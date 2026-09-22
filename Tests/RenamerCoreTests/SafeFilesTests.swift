import Foundation
import XCTest
@testable import RenamerCore

final class SafeFilesTests: XCTestCase {
    private var folder: URL!
    private var journalURL: URL { folder.appendingPathComponent("history/journal.json") }
    private let captureDate = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenshotRenamerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    @discardableResult
    private func file(_ name: String = "Screenshot 2026-09-21 at 2.35.10 PM.PNG", bytes: Data = Data([0, 1, 2, 3, 255, 17])) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    func testRenameAndUndoPreserveExactBytesAndExtension() throws {
        let source = try file()
        let originalBytes = try Data(contentsOf: source)
        let original = try FileSnapshot.capture(at: source)
        let renamer = try SafeFileRenamer(journalURL: journalURL)
        let entry = try renamer.rename(original, title: "Flourish - On-Device AI Notes", captureDate: captureDate)
        XCTAssertEqual(entry.state, .renamed)
        XCTAssertEqual(entry.newURL.pathExtension, "PNG")
        XCTAssertEqual(try Data(contentsOf: entry.newURL), originalBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(try original.matchesCurrentFile(at: entry.newURL))
        let undone = try renamer.undo(entryID: entry.id)
        XCTAssertEqual(undone.state, .undone)
        XCTAssertEqual(try Data(contentsOf: source), originalBytes)
        XCTAssertTrue(try original.matchesCurrentFile())
        XCTAssertFalse(FileManager.default.fileExists(atPath: entry.newURL.path))
    }

    func testCollisionsNeverOverwriteExistingFiles() throws {
        let source = try file()
        let first = try FilenamePolicy.filename(title: "Chart", captureDate: captureDate, originalExtension: "PNG")
        let second = try FilenamePolicy.filename(title: "Chart", captureDate: captureDate, originalExtension: "PNG", collisionIndex: 2)
        let existingOne = try file(first, bytes: Data("first owner".utf8))
        let existingTwo = try file(second, bytes: Data("second owner".utf8))
        let renamer = try SafeFileRenamer(journalURL: journalURL)
        let entry = try renamer.rename(FileSnapshot.capture(at: source), title: "Chart", captureDate: captureDate)
        XCTAssertTrue(entry.newURL.lastPathComponent.hasSuffix(" (3).PNG"))
        XCTAssertEqual(try String(contentsOf: existingOne), "first owner")
        XCTAssertEqual(try String(contentsOf: existingTwo), "second owner")
        XCTAssertEqual(renamer.history.count, 1)
    }

    func testContentChangesDuringAnalysisRefuseRename() throws {
        let source = try file()
        let snapshot = try FileSnapshot.capture(at: source)
        try Data("edited screenshot".utf8).write(to: source)
        let renamer = try SafeFileRenamer(journalURL: journalURL)
        XCTAssertThrowsError(try renamer.rename(snapshot, title: "Stale", captureDate: captureDate))
        XCTAssertEqual(try String(contentsOf: source), "edited screenshot")
        XCTAssertTrue(renamer.history.isEmpty)
    }

    func testSameSizeContentsWithRestoredModificationTimeStillRefuseRename() throws {
        let source = try file(bytes: Data("abcdef".utf8))
        let snapshot = try FileSnapshot.capture(at: source)
        try Data("fedcba".utf8).write(to: source)
        try FileManager.default.setAttributes([.modificationDate: snapshot.modificationDate], ofItemAtPath: source.path)
        let renamer = try SafeFileRenamer(journalURL: journalURL)
        XCTAssertThrowsError(try renamer.rename(snapshot, title: "Stale", captureDate: captureDate))
        XCTAssertEqual(try String(contentsOf: source), "fedcba")
    }

    func testReplacementFileWithSameBytesRefusesRename() throws {
        let source = try file()
        let bytes = try Data(contentsOf: source)
        let snapshot = try FileSnapshot.capture(at: source)
        let moved = folder.appendingPathComponent("manually moved.png")
        try FileManager.default.moveItem(at: source, to: moved)
        try bytes.write(to: source)
        let renamer = try SafeFileRenamer(journalURL: journalURL)
        XCTAssertThrowsError(try renamer.rename(snapshot, title: "Stale", captureDate: captureDate))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try Data(contentsOf: moved), bytes)
    }

    func testManualMoveAndDeletionRefuseRename() throws {
        let source = try file()
        let snapshot = try FileSnapshot.capture(at: source)
        let moved = folder.appendingPathComponent("chosen name.PNG")
        try FileManager.default.moveItem(at: source, to: moved)
        let renamer = try SafeFileRenamer(journalURL: journalURL)
        XCTAssertThrowsError(try renamer.rename(snapshot, title: "Changed", captureDate: captureDate))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
        try FileManager.default.removeItem(at: moved)
        XCTAssertThrowsError(try renamer.rename(snapshot, title: "Deleted", captureDate: captureDate))
    }

    func testSymlinksAndDirectoriesAreNotScreenshots() throws {
        let source = try file()
        let link = folder.appendingPathComponent("symlink.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertThrowsError(try FileSnapshot.capture(at: link))
        XCTAssertThrowsError(try FileSnapshot.capture(at: folder))
    }

    func testUndoNeverOverwritesRecreatedOriginal() throws {
        let source = try file()
        let renamer = try SafeFileRenamer(journalURL: journalURL)
        let entry = try renamer.rename(FileSnapshot.capture(at: source), title: "Project", captureDate: captureDate)
        let bytes = try Data(contentsOf: entry.newURL)
        try Data("different file".utf8).write(to: source)
        XCTAssertThrowsError(try renamer.undo(entryID: entry.id))
        XCTAssertEqual(try String(contentsOf: source), "different file")
        XCTAssertEqual(try Data(contentsOf: entry.newURL), bytes)
        XCTAssertEqual(renamer.history.first?.state, .renamed)
    }

    func testUndoRefusesChangedContentAndLaterManualRename() throws {
        let source = try file()
        let renamer = try SafeFileRenamer(journalURL: journalURL)
        let entry = try renamer.rename(FileSnapshot.capture(at: source), title: "Project", captureDate: captureDate)
        try Data("user edit".utf8).write(to: entry.newURL)
        XCTAssertThrowsError(try renamer.undo(entryID: entry.id))
        let moved = folder.appendingPathComponent("My chosen title.PNG")
        try FileManager.default.moveItem(at: entry.newURL, to: moved)
        XCTAssertThrowsError(try renamer.undo(entryID: entry.id))
        XCTAssertEqual(try String(contentsOf: moved), "user edit")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testJournalFailurePreventsRename() throws {
        let source = try file()
        let renamer = try SafeFileRenamer(journalURL: journalURL)
        try FileManager.default.removeItem(at: journalURL.deletingLastPathComponent())
        try Data("folder replaced by file".utf8).write(to: journalURL.deletingLastPathComponent())
        XCTAssertThrowsError(try renamer.rename(FileSnapshot.capture(at: source), title: "Project", captureDate: captureDate))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(renamer.history.isEmpty)
    }

    private func writeInterruptedEntry(_ entry: RenameJournalEntry) throws {
        struct Journal: Encodable { let version: Int; let entries: [RenameJournalEntry] }
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Journal(version: 1, entries: [entry])).write(to: journalURL)
    }

    func testRestartRecoversRenameAfterFileMovedBeforeCommit() throws {
        let source = try file()
        let snapshot = try FileSnapshot.capture(at: source)
        let destination = folder.appendingPathComponent("Finished - 2026-09-21.PNG")
        let entry = RenameJournalEntry(originalURL: source, newURL: destination, snapshot: snapshot, state: .renameIntent)
        try writeInterruptedEntry(entry)
        try FileManager.default.moveItem(at: source, to: destination)
        let renamer = try SafeFileRenamer(journalURL: journalURL)
        XCTAssertEqual(renamer.history.first?.state, .renamed)
        _ = try renamer.undo(entryID: entry.id)
        XCTAssertTrue(try snapshot.matchesCurrentFile())
    }

    func testRestartAbandonsIntentWhenRenameNeverHappened() throws {
        let source = try file()
        let snapshot = try FileSnapshot.capture(at: source)
        let destination = folder.appendingPathComponent("Finished.PNG")
        try writeInterruptedEntry(RenameJournalEntry(originalURL: source, newURL: destination, snapshot: snapshot, state: .renameIntent))
        let renamer = try SafeFileRenamer(journalURL: journalURL)
        XCTAssertEqual(renamer.history.first?.state, .abandoned)
        XCTAssertTrue(try snapshot.matchesCurrentFile())
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testRestartRecoversUndoAfterFileMovedBeforeCommit() throws {
        let source = try file()
        let snapshot = try FileSnapshot.capture(at: source)
        let destination = folder.appendingPathComponent("Finished.PNG")
        try writeInterruptedEntry(RenameJournalEntry(originalURL: source, newURL: destination, snapshot: snapshot, state: .undoIntent))
        let renamer = try SafeFileRenamer(journalURL: journalURL)
        XCTAssertEqual(renamer.history.first?.state, .undone)
        XCTAssertTrue(try snapshot.matchesCurrentFile())
    }

    func testRestartDoesNotMoveManuallyChangedFiles() throws {
        let source = try file()
        let snapshot = try FileSnapshot.capture(at: source)
        let destination = folder.appendingPathComponent("Finished.PNG")
        try writeInterruptedEntry(RenameJournalEntry(originalURL: source, newURL: destination, snapshot: snapshot, state: .renameIntent))
        try FileManager.default.moveItem(at: source, to: destination)
        try Data("edited".utf8).write(to: destination)
        let renamer = try SafeFileRenamer(journalURL: journalURL)
        XCTAssertEqual(renamer.history.first?.state, .abandoned)
        XCTAssertEqual(try String(contentsOf: destination), "edited")
    }

    func testCorruptAndSymlinkHistoryAreRejected() throws {
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not valid json".utf8).write(to: journalURL)
        XCTAssertThrowsError(try SafeFileRenamer(journalURL: journalURL))
        try FileManager.default.removeItem(at: journalURL)
        let unrelated = try file("unrelated.json", bytes: Data("untouched".utf8))
        try FileManager.default.createSymbolicLink(at: journalURL, withDestinationURL: unrelated)
        XCTAssertThrowsError(try SafeFileRenamer(journalURL: journalURL))
        XCTAssertEqual(try String(contentsOf: unrelated), "untouched")
        try FileManager.default.removeItem(at: unrelated)
        XCTAssertThrowsError(try SafeFileRenamer(journalURL: journalURL), "Dangling history symlinks must also be rejected.")
    }

    func testSecondInstanceCannotUseSameJournal() throws {
        let renamer = try SafeFileRenamer(journalURL: journalURL)
        XCTAssertThrowsError(try SafeFileRenamer(journalURL: journalURL))
        withExtendedLifetime(renamer) {}
    }

    func testHistoryPrunesAfterThirtyDaysAndClearDoesNotTouchFiles() throws {
        let source = try file()
        let renamer = try SafeFileRenamer(journalURL: journalURL)
        let entry = try renamer.rename(FileSnapshot.capture(at: source), title: "Project", captureDate: captureDate)
        try renamer.pruneHistory(now: entry.timestamp.addingTimeInterval(31 * 24 * 60 * 60))
        XCTAssertTrue(renamer.history.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry.newURL.path))
        let another = try file("Screenshot 2026-09-21 at 2.36.10 PM.png")
        let anotherEntry = try renamer.rename(FileSnapshot.capture(at: another), title: "Second", captureDate: captureDate)
        try renamer.clearHistory()
        XCTAssertTrue(renamer.history.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: anotherEntry.newURL.path))
        XCTAssertThrowsError(try renamer.undo(entryID: anotherEntry.id))
    }

    func testTitleValidationUsesUTF8BytesAndPreservesUnicode() throws {
        XCTAssertEqual(try FilenamePolicy.validatedTitle("  Café 東京  "), "Café 東京")
        XCTAssertEqual(try FilenamePolicy.validatedTitle("Cafe\u{301}"), "Café")
        for title in ["", "  ", ".", "..", ".hidden", "a/b", "a:b", "a\\b", "a\nb", "a\0b", String(repeating: "é", count: 90)] {
            XCTAssertThrowsError(try FilenamePolicy.validatedTitle(title), title)
        }
        XCTAssertEqual(try FilenamePolicy.validatedTitle(String(repeating: "a", count: 179)).utf8.count, 179)
        XCTAssertThrowsError(try FilenamePolicy.validatedTitle(String(repeating: "a", count: 180)))
    }
}
