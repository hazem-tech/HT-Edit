//
//  EditingTests.swift
//  HT EditTests
//
//  What's removed from the edit and why, markers, zoom math, keyboard
//  shortcuts, and automatic transcription.
//

import AppKit
import CoreMedia
import Foundation
import Testing
@testable import HT_Edit

private func range(_ start: Double, _ end: Double) -> CMTimeRange {
    CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 1000), end: CMTime(seconds: end, preferredTimescale: 1000))
}

struct NonSpeechPlannerTests {

    private let clip = UUID()

    private func word(_ start: Double, _ end: Double) -> TimelineWord {
        TimelineWord(id: "\(start)", clipID: clip, start: start, end: end, clipStart: start, clipEnd: end, text: "w", isApproximate: false)
    }

    private func ranges(_ words: [TimelineWord], duration: Double = 10) -> [(Double, Double)] {
        NonSpeechPlanner.ranges(words: words, clipDuration: duration).map { ($0.lowerBound, $0.upperBound) }
    }

    private func same(_ actual: [(Double, Double)], _ expected: [(Double, Double)]) -> Bool {
        actual.count == expected.count && zip(actual, expected).allSatisfy { isClose($0.0, $1.0, tolerance: 1e-9) && isClose($0.1, $1.1, tolerance: 1e-9) }
    }

    @Test func cutsBeforeBetweenAndAfterTheWords() {
        // Speech 1–2 and 3–4 s in a 10 s clip.
        let result = ranges([word(1, 2), word(3, 4)])
        #expect(same(result, [(0, 0.9), (2.1, 2.9), (4.1, 10)]))
    }

    @Test func shortPausesBetweenWordsAreKept() {
        let result = ranges([word(0, 1), word(1.2, 2), word(2.29, 3)], duration: 3)
        #expect(result.isEmpty, "pauses under 0.3 s, and speech up to both edges")
    }

    @Test func overlappingWordsDontOpenAGap() {
        // The second word ends before the first: the gap starts after the longest one.
        let result = ranges([word(0, 3), word(1, 2), word(4, 5)], duration: 5)
        #expect(same(result, [(3.1, 3.9)]))
    }

    @Test func wordsOutOfOrderAreSorted() {
        let result = ranges([word(3, 4), word(1, 2)], duration: 4)
        #expect(same(result, [(0, 0.9), (2.1, 2.9)]))
    }

    @Test func aClipWithoutWordsKeepsEverything() {
        #expect(ranges([]).isEmpty)
        #expect(NonSpeechPlanner.ranges(words: [word(1, 2)], clipDuration: .nan).isEmpty)
    }
}

struct RemovalPlannerTests {

    @Test func overlappingRangesMergeAndKeepEveryReason() {
        let merged = RemovalPlanner.merge([
            (range: range(5, 6), reason: .noSpeech),
            (range: range(0, 1), reason: .silence),
            (range: range(0.5, 2), reason: .noSpeech),
            (range: range(1.5, 1.8), reason: .silence),
            (range: range(3, 4), reason: .cutWords("hello")),
        ])
        #expect(merged.map(\.range) == [range(0, 2), range(3, 4), range(5, 6)])
        #expect(merged.map(\.reasons) == [[.silence, .noSpeech], [.cutWords("hello")], [.noSpeech]])
    }

    @Test func emptyRangesAreDropped() {
        #expect(RemovalPlanner.merge([(range: range(1, 1), reason: .silence)]).isEmpty)
    }

    @Test func findsTheRangeUnderAPoint() {
        let ranges = RemovalPlanner.merge([(range: range(1, 2), reason: .silence), (range: range(4, 5), reason: .noSpeech)])
        #expect(RemovalPlanner.index(containing: 1.5, in: ranges) == 0)
        #expect(RemovalPlanner.index(containing: 4, in: ranges) == 1)
        #expect(RemovalPlanner.index(containing: 2, in: ranges) == nil, "the end isn't inside")
        #expect(RemovalPlanner.index(containing: 3, in: ranges) == nil)
        #expect(RemovalPlanner.index(containing: .nan, in: ranges) == nil)
        #expect(RemovalPlanner.firstIndex(endingAfter: 2.5, in: ranges) == 1)
        #expect(RemovalPlanner.firstIndex(endingAfter: 9, in: ranges) == 2)
    }

    @Test func reasonsHaveReadableTitles() {
        #expect(RemovalReason.silence.title == "Silence")
        #expect(RemovalReason.noSpeech.title == "No speech")
        #expect(RemovalReason.cutWords("um so").title == "Cut words: “um so”")
        #expect(RemovalReason.cutWords(String(repeating: "a", count: 80)).title.count < 60, "long cuts are shortened")
    }
}

struct TimelineZoomTests {

    @Test func sliderIsLogarithmic() {
        #expect(TimelineZoom.zoom(forSliderPosition: 0) == 1)
        #expect(isClose(TimelineZoom.zoom(forSliderPosition: 1), 400, tolerance: 1e-9))
        #expect(isClose(TimelineZoom.zoom(forSliderPosition: 0.5), 20, tolerance: 1e-9), "the middle is the geometric mean")
        for zoom in [1.0, 1.5, 20, 133, 400] {
            #expect(isClose(TimelineZoom.zoom(forSliderPosition: TimelineZoom.sliderPosition(forZoom: zoom)), zoom, tolerance: 1e-6))
        }
    }

    @Test func outOfRangeAndNonFiniteValuesAreClamped() {
        #expect(TimelineZoom.zoom(forSliderPosition: -3) == 1)
        #expect(isClose(TimelineZoom.zoom(forSliderPosition: 7), 400, tolerance: 1e-9))
        #expect(TimelineZoom.zoom(forSliderPosition: .nan) == 1)
        #expect(TimelineZoom.sliderPosition(forZoom: .infinity) == 0)
        #expect(TimelineZoom.sliderPosition(forZoom: 10_000) == 1)
        #expect(TimelineZoom.clamped(0) == 1)
    }

    @Test func anchoredOffsetKeepsTheAnchorInPlaceWithinBounds() {
        // 10 s at 100 pt/s in a 200 pt view: time 5 s at x = 50 needs offset 450.
        #expect(TimelineZoom.anchoredOffset(anchorTime: 5, anchorX: 50, pixelsPerSecond: 100, contentWidth: 1000, viewportWidth: 200) == 450)
        #expect(TimelineZoom.anchoredOffset(anchorTime: 9.9, anchorX: 0, pixelsPerSecond: 100, contentWidth: 1000, viewportWidth: 200) == 800, "never past the end")
        #expect(TimelineZoom.anchoredOffset(anchorTime: 0.1, anchorX: 100, pixelsPerSecond: 100, contentWidth: 1000, viewportWidth: 200) == 0, "never before the start")
        #expect(TimelineZoom.anchoredOffset(anchorTime: .nan, anchorX: 0, pixelsPerSecond: 100, contentWidth: 1000, viewportWidth: 200) == 0)
        #expect(TimelineZoom.anchoredOffset(anchorTime: 5, anchorX: 0, pixelsPerSecond: .infinity, contentWidth: .infinity, viewportWidth: 200) == 0)
    }
}

struct EditorKeyCommandTests {

    private func command(
        _ keyCode: UInt16,
        _ characters: String? = nil,
        _ modifiers: NSEvent.ModifierFlags = [],
        typing: Bool = false,
        list: Bool = false,
        words: Bool = false
    ) -> EditorKeyCommand? {
        EditorKeyCommand.command(
            keyCode: keyCode, characters: characters, modifiers: modifiers,
            isTextInputFocused: typing, isListFocused: list, hasWordSelection: words
        )
    }

    @Test func spacePlaysWhateverHasFocusExceptATextField() {
        #expect(command(49, " ") == .togglePlayback)
        #expect(command(49, " ", list: true) == .togglePlayback)
        #expect(command(49, " ", words: true) == .togglePlayback)
        #expect(command(49, " ", typing: true) == nil)
        #expect(command(49, " ", .command) == nil)
        #expect(command(49, " ", [.numericPad, .function]) == .togglePlayback, "flags that aren't modifiers don't count")
    }

    @Test func mAddsAMarker() {
        #expect(command(46, "m") == .addMarker)
        #expect(command(41, "m") == .addMarker, "M elsewhere on another layout")
        #expect(command(46, "ة") == .addMarker, "the M key on an Arabic layout")
        #expect(command(46, ",") == nil, "a comma there on another layout")
        #expect(command(46, "q") == nil, "another letter there on another layout")
        #expect(command(46, "M", .shift) == nil)
        #expect(command(46, "m", .command) == nil)
        #expect(command(46, "m", typing: true) == nil)
    }

    @Test func deleteTogglesSelectedWordsUnlessTheClipListHasFocus() {
        #expect(command(51, words: true) == .toggleSelectedWords)
        #expect(command(117, words: true) == .toggleSelectedWords)
        #expect(command(51, nil, .command, words: true) == .toggleSelectedWords)
        #expect(command(51) == nil, "nothing selected")
        #expect(command(51, list: true, words: true) == nil, "Delete removes clips in the list")
        #expect(command(51, typing: true, words: true) == nil)
        #expect(command(51, nil, .option, words: true) == nil)
    }
}

@MainActor
struct MarkerTests {

    private func makeModel() -> EditorViewModel {
        EditorViewModel(
            analyzedClips: [makeClip(loud(3), name: "a"), makeClip(loud(2), name: "b")],
            settings: settings()
        )
    }

    @Test func markersAreAddedAtThePlayheadOnce() {
        let model = makeModel()
        model.seek(toSeconds: 1)
        model.addMarker()
        model.seek(toSeconds: 4)
        model.addMarker()
        model.addMarker()
        #expect(model.markers.count == 2, "no second marker at the same spot")
        #expect(model.markers.map(\.clipID) == [model.clips[0].id, model.clips[1].id])
        #expect(model.markerTimes.count == 2)
        #expect(isClose(model.markerTimes[0], 1) && isClose(model.markerTimes[1], 4))
    }

    @Test func markersMoveWithTheirClip() {
        let model = makeModel()
        model.seek(toSeconds: 1)
        model.addMarker()
        model.seek(toSeconds: 4)
        model.addMarker()

        model.moveClips(fromOffsets: IndexSet([1]), toOffset: 0)
        // b (2 s) now comes first: its marker at 1 s, a's at 2 + 1 s.
        #expect(model.markerTimes.count == 2)
        #expect(isClose(model.markerTimes[0], 1) && isClose(model.markerTimes[1], 3))

        model.removeClips([model.clips[1].id])
        #expect(model.markers.count == 1)
        #expect(model.markerTimes.count == 1)
    }

    @Test func noMarkerWithoutMedia() {
        let model = EditorViewModel(analyzedClips: [])
        model.addMarker()
        #expect(model.markers.isEmpty)
    }

    @Test func scrollingWhilePausedKeepsFollowingThePlayhead() {
        let model = makeModel()
        #expect(model.followsPlayhead)
        model.userScrolledTimeline()
        #expect(model.followsPlayhead, "only scrolling during playback stops it")
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AutomaticTranscriptionTests {

    @Test func aClipQueuedDuringARunWaitsItsTurn() async throws {
        let directory = makeTemporaryDirectory("queue")
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = try await MediaFixtures.make(.audioOnly, in: directory, duration: 3)
        let engine = ScriptedEngine(delay: .milliseconds(300))
        let controller = TranscriptionController(engine: engine, cache: nil, defaults: nil, chunkLength: 3)
        let first = Clip(url: audio, duration: CMTime(seconds: 3, preferredTimescale: 600))
        let second = Clip(url: audio, duration: CMTime(seconds: 3, preferredTimescale: 600))

        controller.enqueue([first])
        #expect(controller.isRunning)
        controller.enqueue([second])
        controller.enqueue([first])
        #expect(await waitUntil { controller.completedClipIDs == [first.id, second.id] && controller.phase == .finished })
        #expect(engine.calls.count == 2, "each clip once: nothing was cancelled or repeated")
        #expect(!controller.needsRetry(for: [first, second]))

        controller.enqueue([first])
        #expect(!controller.isRunning, "a complete clip isn't transcribed again")
    }

    @Test func cancellingLeavesARetry() async throws {
        let directory = makeTemporaryDirectory("cancel")
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = try await MediaFixtures.make(.audioOnly, in: directory, duration: 3)
        let controller = TranscriptionController(engine: ScriptedEngine(delay: .milliseconds(500)), cache: nil, defaults: nil, chunkLength: 3)
        let clip = Clip(url: audio, duration: CMTime(seconds: 3, preferredTimescale: 600))

        controller.enqueue([clip])
        controller.cancel()
        #expect(controller.phase == .cancelled)
        #expect(controller.needsRetry(for: [clip]))

        controller.retry([clip])
        #expect(await waitUntil { controller.phase == .finished })
        #expect(controller.completedClipIDs == [clip.id])
        #expect(!controller.needsRetry(for: [clip]))
    }

    @Test func failedPartsAreRetriedAlone() async throws {
        let directory = makeTemporaryDirectory("retry-parts")
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = try await MediaFixtures.make(.audioOnly, in: directory, duration: 7)
        // The 4 s chunk (3–7) fails on its first two tries (one try plus one retry).
        let engine = ScriptedEngine { call, duration in
            if duration > 3.5, call < 3 { throw AgyError.invalidOutput("nope") }
            return [TranscriptSegment(start: 0.5, end: 1.5, text: "words")]
        }
        let controller = TranscriptionController(engine: engine, cache: nil, defaults: nil, chunkLength: 3)
        let clip = Clip(url: audio, duration: CMTime(seconds: 7, preferredTimescale: 600))

        controller.enqueue([clip])
        #expect(await waitUntil { controller.phase == .finished })
        #expect(controller.hasFailedChunks)
        #expect(controller.needsRetry(for: [clip]))
        let callsBefore = engine.calls.count

        controller.retry([clip])
        #expect(await waitUntil { controller.phase == .finished && !controller.isRunning })
        #expect(engine.calls.count == callsBefore + 1, "only the failed chunk")
        #expect(controller.completedClipIDs == [clip.id])
        #expect(controller.transcripts[clip.id]?.map(\.start) == [0.5, 3.5], "the earlier chunk is kept")
    }

    @Test func importingAClipTranscribesItAutomatically() async throws {
        let directory = makeTemporaryDirectory("auto-transcribe")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await MediaFixtures.make(.audioOnly, in: directory, duration: 3)
        var analyzer = AudioLevelAnalyzer(cache: LevelsCache(directory: directory.appending(path: "cache")))
        analyzer.stallTimeout = .seconds(5)
        let engine = ScriptedEngine()
        let controller = TranscriptionController(engine: engine, cache: nil, defaults: nil, chunkLength: 3)
        let model = EditorViewModel(analyzer: analyzer, transcription: controller)

        model.add(urls: [url])
        #expect(await waitUntil(timeout: .seconds(20)) { controller.phase == .finished })
        #expect(model.timelineTranscript.map(\.text) == ["words"])
        #expect(controller.completedClipIDs == Set(model.clips.map(\.id)))
        #expect(engine.calls.count == 1)
        // Speech 0.5–1.5 s: the rest isn't speech.
        #expect(matches(model.nonSpeechRanges, [(0, 0.4), (1.6, 3)], tolerance: 0.05))
    }
}
