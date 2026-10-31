//
//  SilenceDetectorTests.swift
//  HT EditTests
//

import CoreMedia
import Testing
@testable import HT_Edit

struct SilenceDetectorTests {

    // MARK: silentRuns

    @Test func silentRunsGroupsConsecutiveWindows() {
        let runs = SilenceDetector.silentRuns(in: [-10, -50, -50, -10, -50], thresholdDB: -40)
        #expect(runs == [1..<3, 4..<5])
    }

    @Test func levelEqualToThresholdIsNotSilent() {
        #expect(SilenceDetector.silentRuns(in: [-40, -40], thresholdDB: -40).isEmpty)
    }

    @Test func emptyLevelsProduceNoSilences() {
        #expect(SilenceDetector.detect(levels: .empty, settings: .default).isEmpty)
    }

    // MARK: detect

    @Test func allLoudProducesNoSilences() {
        let levels = makeLevels(loud(3))
        #expect(SilenceDetector.detect(levels: levels, settings: settings()).isEmpty)
    }

    @Test func allSilentIsOneRangeWithoutEdgePadding() {
        let levels = makeLevels(quiet(2))
        let result = SilenceDetector.detect(levels: levels, settings: settings(paddingStart: 0.1, paddingEnd: 0.1))
        #expect(matches(result, [(0, 2)]))
    }

    @Test func detectsGapBetweenSpeech() {
        let levels = makeLevels(loud(1) + quiet(1) + loud(1))
        let result = SilenceDetector.detect(levels: levels, settings: settings())
        #expect(matches(result, [(1, 2)]))
    }

    @Test func detectsMultipleGapsInOrder() {
        let levels = makeLevels(loud(1) + quiet(0.5) + loud(1) + quiet(0.8) + loud(0.5))
        let result = SilenceDetector.detect(levels: levels, settings: settings())
        #expect(matches(result, [(1, 1.5), (2.5, 3.3)]))
    }

    @Test func paddingStartOnlyMovesTheStartEdge() {
        let levels = makeLevels(loud(1) + quiet(1) + loud(1))
        let result = SilenceDetector.detect(levels: levels, settings: settings(paddingStart: 0.15))
        #expect(matches(result, [(1.15, 2)]))
    }

    @Test func paddingEndOnlyMovesTheEndEdge() {
        let levels = makeLevels(loud(1) + quiet(1) + loud(1))
        let result = SilenceDetector.detect(levels: levels, settings: settings(paddingEnd: 0.25))
        #expect(matches(result, [(1, 1.75)]))
    }

    @Test func paddingOnBothSides() {
        let levels = makeLevels(loud(1) + quiet(1) + loud(1))
        let result = SilenceDetector.detect(levels: levels, settings: settings(paddingStart: 0.1, paddingEnd: 0.2))
        #expect(matches(result, [(1.1, 1.8)]))
    }

    @Test func paddingLargerThanGapRemovesIt() {
        let levels = makeLevels(loud(1) + quiet(0.3) + loud(1))
        let result = SilenceDetector.detect(levels: levels, settings: settings(paddingStart: 0.2, paddingEnd: 0.2))
        #expect(result.isEmpty)
    }

    @Test(arguments: [
        (0.1, 1), // 0.2 s gap is kept when the minimum is 0.1 s
        (0.2, 1), // exactly the minimum is kept
        (0.3, 0), // shorter than the minimum is dropped
    ])
    func minimumDurationFilter(minimum: Double, expectedCount: Int) {
        let levels = makeLevels(loud(1) + quiet(0.2) + loud(1))
        let result = SilenceDetector.detect(levels: levels, settings: settings(minimum: minimum))
        #expect(result.count == expectedCount)
    }

    @Test func minimumDurationIsCheckedBeforePadding() {
        // 0.4 s gap, 0.3 s minimum: kept, then padded down to 0.2 s.
        let levels = makeLevels(loud(1) + quiet(0.4) + loud(1))
        let result = SilenceDetector.detect(levels: levels, settings: settings(paddingStart: 0.1, paddingEnd: 0.1, minimum: 0.3))
        #expect(matches(result, [(1.1, 1.3)]))
    }

    @Test(arguments: [
        (-60.0, 0), // gap at -50 dB is louder than a -60 dB threshold
        (-40.0, 1), // and quieter than a -40 dB threshold
    ])
    func thresholdDecidesWhatIsSilent(threshold: Double, expectedCount: Int) {
        let gap = [Float](repeating: -50, count: 100)
        let levels = makeLevels(loud(1) + gap + loud(1))
        let result = SilenceDetector.detect(levels: levels, settings: settings(threshold: threshold))
        #expect(result.count == expectedCount)
    }

    @Test func leadingSilenceGetsNoStartPadding() {
        let levels = makeLevels(quiet(0.5) + loud(1))
        let result = SilenceDetector.detect(levels: levels, settings: settings(paddingStart: 0.1, paddingEnd: 0.1))
        #expect(matches(result, [(0, 0.4)]))
    }

    @Test func trailingSilenceGetsNoEndPaddingWhenComplete() {
        let levels = makeLevels(loud(1) + quiet(0.5), complete: true)
        let result = SilenceDetector.detect(levels: levels, settings: settings(paddingStart: 0.1, paddingEnd: 0.1))
        #expect(matches(result, [(1.1, 1.5)]))
    }

    @Test func trailingSilenceIsPaddedWhileAnalysisIsInProgress() {
        let levels = makeLevels(loud(1) + quiet(0.5), complete: false)
        let result = SilenceDetector.detect(levels: levels, settings: settings(paddingStart: 0.1, paddingEnd: 0.1))
        #expect(matches(result, [(1.1, 1.4)]))
    }

    @Test func partialLastWindowIsClampedToMediaEnd() {
        // 150 windows of 10 frames, but only 1495 frames of audio.
        let levels = makeLevels(loud(1) + quiet(0.5), frameCount: 1_495)
        let result = SilenceDetector.detect(levels: levels, settings: settings())
        #expect(matches(result, [(1, 1.495)]))
    }

    @Test func rangesUseTheAudioSampleRateAsTimescale() {
        let levels = makeLevels(loud(1) + quiet(1) + loud(1))
        let result = SilenceDetector.detect(levels: levels, settings: settings())
        #expect(result.first?.start == CMTime(value: 1_000, timescale: 1_000))
        #expect(result.first?.start.timescale == 1_000)
    }

    @Test func totalDurationSumsRanges() {
        let levels = makeLevels(loud(1) + quiet(0.5) + loud(1) + quiet(0.8) + loud(0.5))
        let result = SilenceDetector.detect(levels: levels, settings: settings())
        #expect(isClose(SilenceDetector.totalDuration(of: result).seconds, 1.3))
    }

    @Test func hourLongInputIsFast() {
        // ~360k windows: one hour of audio at 10 ms windows.
        var decibels: [Float] = []
        decibels.reserveCapacity(360_000)
        for second in 0..<3_600 {
            decibels += second.isMultiple(of: 3) ? quiet(1) : loud(1)
        }
        let levels = makeLevels(decibels)
        let clock = ContinuousClock()
        var result: [CMTimeRange] = []
        let elapsed = clock.measure {
            result = SilenceDetector.detect(levels: levels, settings: settings())
        }
        #expect(result.count == 1_200)
        // Generous bound so unoptimized Debug test builds never flake; Release is ~1 ms.
        #expect(elapsed < .milliseconds(250))
    }
}
