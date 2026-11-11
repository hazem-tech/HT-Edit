//
//  AgyCleaner.swift
//  HT Edit
//
//  Proofreads Whisper's transcript with the user's own Antigravity CLI (`agy`),
//  under their Google sign-in and subscription: no API key, nothing per call.
//  Only text is sent, never audio, and the reply can only change a line's
//  words, never its timing. `scripts/agy-probe.sh` runs the same command by hand.
//

import Foundation
import os

nonisolated enum AgyError: LocalizedError, Equatable, FatalTranscriptionError {
    case notInstalled
    case notSignedIn
    case timedOut
    case failed(String)
    case invalidOutput(String)

    /// Errors that will fail every call the same way: stop instead of retrying.
    var isFatal: Bool {
        switch self {
        case .notInstalled, .notSignedIn: true
        case .timedOut, .failed, .invalidOutput: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .notInstalled: "Antigravity CLI (agy) isn't installed."
        case .notSignedIn: "Antigravity CLI isn't signed in. Run agy in Terminal once to sign in."
        case .timedOut: "Antigravity didn't answer in time."
        case .failed(let reason): "Antigravity failed: \(reason)"
        case .invalidOutput(let excerpt): "Antigravity returned something unexpected: \(excerpt)"
        }
    }

    /// Classifies a non-zero exit from `agy`.
    static func from(_ output: ProcessOutput) -> AgyError {
        let message = [output.stderr, output.stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "exit status \(output.status)"
        return looksLikeSignInProblem(message) ? .notSignedIn : .failed(String(message.prefix(300)))
    }

    static func looksLikeSignInProblem(_ message: String) -> Bool {
        let text = message.lowercased()
        return ["not signed in", "sign in", "signed out", "log in", "login", "not logged in",
                "unauthenticated", "authenticate", "authentication", "credentials", "oauth"]
            .contains { text.contains($0) }
    }
}

// MARK: - Instructions

/// What Gemini is told to do with the transcript. Editable in Settings (⌘,);
/// HT Edit adds the context, the transcript and the reply format around it.
nonisolated enum CleanupInstructions {
    static let defaultsKey = "cleanupInstructions"

    static let defaultText = [
        "You are proofreading an automatic speech-to-text transcript. A speech recognizer wrote each line below; each has an id.",
        "Fix only words the recognizer clearly misheard, using the meaning of the surrounding lines, the whole transcript and the context.",
        "Rules:",
        "- Keep the speaker's own dialect and wording. If they speak a dialect (for example Egyptian Arabic), keep that dialect: never rewrite it into the standard or formal language, and never make it more formal.",
        "- Never drop, summarize, shorten, merge, split, reorder or add anything. Repeated words, false starts and filler stay. Every input line gets exactly one output line with the same id.",
        "- Recognizers often turn dialect into the formal language. When the speaker clearly talks in a dialect, write the dialect words they said instead of formal ones the recognizer substituted (in Egyptian Arabic for example ده not هذا, اللي not الذي, لازم not يجب أن, بدل not بدلاً, التلات not الثلاث, نقط not نقاط), keeping the same number of words.",
        "- When the speaker says an English word or a product name, write it the usual way in Latin letters (for example ChatGPT, Gemini, privacy), even inside an Arabic line.",
        "- If a line is already right, or you aren't sure, return it unchanged.",
        "- Don't run commands, and don't read or change any files.",
    ].joined(separator: "\n")

    /// The saved instructions, or the default when none are saved (or they were cleared).
    static func current(_ defaults: UserDefaults? = .standard) -> String {
        let saved = defaults?.string(forKey: defaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return saved.isEmpty ? defaultText : saved
    }
}

// MARK: - Command

/// The exact `agy` invocations HT Edit makes (kept in sync with `scripts/agy-probe.sh`).
nonisolated enum AgyCommand {
    static let listModels = ["models"]

    /// JSON Schema for the answer, passed with `--json-schema` so the reply
    /// comes back as structured output instead of free text.
    static let cleanupSchema = #"{"type":"object","properties":{"lines":{"type":"array","items":{"type":"object","properties":{"id":{"type":"integer"},"text":{"type":"string"}},"required":["id","text"]}}},"required":["lines"]}"#

    /// Most transcript characters sent as background with each batch, so the
    /// model knows what the whole clip is about.
    static let referenceLimit = 12_000

    static func cleanup(
        lines: [(id: Int, line: CleanupLine)], reference: String, model: String, context: String,
        instructions: String = CleanupInstructions.defaultText, timeout: Duration
    ) -> [String] {
        [
            "-p", prompt(lines: lines, reference: reference, context: context, instructions: instructions),
            "--output-format", "json",
            "--json-schema", cleanupSchema,
            "--model", model,
            "--print-timeout", "\(Int(timeout.components.seconds))s",
        ]
    }

    /// The full prompt: the (editable) instructions, then what HT Edit always adds.
    static func prompt(lines: [(id: Int, line: CleanupLine)], reference: String, context: String, instructions: String = CleanupInstructions.defaultText) -> String {
        let hasAlternatives = lines.contains { $0.line.alternative != nil }
        var parts = [instructions.trimmingCharacters(in: .whitespacesAndNewlines)]
        if hasAlternatives {
            parts.append("Some lines have \"alt\": a second recognition of the same audio made without the context. It is often closer to the speaker's dialect but worse at names and terms. Per word, choose what the speaker most likely said; the output must still cover the whole line.")
        }
        let context = context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !context.isEmpty {
            parts.append("Context from the user (names, terms, spellings, topic): \(context)")
        }
        let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reference.isEmpty {
            parts.append("The whole transcript, for reference only (don't return it):\n\(String(reference.prefix(referenceLimit)))")
        }
        struct Payload: Encodable { var id: Int; var text: String; var alt: String? }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let json = (try? encoder.encode(lines.map { Payload(id: $0.id, text: $0.line.text, alt: $0.line.alternative) }))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        parts.append("Lines to proofread (JSON):\n\(json)")
        parts.append(#"Reply only with JSON of the form {"lines":[{"id":0,"text":"..."}]}."#)
        return parts.joined(separator: "\n")
    }
}

// MARK: - Output

/// Reads `agy --output-format json` output, and tolerates the model replying
/// in plain text (with or without a code fence) when structured output isn't used.
nonisolated enum AgyOutputParser {
    struct Line: Decodable, Equatable, Sendable {
        var id: Int
        var text: String
    }

    static func lines(from stdout: String) throws -> [Line] {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(trimmed.utf8)) {
            if let status = envelope.status, status.uppercased() != "SUCCESS" {
                let reason = envelope.error ?? envelope.response ?? status
                throw AgyError.looksLikeSignInProblem(reason) ? AgyError.notSignedIn : AgyError.failed(reason)
            }
            if let structured = envelope.structuredOutput { return structured.lines }
            if let response = envelope.response { return try lines(fromText: response) }
        }
        return try lines(fromText: trimmed)
    }

    /// Finds the JSON in a model reply: `{"lines": [...]}` or a bare `[...]`.
    static func lines(fromText text: String) throws -> [Line] {
        let decoder = JSONDecoder()
        for opener in ["{", "["] {
            guard let start = text.firstIndex(of: Character(opener)),
                  let end = text.lastIndex(of: opener == "{" ? "}" : "]"), start < end else { continue }
            let data = Data(text[start...end].utf8)
            if let list = try? decoder.decode(LineList.self, from: data) { return list.lines }
            if let array = try? decoder.decode([Line].self, from: data) { return array }
        }
        throw AgyError.invalidOutput(String(text.prefix(200)))
    }

    private struct LineList: Decodable {
        var lines: [Line]
    }

    private struct Envelope: Decodable {
        var status: String?
        var response: String?
        var error: String?
        var structuredOutput: LineList?

        enum CodingKeys: String, CodingKey {
            case status, response, error
            case structuredOutput = "structured_output"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try? container.decode(String.self, forKey: .status)
            response = try? container.decode(String.self, forKey: .response)
            error = try? container.decode(String.self, forKey: .error)
            structuredOutput = try? container.decode(LineList.self, forKey: .structuredOutput)
            guard status != nil || response != nil || structuredOutput != nil else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Not an agy envelope"))
            }
        }
    }
}

// MARK: - Guard

/// Decides whether a proofread line may replace the original. The model is
/// told never to drop or summarize; this enforces it.
nonisolated enum CleanupGuard {
    /// The corrected text, or `nil` to keep the original line.
    static func accept(original: String, corrected: String?) -> String? {
        guard let corrected else { return nil }
        let text = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != original else { return nil }
        let before = wordCount(original), after = wordCount(text)
        // Lost or invented words: allow a little merging ("ال chat" → "الـchat"), no more.
        let lowest = before <= 3 ? before - 1 : Int((Double(before) * 0.7).rounded(.down))
        let highest = before <= 3 ? before + 1 : Int((Double(before) * 1.4).rounded(.up))
        guard after >= max(1, lowest), after <= highest else { return nil }
        return text
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}

// MARK: - Cleaner

/// Runs the installed `agy`. Finding it is cached; everything else runs per call.
actor AgyCleaner: TranscriptCleaner {
    /// Where to look when `agy` isn't on the login shell's `PATH`. The installer uses `~/.local/bin`.
    nonisolated static let candidateDirectories = [
        URL.homeDirectory.appending(path: ".local/bin", directoryHint: .isDirectory),
        URL(filePath: "/opt/homebrew/bin", directoryHint: .isDirectory),
        URL(filePath: "/usr/local/bin", directoryHint: .isDirectory),
    ]

    /// Lines per request: small enough for a quick reply, large enough to keep the call count low.
    nonisolated static let batchSize = 80

    private let fixedExecutable: URL?
    private let timeout: Duration
    private let instructions: @Sendable () -> String
    private var located: URL?

    /// - Parameters:
    ///   - executable: a specific `agy` to run (tests); `nil` finds the installed one.
    ///   - instructions: read at each run, so edits in Settings apply to the next cleanup.
    init(executable: URL? = nil, timeout: Duration = .seconds(300), instructions: @escaping @Sendable () -> String = { CleanupInstructions.current() }) {
        self.fixedExecutable = executable
        self.timeout = timeout
        self.instructions = instructions
    }

    func checkStatus() async -> EngineStatus {
        guard let agy = await executable() else { return .notInstalled }
        do {
            let output = try await ProcessRunner.run(agy, arguments: AgyCommand.listModels, environment: environment(for: agy), timeout: .seconds(30))
            guard output.status == 0 else {
                let error = AgyError.from(output)
                Log.transcription.error("agy models failed: \(error.localizedDescription, privacy: .public)")
                return error == .notSignedIn ? .notSignedIn : .failed(error.localizedDescription)
            }
            let models = TranscriptionModel.available(inModelList: output.stdout)
            Log.transcription.notice("agy models: \(models.map(\.id).joined(separator: ", "), privacy: .public)")
            // An unrecognized list format shouldn't block cleanup: offer the whole catalog.
            return .ready(models.isEmpty ? TranscriptionModel.catalog : models)
        } catch {
            return .failed("agy didn't answer. If you haven't signed in yet, run agy in Terminal once.")
        }
    }

    func clean(_ lines: [CleanupLine], model: String, context: String) async throws -> [String?] {
        guard let agy = await executable() else { throw AgyError.notInstalled }
        guard !lines.isEmpty else { return [] }
        let reference = lines.map(\.text).joined(separator: "\n")
        // agy needs a working folder; give it an empty one so it can't see anything else.
        let folder = FileManager.default.temporaryDirectory.appending(path: "cleanup-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let instructions = instructions()
        var result = [String?](repeating: nil, count: lines.count)
        for batchStart in stride(from: 0, to: lines.count, by: Self.batchSize) {
            try Task.checkCancellation()
            let ids = Array(batchStart..<min(lines.count, batchStart + Self.batchSize))
            let arguments = AgyCommand.cleanup(
                lines: ids.map { ($0, lines[$0]) }, reference: lines.count > ids.count ? reference : "",
                model: model, context: context, instructions: instructions, timeout: timeout
            )
            let reply = try await run(agy, arguments: arguments, in: folder)
            for line in reply where ids.contains(line.id) {
                result[line.id] = CleanupGuard.accept(original: lines[line.id].text, corrected: line.text)
            }
        }
        return result
    }

    private func run(_ agy: URL, arguments: [String], in folder: URL) async throws -> [AgyOutputParser.Line] {
        let output: ProcessOutput
        do {
            output = try await ProcessRunner.run(
                agy, arguments: arguments, currentDirectory: folder,
                environment: environment(for: agy), timeout: timeout + .seconds(30)
            )
        } catch ProcessRunnerError.timedOut {
            throw AgyError.timedOut
        }
        guard output.status == 0 else { throw AgyError.from(output) }
        return try AgyOutputParser.lines(from: output.stdout)
    }

    // MARK: Locating agy

    private func executable() async -> URL? {
        if let fixedExecutable { return fixedExecutable }
        if let located, FileManager.default.isExecutableFile(atPath: located.path) { return located }
        located = await Self.locate()
        return located
    }

    /// Apps launched from the Finder don't get the shell's `PATH`, so check the
    /// usual install folders, then ask the login shell.
    private static func locate() async -> URL? {
        for directory in candidateDirectories {
            let candidate = directory.appending(path: "agy", directoryHint: .notDirectory)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        guard let output = try? await ProcessRunner.run(
            URL(filePath: "/bin/zsh"), arguments: ["-lc", "command -v agy"], timeout: .seconds(5)
        ), output.status == 0,
              let path = output.stdout.split(separator: "\n").last.map(String.init),
              path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(filePath: path)
    }

    /// The app's environment with `agy`'s folder and the usual tool folders on `PATH`.
    private nonisolated func environment(for agy: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let extra = [agy.deletingLastPathComponent().path] + Self.candidateDirectories.map(\.path)
        let existing = environment["PATH"].map { [$0] } ?? ["/usr/bin:/bin:/usr/sbin:/sbin"]
        environment["PATH"] = (extra + existing).joined(separator: ":")
        return environment
    }
}
