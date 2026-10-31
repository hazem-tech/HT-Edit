//
//  AudioMathTests.swift
//  HT EditTests
//

import CoreMedia
import Testing
@testable import HT_Edit

struct DecibelTests {

    @Test(arguments: [
        (Float(1.0), Float(0)),
        (Float(0.1), Float(-20)),
        (Float(0.01), Float(-40)),
        (Float(0.5), Float(-6.0206)),
    ])
    func amplitudeToDecibels(amplitude: Float, expected: Float) {
        let result = WindowAccumulator.decibels([amplitude])
        #expect(abs(result[0] - expected) < 0.001)
    }

    @Test func zeroAmplitudeIsFloored() {
        #expect(WindowAccumulator.decibels([0]) == [AudioLevels.floorDB])
    }

    @Test func emptyInput() {
        #expect(WindowAccumulator.decibels([]).isEmpty)
    }
}

struct WindowAccumulatorTests {

    @Test func windowSizeFollowsSampleRate() {
        #expect(WindowAccumulator.framesPerWindow(sampleRate: 48_000, windowDuration: 0.01) == 480)
        #expect(WindowAccumulator.framesPerWindow(sampleRate: 44_100, windowDuration: 0.01) == 441)
    }

    @Test func downmixesAndWindowsSamples() {
        var accumulator = WindowAccumulator(framesPerWindow: 10)

        let left = [Float](repeating: 1, count: 25)
        let right = [Float](repeating: 0, count: 25)
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                accumulator.appendMono(channels: [l, r], frames: 25)
            }
        }

        let batch = accumulator.drain()
        #expect(batch?.rmsDB.count == 2)
        #expect(batch?.frameCount == 20)
        // Mono is 0.5 → -6.02 dB.
        #expect(batch.map { abs($0.rmsDB[0] - (-6.0206)) < 0.001 } == true)
        #expect(batch.map { abs($0.peakDB[1] - (-6.0206)) < 0.001 } == true)

        #expect(accumulator.drain() == nil)

        // The 5 leftover frames become a final partial window.
        let tail = accumulator.finish()
        #expect(tail?.rmsDB.count == 1)
        #expect(tail?.frameCount == 5)
        #expect(accumulator.finish() == nil)
    }

    @Test func rmsAndPeakDiffer() {
        var accumulator = WindowAccumulator(framesPerWindow: 10)
        var samples = [Float](repeating: 0, count: 10)
        samples[0] = 1
        samples.withUnsafeBufferPointer { accumulator.appendMono(channels: [$0], frames: 10) }

        let batch = accumulator.drain()
        #expect(batch.map { abs($0.peakDB[0]) < 0.001 } == true)       // peak 1.0 → 0 dB
        #expect(batch.map { abs($0.rmsDB[0] - (-10)) < 0.001 } == true) // rms √0.1 → -10 dB
    }
}

struct AudioLevelsTests {

    private func chunk(offset: Int, values: [Float], total: Int = 10) -> AudioLevelsChunk {
        AudioLevelsChunk(
            sampleRate: 1_000, framesPerWindow: 10, totalWindows: total, totalFrames: total * 10,
            windowOffset: offset, rmsDB: values, peakDB: values
        )
    }

    @Test func firstChunkAllocatesTheWholeTrack() {
        var levels = AudioLevels.empty
        levels.apply(chunk(offset: 4, values: [-20, -30]))
        #expect(levels.windowCount == 10)
        #expect(levels.frameCount == 100)
        #expect(levels.rmsDB[4] == -20)
        #expect(levels.rmsDB[5] == -30)
        #expect(levels.rmsDB[0] == AudioLevels.unanalyzed)
        #expect(levels.rmsDB[9] == AudioLevels.unanalyzed)
    }

    @Test func chunksCanArriveOutOfOrder() {
        var levels = AudioLevels.empty
        levels.apply(chunk(offset: 5, values: [-5, -6, -7, -8, -9]))
        levels.apply(chunk(offset: 0, values: [-0, -1, -2, -3, -4]))
        #expect(levels.rmsDB == [-0, -1, -2, -3, -4, -5, -6, -7, -8, -9])
    }

    @Test func overflowingChunkIsClipped() {
        var levels = AudioLevels.empty
        levels.apply(chunk(offset: 8, values: [-1, -2, -3, -4]))
        #expect(levels.windowCount == 10)
        #expect(levels.rmsDB[8] == -1)
        #expect(levels.rmsDB[9] == -2)
    }

    @Test func unanalyzedWindowsAreNeverSilent() {
        var levels = AudioLevels.empty
        levels.apply(chunk(offset: 0, values: [-90, -90, -90], total: 100))
        let silences = SilenceDetector.detect(levels: levels, settings: settings(minimum: 0.01))
        #expect(matches(silences, [(0, 0.03)]))
    }

    @Test func unanalyzedWindowsDrawAsEmpty() {
        #expect(WaveformSampler.normalized(AudioLevels.unanalyzed, floorDB: -80) == 0)
    }
}

struct AudioSegmentPlannerTests {

    @Test func shortTracksUseOneSegment() {
        #expect(AudioSegmentPlanner.segments(totalWindows: 1_500, count: 8) == [0..<1_500])
    }

    @Test func emptyTrackHasNoSegments() {
        #expect(AudioSegmentPlanner.segments(totalWindows: 0, count: 8).isEmpty)
    }

    @Test(arguments: [1, 3, 8, 12])
    func segmentsAreContiguousAndCoverEverything(count: Int) {
        let total = 360_001
        let segments = AudioSegmentPlanner.segments(totalWindows: total, count: count)
        #expect(segments.count == count)
        #expect(segments.first?.lowerBound == 0)
        #expect(segments.last?.upperBound == total)
        for (a, b) in zip(segments, segments.dropFirst()) {
            #expect(a.upperBound == b.lowerBound)
        }
        let lengths = segments.map(\.count)
        #expect((lengths.max() ?? 0) - (lengths.min() ?? 0) <= 1)
    }

    @Test func segmentCountIsLimitedByLength() {
        // 5 000 windows at a 2 000-window minimum → at most 2 segments.
        #expect(AudioSegmentPlanner.segments(totalWindows: 5_000, count: 8).count == 2)
    }
}

struct WaveformSamplerTests {

    @Test func producesRequestedBucketCount() {
        let result = WaveformSampler.buckets([1, 2, 3, 4], startWindow: 0, windowsPerBucket: 2, count: 2)
        #expect(result == [2, 4])
    }

    @Test func bucketsKeepTheMaximum() {
        let result = WaveformSampler.buckets([-50, -10, -60, -30, -20, -70], startWindow: 0, windowsPerBucket: 3, count: 2)
        #expect(result == [-10, -20])
    }

    @Test func zoomedInRepeatsWindows() {
        let result = WaveformSampler.buckets([-10, -20], startWindow: 0, windowsPerBucket: 0.5, count: 4)
        #expect(result == [-10, -10, -20, -20])
    }

    @Test func outOfRangeBucketsUseFill() {
        let result = WaveformSampler.buckets([-10, -20], startWindow: 1, windowsPerBucket: 1, count: 3, fill: -99)
        #expect(result == [-20, -99, -99])
    }

    @Test func negativeStartUsesFill() {
        let result = WaveformSampler.buckets([-10, -20], startWindow: -1, windowsPerBucket: 1, count: 2, fill: -99)
        #expect(result == [-99, -10])
    }

    @Test func emptyInputs() {
        #expect(WaveformSampler.buckets([], startWindow: 0, windowsPerBucket: 1, count: 3, fill: -1) == [-1, -1, -1])
        #expect(WaveformSampler.buckets([1], startWindow: 0, windowsPerBucket: 1, count: 0).isEmpty)
    }

    @Test(arguments: [
        (Float(-80), Float(0)),
        (Float(-40), Float(0.5)),
        (Float(0), Float(1)),
        (Float(-120), Float(0)),
        (Float(6), Float(1)),
    ])
    func normalization(decibels: Float, expected: Float) {
        #expect(WaveformSampler.normalized(decibels, floorDB: -80) == expected)
    }
}

struct PlaybackSkipperTests {
    let silences = [
        CMTimeRange(start: CMTime(value: 1, timescale: 1), end: CMTime(value: 2, timescale: 1)),
        CMTimeRange(start: CMTime(value: 5, timescale: 1), end: CMTime(value: 7, timescale: 1)),
    ]

    @Test(arguments: [
        (0.5, nil),
        (1.0, 2.0),  // start is inclusive
        (1.5, 2.0),
        (2.0, nil),  // end is exclusive
        (4.99, nil),
        (6.0, 7.0),
        (8.0, nil),
    ] as [(Double, Double?)])
    func skipTarget(time: Double, expected: Double?) {
        let target = PlaybackSkipper.skipTarget(for: CMTime(seconds: time, preferredTimescale: 1_000), in: silences)
        #expect(target?.seconds == expected)
    }

    @Test func noSilences() {
        #expect(PlaybackSkipper.skipTarget(for: .zero, in: []) == nil)
    }

    @Test func invalidTime() {
        #expect(PlaybackSkipper.skipTarget(for: .invalid, in: silences) == nil)
    }
}

struct TimeFormattingTests {

    @Test(arguments: [
        (0.0, 1, "0:00.0"),
        (5.25, 2, "0:05.25"),
        (65.0, 0, "1:05"),
        (3_725.5, 1, "1:02:05.5"),
        (-3.0, 1, "0:00.0"),
    ])
    func formats(seconds: Double, digits: Int, expected: String) {
        #expect(TimeFormatting.string(seconds, fractionDigits: digits) == expected)
    }

    @Test func nonFinite() {
        #expect(TimeFormatting.string(.nan) == "--:--")
    }
}

struct SilenceSettingsTests {

    @Test func defaults() {
        let defaults = SilenceSettings.default
        #expect(defaults.thresholdDB == -70)
        #expect(defaults.paddingStart == 0)
        #expect(defaults.paddingEnd == 0)
        #expect(defaults.minimumSilenceDuration == 0.3)
        #expect(SilenceSettings.thresholdRange.contains(defaults.thresholdDB))
    }
}
