import Foundation
import XCTest
@testable import RenamerCore

final class ReplacementEligibilityTests: XCTestCase {
    private let activation = Date(timeIntervalSince1970: 1_000)
    private let pendingName = "Screenshot 2026-09-21 at 2.35.10 PM.png"
    private let otherName = "Screenshot 2026-09-21 at 2.36.10 PM.png"

    private func observation(_ name: String? = nil, identity: String = "pending", revision: String = "1",
                             createdOffset: TimeInterval = 1, eligible: Bool = true) -> CaptureObservation {
        CaptureObservation(name: name ?? pendingName, identity: identity, revision: revision,
                           created: activation.addingTimeInterval(createdOffset), captureDate: activation,
                           eligible: eligible)
    }

    func testBaselineIdentityCannotReplacePendingCapture() {
        let baseline = observation(otherName, identity: "baseline")
        var ledger = CaptureLedger(baseline: [baseline], activatedAt: activation)
        ledger.reconcile([baseline, observation()], now: activation)

        ledger.reconcile([observation(identity: "baseline", revision: "moved")], now: activation.addingTimeInterval(3))

        XCTAssertTrue(ledger.pending.isEmpty)
        XCTAssertNil(ledger.nextReady(now: activation.addingTimeInterval(6)))
    }

    func testCompletedIdentityCannotReplacePendingCapture() throws {
        var ledger = CaptureLedger(baseline: [], activatedAt: activation)
        let completed = observation(otherName, identity: "completed")
        ledger.reconcile([completed], now: activation)
        ledger.finish(try XCTUnwrap(ledger.pending.first).id)
        ledger.reconcile([completed, observation()], now: activation.addingTimeInterval(3))

        ledger.reconcile([observation(identity: "completed", revision: "moved")], now: activation.addingTimeInterval(6))

        XCTAssertTrue(ledger.pending.isEmpty)
    }

    func testPreviouslyUnseenPreactivationFileCannotReplacePendingCapture() {
        var ledger = CaptureLedger(baseline: [], activatedAt: activation)
        ledger.reconcile([observation()], now: activation)

        ledger.reconcile([observation(identity: "older", createdOffset: -1)], now: activation.addingTimeInterval(3))

        XCTAssertTrue(ledger.pending.isEmpty)
        XCTAssertTrue(ledger.knownIdentities.contains("older"))
    }

    func testFreshEditorReplacementWaitsForStability() throws {
        var ledger = CaptureLedger(baseline: [], activatedAt: activation)
        ledger.reconcile([observation()], now: activation)
        let originalJob = try XCTUnwrap(ledger.pending.first)

        ledger.reconcile([observation(identity: "editor-save", revision: "2", createdOffset: 3)],
                         now: activation.addingTimeInterval(3))

        XCTAssertEqual(ledger.pending.first?.id, originalJob.id)
        XCTAssertEqual(ledger.pending.first?.identity, "editor-save")
        XCTAssertNil(ledger.nextReady(now: activation.addingTimeInterval(4)))
        XCTAssertEqual(ledger.nextReady(now: activation.addingTimeInterval(6))?.identity, "editor-save")
    }

    func testSameIdentityEditRemainsEligible() throws {
        var ledger = CaptureLedger(baseline: [], activatedAt: activation)
        ledger.reconcile([observation()], now: activation)
        var job = try XCTUnwrap(ledger.pending.first)
        job.state = .failed
        job.attempts = 3
        ledger.update(job)

        ledger.reconcile([observation(revision: "edited")], now: activation.addingTimeInterval(3))

        XCTAssertEqual(ledger.pending.first?.id, job.id)
        XCTAssertEqual(ledger.pending.first?.state, .waiting)
        XCTAssertEqual(ledger.pending.first?.attempts, 0)
        XCTAssertNil(ledger.nextReady(now: activation.addingTimeInterval(4)))
        XCTAssertEqual(ledger.nextReady(now: activation.addingTimeInterval(6))?.revision, "edited")
    }

    func testCanceledReplacementCannotBeRediscoveredAfterRenameAndRestart() throws {
        var ledger = CaptureLedger(baseline: [], activatedAt: activation)
        ledger.reconcile([observation()], now: activation)
        ledger.reconcile([observation("My chosen name.png", eligible: false), observation(identity: "replacement")],
                         now: activation.addingTimeInterval(3))
        XCTAssertTrue(ledger.pending.isEmpty)

        var restored = try JSONDecoder().decode(CaptureLedger.self, from: JSONEncoder().encode(ledger))
        restored.recoverAfterRestart()
        restored.reconcile([observation(otherName, identity: "replacement")], now: activation.addingTimeInterval(6))

        XCTAssertTrue(restored.pending.isEmpty)
    }

    func testReplacementAtCompletedNameCannotBeRediscoveredAfterRename() throws {
        var ledger = CaptureLedger(baseline: [], activatedAt: activation)
        ledger.reconcile([observation()], now: activation)
        ledger.finish(try XCTUnwrap(ledger.pending.first).id)
        ledger.reconcile([observation(identity: "replacement")], now: activation.addingTimeInterval(3))

        ledger.reconcile([observation(otherName, identity: "replacement")], now: activation.addingTimeInterval(6))

        XCTAssertTrue(ledger.pending.isEmpty)
    }
}
