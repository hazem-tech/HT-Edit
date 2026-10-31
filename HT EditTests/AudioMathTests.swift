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
        var accumulator = WindowAccumulator(windowDuration: 0.01)
        accumulator.configure(sampleRate: 48_000)
        #expect(accumulator.framesPerWindow == 480)
        #expect(accumulator.sampleRate == 48_000)
    }

    @Test func downmixesAndWindowsSamples() {
        var accumulator = WindowAccumulator(windowDuration: 0.01)
        accumulator.configure(sampleRate: 1_000) // 10 frames per window

        let left = [Float](repeating: 1, count: 25)
        let right = [Float](repeating: 0, count: 25)
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                accumulator.appendMono(channels: [l, r], frames: 25)
            }
        }

        let chunk = accumulator.drain()
        #expect(chunk?.rmsDB.count == 2)
        #expect(chunk?.frameCount == 20)
        // Mono is 0.5 → -6.02 dB.
        #expect(chunk.map { abs($0.rmsDB[0] - (-6.0206)) < 0.001 } == true)
        #expect(chunk.map { abs($0.peakDB[1] - (-6.0206)) < 0.001 } == true)

        #expect(accumulator.drain() == nil)

        // The 5 leftover frames become a final partial window.
        let tail = accumulator.finish()
        #expect(tail?.rmsDB.count == 1)
        #expect(tail?.frameCount == 5)
        #expect(accumulator.finish() == nil)
    }

    @Test func rmsAndPeakDiffer() {
        var accumulator = WindowAccumulator(windowDuration: 0.01)
        accumulator.configure(sampleRate: 1_000)
        var samples = [Float](repeating: 0, count: 10)
        samples[0] = 1
        samples.withUnsafeBufferPointer { accumulator.appendMono(channels: [$0], frames: 10) }

        let chunk = accumulator.drain()
        #expect(chunk.map { abs($0.peakDB[0]) < 0.001 } == true)       // peak 1.0 → 0 dB
        #expect(chunk.map { abs($0.rmsDB[0] - (-10)) < 0.001 } == true) // rms √0.1 → -10 dB
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

    @Test func defaultsAreInsideTheirRanges() {
        let defaults = SilenceSettings.default
        #expect(SilenceSettings.thresholdRange.contains(defaults.thresholdDB))
        #expect(SilenceSettings.paddingRange.contains(defaults.paddingStart))
        #expect(SilenceSettings.paddingRange.contains(defaults.paddingEnd))
        #expect(SilenceSettings.minimumSilenceDurationRange.contains(defaults.minimumSilenceDuration))
    }
}
