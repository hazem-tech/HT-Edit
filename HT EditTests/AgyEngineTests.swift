//
//  AgyEngineTests.swift
//  HT EditTests
//

import Foundation
import Testing
@testable import HT_Edit

struct AgyCommandTests {

    @Test func transcribeCommandIsHeadlessJSONWithTheChosenModel() throws {
        let arguments = AgyCommand.transcribe(fileName: "chunk-1.m4a", duration: 180, model: "gemini-3.6-flash", context: "", timeout: .seconds(300))
        #expect(arguments.first == "-p")
        #expect(arguments.contains("--output-format"))
        #expect(value(after: "--output-format", in: arguments) == "json")
        #expect(value(after: "--model", in: arguments) == "gemini-3.6-flash")
        #expect(value(after: "--print-timeout", in: arguments) == "300s")
        let schema = try #require(value(after: "--json-schema", in: arguments))
        #expect((try? JSONSerialization.jsonObject(with: Data(schema.utf8))) != nil, "Schema must be valid JSON")
    }

    @Test func promptMentionsTheFileAndOnlyIncludesContextWhenGiven() {
        let plain = AgyCommand.prompt(fileName: "chunk-2.m4a", duration: 42, context: "  \n ")
        #expect(plain.contains("@chunk-2.m4a"))
        #expect(plain.contains("42.0 seconds"))
        #expect(!plain.contains("Context"))

        let withContext = AgyCommand.prompt(fileName: "chunk-2.m4a", duration: 42, context: "Hazem, SwiftUI, HT Edit")
        #expect(withContext.contains("Context from the user"))
        #expect(withContext.contains("Hazem, SwiftUI, HT Edit"))
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}

struct AgyOutputParserTests {

    private let expected = [TranscriptSegment(start: 0.5, end: 1.5, text: "Hello there.")]

    @Test func readsStructuredOutput() throws {
        let stdout = #"{"conversation_id":"c1","status":"SUCCESS","response":"","structured_output":{"segments":[{"start":0.5,"end":1.5,"text":"Hello there."}]},"usage":{}}"#
        #expect(try AgyOutputParser.segments(from: stdout) == expected)
    }

    @Test(arguments: [
        #"{"status":"SUCCESS","response":"{\"segments\":[{\"start\":0.5,\"end\":1.5,\"text\":\"Hello there.\"}]}"}"#,
        #"{"status":"SUCCESS","response":"Here you go:\n```json\n[{\"start\":\"0:00.5\",\"end\":\"00:00:01,500\",\"text\":\"Hello there.\"}]\n```"}"#,
        #"[{"start":"0.5s","end":1.5,"text":"Hello there."}]"#,
    ])
    func readsTextRepliesInCommonShapes(stdout: String) throws {
        #expect(try AgyOutputParser.segments(from: stdout) == expected)
    }

    @Test func emptyTranscriptIsValid() throws {
        #expect(try AgyOutputParser.segments(from: #"{"status":"SUCCESS","structured_output":{"segments":[]}}"#).isEmpty)
    }

    @Test func failedStatusThrows() {
        #expect(throws: AgyError.failed("quota exceeded")) {
            try AgyOutputParser.segments(from: #"{"status":"ERROR","error":"quota exceeded"}"#)
        }
        #expect(throws: AgyError.notSignedIn) {
            try AgyOutputParser.segments(from: #"{"status":"ERROR","error":"Please sign in to continue"}"#)
        }
    }

    @Test func proseWithoutJSONThrows() {
        #expect(throws: AgyError.self) {
            try AgyOutputParser.segments(from: "I can't hear audio files, sorry.")
        }
    }

    @Test(arguments: [
        ("12", 12.0), ("12.5s", 12.5), ("1:02.5", 62.5), ("01:02:03", 3723.0), ("00:00:01,250", 1.25),
    ])
    func parsesTimeStrings(text: String, seconds: Double) {
        #expect(AgyOutputParser.seconds(from: text) == seconds)
    }

    @Test(arguments: ["", "abc", "1:2:3:4", "-5"])
    func rejectsBadTimeStrings(text: String) {
        #expect(AgyOutputParser.seconds(from: text) == nil)
    }
}

/// Runs the real `AgyEngine` and `ProcessRunner` against small shell scripts
/// that behave like `agy`: success, signed out, errors and hangs.
@Suite(.timeLimit(.minutes(1)))
struct AgyEngineProcessTests {

    @Test func transcribeRunsAgyInTheChunkFolderAndParsesTheReply() async throws {
        let fake = try FakeAgy(#"""
        for arg in "$@"; do printf '%s\0' "$arg"; done > "$LOG/args"
        ls > "$LOG/files"
        echo '{"status":"SUCCESS","structured_output":{"segments":[{"start":0.25,"end":1,"text":"Hi."}]}}'
        """#)
        defer { fake.remove() }
        let audio = fake.directory.appending(path: "work/chunk-7.m4a")
        try FileManager.default.createDirectory(at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0]).write(to: audio)

        let engine = AgyEngine(executable: fake.url)
        let segments = try await engine.transcribe(audio: audio, duration: 30, model: "gemini-3.5-flash-lite", context: "Swift")
        #expect(segments == [TranscriptSegment(start: 0.25, end: 1, text: "Hi.")])

        let arguments = try fake.log("args").split(separator: "\0").map(String.init)
        #expect(arguments.contains("gemini-3.5-flash-lite"))
        #expect(arguments.contains { $0.contains("@chunk-7.m4a") && $0.contains("Swift") })
        #expect(try fake.log("files").contains("chunk-7.m4a"), "agy must run in the folder holding the chunk")
    }

    @Test func statusListsOnlyCatalogModelsFromAgyModels() async throws {
        let fake = try FakeAgy(#"""
        [ "$1" = "models" ] || exit 2
        printf 'claude-sonnet-5-5\ngemini-3.8-flash-high\ngemini-3.8-flash-low\n'
        """#)
        defer { fake.remove() }
        let expected = [try ExpectedCatalog.model(ExpectedCatalog.low), try ExpectedCatalog.model(ExpectedCatalog.high)]
        let status = await AgyEngine(executable: fake.url).checkStatus()
        #expect(status == .ready(expected))
    }

    @Test func signedOutAgyIsReportedAsNotSignedIn() async throws {
        let fake = try FakeAgy(#"""
        echo "Error: not signed in. Run agy to sign in with Google." >&2
        exit 1
        """#)
        defer { fake.remove() }
        let engine = AgyEngine(executable: fake.url)
        #expect(await engine.checkStatus() == .notSignedIn)
        await #expect(throws: AgyError.notSignedIn) {
            try await engine.transcribe(audio: fake.url, duration: 1, model: "m", context: "")
        }
    }

    @Test func otherFailuresCarryTheErrorText() async throws {
        let fake = try FakeAgy(#"""
        echo "model gemini-x is not available" >&2
        exit 3
        """#)
        defer { fake.remove() }
        await #expect(throws: AgyError.failed("model gemini-x is not available")) {
            try await AgyEngine(executable: fake.url).transcribe(audio: fake.url, duration: 1, model: "gemini-x", context: "")
        }
    }

    @Test func aHungAgyTimesOut() async throws {
        let fake = try FakeAgy("sleep 30")
        defer { fake.remove() }
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: ProcessRunnerError.timedOut) {
            try await ProcessRunner.run(fake.url, arguments: [], timeout: .milliseconds(300))
        }
        #expect(clock.now - start < .seconds(5))
    }

    @Test func cancellingStopsTheProcess() async throws {
        let fake = try FakeAgy(#"""
        echo $$ > "$LOG/pid"
        sleep 30
        """#)
        defer { fake.remove() }
        let run = Task { try await ProcessRunner.run(fake.url, arguments: [], timeout: .seconds(60)) }
        let pidFile = fake.directory.appending(path: "pid")
        #expect(await waitUntil(timeout: .seconds(5)) { FileManager.default.fileExists(atPath: pidFile.path) })
        run.cancel()
        await #expect(throws: CancellationError.self) { try await run.value }

        let pid = try #require(Int32(fake.log("pid").trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(await waitUntil(timeout: .seconds(5)) { kill(pid, 0) != 0 }, "agy should be terminated on cancel")
    }

    @Test func largeOutputDoesNotBlock() async throws {
        // Far more than a pipe buffer (64 KB): output goes to files, so this can't deadlock.
        let fake = try FakeAgy("head -c 2000000 /dev/zero | tr '\\0' 'a'")
        defer { fake.remove() }
        let output = try await ProcessRunner.run(fake.url, arguments: [], timeout: .seconds(20))
        #expect(output.status == 0)
        #expect(output.stdout.count == 2_000_000)
    }
}

/// A throwaway executable standing in for `agy`. `$LOG` is its folder, for recording what it saw.
struct FakeAgy {
    let directory: URL
    let url: URL

    init(_ body: String) throws {
        directory = makeTemporaryDirectory("fake-agy")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appending(path: "agy")
        let script = "#!/bin/sh\nLOG='\(directory.path)'\n\(body)\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func log(_ name: String) throws -> String {
        try String(contentsOf: directory.appending(path: name), encoding: .utf8)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
