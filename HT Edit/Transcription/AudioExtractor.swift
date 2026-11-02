//
//  AudioExtractor.swift
//  HT Edit
//

import AVFoundation

/// Re-encodes a clip's audio as small mono AAC for upload: 16 kHz, ~32 kbps
/// (about 240 KB per minute), so a whole clip fits in one inline request.
/// Speech recognition loses nothing at this quality, and Gemini bills audio
/// by duration, not by bytes.
nonisolated enum AudioExtractor {
    static let sampleRate = 16_000.0
    static let bitRate = 32_000
    static let mimeType = "audio/m4a"
    /// Audio after which nothing is delivered for this long is abandoned.
    static let stallTimeout: Duration = .seconds(15)

    /// Encodes the first audio track of `url` (optionally only `timeRange`, in
    /// asset time) and returns the m4a bytes.
    @concurrent
    static func extract(url: URL, timeRange: CMTimeRange? = nil) async throws -> Data {
        let output = URL.temporaryDirectory.appending(path: "transcribe-\(UUID().uuidString).m4a", directoryHint: .notDirectory)
        defer { try? FileManager.default.removeItem(at: output) }

        await ReaderLimiter.shared.acquire()
        do {
            let progress = ProgressMarker()
            try await StallWatchdog.run(timeout: stallTimeout, progress: progress) {
                try await encode(url: url, timeRange: timeRange, to: output, progress: progress)
            }
            await ReaderLimiter.shared.release()
        } catch {
            await ReaderLimiter.shared.release()
            throw error
        }
        return try Data(contentsOf: output)
    }

    @concurrent
    private static func encode(url: URL, timeRange: CMTimeRange?, to output: URL, progress: ProgressMarker) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AnalysisError.noAudioTrack
        }

        let reader = try AVAssetReader(asset: asset)
        let expectedFrames: Int
        if let timeRange {
            reader.timeRange = timeRange
            expectedFrames = Int((timeRange.duration.seconds * sampleRate).rounded(.up))
        } else {
            expectedFrames = Int.max
        }
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
        ])
        let provider = reader.outputProvider(for: trackOutput)

        let file = try makeFile(at: output)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            throw AnalysisError.unsupportedFormat
        }

        try reader.start()
        defer {
            if reader.status == .reading { reader.cancelReading() }
        }

        var written = 0
        while written < expectedFrames, let sampleBuffer = try await provider.next() {
            try Task.checkCancellation()
            progress.touch()
            written += sampleBuffer.sampleCount
            try sampleBuffer.withUnsafeSampleBuffer { buffer in
                try buffer.withAudioBufferList { list, _ in
                    guard let channel = list.first, let data = channel.mData else { return }
                    let frames = Int(channel.mDataByteSize) / MemoryLayout<Float>.stride
                    guard frames > 0,
                          let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                          let destination = pcm.floatChannelData?[0] else { return }
                    destination.update(from: data.assumingMemoryBound(to: Float.self), count: frames)
                    pcm.frameLength = AVAudioFrameCount(frames)
                    try file.write(from: pcm)
                }
            }
        }
        if reader.status == .failed {
            throw AnalysisError.readerFailed(reader.error?.localizedDescription ?? "Unknown error")
        }
        file.close()
    }

    /// An AAC file at the target bit rate, or the encoder's default rate if it refuses that one.
    private static func makeFile(at url: URL) throws -> AVAudioFile {
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate,
        ]
        do {
            return try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            settings[AVEncoderBitRateKey] = nil
            return try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        }
    }
}
