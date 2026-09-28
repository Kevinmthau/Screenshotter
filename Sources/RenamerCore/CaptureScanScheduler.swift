import Foundation

/// One in-flight scan and at most one follow-up batch. Results from an old folder,
/// activation or shutdown are discarded before they can mutate the capture queue.
@MainActor public final class CaptureScanScheduler {
    public typealias Scan = (URL) async throws -> CaptureObservationBatch
    private let scan: Scan
    private let receive: (Result<CaptureObservationBatch, Error>) -> Void
    private var work: Task<Void, Never>?
    private var pending: URL?
    private var generation = 0

    public init(scan: @escaping Scan, receive: @escaping (Result<CaptureObservationBatch, Error>) -> Void) {
        self.scan = scan
        self.receive = receive
    }

    public func request(_ directory: URL) {
        pending = directory
        guard work == nil else { return }
        work = Task { [weak self] in
            guard let self else { return }
            defer { self.work = nil }
            while let directory = self.pending {
                self.pending = nil
                let submittedGeneration = self.generation
                let result: Result<CaptureObservationBatch, Error>
                do { result = .success(try await self.scan(directory)) }
                catch { result = .failure(error) }
                if submittedGeneration == self.generation { self.receive(result) }
            }
        }
    }

    public func invalidate() {
        generation += 1
        pending = nil
    }

    public func drain() async { await work?.value }
}

/// FSEvents request a scan for every change, so with the watcher running and nothing pending
/// the timer is only a safety net. Pending captures keep the two-second cadence that stability
/// and retry timing depend on, as does a folder without a watcher.
public struct PeriodicScanPolicy: Sendable {
    public static let idleInterval: TimeInterval = 30
    private var lastScan = Date.distantPast
    public init() {}

    /// Change, wake, resume and retry requests always scan and restart the idle interval.
    /// A clock set back ends the interval rather than suspending the safety net.
    public mutating func shouldScan(periodic: Bool, watching: Bool, pending: Bool, now: Date = Date()) -> Bool {
        if periodic, watching, !pending, (0..<Self.idleInterval).contains(now.timeIntervalSince(lastScan)) { return false }
        lastScan = now
        return true
    }
}

/// Queue policy is independent of AppKit and wall-clock time. The controller owns
/// persistence; these transitions are also used by deterministic retry/pause tests.
public struct CaptureQueuePolicy: Sendable {
    private var lastObservationRevision: UInt64 = 0
    public struct Reconciliation {
        public let overflow: Bool
        public let invalidatedActiveCapture: Bool
    }

    /// Shared by periodic, completion and failure scans. Stale batches must not
    /// remove newly discovered captures whose names are already remembered.
    public mutating func reconcile(_ batch: CaptureObservationBatch, ledger: inout CaptureLedger,
                                   active: PendingCapture?, authorization: FileMutationAuthorization?) -> Reconciliation? {
        guard batch.revision > lastObservationRevision else { return nil }
        lastObservationRevision = batch.revision
        let overflow = ledger.reconcile(batch.files, now: now())
        let invalidated: Bool
        if let active {
            let current = ledger.capture(active.id)
            invalidated = current?.identity != active.identity || current?.revision != active.revision
        } else { invalidated = false }
        if invalidated { authorization?.cancel() }
        return Reconciliation(overflow: overflow, invalidatedActiveCapture: invalidated)
    }

    private let now: @Sendable () -> Date
    public init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    public func claim(from ledger: inout CaptureLedger) -> PendingCapture? {
        guard var job = ledger.nextReady(now: now()) else { return nil }
        job.state = .analyzing
        job.attempts += 1
        ledger.update(job)
        return job
    }

    public func reset(_ id: UUID, in ledger: inout CaptureLedger) {
        guard var job = ledger.capture(id) else { return }
        job.state = .waiting
        job.stableSince = now()
        job.nextAttempt = .distantPast
        ledger.update(job)
    }

    /// How the controller continues after a naming attempt fails.
    public enum FailureOutcome: Equatable, Sendable {
        /// The capture is retried automatically at its `nextAttempt`.
        case retryScheduled
        /// Codex needs sign-in, usage, or a compatible CLI. The capture resumes after the
        /// next successful connection check rather than on its own timer.
        case awaitingConnection
        /// Another attempt cannot produce a usable name; keep the original filename for review.
        case keepOriginal
        /// Automatic attempts are exhausted; Retry Pending is required.
        case failed
    }

    /// Delays after attempts 1 through 5. Together they cover sleep, network changes and short
    /// service interruptions (about 50 minutes) without resubmitting an image indefinitely.
    static let retryDelays: [TimeInterval] = [15, 60, 300, 900, 1800]
    static let maximumAttempts = 6
    /// Unreadable images and invalid model answers are retried twice, then keep their name.
    static let maximumContentAttempts = 3

    /// Every submission counts toward the attempt limit, including ones that wait for a
    /// connection, so a misclassified failure cannot hold the queue indefinitely.
    public func fail(_ job: inout PendingCapture, with error: CodexAnalysisError) -> FailureOutcome {
        let attempt = max(job.attempts, 1)
        switch error {
        case .authenticationRequired, .quotaExceeded, .unavailable:
            guard attempt < Self.maximumAttempts else { job.state = .failed; return .failed }
            job.state = .retry
            job.nextAttempt = .distantPast
            return .awaitingConnection
        case .invalidImage, .invalidResponse:
            guard attempt < Self.maximumContentAttempts else { job.state = .failed; return .keepOriginal }
        case .offline, .transientFailure, .timedOut:
            guard attempt < Self.maximumAttempts else { job.state = .failed; return .failed }
        }
        job.state = .retry
        job.nextAttempt = now().addingTimeInterval(Self.retryDelays[min(attempt, Self.retryDelays.count) - 1])
        return .retryScheduled
    }

    /// Delay before the next automatic connection check after Codex stopped accepting work.
    /// A check runs `codex exec --help` and `codex login status` locally; it never submits an image.
    public static func connectionCheckDelay(after error: CodexAnalysisError, consecutiveFailures: Int) -> TimeInterval {
        let schedule: [TimeInterval]
        switch error {
        case .quotaExceeded: schedule = [1800, 3600]
        case .authenticationRequired, .unavailable: schedule = [60, 120, 300, 600, 900]
        case .offline, .transientFailure, .timedOut, .invalidResponse, .invalidImage: schedule = [15, 30, 60, 120, 300]
        }
        return schedule[min(max(consecutiveFailures, 1), schedule.count) - 1]
    }
}
