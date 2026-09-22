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
        do {
            _ = try await IntegrationCheckRunner().run(reportURL: report, bundlePath: Bundle.main.bundlePath)
        } catch {
            fputs("Screenshot Renamer integration check: \(error.localizedDescription)\n", stderr)
        }
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let delegate = ApplicationDelegate()
    application.delegate = delegate
    application.run()
}
