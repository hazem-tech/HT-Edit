//
//  TranscriptTests.swift
//  HT EditTests
//

import CoreMedia
import Foundation
import Testing
@testable import HT_Edit

struct TranscriptBuilderTests {

    private func word(_ text: String, _ start: Double, _ end: Double) -> TranscriptWord {
        TranscriptWord(text: text, start: start, end: end)
    }

    @Test func sentencesBecomePhrases() {
        let words = [
            word("Welcome", 0.3, 0.9), word("to", 0.9, 1.2), word("HT", 1.2, 2.1), word("Edit.", 2.1, 2.5),
            word("Today", 2.9, 3.5), word("we", 3.5, 3.8), word("test.", 3.8, 4.2),
        ]
        let phrases = TranscriptBuilder.phrases(from: words)
        #expect(phrases.map(\.text) == ["Welcome to HT Edit.", "Today we test."])
        #expect(phrases.map(\.start) == [0.3, 2.9])
        #expect(phrases.map(\.end) == [2.5, 4.2])
        #expect(phrases.map(\.id) == [0, 1])
    }

    @Test func longPausesSplitPhrases() {
        let words = [word("so", 0, 0.3), word("then", 0.4, 0.7), word("later", 2.0, 2.4)]
        #expect(TranscriptBuilder.phrases(from: words).map(\.text) == ["so then", "later"])
    }

    @Test func longRunsAreSplitByWordCount() {
        let words = (0..<30).map { word("w\($0)", Double($0) * 0.2, Double($0) * 0.2 + 0.15) }
        let phrases = TranscriptBuilder.phrases(from: words)
        #expect(phrases.allSatisfy { $0.text.split(separator: " ").count <= TranscriptBuilder.maximumWords })
        #expect(phrases.flatMap { $0.text.split(separator: " ") }.count == 30)
    }

    @Test func longRunsAreSplitByDuration() {
        let words = (0..<10).map { word("w\($0)", Double($0), Double($0) + 0.6) }
        let phrases = TranscriptBuilder.phrases(from: words)
        #expect(phrases.allSatisfy { $0.end - $0.start <= TranscriptBuilder.maximumDuration + 1 })
        #expect(phrases.count > 1)
    }

    @Test func emptyWordsAreDropped() {
        let phrases = TranscriptBuilder.phrases(from: [word(" ", 0, 0.1), word("hi", 0.1, 0.3)])
        #expect(phrases.map(\.text) == ["hi"])
    }

    @Test func cjkIsJoinedWithoutSpaces() {
        #expect(TranscriptBuilder.join(["今日は", "晴れ"]) == "今日は晴れ")
        #expect(TranscriptBuilder.join(["hello", "world"]) == "hello world")
    }

    @Test func correctionsKeepTimings() {
        let phrases = [
            TranscriptPhrase(id: 0, text: "age tea edit", start: 1, end: 2),
            TranscriptPhrase(id: 1, text: "fine", start: 3, end: 4),
        ]
        let fixed = TranscriptBuilder.applying([0: "HT Edit", 1: "  "], to: phrases)
        #expect(fixed.map(\.text) == ["HT Edit", "fine"])
        #expect(fixed.map(\.start) == [1, 3])
        #expect(fixed.map(\.end) == [2, 4])
    }

    @Test func phrasesAreShiftedToTheirClipsPosition() {
        let a = UUID(), b = UUID()
        let timeline = TranscriptBuilder.timeline([
            .init(clipID: a, start: 0, duration: 3, phrases: [TranscriptPhrase(id: 0, text: "one", start: 0.5, end: 1)]),
            .init(clipID: b, start: 3, duration: 2, phrases: [
                TranscriptPhrase(id: 0, text: "two", start: 0.2, end: 0.8),
                TranscriptPhrase(id: 1, text: "clamped", start: 1.5, end: 9),
                TranscriptPhrase(id: 2, text: "past the end", start: 2.5, end: 3),
            ]),
        ])
        #expect(timeline.map(\.text) == ["one", "two", "clamped"])
        #expect(timeline.map(\.start) == [0.5, 3.2, 4.5])
        #expect(timeline.map(\.end) == [1, 3.8, 5])
        #expect(Set(timeline.map(\.id)).count == 3)
    }

    @Test(arguments: [
        (0.0, nil as Int?),
        (0.5, 0),
        (1.5, 0),  // between phrases: the previous one stays highlighted
        (2.0, 1),
        (9.0, 2),
    ] as [(Double, Int?)])
    func activePhrase(seconds: Double, expected: Int?) {
        #expect(TranscriptBuilder.phraseIndex(at: seconds, in: samplePhrases) == expected)
    }

    @Test func captionsHideBetweenPhrases() {
        #expect(TranscriptBuilder.captionIndex(at: 0.9, in: samplePhrases) == 0)
        #expect(TranscriptBuilder.captionIndex(at: 1.0 + TranscriptBuilder.captionHold + 0.01, in: samplePhrases) == nil)
        #expect(TranscriptBuilder.captionIndex(at: 2.5, in: samplePhrases) == 1)
    }

    private var samplePhrases: [TimelinePhrase] {
        [(0.5, 1.0), (2.0, 3.0), (5.0, 6.0)].enumerated().map { index, range in
            TimelinePhrase(id: "\(index)", clipID: UUID(), text: "p\(index)", start: range.0, end: range.1)
        }
    }
}

struct GeminiClientTests {

    @Test(arguments: [
        ("0.300s", 0.3 as Double?),
        ("12s", 12),
        ("1.250s", 1.25),
        ("abc", nil),
    ] as [(String, Double?)])
    func parsesDurations(value: String, expected: Double?) {
        #expect(GeminiClient.seconds(value) == expected)
    }

    @Test func parsesNumericDurations() {
        #expect(GeminiClient.seconds(2.5) == 2.5)
        #expect(GeminiClient.seconds(nil) == nil)
    }

    @Test func readsWordTimestamps() throws {
        let response = Data(#"""
        {"candidates":[{"content":{"parts":[{"text":"Hello world.","audioTranscription":{"text":"Hello world.",
        "words":[{"word":"world.","startOffset":"0.500s","endOffset":"0.800s"},{"word":"Hello","startOffset":"0.100s","endOffset":"0.400s"}]}}]},
        "finishReason":"STOP"}]}
        """#.utf8)
        let words = try GeminiClient.words(from: response)
        #expect(words == [TranscriptWord(text: "Hello", start: 0.1, end: 0.4), TranscriptWord(text: "world.", start: 0.5, end: 0.8)])
    }

    @Test func noSpeechGivesNoWords() throws {
        let response = Data(#"{"candidates":[{"content":{"parts":[{"text":""}]},"finishReason":"STOP"}]}"#.utf8)
        #expect(try GeminiClient.words(from: response).isEmpty)
    }

    @Test func skipsThoughtParts() throws {
        let response = Data(#"{"candidates":[{"content":{"parts":[{"text":"hmm","thought":true},{"text":"Answer"}]}}]}"#.utf8)
        #expect(try GeminiClient.text(from: response) == "Answer")
    }

    @Test func transcriptionRequestAsksForWordTimestamps() throws {
        let body = try #require(try JSONSerialization.jsonObject(with: GeminiClient.transcriptionBody(audio: Data([1, 2, 3]), mimeType: "audio/m4a")) as? [String: Any])
        let config = body["generationConfig"] as? [String: Any]
        let transcription = config?["audioTranscriptionConfig"] as? [String: Any]
        #expect(transcription?["wordTimestamp"] as? Bool == true)
        // Custom vocabulary can't be combined with timestamps: it must never be sent.
        #expect(transcription?["customVocabulary"] == nil)
        let contents = body["contents"] as? [[String: Any]]
        let part = (contents?.first?["parts"] as? [[String: Any]])?.first
        let inline = part?["inlineData"] as? [String: Any]
        #expect(inline?["mimeType"] as? String == "audio/m4a")
        #expect(inline?["data"] as? String == Data([1, 2, 3]).base64EncodedString())
    }

    @Test func textRequestUsesSchemaAndThinkingLevel() throws {
        let data = GeminiClient.textBody(thinkingLevel: "minimal", system: "sys", prompt: "hi", schemaJSON: TranscriptionService.polishSchema)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let config = try #require(body["generationConfig"] as? [String: Any])
        #expect(config["responseMimeType"] as? String == "application/json")
        #expect((config["responseSchema"] as? [String: Any])?["type"] as? String == "ARRAY")
        #expect((config["thinkingConfig"] as? [String: Any])?["thinkingLevel"] as? String == "minimal")
    }

    @Test func mapsErrors() {
        let quota = Data(#"{"error":{"code":429,"message":"quota","status":"RESOURCE_EXHAUSTED","details":[{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"56240s"}]}}"#.utf8)
        #expect(GeminiClient.error(status: 429, body: quota) == .rateLimited(retryAfter: 56240))
        #expect(GeminiClient.automaticRetryDelay(for: .rateLimited(retryAfter: 56240)) == nil)
        #expect(GeminiClient.automaticRetryDelay(for: .rateLimited(retryAfter: 10)) != nil)

        let badKey = Data(#"{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT"}}"#.utf8)
        #expect(GeminiClient.error(status: 400, body: badKey) == .invalidAPIKey)

        let busy = Data(#"{"error":{"code":503,"message":"busy","status":"UNAVAILABLE"}}"#.utf8)
        #expect(GeminiClient.error(status: 503, body: busy) == .unavailable)

        #expect(GeminiClient.error(status: 500, body: Data("oops".utf8)) == .server(status: 500, message: HTTPURLResponse.localizedString(forStatusCode: 500)))
    }
}

struct TranscriptionSettingsTests {

    @Test func lowOnlyPolishesWithContext() {
        var settings = TranscriptionSettings()
        #expect(settings.tier == .low)
        #expect(!settings.hasContext)
        #expect(!settings.runsTextPass)

        settings.keywords = " , \n"
        #expect(!settings.runsTextPass)

        settings.keywords = "HT Edit, Gemini, ht edit"
        #expect(settings.keywordList == ["HT Edit", "Gemini"])
        #expect(settings.runsTextPass)

        settings.keywords = ""
        settings.context = "  A video editor demo  "
        #expect(settings.runsTextPass)
    }

    @Test func higherTiersAlwaysPolish() {
        #expect(TranscriptionSettings(tier: .medium).runsTextPass)
        #expect(TranscriptionSettings(tier: .high).runsTextPass)
    }

    @Test func persistsInDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "TranscriptionSettingsTests-\(UUID().uuidString)"))
        #expect(TranscriptionSettings.load(from: defaults) == .default)
        let settings = TranscriptionSettings(tier: .medium, context: "c", keywords: "k", showsCaptions: false)
        settings.save(to: defaults)
        #expect(TranscriptionSettings.load(from: defaults) == settings)
    }

    @Test func longClipsAreSentInChunks() {
        #expect(TranscriptionService.chunks(duration: 60) == [nil])
        let chunks = TranscriptionService.chunks(duration: 3600).compactMap { $0 }
        #expect(chunks.count == 3)
        #expect(chunks.map(\.start.seconds) == [0, 1500, 3000])
        #expect(chunks.last.map { ($0.start + $0.duration).seconds } == 3600)
    }
}

/// Cache behaviour: these never touch the network (the client has no key, so
/// any request would fail with `missingAPIKey`).
struct TranscriptCacheTests {

    private func makeFixture() throws -> (service: TranscriptionService, job: TranscriptionJob, wordsKey: String) {
        let directory = URL.temporaryDirectory.appending(path: "TranscriptCacheTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let media = directory.appending(path: "clip.mov")
        try Data([0, 1, 2]).write(to: media)
        let service = TranscriptionService(cache: TranscriptCache(directory: directory.appending(path: "cache")))
        let job = TranscriptionJob(clipID: UUID(), url: media, name: "clip.mov", duration: 10)
        return (service, job, try #require(TranscriptCache.wordsKey(for: media)))
    }

    private let words = [
        TranscriptWord(text: "Hello", start: 0.1, end: 0.4),
        TranscriptWord(text: "world.", start: 0.5, end: 0.8),
    ]

    @Test func cachedWordsNeedNoRequest() async throws {
        let (service, job, key) = try makeFixture()
        #expect(await service.cachedPhrases(for: job, settings: .default) == nil)

        await service.cache.store(words, key: key)
        let phrases = try await service.phrases(for: job, settings: .default, client: GeminiClient(apiKey: ""))
        #expect(phrases.map(\.text) == ["Hello world."])
        #expect(await service.cachedPhrases(for: job, settings: .default)?.map(\.text) == ["Hello world."])
    }

    @Test func contextOnlyRerunsTheTextPass() async throws {
        let (service, job, key) = try makeFixture()
        await service.cache.store(words, key: key)
        let settings = TranscriptionSettings(keywords: "Hallo")

        // Words are cached, so the only request would be the text pass.
        await #expect(throws: GeminiError.missingAPIKey) {
            try await service.phrases(for: job, settings: settings, client: GeminiClient(apiKey: ""))
        }
        // Before polishing, the cache still offers the unpolished phrases.
        #expect(await service.cachedPhrases(for: job, settings: settings)?.map(\.text) == ["Hello world."])

        let polished = [TranscriptPhrase(id: 0, text: "Hallo world.", start: 0.1, end: 0.8)]
        await service.cache.store(polished, key: TranscriptCache.phrasesKey(wordsKey: key, settings: settings))
        #expect(try await service.phrases(for: job, settings: settings, client: GeminiClient(apiKey: "")) == polished)
    }

    @Test func editedFilesGetANewKey() throws {
        let (_, job, key) = try makeFixture()
        try Data([9, 9, 9, 9]).write(to: job.url)
        #expect(TranscriptCache.wordsKey(for: job.url) != key)
    }

    @Test func summariesAreCached() async throws {
        let (service, _, _) = try makeFixture()
        let key = TranscriptCache.summaryKey(transcript: "text", settings: .default)
        await service.cache.store("A summary.", key: key)
        #expect(try await service.summary(of: "text", settings: .default, client: GeminiClient(apiKey: "")) == "A summary.")
        await #expect(throws: GeminiError.missingAPIKey) {
            try await service.summary(of: "other text", settings: .default, client: GeminiClient(apiKey: ""))
        }
    }
}

@MainActor
struct TranscriptionModelTests {

    @Test func highlightsFollowThePlayheadAndClipOrder() async throws {
        let directory = URL.temporaryDirectory.appending(path: "TranscriptionModelTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cache = TranscriptCache(directory: directory.appending(path: "cache"))
        let urlA = directory.appending(path: "a.mov"), urlB = directory.appending(path: "b.mov")
        try Data([1]).write(to: urlA)
        try Data([2]).write(to: urlB)
        await cache.store([TranscriptWord(text: "first.", start: 0.5, end: 1)], key: try #require(TranscriptCache.wordsKey(for: urlA)))
        await cache.store([TranscriptWord(text: "second.", start: 0.2, end: 0.6)], key: try #require(TranscriptCache.wordsKey(for: urlB)))

        let defaults = try #require(UserDefaults(suiteName: "TranscriptionModelTests-\(UUID().uuidString)"))
        let model = TranscriptionModel(service: TranscriptionService(cache: cache), defaults: defaults)
        let a = TranscriptionModel.ClipSlot(id: UUID(), url: urlA, name: "a", start: 0, duration: 3)
        let b = TranscriptionModel.ClipSlot(id: UUID(), url: urlB, name: "b", start: 3, duration: 2)

        // Cached transcripts load on import, without any request.
        model.updateLayout([a, b])
        for _ in 0..<200 where model.phrases.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.phrases.map(\.text) == ["first.", "second."])
        #expect(model.phrases.map(\.start) == [0.5, 3.2])

        model.updatePlayhead(3.3)
        #expect(model.activeIndex == 1)
        #expect(model.captionText == "second.")
        model.settings.showsCaptions = false
        #expect(model.captionText == nil)

        // Reordering re-maps the same phrases.
        var movedB = b, movedA = a
        movedB.start = 0
        movedA.start = 2
        model.updateLayout([movedB, movedA])
        #expect(model.phrases.map(\.text) == ["second.", "first."])
        #expect(model.phrases.map(\.start) == [0.2, 2.5])
        #expect(model.activeIndex == 1)

        // Removing a clip drops its phrases.
        model.updateLayout([movedB])
        #expect(model.phrases.map(\.text) == ["second."])
    }
}
