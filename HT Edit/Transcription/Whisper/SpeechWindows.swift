//
//  SpeechWindows.swift
//  HT Edit
//
//  Whisper does best on windows of about 25 seconds cut at pauses: one long
//  pass loops on repeated takes, and short chunks lose the context it needs.
//  This finds the speech in a clip and packs it into such windows.
//

import AVFoundation
import Foundation

nonisolated enum SpeechWindows {
    /// Seconds per loudness frame.
    static let hop = 0.02

    /// Clip-second ranges to transcribe, from per-frame loudness in dBFS (one value per `hop`).
    ///
    /// - Speech is anything 10 dB above the noise floor (but at least -50 dB);
    ///   when there are almost no pauses, 15 dB below the loud parts.
    /// - Pauses under 0.25 s are bridged; blips under 0.12 s are ignored.
    /// - Windows close at a pause before passing `maxWindow` seconds, or at a gap over 6 s.
    ///   Speech without any pause that long is split at its quietest moment.
    /// - Each window gets `padding` seconds either side, without overlapping its neighbors.
    static func plan(levels: [Float], duration: Double, maxWindow: Double = 25, padding: Double = 0.25) -> [Range<Double>] {
        guard !levels.isEmpty, duration > 0 else { return [] }
        let sorted = levels.sorted()
        func percentile(_ p: Double) -> Double { Double(sorted[Int(Double(sorted.count - 1) * p)]) }
        let noise = percentile(0.10), loud = percentile(0.90)
        guard loud > -50 else { return [] }   // nothing louder than a quiet room
        var threshold = Float(max(noise + 10, -50))
        // Speech with hardly any pauses: the "floor" is the speech itself.
        if Double(threshold) >= loud - 3 { threshold = Float(loud - 15) }

        // Runs of frames above the threshold, in frame indices.
        var runs: [(start: Int, end: Int)] = []
        var runStart: Int?
        for (index, level) in levels.enumerated() {
            if level > threshold {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                runs.append((start, index))
                runStart = nil
            }
        }
        if let start = runStart { runs.append((start, levels.count)) }

        var merged: [(start: Int, end: Int)] = []
        for run in runs {
            if let last = merged.last, Double(run.start - last.end) * hop < 0.25 {
                merged[merged.count - 1].end = run.end
            } else {
                merged.append(run)
            }
        }
        let regions = merged
            .filter { Double($0.end - $0.start) * hop >= 0.12 }
            .flatMap { split($0, levels: levels, maxFrames: Int(maxWindow / hop)) }

        var windows: [(start: Int, end: Int)] = []
        for region in regions {
            if let last = windows.last,
               Double(region.end - last.start) * hop <= maxWindow,
               Double(region.start - last.end) * hop <= 6 {
                windows[windows.count - 1].end = region.end
            } else {
                windows.append(region)
            }
        }

        var ranges = windows.map { (Double($0.start) * hop - padding, Double($0.end) * hop + padding) }
        for index in ranges.indices {
            ranges[index].0 = max(0, ranges[index].0)
            ranges[index].1 = min(duration, ranges[index].1)
            if index > 0, ranges[index].0 < ranges[index - 1].1 {
                let middle = (ranges[index].0 + ranges[index - 1].1) / 2
                ranges[index - 1].1 = middle
                ranges[index].0 = middle
            }
        }
        return ranges.filter { $0.1 > $0.0 }.map { $0.0..<$0.1 }
    }

    /// Splits a region longer than `maxFrames` at its quietest 0.2 s between 35 % and 65 % of its length.
    private static func split(_ region: (start: Int, end: Int), levels: [Float], maxFrames: Int) -> [(start: Int, end: Int)] {
        let length = region.end - region.start
        guard length > maxFrames, length >= 20 else { return [region] }
        let low = region.start + length * 35 / 100, high = region.start + length * 65 / 100
        var best = low, bestLevel = Float.infinity
        for index in low..<high {
            let window = levels[max(region.start, index - 5)..<min(region.end, index + 5)]
            let average = window.reduce(0, +) / Float(window.count)
            if average < bestLevel { bestLevel = average; best = index }
        }
        return split((region.start, best), levels: levels, maxFrames: maxFrames)
            + split((best, region.end), levels: levels, maxFrames: maxFrames)
    }
}

/// Reads a file's audio as 16 kHz mono, the format Whisper wants.
nonisolated enum MonoAudio {
    static let sampleRate = 16_000.0

    enum ReadError: LocalizedError {
        case noAudio
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .noAudio: "This file has no audio to transcribe."
            case .unreadable(let reason): "The audio couldn't be read: \(reason)"
            }
        }
    }

    /// Streams the audio (all tracks mixed) as 16 kHz mono Float32 buffers.
    static func read(_ url: URL, _ body: ([Float]) -> Void) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw ReadError.noAudio }
        let duration = try await asset.load(.duration)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        let provider = reader.outputProvider(for: output)
        try reader.start()
        defer {
            if reader.status == .reading { reader.cancelReading() }
        }
        // Stop once the whole duration is in rather than waiting for the provider to signal the end.
        let expected = Int(duration.seconds.isFinite ? duration.seconds * sampleRate : .infinity)
        var decoded = 0
        while decoded < expected, let sampleBuffer = try await provider.next() {
            try Task.checkCancellation()
            decoded += sampleBuffer.sampleCount
            let samples: [Float] = sampleBuffer.withUnsafeSampleBuffer { buffer in
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { return [] }
                let length = CMBlockBufferGetDataLength(block)
                var samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
                let status = samples.withUnsafeMutableBytes { raw in
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count, destination: raw.baseAddress!)
                }
                return status == kCMBlockBufferNoErr ? samples : []
            }
            if !samples.isEmpty { body(samples) }
        }
        if reader.status == .failed {
            throw ReadError.unreadable(reader.error?.localizedDescription ?? "unknown error")
        }
    }

    /// Loudness per `SpeechWindows.hop` frame, in dBFS.
    @concurrent
    static func levels(_ url: URL) async throws -> [Float] {
        let frame = Int(sampleRate * SpeechWindows.hop)
        var levels: [Float] = []
        var sum: Float = 0, count = 0
        try await read(url) { samples in
            for sample in samples {
                sum += sample * sample
                count += 1
                if count == frame {
                    levels.append(10 * log10(sum / Float(frame) + 1e-12))
                    sum = 0
                    count = 0
                }
            }
        }
        return levels
    }

    /// Writes the audio as a 16 kHz mono 16-bit WAV file.
    @concurrent
    static func writeWAV(from source: URL, to destination: URL) async throws {
        var pcm = Data()
        try await read(source) { samples in
            pcm.reserveCapacity(pcm.count + samples.count * 2)
            for sample in samples {
                let value = Int16(max(-1, min(1, sample)) * 32767)
                withUnsafeBytes(of: value.littleEndian) { pcm.append(contentsOf: $0) }
            }
        }
        var file = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { file.append(contentsOf: $0) } }
        file.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + pcm.count))
        file.append(contentsOf: Array("WAVE".utf8))
        file.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        file.append(contentsOf: Array("data".utf8)); append(UInt32(pcm.count))
        file.append(pcm)
        try file.write(to: destination, options: .atomic)
    }
}
