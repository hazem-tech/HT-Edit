//
//  AgyCleanerTests.swift
//  HT EditTests
//

import Foundation
import Testing
@testable import HT_Edit

struct AgyCommandTests {

    private let lines: [(id: Int, line: CleanupLine)] = [(0, CleanupLine("لو انت مهتم قوي بالخصوصية")), (1, CleanupLine("هذا هو الوضع الخافي", alternative: "ده هو الوضع الخافي"))]

    @Test func cleanupCommandIsHeadlessJSONWithTheChosenModel() throws {
        let arguments = AgyCommand.cleanup(lines: lines, reference: "", model: "gemini-3.8-flash-low", context: "", timeout: .seconds(300))
        #expect(arguments.first == "-p")
        #expect(value(after: "--output-format", in: arguments) == "json")
        #expect(value(after: "--model", in: arguments) == "gemini-3.8-flash-low")
        #expect(value(after: "--print-timeout", in: arguments) == "300s")
        let schema = try #require(value(after: "--json-schema", in: arguments))
        #expect((try? JSONSerialization.jsonObject(with: Data(schema.utf8))) != nil, "Schema must be valid JSON")
    }

    @Test func promptCarriesTheLinesAndTheRulesThatProtectTheSpeech() {
        let prompt = AgyCommand.prompt(lines: lines, reference: "", context: "  \n ")
        #expect(prompt.contains(#""text":"لو انت مهتم قوي بالخصوصية""#) && prompt.contains(#""id":1"#))
        #expect(prompt.contains("keep that dialect"))
        #expect(prompt.contains("Never drop"))
        #expect(!prompt.contains("Context from the user"))
        #expect(!prompt.contains("for reference only"))
        #expect(prompt.contains(#""alt":"ده هو الوضع الخافي""#), "the second reading goes with its line")
        #expect(prompt.contains("second recognition"))
        #expect(!prompt.contains("@"), "cleanup never attaches files")

        let withContext = AgyCommand.prompt(lines: lines, reference: "all of it", context: "ChatGPT, الوضع الخفي")
        #expect(withContext.contains("Context from the user"))
        #expect(withContext.contains("ChatGPT, الوضع الخفي"))
        #expect(withContext.contains("all of it"))
    }

    @Test func defaultInstructionsStartThePromptAndEditedOnesReplaceThem() throws {
        let standard = AgyCommand.prompt(lines: lines, reference: "", context: "")
        #expect(standard.hasPrefix(CleanupInstructions.defaultText + "\n"))

        let custom = AgyCommand.prompt(lines: lines, reference: "", context: "", instructions: "Fix spelling only.")
        #expect(custom.hasPrefix("Fix spelling only.\n"))
        #expect(!custom.contains("Rules:"))
        #expect(custom.contains("Lines to proofread (JSON)"), "lines and reply format are always added")
        #expect(custom.contains("Reply only with JSON"))
    }

    @Test func savedInstructionsWinAndEmptyOnesFallBackToTheDefault() throws {
        let defaults = try #require(UserDefaults(suiteName: "instructions-\(UUID().uuidString)"))
        #expect(CleanupInstructions.current(defaults) == CleanupInstructions.defaultText)
        defaults.set("  Keep it Egyptian.  ", forKey: CleanupInstructions.defaultsKey)
        #expect(CleanupInstructions.current(defaults) == "Keep it Egyptian.")
        defaults.set("   \n ", forKey: CleanupInstructions.defaultsKey)
        #expect(CleanupInstructions.current(defaults) == CleanupInstructions.defaultText)
        #expect(CleanupInstructions.current(nil) == CleanupInstructions.defaultText)
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}

struct AgyOutputParserTests {

    private let expected = [AgyOutputParser.Line(id: 0, text: "على ChatGPT")]

    @Test func readsStructuredOutput() throws {
        let stdout = #"{"conversation_id":"c1","status":"SUCCESS","response":"","structured_output":{"lines":[{"id":0,"text":"على ChatGPT"}]},"usage":{}}"#
        #expect(try AgyOutputParser.lines(from: stdout) == expected)
    }

    @Test(arguments: [
        #"{"status":"SUCCESS","response":"{\"lines\":[{\"id\":0,\"text\":\"على ChatGPT\"}]}"}"#,
        #"{"status":"SUCCESS","response":"Here you go:\n```json\n[{\"id\":0,\"text\":\"على ChatGPT\"}]\n```"}"#,
        #"[{"id":0,"text":"على ChatGPT"}]"#,
    ])
    func readsTextRepliesInCommonShapes(stdout: String) throws {
        #expect(try AgyOutputParser.lines(from: stdout) == expected)
    }

    @Test func failedStatusThrows() {
        #expect(throws: AgyError.failed("quota exceeded")) {
            try AgyOutputParser.lines(from: #"{"status":"ERROR","error":"quota exceeded"}"#)
        }
        #expect(throws: AgyError.notSignedIn) {
            try AgyOutputParser.lines(from: #"{"status":"ERROR","error":"Please sign in to continue"}"#)
        }
    }

    @Test func proseWithoutJSONThrows() {
        #expect(throws: AgyError.self) {
            try AgyOutputParser.lines(from: "Sorry, I can't help with that.")
        }
    }
}

struct CleanupGuardTests {

    @Test func acceptsWordFixes() {
        #expect(CleanupGuard.accept(original: "على شاتي بيتي", corrected: "على ChatGPT") == "على ChatGPT")
        #expect(CleanupGuard.accept(original: "الزاكرة بتاعته ساعات تبقى حلوة", corrected: "الذاكرة بتاعته ساعات تبقى حلوة") == "الذاكرة بتاعته ساعات تبقى حلوة")
    }

    @Test func keepsTheOriginalWhenWordsAreDroppedOrAdded() {
        let original = "دي حاجة لازم تعملها كل مرة تتكلم مع شاتي بيتي كل مرة"
        #expect(CleanupGuard.accept(original: original, corrected: "يجب أن تفعل ذلك") == nil, "summarized")
        #expect(CleanupGuard.accept(original: "بدل ما تدوس", corrected: "بدلاً من أن تضغط على الزر الموجود في الأسفل") == nil, "padded")
    }

    @Test func keepsTheOriginalForEmptyOrUnchangedReplies() {
        #expect(CleanupGuard.accept(original: "تمام", corrected: nil) == nil)
        #expect(CleanupGuard.accept(original: "تمام", corrected: "   ") == nil)
        #expect(CleanupGuard.accept(original: "تمام", corrected: "تمام") == nil)
    }
}

/// Runs the real `AgyCleaner` and `ProcessRunner` against small shell scripts
/// that behave like `agy`: success, signed out, errors and hangs.
@Suite(.timeLimit(.minutes(1)))
struct AgyCleanerProcessTests {

    @Test func cleanRunsAgyWithTheLinesAndKeepsGuardedReplies() async throws {
        let fake = try FakeAgy(#"""
        for arg in "$@"; do printf '%s\0' "$arg"; done > "$LOG/args"
        ls -A > "$LOG/files"
        echo '{"status":"SUCCESS","structured_output":{"lines":[{"id":0,"text":"على ChatGPT"},{"id":1,"text":"تم"}]}}'
        """#)
        defer { fake.remove() }

        let cleaner = AgyCleaner(executable: fake.url)
        let result = try await cleaner.clean(["على شاتي بيتي", "الوضع الخافي ده هو", "بس كده"].map { CleanupLine($0) }, model: "gemini-x", context: "ChatGPT")
        #expect(result == ["على ChatGPT", nil, nil], "line 1 lost words, line 2 wasn't returned")

        let arguments = try fake.log("args").split(separator: "\0").map(String.init)
        #expect(arguments.contains("gemini-x"))
        #expect(arguments.contains { $0.contains("على شاتي بيتي") && $0.contains("ChatGPT") })
        #expect(try fake.log("files").isEmpty, "agy runs in an empty folder")
    }

    @Test func statusListsOnlyCatalogModelsFromAgyModels() async throws {
        let first = TranscriptionModel.catalog[0], last = TranscriptionModel.catalog[TranscriptionModel.catalog.count - 1]
        let fake = try FakeAgy("""
        [ "$1" = "models" ] || exit 2
        printf 'claude-sonnet-5-5\n\(last.id)\n\(first.id)\n'
        """)
        defer { fake.remove() }
        let status = await AgyCleaner(executable: fake.url).checkStatus()
        #expect(status == .ready([first, last]))
    }

    @Test func signedOutAgyIsReportedAsNotSignedIn() async throws {
        let fake = try FakeAgy(#"""
        echo "Error: not signed in. Run agy to sign in with Google." >&2
        exit 1
        """#)
        defer { fake.remove() }
        let cleaner = AgyCleaner(executable: fake.url)
        #expect(await cleaner.checkStatus() == .notSignedIn)
        await #expect(throws: AgyError.notSignedIn) {
            try await cleaner.clean([CleanupLine("x")], model: "m", context: "")
        }
    }

    @Test func otherFailuresCarryTheErrorText() async throws {
        let fake = try FakeAgy(#"""
        echo "model gemini-x is not available" >&2
        exit 3
        """#)
        defer { fake.remove() }
        await #expect(throws: AgyError.failed("model gemini-x is not available")) {
            try await AgyCleaner(executable: fake.url).clean([CleanupLine("x")], model: "gemini-x", context: "")
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
