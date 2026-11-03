//
//  AudioChunkExporter.swift
//  HT Edit
//

import AVFoundation

/// Cuts a time range of a media file's audio into a standalone `.m4a` file,
/// the input format for the transcription model.
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
}
