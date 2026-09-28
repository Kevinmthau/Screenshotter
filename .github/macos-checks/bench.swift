import CoreServices
import Darwin
import Foundation

/// Temporary macOS measurement helper for the idle-scan change. measure.sh compiles it
/// together with Sources/RenamerCore from each commit; it is not part of the app.
@main
enum Bench {
    private static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!

    private struct ReviewSuggestion: Codable {
        var original: String
        var proposed: String
        var detail: String
        var date: Date
    }

    /// Same shape as AppController's private SavedSettings.
    private struct SavedSettings: Codable {
        var folderBookmark: Data?
        var folderPath: String?
        var executablePath: String?
        var enabled = false
        var paused = false
        var previewCompleted = false
        var previewSamples: [ReviewSuggestion]?
        var ledger: CaptureLedger?
        var suggestions: [ReviewSuggestion] = []
    }

    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count >= 2 else { fatalError("usage: bench prepare|answers|scan|settings|known PATH ...") }
        let path = URL(fileURLWithPath: arguments[1])
        switch arguments[0] {
        case "prepare": try prepare(path, count: Int(arguments[2])!, metadata: arguments[3] == "1")
        case "answers": try answers(path)
        case "scan": try scan(path, label: arguments[2], scans: Int(arguments[3])!)
        case "settings": try writeSettings(folder: path, to: URL(fileURLWithPath: arguments[2]), scoped: arguments[3] == "1")
        case "known": print(try JSONDecoder().decode(SavedSettings.self, from: Data(contentsOf: path)).ledger?.knownIdentities.count ?? -1)
        default: fatalError("unknown command \(arguments[0])")
        }
    }

    private static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private static func format(_ value: Double) -> String { String(format: "%.2f", value) }

    private static func prepare(_ directory: URL, count: Int, metadata: Bool) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let flag = try PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
        for index in 0..<count {
            let url = directory.appendingPathComponent(String(format: "Screenshot 2026-09-21 at %d.%02d.00 PM.png", 1 + index / 60, index % 60))
            try png.write(to: url)
            guard metadata else { continue }
            // The screenshot tool stores this flag, which Spotlight reports as kMDItemIsScreenCapture.
            let result = flag.withUnsafeBytes {
                setxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", $0.baseAddress, $0.count, 0, 0)
            }
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        print("prepared \(count) files in \(directory.path), screen-capture metadata: \(metadata)")
    }

    /// Spotlight's answers, read the same way as the scanner, and the time for one pass.
    private static func answers(_ directory: URL) throws {
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        var counts = ["true": 0, "false": 0, "nil": 0]
        let start = DispatchTime.now().uptimeNanoseconds
        for url in urls {
            var answer: Bool?
            if let item = MDItemCreate(nil, url.path as CFString) {
                answer = (MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) as? NSNumber)?.boolValue
            }
            counts[answer.map { $0 ? "true" : "false" } ?? "nil", default: 0] += 1
        }
        let elapsed = milliseconds(since: start)
        print("SPOTLIGHT \(directory.lastPathComponent): true=\(counts["true"]!) false=\(counts["false"]!) nil=\(counts["nil"]!) ; "
              + "\(urls.count) MDItemCreate+MDItemCopyAttribute pairs took \(format(elapsed)) ms")
    }

    /// Times the real CaptureDirectoryScanner from the commit this binary was built from.
    private static func scan(_ directory: URL, label: String, scans: Int) throws {
        #if METADATA_HOOK
        var lookups = 0
        var scanner = CaptureDirectoryScanner { lookups += 1; return CaptureDirectoryScanner.spotlightScreenCapture($0) }
        #else
        var scanner = CaptureDirectoryScanner()
        #endif
        var start = DispatchTime.now().uptimeNanoseconds
        let first = try scanner.observations(in: directory)
        let firstScan = milliseconds(since: start)
        #if METADATA_HOOK
        let firstLookups = lookups
        #endif
        var durations: [Double] = []
        for _ in 0..<scans {
            start = DispatchTime.now().uptimeNanoseconds
            _ = try scanner.observations(in: directory)
            durations.append(milliseconds(since: start))
        }
        durations.sort()
        #if METADATA_HOOK
        let spotlight = "Spotlight lookups: first scan \(firstLookups), next \(scans) scans \(lookups - firstLookups)"
        #else
        let candidates = first.filter { ScreenshotRecognition.isCandidate(name: $0.name) }.count
        let spotlight = "Spotlight lookups: \(candidates) on every scan"
        #endif
        print("SCAN \(label): \(first.count) files, \(first.filter(\.eligible).count) eligible; first scan \(format(firstScan)) ms; "
              + "next \(scans) scans median \(format(durations[durations.count / 2])) ms, p90 \(format(durations[durations.count * 9 / 10])) ms, "
              + "total \(format(durations.reduce(0, +))) ms; \(spotlight)")
    }

    private static func writeSettings(folder: URL, to output: URL, scoped: Bool) throws {
        var saved = SavedSettings()
        saved.folderBookmark = try folder.bookmarkData(options: scoped ? [.withSecurityScope] : [])
        saved.folderPath = folder.path
        saved.enabled = true
        saved.previewCompleted = true
        // Activated now with an empty baseline: the existing files predate activation and are
        // never queued, but the app's first scan records them, which shows it is scanning.
        saved.ledger = CaptureLedger(baseline: [], activatedAt: Date())
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(saved).write(to: output)
    }
}
