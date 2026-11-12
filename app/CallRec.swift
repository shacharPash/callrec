// CallRec: menu bar app around the callrec engine.
// Click the icon, "Start recording", "Stop". Everything else (both sides, language, transcript) is automatic.

import AppKit
import AVFoundation
import Carbon.HIToolbox
import EventKit
import ServiceManagement
import SwiftUI
import UserNotifications

let home = FileManager.default.homeDirectoryForCurrentUser
let recDir = home.appendingPathComponent("CallRecordings")
let stateDir = home.appendingPathComponent(".callrec")
let autoOffFlag = stateDir.appendingPathComponent("auto-off")
let discreetFlag = stateDir.appendingPathComponent("discreet")
let muteLog = stateDir.appendingPathComponent("mute-log")
let toolDirs = [stateDir.appendingPathComponent("bin").path, "/opt/homebrew/bin", "/usr/local/bin"]
@MainActor weak var currentEngine: Engine?
let searchPath = (toolDirs + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")

/// Saves (or clears) a recording's name in its meta.json, and in the transcript's first line.
func setTitle(_ dir: URL, _ title: String?) {
    let url = dir.appendingPathComponent("meta.json")
    var meta = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    let t = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    meta["title"] = t.isEmpty ? nil : t
    if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .withoutEscapingSlashes]) {
        try? data.write(to: url)
    }
    let md = dir.appendingPathComponent("call.transcript.md")
    if var text = try? String(contentsOf: md, encoding: .utf8), text.hasPrefix("# ") {
        let end = text.firstIndex(of: "\n") ?? text.endIndex
        text.replaceSubrange(text.startIndex..<end, with: "# " + (t.isEmpty ? dir.lastPathComponent : t))
        try? text.write(to: md, atomically: true, encoding: .utf8)
    }
}

func metaTitle(_ dir: URL) -> String? {
    guard let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
          let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let t = meta["title"] as? String, !t.isEmpty else { return nil }
    return t
}

struct Recording: Identifiable {
    let id: URL
    let title: String
    let transcript: URL?
    let transcribing: Bool
}

enum Phase: Equatable {
    case starting
    case needsSetup(String)
    case settingUp(String)
    case ready        // waiting for you (or for a call, if auto is on)
    case paused       // stopped by hand, the call is still on
    case recording(app: String?, since: Date)
    case saving
    case failed(String)
}

@MainActor
final class Engine: ObservableObject {
    @Published var phase: Phase = .starting
    @Published var warning: String?
    @Published var recordings: [Recording] = []
    @Published var now = Date()
    @Published var autoStart: Bool {
        didSet { setAutoFlag(autoStart) }
    }
    /// Always discreet: plain icon, no timer, no pop-ups during a call, so nothing shows on a shared screen.
    /// The only pop-ups are for setup and the self-test, never during a call.
    func applyDiscreet() {
        FileManager.default.createFile(atPath: discreetFlag.path, contents: nil)
    }

    /// Name each recording after the calendar meeting happening when it starts. Off until you turn it on,
    /// so the Calendar permission prompt shows up then and never in the middle of a call.
    @Published var calendarTitles: Bool = UserDefaults.standard.bool(forKey: "calendarTitles") {
        didSet {
            UserDefaults.standard.set(calendarTitles, forKey: "calendarTitles")
            if calendarTitles && !oldValue { askCalendar() }
        }
    }
    private let calendar = EKEventStore()
    private var titledFolder: String?

    func askCalendar() {
        calendar.requestFullAccessToEvents { granted, _ in
            Task { @MainActor in
                guard !granted else { return }
                self.calendarTitles = false
                let alert = NSAlert()
                alert.messageText = "CallRec can't read your calendar"
                alert.informativeText = "Allow CallRec in System Settings > Privacy & Security > Calendars, then turn this on again."
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    /// The timed meeting closest to `at` that is happening then (or starts within 10 minutes).
    func meetingTitle(at: Date) -> String? {
        guard calendarTitles, EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        let pred = calendar.predicateForEvents(withStart: at.addingTimeInterval(-6 * 3600),
                                               end: at.addingTimeInterval(600), calendars: nil)
        return calendar.events(matching: pred)
            .filter { !$0.isAllDay && $0.startDate <= at.addingTimeInterval(600) && $0.endDate > at
                      && !($0.title ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
            .min { abs($0.startDate.timeIntervalSince(at)) < abs($1.startDate.timeIntervalSince(at)) }?
            .title
    }

    @Published var openAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet {
            guard openAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if openAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                openAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    private var process: Process?
    private var quitting = false
    private var buffer = Data()
    private var ticks = 0
    // The engine runs from ~/.callrec/engine, not from inside the app, so updating it does not
    // change the app's signature (which would make macOS ask for permissions again).
    private let engineDir = stateDir.appendingPathComponent("engine")
    private var engineURL: URL { engineDir.appendingPathComponent("callrec") }
    private var setupURL: URL { engineDir.appendingPathComponent("setup.sh") }

    func syncEngine() {
        let fm = FileManager.default
        try? fm.createDirectory(at: engineDir, withIntermediateDirectories: true)
        try? fm.removeItem(at: engineDir.appendingPathComponent("install.sh"))
        let bundled = Bundle.main.resourceURL!.appendingPathComponent("engine")
        for name in ["callrec", "setup.sh"] {
            let src = bundled.appendingPathComponent(name), dst = engineDir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: src) else { continue }
            let old = try? Data(contentsOf: dst)
            // Only copy when the app ships a newer engine; a newer local copy is left alone.
            let bundledDate = (try? fm.attributesOfItem(atPath: src.path)[.modificationDate] as? Date) ?? .distantPast
            let localDate = (try? fm.attributesOfItem(atPath: dst.path)[.modificationDate] as? Date) ?? .distantPast
            if old == nil || (old != data && bundledDate > localDate) {
                try? data.write(to: dst)
            }
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
        }
    }

    init() {
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        // Default: record only when you ask.
        if UserDefaults.standard.object(forKey: "autoStart") == nil {
            FileManager.default.createFile(atPath: autoOffFlag.path, contents: nil)
            UserDefaults.standard.set(false, forKey: "autoStart")
        }
        autoStart = !FileManager.default.fileExists(atPath: autoOffFlag.path)
        currentEngine = self
        applyDiscreet()
        syncEngine()
        Hotkey.install([
            UInt32(kVK_ANSI_R): { Task { @MainActor in currentEngine?.toggleRecording() } },
            UInt32(kVK_ANSI_M): { Task { @MainActor in currentEngine?.toggleMute() } },
        ])
        pruneMuteLog()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        refreshRecordings()
        bootstrap()
    }

    // MARK: setup

    func missingPieces() -> [String] {
        var missing: [String] = []
        for tool in ["uv", "ffmpeg", "whisper-cli"] where !toolDirs.contains(where: {
            FileManager.default.isExecutableFile(atPath: "\($0)/\(tool)")
        }) { missing.append(tool) }
        let models = stateDir.appendingPathComponent("models")
        for (file, label) in [("ivrit-whisper-large-v3-turbo.bin", "Hebrew model"),
                              ("ggml-large-v3-turbo-q8_0.bin", "English model")]
        where !FileManager.default.fileExists(atPath: models.appendingPathComponent(file).path) {
            missing.append(label)
        }
        return missing
    }

    func bootstrap() {
        let missing = missingPieces()
        if missing.isEmpty {
            // First launch: run the self-test, so permission prompts appear now and not during a call.
            // A new build has a new signature, so macOS asks again: run the check on its first launch too.
            let build = Self.buildID()
            let tested = UserDefaults.standard.bool(forKey: "selftestPassed")
                && UserDefaults.standard.string(forKey: "selftestBuild") == build
            startEngine(selftestFirst: !tested)
        } else {
            phase = .needsSetup(missing.joined(separator: ", "))
        }
    }

    static func buildID() -> String {
        let exe = Bundle.main.executableURL!
        let date = (try? FileManager.default.attributesOfItem(atPath: exe.path)[.modificationDate] as? Date) ?? .distantPast
        return String(Int(date.timeIntervalSince1970))
    }

    func runSetup() {
        phase = .settingUp("Installing tools and models (a few minutes)…")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [setupURL.path]
        p.environment = env()
        let log = stateDir.appendingPathComponent("setup.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: log)
        p.standardOutput = handle
        p.standardError = handle
        p.terminationHandler = { proc in
            Task { @MainActor in
                if proc.terminationStatus == 0 && self.missingPieces().isEmpty {
                    self.notify("CallRec is ready", "Now checking that both sides record…", force: true)
                    self.startEngine(selftestFirst: true)
                } else {
                    self.phase = .failed("Setup failed. See ~/.callrec/setup.log")
                }
            }
        }
        try? p.run()
    }

    func runSelftest() {
        guard process == nil || !isRecording else { return }
        stopEngine { self.startEngine(selftestFirst: true) }
    }

    // MARK: engine process

    func env() -> [String: String] {
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = searchPath
        e["CALLREC_EVENTS"] = "1"
        e["CALLREC_END_GRACE"] = "300"  // safety net: stop 5 minutes after the call app is gone
        e["PYTHONUNBUFFERED"] = "1"
        e["CALLREC_APP_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        return e
    }

    func startEngine(selftestFirst: Bool = false) {
        guard process == nil else { return }
        // Ask for the mic up front, so the prompt never shows up in the middle of a call.
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        phase = .starting
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Self-test first (records 5s and plays a sound), then keep running and wait for you.
        let cmd = "\"\(engineURL.path)\""
        p.arguments = ["-c", selftestFirst ? "\(cmd) selftest; exec \(cmd)" : "exec \(cmd)"]
        p.environment = env()
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        let logURL = stateDir.appendingPathComponent("engine.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        if let log = try? FileHandle(forWritingTo: logURL) {
            log.seekToEndOfFile()
            p.standardError = log
        }
        out.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            Task { @MainActor in self.consume(data) }
        }
        p.terminationHandler = { _ in
            Task { @MainActor in
                out.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                if self.quitting {
                    NSApp.reply(toApplicationShouldTerminate: true)
                    NSApp.terminate(nil)
                } else if let done = self.onStopped {
                    self.onStopped = nil
                    done()
                } else {
                    // The engine should never exit on its own: restart it. Any cut-off
                    // recording is finished automatically when it starts again.
                    self.phase = .failed("Restarting…")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.bootstrap() }
                }
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            phase = .failed("Could not start: \(error.localizedDescription)")
        }
    }

    private var onStopped: (() -> Void)?

    func stopEngine(then: @escaping () -> Void) {
        guard let p = process else { then(); return }
        onStopped = then
        p.terminate()  // SIGTERM: the engine saves any recording before it exits
    }

    func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let state = obj["state"] as? String else { continue }
            handle(state, obj)
        }
    }

    func handle(_ state: String, _ e: [String: Any]) {
        switch state {
        case "waiting", "idle":
            phase = .ready
        case "paused":
            phase = .paused
        case "recording":
            let since = (e["started"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
            if case .recording = phase {} else { warning = nil; setMuted(false) }
            phase = .recording(app: e["app"] as? String, since: since)
            if let folder = e["folder"] as? String, folder != titledFolder {
                titledFolder = folder
                let dir = URL(fileURLWithPath: folder)
                if metaTitle(dir) == nil, let t = meetingTitle(at: since) { setTitle(dir, t) }
            }
        case "saving":
            setMuted(false)  // a mute ends with its recording
            phase = .saving
        case "saved":
            refreshRecordings()
            if e["transcribing"] as? Bool == true {
                notify("Recording saved", "Transcribing now. You'll get a notification when it's ready.")
            }
        case "recovered":
            refreshRecordings()
            notify("Recovered a recording", "A recording that was cut off was saved and is being transcribed.")
        case "warning", "error":
            let msg = e["message"] as? String ?? "Something went wrong"
            warning = msg
            notify("CallRec: check this now", msg)
        case "selftest":
            let mic = e["mic"] as? Bool ?? false, sys = e["system"] as? Bool ?? false
            UserDefaults.standard.set(mic && sys, forKey: "selftestPassed")
            UserDefaults.standard.set(Self.buildID(), forKey: "selftestBuild")
            if mic && sys {
                warning = nil
                notify("CallRec works", "Both your mic and the other side are recorded.", force: true)
            } else {
                warning = !mic ? "Microphone is not recorded. Allow CallRec in System Settings > Privacy & Security > Microphone."
                               : "The other side is not recorded. Allow CallRec in System Settings > Privacy & Security > Screen & System Audio Recording."
                notify("CallRec needs a permission", warning!, force: true)
            }
        case "off":
            break
        default:
            break
        }
    }

    // MARK: actions

    var isRecording: Bool { if case .recording = phase { return true } else { return false } }

    func startRecording() {
        guard let p = process, p.isRunning else { bootstrap(); return }
        warning = nil
        kill(p.processIdentifier, SIGUSR1)
    }

    func stopRecording() {
        guard let p = process, p.isRunning else { return }
        kill(p.processIdentifier, SIGUSR2)
    }

    /// "Mute me in the recording": your mic is silent in the recording until you unmute.
    /// For when you mute yourself in the meeting app and talk to someone in the room.
    @Published var mutedMe = false

    func toggleMute() {
        guard isRecording else { return }
        setMuted(!mutedMe)
    }

    func setMuted(_ on: Bool) {
        guard on != mutedMe else { return }
        mutedMe = on
        let line = "\(on ? "on" : "off") \(Date().timeIntervalSince1970)\n"
        if let h = try? FileHandle(forWritingTo: muteLog) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        } else {
            try? line.write(to: muteLog, atomically: true, encoding: .utf8)
        }
    }

    func pruneMuteLog() {
        guard let text = try? String(contentsOf: muteLog, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n")
        if lines.count > 400 {
            try? (lines.suffix(200).joined(separator: "\n") + "\n").write(to: muteLog, atomically: true, encoding: .utf8)
        }
    }

    /// Ctrl+Option+R from anywhere.
    func toggleRecording() {
        switch phase {
        case .recording: stopRecording()
        case .ready, .paused: startRecording()
        default: break
        }
    }

    func setAutoFlag(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "autoStart")
        if on {
            try? FileManager.default.removeItem(at: autoOffFlag)
        } else {
            FileManager.default.createFile(atPath: autoOffFlag.path, contents: nil)
        }
    }

    /// Any quit (menu, Dock, logout, AppleScript): stop the engine first so a recording is saved.
    func shouldTerminate() -> NSApplication.TerminateReply {
        guard let p = process, p.isRunning else { return .terminateNow }
        if quitting { return .terminateLater }
        quit()
        return .terminateLater
    }

    func quit() {
        quitting = true
        if let p = process, p.isRunning {
            phase = .saving
            p.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                NSApp.reply(toApplicationShouldTerminate: true)
                exit(0)
            }
        } else {
            NSApp.terminate(nil)
        }
    }

    // MARK: recordings

    func tick() {
        now = Date()
        ticks += 1
        if ticks % 5 == 0 { refreshRecordings() }
    }

    func refreshRecordings() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: recDir, includingPropertiesForKeys: nil) else {
            recordings = []
            return
        }
        recordings = dirs.filter { $0.hasDirectoryPath }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(8)
            .map { dir in
                let md = dir.appendingPathComponent("call.transcript.md")
                return Recording(
                    id: dir,
                    title: Self.title(for: dir),
                    transcript: fm.fileExists(atPath: md.path) ? md : nil,
                    transcribing: fm.fileExists(atPath: dir.appendingPathComponent(".transcribing").path))
            }
    }

    /// 2026-11-08_1101_Zoom → "Today 11:01", "Yesterday 11:01", "Nov 8, 11:01" (long: with weekday and year).
    static func dateText(for dir: URL, long: Bool) -> String? {
        let parts = dir.lastPathComponent.split(separator: "_", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmm"
        guard let d = f.date(from: "\(parts[0])_\(parts[1].prefix(4))") else { return nil }
        let out = DateFormatter()
        let cal = Calendar.current
        if long {
            out.dateFormat = "EEEE, MMM d yyyy, HH:mm"
        } else if cal.isDateInToday(d) {
            out.dateFormat = "'Today' HH:mm"
        } else if cal.isDateInYesterday(d) {
            out.dateFormat = "'Yesterday' HH:mm"
        } else {
            out.dateFormat = cal.isDate(d, equalTo: Date(), toGranularity: .year) ? "MMM d, HH:mm" : "MMM d yyyy, HH:mm"
        }
        return out.string(from: d)
    }

    static func title(for dir: URL) -> String {
        // 2026-11-08_1101_Zoom → "Today 11:01 · Zoom · 19 min"
        let parts = dir.lastPathComponent.split(separator: "_", maxSplits: 2).map(String.init)
        var title = dir.lastPathComponent
        if let d = dateText(for: dir, long: false) {
            title = metaTitle(dir).map { "\($0) · \(d)" } ?? d + (parts.count > 2 ? " · \(parts[2])" : "")
        }
        let metaURL = dir.appendingPathComponent("meta.json")
        if let data = try? Data(contentsOf: metaURL),
           let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let dur = meta["duration"] as? Double {
            title += " · \(max(1, Int(dur / 60))) min"
        }
        return title
    }

    func open(_ r: Recording) {
        NSWorkspace.shared.open(r.transcript ?? r.id)
    }

    func notify(_ title: String, _ body: String, force: Bool = false) {
        if !force { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    // MARK: display

    var elapsed: String {
        guard case let .recording(_, since) = phase else { return "" }
        let s = Int(now.timeIntervalSince(since))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    var statusLine: String {
        switch phase {
        case .starting: return "Starting…"
        case .needsSetup(let what): return "Setup needed: \(what)"
        case .settingUp(let msg): return msg
        case .ready: return autoStart ? "Ready · records calls automatically" : "Ready"
        case .paused: return "Stopped · waiting for the call to end"
        case .recording(let app, _):
            return "Recording \(elapsed)" + (app.map { " · \($0)" } ?? "") + (mutedMe ? " · you are muted" : "")
        case .saving: return "Saving…"
        case .failed(let msg): return msg
        }
    }

    var icon: String {
        if warning != nil { return "exclamationmark.triangle.fill" }
        switch phase {
        case .recording: return mutedMe ? "mic.slash.circle.fill" : "waveform.circle.fill"
        case .needsSetup, .failed: return "exclamationmark.triangle"
        case .starting, .settingUp, .saving: return "ellipsis.circle"
        default: return "waveform.circle"
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var library: Library
    @Environment(\.openWindow) private var openWindow

    func showRecordings(_ dir: URL? = nil) {
        library.reload()
        if let dir { library.selection = dir }
        openWindow(id: "recordings")
        NSApp.activate(ignoringOtherApps: true)
    }

    var body: some View {
        Text(engine.statusLine)
        if let w = engine.warning {
            Text("⚠︎ " + w)
        }
        Divider()
        switch engine.phase {
        case .recording:
            Button("Stop recording   ⌃⌥R") { engine.stopRecording() }
            Button(engine.mutedMe ? "Unmute me in the recording   ⌃⌥M" : "Mute me in the recording   ⌃⌥M") {
                engine.toggleMute()
            }
        case .ready, .paused:
            Button("Start recording   ⌃⌥R") { engine.startRecording() }
        case .needsSetup:
            Button("Finish setup…") { engine.runSetup() }
        case .failed:
            Button("Try again") { engine.bootstrap() }
        default:
            EmptyView()
        }
        Toggle("Start automatically when a call starts", isOn: $engine.autoStart)
        Toggle("Name recordings from Calendar", isOn: $engine.calendarTitles)
        Divider()
        if !engine.recordings.isEmpty {
            Text("Recent recordings")
            ForEach(engine.recordings) { r in
                Button((r.transcript != nil ? "" : (r.transcribing ? "⏳ " : "♪ ")) + r.title) { showRecordings(r.id) }
            }
        }
        Button("Show all recordings…") { showRecordings() }
            .keyboardShortcut("o")
        Button("Import recording…") {
            showRecordings()
            DispatchQueue.main.async { library.chooseFiles() }
        }
        .keyboardShortcut("i")
        Divider()
        Button("Test mic and system audio") { engine.runSelftest() }
            .disabled(engine.isRecording)
        Toggle("Open at login", isOn: $engine.openAtLogin)
        Button("Quit CallRec") { engine.quit() }
            .keyboardShortcut("q")
    }
}

/// A global shortcut (Ctrl+Option+R) through Carbon: works in any app, needs no permission.
enum Hotkey {
    /// Key code → action, all with Ctrl+Option.
    static var actions: [UInt32: () -> Void] = [:]
    static var refs: [EventHotKeyRef?] = []

    static func install(_ keys: [UInt32: () -> Void]) {
        guard refs.isEmpty else { return }
        actions = keys
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            Hotkey.actions[id.id]?()
            return noErr
        }, 1, &spec, nil, nil)
        for key in keys.keys {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4352_4543), id: key)  // "CREC", id = key code
            RegisterEventHotKey(key, UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
            refs.append(ref)
        }
    }
}

/// Set by the menu bar icon, which is always on screen: opens the Recordings window from anywhere.
@MainActor var openRecordingsWindow: (() -> Void)?

struct MenuIcon: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var library: Library
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: engine.icon)
            .onAppear {
                openRecordingsWindow = {
                    library.reload()
                    openWindow(id: "recordings")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Opening CallRec again (Spotlight, Applications, Dock) shows the recordings, since the app has no window of its own.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { openRecordingsWindow?() }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { currentEngine?.shouldTerminate() ?? .terminateNow }
    }
}

@main
struct CallRecApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var engine = Engine()
    @StateObject private var library = Library()

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(engine).environmentObject(library)
        } label: {
            MenuIcon().environmentObject(engine).environmentObject(library)
        }

        Window("Recordings", id: "recordings") {
            RecordingsView().environmentObject(library)
        }
        .defaultSize(width: 980, height: 640)
    }
}
