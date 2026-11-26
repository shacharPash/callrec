// Update check and one-click update.
// Once a day (and after launch) CallRec reads the version that the install command would install, APP_VERSION in
// install.sh on GitHub, and compares it with its own. That request is all it sends, and "Check for updates" in the
// menu turns it off. "Update" runs that same install command: it closes CallRec (any recording is saved first),
// replaces the app, runs setup and opens it again.

import AppKit
import Foundation
import UserNotifications

let quitRequestFlag = stateDir.appendingPathComponent("quit-request")
/// Left by the installer when an update failed after it had closed CallRec.
let updateFailedFlag = stateDir.appendingPathComponent("update-failed")
/// The installer's exit code for "a call is being recorded, try again later".
let installerBusyCode: Int32 = 75

@MainActor
final class Updater: ObservableObject {
    static let installScript = URL(string: "https://raw.githubusercontent.com/shacharPash/callrec/main/install.sh")!
    static let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    static let checkEvery: TimeInterval = 24 * 3600

    @Published private(set) var available: String?
    @Published private(set) var updating = false
    @Published var enabled: Bool = UserDefaults.standard.object(forKey: "checkForUpdates") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "checkForUpdates")
            if enabled { check() } else { available = nil }
        }
    }

    private let defaults = UserDefaults.standard
    private let log = stateDir.appendingPathComponent("update.log")

    /// To try a release before it is published, point these at a local copy:
    /// `defaults write app.callrec.CallRec updateScript file:///…/install.sh` and
    /// `defaults write app.callrec.CallRec updateReleaseURL file:///…/build/release`.
    private var script: URL { defaults.string(forKey: "updateScript").flatMap(URL.init(string:)) ?? Self.installScript }

    init() {
        announceUpdate()
        if FileManager.default.fileExists(atPath: updateFailedFlag.path) {
            try? FileManager.default.removeItem(at: updateFailedFlag)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                Self.notify("CallRec was not updated",
                            "The update did not finish, so CallRec opened as it was. The details are in ~/.callrec/update.log.")
            }
        }
        if enabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.check() }
        }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        let last = defaults.double(forKey: "lastUpdateCheck")
        if enabled && Date().timeIntervalSince1970 - last >= Self.checkEvery { check() }
        notifyIfDue()
    }

    func check() {
        guard enabled else { return }
        // Until it answers, the next try is in an hour (offline, GitHub down), not in a day.
        defaults.set(Date().timeIntervalSince1970 - Self.checkEvery + 3600, forKey: "lastUpdateCheck")
        Task {
            guard let text = await fetchScript(), let version = Self.version(in: text) else { return }
            defaults.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
            available = Self.isNewer(version, than: Self.current) ? version : nil
            notifyIfDue()
        }
    }

    private func fetchScript() async -> String? {
        let request = URLRequest(url: script, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { return nil }
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix("#!/bin/bash") else { return nil }
        return text
    }

    static func version(in script: String) -> String? {
        guard let match = script.range(of: #"(?m)^APP_VERSION="[0-9]+(\.[0-9]+)*"$"#, options: .regularExpression)
        else { return nil }
        return String(script[match].dropFirst("APP_VERSION=\"".count).dropLast())
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// One notification per new version, only while CallRec is free (never during a call, even one you stopped).
    private func notifyIfDue() {
        guard let version = available, defaults.string(forKey: "notifiedVersion") != version, free else { return }
        defaults.set(version, forKey: "notifiedVersion")
        Self.notify("CallRec \(version) is available", "Choose Update in the CallRec menu. It takes about a minute.")
    }

    /// Updating restarts CallRec and runs its self-test (5 s of recording and a sound), so only when it waits for you:
    /// not during a call (recording, or stopped by hand while the call goes on), saving, starting or setting up.
    var free: Bool {
        switch currentEngine?.phase {
        case .ready, .needsSetup, .failed, nil: return true
        default: return false
        }
    }

    /// The first launch after an update says so, since macOS may ask for the two permissions again.
    private func announceUpdate() {
        let last = defaults.string(forKey: "lastRunVersion")
        defaults.set(Self.current, forKey: "lastRunVersion")
        guard let last, Self.isNewer(Self.current, than: last) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            Self.notify("CallRec updated to \(Self.current)",
                        "If macOS asks for Microphone and System Audio Recording, allow both.")
        }
    }

    static func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func confirmAndUpdate() {
        guard let version = available, !updating, free else { return }
        let alert = NSAlert()
        alert.messageText = "Update CallRec to \(version)?"
        alert.informativeText = "CallRec closes, updates and opens again by itself, in about a minute. "
            + "After that macOS may ask again for Microphone and System Audio Recording: allow both."
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        // A call can start while the dialog is open.
        guard alert.runModal() == .alertFirstButtonReturn, free else { return }
        updating = true
        Task { await run() }
    }

    private func run() async {
        guard let text = await fetchScript(), Self.version(in: text) != nil else {
            return fail("Could not download the update. Check your internet connection and try again.")
        }
        guard free else { updating = false; return }
        let dir = stateDir.appendingPathComponent("update")
        let file = dir.appendingPathComponent("install.sh")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            return fail("Could not save the update: \(error.localizedDescription)")
        }
        let p = Process()
        // nohup: the installer keeps going after it closes CallRec.
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        p.arguments = ["/bin/bash", file.path]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath
        if let releases = defaults.string(forKey: "updateReleaseURL") { env["CALLREC_RELEASE_URL"] = releases }
        p.environment = env
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let out = try? FileHandle(forWritingTo: log)
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out
        p.standardError = out
        // Reaching this means CallRec is still open: the installer stopped before it closed the app. A call that
        // started meanwhile stops it too; then no alert (it would show up on a shared screen), the item stays.
        p.terminationHandler = { proc in
            Task { @MainActor in
                self.updating = false
                let status = proc.terminationStatus
                if status != 0 && status != installerBusyCode {
                    self.fail("The update did not finish. The details are in ~/.callrec/update.log.")
                }
            }
        }
        do {
            try p.run()
        } catch {
            fail("Could not start the update: \(error.localizedDescription)")
        }
    }

    private func fail(_ message: String) {
        updating = false
        let alert = NSAlert()
        alert.messageText = "CallRec was not updated"
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
