//
//  SpeechAudioExtractor.swift
//  HT Edit
//

import AVFoundation
import CoreMedia

/// Decodes a media file's first audio track to 16 kHz mono Float32 samples,
/// the input speech models expect. Works for video files too (AVAssetReader,
/// not AVAudioFile).
nonisolated enum SpeechAudioExtractor {
    static let sampleRate: Double = 16_000

    /// All samples of the first audio track. Throws `AnalysisError.noAudioTrack`
    /// for files without audio.
    @concurrent
    static func samples(
        from url: URL,
        limiter: ReaderLimiter = .shared,
        stallTimeout: Duration = .seconds(15)
    ) async throws -> [Float] {
        await limiter.acquire()
        do {
            let progress = ProgressMarker()
            let samples = try await StallWatchdog.run(timeout: stallTimeout, progress: progress) {
                try await decode(url: url, progress: progress)
            }
            await limiter.release()
            return samples
        } catch {
            await limiter.release()
            throw error
        }
    }

    @concurrent
    private static func decode(url: URL, progress: ProgressMarker) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AnalysisError.noAudioTrack
        }
        let timeRange = try await track.load(.timeRange)
        let expectedFrames = max(0, Int((timeRange.duration.seconds * sampleRate).rounded(.down)))
        guard expectedFrames > 0 else { return [] }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        let provider = reader.outputProvider(for: output)
        try reader.start()
        defer {
            if reader.status == .reading { reader.cancelReading() }
        }

        var samples: [Float] = []
        samples.reserveCapacity(expectedFrames)
        // Stop once every frame has arrived instead of waiting for the provider
        // to signal the end of data (see AudioLevelAnalyzer).
        while samples.count < expectedFrames, let sampleBuffer = try await provider.next() {
            try Task.checkCancellation()
            progress.touch()
            try sampleBuffer.withUnsafeSampleBuffer { buffer in
                try buffer.withAudioBufferList { list, _ in
                    guard let first = list.first, let data = first.mData else { return }
                    let count = Int(first.mDataByteSize) / MemoryLayout<Float>.stride
                    samples.append(contentsOf: UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
                }
            }
        }
        if reader.status == .failed {
            throw AnalysisError.readerFailed(reader.error?.localizedDescription ?? "Unknown error")
        }
        try Task.checkCancellation()
        return samples
    }

    /// Writes 16 kHz mono samples to a CAF file (for engines that read files).
    static func writeAudioFile(_ samples: [Float], to url: URL) throws {
        guard !samples.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw AnalysisError.unsupportedFormat
        }
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                channel.update(from: base, count: source.count)
            }
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        file.close()
    }
}
