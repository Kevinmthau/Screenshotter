import CoreServices
import Darwin
import Foundation

/// Compiled together with the production DirectoryWatcher, CaptureLedger, and
/// SafeFiles sources by test-watcher.sh. Uses only an isolated temporary folder.
private struct VerificationFailure: Error, CustomStringConvertible {
    let description: String
}

private final class WatcherVerification {
    private let root: URL
    private let desktop: URL
    private let bytes = Data("Synthetic filesystem test data; not an image or personal content.".utf8)
    private var ledger = CaptureLedger(baseline: [])
    private var watcher: DirectoryWatcher?
    private var eventBatches = 0
    private var callbackFailure: Error?
    private var checks = 0

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenshotRenamer-Watcher-\(UUID().uuidString)", isDirectory: true)
        desktop = root.appendingPathComponent("Test Desktop", isDirectory: true)
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
    }

    func run() throws {
        defer {
            watcher?.stop()
            try? FileManager.default.removeItem(at: root)
        }
        let baseline = try create("Screenshot 2026-09-21 at 1.00.00 PM.png")
        ledger = CaptureLedger(baseline: try scan(), activatedAt: Date())
        watcher = try DirectoryWatcher(url: desktop) { [weak self] in
            guard let self else { return }
            do {
                guard Thread.isMainThread else { throw VerificationFailure(description: "FSEvents callback was not on the main thread") }
                self.eventBatches += 1
                self.ledger.reconcile(try self.scan())
            } catch { self.callbackFailure = error }
        }

        var previousEvents = eventBatches
        let first = try create("Screenshot 2026-09-21 at 1.01.00 PM.png")
        try wait("new capture filesystem event") { self.eventBatches > previousEvents && self.ledger.pending.count == 1 }
        guard let initialJob = ledger.pending.first else { throw VerificationFailure(description: "Missing capture after creation event") }
        try check(initialJob.name == first.lastPathComponent, "real FSEvents creation callback queued the new screenshot")
        try check(ledger.nextReady() == nil, "new capture waits for the production two-second stability interval")
        try wait("capture stabilization") { self.ledger.nextReady()?.id == initialJob.id }
        try check(ledger.nextReady()?.id == initialJob.id, "stable capture became ready without an extra filesystem event")

        for index in 1...3 {
            previousEvents = eventBatches
            _ = try create("ordinary-download-\(index).png")
            try wait("repeated unrelated filesystem event \(index)") { self.eventBatches > previousEvents }
            guard ledger.pending.count == 1, ledger.pending.first?.id == initialJob.id else {
                throw VerificationFailure(description: "Repeated events queued an extra capture or changed its job")
            }
        }
        try check(true, "three additional real event batches did not duplicate the job or queue ordinary downloads")

        previousEvents = eventBatches
        let chosen = desktop.appendingPathComponent("My manually chosen name.png")
        try FileManager.default.moveItem(at: first, to: chosen)
        try wait("manual rename filesystem event") { self.eventBatches > previousEvents && self.ledger.pending.isEmpty }
        try check(try Data(contentsOf: chosen) == bytes, "manual rename canceled pending analysis and preserved the user's file")

        previousEvents = eventBatches
        let deleted = try create("Screenshot 2026-09-21 at 1.02.00 PM.png")
        try wait("second capture filesystem event") { self.eventBatches > previousEvents && self.ledger.pending.count == 1 }
        previousEvents = eventBatches
        try FileManager.default.removeItem(at: deleted)
        try wait("deletion filesystem event") { self.eventBatches > previousEvents && self.ledger.pending.isEmpty }
        try check(true, "deletion canceled the pending capture")

        previousEvents = eventBatches
        let automated = try create("Screenshot 2026-09-21 at 1.03.00 PM.PNG")
        try wait("third capture filesystem event") { self.eventBatches > previousEvents && self.ledger.pending.count == 1 }
        try wait("third capture stabilization") { self.ledger.nextReady() != nil }
        guard let job = ledger.nextReady() else { throw VerificationFailure(description: "Third capture never became ready") }
        let renamer = try SafeFileRenamer(journalURL: root.appendingPathComponent("state/history.json"))
        let snapshot = try FileSnapshot.capture(at: automated)
        previousEvents = eventBatches
        let entry = try renamer.rename(snapshot, title: "Watcher Integration Sample", captureDate: job.captureDate, captureDay: job.namingDay)
        ledger.finish(job.id)
        try wait("application rename filesystem event") { self.eventBatches > previousEvents }
        try check(ledger.pending.isEmpty && (try Data(contentsOf: entry.newURL)) == bytes,
                  "the app's own real rename event did not requeue the image and preserved its bytes")
        try check(try Data(contentsOf: baseline) == bytes && !ledger.pending.contains(where: { $0.name == baseline.lastPathComponent }),
                  "the pre-activation baseline file remained unchanged and unqueued")

        print("PASS: \(checks) checks; \(eventBatches) real FSEvents callback batches; all files isolated and cleaned up.")
    }

    @discardableResult
    private func create(_ name: String) throws -> URL {
        let url = desktop.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    private func scan() throws -> [CaptureObservation] {
        try FileManager.default.contentsOfDirectory(at: desktop, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).compactMap { url in
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
            let created = Date(timeIntervalSince1970: Double(info.st_birthtimespec.tv_sec) + Double(info.st_birthtimespec.tv_nsec) / 1_000_000_000)
            return CaptureObservation(
                name: url.lastPathComponent,
                identity: "\(info.st_dev):\(info.st_ino)",
                revision: "\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)",
                created: created,
                captureDate: ScreenshotRecognition.captureDate(name: url.lastPathComponent, fallback: created),
                eligible: ScreenshotRecognition.isCandidate(name: url.lastPathComponent)
            )
        }
    }

    private func wait(_ description: String, timeout: TimeInterval = 10, until predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if let callbackFailure { throw callbackFailure }
            guard Date() < deadline else { throw VerificationFailure(description: "Timed out waiting for \(description); \(eventBatches) event batches observed") }
            // FSEvents uses DispatchQueue.main. Run the actual main run loop so
            // callbacks arrive while this synchronous harness waits for them.
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if let callbackFailure { throw callbackFailure }
    }

    private func check(_ value: Bool, _ description: String) throws {
        guard value else { throw VerificationFailure(description: description) }
        checks += 1
        print("PASS: \(description)")
    }
}

@main
private struct Main {
    static func main() {
        do { try WatcherVerification().run() }
        catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
