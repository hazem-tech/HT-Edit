//
//  TestSupport.swift
//  HT EditTests
//

import CoreMedia
import Foundation
import Testing
@testable import HT_Edit

/// Builds `AudioLevels` from per-window dB values: 1 kHz, 10 frames per window (10 ms).
func makeLevels(_ decibels: [Float], complete: Bool = true, frameCount: Int? = nil) -> AudioLevels {
    var levels = AudioLevels.empty
    levels.apply(AudioLevelsChunk(
        sampleRate: 1_000,
        framesPerWindow: 10,
        totalWindows: decibels.count,
        totalFrames: frameCount ?? decibels.count * 10,
        windowOffset: 0,
        rmsDB: decibels,
        peakDB: decibels
    ))
    levels.isComplete = complete
    return levels
}

/// `seconds` of loud (-10 dB) or silent (-60 dB) windows at 10 ms each.
func loud(_ seconds: Double) -> [Float] { Array(repeating: -10, count: Int((seconds * 100).rounded())) }
func quiet(_ seconds: Double) -> [Float] { Array(repeating: -60, count: Int((seconds * 100).rounded())) }

func settings(
    threshold: Double = -40,
    paddingStart: Double = 0,
    paddingEnd: Double = 0,
    minimum: Double = 0.05
) -> SilenceSettings {
    SilenceSettings(thresholdDB: threshold, paddingStart: paddingStart, paddingEnd: paddingEnd, minimumSilenceDuration: minimum)
}

func isClose(_ a: Double, _ b: Double, tolerance: Double = 0.0005) -> Bool {
    abs(a - b) <= tolerance
}

/// Simplified `(start, end)` seconds for readable assertions.
func seconds(_ ranges: [CMTimeRange]) -> [(Double, Double)] {
    ranges.map { ($0.start.seconds, $0.end.seconds) }
}

func matches(_ ranges: [CMTimeRange], _ expected: [(Double, Double)], tolerance: Double = 0.0005) -> Bool {
    let actual = seconds(ranges)
    guard actual.count == expected.count else { return false }
    return zip(actual, expected).allSatisfy { isClose($0.0, $1.0, tolerance: tolerance) && isClose($0.1, $1.1, tolerance: tolerance) }
}

/// A clip with pre-computed levels, for timeline and view-model tests.
@MainActor
func makeClip(_ decibels: [Float], name: String = "clip") -> (clip: Clip, levels: AudioLevels) {
    let levels = makeLevels(decibels)
    return (Clip(url: URL(filePath: "/tmp/\(name).mov"), name: name, duration: levels.duration), levels)
}

/// A fresh temporary directory, removed by the caller.
func makeTemporaryDirectory(_ label: String = "tests") -> URL {
    FileManager.default.temporaryDirectory.appending(path: "\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
}

/// Polls `condition` on the main actor until it's true or `timeout` passes.
@MainActor
func waitUntil(timeout: Duration = .seconds(15), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        if clock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return true
}
