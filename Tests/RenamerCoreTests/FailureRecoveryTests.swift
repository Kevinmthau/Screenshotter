import XCTest
@testable import RenamerCore

final class FailureRecoveryTests: XCTestCase {
    private func job(at now: Date) -> PendingCapture {
        PendingCapture(name: "Screenshot 2026-09-21 at 1.00.00 PM.png", identity: "1", revision: "1",
                       captureDate: now, stableSince: now)
    }

    func testTransientFailuresBackOffBeforeRequiringRetry() {
        let now = Date(timeIntervalSince1970: 1_000)
        let policy = CaptureQueuePolicy(now: { now })
        var capture = job(at: now)
        for (attempt, delay) in zip(1..., [15.0, 60, 300, 900, 1800]) {
            capture.attempts = attempt
            XCTAssertEqual(policy.fail(&capture, with: .transientFailure), .retryScheduled)
            XCTAssertEqual(capture.state, .retry)
            XCTAssertEqual(capture.nextAttempt, now.addingTimeInterval(delay))
        }
        capture.attempts = 6
        XCTAssertEqual(policy.fail(&capture, with: .timedOut), .failed)
        XCTAssertEqual(capture.state, .failed)
    }

    func testAccountFailuresWaitForConnectionWithinAttemptLimit() {
        let now = Date(timeIntervalSince1970: 1_000)
        let policy = CaptureQueuePolicy(now: { now })
        for error in [CodexAnalysisError.authenticationRequired, .quotaExceeded, .unavailable] {
            var capture = job(at: now)
            capture.attempts = 1
            XCTAssertEqual(policy.fail(&capture, with: error), .awaitingConnection)
            XCTAssertEqual(capture.state, .retry)
            XCTAssertEqual(capture.nextAttempt, Date.distantPast, "Resumes as soon as a connection check succeeds")
            capture.attempts = 6
            XCTAssertEqual(policy.fail(&capture, with: error), .failed, "A misclassified failure cannot loop forever")
        }
    }

    func testCaptureAwaitingConnectionResumesAndStillCountsAttempts() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let policy = CaptureQueuePolicy(now: { now })
        var ledger = CaptureLedger(baseline: [], activatedAt: now.addingTimeInterval(-10))
        ledger.reconcile([CaptureObservation(name: "Screenshot 2026-09-21 at 1.00.00 PM.png", identity: "1", revision: "1",
                                             created: now, captureDate: now, eligible: true)], now: now.addingTimeInterval(-3))
        var capture = try XCTUnwrap(policy.claim(from: &ledger))
        XCTAssertEqual(policy.fail(&capture, with: .authenticationRequired), .awaitingConnection)
        ledger.update(capture)
        XCTAssertEqual(ledger.nextReady(now: now)?.id, capture.id)
        XCTAssertEqual(policy.claim(from: &ledger)?.attempts, 2)
    }

    func testCaptureWaitingForConnectionDoesNotHoldTheQueue() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let policy = CaptureQueuePolicy(now: { now })
        var ledger = CaptureLedger(baseline: [], activatedAt: now.addingTimeInterval(-10))
        ledger.reconcile([
            CaptureObservation(name: "Screenshot 2026-09-21 at 1.00.00 PM.png", identity: "1", revision: "1",
                               created: now.addingTimeInterval(-2), captureDate: now, eligible: true),
            CaptureObservation(name: "Screenshot 2026-09-21 at 1.01.00 PM.png", identity: "2", revision: "1",
                               created: now.addingTimeInterval(-1), captureDate: now, eligible: true)
        ], now: now.addingTimeInterval(-3))
        var capture = try XCTUnwrap(policy.claim(from: &ledger))
        XCTAssertEqual(capture.identity, "1")
        XCTAssertEqual(policy.fail(&capture, with: .quotaExceeded), .awaitingConnection)
        ledger.update(capture)
        ledger.moveToBack(capture.id)
        XCTAssertEqual(ledger.nextReady(now: now)?.identity, "2")
        XCTAssertEqual(ledger.pending.last?.id, capture.id)
    }

    func testUnreadableImagesAndInvalidAnswersKeepOriginalAfterThirdAttempt() {
        let now = Date(timeIntervalSince1970: 1_000)
        let policy = CaptureQueuePolicy(now: { now })
        for error in [CodexAnalysisError.invalidImage, .invalidResponse] {
            var capture = job(at: now)
            capture.attempts = 1
            XCTAssertEqual(policy.fail(&capture, with: error), .retryScheduled)
            XCTAssertEqual(capture.nextAttempt, now.addingTimeInterval(15))
            capture.attempts = 2
            XCTAssertEqual(policy.fail(&capture, with: error), .retryScheduled)
            XCTAssertEqual(capture.nextAttempt, now.addingTimeInterval(60))
            capture.attempts = 3
            XCTAssertEqual(policy.fail(&capture, with: error), .keepOriginal)
        }
    }

    func testConnectionChecksBackOffByCause() {
        XCTAssertEqual(CaptureQueuePolicy.connectionCheckDelay(after: .timedOut, consecutiveFailures: 0), 15)
        XCTAssertEqual(CaptureQueuePolicy.connectionCheckDelay(after: .timedOut, consecutiveFailures: 1), 15)
        XCTAssertEqual(CaptureQueuePolicy.connectionCheckDelay(after: .transientFailure, consecutiveFailures: 50), 300)
        XCTAssertEqual(CaptureQueuePolicy.connectionCheckDelay(after: .authenticationRequired, consecutiveFailures: 1), 60)
        XCTAssertEqual(CaptureQueuePolicy.connectionCheckDelay(after: .unavailable, consecutiveFailures: 5), 900)
        XCTAssertEqual(CaptureQueuePolicy.connectionCheckDelay(after: .quotaExceeded, consecutiveFailures: 1), 1800)
        XCTAssertEqual(CaptureQueuePolicy.connectionCheckDelay(after: .quotaExceeded, consecutiveFailures: 3), 3600)
    }
}
