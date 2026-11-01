//
//  TranscriptionEngine.swift
//  HT Edit
//

import AVFoundation
import CoreMedia
import Speech
import WhisperKit

/// A local speech-to-text engine. Transcribes files one after another and
/// streams each file's segments as soon as it's done.
nonisolated protocol TranscriptionEngine: Sendable {
    func transcribe(_ files: [URL]) -> AsyncThrowingStream<ClipTranscript, any Error>
}

nonisolated enum TranscriptionStream {
    /// Runs `body` off the main actor; dropping the stream cancels it.
    static func make(
        _ body: @escaping @Sendable (_ emit: @escaping @Sendable (ClipTranscript) -> Void) async throws -> Void
    ) -> AsyncThrowingStream<ClipTranscript, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try await body { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - WhisperKit

/// Whisper (Core ML) through WhisperKit, forced to Arabic, with word timestamps.
///
/// The `WhisperKit` object isn't Sendable, so it only ever lives inside one
/// `@concurrent` call: it's loaded, used for every file and released there.
nonisolated struct WhisperKitEngine: TranscriptionEngine {
    /// Folder of one downloaded model variant.
    let modelFolder: URL
    /// Download base; the tokenizer is cached here so later runs are offline.
    let tokenizerFolder: URL

    static let language = "ar"

    static var decodingOptions: DecodingOptions {
        DecodingOptions(
            task: .transcribe,
            language: language,
            temperatureFallbackCount: 3,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: true,
            chunkingStrategy: .vad
        )
    }

    func transcribe(_ files: [URL]) -> AsyncThrowingStream<ClipTranscript, any Error> {
        let engine = self
        return TranscriptionStream.make { emit in
            try await engine.run(files, emit: emit)
        }
    }

    /// Loads the model once: fetches its tokenizer and lets Core ML compile it
    /// for this Mac, so the first transcription starts quickly and offline.
    @concurrent
    func prepare() async throws {
        let kit = try await loadKit()
        await kit.unloadModels()
    }

    @concurrent
    private func run(_ files: [URL], emit: @Sendable (ClipTranscript) -> Void) async throws {
        let kit = try await loadKit()
        for (index, url) in files.enumerated() {
            try Task.checkCancellation()
            let samples: [Float]
            do {
                samples = try await SpeechAudioExtractor.samples(from: url)
            } catch AnalysisError.noAudioTrack {
                emit(ClipTranscript(index: index, segments: []))
                continue
            }
            guard !samples.isEmpty else {
                emit(ClipTranscript(index: index, segments: []))
                continue
            }
            let results = try await kit.transcribe(audioArray: samples, decodeOptions: Self.decodingOptions)
            try Task.checkCancellation()
            let segments = results
                .flatMap(\.segments)
                .compactMap { segment in
                    TranscriptTimeline.segment(
                        text: segment.text,
                        start: Double(segment.start),
                        end: Double(segment.end),
                        words: (segment.words ?? []).map { (text: $0.word, start: Double($0.start), end: Double($0.end)) }
                    )
                }
                .sorted { $0.start < $1.start }
            emit(ClipTranscript(index: index, segments: segments))
        }
        await kit.unloadModels()
    }

    @concurrent
    private func loadKit() async throws -> WhisperKit {
        let config = WhisperKitConfig(
            modelFolder: modelFolder.path(percentEncoded: false),
            tokenizerFolder: tokenizerFolder,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: false
        )
        return try await WhisperKit(config)
    }
}

// MARK: - Apple Speech

/// Apple's on-device `SpeechTranscriber` (Speech framework), with word time ranges.
nonisolated struct AppleSpeechEngine: TranscriptionEngine {
    let locale: Locale

    /// The configuration used both to install assets and to transcribe, so the
    /// installed assets always match.
    static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
    }

    func transcribe(_ files: [URL]) -> AsyncThrowingStream<ClipTranscript, any Error> {
        let engine = self
        return TranscriptionStream.make { emit in
            try await engine.run(files, emit: emit)
        }
    }

    @concurrent
    private func run(_ files: [URL], emit: @Sendable (ClipTranscript) -> Void) async throws {
        for (index, url) in files.enumerated() {
            try Task.checkCancellation()
            let segments: [TranscriptSegment]
            do {
                segments = try await transcribe(samples: SpeechAudioExtractor.samples(from: url))
            } catch AnalysisError.noAudioTrack {
                segments = []
            }
            emit(ClipTranscript(index: index, segments: segments))
        }
    }

    @concurrent
    private func transcribe(samples: [Float]) async throws -> [TranscriptSegment] {
        guard !samples.isEmpty else { return [] }
        let fileURL = URL.temporaryDirectory.appending(path: "htedit-speech-\(UUID().uuidString).caf")
        try SpeechAudioExtractor.writeAudioFile(samples, to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let transcriber = Self.makeTranscriber(locale: locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () async throws -> [TranscriptSegment] in
            var segments: [TranscriptSegment] = []
            for try await result in transcriber.results {
                if let segment = Self.segment(from: result) {
                    segments.append(segment)
                }
            }
            return segments
        }

        do {
            let audioFile = try AVAudioFile(forReading: fileURL)
            if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            collector.cancel()
            throw error
        }
        return try await collector.value
    }

    private static func segment(from result: SpeechTranscriber.Result) -> TranscriptSegment? {
        var words: [(text: String, start: Double, end: Double)] = []
        for run in result.text.runs {
            guard let range = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] else { continue }
            let word = String(result.text[run.range].characters)
            words.append((text: word, start: range.start.seconds, end: range.end.seconds))
        }
        return TranscriptTimeline.segment(
            text: String(result.text.characters),
            start: result.range.start.seconds,
            end: result.range.end.seconds,
            words: words
        )
    }
}
