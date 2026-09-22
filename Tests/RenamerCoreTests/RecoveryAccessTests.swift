import Darwin
import Foundation
import XCTest
@testable import RenamerCore

final class RecoveryAccessTests: XCTestCase {
    private var directory: URL!
    private var captures: URL { directory.appendingPathComponent("captures", isDirectory: true) }
    private var journalURL: URL { directory.appendingPathComponent("history/journal.json") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("RecoveryAccessTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testUnreadableRenamedImagePreservesIntentUntilAccessReturns() throws {
        let entry = try interruptedEntry(state: .renameIntent, moved: true)
        let journalBefore = try Data(contentsOf: journalURL)
        try withNoPermissions(at: entry.newURL) {
            assertRecoveryRequired()
            XCTAssertEqual(try Data(contentsOf: journalURL), journalBefore)
        }

        let recovered = try SafeFileRenamer(journalURL: journalURL)
        XCTAssertEqual(recovered.history.first?.state, .renamed)
        _ = try recovered.undo(entryID: entry.id)
        XCTAssertTrue(try entry.snapshot.matchesCurrentFile())
    }

    func testUnreadableOriginalPreservesCompletedUndoIntentUntilAccessReturns() throws {
        let entry = try interruptedEntry(state: .undoIntent, moved: false)
        let journalBefore = try Data(contentsOf: journalURL)
        try withNoPermissions(at: entry.originalURL) {
            assertRecoveryRequired()
            XCTAssertEqual(try Data(contentsOf: journalURL), journalBefore)
        }

        let recovered = try SafeFileRenamer(journalURL: journalURL)
        XCTAssertEqual(recovered.history.first?.state, .undone)
        XCTAssertTrue(try entry.snapshot.matchesCurrentFile())
    }

    func testInaccessibleParentPreservesIntentUntilAccessReturns() throws {
        let entry = try interruptedEntry(state: .renameIntent, moved: true)
        let journalBefore = try Data(contentsOf: journalURL)
        try withNoPermissions(at: captures) {
            assertRecoveryRequired()
            XCTAssertEqual(try Data(contentsOf: journalURL), journalBefore)
        }

        let recovered = try SafeFileRenamer(journalURL: journalURL)
        XCTAssertEqual(recovered.history.first?.state, .renamed)
        XCTAssertTrue(try entry.snapshot.matchesCurrentFile(at: entry.newURL))
    }

    func testMissingParentIsNotMistakenForDeletedScreenshot() throws {
        let entry = try interruptedEntry(state: .undoIntent, moved: true)
        let journalBefore = try Data(contentsOf: journalURL)
        let unavailable = directory.appendingPathComponent("unavailable-captures", isDirectory: true)
        try FileManager.default.moveItem(at: captures, to: unavailable)
        assertRecoveryRequired()
        XCTAssertEqual(try Data(contentsOf: journalURL), journalBefore)

        try FileManager.default.moveItem(at: unavailable, to: captures)
        let recovered = try SafeFileRenamer(journalURL: journalURL)
        XCTAssertEqual(recovered.history.first?.state, .renamed)
        _ = try recovered.undo(entryID: entry.id)
        XCTAssertTrue(try entry.snapshot.matchesCurrentFile())
    }

    func testDeletedScreenshotInAccessibleFolderAbandonsIntent() throws {
        let entry = try interruptedEntry(state: .renameIntent, moved: true)
        try FileManager.default.removeItem(at: entry.newURL)
        let recovered = try SafeFileRenamer(journalURL: journalURL)
        XCTAssertEqual(recovered.history.first?.state, .abandoned)
    }

    func testSymlinkReplacementAbandonsIntentWithoutFollowingIt() throws {
        let entry = try interruptedEntry(state: .renameIntent, moved: true)
        let unrelated = directory.appendingPathComponent("unrelated.png")
        try Data("untouched".utf8).write(to: unrelated)
        try FileManager.default.removeItem(at: entry.newURL)
        try FileManager.default.createSymbolicLink(at: entry.newURL, withDestinationURL: unrelated)
        let recovered = try SafeFileRenamer(journalURL: journalURL)
        XCTAssertEqual(recovered.history.first?.state, .abandoned)
        XCTAssertEqual(try String(contentsOf: unrelated), "untouched")
    }

    private func interruptedEntry(state: RenameJournalEntry.State, moved: Bool) throws -> RenameJournalEntry {
        let original = captures.appendingPathComponent("Screenshot.png")
        let renamed = captures.appendingPathComponent("Named Screenshot.png")
        try Data("original screenshot".utf8).write(to: original)
        let entry = RenameJournalEntry(originalURL: original, newURL: renamed,
            snapshot: try FileSnapshot.capture(at: original), state: state)
        if moved { try FileManager.default.moveItem(at: original, to: renamed) }
        struct Journal: Encodable { let version: Int; let entries: [RenameJournalEntry] }
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Journal(version: 1, entries: [entry])).write(to: journalURL)
        return entry
    }

    private func withNoPermissions(at url: URL, body: () throws -> Void) throws {
        guard geteuid() != 0 else { throw XCTSkip("Permission-denial tests require an unprivileged user.") }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
        try body()
    }

    private func assertRecoveryRequired(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try SafeFileRenamer(journalURL: journalURL), file: file, line: line) { error in
            guard case SafeFileError.recoveryRequired = error else {
                return XCTFail("Expected recoverable inspection failure, got \(error)", file: file, line: line)
            }
        }
    }
}
