import Darwin
import Foundation
import XCTest
@testable import RenamerCore

final class SafeFileTransactionTests: XCTestCase {
    private var folder: URL!
    private var journalURL: URL { folder.appendingPathComponent("history/journal.json") }
    private let captureDate = Date(timeIntervalSince1970: 1_790_000_000)
    private let captureDay = CaptureDay(iso8601: "2026-09-21")!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SafeFileTransactionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    func testOccupiedDestinationsNeedOnlyOneRenameTransaction() throws {
        let snapshot = try sourceSnapshot()
        let existingBytes = Data("existing owner".utf8)
        for index in 1...100 {
            let url = try destination(index)
            if index == 50 {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            } else if index == 75 {
                try FileManager.default.createSymbolicLink(at: url, withDestinationURL: folder.appendingPathComponent("missing.png"))
            } else {
                try existingBytes.write(to: url)
            }
        }
        var fileSyncs = 0
        var directorySyncs = 0
        let synchronization = JournalSynchronization(file: { fd in
            fileSyncs += 1
            return Darwin.fsync(fd)
        }, directory: { fd in
            directorySyncs += 1
            return Darwin.fsync(fd)
        })
        let renamer = try SafeFileRenamer(journalURL: journalURL, journalSynchronization: synchronization)

        let entry = try rename(snapshot, using: renamer)

        XCTAssertEqual(entry.newURL, try destination(101))
        XCTAssertEqual(fileSyncs, 2, "Only the rename intent and completed rename should be written.")
        XCTAssertEqual(directorySyncs, 2)
        XCTAssertEqual(renamer.history.count, 1)
        XCTAssertTrue(try snapshot.matchesCurrentFile(at: entry.newURL))
        for index in 1...100 where index != 50 && index != 75 {
            XCTAssertEqual(try Data(contentsOf: destination(index)), existingBytes)
        }
        var info = stat()
        XCTAssertEqual(lstat(try destination(50).path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFDIR)
        XCTAssertEqual(lstat(try destination(75).path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFLNK)
    }

    func testDestinationCreatedAfterPreflightStillUsesExclusiveRename() throws {
        let snapshot = try sourceSnapshot()
        let occupied = try destination(1)
        let existingBytes = Data("created during intent persistence".utf8)
        var fileSyncs = 0
        let synchronization = JournalSynchronization(file: { fd in
            fileSyncs += 1
            if fileSyncs == 1 {
                do { try existingBytes.write(to: occupied) }
                catch { XCTFail("Could not create racing destination: \(error)") }
            }
            return Darwin.fsync(fd)
        })
        let renamer = try SafeFileRenamer(journalURL: journalURL, journalSynchronization: synchronization)

        let entry = try rename(snapshot, using: renamer)

        XCTAssertEqual(entry.newURL, try destination(2))
        XCTAssertEqual(try Data(contentsOf: occupied), existingBytes)
        XCTAssertEqual(fileSyncs, 4, "The raced intent is removed before the next candidate is attempted.")
        XCTAssertEqual(renamer.history.count, 1)
        XCTAssertEqual(try journalEntries(), renamer.history)
        XCTAssertTrue(try snapshot.matchesCurrentFile(at: entry.newURL))
    }

    func testJournalFileSyncFailureAfterRenamePreservesRecoverableIntent() throws {
        let snapshot = try sourceSnapshot()
        var fileSyncs = 0
        let synchronization = JournalSynchronization(file: { fd in
            fileSyncs += 1
            if fileSyncs == 2 { errno = EIO; return -1 }
            return Darwin.fsync(fd)
        })
        var renamer: SafeFileRenamer? = try SafeFileRenamer(journalURL: journalURL, journalSynchronization: synchronization)

        assertJournalFailure { _ = try rename(snapshot, using: renamer!) }

        XCTAssertTrue(renamer!.requiresRecovery)
        XCTAssertEqual(renamer!.history.first?.state, .renameIntent)
        XCTAssertEqual(try journalEntries().first?.state, .renameIntent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.url.path))
        XCTAssertTrue(try snapshot.matchesCurrentFile(at: destination(1)))
        XCTAssertThrowsError(try renamer!.clearHistory())
        renamer = nil

        let recovered = try SafeFileRenamer(journalURL: journalURL)
        let entry = try XCTUnwrap(recovered.history.first)
        XCTAssertEqual(entry.state, .renamed)
        _ = try recovered.undo(entryID: entry.id)
        XCTAssertTrue(try snapshot.matchesCurrentFile())
    }

    func testJournalDirectorySyncFailureAfterRenameStopsUntilRecovery() throws {
        let snapshot = try sourceSnapshot()
        var directorySyncs = 0
        let synchronization = JournalSynchronization(directory: { fd in
            directorySyncs += 1
            if directorySyncs == 2 { errno = EIO; return -1 }
            return Darwin.fsync(fd)
        })
        var renamer: SafeFileRenamer? = try SafeFileRenamer(journalURL: journalURL, journalSynchronization: synchronization)

        assertJournalFailure { _ = try rename(snapshot, using: renamer!) }

        XCTAssertTrue(renamer!.requiresRecovery)
        XCTAssertEqual(renamer!.history.first?.state, .renameIntent)
        XCTAssertEqual(try journalEntries().first?.state, .renamed)
        XCTAssertTrue(try snapshot.matchesCurrentFile(at: destination(1)))
        XCTAssertThrowsError(try renamer!.clearHistory())
        renamer = nil

        let recovered = try SafeFileRenamer(journalURL: journalURL)
        let entry = try XCTUnwrap(recovered.history.first)
        XCTAssertEqual(entry.state, .renamed)
        _ = try recovered.undo(entryID: entry.id)
        XCTAssertTrue(try snapshot.matchesCurrentFile())
    }

    func testIntentDirectorySyncFailurePreventsRenameAndRecoversAsAbandoned() throws {
        let snapshot = try sourceSnapshot()
        let synchronization = JournalSynchronization(directory: { _ in errno = EIO; return -1 })
        var renamer: SafeFileRenamer? = try SafeFileRenamer(journalURL: journalURL, journalSynchronization: synchronization)

        assertJournalFailure { _ = try rename(snapshot, using: renamer!) }

        XCTAssertTrue(renamer!.requiresRecovery)
        XCTAssertTrue(renamer!.history.isEmpty)
        XCTAssertEqual(try journalEntries().first?.state, .renameIntent)
        XCTAssertTrue(try snapshot.matchesCurrentFile())
        XCTAssertFalse(FileManager.default.fileExists(atPath: try destination(1).path))
        renamer = nil

        let recovered = try SafeFileRenamer(journalURL: journalURL)
        XCTAssertEqual(recovered.history.first?.state, .abandoned)
        XCTAssertTrue(try snapshot.matchesCurrentFile())
    }

    func testFIFOJournalIsRejectedWithoutWaitingForAWriter() throws {
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fifo = journalURL
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do {
                _ = try SafeFileRenamer(journalURL: fifo)
                XCTFail("A FIFO cannot be used as rename history.")
            } catch {
                if case SafeFileError.journal = error {} else { XCTFail("Unexpected error: \(error)") }
            }
            finished.signal()
        }
        let result = finished.wait(timeout: .now() + 2)
        if result == .timedOut {
            // Unblock a regressed blocking open so a failed test does not leave
            // a worker suspended or prevent the fixture from being removed.
            let writer = Darwin.open(fifo.path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
            if writer >= 0 { Darwin.close(writer) }
            _ = finished.wait(timeout: .now() + 2)
        }
        XCTAssertEqual(result, .success)
        try FileManager.default.removeItem(at: fifo)
        XCTAssertNoThrow(try SafeFileRenamer(journalURL: journalURL), "Rejected journals must release the history lock.")
    }

    func testDirectoryJournalIsRejected() throws {
        try FileManager.default.createDirectory(at: journalURL, withIntermediateDirectories: true)
        assertJournalFailure { _ = try SafeFileRenamer(journalURL: journalURL) }
    }

    private func sourceSnapshot() throws -> FileSnapshot {
        let source = folder.appendingPathComponent("Screenshot.png")
        try Data(repeating: 17, count: 128 * 1024).write(to: source)
        return try FileSnapshot.capture(at: source)
    }

    private func destination(_ index: Int) throws -> URL {
        let name = try FilenamePolicy.filename(title: "Chart", captureDate: captureDate, originalExtension: "png",
                                               collisionIndex: index, captureDay: captureDay)
        return folder.appendingPathComponent(name)
    }

    private func rename(_ snapshot: FileSnapshot, using renamer: SafeFileRenamer) throws -> RenameJournalEntry {
        try renamer.rename(snapshot, title: "Chart", captureDate: captureDate, captureDay: captureDay)
    }

    private func journalEntries() throws -> [RenameJournalEntry] {
        struct Journal: Decodable { let entries: [RenameJournalEntry] }
        return try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL)).entries
    }

    private func assertJournalFailure(_ operation: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard case SafeFileError.journal = error else {
                return XCTFail("Expected journal failure, got \(error)", file: file, line: line)
            }
        }
    }
}
