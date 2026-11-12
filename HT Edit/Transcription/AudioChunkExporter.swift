//
//  AudioChunkExporter.swift
//  HT Edit
//

import AVFoundation

/// Cuts a time range of a media file's audio into a standalone file: `.m4a`
/// for the transcription model, 16 kHz mono `.wav` for the word aligner.
nonisolated enum AudioChunkExporter {
    enum ExportError: LocalizedError {
        case cannotExport

        var errorDescription: String? { "This file's audio can't be exported for transcription." }
    }

    /// Writes the audio in `range` (seconds) of `source` to `destination`, replacing any file there.
    @concurrent
    static func export(_ source: URL, range: Range<Double>, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty,
              let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ExportError.cannotExport
        }
        let timescale: CMTimeScale = 600
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: range.lowerBound, preferredTimescale: timescale),
            end: CMTime(seconds: range.upperBound, preferredTimescale: timescale)
        )
        try? FileManager.default.removeItem(at: destination)
        try await session.export(to: destination, as: .m4a)
    }

    /// The sample rate the word aligner listens at.
    static let alignerSampleRate = 16_000

    /// Writes the audio in `range` (seconds) of `source` to `destination` as
    /// 16 kHz mono 16-bit PCM WAV, replacing any file there.
    @concurrent
    static func exportWAV(_ source: URL, range: Range<Double>, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ExportError.cannotExport
        }
        let rate = alignerSampleRate
        let reader = try AVAssetReader(asset: asset)
        let expectedFrames = max(0, Int(((range.upperBound - range.lowerBound) * Double(rate)).rounded()))
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: range.lowerBound, preferredTimescale: CMTimeScale(rate)),
            duration: CMTime(value: CMTimeValue(expectedFrames), timescale: CMTimeScale(rate))
        )
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        let provider = reader.outputProvider(for: output)
        try reader.start()
        defer {
            if reader.status == .reading { reader.cancelReading() }
        }

        var pcm = Data()
        pcm.reserveCapacity(expectedFrames * 2)
        // Stop once every frame is in instead of waiting for the end of data.
        var frames = 0
        while frames < expectedFrames, let sampleBuffer = try await provider.next() {
            try Task.checkCancellation()
            frames += sampleBuffer.sampleCount
            try sampleBuffer.withUnsafeSampleBuffer { buffer in
                try buffer.withAudioBufferList { list, _ in
                    for channel in list {
                        guard let data = channel.mData else { continue }
                        pcm.append(data.assumingMemoryBound(to: UInt8.self), count: Int(channel.mDataByteSize))
                    }
                }
            }
        }
        guard reader.status != .failed else { throw reader.error ?? ExportError.cannotExport }
        pcm = pcm.prefix(expectedFrames * 2)

        try? FileManager.default.removeItem(at: destination)
        try (wavHeader(dataSize: pcm.count, sampleRate: rate) + pcm).write(to: destination, options: .atomic)
    }

    /// The 44-byte header of a mono 16-bit PCM WAV file.
    static func wavHeader(dataSize: Int, sampleRate: Int) -> Data {
        var header = Data()
        func text(_ string: String) { header.append(contentsOf: Array(string.utf8)) }
        func integer<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
        }
        text("RIFF")
        integer(UInt32(36 + dataSize))
        text("WAVE")
        text("fmt ")
        integer(UInt32(16))
        integer(UInt16(1)) // PCM
        integer(UInt16(1)) // mono
        integer(UInt32(sampleRate))
        integer(UInt32(sampleRate * 2)) // bytes per second
        integer(UInt16(2)) // bytes per frame
        integer(UInt16(16)) // bits per sample
        text("data")
        integer(UInt32(dataSize))
        return header
    }
}
