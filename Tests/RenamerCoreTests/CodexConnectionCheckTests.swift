import Foundation
import XCTest
@testable import RenamerCore

@MainActor
private final class SuspendedConnectionCheck {
    let started = XCTestExpectation(description: "connection check started")
    let cancelled = XCTestExpectation(description: "connection check cancelled")
    private var continuation: CheckedContinuation<CodexAvailability, Never>?
    private(set) var finishedCleanup = false
    private(set) var wasCancelled = false

    func run() async -> CodexAvailability {
        let cancelled = cancelled
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                started.fulfill()
            }
        } onCancel: {
            cancelled.fulfill()
        }
        // Simulate subprocess cleanup that must finish even after cancellation.
        wasCancelled = Task.isCancelled
        finishedCleanup = true
        return result
    }

    func finish(with result: CodexAvailability) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: result)
    }
}

final class CodexConnectionCheckTests: XCTestCase {
    @MainActor func testChangingExecutableDiscardsStaleSuccess() async {
        await verifyReplacement(
            stale: .available(executable: URL(fileURLWithPath: "/old/codex")),
            latest: .unavailable(.authenticationRequired)
        )
    }

    @MainActor func testChangingExecutableDiscardsStaleFailure() async {
        await verifyReplacement(
            stale: .unavailable(.unavailable),
            latest: .available(executable: URL(fileURLWithPath: "/new/codex"))
        )
    }

    @MainActor func testRapidReplacementWaitsForCleanupAndSkipsQueuedChecks() async {
        let connection = CodexConnectionCheck()
        let first = SuspendedConnectionCheck()
        let latest = SuspendedConnectionCheck()
        let received = expectation(description: "latest result received")
        var queuedCheckStarted = false
        var results: [CodexAvailability] = []
        connection.start(check: { await first.run() }, receive: { results.append($0) })
        await fulfillment(of: [first.started], timeout: 1)

        connection.start(check: {
            queuedCheckStarted = true
            return .unavailable(.offline)
        }, receive: { results.append($0) })
        connection.start(check: {
            XCTAssertTrue(first.finishedCleanup, "A replacement must wait for the old subprocess to finish cleanup")
            return await latest.run()
        }, receive: {
            XCTAssertFalse(connection.isChecking)
            results.append($0)
            received.fulfill()
        })
        await fulfillment(of: [first.cancelled], timeout: 1)
        XCTAssertTrue(connection.isChecking, "A queued replacement still counts as checking")
        first.finish(with: .unavailable(.unavailable))
        await fulfillment(of: [latest.started], timeout: 1)
        XCTAssertFalse(queuedCheckStarted, "A superseded queued check must never launch a subprocess")
        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(connection.isChecking)

        let result = CodexAvailability.available(executable: URL(fileURLWithPath: "/latest/codex"))
        latest.finish(with: result)
        await fulfillment(of: [received], timeout: 1)
        XCTAssertEqual(results, [result])
        XCTAssertFalse(connection.isChecking)
        await connection.stop()
    }

    @MainActor func testStopDrainsReplacementChainAndPermanentlyRejectsChecks() async {
        let connection = CodexConnectionCheck()
        let first = SuspendedConnectionCheck()
        let stopping = expectation(description: "shutdown started")
        let stopped = expectation(description: "shutdown finished")
        var replacementStarted = false
        var receivedResult = false
        var shutdownFinished = false
        connection.start(check: { await first.run() }, receive: { _ in receivedResult = true })
        await fulfillment(of: [first.started], timeout: 1)
        for _ in 0..<3 {
            connection.start(check: {
                replacementStarted = true
                return .unavailable(.offline)
            }, receive: { _ in receivedResult = true })
        }
        await fulfillment(of: [first.cancelled], timeout: 1)

        let shutdown = Task { @MainActor in
            stopping.fulfill()
            await connection.stop()
            XCTAssertTrue(first.finishedCleanup, "Quit must await the entire chain of replaced checks")
            shutdownFinished = true
            stopped.fulfill()
        }
        await fulfillment(of: [stopping], timeout: 1)
        XCTAssertFalse(shutdownFinished, "Quit must remain suspended while the old subprocess is cleaning up")
        connection.start(check: {
            replacementStarted = true
            return .unavailable(.offline)
        }, receive: { _ in receivedResult = true })

        first.finish(with: .available(executable: URL(fileURLWithPath: "/old/codex")))
        await fulfillment(of: [stopped], timeout: 1)
        if shutdownFinished { await shutdown.value }
        XCTAssertTrue(first.wasCancelled)
        XCTAssertFalse(replacementStarted)
        XCTAssertFalse(receivedResult)
        XCTAssertFalse(connection.isChecking)

        connection.start(check: {
            replacementStarted = true
            return .unavailable(.offline)
        }, receive: { _ in receivedResult = true })
        XCTAssertFalse(connection.isChecking, "A stopped connection checker cannot be restarted")
        await connection.stop()
        XCTAssertFalse(replacementStarted)
        XCTAssertFalse(receivedResult)
    }

    @MainActor private func verifyReplacement(stale: CodexAvailability, latest: CodexAvailability) async {
        let connection = CodexConnectionCheck()
        let oldCheck = SuspendedConnectionCheck()
        let newCheck = SuspendedConnectionCheck()
        let received = expectation(description: "current executable result received")
        var results: [CodexAvailability] = []
        XCTAssertFalse(connection.isChecking)
        connection.start(check: { await oldCheck.run() }, receive: { results.append($0) })
        XCTAssertTrue(connection.isChecking)
        await fulfillment(of: [oldCheck.started], timeout: 1)

        connection.start(check: {
            XCTAssertTrue(oldCheck.finishedCleanup)
            return await newCheck.run()
        }, receive: {
            XCTAssertFalse(connection.isChecking, "The receiver may immediately start another check")
            results.append($0)
            received.fulfill()
        })
        await fulfillment(of: [oldCheck.cancelled], timeout: 1)
        XCTAssertTrue(connection.isChecking)
        oldCheck.finish(with: stale)
        await fulfillment(of: [newCheck.started], timeout: 1)
        XCTAssertTrue(oldCheck.wasCancelled)
        XCTAssertTrue(results.isEmpty, "An operation that ignores cancellation must not deliver its obsolete result")
        XCTAssertTrue(connection.isChecking)

        newCheck.finish(with: latest)
        await fulfillment(of: [received], timeout: 1)
        XCTAssertEqual(results, [latest])
        XCTAssertFalse(connection.isChecking)
        await connection.stop()
    }
}
