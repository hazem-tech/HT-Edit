//
//  WarmUp.swift
//  HT Edit
//

import AVFoundation
import os

/// Runs the import pipeline once on a tiny generated clip while the splash
/// screen is up, so frameworks, the AAC decoder, `AVAssetReader`, the player
/// and the Metal-backed canvas are all loaded before the first real import.
enum WarmUp {
    /// Upper bound on how long launch may wait for warm-up.
    static let timeLimit: Duration = .seconds(2)

    /// Returns after warm-up or `timeLimit`, whichever comes first. Uses the
    /// stall watchdog (not a task group, which would wait for a stuck child),
    /// so launch can never be blocked.
    static func run() async {
        let clock = ContinuousClock()
        let started = clock.now
        do {
            try await StallWatchdog.run(timeout: timeLimit, progress: ProgressMarker()) {
                await perform()
            }
            Log.importing.notice("Warm-up finished in \((clock.now - started).description, privacy: .public)")
        } catch {
            Log.importing.error("Warm-up skipped after \((clock.now - started).description, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func perform() async {
        guard let url = await makeSampleFile() else { return }
        defer { try? FileManager.default.removeItem(at: url) }

        // Decoder + reader + vDSP path (no cache, so it really decodes).
        _ = try? await AudioLevelAnalyzer(segmentCount: 2, cache: nil).analyzeAll(url: url)

        // Composition + player item path.
        if let item = try? await CompositionBuilder.makePlayerItem(
            for: [.init(url: url, duration: CMTime(value: 1, timescale: 2))]
        ) {
            let player = AVPlayer(playerItem: item)
            _ = try? await item.asset.load(.duration, .tracks)
            player.replaceCurrentItem(with: nil)
        }
    }

    /// Writes 0.5 s of quiet AAC audio to a temporary `.m4a`.
    @concurrent
    nonisolated private static func makeSampleFile() async -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "htedit-warmup-\(UUID().uuidString).m4a", directoryHint: .notDirectory)
        let sampleRate = 48_000.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate / 2)),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) {
            let value = Float(0.1 * sin(2 * .pi * 440 * Double(frame) / sampleRate))
            channels[0][frame] = value
            channels[1][frame] = value
        }
        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: 2,
                ],
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try file.write(from: buffer)
            file.close()
            return url
        } catch {
            return nil
        }
    }
}
