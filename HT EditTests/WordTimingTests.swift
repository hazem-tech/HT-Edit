//
//  WordTimingTests.swift
//  HT EditTests
//

import CoreMedia
import Foundation
import Synchronization
import Testing
@testable import HT_Edit

struct TranscriptWordsTests {

    @Test func punctuationWrittenApartJoinsTheWordBefore() {
        #expect(TranscriptWords.tokenize("مرحبا ، كيف حالك ؟") == ["مرحبا ،", "كيف", "حالك ؟"])
        #expect(TranscriptWords.tokenize("  Hello,   world! ") == ["Hello,", "world!"])
        #expect(TranscriptWords.tokenize("— dash first") == ["—", "dash", "first"], "nothing before it to join")
        #expect(TranscriptWords.tokenize("") == [])
    }

    @Test func diacriticsDontCountTowardsLength() {
        #expect(TranscriptWords.spokenLength("كَتَبَ") == TranscriptWords.spokenLength("كتب"))
        #expect(TranscriptWords.spokenLength("2026") == 4)
    }

    @Test func evenSpreadCoversTheLineByLength() {
        let words = TranscriptWords.evenlySpread(TranscriptSegment(start: 10, end: 13, text: "ab abcd ab"))
        #expect(words.map(\.text) == ["ab", "abcd", "ab"])
        #expect(words.first?.start == 10)
        #expect(abs((words.last?.end ?? 0) - 13) < 1e-9)
        #expect(abs(words[1].end - words[1].start - 1.5) < 1e-9, "twice as long, twice the time")
        let contiguous = zip(words, words.dropFirst()).allSatisfy { $0.end == $1.start }
        #expect(contiguous)
        let allApproximate = words.allSatisfy { $0.isApproximate }
        #expect(allApproximate)
    }

    @Test func missingTimesAreFilledFromTheNeighbors() {
        let segment = TranscriptSegment(start: 0, end: 4, text: "a 12 b")
        let words = TranscriptWords.filling(["a", "12", "b"], times: [
            TranscriptWord(start: 0.2, end: 1, text: ""),
            nil,
            TranscriptWord(start: 2.5, end: 3, text: ""),
        ], in: segment)
        #expect(words.map(\.text) == ["a", "12", "b"])
        #expect(words[1].start == 1 && words[1].end == 2.5, "the gap between its neighbors")
        #expect(words[1].isApproximate && !words[0].isApproximate && !words[2].isApproximate)
    }

    @Test func filledTimesStayInOrderAndInsideTheLine() {
        let segment = TranscriptSegment(start: 1, end: 2, text: "a b")
        let words = TranscriptWords.filling(["a", "b"], times: [
            TranscriptWord(start: 0.5, end: 1.6, text: ""),
            TranscriptWord(start: 1.4, end: 2.5, text: ""),
        ], in: segment)
        #expect(words[0].start == 1)
        #expect(words[1].start == 1.6, "never before the previous word ends")
        #expect(words[1].end == 2)
    }

    @Test func wordsArePlacedOnTheTimelineWithStableIDs() {
        let a = UUID(), b = UUID()
        let transcripts = [
            a: [TranscriptSegment(start: 1, end: 2, text: "x y", words: [
                TranscriptWord(start: 1, end: 1.4, text: "x"),
                TranscriptWord(start: 1.5, end: 2, text: "y"),
            ])],
            b: [TranscriptSegment(start: 0, end: 1, text: "z")],
        ]
        let segments = TranscriptTimeline.segments(transcripts: transcripts, clips: [(b, 5), (a, 10)])
        let words = segments.flatMap(\.words)
        #expect(words.map(\.text) == ["z", "x", "y"])
        #expect(words.map(\.start) == [0, 6, 6.5])
        #expect(words.map(\.clipStart) == [0, 1, 1.5])
        #expect(words[0].isApproximate && !words[1].isApproximate)

        let reordered = TranscriptTimeline.segments(transcripts: transcripts, clips: [(a, 10), (b, 5)])
        #expect(Set(reordered.flatMap(\.words).map(\.id)) == Set(words.map(\.id)), "IDs don't depend on clip order")
    }
}

struct WordCutPlannerTests {

    private let clip = UUID()

    private func word(_ start: Double, _ end: Double, _ text: String) -> TimelineWord {
        TimelineWord(
            id: TranscriptWords.id(clipID: clip, word: TranscriptWord(start: start, end: end, text: text)),
            clipID: clip, start: start, end: end, clipStart: start, clipEnd: end, text: text, isApproximate: false
        )
    }

    /// Speech 0–1 s, pause 1–1.3 s, speech 1.3–2 s, pause 2–2.2 s, speech 2.2–3 s.
    private var levels: AudioLevels {
        makeLevels(loud(1) + quiet(0.3) + loud(0.7) + quiet(0.2) + loud(0.8))
    }

    @Test func cutsLandInTheMiddleOfThePausesAroundTheWord() throws {
        // Word edges a little off, as an aligner gives them.
        let words = [word(0.05, 0.95, "one"), word(1.32, 1.95, "two"), word(2.25, 2.9, "three")]
        let cuts = WordCutPlanner.cuts(clipID: clip, words: words, deleted: [words[1].id], levels: levels, clipDuration: 3)
        let cut = try #require(cuts.first)
        #expect(cuts.count == 1)
        #expect((1.0...1.3).contains(cut.start), "in the first pause")
        #expect(abs(cut.start - 1.135) < 0.03, "near its middle")
        #expect((2.0...2.2).contains(cut.end), "in the second pause")
        #expect(!cut.isTight)
    }

    @Test func consecutiveDeletedWordsMakeOneCut() {
        let words = [word(0.05, 0.95, "one"), word(1.32, 1.95, "two"), word(2.25, 2.9, "three")]
        let deleted = Set(words[1...2].map(\.id))
        let cuts = WordCutPlanner.cuts(clipID: clip, words: words, deleted: deleted, levels: levels, clipDuration: 3)
        #expect(cuts.count == 1)
        #expect((cuts.first?.end ?? 0) > 2.9, "past the last deleted word")
    }

    @Test func wordsThatRunTogetherMakeATightCut() {
        let words = [word(0, 1, "one"), word(1.01, 2, "two"), word(2.5, 3, "three")]
        let cuts = WordCutPlanner.cuts(clipID: clip, words: words, deleted: [words[1].id], levels: .empty, clipDuration: 3)
        #expect(cuts.first?.isTight == true)
    }

    @Test func withoutLevelsTheCutGoesMidPause() {
        let at = WordCutPlanner.quietest(in: 1...2, preferring: 1.25, levels: .empty)
        #expect(at == 1.25)
    }

    @Test func quietestPrefersTheMiddleAmongEquallyQuietWindows() {
        let flat = makeLevels(quiet(3))
        let at = WordCutPlanner.quietest(in: 0.5...2.5, preferring: 1.5, levels: flat)
        #expect(abs(at - 1.505) < 0.011)
    }

    @Test func unionMergesOverlappingRanges() {
        func range(_ start: Double, _ end: Double) -> CMTimeRange {
            CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 1000), end: CMTime(seconds: end, preferredTimescale: 1000))
        }
        let merged = WordCutPlanner.union([range(0, 1), range(5, 6)], [range(0.5, 2), range(3, 4)])
        #expect(merged == [range(0, 2), range(3, 4), range(5, 6)])
    }
}

struct AlignmentProtocolTests {

    @Test func requestTimesAreRelativeToTheChunk() {
        let request = AlignmentProtocol.request(for: [TranscriptSegment(start: 181, end: 184, text: "a b")], chunk: 180..<360)
        #expect(request.segments.first?.start == 1)
        #expect(request.segments.first?.end == 4)
        #expect(request.segments.first?.words == ["a", "b"])
    }

    @Test func replyTimesAreMovedBackToClipTime() throws {
        let segments = [
            TranscriptSegment(start: 181, end: 184, text: "a 12 b"),
            TranscriptSegment(start: 185, end: 186, text: "c"),
            TranscriptSegment(start: 187, end: 188, text: "d e"),
        ]
        let reply = #"""
        progress noise
        {"segments": [{"words": [{"start": 1.2, "end": 1.8, "score": 0.9}, null, {"start": 3.0, "end": 3.5, "score": 0.8}]}, null, {"words": [{"start": 7.1, "end": 7.4}]}]}
        """#
        let aligned = try AlignmentProtocol.apply(reply, to: segments, chunk: 180..<360)
        let first = try #require(aligned[0].words)
        #expect(first.map(\.text) == ["a", "12", "b"])
        #expect(abs(first[0].start - 181.2) < 1e-9 && abs(first[2].end - 183.5) < 1e-9)
        #expect(first[1].isApproximate)
        #expect(aligned[1].words == nil, "not aligned")
        #expect(aligned[2].words == nil, "word count doesn't match: not trusted")
    }

    @Test func garbageIsAnError() {
        #expect(throws: WordAlignerError.self) {
            _ = try AlignmentProtocol.apply("Traceback (most recent call last):", to: [TranscriptSegment(start: 0, end: 1, text: "a")], chunk: 0..<1)
        }
    }

    @Test func wavHeaderDescribes16kMono16Bit() {
        let header = AudioChunkExporter.wavHeader(dataSize: 32_000, sampleRate: 16_000)
        #expect(header.count == 44)
        #expect(String(decoding: header.prefix(4), as: UTF8.self) == "RIFF")
        #expect(header[22] == 1, "mono")
        #expect(header[24] == 0x80 && header[25] == 0x3E, "16000 Hz")
        #expect(header[34] == 16, "16-bit")
    }

    @Test func theAlignerScriptShipsWithTheApp() {
        #expect(Bundle.main.url(forResource: UVWordAligner.scriptName, withExtension: "py") != nil)
    }

    @Test func exportedWAVHasTheRequestedLength() async throws {
        let directory = makeTemporaryDirectory("wav")
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = try await MediaFixtures.make(.audioOnly, in: directory, duration: 4)
        let wav = directory.appending(path: "chunk.wav")
        try await AudioChunkExporter.exportWAV(audio, range: 1..<3.5, to: wav)
        let data = try Data(contentsOf: wav)
        let frames = (data.count - 44) / 2
        #expect(abs(frames - 40_000) <= 160, "2.5 s of 16 kHz 16-bit mono, give or take 10 ms")
    }
}

/// An aligner whose answer each test scripts.
final class ScriptedAligner: WordAligner {
    private let status: WordTimingStatus
    private let failure: WordAlignerError?
    private let calls = Mutex(0)

    init(status: WordTimingStatus = .ready, failure: WordAlignerError? = nil) {
        self.status = status
        self.failure = failure
    }

    var callCount: Int { calls.withLock { $0 } }

    func checkStatus() async -> WordTimingStatus { status }

    func align(_ segments: [TranscriptSegment], in source: URL, chunk: Range<Double>, scratch: URL) async throws -> [TranscriptSegment] {
        calls.withLock { $0 += 1 }
        if let failure { throw failure }
        return segments.map { segment in
            var segment = segment
            segment.words = TranscriptWords.evenlySpread(segment).map { word in
                var word = word
                word.isApproximate = false
                return word
            }
            return segment
        }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct WordTimingTranscriberTests {

    private func collect(_ stream: AsyncThrowingStream<TranscriptionEvent, any Error>) async throws -> [TranscriptionEvent] {
        var events: [TranscriptionEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    @Test func alignedWordsArriveWithEachChunk() async throws {
        let directory = makeTemporaryDirectory("aligned")
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = try await MediaFixtures.make(.audioOnly, in: directory, duration: 7)
        let aligner = ScriptedAligner()
        let transcriber = Transcriber(engine: ScriptedEngine(), cache: nil, chunkLength: 3, aligner: aligner)

        let events = try await collect(transcriber.run([TranscriptionJob(clipID: UUID(), url: audio, duration: 7, chunks: nil)], model: "m", context: ""))
        let segments = events.flatMap { event -> [TranscriptSegment] in
            if case .chunkFinished(_, _, let segments) = event { return segments }
            return []
        }
        #expect(segments.count == 2)
        let allAligned = segments.allSatisfy { $0.words?.isEmpty == false }
        #expect(allAligned)
        #expect(aligner.callCount == 2)
    }

    @Test func aFailingAlignerKeepsTheTextAndCachesOnlyTheText() async throws {
        let directory = makeTemporaryDirectory("align-fails")
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = try await MediaFixtures.make(.audioOnly, in: directory, duration: 7)
        let cache = TranscriptCache(directory: directory.appending(path: "cache"))
        let engine = ScriptedEngine()
        let aligner = ScriptedAligner(failure: WordAlignerError.timedOut)
        let transcriber = Transcriber(engine: engine, cache: cache, chunkLength: 3, aligner: aligner)
        let job = TranscriptionJob(clipID: UUID(), url: audio, duration: 7, chunks: nil)

        let events = try await collect(transcriber.run([job], model: "m", context: ""))
        let reportedFailure = events.contains { if case .wordTimingFailed = $0 { true } else { false } }
        let keptText = events.contains { if case .chunkFinished(_, _, let segments) = $0 { segments.first?.words == nil } else { false } }
        #expect(reportedFailure)
        #expect(keptText)

        let second = try await collect(transcriber.run([job], model: "m", context: ""))
        let cachedText = second.contains { if case .cached = $0 { true } else { false } }
        #expect(cachedText, "the text shows at once")
        #expect(engine.calls.count == 2, "the engine isn't asked for the same text again")
        #expect(aligner.callCount == 4, "the word times are tried again")
    }

    @Test func cachedTextIsOnlyAlignedAgain() async throws {
        let directory = makeTemporaryDirectory("align-cached-text")
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = try await MediaFixtures.make(.audioOnly, in: directory, duration: 7)
        let cache = TranscriptCache(directory: directory.appending(path: "cache"))
        let engine = ScriptedEngine()
        let job = TranscriptionJob(clipID: UUID(), url: audio, duration: 7, chunks: nil)

        // Transcribed before word timing was set up.
        _ = try await collect(Transcriber(engine: engine, cache: cache, chunkLength: 3).run([job], model: "m", context: ""))
        #expect(engine.calls.count == 2)

        let aligner = ScriptedAligner()
        let transcriber = Transcriber(engine: engine, cache: cache, chunkLength: 3, aligner: aligner)
        let events = try await collect(transcriber.run([job], model: "m", context: ""))
        let measured = events.compactMap { event -> [TranscriptSegment]? in
            if case .wordsMeasured(_, let segments) = event { return segments }
            return nil
        }
        #expect(engine.calls.count == 2, "no new transcription")
        #expect(aligner.callCount == 2)
        #expect(measured.first?.count == 2)
        let allAligned = measured.first?.allSatisfy { $0.words?.isEmpty == false } ?? false
        #expect(allAligned)

        // Now the measured transcript is cached too.
        let third = try await collect(transcriber.run([job], model: "m", context: ""))
        #expect(third.count == 1)
        #expect(aligner.callCount == 2)
    }

    @Test func anAlignerThatIsntReadyIsSkipped() async throws {
        let directory = makeTemporaryDirectory("align-missing")
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = try await MediaFixtures.make(.audioOnly, in: directory, duration: 3)
        let aligner = ScriptedAligner(status: .notInstalled)
        let transcriber = Transcriber(engine: ScriptedEngine(), cache: nil, chunkLength: 3, aligner: aligner)

        let events = try await collect(transcriber.run([TranscriptionJob(clipID: UUID(), url: audio, duration: 3, chunks: nil)], model: "m", context: ""))
        #expect(aligner.callCount == 0)
        let reportedFailure = events.contains { if case .wordTimingFailed = $0 { true } else { false } }
        #expect(!reportedFailure)
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct WordDeletionTests {

    @Test func deletingAWordMakesPlaybackSkipIt() async throws {
        let directory = makeTemporaryDirectory("delete-words")
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = try await MediaFixtures.make(.audioOnly, in: directory, duration: 3)
        let engine = ScriptedEngine { _, _ in [TranscriptSegment(start: 0.5, end: 2.5, text: "one two three four")] }
        let controller = TranscriptionController(engine: engine, cache: nil, defaults: nil, chunkLength: 3)
        let clip = Clip(url: audio, duration: CMTime(seconds: 3, preferredTimescale: 600))
        let model = EditorViewModel(analyzedClips: [(clip, makeLevels(loud(3)))], transcription: controller)
        model.cutsNonSpeech = false

        model.transcribeAll()
        #expect(await waitUntil { controller.phase == .finished })
        let words = model.timelineTranscript.flatMap(\.words)
        #expect(words.map(\.text) == ["one", "two", "three", "four"])
        #expect(model.skipRanges.isEmpty, "all loud: no silences")

        model.toggleDeletion(of: [words[1].id])
        #expect(model.wordCuts.count == 1)
        let skip = try #require(model.skipRanges.first)
        #expect(skip.start.seconds < words[1].start + 0.05 && skip.end.seconds > words[1].end - 0.05)

        model.toggleDeletion(of: [words[1].id])
        #expect(model.skipRanges.isEmpty, "toggling again restores it")

        model.toggleDeletion(of: [words[2].id])
        model.transcribeAll()
        #expect(model.deletedWordIDs.isEmpty, "a new transcript starts with nothing deleted")
        #expect(await waitUntil { controller.phase == .finished })
    }

    @Test func deleteKeyTogglesTheSelectedWords() async throws {
        let directory = makeTemporaryDirectory("toggle-words")
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = try await MediaFixtures.make(.audioOnly, in: directory, duration: 3)
        let engine = ScriptedEngine { _, _ in [TranscriptSegment(start: 0.5, end: 2.5, text: "one two three four")] }
        let controller = TranscriptionController(engine: engine, cache: nil, defaults: nil, chunkLength: 3)
        let clip = Clip(url: audio, duration: CMTime(seconds: 3, preferredTimescale: 600))
        let model = EditorViewModel(analyzedClips: [(clip, makeLevels(loud(3)))], transcription: controller)
        model.cutsNonSpeech = false
        model.transcribeAll()
        #expect(await waitUntil { controller.phase == .finished })
        let words = model.timelineWords

        model.selectWord(at: 1)
        model.selectWord(at: 2, extending: true)
        #expect(model.selectedWordIDs == [words[1].id, words[2].id])
        model.toggleSelectedWords()
        #expect(model.deletedWordIDs == [words[1].id, words[2].id])
        #expect(model.wordCuts.count == 1, "neighbors make one cut")
        #expect(model.removedRanges.first?.reasons == [.cutWords("two three")])

        model.toggleSelectedWords()
        #expect(model.deletedWordIDs.isEmpty, "pressing it again restores them")

        model.selectWord(at: 0)
        model.selectWord(at: 3, toggling: true)
        #expect(model.selectedWordIDs == [words[0].id, words[3].id])
        model.selectWord(at: 3, toggling: true)
        #expect(model.selectedWordIDs == [words[0].id])
    }

    @Test func whatIsntSpeechIsCutOnceTheTranscriptIsComplete() async throws {
        let directory = makeTemporaryDirectory("no-speech")
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = try await MediaFixtures.make(.audioOnly, in: directory, duration: 3)
        let engine = ScriptedEngine(delay: .milliseconds(300)) { _, _ in [TranscriptSegment(start: 0.5, end: 2.5, text: "one two three four")] }
        let controller = TranscriptionController(engine: engine, cache: nil, defaults: nil, chunkLength: 3)
        let clip = Clip(url: audio, duration: CMTime(seconds: 3, preferredTimescale: 600))
        let model = EditorViewModel(analyzedClips: [(clip, makeLevels(loud(3)))], transcription: controller)

        model.transcribeAll()
        #expect(model.nonSpeechRanges.isEmpty, "nothing is cut while transcribing")
        #expect(await waitUntil { controller.phase == .finished })
        #expect(controller.completedClipIDs == [clip.id])

        // Speech 0.5–2.5 s: before and after it is cut, keeping 0.1 s next to the words.
        #expect(matches(model.nonSpeechRanges, [(0, 0.4), (2.6, 3)], tolerance: 0.001))
        #expect(model.removedRanges.map(\.reasons) == [[.noSpeech], [.noSpeech]])
        #expect(model.skipRanges == model.removedRanges.map(\.range))

        model.cutsNonSpeech = false
        #expect(model.skipRanges.isEmpty)
        model.cutsNonSpeech = true
        #expect(model.skipRanges.count == 2)
    }

    @Test func aClipWithFailedPartsKeepsWhatIsntTranscribed() async throws {
        let directory = makeTemporaryDirectory("no-speech-failed")
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = try await MediaFixtures.make(.audioOnly, in: directory, duration: 7)
        // The 4 s chunk (3–7) always fails.
        let engine = ScriptedEngine { _, duration in
            if duration > 3.5 { throw AgyError.invalidOutput("nope") }
            return [TranscriptSegment(start: 1, end: 2, text: "ok")]
        }
        let controller = TranscriptionController(engine: engine, cache: nil, defaults: nil, chunkLength: 3)
        let clip = Clip(url: audio, duration: CMTime(seconds: 7, preferredTimescale: 600))
        let model = EditorViewModel(analyzedClips: [(clip, makeLevels(loud(7)))], transcription: controller)

        model.transcribeAll()
        #expect(await waitUntil { controller.phase == .finished })
        #expect(controller.hasFailedChunks)
        #expect(controller.completedClipIDs.isEmpty)
        #expect(model.nonSpeechRanges.isEmpty, "the untranscribed part may well be speech")
        #expect(controller.needsRetry(for: model.placedClips))
    }
}
