import Foundation

/// The existing diagnostic JSON schema, including per-sample preservation checks.
public struct IntegrationReport: Codable, Sendable {
    public let date: String
    public let bundle: String
    public let launch: String
    public let automaticNamingEnabled: Bool
    public fileprivate(set) var authentication: String?
    public fileprivate(set) var executable: String?
    public fileprivate(set) var samples: [IntegrationSampleReport] = []
    public fileprivate(set) var success = false
    public fileprivate(set) var error: String?

    init(date: String, bundle: String) {
        self.date = date
        self.bundle = bundle
        self.launch = "NSApplication via LaunchServices"
        self.automaticNamingEnabled = false
    }
}

public struct IntegrationSampleReport: Codable, Sendable {
    public let sample: String
    public let title: String
    public let useful: Bool
    public let seconds: TimeInterval
    public fileprivate(set) var renamed: String?
    public fileprivate(set) var contentPreserved: Bool?
    public fileprivate(set) var undoPreserved: Bool?
}

protocol IntegrationRenaming {
    func rename(_ snapshot: FileSnapshot, title: String, captureDate: Date, captureDay: CaptureDay?) throws -> RenameJournalEntry
    func undo(entryID: UUID) throws -> RenameJournalEntry
}

/// Keep the diagnostic boundary independent of optional production rename inputs.
private final class IntegrationFileRenamer: IntegrationRenaming {
    private let renamer: SafeFileRenamer

    init(journalURL: URL) throws { renamer = try SafeFileRenamer(journalURL: journalURL) }

    func rename(_ snapshot: FileSnapshot, title: String, captureDate: Date, captureDay: CaptureDay?) throws -> RenameJournalEntry {
        try renamer.rename(snapshot, title: title, captureDate: captureDate, captureDay: captureDay)
    }

    func undo(entryID: UUID) throws -> RenameJournalEntry { try renamer.undo(entryID: entryID) }
}

private enum IntegrationVerificationError: String, LocalizedError {
    case noSamples = "No generated samples were available for verification."
    case noUsefulName = "A generated sample did not produce a useful name; rename and Undo were not verified."
    case renameChangedContents = "Renaming changed a generated sample's contents."
    case undoChangedContents = "Undo changed a generated sample's contents."

    var errorDescription: String? { rawValue }
}

private struct IntegrationReportWriteError: LocalizedError {
    let reason: String
    var errorDescription: String? { "Could not write the integration report: \(reason)" }
}

/// Runs only on generated files in a temporary directory. Operational failures are
/// recorded as success=false; inability to write the report is thrown to the caller.
@MainActor
public struct IntegrationCheckRunner {
    private let availability: () async -> CodexAvailability
    private let analyze: (URL) async throws -> NamingSuggestion
    private let createSamples: (URL) throws -> [URL]
    private let makeRenamer: (URL) throws -> any IntegrationRenaming

    public init(analyzer: CodexAnalyzer = CodexAnalyzer()) {
        self.init(availability: analyzer.checkAvailability, analyze: analyzer.analyze)
    }

    init(availability: @escaping () async -> CodexAvailability,
         analyze: @escaping (URL) async throws -> NamingSuggestion,
         createSamples: @escaping (URL) throws -> [URL] = SampleScreenshots.create,
         makeRenamer: @escaping (URL) throws -> any IntegrationRenaming = { try IntegrationFileRenamer(journalURL: $0) }) {
        self.availability = availability
        self.analyze = analyze
        self.createSamples = createSamples
        self.makeRenamer = makeRenamer
    }

    public func run(reportURL: URL, bundlePath: String) async throws -> IntegrationReport {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenshotRenamer-Integration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var report = IntegrationReport(date: ISO8601DateFormatter().string(from: Date()), bundle: bundlePath)
        do {
            switch await availability() {
            case .available(let executable):
                report.authentication = "available"
                report.executable = executable.path
            case .unavailable(let error):
                report.authentication = error.localizedDescription
                throw error
            }
            // Check the report destination before submitting any generated images.
            try write(report, to: reportURL)
            let files = try createSamples(directory)
            guard !files.isEmpty else { throw IntegrationVerificationError.noSamples }
            let renamer = try makeRenamer(directory.appendingPathComponent("journal.json"))
            for file in files {
                let snapshot = try FileSnapshot.capture(at: file)
                let started = Date()
                let suggestion = try await analyze(file)
                let index = report.samples.count
                report.samples.append(IntegrationSampleReport(sample: file.lastPathComponent, title: suggestion.title,
                                                               useful: suggestion.useful, seconds: Date().timeIntervalSince(started)))
                guard suggestion.useful else { throw IntegrationVerificationError.noUsefulName }
                let entry = try renamer.rename(snapshot, title: suggestion.title, captureDate: Date(), captureDay: nil)
                report.samples[index].renamed = entry.newURL.lastPathComponent
                let preserved = try FileSnapshot.capture(at: entry.newURL).fingerprint == snapshot.fingerprint
                report.samples[index].contentPreserved = preserved
                guard preserved else { throw IntegrationVerificationError.renameChangedContents }
                _ = try renamer.undo(entryID: entry.id)
                let undoPreserved = try FileSnapshot.capture(at: file).fingerprint == snapshot.fingerprint
                report.samples[index].undoPreserved = undoPreserved
                guard undoPreserved else { throw IntegrationVerificationError.undoChangedContents }
                try write(report, to: reportURL)
            }
            report.success = true
        } catch let error as IntegrationReportWriteError {
            throw error
        } catch {
            report.error = error.localizedDescription
        }
        try write(report, to: reportURL)
        return report
    }

    private func write(_ report: IntegrationReport, to url: URL) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: url, options: .atomic)
        } catch { throw IntegrationReportWriteError(reason: error.localizedDescription) }
    }
}
