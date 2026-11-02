//
//  TranscriptionService.swift
//  HT Edit
//

import AVFoundation
import os

/// One clip to transcribe.
nonisolated struct TranscriptionJob: Sendable, Equatable {
    var clipID: UUID
    var url: URL
    var name: String
    /// Clip length in seconds.
    var duration: Double
    /// The analyzed audio never rises above the speech floor: nothing to send.
    var isSilent = false
}

/// Speech-to-text, the optional text pass and summaries, with every result
/// cached so the same work is never paid for twice.
///
/// Requests per clip: one for speech-to-text (one per 25 minutes for longer
/// clips), plus one for the text pass when the settings call for it. Cached
/// results cost nothing.
nonisolated struct TranscriptionService: Sendable {
    var cache: TranscriptCache = .shared

    /// Gemini accepts up to 30 minutes per request with word timestamps.
    static let chunkDuration = 25.0 * 60
    /// The text pass sends at most this many phrases per request.
    static let phrasesPerTextPass = 800

    // MARK: Transcripts

    /// Phrases from the cache only; never touches the network.
    /// `nil` if this file was never transcribed.
    func cachedPhrases(for job: TranscriptionJob, settings: TranscriptionSettings) async -> [TranscriptPhrase]? {
        guard let wordsKey = TranscriptCache.wordsKey(for: job.url),
              let words = await cache.load([TranscriptWord].self, key: wordsKey) else { return nil }
        let base = TranscriptBuilder.phrases(from: words)
        guard settings.runsTextPass, !base.isEmpty else { return base }
        let key = TranscriptCache.phrasesKey(wordsKey: wordsKey, settings: settings)
        return await cache.load([TranscriptPhrase].self, key: key) ?? base
    }

    /// Phrases for `job`, calling Gemini only for what isn't cached.
    func phrases(for job: TranscriptionJob, settings: TranscriptionSettings, client: GeminiClient) async throws -> [TranscriptPhrase] {
        let wordsKey = TranscriptCache.wordsKey(for: job.url)
        let words: [TranscriptWord]
        if let wordsKey, let cached = await cache.load([TranscriptWord].self, key: wordsKey) {
            words = cached
        } else {
            words = try await transcribe(job, client: client)
            if let wordsKey { await cache.store(words, key: wordsKey) }
        }

        let base = TranscriptBuilder.phrases(from: words)
        guard settings.runsTextPass, !base.isEmpty else { return base }

        let identity = wordsKey ?? TranscriptCache.hash(words.map(\.text).joined(separator: " "))
        let key = TranscriptCache.phrasesKey(wordsKey: identity, settings: settings)
        if let cached = await cache.load([TranscriptPhrase].self, key: key) { return cached }
        let polished = try await polish(base, settings: settings, client: client)
        await cache.store(polished, key: key)
        return polished
    }

    private func transcribe(_ job: TranscriptionJob, client: GeminiClient) async throws -> [TranscriptWord] {
        guard !job.isSilent else {
            Log.transcription.notice("\(job.name, privacy: .public): silent, nothing to transcribe")
            return []
        }
        do {
            var words: [TranscriptWord] = []
            for range in Self.chunks(duration: job.duration) {
                let audio = try await AudioExtractor.extract(url: job.url, timeRange: range)
                let offset = range?.start.seconds ?? 0
                Log.transcription.notice("\(job.name, privacy: .public): sending \(audio.count / 1024) KB of audio from \(offset) s")
                let chunk = try await client.transcribe(audio: audio, mimeType: AudioExtractor.mimeType)
                words += chunk.map { TranscriptWord(text: $0.text, start: $0.start + offset, end: $0.end + offset) }
            }
            Log.transcription.notice("\(job.name, privacy: .public): \(words.count) words")
            return words
        } catch AnalysisError.noAudioTrack {
            return []
        }
    }

    /// Time ranges to send: the whole file (`nil`) when it fits in one request.
    static func chunks(duration: Double) -> [CMTimeRange?] {
        guard duration > chunkDuration + 60 else { return [nil] }
        return stride(from: 0, to: duration, by: chunkDuration).map { start in
            CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                duration: CMTime(seconds: min(chunkDuration, duration - start), preferredTimescale: 600)
            )
        }
    }

    // MARK: Text pass

    nonisolated private struct Line: Codable {
        var i: Int
        var t: String
    }

    static let polishSystem = """
    You correct automatic speech recognition output from a video. You get numbered phrases in spoken order.
    Return every phrase exactly once, with the same "i".
    Fix misheard words, names, technical terms, spelling, capitalization and punctuation. Use the context and key words when given.
    Keep the speaker's own words and language: never translate, summarize, censor, merge, split or reorder phrases. If a phrase is fine, return it unchanged.
    """

    static let polishSchema = #"{"type":"ARRAY","items":{"type":"OBJECT","properties":{"i":{"type":"INTEGER"},"t":{"type":"STRING"}},"required":["i","t"]}}"#

    /// Corrects phrase texts with the tier's language model; timings are untouched.
    private func polish(_ phrases: [TranscriptPhrase], settings: TranscriptionSettings, client: GeminiClient) async throws -> [TranscriptPhrase] {
        var corrections: [Int: String] = [:]
        for start in stride(from: 0, to: phrases.count, by: Self.phrasesPerTextPass) {
            let batch = phrases[start..<min(phrases.count, start + Self.phrasesPerTextPass)]
            let lines = batch.map { Line(i: $0.id, t: $0.text) }
            let json = String(decoding: try JSONEncoder().encode(lines), as: UTF8.self)
            let reply = try await client.generate(
                model: settings.tier.textModel,
                thinkingLevel: settings.tier.thinkingLevel,
                system: Self.polishSystem,
                prompt: Self.contextBlock(settings) + "Phrases:\n" + json,
                schemaJSON: Self.polishSchema
            )
            guard let fixed = try? JSONDecoder().decode([Line].self, from: Data(reply.utf8)) else {
                throw GeminiError.invalidResponse
            }
            for line in fixed { corrections[line.i] = line.t }
        }
        return TranscriptBuilder.applying(corrections, to: phrases)
    }

    static func contextBlock(_ settings: TranscriptionSettings) -> String {
        var block = ""
        if !settings.trimmedContext.isEmpty { block += "Context: \(settings.trimmedContext)\n" }
        if !settings.keywordList.isEmpty { block += "Key words: \(settings.keywordList.joined(separator: ", "))\n" }
        return block.isEmpty ? "" : block + "\n"
    }

    // MARK: Summary

    static let summarySystem = """
    You summarize video transcripts. Write in the transcript's language.
    Start with a one-sentence overview, then 3 to 7 short bullet points starting with "• " that cover the key points in order.
    Plain text only: no headings and no markdown. Don't add anything that isn't in the transcript.
    """

    /// A summary of `transcript` (cached; one request otherwise).
    func summary(of transcript: String, settings: TranscriptionSettings, client: GeminiClient) async throws -> String {
        let key = TranscriptCache.summaryKey(transcript: transcript, settings: settings)
        if let cached = await cache.load(String.self, key: key) { return cached }
        let summary = try await client.generate(
            model: settings.tier.textModel,
            thinkingLevel: settings.tier.thinkingLevel,
            system: Self.summarySystem,
            prompt: Self.contextBlock(settings) + "Transcript:\n" + transcript
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        await cache.store(summary, key: key)
        return summary
    }

    /// Cached summary only; never touches the network.
    func cachedSummary(of transcript: String, settings: TranscriptionSettings) async -> String? {
        await cache.load(String.self, key: TranscriptCache.summaryKey(transcript: transcript, settings: settings))
    }
}
