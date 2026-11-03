//
//  AgyEngine.swift
//  HT Edit
//
//  Transcribes audio with the user's own Antigravity CLI (`agy`): it runs under
//  their Google sign-in and subscription, so HT Edit holds no API key and pays
//  nothing per call. `scripts/agy-probe.sh` runs the same command by hand.
//

import Foundation
import os

/// Whether transcription can run, as far as the engine can tell.
nonisolated enum EngineStatus: Equatable, Sendable {
    case unknown
    case checking
    /// Ready, with the models the picker should offer (cheapest first).
    case ready([TranscriptionModel])
    case notInstalled
    case notSignedIn
    case failed(String)
}

/// Turns one audio file into timed segments (seconds from the start of that file).
nonisolated protocol TranscriptionEngine: Sendable {
    func checkStatus() async -> EngineStatus
    func transcribe(audio: URL, duration: Double, model: String, context: String) async throws -> [TranscriptSegment]
}

nonisolated enum AgyError: LocalizedError, Equatable {
    case notInstalled
    case notSignedIn
    case timedOut
    case failed(String)
    case invalidOutput(String)

    /// Errors that will fail every chunk the same way: stop instead of retrying.
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
        case .invalidOutput(let excerpt): "Antigravity returned something that isn't a transcript: \(excerpt)"
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

// MARK: - Command

/// The exact `agy` invocations HT Edit makes (kept in sync with `scripts/agy-probe.sh`).
nonisolated enum AgyCommand {
    static let listModels = ["models"]

    /// JSON Schema for the answer, passed with `--json-schema` so the reply
    /// comes back as structured output instead of free text.
    static let transcriptSchema = #"{"type":"object","properties":{"segments":{"type":"array","items":{"type":"object","properties":{"start":{"type":"number"},"end":{"type":"number"},"text":{"type":"string"}},"required":["start","end","text"]}}},"required":["segments"]}"#

    /// Headless transcription of `fileName`, which must be in the working directory.
    static func transcribe(fileName: String, duration: Double, model: String, context: String, timeout: Duration) -> [String] {
        [
            "-p", prompt(fileName: fileName, duration: duration, context: context),
            "--output-format", "json",
            "--json-schema", transcriptSchema,
            "--model", model,
            "--print-timeout", "\(Int(timeout.components.seconds))s",
        ]
    }

    static func prompt(fileName: String, duration: Double, context: String) -> String {
        var lines = [
            "Transcribe the speech in the audio file @\(fileName) verbatim, in the language that is spoken.",
            "The file is \(String(format: "%.1f", duration)) seconds long.",
            "Split the speech into short segments at sentence or phrase boundaries, each at most about 10 seconds.",
            "For each segment give start and end in seconds from the beginning of this file, and the text.",
            "If there is no speech, return an empty list.",
            "Only read that file: don't run commands or change any files.",
        ]
        let context = context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !context.isEmpty {
            lines.append("Context from the user, to get names, terms and spellings right: \(context)")
        }
        lines.append(#"Reply only with JSON of the form {"segments":[{"start":0.0,"end":2.5,"text":"..."}]}."#)
        return lines.joined(separator: "\n")
    }
}

// MARK: - Output

/// Reads `agy --output-format json` output, and tolerates the model replying
/// in plain text (with or without a code fence) when structured output isn't used.
nonisolated enum AgyOutputParser {
    static func segments(from stdout: String) throws -> [TranscriptSegment] {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(trimmed.utf8)) {
            if let status = envelope.status, status.uppercased() != "SUCCESS" {
                let reason = envelope.error ?? envelope.response ?? status
                throw AgyError.looksLikeSignInProblem(reason) ? AgyError.notSignedIn : AgyError.failed(reason)
            }
            if let structured = envelope.structuredOutput { return structured.segments }
            if let response = envelope.response { return try segments(fromText: response) }
        }
        return try segments(fromText: trimmed)
    }

    /// Finds the JSON in a model reply: `{"segments": [...]}` or a bare `[...]`.
    static func segments(fromText text: String) throws -> [TranscriptSegment] {
        let decoder = JSONDecoder()
        for opener in ["{", "["] {
            guard let start = text.firstIndex(of: Character(opener)),
                  let end = text.lastIndex(of: opener == "{" ? "}" : "]"), start < end else { continue }
            let data = Data(text[start...end].utf8)
            if let list = try? decoder.decode(SegmentList.self, from: data) { return list.segments }
            if let array = try? decoder.decode([RawSegment].self, from: data) { return array.map(\.segment) }
        }
        throw AgyError.invalidOutput(String(text.prefix(200)))
    }

    private struct Envelope: Decodable {
        var status: String?
        var response: String?
        var error: String?
        var structuredOutput: SegmentList?

        enum CodingKeys: String, CodingKey {
            case status, response, error
            case structuredOutput = "structured_output"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try? container.decode(String.self, forKey: .status)
            response = try? container.decode(String.self, forKey: .response)
            error = try? container.decode(String.self, forKey: .error)
            structuredOutput = try? container.decode(SegmentList.self, forKey: .structuredOutput)
            guard status != nil || response != nil || structuredOutput != nil else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Not an agy envelope"))
            }
        }
    }

    private struct SegmentList: Decodable {
        var segments: [TranscriptSegment]

        enum CodingKeys: String, CodingKey { case segments }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            segments = try container.decode([RawSegment].self, forKey: .segments).map(\.segment)
        }
    }

    /// A segment whose times may be numbers or strings like `"1:02.5"`, `"00:01:02,500"` or `"62.5s"`.
    private struct RawSegment: Decodable {
        var segment: TranscriptSegment

        enum CodingKeys: String, CodingKey { case start, end, text }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func seconds(_ key: CodingKeys) throws -> Double {
                if let value = try? container.decode(Double.self, forKey: key) { return value }
                let string = try container.decode(String.self, forKey: key)
                guard let value = AgyOutputParser.seconds(from: string) else {
                    throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "Bad time \(string)")
                }
                return value
            }
            segment = TranscriptSegment(
                start: try seconds(.start),
                end: try seconds(.end),
                text: try container.decode(String.self, forKey: .text)
            )
        }
    }

    /// Parses `"62.5"`, `"62.5s"`, `"1:02.5"` and `"00:01:02,500"` into seconds.
    static func seconds(from string: String) -> Double? {
        var text = string.trimmingCharacters(in: .whitespaces).replacing(",", with: ".")
        if text.hasSuffix("s") { text.removeLast() }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return total
    }
}

// MARK: - Engine

/// Runs the installed `agy`. Finding it is cached; everything else runs per call.
actor AgyEngine: TranscriptionEngine {
    /// Where to look when `agy` isn't on the login shell's `PATH`. The installer uses `~/.local/bin`.
    nonisolated static let candidateDirectories = [
        URL.homeDirectory.appending(path: ".local/bin", directoryHint: .isDirectory),
        URL(filePath: "/opt/homebrew/bin", directoryHint: .isDirectory),
        URL(filePath: "/usr/local/bin", directoryHint: .isDirectory),
    ]

    private let fixedExecutable: URL?
    private let chunkTimeout: Duration
    private var located: URL?

    /// - Parameter executable: a specific `agy` to run (tests); `nil` finds the installed one.
    init(executable: URL? = nil, chunkTimeout: Duration = .seconds(300)) {
        self.fixedExecutable = executable
        self.chunkTimeout = chunkTimeout
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
            // An unrecognized list format shouldn't block transcription: offer the whole catalog.
            return .ready(models.isEmpty ? TranscriptionModel.catalog : models)
        } catch {
            return .failed("agy didn't answer. If you haven't signed in yet, run agy in Terminal once.")
        }
    }

    func transcribe(audio: URL, duration: Double, model: String, context: String) async throws -> [TranscriptSegment] {
        guard let agy = await executable() else { throw AgyError.notInstalled }
        let arguments = AgyCommand.transcribe(
            fileName: audio.lastPathComponent, duration: duration, model: model, context: context, timeout: chunkTimeout
        )
        let output: ProcessOutput
        do {
            output = try await ProcessRunner.run(
                agy,
                arguments: arguments,
                currentDirectory: audio.deletingLastPathComponent(),
                environment: environment(for: agy),
                timeout: chunkTimeout + .seconds(30)
            )
        } catch ProcessRunnerError.timedOut {
            throw AgyError.timedOut
        }
        guard output.status == 0 else { throw AgyError.from(output) }
        return try AgyOutputParser.segments(from: output.stdout)
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
