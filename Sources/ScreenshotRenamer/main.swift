import AppKit
import RenamerCore

@MainActor final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    var controller: AppController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index = CommandLine.arguments.firstIndex(of: "--integration-check"), CommandLine.arguments.count > index + 1 {
            let report = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task { await integrationCheck(report: report); NSApplication.shared.terminate(nil) }
            return
        }
        let sameApp = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.kevinthau.screenshot-renamer")
            .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let sameApp { sameApp.activate(options: []); NSApplication.shared.terminate(nil); return }
        controller = AppController()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.showWindow(); return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller else { return .terminateNow }
        Task { await controller.stop(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    private func integrationCheck(report: URL) async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenshotRenamer-Integration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var result: [String: Any] = ["date": ISO8601DateFormatter().string(from: Date()), "bundle": Bundle.main.bundlePath,
                                     "launch": "NSApplication via LaunchServices", "automaticNamingEnabled": false]
        let analyzer = CodexAnalyzer()
        switch await analyzer.checkAvailability() {
        case .available(let executable): result["authentication"] = "available"; result["executable"] = executable.path
        case .unavailable(let error): result["authentication"] = error.localizedDescription
        }
        do {
            let files = try SampleScreenshots.create(in: directory)
            let renamer = try SafeFileRenamer(journalURL: directory.appendingPathComponent("journal.json"))
            var previews: [[String: Any]] = []
            for file in files {
                let snapshot = try FileSnapshot.capture(at: file)
                let started = Date()
                let suggestion = try await analyzer.analyze(file)
                let elapsed = Date().timeIntervalSince(started)
                var preview: [String: Any] = ["sample": file.lastPathComponent, "title": suggestion.title, "useful": suggestion.useful, "seconds": elapsed]
                if suggestion.useful {
                    let entry = try renamer.rename(snapshot, title: suggestion.title, captureDate: Date())
                    preview["renamed"] = entry.newURL.lastPathComponent
                    preview["contentPreserved"] = try FileSnapshot.capture(at: entry.newURL).fingerprint == snapshot.fingerprint
                    _ = try renamer.undo(entryID: entry.id)
                    preview["undoPreserved"] = try FileSnapshot.capture(at: file).fingerprint == snapshot.fingerprint
                }
                previews.append(preview)
                result["samples"] = previews
                try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: report, options: .atomic)
            }
            result["success"] = true
        } catch { result["success"] = false; result["error"] = error.localizedDescription }
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: report, options: .atomic)
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let delegate = ApplicationDelegate()
    application.delegate = delegate
    application.run()
}
