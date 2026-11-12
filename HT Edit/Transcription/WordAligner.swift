//
//  WordAligner.swift
//  HT Edit
//
//  Measures when each word was said. The text comes from the transcription
//  model, which is good at words but only guesses their times. The aligner
//  listens to the audio with the text in hand and finds each word's start
//  and end on the waveform.
//
//  It runs `align.py` (bundled with the app) through the user's `uv`, which
//  installs a private Python and the model on first use. Nothing touches the
//  system Python. `scripts/align-probe.sh` runs the same command by hand.
//

import Foundation
import os

/// Whether word timing can be measured, as far as the aligner can tell.
nonisolated enum WordTimingStatus: Equatable, Sendable {
    case unknown
    case checking
    case ready
    /// `uv` isn't installed: words are spread over each line instead.
    case notInstalled
    case failed(String)
}

/// Adds measured word times to transcript lines.
nonisolated protocol WordAligner: Sendable {
    func checkStatus() async -> WordTimingStatus

    /// `segments` (clip times) of `source`, all inside `chunk`, with `words`
    /// filled in for every line the aligner could place. Lines it couldn't
    /// keep `words == nil`. `scratch` is a folder for temporary files.
    func align(_ segments: [TranscriptSegment], in source: URL, chunk: Range<Double>, scratch: URL) async throws -> [TranscriptSegment]
}

nonisolated enum WordAlignerError: LocalizedError, Equatable {
    case notInstalled
    case scriptMissing
    case timedOut
    case failed(String)
    case invalidOutput(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: "uv isn't installed, so word timing is estimated."
        case .scriptMissing: "The word aligner is missing from the app."
        case .timedOut: "The word aligner didn't finish in time."
        case .failed(let reason): "The word aligner failed: \(reason)"
        case .invalidOutput(let excerpt): "The word aligner returned something unexpected: \(excerpt)"
        }
    }
}

// MARK: - Request and reply

/// What `align.py` reads and prints (see the script's docstring).
nonisolated enum AlignmentProtocol {
    /// Audio around each line that's also given to the aligner, so a line
    /// whose times are a bit off still has all of its words in view.
    static let padding = 1.0

    struct Request: Encodable {
        struct Segment: Encodable {
            var start: Double
            var end: Double
            var words: [String]
        }

        var padding: Double
        var segments: [Segment]
    }

    struct Reply: Decodable {
        struct Segment: Decodable {
            var words: [Word?]
        }

        struct Word: Decodable {
            var start: Double
            var end: Double
        }

        var segments: [Segment?]
    }

    /// The request for `segments` (clip times), with times relative to `chunk`.
    static func request(for segments: [TranscriptSegment], chunk: Range<Double>) -> Request {
        Request(padding: padding, segments: segments.map { segment in
            Request.Segment(
                start: segment.start - chunk.lowerBound,
                end: segment.end - chunk.lowerBound,
                words: TranscriptWords.tokenize(segment.text)
            )
        })
    }

    /// `segments` with the words from `stdout` filled in. Times in the reply
    /// are relative to `chunk`. A line the reply couldn't place, or whose word
    /// count doesn't match, keeps `words == nil`.
    static func apply(_ stdout: String, to segments: [TranscriptSegment], chunk: Range<Double>) throws -> [TranscriptSegment] {
        let json = stdout.split(separator: "\n").last(where: { $0.hasPrefix("{") }).map(String.init) ?? stdout
        guard let reply = try? JSONDecoder().decode(Reply.self, from: Data(json.utf8)),
              reply.segments.count == segments.count else {
            throw WordAlignerError.invalidOutput(String(stdout.prefix(200)))
        }
        return zip(segments, reply.segments).map { segment, aligned in
            var segment = segment
            let words = TranscriptWords.tokenize(segment.text)
            guard let aligned, aligned.words.count == words.count, aligned.words.contains(where: { $0 != nil }) else {
                return segment
            }
            let times = aligned.words.map { word in
                word.map { TranscriptWord(start: chunk.lowerBound + $0.start, end: chunk.lowerBound + $0.end, text: "") }
            }
            segment.words = TranscriptWords.filling(words, times: times, in: segment)
            return segment
        }
    }
}

// MARK: - uv

/// Runs the bundled `align.py` with the installed `uv`, one chunk at a time
/// (each run loads a ~1 GB model; two at once would only compete for memory).
actor UVWordAligner: WordAligner {
    nonisolated static let scriptName = "align"

    private let fixedExecutable: URL?
    private let script: URL?
    private let timeout: Duration
    private let limiter = ReaderLimiter(limit: 1)
    private var located: URL?

    /// - Parameters:
    ///   - executable: a specific `uv` to run (tests); `nil` finds the installed one.
    ///   - script: the aligner script; `nil` uses the one bundled with the app.
    ///   - timeout: per chunk. Generous: the first run downloads Python, PyTorch and the model.
    init(executable: URL? = nil, script: URL? = nil, timeout: Duration = .seconds(30 * 60)) {
        self.fixedExecutable = executable
        self.script = script ?? Bundle.main.url(forResource: Self.scriptName, withExtension: "py")
        self.timeout = timeout
    }

    func checkStatus() async -> WordTimingStatus {
        guard script != nil else { return .failed(WordAlignerError.scriptMissing.localizedDescription) }
        guard let uv = await executable() else { return .notInstalled }
        guard let output = try? await ProcessRunner.run(
            uv, arguments: ["--version"], environment: Self.environment(for: uv), timeout: .seconds(15)
        ), output.status == 0 else {
            return .failed("uv is installed but didn't run.")
        }
        Log.transcription.notice("Word aligner: \(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines), privacy: .public)")
        return .ready
    }

    func align(_ segments: [TranscriptSegment], in source: URL, chunk: Range<Double>, scratch: URL) async throws -> [TranscriptSegment] {
        guard !segments.isEmpty else { return segments }
        guard let script else { throw WordAlignerError.scriptMissing }
        guard let uv = await executable() else { throw WordAlignerError.notInstalled }

        let name = "align-\(UUID().uuidString)"
        let audio = scratch.appending(path: name + ".wav", directoryHint: .notDirectory)
        let request = scratch.appending(path: name + ".json", directoryHint: .notDirectory)
        defer {
            try? FileManager.default.removeItem(at: audio)
            try? FileManager.default.removeItem(at: request)
        }
        try await AudioChunkExporter.exportWAV(source, range: chunk, to: audio)
        try JSONEncoder().encode(AlignmentProtocol.request(for: segments, chunk: chunk)).write(to: request)

        await limiter.acquire()
        let output: ProcessOutput
        do {
            output = try await ProcessRunner.run(
                uv,
                arguments: Self.arguments(script: script, audio: audio, request: request),
                environment: Self.environment(for: uv),
                timeout: timeout
            )
            await limiter.release()
        } catch ProcessRunnerError.timedOut {
            await limiter.release()
            throw WordAlignerError.timedOut
        } catch {
            await limiter.release()
            throw error
        }
        guard output.status == 0 else {
            let message = output.stderr.split(separator: "\n").last.map(String.init) ?? "exit status \(output.status)"
            throw WordAlignerError.failed(String(message.prefix(300)))
        }
        return try AlignmentProtocol.apply(output.stdout, to: segments, chunk: chunk)
    }

    /// The exact command (kept in sync with `scripts/align-probe.sh`).
    nonisolated static func arguments(script: URL, audio: URL, request: URL) -> [String] {
        ["run", "--quiet", "--script", script.path, audio.path, request.path]
    }

    /// `uv` with a Python of its own, never the system's or Homebrew's.
    nonisolated static func environment(for uv: URL) -> [String: String] {
        var environment = ExecutableLocator.environment(for: uv)
        environment["UV_PYTHON_PREFERENCE"] = "only-managed"
        environment["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
        return environment
    }

    private func executable() async -> URL? {
        if let fixedExecutable { return fixedExecutable }
        if let located, FileManager.default.isExecutableFile(atPath: located.path) { return located }
        located = await ExecutableLocator.locate("uv")
        return located
    }
}
