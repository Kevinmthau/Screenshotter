import Foundation
import XCTest
@testable import RenamerCore

final class LedgerEdgeCaseTests: XCTestCase {
    private let activation = Date(timeIntervalSince1970: 1_000)
    private let originalName = "Screenshot 2026-09-21 at 2.35.10 PM.png"

    private func observation(_ name: String? = nil, identity: String = "original", revision: String = "1", eligible: Bool = true) -> CaptureObservation {
        CaptureObservation(name: name ?? originalName, identity: identity, revision: revision,
                           created: activation.addingTimeInterval(1), captureDate: activation, eligible: eligible)
    }

    func testManualMovePlusReplacementAtOriginalPathIsNeverResubmitted() throws {
        var ledger = CaptureLedger(baseline: [], activatedAt: activation)
        ledger.reconcile([observation()], now: activation)
        var pending = try XCTUnwrap(ledger.pending.first)
        pending.state = .analyzing
        ledger.update(pending)
        let moved = observation("My chosen filename.png", eligible: false)
        let replacement = observation(identity: "replacement")
        ledger.reconcile([moved, replacement], now: activation.addingTimeInterval(5))
        XCTAssertTrue(ledger.pending.isEmpty)
        // An identical path must stay suppressed on later scans and after restart.
        ledger.reconcile([replacement], now: activation.addingTimeInterval(10))
        var restored = try JSONDecoder().decode(CaptureLedger.self, from: JSONEncoder().encode(ledger))
        restored.recoverAfterRestart()
        restored.reconcile([replacement], now: activation.addingTimeInterval(20))
        XCTAssertTrue(restored.pending.isEmpty)
    }

    func testRestartDiscardsCaptureManuallyMovedWhileAppWasClosed() throws {
        var ledger = CaptureLedger(baseline: [], activatedAt: activation)
        ledger.reconcile([observation()], now: activation)
        var pending = try XCTUnwrap(ledger.pending.first)
        pending.state = .analyzing
        ledger.update(pending)
        var restored = try JSONDecoder().decode(CaptureLedger.self, from: JSONEncoder().encode(ledger))
        restored.recoverAfterRestart()
        restored.reconcile([observation("My chosen filename.png", eligible: false), observation(identity: "replacement")])
        XCTAssertTrue(restored.pending.isEmpty)
    }

    func testExplicitRetryDoesNotRequeueAnalyzingOrCompletedCaptures() throws {
        var ledger = CaptureLedger(baseline: [], activatedAt: activation)
        let first = observation()
        let second = observation("Screenshot 2026-09-21 at 2.36.10 PM.png", identity: "second")
        let third = observation("Screenshot 2026-09-21 at 2.37.10 PM.png", identity: "third")
        ledger.reconcile([first, second, third], now: activation)
        var analyzing = try XCTUnwrap(ledger.pending.first(where: { $0.identity == "original" }))
        analyzing.state = .analyzing; analyzing.attempts = 1; ledger.update(analyzing)
        var failed = try XCTUnwrap(ledger.pending.first(where: { $0.identity == "second" }))
        failed.state = .failed; failed.attempts = 3; failed.nextAttempt = .distantFuture; ledger.update(failed)
        let completed = try XCTUnwrap(ledger.pending.first(where: { $0.identity == "third" }))
        ledger.finish(completed.id)
        ledger.retryFailures()
        XCTAssertEqual(ledger.capture(analyzing.id)?.state, .analyzing)
        XCTAssertEqual(ledger.capture(failed.id)?.state, .waiting)
        XCTAssertEqual(ledger.capture(failed.id)?.attempts, 0)
        XCTAssertNil(ledger.capture(completed.id))
        XCTAssertEqual(ledger.nextReady(now: activation.addingTimeInterval(10))?.id, failed.id)
    }

    func testDeferredRetryDoesNotBlockAnotherStableCapture() throws {
        var ledger = CaptureLedger(baseline: [], activatedAt: activation)
        ledger.reconcile([observation()], now: activation)
        var pending = try XCTUnwrap(ledger.pending.first)
        pending.state = .retry; pending.nextAttempt = activation.addingTimeInterval(60)
        ledger.update(pending)
        ledger.reconcile([observation(), observation("Screenshot 2026-09-21 at 2.36.10 PM.png", identity: "second")], now: activation)
        XCTAssertEqual(ledger.nextReady(now: activation.addingTimeInterval(3))?.identity, "second")
    }

    func testChangedCaptureResetsFailedStateAndWaitsForStability() throws {
        var ledger = CaptureLedger(baseline: [], activatedAt: activation)
        ledger.reconcile([observation()], now: activation)
        var pending = try XCTUnwrap(ledger.pending.first)
        pending.state = .failed; pending.attempts = 3; ledger.update(pending)
        ledger.reconcile([observation(revision: "edited")], now: activation.addingTimeInterval(10))
        XCTAssertEqual(ledger.pending.first?.id, pending.id)
        XCTAssertEqual(ledger.pending.first?.attempts, 0)
        XCTAssertNil(ledger.nextReady(now: activation.addingTimeInterval(11)))
        XCTAssertEqual(ledger.nextReady(now: activation.addingTimeInterval(13))?.state, .waiting)
    }
}
