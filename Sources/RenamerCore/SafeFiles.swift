import CryptoKit
import Darwin
import Foundation

public enum SafeFileError: Error, LocalizedError {
    case invalidTitle(String)
    case unsafeFile(String)
    case fileChanged
    case destinationExists
    case missingHistory
    case unavailableUndo
    case journal(String)
    case operation(String, Int32)
    case recoveryRequired

    public var errorDescription: String? {
        switch self {
        case .invalidTitle(let reason): return "Invalid screenshot title: \(reason)"
        case .unsafeFile(let reason): return "Cannot use this screenshot: \(reason)"
        case .fileChanged: return "The screenshot was changed, moved, or manually renamed. Review it before retrying."
        case .destinationExists: return "A file already uses the destination name. No file was overwritten."
        case .missingHistory: return "This rename is no longer in the local history."
        case .unavailableUndo: return "This rename cannot be undone because the file or its name has changed."
        case .journal(let reason): return "Could not save rename history: \(reason)"
        case .operation(let name, let code): return "\(name): \(String(cString: strerror(code)))"
        case .recoveryRequired: return "Restart Screenshot Renamer to recover an interrupted history update."
        }
    }
}

public struct FileIdentity: Codable, Equatable, Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

/// A digest of a regular file opened without following a final-component symlink.
public struct FileSnapshot: Codable, Equatable, Sendable {
    public let url: URL
    public let identity: FileIdentity
    public let fingerprint: String
    public let size: UInt64
    public let modificationDate: Date
    public let creationDate: Date
    public let modificationSeconds: Int64
    public let modificationNanoseconds: Int64

    public static func capture(at url: URL) throws -> FileSnapshot {
        let normalizedURL = url.standardizedFileURL
        let fd = normalizedURL.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard fd >= 0 else { throw SafeFileError.operation("Open screenshot", errno) }
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0 else { throw SafeFileError.operation("Inspect screenshot", errno) }
        guard (before.st_mode & S_IFMT) == S_IFREG else { throw SafeFileError.unsafeFile("only regular files are supported") }
        guard before.st_size >= 0 else { throw SafeFileError.unsafeFile("invalid file size") }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 128 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw SafeFileError.operation("Read screenshot", errno)
            }
            if count == 0 { break }
            hasher.update(data: Data(buffer.prefix(count)))
        }
        var after = stat()
        var atPath = stat()
        guard fstat(fd, &after) == 0,
              normalizedURL.path.withCString({ lstat($0, &atPath) }) == 0,
              sameStableMetadata(before, after), sameStableMetadata(after, atPath) else {
            throw SafeFileError.fileChanged
        }
        return FileSnapshot(
            url: normalizedURL,
            identity: identity(of: after),
            fingerprint: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
            size: UInt64(after.st_size),
            modificationDate: date(after.st_mtimespec),
            creationDate: date(after.st_birthtimespec),
            modificationSeconds: Int64(after.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(after.st_mtimespec.tv_nsec)
        )
    }

    public func matchesCurrentFile(at candidateURL: URL? = nil) throws -> Bool {
        let current = try Self.capture(at: candidateURL ?? url)
        return sameFileAndContents(as: current)
    }

    private func sameFileAndContents(as other: FileSnapshot) -> Bool {
        identity == other.identity && fingerprint == other.fingerprint && size == other.size &&
            modificationSeconds == other.modificationSeconds && modificationNanoseconds == other.modificationNanoseconds &&
            creationDate == other.creationDate
    }

    private static func identity(of info: stat) -> FileIdentity {
        FileIdentity(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino))
    }

    private static func sameStableMetadata(_ lhs: stat, _ rhs: stat) -> Bool {
        identity(of: lhs) == identity(of: rhs) && (rhs.st_mode & S_IFMT) == S_IFREG &&
            lhs.st_size == rhs.st_size && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec &&
            lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
            lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func date(_ value: timespec) -> Date {
        Date(timeIntervalSince1970: Double(value.tv_sec) + Double(value.tv_nsec) / 1_000_000_000)
    }
}

/// A calendar day, without a timezone-dependent instant. Stored with queued captures.
public struct CaptureDay: Codable, Equatable, Sendable {
    public let value: String

    public init(_ date: Date, timeZone: TimeZone = .current) {
        value = Self.formatter(timeZone: timeZone).string(from: date)
    }

    public init?(iso8601 value: String) {
        let formatter = Self.formatter(timeZone: TimeZone(secondsFromGMT: 0)!)
        guard value.utf8.count == 10, let date = formatter.date(from: value),
              formatter.string(from: date) == value else { return nil }
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let day = Self(iso8601: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid capture day")
        }
        self = day
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    private static func formatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }
}

public enum FilenamePolicy {
    public static func validatedTitle(_ title: String) throws -> String {
        guard !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw SafeFileError.invalidTitle("control characters are not allowed")
        }
        guard !title.contains("/"), !title.contains(":"), !title.contains("\\") else {
            throw SafeFileError.invalidTitle("path separators are not allowed")
        }
        let result = title.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !result.isEmpty, result != ".", result != "..", !result.hasPrefix(".") else {
            throw SafeFileError.invalidTitle("a visible, nonempty title is required")
        }
        guard result.utf8.count < 180 else { throw SafeFileError.invalidTitle("the title must be shorter than 180 UTF-8 bytes") }
        return result
    }

    public static func filename(title: String, captureDate: Date, originalExtension: String, collisionIndex: Int = 1,
                                captureDay: CaptureDay? = nil) throws -> String {
        let validated = try validatedTitle(title)
        guard collisionIndex >= 1 else { throw SafeFileError.invalidTitle("invalid collision suffix") }
        guard !originalExtension.contains("/"), !originalExtension.contains("\\"), !originalExtension.contains(":"),
              !originalExtension.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw SafeFileError.invalidTitle("invalid file extension")
        }
        let day = captureDay ?? CaptureDay(captureDate)
        let suffix = collisionIndex == 1 ? "" : " (\(collisionIndex))"
        let ext = originalExtension.isEmpty ? "" : ".\(originalExtension)"
        let result = "\(validated) - \(day.value)\(suffix)\(ext)"
        guard result.utf8.count <= 255 else { throw SafeFileError.invalidTitle("the complete filename is too long") }
        return result
    }
}

public struct RenameJournalEntry: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable {
        case renameIntent, renamed, undoIntent, undone, abandoned
    }

    public let id: UUID
    public let originalURL: URL
    public let newURL: URL
    public let timestamp: Date
    public let snapshot: FileSnapshot
    public var state: State
    public var detail: String?

    public init(id: UUID = UUID(), originalURL: URL, newURL: URL, timestamp: Date = Date(), snapshot: FileSnapshot, state: State, detail: String? = nil) {
        self.id = id
        self.originalURL = originalURL
        self.newURL = newURL
        self.timestamp = timestamp
        self.snapshot = snapshot
        self.state = state
        self.detail = detail
    }
}

/// The two durability boundaries of an atomic journal replacement. Kept internal
/// so failure recovery can be tested without replacing filesystem operations.
struct JournalSynchronization {
    var file: (Int32) -> Int32 = { Darwin.fsync($0) }
    var directory: (Int32) -> Int32 = { Darwin.fsync($0) }
}

/// Call from one serial executor. The exclusive rename is atomic and never replaces a
/// destination. Unix has no rename-if-source-inode-matches primitive: a different
/// process can replace/edit the source between verification and rename. We verify
/// afterward, attempt an exclusive rollback, and retain a recoverable journal intent
/// when recovery cannot be established. This is not a mandatory filesystem lock.
public final class SafeFileRenamer {
    public private(set) var history: [RenameJournalEntry] = []
    public let journalURL: URL
    public var requiresRecovery: Bool { recoveryRequired }
    private var recoveryRequired = false
    private var journalLockFD: Int32 = -1
    private let journalSynchronization: JournalSynchronization

    private struct Journal: Codable {
        let version: Int
        let entries: [RenameJournalEntry]
    }

    public convenience init(journalURL: URL) throws {
        try self.init(journalURL: journalURL, journalSynchronization: JournalSynchronization())
    }

    init(journalURL: URL, journalSynchronization: JournalSynchronization) throws {
        self.journalURL = journalURL.standardizedFileURL
        self.journalSynchronization = journalSynchronization
        let parent = self.journalURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lockURL = parent.appendingPathComponent(".\(self.journalURL.lastPathComponent).lock")
        let lockFD = lockURL.path.withCString { Darwin.open($0, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600)) }
        guard lockFD >= 0 else { throw SafeFileError.journal("could not open the history lock") }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(lockFD)
            throw SafeFileError.journal("another Screenshot Renamer instance is using this history")
        }
        journalLockFD = lockFD
        var journalInfo = stat()
        if self.journalURL.path.withCString({ lstat($0, &journalInfo) }) == 0 {
            guard (journalInfo.st_mode & S_IFMT) == S_IFREG else {
                throw SafeFileError.journal("history must be a regular file")
            }
            // A replacement between lstat and open must not turn startup into a
            // blocking FIFO read. Validate the opened descriptor as well.
            let fd = self.journalURL.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
            guard fd >= 0 else { throw SafeFileError.journal("the history file could not be opened safely") }
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                Darwin.close(fd)
                throw SafeFileError.journal("history must be a regular file")
            }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            let journal: Journal
            do {
                journal = try JSONDecoder().decode(Journal.self, from: handle.readToEnd() ?? Data())
            } catch { throw SafeFileError.journal("history is unreadable; preserve it before trying again") }
            guard journal.version == 1 else { throw SafeFileError.journal("unsupported history version") }
            history = journal.entries
        } else if errno != ENOENT {
            throw SafeFileError.journal("could not inspect existing history")
        }
        try recoverInterruptedOperations()
        try pruneHistory()
    }

    deinit {
        if journalLockFD >= 0 { Darwin.close(journalLockFD) }
    }

    @discardableResult
    public func rename(_ snapshot: FileSnapshot, title: String, captureDate: Date,
                       captureDay: CaptureDay? = nil, authorization: FileMutationAuthorization? = nil) throws -> RenameJournalEntry {
        try requireReady()
        guard (try? snapshot.matchesCurrentFile()) == true else { throw SafeFileError.fileChanged }
        let folder = snapshot.url.deletingLastPathComponent()
        for index in 1...10_000 {
            let name = try FilenamePolicy.filename(title: title, captureDate: captureDate, originalExtension: snapshot.url.pathExtension,
                                                   collisionIndex: index, captureDay: captureDay)
            let destination = folder.appendingPathComponent(name, isDirectory: false)
            // Avoid a durable transaction and another source hash for occupied
            // names. RENAME_EXCL below still handles destinations created later.
            if try destinationExists(at: destination) { continue }
            let intent = RenameJournalEntry(originalURL: snapshot.url, newURL: destination, snapshot: snapshot, state: .renameIntent)
            try save(history + [intent])
            do {
                try verifiedExclusiveRename(from: snapshot.url, to: destination, expected: snapshot, authorization: authorization)
            } catch SafeFileError.destinationExists {
                try removeEntry(id: intent.id)
                continue
            } catch {
                // Keep durable intent if a rename may have happened. Recovery only
                // observes matching files; it never guesses which file to move.
                do { try recoverInterruptedOperations() } catch { recoveryRequired = true }
                throw error
            }
            return try setState(id: intent.id, state: .renamed)
        }
        throw SafeFileError.destinationExists
    }

    @discardableResult
    public func undo(entryID: UUID) throws -> RenameJournalEntry {
        try requireReady()
        guard let entry = history.first(where: { $0.id == entryID }) else { throw SafeFileError.missingHistory }
        guard entry.state == .renamed, (try? entry.snapshot.matchesCurrentFile(at: entry.newURL)) == true else {
            throw SafeFileError.unavailableUndo
        }
        _ = try setState(id: entryID, state: .undoIntent)
        do {
            try verifiedExclusiveRename(from: entry.newURL, to: entry.originalURL, expected: entry.snapshot)
        } catch {
            do { try recoverInterruptedOperations() } catch { recoveryRequired = true }
            throw error
        }
        return try setState(id: entryID, state: .undone)
    }

    public func clearHistory() throws {
        try requireReady()
        try recoverInterruptedOperations()
        try save([])
    }

    private func destinationExists(at url: URL) throws -> Bool {
        var info = stat()
        if url.path.withCString({ lstat($0, &info) }) == 0 { return true }
        let code = errno
        guard code == ENOENT else { throw SafeFileError.operation("Inspect destination", code) }
        return false
    }

    public func pruneHistory(now: Date = Date()) throws {
        try requireReady()
        let cutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        let retained = history.filter { $0.timestamp >= cutoff || $0.state == .renameIntent || $0.state == .undoIntent }
        if retained.count != history.count { try save(retained) }
    }

    private func requireReady() throws {
        if recoveryRequired { throw SafeFileError.recoveryRequired }
    }

    private func recoverInterruptedOperations() throws {
        var recovered = history
        for index in recovered.indices {
            let entry = recovered[index]
            guard entry.state == .renameIntent || entry.state == .undoIntent else { continue }
            let originalMatches: Bool
            let renamedMatches: Bool
            do {
                originalMatches = try recoveryMatches(entry.snapshot, at: entry.originalURL)
                renamedMatches = try recoveryMatches(entry.snapshot, at: entry.newURL)
            } catch {
                // An unavailable folder or unreadable image cannot establish that an
                // operation failed. Keep every durable intent for a later restart.
                recoveryRequired = true
                throw SafeFileError.recoveryRequired
            }
            if originalMatches && !renamedMatches {
                recovered[index].state = entry.state == .undoIntent ? .undone : .abandoned
                recovered[index].detail = entry.state == .undoIntent ? "Recovered completed undo." : "Rename did not complete."
            } else if renamedMatches && !originalMatches {
                recovered[index].state = .renamed
                recovered[index].detail = entry.state == .undoIntent ? "Undo did not complete." : "Recovered completed rename."
            } else {
                recovered[index].state = .abandoned
                recovered[index].detail = "File changed, moved, or could not be identified during recovery; no file was moved."
            }
        }
        if recovered != history { try save(recovered) }
    }

    private func recoveryMatches(_ snapshot: FileSnapshot, at url: URL) throws -> Bool {
        let parent = url.deletingLastPathComponent()
        let directoryFD = parent.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
        guard directoryFD >= 0 else { throw SafeFileError.recoveryRequired }
        defer { Darwin.close(directoryFD) }

        var info = stat()
        let inspected = url.lastPathComponent.withCString {
            fstatat(directoryFD, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        if inspected != 0 {
            // ENOENT is conclusive only for the leaf inside an accessible folder;
            // a missing parent may simply be an unavailable volume or location.
            guard errno == ENOENT else { throw SafeFileError.recoveryRequired }
            return false
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return false }
        return try snapshot.matchesCurrentFile(at: url)
    }

    private func setState(id: UUID, state: RenameJournalEntry.State) throws -> RenameJournalEntry {
        var updated = history
        guard let index = updated.firstIndex(where: { $0.id == id }) else { throw SafeFileError.missingHistory }
        updated[index].state = state
        do { try save(updated) } catch {
            recoveryRequired = true
            throw error
        }
        return updated[index]
    }

    private func removeEntry(id: UUID) throws {
        try save(history.filter { $0.id != id })
    }

    private func verifiedExclusiveRename(from source: URL, to destination: URL, expected: FileSnapshot,
                                         authorization: FileMutationAuthorization? = nil) throws {
        guard source.deletingLastPathComponent() == destination.deletingLastPathComponent() else {
            throw SafeFileError.unsafeFile("renames must stay in the same folder")
        }
        let parent = source.deletingLastPathComponent()
        let directoryFD = parent.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
        guard directoryFD >= 0 else { throw SafeFileError.operation("Open screenshot folder", errno) }
        defer { Darwin.close(directoryFD) }
        guard (try? expected.matchesCurrentFile(at: source)) == true else { throw SafeFileError.fileChanged }
        let mutation = {
            source.lastPathComponent.withCString { from in
                destination.lastPathComponent.withCString { to in
                    renameatx_np(directoryFD, from, directoryFD, to, UInt32(RENAME_EXCL))
                }
            }
        }
        let result = try authorization.map { try $0.perform(mutation) } ?? mutation()
        if result != 0 {
            let code = errno
            if code == EEXIST { throw SafeFileError.destinationExists }
            throw SafeFileError.operation("Rename screenshot", code)
        }
        guard (try? expected.matchesCurrentFile(at: destination)) == true else {
            // Roll back only the file currently observed at the destination, and
            // only if it remains there and the old name is free. A failed rollback
            // leaves the journal intent for conservative restart recovery.
            if let observed = try? FileSnapshot.capture(at: destination), observed.identity == expected.identity,
               (try? observed.matchesCurrentFile(at: destination)) == true {
                _ = destination.lastPathComponent.withCString { from in
                    source.lastPathComponent.withCString { to in
                        renameatx_np(directoryFD, from, directoryFD, to, UInt32(RENAME_EXCL))
                    }
                }
                _ = fsync(directoryFD)
            }
            throw SafeFileError.fileChanged
        }
        guard fsync(directoryFD) == 0 else {
            recoveryRequired = true
            throw SafeFileError.operation("Save screenshot folder changes", errno)
        }
    }

    private func save(_ entries: [RenameJournalEntry]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Journal(version: 1, entries: entries))
        let parent = journalURL.deletingLastPathComponent()
        let temp = parent.appendingPathComponent(".\(journalURL.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = temp.path.withCString { Darwin.open($0, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600)) }
        guard fd >= 0 else { throw SafeFileError.journal(String(cString: strerror(errno))) }
        defer { Darwin.close(fd); _ = temp.path.withCString { unlink($0) } }
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw SafeFileError.journal(String(cString: strerror(errno))) }
                written += count
            }
        }
        guard journalSynchronization.file(fd) == 0 else { throw SafeFileError.journal(String(cString: strerror(errno))) }
        // Replacing our journal is intentional. It never opens or writes through
        // a symlink and the temporary file is private to this process.
        let renamed = temp.path.withCString { from in journalURL.path.withCString { to in Darwin.rename(from, to) } }
        guard renamed == 0 else { throw SafeFileError.journal(String(cString: strerror(errno))) }
        let directoryFD = parent.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
        guard directoryFD >= 0 else { recoveryRequired = true; throw SafeFileError.journal("could not open history folder for synchronization") }
        defer { Darwin.close(directoryFD) }
        guard journalSynchronization.directory(directoryFD) == 0 else { recoveryRequired = true; throw SafeFileError.journal("could not synchronize history folder") }
        history = entries
    }
}
