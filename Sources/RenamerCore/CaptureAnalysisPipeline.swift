import Foundation

public protocol ScreenshotAnalyzing: Sendable {
    func analyze(_ imageURL: URL) async throws -> NamingSuggestion
}
extension CodexAnalyzer: ScreenshotAnalyzing {}

/// Injectable preparation/submission boundary: cancellation and current queue state
/// are checked after background hashing and before any image is submitted.
public struct CaptureAnalysisPipeline: Sendable {
    private let analyzer: any ScreenshotAnalyzing
    private let snapshot: @Sendable (URL) async throws -> FileSnapshot

    public init(analyzer: any ScreenshotAnalyzing,
                snapshot: @escaping @Sendable (URL) async throws -> FileSnapshot) {
        self.analyzer = analyzer
        self.snapshot = snapshot
    }

    public func analyze(_ url: URL, for job: PendingCapture,
                        isCurrent: @MainActor @Sendable () -> Bool) async throws -> (FileSnapshot, NamingSuggestion) {
        try Task.checkCancellation()
        let source = try await snapshot(url)
        try Task.checkCancellation()
        guard "\(source.identity.device):\(source.identity.inode)" == job.identity,
              job.revision.hasPrefix("\(source.size):\(source.modificationSeconds):\(source.modificationNanoseconds):") else {
            throw SafeFileError.fileChanged
        }
        guard await isCurrent() else { throw CancellationError() }
        try Task.checkCancellation()
        let result = try await analyzer.analyze(url)
        return (source, result)
    }
}
