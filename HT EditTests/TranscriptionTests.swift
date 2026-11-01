//
//  TranscriptionTests.swift
//  HT EditTests
//
//  Speech-to-text plumbing that doesn't need a downloaded model: the model
//  rules, engine-output cleanup, timeline placement and audio extraction.
//

import Foundation
import Testing
@testable import HT_Edit

struct SpeechModelCatalogTests {

    @Test func keepsOnlyArabicCapableWhisperModels() {
        let all = [
            "openai_whisper-tiny", "openai_whisper-tiny.en",
            "openai_whisper-base", "openai_whisper-base.en",
            "openai_whisper-small", "openai_whisper-small.en", "openai_whisper-small.en_217MB", "openai_whisper-small_216MB",
            "openai_whisper-medium", "openai_whisper-medium.en",
            "openai_whisper-large-v3", "openai_whisper-large-v3_turbo", "openai_whisper-large-v3-v20240930_626MB",
            "distil-whisper_distil-large-v3", "distil-whisper_distil-large-v3_turbo_600MB",
        ]
        #expect(SpeechModelCatalog.arabicCapable(all) == [
            "openai_whisper-tiny",
            "openai_whisper-base",
            "openai_whisper-small", "openai_whisper-small_216MB",
            "openai_whisper-medium",
            "openai_whisper-large-v3", "openai_whisper-large-v3_turbo", "openai_whisper-large-v3-v20240930_626MB",
        ])
    }

    @Test func describesVariants() {
        let small = SpeechModelCatalog.describe(whisperVariant: "openai_whisper-small")
        #expect(small.name == "Whisper Small")
        #expect(small.sizeMB == 486)

        let turbo = SpeechModelCatalog.describe(whisperVariant: "openai_whisper-large-v3-v20240930_626MB")
        #expect(turbo.name == "Whisper Large v3 Turbo – 626 MB")
        #expect(turbo.sizeMB == 626)

        let build = SpeechModelCatalog.describe(whisperVariant: "openai_whisper-large-v3_turbo_954MB")
        #expect(build.name == "Whisper Large v3 (Turbo build) – 954 MB")
        #expect(build.sizeMB == 954)
    }

    @Test func modelIDsIncludeTheEngine() {
        let model = SpeechModelCatalog.whisperModel(variant: "openai_whisper-small")
        #expect(model.id == "whisperKit:openai_whisper-small")
    }
}

struct TranscriptTimelineTests {

    @Test func cleansWhisperSpecialTokens() {
        #expect(TranscriptTimeline.clean("<|startoftranscript|><|ar|><|0.00|> مرحبا بكم <|2.40|><|endoftext|>") == "مرحبا بكم")
    }

    @Test func buildsSegmentsAndDropsEmptyWords() throws {
        let segment = try #require(TranscriptTimeline.segment(
            text: " مرحبا بكم<|endoftext|>",
            start: 1,
            end: 2.5,
            words: [(" مرحبا", 1, 1.6), ("<|endoftext|>", 2.5, 2.5), (" بكم", 1.7, 2.4)]
        ))
        #expect(segment.text == "مرحبا بكم")
        #expect(segment.words == [
            TranscriptWord(text: "مرحبا", start: 1, end: 1.6),
            TranscriptWord(text: "بكم", start: 1.7, end: 2.4),
        ])
        #expect(TranscriptTimeline.segment(text: "<|endoftext|>", start: 0, end: 1, words: []) == nil)
    }

    @Test func shiftsSegmentsToTheirClipsTimelinePosition() {
        let first = UUID(), second = UUID()
        let segment = TranscriptSegment(text: "نص", start: 1, end: 2, words: [TranscriptWord(text: "نص", start: 1, end: 2)])
        let lines = TranscriptTimeline.lines(
            clips: [(id: first, duration: 5), (id: second, duration: 3)],
            segments: [first: [segment], second: [segment]]
        )
        #expect(lines.map(\.clipID) == [first, second])
        #expect(lines.map(\.segment.start) == [1, 6])
        #expect(lines[1].segment.words.first?.end == 7)
        #expect(TranscriptTimeline.lineIndex(at: 6.5, in: lines) == 1)
        #expect(TranscriptTimeline.lineIndex(at: 4, in: lines) == nil)
    }

    @Test func wordLinksRoundTrip() throws {
        let url = try #require(TranscriptLink.url(seconds: 12.34))
        #expect(TranscriptLink.seconds(from: url) == 12.34)
        #expect(TranscriptLink.seconds(from: URL(string: "https://example.com")!) == nil)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct SpeechAudioExtractorTests {

    @Test func decodesSixteenKilohertzMono() async throws {
        let directory = makeTemporaryDirectory("speech-audio")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await MediaFixtures.make(.h264Landscape, in: directory, duration: 2)

        let samples = try await SpeechAudioExtractor.samples(from: url, limiter: ReaderLimiter(limit: 1))
        // 2 s at 16 kHz, give or take encoder priming.
        #expect(abs(samples.count - 32_000) < 1_600, "got \(samples.count) samples")
        #expect(samples.contains { $0 != 0 })
    }

    @Test func writtenAudioFileHasAllSamples() throws {
        let directory = makeTemporaryDirectory("speech-audio-file")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "speech.caf")
        try SpeechAudioExtractor.writeAudioFile(Array(repeating: 0.25, count: 16_000), to: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        #expect((attributes[.size] as? Int ?? 0) >= 16_000 * MemoryLayout<Float>.size)
    }
}
