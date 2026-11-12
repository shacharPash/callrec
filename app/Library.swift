// The "Recordings" window: every recording, its transcript, and a player.

import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct Entry: Identifiable, Hashable {
    let id: URL
    let title: String
    let subtitle: String
    let language: String
    let hasTranscript: Bool
    let transcribing: Bool
    let failure: String?
    let searchText: String
    let info: [Info]
}

struct Info: Hashable {
    let label: String
    let value: String
}

/// The recording's audio: call.wav until it is compressed, then call.m4a. While both exist the WAV is
/// the full recording (it is removed only after the m4a is checked), and the m4a may be cut off.
func audioFile(_ dir: URL) -> URL? {
    for name in ["call.wav", "call.m4a"] {
        let u = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: u.path) { return u }
    }
    return nil
}

func languageName(_ code: String) -> String {
    code.split(separator: "+").map { c -> String in
        switch c {
        case "he": return "Hebrew"
        case "en": return "English"
        default: return String(c)
        }
    }.joined(separator: " + ")
}

func durationText(_ d: Double) -> String {
    let m = Int((d / 60).rounded())
    if d < 60 { return "\(Int(d)) sec" }
    return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
}

struct Line: Identifiable {
    let id: Int
    let speaker: String
    let time: TimeInterval
    let label: String
    let text: String
}

@MainActor
final class Library: ObservableObject {
    @Published var entries: [Entry] = []
    @Published var query = ""
    @Published var lines: [Line] = []
    @Published var playing = false
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var busy = false
    /// Playback speed, kept between recordings.
    @Published var rate: Float = UserDefaults.standard.object(forKey: "playbackRate") as? Float ?? 1 {
        didSet {
            UserDefaults.standard.set(rate, forKey: "playbackRate")
            player?.rate = rate
        }
    }
    static let rates: [Float] = [1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    func nextRate() {
        let i = Self.rates.firstIndex(of: rate) ?? 0
        rate = Self.rates[(i + 1) % Self.rates.count]
    }
    @Published var selection: URL? {
        didSet { if selection != oldValue { load() } }
    }

    private var player: AVAudioPlayer?
    /// Folders that existed before an import, so the new one can be selected when it appears.
    private var beforeImport: Set<URL>?

    init() {
        reload()
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickPlayer() }
        }
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload(keepLines: true) }
        }
    }

    var filtered: [Entry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? entries : entries.filter { $0.searchText.contains(q) }
    }

    var selected: Entry? { entries.first { $0.id == selection } }

    func reload(keepLines: Bool = false) {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: recDir, includingPropertiesForKeys: nil)) ?? []
        let old = selected
        entries = dirs.filter { $0.hasDirectoryPath }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { dir in
                let md = dir.appendingPathComponent("call.transcript.md")
                let meta = Self.meta(dir)
                let app = (meta["app"] as? String) ?? Self.appFromName(dir)
                let lang = meta["language"] as? String ?? ""
                let name = meta["title"] as? String
                let date = Engine.dateText(for: dir, long: false)
                var sub: [String] = []
                if name != nil, let date { sub.append(date) }
                if let app { sub.append(app) }
                if let d = meta["duration"] as? Double { sub.append(durationText(d)) }
                if !lang.isEmpty { sub.append(languageName(lang)) }
                let text = (try? String(contentsOf: md, encoding: .utf8)) ?? ""
                var info: [Info] = []
                func add(_ label: String, _ value: String?) {
                    if let v = value, !v.isEmpty { info.append(Info(label: label, value: v)) }
                }
                add("Date", Engine.dateText(for: dir, long: true))
                add("Duration", (meta["duration"] as? Double).map(durationText))
                add("App", app)
                add("Language", lang.isEmpty ? nil : languageName(lang))
                add("Transcribed with", (meta["model"] as? String).map(Self.modelName))
                add("Microphone", meta["mic"] as? String)
                add("Played through", meta["output"] as? String)
                return Entry(
                    id: dir,
                    title: name ?? date ?? dir.lastPathComponent,
                    subtitle: sub.joined(separator: " · "),
                    language: lang,
                    hasTranscript: fm.fileExists(atPath: md.path),
                    transcribing: fm.fileExists(atPath: dir.appendingPathComponent(".transcribing").path),
                    failure: fm.fileExists(atPath: md.path) ? nil
                        : try? String(contentsOf: dir.appendingPathComponent(".transcribe-failed"), encoding: .utf8),
                    searchText: (dir.lastPathComponent + " " + (name ?? "") + " " + text).lowercased(),
                    info: info)
            }
        if let before = beforeImport, let new = entries.first(where: { !before.contains($0.id) }) {
            beforeImport = nil
            selection = new.id
        }
        if selection == nil { selection = entries.first?.id }
        // A transcript that just finished: show it.
        if keepLines, let now = selected, let before = old, now.hasTranscript != before.hasTranscript { load() }
    }

    /// 2026-11-08_1229_Chrome → "Chrome" (older recordings have no app in meta.json).
    static func appFromName(_ dir: URL) -> String? {
        let parts = dir.lastPathComponent.split(separator: "_", maxSplits: 2)
        return parts.count > 2 ? String(parts[2]) : nil
    }

    /// Older recordings stored the model file name; show a readable name.
    static func modelName(_ m: String) -> String {
        if m.hasPrefix("ivrit") { return "ivrit.ai whisper-large-v3-turbo" }
        if m.hasPrefix("ggml-large-v3-turbo") { return "Whisper large-v3-turbo" }
        return m
    }

    static func meta(_ dir: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    func load() {
        player?.stop()
        player = nil
        playing = false
        position = 0
        duration = 0
        lines = []
        guard let dir = selection else { return }
        let md = dir.appendingPathComponent("call.transcript.md")
        if let text = try? String(contentsOf: md, encoding: .utf8) {
            lines = Self.parse(text)
        }
        if let audio = audioFile(dir), let p = try? AVAudioPlayer(contentsOf: audio) {
            p.enableRate = true
            p.rate = rate
            p.prepareToPlay()
            player = p
            duration = p.duration
        }
    }

    /// Parses "**speaker** (00:01:02): text" and "text (00:01:02)" paragraphs.
    static func parse(_ md: String) -> [Line] {
        let body = md.components(separatedBy: "\n---\n").last ?? md
        let withSpeaker = try! NSRegularExpression(pattern: #"^\*\*(.+?)\*\* \((\d\d):(\d\d):(\d\d)\): (.*)$"#)
        let plain = try! NSRegularExpression(pattern: #"^(.*) \((\d\d):(\d\d):(\d\d)\)$"#)
        var out: [Line] = []
        for para in body.components(separatedBy: "\n\n") {
            let p = para.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.isEmpty else { continue }
            let ns = p as NSString
            let range = NSRange(location: 0, length: ns.length)
            func g(_ m: NSTextCheckingResult, _ i: Int) -> String { ns.substring(with: m.range(at: i)) }
            if let m = withSpeaker.firstMatch(in: p, range: range) {
                let t = Double(g(m, 2))! * 3600 + Double(g(m, 3))! * 60 + Double(g(m, 4))!
                out.append(Line(id: out.count, speaker: g(m, 1), time: t, label: "\(g(m, 2)):\(g(m, 3)):\(g(m, 4))".replacingOccurrences(of: "^00:", with: "", options: .regularExpression), text: g(m, 5)))
            } else if let m = plain.firstMatch(in: p, range: range) {
                let t = Double(g(m, 2))! * 3600 + Double(g(m, 3))! * 60 + Double(g(m, 4))!
                out.append(Line(id: out.count, speaker: "", time: t, label: "\(g(m, 2)):\(g(m, 3)):\(g(m, 4))".replacingOccurrences(of: "^00:", with: "", options: .regularExpression), text: g(m, 1)))
            }
        }
        return out
    }

    // MARK: player

    func togglePlay() {
        guard let p = player else { return }
        if p.isPlaying { p.pause() } else { p.play() }
        playing = p.isPlaying
    }

    func seek(_ t: TimeInterval) {
        guard let p = player else { return }
        p.currentTime = max(0, min(t, p.duration))
        position = p.currentTime
        if !p.isPlaying { p.play() }
        playing = true
    }

    func tickPlayer() {
        guard let p = player else { return }
        if p.isPlaying { position = p.currentTime }
        if playing != p.isPlaying { playing = p.isPlaying }
    }

    /// The other voices in this transcript, in the order they first talk.
    var speakers: [String] {
        var seen: [String] = []
        for l in lines where !l.speaker.isEmpty && l.speaker != "?" && !meNames.contains(l.speaker) && !seen.contains(l.speaker) {
            seen.append(l.speaker)
        }
        return seen
    }

    /// "דובר 1" → "Danny": renames every line of that speaker in the transcript file.
    func renameSpeaker(_ old: String) {
        guard let dir = selection else { return }
        let md = dir.appendingPathComponent("call.transcript.md")
        guard var text = try? String(contentsOf: md, encoding: .utf8) else { return }
        let alert = NSAlert()
        alert.messageText = "Who is \(old)?"
        alert.informativeText = "Every line of \(old) in this recording gets the new name."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = old
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let new = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "*", with: "")
        guard !new.isEmpty, new != old else { return }
        text = text.components(separatedBy: "\n").map { line in
            line.hasPrefix("**\(old)** (") ? "**\(new)**" + line.dropFirst(old.count + 4) : line
        }.joined(separator: "\n")
        try? text.write(to: md, atomically: true, encoding: .utf8)
        let pos = position
        load()
        position = pos
    }

    var currentLine: Int? {
        guard playing || position > 0 else { return nil }
        return lines.last { $0.time <= position + 0.3 }?.id
    }

    // MARK: actions

    func copyTranscript() {
        let text = lines.map { ($0.speaker.isEmpty ? "" : "\($0.speaker): ") + $0.text }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func showInFinder() {
        guard let dir = selection else { return }
        NSWorkspace.shared.activateFileViewerSelecting([audioFile(dir) ?? dir])
    }

    /// Add audio or video files (phone recordings, voice memos, exported meetings) and transcribe them.
    func importFiles(_ urls: [URL]) {
        let files = urls.filter { !$0.hasDirectoryPath && FileManager.default.isReadableFile(atPath: $0.path) }
        guard !files.isEmpty else { return }
        beforeImport = Set(entries.map(\.id))
        let p = Process()
        p.executableURL = stateDir.appendingPathComponent("engine/callrec")
        p.arguments = ["import"] + files.map(\.path)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { _ in
            Task { @MainActor in self.reload(); self.load() }
        }
        do {
            try p.run()
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        for delay in [1.5, 4.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.reload() }
        }
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.title = "Import a recording to transcribe"
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { importFiles(panel.urls) }
    }

    /// Give the recording a name of your own (empty = back to the date).
    func rename() {
        guard let e = selected else { return }
        let alert = NSAlert()
        alert.messageText = "Name this recording"
        alert.informativeText = e.subtitle
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = metaTitle(e.id) ?? ""
        field.placeholderString = e.title
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        setTitle(e.id, field.stringValue)
        reload()
    }

    /// Name an existing recording after the calendar meeting at the time it started.
    func nameFromCalendar() {
        guard let e = selected, let engine = currentEngine else { return }
        let started = (Self.meta(e.id)["started"] as? String).flatMap { s -> Date? in
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            return f.date(from: s)
        }
        guard let at = started else { return }
        if let t = engine.meetingTitle(at: at) {
            setTitle(e.id, t)
            reload()
        } else {
            let alert = NSAlert()
            alert.messageText = "No meeting on your calendar at that time"
            alert.informativeText = engine.calendarTitles ? "You can name it yourself with Rename." : "Turn on \"Name recordings from Calendar\" in the menu first."
            alert.runModal()
        }
    }

    /// Moves the whole recording folder to the Trash (it can be restored from there).
    func delete() {
        guard let e = selected else { return }
        let alert = NSAlert()
        alert.messageText = "Move this recording to the Trash?"
        alert.informativeText = "\(e.title) · \(e.subtitle)\nThe audio and the transcript go to the Trash. You can restore them from there."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        player?.stop()
        player = nil
        let idx = filtered.firstIndex(of: e)
        do {
            try FileManager.default.trashItem(at: e.id, resultingItemURL: nil)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        selection = nil
        reload()
        let rest = filtered
        if let i = idx, !rest.isEmpty { selection = rest[min(i, rest.count - 1)].id }
    }

    /// Transcribe (again) with the engine, e.g. after a failure.
    func transcribe() {
        guard let dir = selection else { return }
        guard let wav = audioFile(dir) else { return }
        busy = true
        let p = Process()
        p.executableURL = stateDir.appendingPathComponent("engine/callrec")
        p.arguments = ["transcribe", wav.path]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { _ in
            Task { @MainActor in
                self.busy = false
                self.reload()
                self.load()
            }
        }
        try? p.run()
    }
}

let meNames: Set<String> = ["אני", "Me"]
let speakerPalette: [Color] = [.orange, .green, .purple, .pink, .teal, .yellow, .brown, .mint, .red, .indigo]

/// Blue for you; every other voice gets its own color, in the order they first talk.
func speakerColor(_ name: String, _ others: [String]) -> Color {
    if meNames.contains(name) { return .blue }
    if name.isEmpty { return .primary }
    if name == "?" { return .secondary }
    let i = others.firstIndex(of: name) ?? 0
    return speakerPalette[i % speakerPalette.count]
}

func rateText(_ r: Float) -> String {
    (r == r.rounded() ? String(format: "%.0f", r) : String(format: "%g", r)) + "×"
}

func formatTime(_ t: Double) -> String {
    let s = Int(t)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
                     : String(format: "%d:%02d", s / 60, s % 60)
}

struct RecordingsView: View {
    @EnvironmentObject var library: Library

    var body: some View {
        NavigationSplitView {
            List(selection: $library.selection) {
                ForEach(library.filtered) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            if e.transcribing { Image(systemName: "hourglass").foregroundStyle(.secondary) }
                            else if e.failure != nil { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                            else if !e.hasTranscript { Image(systemName: "waveform").foregroundStyle(.secondary) }
                            Text(e.title).font(.headline)
                        }
                        .contextMenu {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([audioFile(e.id) ?? e.id]) }
                            Button("Rename…") { library.selection = e.id; library.rename() }
                            Button("Name from Calendar") { library.selection = e.id; library.nameFromCalendar() }
                            Button("Move to Trash…") { library.selection = e.id; library.delete() }
                        }
                        if !e.subtitle.isEmpty {
                            Text(e.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(e.id)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .searchable(text: $library.query, placement: .sidebar, prompt: "Search transcripts")
        } detail: {
            if let e = library.selected {
                DetailView(entry: e)
            } else {
                VStack(spacing: 8) {
                    Text("No recordings yet").foregroundStyle(.secondary)
                    Text("Drag an audio file here to transcribe it").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button { library.chooseFiles() } label: {
                    Label("Import recording", systemImage: "square.and.arrow.down")
                }
                .help("Import an audio or video file to transcribe (or drag it into this window)")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            library.importFiles(urls)
            return !urls.isEmpty
        }
        .frame(minWidth: 760, minHeight: 480)
    }
}

struct DetailView: View {
    @EnvironmentObject var library: Library
    let entry: Entry

    var rtl: Bool { entry.language == "he" || entry.language.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            // Player bar
            HStack(spacing: 12) {
                Button { library.togglePlay() } label: {
                    Image(systemName: library.playing ? "pause.fill" : "play.fill").frame(width: 18)
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(library.duration == 0)
                Text(formatTime(library.position)).monospacedDigit().foregroundStyle(.secondary)
                Slider(value: Binding(get: { library.position }, set: { library.seek($0) }),
                       in: 0...max(library.duration, 1))
                    .disabled(library.duration == 0)
                Text(formatTime(library.duration)).monospacedDigit().foregroundStyle(.secondary)
                Menu {
                    ForEach(Library.rates, id: \.self) { r in
                        Button(rateText(r)) { library.rate = r }
                    }
                } label: {
                    Text(rateText(library.rate)).monospacedDigit()
                } primaryAction: {
                    library.nextRate()
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Playback speed: click to go faster, hold for the list")
                Divider().frame(height: 18)
                Button { library.copyTranscript() } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy transcript").disabled(library.lines.isEmpty)
                Button { library.showInFinder() } label: { Image(systemName: "folder") }
                    .help("Show in Finder")
                Button { library.rename() } label: { Image(systemName: "pencil") }
                    .help("Rename")
                Button { library.delete() } label: { Image(systemName: "trash") }
                    .help("Move to Trash")
                    .keyboardShortcut(.delete, modifiers: .command)
            }
            .padding(12)
            Divider()
            InfoCard(entry: entry, hasSpeakers: library.lines.contains { !$0.speaker.isEmpty },
                     speakers: library.speakers)
            Divider()

            if library.lines.isEmpty {
                VStack(spacing: 12) {
                    if entry.transcribing || library.busy {
                        ProgressView()
                        Text("Transcribing… usually under a minute").foregroundStyle(.secondary)
                    } else if let why = entry.failure {
                        Label("Transcription failed", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(why).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            .frame(maxWidth: 420)
                        Text("The recording itself is safe.").foregroundStyle(.secondary)
                        Button("Try again") { library.transcribe() }
                    } else {
                        Text(entry.hasTranscript ? "Nothing was said in this recording." : "No transcript yet.")
                            .foregroundStyle(.secondary)
                        Button("Transcribe") { library.transcribe() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(library.lines) { line in
                            LineRow(line: line, current: library.currentLine == line.id, rtl: rtl,
                                    color: speakerColor(line.speaker, library.speakers),
                                    rename: { library.renameSpeaker(line.speaker) }) {
                                library.seek(line.time)
                            }
                        }
                        if entry.hasTranscript {
                            Button("Transcribe again") { library.transcribe() }
                                .buttonStyle(.link)
                                .disabled(library.busy)
                                .padding(.top, 8)
                                .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
                }
            }
        }
        .navigationTitle(entry.title)
        .navigationSubtitle(entry.subtitle)
    }
}

struct LineRow: View {
    let line: Line
    let current: Bool
    let rtl: Bool
    let color: Color
    let rename: () -> Void
    let seek: () -> Void

    // Layout stays left-to-right (SwiftUI's RTL flip shifts a ScrollView's content out of view on macOS);
    // Hebrew lines are simply aligned right, and the text itself renders right-to-left on its own.
    var body: some View {
        VStack(alignment: rtl ? .trailing : .leading, spacing: 4) {
            HStack(spacing: 8) {
                if rtl { Spacer(minLength: 0) }
                if rtl { stamp }
                if !line.speaker.isEmpty {
                    Button(action: rename) {
                        Text(line.speaker).font(.subheadline.bold()).foregroundStyle(color)
                    }
                    .buttonStyle(.plain)
                    .help("Click to rename this speaker")
                }
                if !rtl { stamp }
            }
            Text(line.text)
                .font(.body)
                .lineSpacing(3)
                .textSelection(.enabled)
                .multilineTextAlignment(rtl ? .trailing : .leading)
                .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(current ? Color.accentColor.opacity(0.12) : .clear))
    }

    var stamp: some View {
        Button(line.label, action: seek)
            .buttonStyle(.link)
            .font(.caption.monospacedDigit())
    }
}

/// Recording details and a speaker legend, above the transcript.
struct InfoCard: View {
    @EnvironmentObject var library: Library
    let entry: Entry
    let hasSpeakers: Bool
    let speakers: [String]

    var he: Bool { entry.language.hasPrefix("he") || entry.language.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .topLeading)],
                      alignment: .leading, spacing: 8) {
                ForEach(entry.info, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(i.label).font(.caption).foregroundStyle(.secondary)
                        Text(i.value).font(.callout).lineLimit(2).textSelection(.enabled)
                    }
                }
            }
            if hasSpeakers {
                HStack(spacing: 16) {
                    Legend(color: .blue, name: he ? "אני" : "Me", detail: "your microphone")
                    ForEach(speakers, id: \.self) { name in
                        Button { library.renameSpeaker(name) } label: {
                            Legend(color: speakerColor(name, speakers), name: name,
                                   detail: speakers.count == 1 ? "what your Mac played" : "")
                        }
                        .buttonStyle(.plain)
                        .help("Click to rename")
                    }
                    if speakers.count > 1 {
                        Text("Click a name to rename").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
    }
}

struct Legend: View {
    let color: Color
    let name: String
    let detail: String

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(name).font(.caption.bold()).foregroundStyle(color)
            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
