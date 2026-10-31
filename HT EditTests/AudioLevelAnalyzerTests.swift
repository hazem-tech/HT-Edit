//
//  AudioLevelAnalyzerTests.swift
//  HT EditTests
//

import AVFoundation
import Foundation
import Testing
@testable import HT_Edit

/// End-to-end: real file → AVAssetReader → vDSP windows → silence detection.
struct AudioLevelAnalyzerTests {

    /// Writes a stereo 48 kHz file: 1 s tone, 1 s digital silence, 1 s tone.
    private static func makeToneSilenceToneFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tone-silence-tone-\(UUID().uuidString).caf")
        let sampleRate = 48_000.0
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)

        let frames = AVAudioFrameCount(sampleRate * 3)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channels = try #require(buffer.floatChannelData)
        for frame in 0..<Int(frames) {
            let time = Double(frame) / sampleRate
            let isSilent = time >= 1 && time < 2
            let value = isSilent ? 0 : Float(0.5 * sin(2 * .pi * 440 * time))
            channels[0][frame] = value
            channels[1][frame] = value
        }
        try file.write(from: buffer)
        file.close()
        return url
    }

    @Test func analyzesWholeFileAndFindsTheGap() async throws {
        let url = try Self.makeToneSilenceToneFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let levels = try await AudioLevelAnalyzer().analyzeAll(url: url)

        #expect(levels.isComplete)
        #expect(levels.sampleRate == 48_000)
        #expect(levels.framesPerWindow == 480)
        #expect(isClose(levels.duration.seconds, 3, tolerance: 0.001))
        #expect(levels.windowCount == 300)

        // A 0.5 amplitude sine has RMS ≈ 0.354 → ≈ -9 dB.
        #expect(abs(levels.rmsDB[50] - (-9.03)) < 0.1)
        #expect(levels.rmsDB[150] == AudioLevels.floorDB)

        let silences = SilenceDetector.detect(
            levels: levels,
            settings: SilenceSettings(thresholdDB: -40, paddingStart: 0, paddingEnd: 0, minimumSilenceDuration: 0.3)
        )
        #expect(matches(silences, [(1, 2)], tolerance: 0.011))

        let padded = SilenceDetector.detect(
            levels: levels,
            settings: SilenceSettings(thresholdDB: -40, paddingStart: 0.1, paddingEnd: 0.2, minimumSilenceDuration: 0.3)
        )
        #expect(matches(padded, [(1.1, 1.8)], tolerance: 0.011))
    }

    @Test func streamsProgressively() async throws {
        let url = try Self.makeToneSilenceToneFile()
        defer { try? FileManager.default.removeItem(at: url) }

        var analyzer = AudioLevelAnalyzer()
        analyzer.chunkInterval = .zero
        var chunkCount = 0
        var totalFrames = 0
        for try await chunk in analyzer.levels(for: url) {
            chunkCount += 1
            totalFrames += chunk.frameCount
        }
        #expect(chunkCount > 1)
        #expect(totalFrames == 144_000)
    }

    @Test func stoppingEarlyEndsTheStream() async throws {
        let url = try Self.makeToneSilenceToneFile()
        defer { try? FileManager.default.removeItem(at: url) }

        var analyzer = AudioLevelAnalyzer()
        analyzer.chunkInterval = .zero
        var received = 0
        for try await _ in analyzer.levels(for: url) {
            received += 1
            break
        }
        #expect(received == 1)
    }

    @Test func cancellingTheConsumerStopsAnalysis() async throws {
        let url = try Self.makeToneSilenceToneFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let task = Task {
            try await AudioLevelAnalyzer().analyzeAll(url: url)
        }
        task.cancel()
        // Either finishes with a cancellation error or (if it already finished) a result;
        // what matters is that it does not hang.
        _ = await task.result
    }

    @Test func unreadableFileThrows() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-video-\(UUID().uuidString).mov")
        try Data("definitely not a movie".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: (any Error).self) {
            _ = try await AudioLevelAnalyzer().analyzeAll(url: url)
        }
    }
}
