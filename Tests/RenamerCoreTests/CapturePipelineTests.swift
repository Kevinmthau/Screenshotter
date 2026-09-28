import Darwin
import Foundation
import XCTest
@testable import RenamerCore

private actor ControlledScan {
    var directories: [URL] = []
    var continuations: [CheckedContinuation<CaptureObservationBatch, Error>] = []
    func scan(_ directory: URL) async throws -> CaptureObservationBatch {
        directories.append(directory)
        return try await withCheckedThrowingContinuation { continuations.append($0) }
    }
    var count: Int { directories.count }
    func complete(_ files: [CaptureObservation] = []) { continuations.removeFirst().resume(returning: CaptureObservationBatch(revision: UInt64(directories.count), files: files)) }
}

private actor TestAnalyzer: ScreenshotAnalyzing {
    var count = 0
    func analyze(_ url: URL) async throws -> NamingSuggestion {
        count += 1
        return NamingSuggestion(title: "Test Capture", useful: true)
    }
}

final class CapturePipelineTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CapturePipelineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    @MainActor private func waitForCount(_ count: Int, in scan: ControlledScan) async throws {
        let deadline = Date().addingTimeInterval(2)
        while await scan.count < count {
            guard Date() < deadline else { XCTFail("Scan did not start"); throw CocoaError(.coderInvalidValue) }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    @MainActor func testBurstEventsShareOneFollowUpScan() async throws {
        let scan = ControlledScan()
        var delivered = 0
        let scheduler = CaptureScanScheduler(scan: { try await scan.scan($0) }, receive: { _ in delivered += 1 })
        scheduler.request(directory)
        try await waitForCount(1, in: scan)
        for _ in 0..<100 { scheduler.request(directory) }
        await scan.complete()
        try await waitForCount(2, in: scan)
        await scan.complete()
        await scheduler.drain()
        let count = await scan.count
        XCTAssertEqual(count, 2)
        XCTAssertEqual(delivered, 2)
    }

    @MainActor func testInvalidatedFolderResultsCannotReachQueue() async throws {
        let scan = ControlledScan()
        var delivered = 0
        let scheduler = CaptureScanScheduler(scan: { try await scan.scan($0) }, receive: { _ in delivered += 1 })
        scheduler.request(directory)
        try await waitForCount(1, in: scan)
        scheduler.invalidate()
        scheduler.request(directory.appendingPathComponent("new-folder"))
        await scan.complete()
        try await waitForCount(2, in: scan)
        XCTAssertEqual(delivered, 0)
        await scan.complete()
        await scheduler.drain()
        XCTAssertEqual(delivered, 1)
        scheduler.request(directory)
        try await waitForCount(3, in: scan)
        scheduler.invalidate()
        await scan.complete()
        await scheduler.drain()
        XCTAssertEqual(delivered, 1, "Shutdown discards outstanding scan results")
    }

    @MainActor func testBlockedFileScanDoesNotBlockMainActor() async throws {
        let entered = expectation(description: "background scanner entered")
        let unblock = DispatchSemaphore(value: 0)
        let service = CaptureFileService(scan: { _ in
            XCTAssertFalse(Thread.isMainThread)
            entered.fulfill()
            guard unblock.wait(timeout: .now() + 2) == .success else { throw CocoaError(.fileReadUnknown) }
            return []
        })
        let task = Task { try await service.observations(in: directory) }
        await fulfillment(of: [entered], timeout: 1)
        unblock.signal() // Must execute on MainActor while the scanner is blocked.
        let observations = try await task.value
        XCTAssertTrue(observations.files.isEmpty)
    }

    func testCachedScannerStillSeesEditsRenamesAndReplacements() async throws {
        let service = CaptureFileService()
        let source = directory.appendingPathComponent("Screenshot 2026-09-21 at 1.00.00 PM.png")
        try Data([1]).write(to: source)
        let firstBatch = try await service.observations(in: directory)
        let first = try XCTUnwrap(firstBatch.files.first)
        try Data([1, 2, 3]).write(to: source)
        let changedBatch = try await service.observations(in: directory)
        let changed = try XCTUnwrap(changedBatch.files.first)
        XCTAssertNotEqual(changed.revision, first.revision)
        let moved = directory.appendingPathComponent("User Chosen Name.png")
        try FileManager.default.moveItem(at: source, to: moved)
        try Data([4]).write(to: source)
        let next = try await service.observations(in: directory).files
        XCTAssertEqual(next.count, 2)
        XCTAssertFalse(try XCTUnwrap(next.first { $0.name == moved.lastPathComponent }).eligible)
        XCTAssertNotEqual(try XCTUnwrap(next.first { $0.name == source.lastPathComponent }).identity, first.identity)
        try FileManager.default.removeItem(at: source)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: moved)
        let last = try await service.observations(in: directory).files
        XCTAssertEqual(last.map(\.name), [moved.lastPathComponent])
    }

    func testScannerReusesOnlyDefiniteSpotlightAnswersForUnchangedFiles() throws {
        let known = directory.appendingPathComponent("Screenshot 2026-09-21 at 1.00.00 PM.png")
        let unknown = directory.appendingPathComponent("Screenshot 2026-09-21 at 1.01.00 PM.png")
        try Data([1]).write(to: known)
        try Data([2]).write(to: unknown)
        try Data([3]).write(to: directory.appendingPathComponent("download.png"))
        var answers = [known.lastPathComponent: true]
        var lookups: [String] = []
        var scanner = CaptureDirectoryScanner { url in
            lookups.append(url.lastPathComponent)
            return answers[url.lastPathComponent]
        }
        func scan() throws -> [String: Bool] {
            lookups = []
            return Dictionary(uniqueKeysWithValues: try scanner.observations(in: directory).map { ($0.name, $0.eligible) })
        }
        XCTAssertEqual(try scan(), [known.lastPathComponent: true, unknown.lastPathComponent: true, "download.png": false])
        XCTAssertEqual(Set(lookups), [known.lastPathComponent, unknown.lastPathComponent])
        _ = try scan()
        XCTAssertEqual(lookups, [unknown.lastPathComponent], "Only the unknown answer is read again")
        answers[unknown.lastPathComponent] = false
        XCTAssertEqual(try scan()[unknown.lastPathComponent], false, "Late metadata rejection is still observed")
        XCTAssertEqual(lookups, [unknown.lastPathComponent])
        XCTAssertEqual(try scan()[unknown.lastPathComponent], false)
        XCTAssertEqual(lookups, [])
        // Screenshot metadata is an extended attribute; writing one changes ctime and the revision.
        answers[unknown.lastPathComponent] = true
        let flag = try PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
        XCTAssertEqual(flag.withUnsafeBytes {
            setxattr(unknown.path, "com.apple.metadata:kMDItemIsScreenCapture", $0.baseAddress, $0.count, 0, 0)
        }, 0)
        XCTAssertEqual(try scan()[unknown.lastPathComponent], true)
        XCTAssertEqual(lookups, [unknown.lastPathComponent])
        answers[known.lastPathComponent] = false
        try Data([1, 2]).write(to: known)
        XCTAssertEqual(try scan()[known.lastPathComponent], false, "An edit is read again")
        XCTAssertEqual(lookups, [known.lastPathComponent])
        answers[known.lastPathComponent] = true
        try Data([1, 2]).write(to: known, options: .atomic)
        XCTAssertEqual(try scan()[known.lastPathComponent], true, "A replacement is read again")
        XCTAssertEqual(lookups, [known.lastPathComponent])
    }

    func testPendingCapturesIgnoreCachedSpotlightAnswers() throws {
        let capture = directory.appendingPathComponent("Screenshot 2026-09-21 at 1.00.00 PM.png")
        try Data([1]).write(to: capture)
        // Just after an edit or replacement, Spotlight can still return the previous answer.
        var answer = true
        var lookups = 0
        var scanner = CaptureDirectoryScanner { _ in lookups += 1; return answer }
        XCTAssertEqual(try scanner.observations(in: directory).first?.eligible, true)
        answer = false
        XCTAssertEqual(try scanner.observations(in: directory).first?.eligible, true, "Files that are not pending reuse the answer")
        XCTAssertEqual(try scanner.observations(in: directory, freshMetadata: [capture.lastPathComponent]).first?.eligible, false,
                       "A pending capture still sees the late rejection")
        XCTAssertEqual(lookups, 2)
    }

    func testIdleRescansOfScreenshotsWithMetadataSkipSpotlight() throws {
        for index in 0..<200 {
            let name = String(format: "Screenshot 2026-09-21 at %d.%02d.00 PM.png", 1 + index / 60, index % 60)
            try Data([1]).write(to: directory.appendingPathComponent(name))
        }
        var lookups = 0
        var scanner = CaptureDirectoryScanner { _ in lookups += 1; return true }
        // Thirty seconds of two-second rescans previously repeated all 200 lookups each time.
        for _ in 0..<15 { XCTAssertEqual(try scanner.observations(in: directory).filter(\.eligible).count, 200) }
        XCTAssertEqual(lookups, 200)
    }

    func testTimerScansBackOffOnlyWhileWatchedWithNothingPending() {
        let start = Date(timeIntervalSince1970: 1_000)
        var policy = PeriodicScanPolicy()
        func timer(_ seconds: StrideTo<Double>, watching: Bool = true, pending: Bool = false) -> [Double] {
            seconds.filter { policy.shouldScan(periodic: true, watching: watching, pending: pending, now: start.addingTimeInterval($0)) }
        }
        XCTAssertEqual(timer(stride(from: 0, to: 600, by: 2)).count, 20, "Ten idle minutes scan every 30 seconds, not 300 times")
        XCTAssertEqual(timer(stride(from: 600, to: 620, by: 2), pending: true).count, 10)
        XCTAssertEqual(timer(stride(from: 620, to: 640, by: 2), watching: false).count, 10)
        XCTAssertTrue(policy.shouldScan(periodic: false, watching: true, pending: false, now: start.addingTimeInterval(641)),
                      "Filesystem events, wake, resume and retry always scan")
        XCTAssertEqual(timer(stride(from: 642, to: 700, by: 2)), [672], "and restart the idle interval")
        XCTAssertEqual(timer(stride(from: 100, to: 104, by: 2)), [100], "A clock set back cannot suspend the safety net")
    }

    @MainActor func testStaleQueueAndCancellationPreventAnalyzerSubmission() async throws {
        let source = directory.appendingPathComponent("Screenshot 2026-09-21 at 1.00.00 PM.png")
        try Data([1, 2, 3]).write(to: source)
        let snapshot = try FileSnapshot.capture(at: source)
        let job = PendingCapture(name: source.lastPathComponent, identity: "\(snapshot.identity.device):\(snapshot.identity.inode)",
                                 revision: "\(snapshot.size):\(snapshot.modificationSeconds):\(snapshot.modificationNanoseconds):0:0",
                                 captureDate: Date(), stableSince: .distantPast)
        let analyzer = TestAnalyzer()
        let pipeline = CaptureAnalysisPipeline(analyzer: analyzer, snapshot: { _ in snapshot })
        do { _ = try await pipeline.analyze(source, for: job, isCurrent: { false }); XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
        let blocked = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await pipeline.analyze(source, for: job, isCurrent: { true })
        }
        do { _ = try await blocked.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
        let count = await analyzer.count
        XCTAssertEqual(count, 0)
        _ = try await pipeline.analyze(source, for: job, isCurrent: { true })
        let completed = await analyzer.count
        XCTAssertEqual(completed, 1)
    }

    func testRevokedMutationPreservesOriginalAndRecoveryJournal() throws {
        let source = directory.appendingPathComponent("Screenshot.png")
        let bytes = Data([1, 2, 3])
        try bytes.write(to: source)
        let journal = directory.appendingPathComponent("history.json")
        let authorization = FileMutationAuthorization()
        authorization.cancel()
        do {
            let renamer = try SafeFileRenamer(journalURL: journal)
            XCTAssertThrowsError(try renamer.rename(FileSnapshot.capture(at: source), title: "Test Capture", captureDate: Date(), authorization: authorization)) {
                XCTAssertTrue($0 is CancellationError)
            }
            XCTAssertFalse(renamer.requiresRecovery)
            XCTAssertEqual(renamer.history.last?.state, .abandoned)
        }
        let reopened = try SafeFileRenamer(journalURL: journal)
        XCTAssertFalse(reopened.requiresRecovery)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    @MainActor func testPauseRevokesRenameQueuedBehindBackgroundWork() async throws {
        let entered = expectation(description: "file queue occupied")
        let release = DispatchSemaphore(value: 0)
        let service = CaptureFileService(scan: { _ in
            entered.fulfill()
            guard release.wait(timeout: .now() + 3) == .success else { throw CocoaError(.fileReadUnknown) }
            return []
        })
        _ = try await service.open(journalURL: directory.appendingPathComponent("history.json"))
        let source = directory.appendingPathComponent("Screenshot.png")
        try Data([1, 2, 3]).write(to: source)
        let snapshot = try FileSnapshot.capture(at: source)
        let job = PendingCapture(name: source.lastPathComponent, identity: "1", revision: "1",
                                 captureDate: Date(), stableSince: .distantPast)
        let scan = Task { try await service.observations(in: directory) }
        await fulfillment(of: [entered], timeout: 1)
        let authorization = FileMutationAuthorization()
        let rename = Task { try await service.rename(snapshot, title: "Test Capture", job: job, authorization: authorization) }
        await Task.yield()
        authorization.cancel()
        release.signal()
        _ = try await scan.value
        do { _ = try await rename.value; XCTFail("Paused rename should not commit") }
        catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
        XCTAssertEqual(try Data(contentsOf: source), Data([1, 2, 3]))
        let state = try await service.state()
        XCTAssertFalse(state.requiresRecovery)
        XCTAssertEqual(state.history.last?.state, .abandoned)
    }

    func testCancellationSerializesWithAlreadyAuthorizedMutation() async throws {
        let authorization = FileMutationAuthorization()
        let entered = expectation(description: "mutation acquired authorization")
        let cancelling = expectation(description: "cancellation attempted")
        let release = DispatchSemaphore(value: 0)
        let mutation = Task.detached {
            try authorization.perform {
                entered.fulfill()
                return release.wait(timeout: .now() + 3) == .success
            }
        }
        await fulfillment(of: [entered], timeout: 1)
        let cancelledEarly = expectation(description: "cancellation cannot overtake mutation")
        cancelledEarly.isInverted = true
        let cancellation = Task.detached {
            cancelling.fulfill()
            authorization.cancel()
            cancelledEarly.fulfill()
        }
        await fulfillment(of: [cancelling], timeout: 1)
        await fulfillment(of: [cancelledEarly], timeout: 0.05)
        release.signal()
        let committed = try await mutation.value
        await cancellation.value
        XCTAssertTrue(committed)
        XCTAssertThrowsError(try authorization.perform {}) { XCTAssertTrue($0 is CancellationError) }
    }

    func testStaleScanCannotLoseNewCaptureAndIneligibleScanRevokesRename() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        var policy = CaptureQueuePolicy(now: { now })
        var ledger = CaptureLedger(baseline: [], activatedAt: now.addingTimeInterval(-10))
        let file = CaptureObservation(name: "Screenshot 2026-09-21 at 1.00.00 PM.png", identity: "1", revision: "1",
                                      created: now, captureDate: now, eligible: true)
        _ = policy.reconcile(CaptureObservationBatch(revision: 2, files: [file]), ledger: &ledger, active: nil, authorization: nil)
        XCTAssertNil(policy.reconcile(CaptureObservationBatch(revision: 1, files: []), ledger: &ledger, active: nil, authorization: nil))
        let job = try XCTUnwrap(ledger.pending.first)
        let authorization = FileMutationAuthorization()
        let rejected = CaptureObservation(name: file.name, identity: file.identity, revision: file.revision,
                                          created: file.created, captureDate: file.captureDate, eligible: false)
        let result = policy.reconcile(CaptureObservationBatch(revision: 3, files: [rejected]), ledger: &ledger,
                                      active: job, authorization: authorization)
        XCTAssertEqual(result?.invalidatedActiveCapture, true)
        XCTAssertTrue(ledger.pending.isEmpty)
        XCTAssertThrowsError(try authorization.perform {}) { XCTAssertTrue($0 is CancellationError) }
    }

    func testQueueTransitionsUseInjectedClockAndBoundRetries() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let policy = CaptureQueuePolicy(now: { now })
        var ledger = CaptureLedger(baseline: [], activatedAt: now.addingTimeInterval(-10))
        ledger.reconcile([CaptureObservation(name: "Screenshot 2026-09-21 at 1.00.00 PM.png", identity: "1", revision: "1",
                                            created: now, captureDate: now, eligible: true)], now: now.addingTimeInterval(-3))
        var job = try XCTUnwrap(policy.claim(from: &ledger))
        XCTAssertEqual(job.state, .analyzing)
        XCTAssertNil(policy.claim(from: &ledger))
        XCTAssertEqual(policy.fail(&job, with: .offline), .retryScheduled)
        XCTAssertEqual(job.nextAttempt, now.addingTimeInterval(15))
        job.attempts = 2
        XCTAssertEqual(policy.fail(&job, with: .timedOut), .retryScheduled)
        XCTAssertEqual(job.nextAttempt, now.addingTimeInterval(60))
        job.attempts = CaptureQueuePolicy.maximumAttempts
        XCTAssertEqual(policy.fail(&job, with: .offline), .failed)
        XCTAssertEqual(job.state, .failed)
        ledger.update(job)
        policy.reset(job.id, in: &ledger)
        XCTAssertEqual(ledger.capture(job.id)?.stableSince, now)
        XCTAssertNil(policy.claim(from: &ledger), "Resume must respect save stability")
    }
}
