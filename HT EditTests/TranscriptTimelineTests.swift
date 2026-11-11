//
//  TranscriptTimelineTests.swift
//  HT EditTests
//

import Foundation
import Testing
@testable import HT_Edit

struct TranscriptTimelineTests {

    // MARK: Chunks

    @Test(arguments: [
        (duration: 100.0, expected: [0.0..<100.0]),
        (duration: 180.0, expected: [0.0..<180.0]),
        (duration: 400.0, expected: [0.0..<180.0, 180.0..<360.0, 360.0..<400.0]),
        // A 5 s tail is folded into the chunk before it.
        (duration: 365.0, expected: [0.0..<180.0, 180.0..<365.0]),
    ])
    func chunksCoverTheClip(duration: Double, expected: [Range<Double>]) {
        #expect(TranscriptTimeline.chunks(duration: duration, length: 180) == expected)
    }

    @Test(arguments: [0.0, -1.0, .nan, .infinity])
    func noChunksForUnusableDurations(duration: Double) {
        #expect(TranscriptTimeline.chunks(duration: duration, length: 180).isEmpty)
    }

    // MARK: Normalizing model output

    @Test func normalizeOffsetsByTheChunkStart() {
        let raw = [TranscriptSegment(start: 1, end: 2.5, text: "Hello")]
        let result = TranscriptTimeline.normalize(raw, chunk: 180..<360)
        #expect(result == [TranscriptSegment(start: 181, end: 182.5, text: "Hello")])
    }

    @Test func normalizeCleansUpBadOutput() {
        let raw = [
            TranscriptSegment(start: 5, end: 4, text: "end before start"),
            TranscriptSegment(start: -1, end: 1, text: "  negative start  "),
            TranscriptSegment(start: 8, end: 50, text: "runs past the chunk"),
            TranscriptSegment(start: 12, end: 13, text: "starts after the chunk"),
            TranscriptSegment(start: 2, end: 3, text: "   "),
            TranscriptSegment(start: .nan, end: 1, text: "not a number"),
        ]
        let result = TranscriptTimeline.normalize(raw, chunk: 100..<110)
        #expect(result == [
            TranscriptSegment(start: 100, end: 101, text: "negative start"),
            TranscriptSegment(start: 105, end: 105, text: "end before start"),
            TranscriptSegment(start: 108, end: 110, text: "runs past the chunk"),
        ])
    }

    // MARK: Merging chunks

    @Test func chunksMergeInAnyOrderAndRetriesReplaceTheirRange() {
        let second = [TranscriptSegment(start: 185, end: 190, text: "second")]
        let first = [TranscriptSegment(start: 5, end: 9, text: "first")]
        var merged = TranscriptTimeline.merging(second, into: [], chunk: 180..<360)
        merged = TranscriptTimeline.merging(first, into: merged, chunk: 0..<180)
        #expect(merged.map(\.text) == ["first", "second"])

        let retried = [TranscriptSegment(start: 181, end: 184, text: "second, again")]
        merged = TranscriptTimeline.merging(retried, into: merged, chunk: 180..<360)
        #expect(merged.map(\.text) == ["first", "second, again"])
    }

    // MARK: Timeline

    @Test func segmentsFollowClipOrderOnTheTimeline() {
        let a = UUID(), b = UUID()
        let transcripts = [
            a: [TranscriptSegment(start: 1, end: 2, text: "in a")],
            b: [TranscriptSegment(start: 0.5, end: 1, text: "in b"), TranscriptSegment(start: 9, end: 10, text: "past b's end")],
        ]
        let forward = TranscriptTimeline.segments(transcripts: transcripts, clips: [(a, 10), (b, 5)])
        #expect(forward.map(\.text) == ["in a", "in b"])
        #expect(forward.map(\.start) == [1, 10.5])

        let reordered = TranscriptTimeline.segments(transcripts: transcripts, clips: [(b, 5), (a, 10)])
        #expect(reordered.map(\.text) == ["in b", "in a"])
        #expect(reordered.map(\.start) == [0.5, 6])
        #expect(Set(reordered.map(\.id)).count == reordered.count)
    }

    @Test(arguments: [
        (time: 0.0, expected: nil as Int?),
        (time: 1.0, expected: 0),
        (time: 4.9, expected: 0),
        (time: 5.0, expected: 1),
        (time: 99.0, expected: 2),
    ])
    func activeIndexIsTheLastLineStartedByThen(time: Double, expected: Int?) {
        let segments = [1.0, 5.0, 9.0].enumerated().map { index, start in
            TimelineSegment(id: "\(index)", clipID: UUID(), start: start, end: start + 1, text: "line")
        }
        #expect(TranscriptTimeline.activeIndex(at: time, in: segments) == expected)
    }

    @Test func plainTextHasOneStampedLinePerSegment() {
        let segments = [
            TimelineSegment(id: "0", clipID: UUID(), start: 2, end: 3, text: "Hi."),
            TimelineSegment(id: "1", clipID: UUID(), start: 75, end: 76, text: "Bye."),
        ]
        #expect(TranscriptTimeline.plainText(segments) == "[0:02] Hi.\n[1:15] Bye.")
    }

    // MARK: Model catalog

    @Test @MainActor func catalogDefaultsToTheCheapestModel() {
        let controller = TranscriptionController(engine: FakeTranscriptionEngine(), cache: nil, defaults: nil)
        #expect(controller.selectedModel == TranscriptionModel.catalog.first)
        #expect(controller.context.isEmpty)
        #expect(Set(TranscriptionModel.catalog.map(\.id)).count == TranscriptionModel.catalog.count)
        #expect(TranscriptionModel.catalog.allSatisfy { $0.id.hasPrefix("gemini-") })
    }

    @Test func availableModelsComeFromTheAgyListCheapestFirst() {
        // The real `agy models` format: slug, a tab, then the display name.
        let list = """
        Fetching available models...
        gemini-4-argon-medium\tGemini 4 Argon (Medium)
        gemini-3.8-flash-high\tGemini 3.8 Flash (High)
        gemini-3.8-flash-low\tGemini 3.8 Flash (Low)
        claude-sonnet-5-5-low\tClaude Sonnet 5.5 (Low)
        gpt-oss-120b-medium\tGPT-OSS 120B (Medium)
        """
        // Only catalog models count, listed cheapest first whatever order agy uses.
        #expect(TranscriptionModel.available(inModelList: list).map(\.id) == ["gemini-3.8-flash-low", "gemini-3.8-flash-high"])
    }

    @Test func availableModelsMatchDisplayNamesAndPreviewSlugs() {
        #expect(TranscriptionModel.available(inModelList: "Gemini 3.8 Flash (High)\ngemini-3.8-flash-medium-preview").map(\.id)
                == ["gemini-3.8-flash-medium", "gemini-3.8-flash-high"])
        // A longer name isn't a match: "-lowest" isn't "-low", and "-lite" variants are different models.
        #expect(TranscriptionModel.available(inModelList: "gemini-3.8-flash-lowest\ngemini-3.8-flash-high-lite").isEmpty)
        #expect(TranscriptionModel.available(inModelList: "gpt-oss-120b").isEmpty)
    }
}
