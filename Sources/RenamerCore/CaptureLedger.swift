import Foundation
import CryptoKit

public struct CaptureObservation: Sendable {
    public let name: String
    public let identity: String
    public let revision: String
    public let created: Date
    public let captureDate: Date
    public let eligible: Bool
    public init(name: String, identity: String, revision: String, created: Date, captureDate: Date, eligible: Bool) {
        self.name = name; self.identity = identity; self.revision = revision
        self.created = created; self.captureDate = captureDate; self.eligible = eligible
    }
}

public struct PendingCapture: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable { case waiting, analyzing, retry, failed }
    public var id = UUID()
    public var name: String
    public var identity: String
    public var revision: String
    public var captureDate: Date
    public var stableSince: Date
    public var attempts = 0
    public var nextAttempt = Date.distantPast
    public var state: State = .waiting
    public var captureDay: CaptureDay? = nil

    // Legacy ledgers stored only an instant. Their original filename still supplies the day.
    public var namingDay: CaptureDay {
        captureDay ?? ScreenshotRecognition.captureDay(name: name, fallback: captureDate)
    }
}

/// Persistent eligibility ledger. Completed/baseline filenames are retained only as hashes.
/// Files present at activation, already handled identities, and manually renamed captures
/// can never become newly eligible during reconciliation or a restart.
public struct CaptureLedger: Codable, Equatable, Sendable {
    public var activatedAt: Date
    public private(set) var knownIdentities: Set<String>
    public private(set) var knownNames: Set<String>
    public private(set) var pending: [PendingCapture] = []
    public static let capacity = 64

    public init(baseline: [CaptureObservation], activatedAt: Date = Date()) {
        self.activatedAt = activatedAt
        knownIdentities = Set(baseline.map(\.identity))
        knownNames = Set(baseline.map { Self.nameKey($0.name) })
    }

    public mutating func recoverAfterRestart() {
        for i in pending.indices {
            if pending[i].captureDay == nil { pending[i].captureDay = pending[i].namingDay }
            if pending[i].state == .analyzing {
                pending[i].state = .waiting
                pending[i].stableSince = Date()
            }
        }
    }

    /// Returns true when additional captures are deferred because the bounded queue is full.
    @discardableResult public mutating func reconcile(_ files: [CaptureObservation], now: Date = Date()) -> Bool {
        let byName = Dictionary(files.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let byIdentity = Dictionary(files.map { ($0.identity, $0.name) }, uniquingKeysWith: { a, _ in a })
        let excludedReplacementIdentities = knownIdentities
        let activation = activatedAt
        pending.removeAll { job in
            // Moving/renaming the source, even while an editor writes a replacement, cancels it.
            if let currentName = byIdentity[job.identity], currentName != job.name { return true }
            guard let file = byName[job.name], file.eligible else { return true }
            // A new inode must also be new to this activation; occupying an eligible
            // path does not make a baseline, completed, or older file eligible.
            return file.identity != job.identity &&
                (file.created < activation || excludedReplacementIdentities.contains(file.identity))
        }
        for i in pending.indices {
            guard let file = byName[pending[i].name] else { continue }
            if file.revision != pending[i].revision || file.identity != pending[i].identity {
                // A replacement in place is allowed only for an already eligible capture.
                pending[i].identity = file.identity
                pending[i].revision = file.revision
                pending[i].stableSince = now
                pending[i].state = .waiting
                pending[i].attempts = 0
                pending[i].nextAttempt = .distantPast
                knownIdentities.insert(file.identity)
            }
        }
        var overflow = false
        for file in files.sorted(by: { $0.created < $1.created }) {
            let nameKey = Self.nameKey(file.name)
            guard !knownIdentities.contains(file.identity), !knownNames.contains(nameKey) else {
                // Remember both sides of an excluded observation so a replacement
                // cannot become eligible after a later manual rename or restart.
                knownIdentities.insert(file.identity)
                knownNames.insert(nameKey)
                continue
            }
            if file.eligible && file.created >= activatedAt {
                if pending.count >= Self.capacity { overflow = true; continue }
                pending.append(PendingCapture(name: file.name, identity: file.identity, revision: file.revision,
                                              captureDate: file.captureDate, stableSince: now,
                                              captureDay: ScreenshotRecognition.captureDay(name: file.name, fallback: file.captureDate)))
            }
            knownIdentities.insert(file.identity)
            knownNames.insert(nameKey)
        }
        return overflow
    }

    public func nextReady(now: Date = Date(), stability: TimeInterval = 2) -> PendingCapture? {
        pending.first { ($0.state == .waiting || $0.state == .retry) &&
            now.timeIntervalSince($0.stableSince) >= stability && now >= $0.nextAttempt }
    }

    public mutating func update(_ job: PendingCapture) {
        if let i = pending.firstIndex(where: { $0.id == job.id }) { pending[i] = job }
    }
    public mutating func finish(_ id: UUID) { pending.removeAll { $0.id == id } }
    /// Lets other captures go first, so one image cannot hold the queue while Codex recovers.
    public mutating func moveToBack(_ id: UUID) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending.append(pending.remove(at: index))
    }
    public mutating func prunePending(before cutoff: Date) {
        pending.removeAll { $0.stableSince < cutoff }
    }
    public func capture(_ id: UUID) -> PendingCapture? { pending.first { $0.id == id } }
    public mutating func retryFailures() {
        for i in pending.indices where pending[i].state == .failed || pending[i].state == .retry {
            pending[i].state = .waiting; pending[i].attempts = 0; pending[i].nextAttempt = .distantPast
        }
    }
    private static let hexadecimalDigits = Array("0123456789abcdef".utf8)

    private static func nameKey(_ name: String) -> String {
        // Keep the lowercase SHA-256 representation used by persisted ledgers.
        var encoded = [UInt8]()
        encoded.reserveCapacity(64)
        for byte in SHA256.hash(data: Data(name.utf8)) {
            encoded.append(hexadecimalDigits[Int(byte >> 4)])
            encoded.append(hexadecimalDigits[Int(byte & 0x0f)])
        }
        return String(decoding: encoded, as: UTF8.self)
    }
}

public enum ScreenshotRecognition {
    public static let extensions: Set<String> = ["png", "jpg", "jpeg", "tif", "tiff", "heic", "heif", "gif", "bmp", "pdf"]
    // Requiring a system-style name also when metadata exists protects custom titles.
    public static func isCandidate(name: String, metadataIsScreenshot: Bool? = nil) -> Bool {
        guard extensions.contains((name as NSString).pathExtension.lowercased()) else { return false }
        let pattern = #"^(?:Screenshot|Screen Shot) [0-9]{4}-[0-9]{2}-[0-9]{2} (?:at )?[0-9]{1,2}[.:-][0-9]{2}[.:-][0-9]{2}(?:[\s\u00a0\u202f]+(?:AM|PM))?(?: \([0-9]+\))?\.[a-zA-Z]+$"#
        let standardName = name.range(of: pattern, options: .regularExpression) != nil
        return standardName && metadataIsScreenshot != false
    }
    public static func captureDay(name: String, fallback: Date, timeZone: TimeZone = .current) -> CaptureDay {
        let pattern = #"[0-9]{4}-[0-9]{2}-[0-9]{2}"#
        if let range = name.range(of: pattern, options: .regularExpression),
           let day = CaptureDay(iso8601: String(name[range])) { return day }
        return CaptureDay(fallback, timeZone: timeZone)
    }

    public static func captureDate(name: String, fallback: Date) -> Date {
        let pattern = #"[0-9]{4}-[0-9]{2}-[0-9]{2}"#
        guard let range = name.range(of: pattern, options: .regularExpression) else { return fallback }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        return formatter.date(from: String(name[range])) ?? fallback
    }
}
