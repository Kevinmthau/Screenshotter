import CoreServices
import Darwin
import Foundation

public struct CaptureObservationBatch: Sendable {
    public let revision: UInt64
    public let files: [CaptureObservation]
    public init(revision: UInt64, files: [CaptureObservation]) { self.revision = revision; self.files = files }
}

/// Blocking file work is serialized away from AppKit. Only immutable state crosses back.
public final class CaptureFileService: @unchecked Sendable {
    public struct State: Sendable {
        public let revision: UInt64
        public let history: [RenameJournalEntry]
        public let requiresRecovery: Bool
    }

    private let queue = DispatchQueue(label: "ScreenshotRenamer.files", qos: .utility)
    private var renamer: SafeFileRenamer?
    private var revision: UInt64 = 0
    private var scanner = CaptureDirectoryScanner()
    private let scanOverride: (@Sendable (URL) throws -> [CaptureObservation])?

    public init() { scanOverride = nil }
    init(scan: @escaping @Sendable (URL) throws -> [CaptureObservation]) { scanOverride = scan }

    private func perform<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: operation)) }
        }
    }

    public func open(journalURL: URL) async throws -> State {
        try await perform {
            self.renamer = try SafeFileRenamer(journalURL: journalURL)
            return try self.currentState()
        }
    }

    public func observations(in directory: URL) async throws -> CaptureObservationBatch {
        try await perform {
            let files = try self.scanOverride.map { try $0(directory) } ?? self.scanner.observations(in: directory)
            self.revision += 1
            return CaptureObservationBatch(revision: self.revision, files: files)
        }
    }

    public func snapshot(at url: URL) async throws -> FileSnapshot {
        try Task.checkCancellation()
        let result = try await perform { try FileSnapshot.capture(at: url) }
        try Task.checkCancellation()
        return result
    }

    public func matches(_ snapshot: FileSnapshot) async throws -> Bool {
        try await perform { try snapshot.matchesCurrentFile() }
    }

    public func rename(_ snapshot: FileSnapshot, title: String, job: PendingCapture,
                       authorization: FileMutationAuthorization) async throws -> State {
        try await perform {
            guard let renamer = self.renamer else { throw SafeFileError.recoveryRequired }
            _ = try renamer.rename(snapshot, title: title, captureDate: job.captureDate,
                                   captureDay: job.namingDay, authorization: authorization)
            return try self.currentState()
        }
    }

    public func undo(_ id: UUID) async throws -> State {
        try await perform {
            guard let renamer = self.renamer else { throw SafeFileError.recoveryRequired }
            _ = try renamer.undo(entryID: id)
            return try self.currentState()
        }
    }

    public func pruneHistory() async throws -> State {
        try await perform {
            try self.renamer?.pruneHistory()
            return try self.currentState()
        }
    }

    public func clearHistory() async throws -> State {
        try await perform {
            try self.renamer?.clearHistory()
            return try self.currentState()
        }
    }

    public func state() async throws -> State { try await perform { try self.currentState() } }
    public func drain() async { _ = try? await perform {} }

    private func currentState() throws -> State {
        guard let renamer else { throw SafeFileError.recoveryRequired }
        revision += 1
        return State(revision: revision, history: renamer.history, requiresRecovery: renamer.requiresRecovery)
    }
}

/// Cache filename-derived values, and Spotlight answers once definite. Identity and revision
/// are re-read on every scan. A cached answer applies only to the same identity and revision,
/// whose ctime also changes with extended attributes. Unknown answers are re-read on every
/// scan, so late metadata rejection and editor replacements are still observed.
struct CaptureDirectoryScanner {
    private struct CachedName {
        let created: Date
        let candidate: Bool
        let captureDate: Date
    }
    private struct CachedMetadata {
        let revision: String
        let isScreenCapture: Bool
    }
    private var cachedNames: [String: CachedName] = [:]
    private var cachedMetadata: [String: CachedMetadata] = [:]
    private var cachedDirectory: URL?
    private var cachedTimeZone = TimeZone.current
    private let screenCaptureMetadata: (URL) -> Bool?

    init(screenCaptureMetadata: @escaping (URL) -> Bool? = CaptureDirectoryScanner.spotlightScreenCapture) {
        self.screenCaptureMetadata = screenCaptureMetadata
    }

    static func spotlightScreenCapture(_ url: URL) -> Bool? {
        guard let item = MDItemCreate(nil, url.path as CFString) else { return nil }
        return (MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) as? NSNumber)?.boolValue
    }

    mutating func observations(in directory: URL) throws -> [CaptureObservation] {
        if cachedDirectory != directory || cachedTimeZone != .current {
            cachedNames.removeAll()
            cachedMetadata.removeAll()
            cachedDirectory = directory
            cachedTimeZone = .current
        }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        var retained: [String: CachedName] = [:]
        var retainedMetadata: [String: CachedMetadata] = [:]
        let files = urls.compactMap { url -> CaptureObservation? in
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
            let name = url.lastPathComponent
            let identity = "\(UInt64(UInt32(bitPattern: info.st_dev))):\(info.st_ino)"
            let revision = "\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
            let created = Date(timeIntervalSince1970: Double(info.st_birthtimespec.tv_sec) + Double(info.st_birthtimespec.tv_nsec) / 1_000_000_000)
            let cached: CachedName
            if let previous = cachedNames[name], previous.created == created { cached = previous }
            else {
                cached = CachedName(created: created, candidate: ScreenshotRecognition.isCandidate(name: name),
                                    captureDate: ScreenshotRecognition.captureDate(name: name, fallback: created))
            }
            retained[name] = cached
            var metadata: Bool?
            if cached.candidate {
                if let previous = cachedMetadata[identity], previous.revision == revision { metadata = previous.isScreenCapture }
                else { metadata = screenCaptureMetadata(url) }
                if let metadata { retainedMetadata[identity] = CachedMetadata(revision: revision, isScreenCapture: metadata) }
            }
            return CaptureObservation(name: name, identity: identity, revision: revision, created: created,
                                      captureDate: cached.captureDate, eligible: cached.candidate && metadata != false)
        }
        cachedNames = retained
        cachedMetadata = retainedMetadata
        return files
    }
}
