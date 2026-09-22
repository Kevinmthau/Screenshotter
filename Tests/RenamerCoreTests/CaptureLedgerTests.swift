import XCTest
@testable import RenamerCore

final class CaptureLedgerTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_000)
    func file(_ name: String = "Screenshot 2026-09-21 at 2.35.10 PM.png", id: String = "1", revision: String = "1", age: Double = 1, eligible: Bool = true) -> CaptureObservation {
        CaptureObservation(name: name, identity: id, revision: revision, created: start.addingTimeInterval(age), captureDate: start, eligible: eligible)
    }
    func testBaselineAndOldFilesAreNeverQueued() {
        var ledger = CaptureLedger(baseline: [file()], activatedAt: start)
        ledger.reconcile([file(), file("old", id: "2", age: -1)], now: start)
        XCTAssertTrue(ledger.pending.isEmpty)
    }
    func testRepeatedEventsStabilityAndOwnRename() throws {
        var ledger = CaptureLedger(baseline: [], activatedAt: start)
        ledger.reconcile([file()], now: start)
        ledger.reconcile([file()], now: start.addingTimeInterval(1))
        XCTAssertEqual(ledger.pending.count, 1)
        XCTAssertNil(ledger.nextReady(now: start.addingTimeInterval(1)))
        let job = try XCTUnwrap(ledger.nextReady(now: start.addingTimeInterval(3)))
        ledger.finish(job.id)
        ledger.reconcile([file("Title - 2026-09-21.png")], now: start.addingTimeInterval(4))
        XCTAssertTrue(ledger.pending.isEmpty)
    }
    func testManualRenameAndDeleteCancelJobs() {
        var ledger = CaptureLedger(baseline: [], activatedAt: start)
        ledger.reconcile([file()], now: start)
        ledger.reconcile([file("My custom title.png")], now: start)
        XCTAssertTrue(ledger.pending.isEmpty)
        ledger.reconcile([file()], now: start)
        XCTAssertTrue(ledger.pending.isEmpty)
        var other = CaptureLedger(baseline: [], activatedAt: start)
        other.reconcile([file()], now: start); other.reconcile([], now: start)
        XCTAssertTrue(other.pending.isEmpty)
    }
    func testEditorReplacementRestartsStabilityAndAttempts() throws {
        var ledger = CaptureLedger(baseline: [], activatedAt: start)
        ledger.reconcile([file()], now: start)
        var job = try XCTUnwrap(ledger.pending.first); job.state = .analyzing; ledger.update(job)
        ledger.reconcile([file(id: "2", revision: "changed")], now: start.addingTimeInterval(5))
        XCTAssertEqual(ledger.pending.first?.state, .waiting)
        XCTAssertEqual(ledger.pending.first?.identity, "2")
        XCTAssertNil(ledger.nextReady(now: start.addingTimeInterval(6)))
    }
    func testRestartKeepsBaselineAndPendingOnly() throws {
        var ledger = CaptureLedger(baseline: [file("baseline", id: "0")], activatedAt: start)
        ledger.reconcile([file()], now: start)
        var job = try XCTUnwrap(ledger.pending.first); job.state = .analyzing; ledger.update(job)
        var decoded = try JSONDecoder().decode(CaptureLedger.self, from: JSONEncoder().encode(ledger))
        decoded.recoverAfterRestart()
        XCTAssertEqual(decoded.pending.first?.state, .waiting)
        decoded.reconcile([file(), file("baseline", id: "0"), file("new", id: "3")], now: start)
        XCTAssertEqual(decoded.pending.count, 2)
    }
    func testBoundedQueueDefersOverflowWithoutLosingIt() {
        var ledger = CaptureLedger(baseline: [], activatedAt: start)
        let files = (0..<70).map { file("capture\($0)", id: "\($0)") }
        XCTAssertTrue(ledger.reconcile(files, now: start))
        XCTAssertEqual(ledger.pending.count, 64)
        for job in ledger.pending.prefix(6) { ledger.finish(job.id) }
        XCTAssertFalse(ledger.reconcile(files, now: start))
        XCTAssertEqual(ledger.pending.count, 64)
    }
    func testDefaultFilenameRecognitionAndCustomNames() {
        XCTAssertTrue(ScreenshotRecognition.isCandidate(name: "Screenshot 2026-09-21 at 2.35.10 PM.png"))
        XCTAssertTrue(ScreenshotRecognition.isCandidate(name: "Screenshot 2026-09-21 at 14.35.10.heic"))
        XCTAssertFalse(ScreenshotRecognition.isCandidate(name: "Private Notes.png", metadataIsScreenshot: true))
        XCTAssertFalse(ScreenshotRecognition.isCandidate(name: "Screenshot 2026-09-21 at 2.35.10 PM.mov"))
        XCTAssertFalse(ScreenshotRecognition.isCandidate(name: "download.png"))
    }

    func testLateMetadataRejectionCancelsAndDoesNotRequeue() {
        var ledger = CaptureLedger(baseline: [], activatedAt: start)
        ledger.reconcile([file()], now: start)
        ledger.reconcile([file(eligible: false)], now: start.addingTimeInterval(3))
        XCTAssertTrue(ledger.pending.isEmpty)
        ledger.reconcile([file()], now: start.addingTimeInterval(5))
        XCTAssertTrue(ledger.pending.isEmpty)
    }

    func testExpiredPendingFilenameIsRemovedButNotRediscovered() {
        var ledger = CaptureLedger(baseline: [], activatedAt: start)
        ledger.reconcile([file()], now: start)
        ledger.prunePending(before: start.addingTimeInterval(1))
        XCTAssertTrue(ledger.pending.isEmpty)
        ledger.reconcile([file()], now: start.addingTimeInterval(40 * 86400))
        XCTAssertTrue(ledger.pending.isEmpty)
    }
}
