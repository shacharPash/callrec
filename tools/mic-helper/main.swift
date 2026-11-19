import AVFoundation
import CoreAudio
import Foundation

// callrec-mic: writes the microphone to stdout as 16 kHz mono 16 bit PCM, echo cancelled by Apple voice processing
// unless the sound goes to headphones. Every buffer the audio engine delivers is written, so nothing is dropped.
// A change of the audio devices (a call app joining, headphones, another sample rate) restarts the audio engine
// inside this process.
// Exit codes the engine reads: 2 no voice processing, 3 the audio keeps changing or did not restart,
// 4 no input device, 5 no converter, 6 the audio engine did not start, 7 conversion failed.

func log(_ message: String) {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}

func fail(_ message: String, _ code: Int32) -> Never {
    log(message)
    _exit(code)
}

func seconds() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1e9
}

let launched = seconds()

let arguments = CommandLine.arguments
let probe = arguments.contains("--probe")
let voiceProcessingAllowed = !arguments.contains("--no-voice-processing")
let restartDelay = 0.3
let restartTries = 3
let maxRestarts = 8
let restartWindow = 30.0
let levelSeconds = 3.0

signal(SIGPIPE, SIG_IGN)
let stopSignals: [DispatchSourceSignal] = [SIGTERM, SIGINT].map { number in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler { _exit(0) }
    source.resume()
    return source
}

func fourCC(_ text: String) -> UInt32 {
    text.utf8.reduce(0) { $0 << 8 | UInt32($1) }
}

func fourCCText(_ code: UInt32) -> String {
    String(bytes: [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xff) }, encoding: .ascii) ?? "\(code)"
}

func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, empty: T) -> T? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var value = empty
    var size = UInt32(MemoryLayout<T>.size)
    let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
    return status == noErr ? value : nil
}

/// The default output. Headphones need no echo cancellation: the other side goes into the ears, not back into the
/// microphone, and without it macOS does not lower the other apps' sound. Bluetooth (far more often headphones than
/// a speaker) and the headphone jack count; USB, HDMI, AirPlay and anything unknown may be speakers.
struct Output {
    let transport: UInt32
    let source: UInt32?

    static let system = AudioObjectID(kAudioObjectSystemObject)

    static var current: Output? {
        guard let device = property(system, kAudioHardwarePropertyDefaultOutputDevice, empty: AudioDeviceID(0)),
              device != 0,
              let transport = property(device, kAudioDevicePropertyTransportType, empty: UInt32(0)) else { return nil }
        return Output(transport: transport,
                      source: property(device, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput,
                                       empty: UInt32(0)))
    }

    var headphones: Bool {
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return true
        case kAudioDeviceTransportTypeBuiltIn: return source == fourCC("hdpn")
        default: return false
        }
    }

    var described: String {
        (headphones ? "headphones" : "speakers") + " (\(fourCCText(transport))\(source.map { " " + fourCCText($0) } ?? ""))"
    }
}

/// Voice processing is on for speakers and off for headphones, and never with --no-voice-processing.
func wantsVoiceProcessing(_ output: Output?) -> Bool {
    voiceProcessingAllowed && !(output?.headphones ?? false)
}

let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
let out = FileHandle.standardOutput

func describe(_ format: AVAudioFormat) -> String {
    "\(Int(format.sampleRate)) Hz, \(format.channelCount) channels"
}

/// Turns the first input channel into 16 kHz mono and writes it. Runs on the tap's thread; reset() runs on
/// the main thread while the tap is removed.
final class Tap {
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var rate = 0.0
    private var since = seconds()
    private var heard = false
    private var levelFrames = 0
    private var sums: [Double] = []

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        converter?.reset()
        since = seconds()
        heard = false
        levelFrames = 0
        sums = []
    }

    func handle(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        let frames = Int(buffer.frameLength)
        guard frames > 0, let data = buffer.floatChannelData else { return }
        let format = buffer.format
        if !heard {
            heard = true
            log(String(format: "first audio %.1f s after the start: %@", seconds() - since, describe(format)))
        }
        measure(data, format: format, frames: frames, stride: buffer.stride)
        if converter == nil || format.sampleRate != rate {
            rate = format.sampleRate
            let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1,
                                     interleaved: false)!
            guard let made = AVAudioConverter(from: mono, to: target) else { fail("no converter for \(Int(rate)) Hz", 5) }
            converter = made
        }
        write(firstChannel(data, frames: frames, stride: buffer.stride), frames: frames)
    }

    private func firstChannel(_ data: UnsafePointer<UnsafeMutablePointer<Float>>, frames: Int,
                              stride: Int) -> AVAudioPCMBuffer? {
        guard let mono = converter?.inputFormat,
              let chunk = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        chunk.frameLength = AVAudioFrameCount(frames)
        let into = chunk.floatChannelData![0]
        let from = data[0]
        if stride == 1 {
            into.update(from: from, count: frames)
        } else {
            for i in 0..<frames { into[i] = from[i * stride] }
        }
        return chunk
    }

    private func write(_ chunk: AVAudioPCMBuffer?, frames: Int) {
        guard let chunk, let converter else { return }
        let capacity = AVAudioFrameCount(Double(frames) * 16000 / rate) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return chunk
        }
        if status == .error {
            fail("conversion failed: \(error.map { "\($0)" } ?? "unknown error")", 7)
        }
        if converted.frameLength > 0, let samples = converted.int16ChannelData {
            do {
                try out.write(contentsOf: Data(bytes: samples[0], count: Int(converted.frameLength) * 2))
            } catch {
                _exit(0)
            }
        }
    }

    /// Logs each channel's level once, a few seconds after each start, to show which channels carry the voice.
    private func measure(_ data: UnsafePointer<UnsafeMutablePointer<Float>>, format: AVAudioFormat, frames: Int,
                         stride: Int) {
        let limit = Int(format.sampleRate * levelSeconds)
        guard levelFrames < limit else { return }
        let channels = Int(format.channelCount)
        if sums.count != channels { sums = Array(repeating: 0, count: channels) }
        for c in 0..<channels {
            var sum = 0.0
            for i in 0..<frames {
                let x = Double(format.isInterleaved ? data[0][i * stride + c] : data[c][i])
                sum += x * x
            }
            sums[c] += sum
        }
        levelFrames += frames
        if levelFrames >= limit {
            let levels = sums.enumerated().map { c, sum in
                String(format: "ch%d %.1f", c, 10 * log10(max(sum / Double(levelFrames), 1e-12)))
            }
            log("levels in dBFS: " + levels.joined(separator: ", "))
        }
    }
}

let engine = AVAudioEngine()
let input = engine.inputNode
let tap = Tap()

/// Main thread, engine stopped.
func setVoiceProcessing(_ on: Bool) throws {
    if input.isVoiceProcessingEnabled != on {
        try input.setVoiceProcessingEnabled(on)
    }
    if on {
        input.voiceProcessingOtherAudioDuckingConfiguration =
            AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
    }
}

var output = Output.current
if wantsVoiceProcessing(output) {
    do {
        try setVoiceProcessing(true)
    } catch {
        fail("voice processing unavailable: \(error)", 2)
    }
}
_ = engine.outputNode

enum StartError: Error {
    case noInput
}

/// Installs the tap for the input's current format and starts the engine. Main thread, engine stopped.
func run() throws -> AVAudioFormat {
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else { throw StartError.noInput }
    tap.reset()
    input.installTap(onBus: 0, bufferSize: 960, format: nil) { buffer, _ in tap.handle(buffer) }
    engine.prepare()
    do {
        try engine.start()
    } catch {
        input.removeTap(onBus: 0)
        throw error
    }
    return format
}

var pending: DispatchWorkItem?
var restarts: [Double] = []

func scheduleRestart(_ reason: String) {
    pending?.cancel()
    let work = DispatchWorkItem { restart(reason, attempt: 1) }
    pending = work
    DispatchQueue.main.asyncAfter(deadline: .now() + restartDelay, execute: work)
}

func restart(_ reason: String, attempt: Int) {
    let began = seconds()
    if attempt == 1 {
        restarts = restarts.filter { began - $0 < restartWindow } + [began]
        if restarts.count > maxRestarts {
            fail("audio keeps changing: \(restarts.count) restarts in \(Int(restartWindow)) s", 3)
        }
    }
    engine.stop()
    input.removeTap(onBus: 0)
    output = Output.current
    let wanted = wantsVoiceProcessing(output)
    if input.isVoiceProcessingEnabled != wanted {
        do {
            try setVoiceProcessing(wanted)
        } catch {
            log("voice processing could not be turned \(wanted ? "on" : "off"): \(error)")
        }
    }
    do {
        let format = try run()
        log(String(format: "restarted after %@ in %.2f s: %@, output %@, voice processing %@", reason,
                   seconds() - began, describe(format), output?.described ?? "unknown",
                   input.isVoiceProcessingEnabled ? "true" : "false"))
    } catch {
        if attempt >= restartTries {
            fail("audio engine did not restart after \(reason): \(error)", 3)
        }
        log("restart \(attempt) after \(reason) failed: \(error); trying again")
        let retry = DispatchWorkItem { restart(reason, attempt: attempt + 1) }
        pending = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: retry)
    }
}

NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                       queue: nil) { _ in
    DispatchQueue.main.async {
        log("audio configuration changed")
        scheduleRestart("a configuration change")
    }
}

var outputAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                               mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
AudioObjectAddPropertyListenerBlock(Output.system, &outputAddress, .main) { _, _ in
    let now = Output.current
    if wantsVoiceProcessing(now) != input.isVoiceProcessingEnabled {
        log("the output changed to \(now?.described ?? "nothing")")
        scheduleRestart("an output change")
    }
}

signal(SIGUSR1, SIG_IGN)
let testSignal = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
testSignal.setEventHandler { scheduleRestart("SIGUSR1") }
testSignal.resume()

let started: AVAudioFormat
do {
    started = try run()
} catch StartError.noInput {
    fail("no input device", 4)
} catch {
    fail("audio engine did not start: \(error)", 6)
}
log(String(format: "started in %.1f s: %@, output %@, voice processing %@", seconds() - launched, describe(started),
           output?.described ?? "unknown", input.isVoiceProcessingEnabled ? "true" : "false"))
if probe {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { _exit(0) }
}
dispatchMain()
