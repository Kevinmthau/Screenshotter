import AppKit
import Foundation
import RenamerCore

/// Exercises the production controller with generated images, an offline CLI,
/// isolated settings, and login-item registration disabled. No user Desktop,
/// saved account, or model endpoint is accessed; update scheduling stays disabled
/// and windows remain offscreen when exercising error recovery.
private struct VerificationFailure: Error, CustomStringConvertible {
    let description: String
}

private struct PersistedSettings: Decodable {
    let folderBookmark: Data?
    let folderPath: String?
    let enabled: Bool
    let paused: Bool
    let ledger: CaptureLedger?
}

@MainActor
private final class StartupVerification {
    private let root: URL
    private var controllers: [AppController] = []
    private var imageBytes = Data()
    private var checks = 0
    private let title = "Offline Startup Sample"

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenshotRenamer-Startup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func run() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            imageBytes = try Data(contentsOf: SampleScreenshots.create(in: root.appendingPathComponent("generated"))[0])
            try await freshStartupAndPause()
            try await legacyStartup(hasLedger: false)
            try await legacyStartup(hasLedger: true)
            try await unavailableCodexStartup()
            try await folderAccessRecovery()
            await cleanup()
            print("Startup verification passed: \(checks) checks; generated images, offline CLI, isolated settings, no login-item changes or update checks.")
        } catch {
            await cleanup()
            throw error
        }
    }

    private func freshStartupAndPause() async throws {
        let fixture = try directories("fresh")
        let log = fixture.support.appendingPathComponent("analysis-calls.txt")
        let executable = try fakeCodex(log: log)
        let baseline = try create("Screenshot 2026-10-02 at 9.00.00 AM.png", in: fixture.desktop)
        let ordinary = try create("Existing image.png", in: fixture.desktop)
        var controller: AppController? = try start(support: fixture.support, desktop: fixture.desktop, executable: executable)
        try await wait("automatic fresh startup") {
            let saved = try self.saved(in: fixture.support)
            let state = try self.state(of: controller!)
            return saved.enabled && saved.ledger != nil && state.status == "Watching"
        }
        let activated = try saved(in: fixture.support)
        let initialLedger = try require(activated.ledger, "fresh startup did not persist a baseline")
        try check(activated.folderPath == fixture.desktop.path && activated.folderBookmark != nil,
                  "fresh launch automatically saves the default screenshot folder and bookmark")
        try check(initialLedger.knownIdentities.count == 2 && initialLedger.pending.isEmpty,
                  "fresh launch baselines every existing file without an enable or preview action")
        try check(try hasWatcher(controller!), "fresh launch registers the production directory watcher")
        try check(try !window(of: controller!).isVisible, "successful launch runs with its settings window closed")
        let updater: AppUpdater? = try stored("updater", in: controller!)
        try check(updater == nil && (try state(of: controller!)).updates == UIUpdateState(),
                  "isolated startup never creates an updater or schedules update checks")
        try check(analysisCount(log) == 0 && (try Data(contentsOf: baseline)) == imageBytes &&
                  (try Data(contentsOf: ordinary)) == imageBytes,
                  "baseline screenshots and ordinary images remain unchanged and are never analyzed")
        let object = try settingsObject(in: fixture.support)
        try check(object["previewCompleted"] == nil && object["previewSamples"] == nil,
                  "automatic startup persists no preview prerequisites")

        let source = try create("Screenshot 2026-10-02 at 9.01.00 AM.png", in: fixture.desktop)
        let renamed = try renamedURL(for: source)
        try await wait("automatic screenshot naming", timeout: 15) {
            let state = try self.state(of: controller!)
            return FileManager.default.fileExists(atPath: renamed.path) && state.history.count == 1
        }
        try check(!FileManager.default.fileExists(atPath: source.path) && (try Data(contentsOf: renamed)) == imageBytes,
                  "a new eligible screenshot is automatically named and preserves its bytes")
        try check(analysisCount(log) == 1 && (try Data(contentsOf: baseline)) == imageBytes,
                  "only the new screenshot reaches the offline Codex fixture")

        try actions(of: controller!).togglePause()
        try check(try saved(in: fixture.support).paused, "Pause immediately persists the user's choice")
        let pausedSource = try create("Screenshot 2026-10-03 at 9.02.00 AM.png", in: fixture.desktop)
        let pausedRenamed = try renamedURL(for: pausedSource)
        try await wait("paused screenshot reconciliation") {
            try self.saved(in: fixture.support).ledger?.pending.contains(where: { $0.name == pausedSource.lastPathComponent }) == true
        }
        let pendingBeforeRestart = try require(try saved(in: fixture.support).ledger?.pending.first,
                                             "paused screenshot was not saved for later")
        await stop(controller!)
        // A real relaunch releases the process's journal lock. Drop the first
        // controller after shutdown before creating its replacement in this process.
        controller = nil

        // The saved bookmark must win over a different default on a later launch.
        let alternate = root.appendingPathComponent("unused-default", isDirectory: true)
        try FileManager.default.createDirectory(at: alternate, withIntermediateDirectories: true)
        let relaunched = try start(support: fixture.support, desktop: alternate, executable: executable)
        try await wait("paused relaunch") {
            let state = try self.state(of: relaunched)
            let restored = state.folder.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
            return state.status == "Paused" && !state.isBusy && restored == fixture.desktop.resolvingSymlinksInPath()
        }
        let afterRestart = try saved(in: fixture.support)
        try check(afterRestart.paused && afterRestart.enabled && afterRestart.ledger?.activatedAt == initialLedger.activatedAt,
                  "relaunch preserves Pause and the original activation baseline")
        try check(afterRestart.ledger?.pending.first?.id == pendingBeforeRestart.id,
                  "relaunch preserves the queued screenshot instead of baselining it away")
        try await Task.sleep(nanoseconds: 2_500_000_000)
        try check(analysisCount(log) == 1 && FileManager.default.fileExists(atPath: pausedSource.path) &&
                  !FileManager.default.fileExists(atPath: pausedRenamed.path),
                  "a paused relaunch submits and renames no screenshots")
        try actions(of: relaunched).togglePause()
        try await wait("resumed screenshot naming", timeout: 15) {
            let state = try self.state(of: relaunched)
            return FileManager.default.fileExists(atPath: pausedRenamed.path) && state.history.count == 2
        }
        try check(analysisCount(log) == 2 && (try Data(contentsOf: pausedRenamed)) == imageBytes &&
                  (try Data(contentsOf: baseline)) == imageBytes,
                  "Resume names the preserved pending screenshot and leaves the baseline intact")
        await stop(relaunched)
    }

    private func legacyStartup(hasLedger: Bool) async throws {
        let fixture = try directories(hasLedger ? "legacy-ledger" : "legacy-disabled")
        let log = fixture.support.appendingPathComponent("analysis-calls.txt")
        let executable = try fakeCodex(log: log)
        let baseline = try create("Screenshot 2026-10-01 at 9.00.00 AM.png", in: fixture.desktop)
        let observations = try await CaptureFileService().observations(in: fixture.desktop)
        let ledger = CaptureLedger(baseline: observations.files, activatedAt: Date().addingTimeInterval(-86400))
        var old: [String: Any] = [
            "folderBookmark": try fixture.desktop.bookmarkData(options: [.withSecurityScope]).base64EncodedString(),
            "folderPath": fixture.desktop.path, "executablePath": executable.path,
            "enabled": false, "paused": false, "previewCompleted": false, "previewSamples": [], "suggestions": []
        ]
        if hasLedger { old["ledger"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ledger)) }
        try JSONSerialization.data(withJSONObject: old).write(to: fixture.support.appendingPathComponent("settings.json"), options: .atomic)
        let controller = try start(support: fixture.support, desktop: fixture.desktop, executable: executable)
        try await wait("disabled legacy migration") {
            let saved = try self.saved(in: fixture.support)
            let state = try self.state(of: controller)
            return saved.enabled && saved.ledger != nil && state.status == "Watching"
        }
        let updated = try saved(in: fixture.support)
        try check(try hasWatcher(controller) && analysisCount(log) == 0 && (try Data(contentsOf: baseline)) == imageBytes,
                  "\(hasLedger ? "disabled legacy installation with a ledger" : "disabled legacy installation") automatically watches while preserving existing files")
        if hasLedger {
            try check(updated.ledger == ledger, "legacy activation ledger survives automatic startup unchanged")
        } else {
            try check(updated.ledger?.knownIdentities == Set(observations.files.map(\.identity)) && updated.ledger?.pending.isEmpty == true,
                      "legacy installation without activation automatically creates a safe baseline")
        }
        await stop(controller)
    }

    private func unavailableCodexStartup() async throws {
        let fixture = try directories("missing-codex")
        let baseline = try create("Screenshot 2026-10-01 at 8.00.00 AM.png", in: fixture.desktop)
        let missing = root.appendingPathComponent("codex-does-not-exist")
        let controller = try start(support: fixture.support, desktop: fixture.desktop, executable: missing)
        try await wait("baseline startup without Codex") {
            let saved = try self.saved(in: fixture.support)
            let state = try self.state(of: controller)
            return saved.enabled && saved.ledger != nil && !state.isBusy && state.status == "Needs attention"
        }
        try check(try hasWatcher(controller), "missing Codex does not block folder baseline or watcher registration")
        let source = try create("Screenshot 2026-10-02 at 8.01.00 AM.png", in: fixture.desktop)
        try await wait("capture reconciliation without Codex") {
            try self.saved(in: fixture.support).ledger?.pending.contains(where: { $0.name == source.lastPathComponent }) == true
        }
        try await Task.sleep(nanoseconds: 2_500_000_000)
        try check((try Data(contentsOf: source)) == imageBytes && (try Data(contentsOf: baseline)) == imageBytes &&
                  (try saved(in: fixture.support)).ledger?.pending.count == 1,
                  "missing Codex leaves the baseline and queued new screenshot safely unchanged")
        await stop(controller)
    }

    private func folderAccessRecovery() async throws {
        let support = root.appendingPathComponent("folder-recovery").appendingPathComponent("support", isDirectory: true)
        let desktop = root.appendingPathComponent("folder-recovery").appendingPathComponent("Missing Desktop", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let log = support.appendingPathComponent("analysis-calls.txt")
        let executable = try fakeCodex(log: log)
        let controller = try start(support: support, desktop: desktop, executable: executable)
        try await wait("unavailable screenshot folder") {
            let state = try self.state(of: controller)
            return state.status == "Needs attention" && !state.isBusy && !state.isEnabled
        }
        try check(try saved(in: support).ledger == nil && !hasWatcher(controller),
                  "unreadable startup folder cannot activate an empty or unsafe baseline")
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        let baseline = try create("Screenshot 2026-10-02 at 7.00.00 AM.png", in: desktop)
        try actions(of: controller).retry()
        try await wait("startup recovery after folder becomes accessible") {
            let state = try self.state(of: controller)
            return state.status == "Watching" && state.isEnabled && !state.isBusy
        }
        try check(try saved(in: support).ledger?.knownIdentities.count == 1 && hasWatcher(controller),
                  "Retry automatically baselines and watches a newly accessible startup folder")
        try check(analysisCount(log) == 0 && (try Data(contentsOf: baseline)) == imageBytes,
                  "startup access recovery preserves existing screenshots without a preview or enable action")
        await stop(controller)
    }

    private func directories(_ name: String) throws -> (support: URL, desktop: URL) {
        let support = root.appendingPathComponent(name).appendingPathComponent("support", isDirectory: true)
        let desktop = root.appendingPathComponent(name).appendingPathComponent("Test Desktop", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        return (support, desktop)
    }

    private func start(support: URL, desktop: URL, executable: URL) throws -> AppController {
        let controller = AppController(supportDirectory: support, defaultFolder: desktop,
                                       registerLoginItem: false, codexExecutable: executable, monitorNetwork: false)
        controllers.append(controller)
        let window = try window(of: controller)
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderOut(nil)
        return controller
    }

    private func stop(_ controller: AppController) async {
        await controller.stop()
        if let ui: AppUI = try? stored("ui", in: controller) {
            if let window: NSWindow = try? stored("window", in: ui) { window.orderOut(nil) }
            if let statusItem: NSStatusItem = try? stored("statusItem", in: ui) { NSStatusBar.system.removeStatusItem(statusItem) }
        }
        controllers.removeAll { $0 === controller }
    }

    private func cleanup() async {
        for controller in controllers { await stop(controller) }
    }

    private func create(_ name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try imageBytes.write(to: url)
        return url
    }

    private func renamedURL(for source: URL) throws -> URL {
        source.deletingLastPathComponent().appendingPathComponent(try FilenamePolicy.filename(
            title: title, captureDate: Date(), originalExtension: source.pathExtension,
            captureDay: ScreenshotRecognition.captureDay(name: source.lastPathComponent, fallback: Date())))
    }

    private func fakeCodex(log: URL) throws -> URL {
        let executable = log.deletingLastPathComponent().appendingPathComponent("fake-codex")
        let script = """
        #!/bin/sh
        if [ "$1" = login ]; then exit 0; fi
        if [ "$2" = --help ]; then
          printf '%s' '--image --output-schema --output-last-message --ephemeral --ignore-user-config --ignore-rules'
          exit 0
        fi
        response=''
        while [ "$#" -gt 0 ]; do
          if [ "$1" = --output-last-message ]; then shift; response="$1"; fi
          shift
        done
        if [ -z "$response" ]; then exit 2; fi
        printf 'analyze\\n' >> \(quote(log.path))
        printf '%s' '{"title":"\(title)","useful":true}' > "$response"
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    private func analysisCount(_ log: URL) -> Int {
        (try? String(contentsOf: log, encoding: .utf8).split(separator: "\n").count) ?? 0
    }

    private func saved(in support: URL) throws -> PersistedSettings {
        try JSONDecoder().decode(PersistedSettings.self, from: Data(contentsOf: support.appendingPathComponent("settings.json")))
    }

    private func settingsObject(in support: URL) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: support.appendingPathComponent("settings.json"))) as? [String: Any] else {
            throw VerificationFailure(description: "Settings are not a JSON object")
        }
        return object
    }

    private func state(of controller: AppController) throws -> UIState {
        let ui: AppUI = try stored("ui", in: controller)
        return try stored("state", in: ui)
    }

    private func actions(of controller: AppController) throws -> UIActions {
        let ui: AppUI = try stored("ui", in: controller)
        return try stored("actions", in: ui)
    }

    private func window(of controller: AppController) throws -> NSWindow {
        let ui: AppUI = try stored("ui", in: controller)
        return try stored("window", in: ui)
    }

    private func hasWatcher(_ controller: AppController) throws -> Bool {
        let watcher: DirectoryWatcher? = try stored("watcher", in: controller)
        return watcher != nil
    }

    private func stored<T>(_ name: String, in object: Any) throws -> T {
        guard let value = Mirror(reflecting: object).children.first(where: { $0.label == name })?.value as? T else {
            throw VerificationFailure(description: "Missing production field \(name)")
        }
        return value
    }

    private func require<T>(_ value: T?, _ description: String) throws -> T {
        guard let value else { throw VerificationFailure(description: description) }
        return value
    }

    private func wait(_ description: String, timeout: TimeInterval = 10, until predicate: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if (try? predicate()) == true { return }
            guard Date() < deadline else { throw VerificationFailure(description: "Timed out waiting for \(description)") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func check(_ value: Bool, _ description: String) throws {
        guard value else { throw VerificationFailure(description: description) }
        checks += 1
        print("PASS \(description)")
    }

    private func quote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

@main
private enum VerifyStartup {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                try await StartupVerification().run()
                exit(EXIT_SUCCESS)
            } catch {
                FileHandle.standardError.write(Data("Startup verification failed: \(error)\n".utf8))
                exit(EXIT_FAILURE)
            }
        }
        NSApp.run()
    }
}
