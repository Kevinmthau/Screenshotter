import AppKit
import Darwin
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import RenamerCore

final class CodexAnalyzerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AnalyzerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testStructuredSuggestionRejectsInvalidAndUnsafeOutput() throws {
        XCTAssertEqual(try CodexAnalyzer.parseSuggestion(Data(#"{"title":"Flourish - AI Notes","useful":true}"#.utf8)),
                       NamingSuggestion(title: "Flourish - AI Notes", useful: true))
        XCTAssertEqual(try CodexAnalyzer.parseSuggestion(Data(#"{"title":"","useful":false}"#.utf8)).useful, false)
        for input in [
            #"{"title":"../secret","useful":true}"#, #"{"title":"C:\\secret","useful":true}"#,
            #"{"title":"A\nB","useful":true}"#, #"{"title":"","useful":true}"#,
            #"{"title":"Notes","useful":"yes"}"#, #"{"title":"Notes","useful":true,"extra":"bad"}"#,
            "```json\n{\"title\":\"Notes\",\"useful\":true}\n```"
        ] {
            XCTAssertThrowsError(try CodexAnalyzer.parseSuggestion(Data(input.utf8))) { error in
                XCTAssertEqual(error as? CodexAnalysisError, .invalidResponse)
            }
        }
    }

    func testEnvironmentDoesNotInheritSecretsOrParentSession() {
        let analyzer = CodexAnalyzer(executableOverride: nil, timeout: 1, environment: [
            "HOME": "/Users/example", "CODEX_HOME": "/Users/example/.codex", "OPENAI_API_KEY": "secret",
            "CODEX_THREAD_ID": "parent", "CODEX_REMOTE": "remote", "DYLD_INSERT_LIBRARIES": "/bad",
            "OTEL_EXPORTER_OTLP_ENDPOINT": "https://untrusted.invalid", "HTTPS_PROXY": "http://localhost:1234"
        ])
        let environment = analyzer.safeEnvironment(temporaryDirectory: directory)
        XCTAssertEqual(environment["HOME"], "/Users/example")
        XCTAssertEqual(environment["CODEX_HOME"], "/Users/example/.codex")
        XCTAssertEqual(environment["HTTPS_PROXY"], "http://localhost:1234")
        for key in ["OPENAI_API_KEY", "CODEX_THREAD_ID", "CODEX_REMOTE", "DYLD_INSERT_LIBRARIES", "OTEL_EXPORTER_OTLP_ENDPOINT"] {
            XCTAssertNil(environment[key])
        }
    }

    func testModelReadsOnlySimpleTopLevelSlug() {
        XCTAssertEqual(CodexAnalyzer.topLevelModel(in: "# comment\nmodel = \"my-vision-model\" # selection\n[tools]\nx=1"), "my-vision-model")
        XCTAssertNil(CodexAnalyzer.topLevelModel(in: "[profiles.private]\nmodel=\"other\""))
        XCTAssertNil(CodexAnalyzer.topLevelModel(in: "model=\"$(touch /tmp/unwanted)\""))
        XCTAssertNil(CodexAnalyzer.topLevelModel(in: "model=\"\"\"multiple\nlines\"\"\""))
    }

    func testArgumentsDisableToolsAndKeepPathsValidTOML() {
        let analyzer = CodexAnalyzer(executableOverride: nil, timeout: 1, environment: [:])
        let args = analyzer.arguments(directory: directory, image: directory.appendingPathComponent("image.png"),
            schema: directory.appendingPathComponent("schema.json"), instructions: directory.appendingPathComponent("instructions.txt"),
            response: directory.appendingPathComponent("response.json"))
        for flag in ["--ephemeral", "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check", "read-only"] {
            XCTAssertTrue(args.contains(flag))
        }
        for override in ["features.shell_tool=false", "features.unified_exec=false", "features.hooks=false",
                         "features.plugins=false", "features.computer_use=false", "features.browser_use=false",
                         "orchestrator.skills.enabled=false", "web_search=\"disabled\"", "mcp_servers={}"] {
            XCTAssertTrue(args.contains(override))
        }
        let instructions = args.first(where: { $0.hasPrefix("model_instructions_file=") })!
        XCTAssertFalse(instructions.contains("\\/"), "TOML does not support JSON's optional escaped slash")
        XCTAssertEqual(args.suffix(2).first, "--", "End image's variadic argument before the prompt")
    }

    func testSuccessfulProcessReturnsSuggestionAndRemovesTemporaryCopy() async throws {
        let marker = directory.appendingPathComponent("working-directory.txt")
        let executable = try fakeCodex("""
        /bin/pwd > \(quote(marker.path))
        printf '%s' '{"title":"Flourish - AI Notes","useful":true}' > "$response"
        """)
        let original = try image()
        let bytes = try Data(contentsOf: original)
        let result = try await CodexAnalyzer(executableOverride: executable).analyze(original)
        XCTAssertEqual(result.title, "Flourish - AI Notes")
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        let workingDirectory = try String(contentsOf: marker).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workingDirectory))
    }

    func testErrorsAreSanitizedAndCategorized() async throws {
        let cases: [(String, CodexAnalysisError)] = [
            ("401 Unauthorized private_text", .authenticationRequired),
            ("429 rate_limit_exceeded private_text", .quotaExceeded),
            ("DNS lookup failed private_text", .offline),
            ("503 service unavailable private_text", .transientFailure),
            ("unexpected argument --ephemeral private_text", .unavailable)
        ]
        let original = try image()
        for (message, expected) in cases {
            let executable = try fakeCodex("printf '%s' \(quote(message)) >&2\nexit 1")
            do {
                _ = try await CodexAnalyzer(executableOverride: executable).analyze(original)
                XCTFail("Expected an error")
            } catch let error as CodexAnalysisError {
                XCTAssertEqual(error, expected)
                XCTAssertFalse(error.localizedDescription.contains("private_text"))
            }
        }
    }

    func testTimeoutKillsProcessAndCleansTemporaryImage() async throws {
        let marker = directory.appendingPathComponent("timeout-directory.txt")
        let executable = try fakeCodex("/bin/pwd > \(quote(marker.path))\n/bin/sleep 20")
        let start = Date()
        do {
            _ = try await CodexAnalyzer(executableOverride: executable, timeout: 0.2).analyze(try image())
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? CodexAnalysisError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        let path = try String(contentsOf: marker).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testCancellationTerminatesProcessGroup() async throws {
        let marker = directory.appendingPathComponent("child-pid.txt")
        let executable = try fakeCodex("/bin/sleep 20 &\necho $! > \(quote(marker.path))\nwait")
        let original = try image()
        let task = Task { try await CodexAnalyzer(executableOverride: executable).analyze(original) }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: marker.path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let child = try XCTUnwrap(Int32(String(contentsOf: marker).trimmingCharacters(in: .whitespacesAndNewlines)))
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        // Reparenting and reaping can lag the killed process by a moment.
        for _ in 0..<100 {
            if kill(child, 0) == -1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(kill(child, 0), -1)
    }

    func testBoundedOutputStillClassifiesFinalFailure() async throws {
        let executable = try fakeCodex("""
        /usr/bin/yes 'discarded diagnostic data' | /usr/bin/head -c 100000 >&2
        printf '\\n429 rate_limit_exceeded' >&2
        exit 1
        """)
        do {
            _ = try await CodexAnalyzer(executableOverride: executable).analyze(try image())
            XCTFail("Expected failure")
        } catch { XCTAssertEqual(error as? CodexAnalysisError, .quotaExceeded) }
    }

    func testOutputTailRetainsOrderAcrossWrapsAndLargeWrites() {
        var tail = OutputTailBuffer(capacity: 8)
        XCTAssertEqual(tail.data, Data())
        tail.append(Array("abc".utf8)[...])
        XCTAssertEqual(String(decoding: tail.data, as: UTF8.self), "abc")
        tail.append(Array("defghijk".utf8)[...])
        XCTAssertEqual(String(decoding: tail.data, as: UTF8.self), "defghijk")
        tail.append(Array("lmnopqrs".utf8)[...])
        XCTAssertEqual(String(decoding: tail.data, as: UTF8.self), "lmnopqrs")
        tail.append(Array("tuvwxyz0123456789".utf8)[...])
        XCTAssertEqual(String(decoding: tail.data, as: UTF8.self), "23456789")
        XCTAssertEqual(tail.capacity, 8)
    }

    func testOutputFloodKeepsStorageBoundedAndFinalDiagnostics() {
        var tail = OutputTailBuffer()
        let bytes = [UInt8](repeating: 65, count: 8192)
        // This stream previously retained about 156 MiB in a nominal 32 KiB Data slice.
        for _ in 0..<20_000 { tail.append(bytes[...]) }
        let diagnostic = Array("429 rate_limit_exceeded".utf8)
        tail.append(diagnostic[...])
        XCTAssertEqual(tail.capacity, 32768)
        XCTAssertEqual(tail.data.count, 32768)
        XCTAssertEqual(tail.data.suffix(diagnostic.count), Data(diagnostic))
        XCTAssertEqual(CodexAnalyzer.classifyFailure(String(decoding: tail.data, as: UTF8.self)), .quotaExceeded)
    }

    func testDeadlineIncludesPipesHeldByDetachedDescendant() async throws {
        let fixture = try detachedPipeExecutable()
        defer { terminateDetachedFixture(fixture.marker) }
        let start = Date()
        do {
            _ = try await CodexAnalyzer(executableOverride: fixture.executable, timeout: 0.2).analyze(try image())
            XCTFail("A descendant holding stdout/stderr must remain subject to the request deadline")
        } catch {
            XCTAssertEqual(error as? CodexAnalysisError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        let workingDirectory = try String(contentsOf: fixture.marker.appendingPathExtension("directory"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workingDirectory))
    }

    func testCancellationAfterLeaderExitStopsPipeDrainage() async throws {
        let fixture = try detachedPipeExecutable()
        defer { terminateDetachedFixture(fixture.marker) }
        let original = try image()
        let task = Task { try await CodexAnalyzer(executableOverride: fixture.executable).analyze(original) }
        defer { task.cancel() }
        var leaderExited = false
        for _ in 0..<100 {
            if let leader = fixturePID(fixture.marker.appendingPathExtension("leader")),
               kill(leader, 0) == -1, errno == ESRCH {
                leaderExited = true; break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(leaderExited, "Cancel only after the leader has been reaped")
        let start = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        let workingDirectory = try String(contentsOf: fixture.marker.appendingPathExtension("directory"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workingDirectory))
    }

    func testRasterFormatsAndPDFLeaveOriginalContentsUnchanged() throws {
        let original = try image()
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(original as CFURL, nil))
        let cgImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let types: [UTType] = [.png, .jpeg, .tiff, .gif, .bmp, .heic]
        let supported = CGImageDestinationCopyTypeIdentifiers() as! [String]
        for type in types where supported.contains(type.identifier) {
            let file = directory.appendingPathComponent("format.\(type.preferredFilenameExtension!)")
            let output = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, type.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(output, cgImage, nil)
            XCTAssertTrue(CGImageDestinationFinalize(output))
            let before = try Data(contentsOf: file)
            let png = directory.appendingPathComponent("normalized.png")
            try CodexAnalyzer.prepareImage(file, destination: png)
            XCTAssertNotNil(CGImageSourceCreateWithURL(png as CFURL, nil))
            XCTAssertEqual(try Data(contentsOf: file), before)
        }
        let pdf = directory.appendingPathComponent("format.pdf")
        var box = CGRect(x: 0, y: 0, width: 640, height: 400)
        let consumer = try XCTUnwrap(CGDataConsumer(url: pdf as CFURL))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.draw(cgImage, in: box); context.endPDFPage(); context.closePDF()
        let before = try Data(contentsOf: pdf)
        try CodexAnalyzer.prepareImage(pdf, destination: directory.appendingPathComponent("pdf.png"))
        XCTAssertEqual(try Data(contentsOf: pdf), before)
    }

    func testImagePreparationRejectsSymlinksAndNonRegularFiles() throws {
        let original = try image()
        let link = directory.appendingPathComponent("replaced-source.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        let destination = directory.appendingPathComponent("analysis.png")
        XCTAssertThrowsError(try CodexAnalyzer.prepareImage(link, destination: destination)) { error in
            XCTAssertEqual(error as? CodexAnalysisError, .invalidImage)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))

        let fifo = directory.appendingPathComponent("source-fifo.png")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try CodexAnalyzer.prepareImage(fifo, destination: destination)) { error in
            XCTAssertEqual(error as? CodexAnalysisError, .invalidImage)
        }
        XCTAssertThrowsError(try CodexAnalyzer.prepareImage(directory, destination: destination))
    }

    func testImagePreparationRejectsOversizedInputBeforeDecoding() throws {
        let oversized = directory.appendingPathComponent("oversized.png")
        let descriptor = open(oversized.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        XCTAssertEqual(ftruncate(descriptor, 100 * 1024 * 1024 + 1), 0)
        XCTAssertThrowsError(try CodexAnalyzer.prepareImage(oversized, destination: directory.appendingPathComponent("analysis.png"))) { error in
            XCTAssertEqual(error as? CodexAnalysisError, .invalidImage)
        }
    }

    func testMissingExecutableAndSignedOutStatus() async throws {
        let missing = await CodexAnalyzer(executableOverride: directory.appendingPathComponent("missing")).checkAvailability()
        XCTAssertEqual(missing, .unavailable(.unavailable))
        let executable = try fakeCodex("exit 0", loginStatus: 1)
        let availability = await CodexAnalyzer(executableOverride: executable).checkAvailability()
        XCTAssertEqual(availability, .unavailable(.authenticationRequired))
    }

    @MainActor
    func testStoppingConnectionCheckTerminatesCLIAndCleansTemporaryDirectory() async throws {
        let marker = directory.appendingPathComponent("connection-check")
        let workingDirectory = marker.appendingPathExtension("directory")
        let executable = directory.appendingPathComponent("slow-availability")
        try """
        #!/bin/sh
        /bin/pwd > \(quote(workingDirectory.path))
        printf '%s' "$$" > \(quote(marker.path))
        exec /bin/sleep 20
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let analyzer = CodexAnalyzer(executableOverride: executable)
        let connection = CodexConnectionCheck()
        var receivedResult = false
        connection.start(check: { await analyzer.checkAvailability() }, receive: { _ in receivedResult = true })
        var child: pid_t?
        for _ in 0..<100 {
            if let recorded = fixturePID(marker) { child = recorded; break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let start = Date()
        await connection.stop()
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertFalse(connection.isChecking)
        XCTAssertFalse(receivedResult)
        XCTAssertEqual(kill(try XCTUnwrap(child), 0), -1)
        let path = try String(contentsOf: workingDirectory).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testLiveGeneratedSamplesWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["SCREENSHOT_RENAMER_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set SCREENSHOT_RENAMER_LIVE_TESTS=1 to submit generated samples with your saved Codex login.")
        }
        let analyzer = CodexAnalyzer()
        guard case .available = await analyzer.checkAvailability() else { return XCTFail("Codex login unavailable") }
        for sample in try SampleScreenshots.create(in: directory) {
            let suggestion = try await analyzer.analyze(sample)
            XCTAssertTrue(suggestion.useful)
            XCTAssertFalse(suggestion.title.contains("1234"))
            XCTAssertFalse(suggestion.title.contains("2,480"))
            XCTAssertFalse(suggestion.title.uppercased().contains("HACKED"))
        }
    }

    private func image() throws -> URL {
        try SampleScreenshots.create(in: directory).first!
    }

    private func fixturePID(_ url: URL) -> pid_t? {
        guard let text = try? String(contentsOf: url) else { return nil }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func terminateDetachedFixture(_ marker: URL) {
        if let child = fixturePID(marker.appendingPathExtension("child")) { kill(child, SIGKILL) }
    }

    private func detachedPipeExecutable() throws -> (executable: URL, marker: URL) {
        let helper = directory.appendingPathComponent("detached-pipes")
        let source = helper.appendingPathExtension("c")
        let marker = directory.appendingPathComponent("detached-fixture")
        // Compile a local fixture instead of depending on a shell's daemonization behavior.
        // Its detached child has a short failsafe lifetime, even if the test fails.
        try """
        #include <stdio.h>
        #include <stdlib.h>
        #include <unistd.h>
        static void record(const char *base, const char *suffix, int pid) {
            char path[4096]; snprintf(path, sizeof(path), "%s.%s", base, suffix);
            FILE *file = fopen(path, "w"); if (!file) _exit(2);
            fprintf(file, "%d", pid); fclose(file);
        }
        int main(int argc, char **argv) {
            if (argc != 3) return 2;
            int ready[2]; if (pipe(ready)) return 2;
            record(argv[2], "leader", getpid());
            pid_t child = fork(); if (child < 0) return 2;
            if (child == 0) {
                close(ready[0]); if (setsid() < 0) _exit(2);
                record(argv[2], "child", getpid());
                if (write(ready[1], "x", 1) != 1) _exit(2);
                close(ready[1]); sleep(3); _exit(0);
            }
            close(ready[1]); char byte;
            if (read(ready[0], &byte, 1) != 1) return 2;
            close(ready[0]);
            FILE *response = fopen(argv[1], "w"); if (!response) return 2;
            fputs("{\\"title\\":\\"Test\\",\\"useful\\":true}", response);
            fclose(response); return 0;
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        compiler.arguments = [source.path, "-o", helper.path]
        try compiler.run(); compiler.waitUntilExit()
        guard compiler.terminationStatus == 0 else { throw CodexAnalysisError.unavailable }
        let executable = try fakeCodex("""
        /bin/pwd > \(quote(marker.appendingPathExtension("directory").path))
        exec \(quote(helper.path)) "$response" \(quote(marker.path))
        """)
        return (executable, marker)
    }

    private func fakeCodex(_ body: String, loginStatus: Int = 0) throws -> URL {
        let executable = directory.appendingPathComponent("fake-codex-\(UUID().uuidString)")
        let script = """
        #!/bin/sh
        if [ "$1" = login ]; then exit \(loginStatus); fi
        if [ "$2" = --help ]; then
          printf '%s' '--image --output-schema --output-last-message --ephemeral --ignore-user-config --ignore-rules'
          exit 0
        fi
        response=''
        while [ "$#" -gt 0 ]; do
          if [ "$1" = --output-last-message ]; then shift; response="$1"; fi
          shift
        done
        \(body)
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    private func quote(_ string: String) -> String { "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
