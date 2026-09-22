import XCTest
@testable import RenamerCore

@MainActor
final class IntegrationCheckTests: XCTestCase {
    func testSuccessfulRunVerifiesEverySampleAndPreservesJSONSchema() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let result = try await fixture.runner(sampleCount: 2).run(reportURL: fixture.reportURL, bundlePath: "/Synthetic.app")
        XCTAssertTrue(result.success)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.samples.count, 2)
        XCTAssertTrue(result.samples.allSatisfy { $0.contentPreserved == true && $0.undoPreserved == true })
        XCTAssertEqual(fixture.analysisCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(fixture.sampleDirectory).path))

        let data = try Data(contentsOf: fixture.reportURL)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["bundle"] as? String, "/Synthetic.app")
        XCTAssertEqual(json["launch"] as? String, "NSApplication via LaunchServices")
        XCTAssertEqual(json["automaticNamingEnabled"] as? Bool, false)
        XCTAssertEqual(json["authentication"] as? String, "available")
        XCTAssertEqual(json["executable"] as? String, "/synthetic/codex")
        XCTAssertEqual(json["success"] as? Bool, true)
        XCTAssertNotNil(ISO8601DateFormatter().date(from: try XCTUnwrap(json["date"] as? String)))
        let samples = try XCTUnwrap(json["samples"] as? [[String: Any]])
        XCTAssertEqual(Set(samples[0].keys), ["sample", "title", "useful", "seconds", "renamed", "contentPreserved", "undoPreserved"])
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(samples[0]["seconds"] as? Double), 0)
        XCTAssertTrue(try JSONDecoder().decode(IntegrationReport.self, from: data).success)
    }

    func testRenameContentMismatchFailsAndRetainsFailedSample() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let result = try await fixture.runner(corruption: .rename, sampleCount: 2)
            .run(reportURL: fixture.reportURL, bundlePath: "/Synthetic.app")
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.samples.count, 1)
        XCTAssertEqual(result.samples[0].contentPreserved, false)
        XCTAssertNil(result.samples[0].undoPreserved)
        XCTAssertTrue(try XCTUnwrap(result.error).contains("Renaming changed"))
        XCTAssertEqual(fixture.analysisCount, 1)
        let saved = try JSONDecoder().decode(IntegrationReport.self, from: Data(contentsOf: fixture.reportURL))
        XCTAssertFalse(saved.success)
        XCTAssertEqual(saved.samples[0].contentPreserved, false)
    }

    func testUndoContentMismatchFailsAndRetainsBothChecks() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let result = try await fixture.runner(corruption: .undo).run(reportURL: fixture.reportURL, bundlePath: "/Synthetic.app")
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.samples[0].contentPreserved, true)
        XCTAssertEqual(result.samples[0].undoPreserved, false)
        XCTAssertTrue(try XCTUnwrap(result.error).contains("Undo changed"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(fixture.sampleDirectory).path))
    }

    func testNonUsefulSuggestionCannotPassWithoutRenameAndUndo() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let result = try await fixture.runner(useful: false).run(reportURL: fixture.reportURL, bundlePath: "/Synthetic.app")
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.samples[0].useful, false)
        XCTAssertNil(result.samples[0].renamed)
        XCTAssertNotNil(result.error)
    }

    func testUnavailableAnalyzerIsReportedWithoutSubmittingSamples() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let result = try await fixture.runner(availability: .unavailable(.authenticationRequired))
            .run(reportURL: fixture.reportURL, bundlePath: "/Synthetic.app")
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.authentication, CodexAnalysisError.authenticationRequired.localizedDescription)
        XCTAssertEqual(fixture.analysisCount, 0)
        XCTAssertNil(fixture.sampleDirectory)
        XCTAssertNotNil(result.error)
    }

    func testAnalysisFailureCannotOverwritePartialProgressWithSuccess() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let result = try await fixture.runner(sampleCount: 2, failAnalysisAt: 2)
            .run(reportURL: fixture.reportURL, bundlePath: "/Synthetic.app")
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.samples.count, 1)
        XCTAssertEqual(result.samples[0].undoPreserved, true)
        XCTAssertEqual(result.error, CodexAnalysisError.offline.localizedDescription)
    }

    func testEmptySampleSetDoesNotPass() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let result = try await fixture.runner(sampleCount: 0).run(reportURL: fixture.reportURL, bundlePath: "/Synthetic.app")
        XCTAssertFalse(result.success)
        XCTAssertNotNil(result.error)
        XCTAssertEqual(fixture.analysisCount, 0)
    }

    func testUnwritableReportThrowsBeforeSubmittingAnySamples() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let missingParent = fixture.directory.appendingPathComponent("missing/report.json")
        do {
            _ = try await fixture.runner().run(reportURL: missingParent, bundlePath: "/Synthetic.app")
            XCTFail("A report-write failure must be visible to the caller")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Could not write the integration report"))
        }
        XCTAssertEqual(fixture.analysisCount, 0)
        XCTAssertNil(fixture.sampleDirectory)
    }
}

@MainActor
private final class Fixture {
    let directory: URL
    var reportURL: URL { directory.appendingPathComponent("report.json") }
    var sampleDirectory: URL?
    var analysisCount = 0

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("IntegrationCheckTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }

    func runner(corruption: CorruptingRenamer.Corruption? = nil, useful: Bool = true, sampleCount: Int = 1,
                failAnalysisAt: Int? = nil,
                availability: CodexAvailability = .available(executable: URL(fileURLWithPath: "/synthetic/codex"))) -> IntegrationCheckRunner {
        IntegrationCheckRunner(availability: { availability }, analyze: { [self] _ in
            analysisCount += 1
            if analysisCount == failAnalysisAt { throw CodexAnalysisError.offline }
            return NamingSuggestion(title: "Synthetic Test", useful: useful)
        }, createSamples: { [self] directory in
            sampleDirectory = directory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return try (0..<sampleCount).map { index in
                let url = directory.appendingPathComponent("Screenshot \(index).png")
                try Data("Synthetic local fixture \(index)".utf8).write(to: url)
                return url
            }
        }, makeRenamer: { journal in
            try CorruptingRenamer(journal: journal, corruption: corruption)
        })
    }
}

private final class CorruptingRenamer: IntegrationRenaming {
    enum Corruption { case rename, undo }
    private let renamer: SafeFileRenamer
    private let corruption: Corruption?

    init(journal: URL, corruption: Corruption?) throws {
        renamer = try SafeFileRenamer(journalURL: journal)
        self.corruption = corruption
    }

    func rename(_ snapshot: FileSnapshot, title: String, captureDate: Date, captureDay: CaptureDay?) throws -> RenameJournalEntry {
        let entry = try renamer.rename(snapshot, title: title, captureDate: captureDate, captureDay: captureDay)
        if corruption == .rename { try Data("Simulated rename corruption".utf8).write(to: entry.newURL) }
        return entry
    }

    func undo(entryID: UUID) throws -> RenameJournalEntry {
        let entry = try renamer.undo(entryID: entryID)
        if corruption == .undo { try Data("Simulated undo corruption".utf8).write(to: entry.originalURL) }
        return entry
    }
}
