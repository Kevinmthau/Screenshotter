import Darwin
import Foundation
import XCTest
@testable import RenamerCore

final class CaptureDayTests: XCTestCase {
    private let screenshotName = "Screenshot 2026-09-21 at 2.35.10 PM.PNG"
    private let created = ISO8601DateFormatter().date(from: "2026-09-21T04:30:00Z")!

    func testPersistedQueuePreservesOriginalDayAfterTimezoneChange() throws {
        let data = try withTimeZone("America/New_York") {
            var ledger = queuedCapture()
            var job = try XCTUnwrap(ledger.pending.first)
            XCTAssertEqual(job.captureDay?.value, "2026-09-21")
            job.state = .retry
            ledger.update(job)
            return try JSONEncoder().encode(ledger)
        }

        try withTimeZone("America/Los_Angeles") {
            var ledger = try JSONDecoder().decode(CaptureLedger.self, from: data)
            ledger.recoverAfterRestart()
            ledger.reconcile([observation()], now: created.addingTimeInterval(10))
            let job = try XCTUnwrap(ledger.pending.first)
            XCTAssertEqual(job.state, .retry)
            XCTAssertEqual(job.namingDay.value, "2026-09-21")
            XCTAssertEqual(try FilenamePolicy.filename(title: "Travel Notes", captureDate: job.captureDate,
                                                       originalExtension: "PNG", captureDay: job.namingDay),
                           "Travel Notes - 2026-09-21.PNG")
            // Date-only callers retain their existing local-time formatting behavior.
            XCTAssertEqual(try FilenamePolicy.filename(title: "Travel Notes", captureDate: job.captureDate,
                                                       originalExtension: "PNG"),
                           "Travel Notes - 2026-09-20.PNG")
        }
    }

    func testLegacyQueueRecoversOriginalDayFromFilename() throws {
        let legacyData = try withTimeZone("America/New_York") {
            let data = try JSONEncoder().encode(queuedCapture())
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            var pending = try XCTUnwrap(json["pending"] as? [[String: Any]])
            pending[0].removeValue(forKey: "captureDay")
            json["pending"] = pending
            return try JSONSerialization.data(withJSONObject: json)
        }

        try withTimeZone("America/Los_Angeles") {
            var ledger = try JSONDecoder().decode(CaptureLedger.self, from: legacyData)
            let legacyJob = try XCTUnwrap(ledger.pending.first)
            XCTAssertNil(legacyJob.captureDay)
            XCTAssertEqual(legacyJob.namingDay.value, "2026-09-21")
            ledger.recoverAfterRestart()
            ledger.reconcile([observation()], now: created.addingTimeInterval(10))
            let migrated = try JSONDecoder().decode(CaptureLedger.self, from: JSONEncoder().encode(ledger))
            let job = try XCTUnwrap(migrated.pending.first)
            XCTAssertEqual(job.captureDay?.value, "2026-09-21")
            XCTAssertEqual(try FilenamePolicy.filename(title: "Legacy Capture", captureDate: job.captureDate,
                                                       originalExtension: "PNG", captureDay: job.namingDay),
                           "Legacy Capture - 2026-09-21.PNG")
        }
    }

    func testInvalidFilenameDateFreezesFallbackDayWhenQueued() throws {
        let invalidName = "Screenshot 2026-02-30 at 2.35.10 PM.png"
        let data = try withTimeZone("America/New_York") {
            let ledger = queuedCapture(named: invalidName)
            let job = try XCTUnwrap(ledger.pending.first)
            XCTAssertEqual(job.captureDate, created)
            XCTAssertEqual(job.captureDay?.value, "2026-09-21")
            return try JSONEncoder().encode(ledger)
        }

        try withTimeZone("America/Los_Angeles") {
            var ledger = try JSONDecoder().decode(CaptureLedger.self, from: data)
            ledger.recoverAfterRestart()
            ledger.reconcile([observation(named: invalidName)], now: created.addingTimeInterval(10))
            let job = try XCTUnwrap(ledger.pending.first)
            XCTAssertEqual(CaptureDay(job.captureDate).value, "2026-09-20")
            XCTAssertEqual(job.namingDay.value, "2026-09-21")
        }
    }

    func testCaptureDayValidatesCalendarDatesAndEncodedValues() throws {
        let leapDay = try XCTUnwrap(CaptureDay(iso8601: "2024-02-29"))
        XCTAssertEqual(try JSONDecoder().decode(CaptureDay.self, from: JSONEncoder().encode(leapDay)), leapDay)
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: JSONEncoder().encode(leapDay)), "2024-02-29")
        for invalid in ["2026-02-29", "2026-02-30", "2026-13-01", "2026-9-21", "2026-09-21/../other"] {
            XCTAssertNil(CaptureDay(iso8601: invalid), invalid)
            let data = try JSONEncoder().encode(invalid)
            XCTAssertThrowsError(try JSONDecoder().decode(CaptureDay.self, from: data), invalid)
        }
    }

    func testCaptureDayDateConstructorUsesSpecifiedTimeZone() throws {
        let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let losAngeles = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        XCTAssertEqual(CaptureDay(created, timeZone: newYork).value, "2026-09-21")
        XCTAssertEqual(CaptureDay(created, timeZone: losAngeles).value, "2026-09-20")
    }

    func testRenamePreservesCaptureDayWhenChoosingCollisionSuffix() throws {
        let job = try withTimeZone("America/New_York") {
            try XCTUnwrap(queuedCapture().pending.first)
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenshotRenamer-CaptureDay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent(screenshotName)
        let screenshotBytes = Data("Synthetic capture contents".utf8)
        try screenshotBytes.write(to: source)
        let first = folder.appendingPathComponent("Travel Notes - 2026-09-21.PNG")
        let second = folder.appendingPathComponent("Travel Notes - 2026-09-21 (2).PNG")
        try Data("First existing file".utf8).write(to: first)
        try Data("Second existing file".utf8).write(to: second)

        try withTimeZone("America/Los_Angeles") {
            let renamer = try SafeFileRenamer(journalURL: folder.appendingPathComponent("history/journal.json"))
            let entry = try renamer.rename(FileSnapshot.capture(at: source), title: "Travel Notes",
                                           captureDate: job.captureDate, captureDay: job.namingDay)
            XCTAssertEqual(entry.newURL.lastPathComponent, "Travel Notes - 2026-09-21 (3).PNG")
            XCTAssertEqual(try Data(contentsOf: entry.newURL), screenshotBytes)
            XCTAssertEqual(try String(contentsOf: first), "First existing file")
            XCTAssertEqual(try String(contentsOf: second), "Second existing file")
        }
    }

    private func observation(named customName: String? = nil) -> CaptureObservation {
        let filename = customName ?? screenshotName
        return CaptureObservation(name: filename, identity: "1:123", revision: "unchanged", created: created,
                                  captureDate: ScreenshotRecognition.captureDate(name: filename, fallback: created),
                                  eligible: ScreenshotRecognition.isCandidate(name: filename))
    }

    private func queuedCapture(named customName: String? = nil) -> CaptureLedger {
        var ledger = CaptureLedger(baseline: [], activatedAt: created.addingTimeInterval(-1))
        ledger.reconcile([observation(named: customName)], now: created)
        return ledger
    }

    /// XCTest runs these synchronous cases serially; restore both Foundation timezone caches afterward.
    private func withTimeZone<T>(_ identifier: String, _ body: () throws -> T) rethrows -> T {
        let originalEnvironment = getenv("TZ").map { String(cString: $0) }
        let originalDefault = NSTimeZone.default
        setenv("TZ", identifier, 1)
        NSTimeZone.resetSystemTimeZone()
        NSTimeZone.default = TimeZone(identifier: identifier)!
        defer {
            if let originalEnvironment { setenv("TZ", originalEnvironment, 1) }
            else { unsetenv("TZ") }
            NSTimeZone.resetSystemTimeZone()
            NSTimeZone.default = originalDefault
        }
        return try body()
    }
}
