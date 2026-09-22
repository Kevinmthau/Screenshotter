import Foundation
import XCTest
@testable import RenamerCore

final class FilenameHashCompatibilityTests: XCTestCase {
    private let activation = Date(timeIntervalSinceReferenceDate: 0)
    private let screenshotName = "Screenshot 2026-09-21 at 2.35.10 PM.png"

    func testKnownFilenameHashesKeepTheirPersistedRepresentation() throws {
        // Fixed SHA-256 vectors cover leading zeros, empty input, Unicode, and
        // distinct UTF-8 spellings of canonically equivalent filenames.
        let fixtures = [
            ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            (screenshotName, "73a37baaca308f885f706fd9f2a33978b8ed20b337c28d8746402990fb015001"),
            ("Café 東京.png", "ec250a0696bf82d2fb3cbf25c9bea66616176a4545400a10801e0d388113a4f4"),
            ("Cafe\u{301} 東京.png", "3649c72a89de727643eb77fcb2d78e008c213f743d339ae0a8e13f1c7cc522bb")
        ]
        let observations = fixtures.enumerated().map { index, fixture in
            observation(fixture.0, identity: "baseline-\(index)")
        }
        let ledger = CaptureLedger(baseline: observations, activatedAt: activation)
        let expectedHashes = Set(fixtures.map { $0.1 })

        XCTAssertEqual(ledger.knownNames, expectedHashes)
        let encoded = try JSONEncoder().encode(ledger)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(try XCTUnwrap(json["knownNames"] as? [String])), expectedHashes)
        XCTAssertEqual(try JSONDecoder().decode(CaptureLedger.self, from: encoded), ledger)
    }

    func testLegacyPersistedNameStillSuppressesReplacedAndRenamedCapture() throws {
        // A literal legacy ledger makes compatibility independent of the current
        // encoder and hash implementation.
        let data = Data("""
        {
          "activatedAt": 0,
          "knownIdentities": ["original-identity"],
          "knownNames": ["73a37baaca308f885f706fd9f2a33978b8ed20b337c28d8746402990fb015001"],
          "pending": []
        }
        """.utf8)
        var ledger = try JSONDecoder().decode(CaptureLedger.self, from: data)
        ledger.recoverAfterRestart()

        ledger.reconcile([observation(screenshotName, identity: "replacement")], now: activation.addingTimeInterval(2))

        XCTAssertTrue(ledger.pending.isEmpty, "A fresh inode at an excluded name must remain excluded.")
        XCTAssertTrue(ledger.knownIdentities.contains("replacement"))
        XCTAssertEqual(ledger.knownNames, ["73a37baaca308f885f706fd9f2a33978b8ed20b337c28d8746402990fb015001"])
        var restored = try JSONDecoder().decode(CaptureLedger.self, from: JSONEncoder().encode(ledger))
        restored.recoverAfterRestart()
        restored.reconcile([observation("Screenshot 2026-09-21 at 2.36.10 PM.png", identity: "replacement")],
                           now: activation.addingTimeInterval(3))
        XCTAssertTrue(restored.pending.isEmpty, "Renaming the excluded replacement must not make it eligible after restart.")
    }

    private func observation(_ name: String, identity: String) -> CaptureObservation {
        CaptureObservation(name: name, identity: identity, revision: "1", created: activation.addingTimeInterval(1),
                           captureDate: activation, eligible: true)
    }
}
