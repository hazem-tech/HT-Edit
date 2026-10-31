//
//  CompositionBuilder.swift
//  HT Edit
//

import AVFoundation

/// Builds one seamless player item from clips placed back to back.
///
/// Inserting into an `AVMutableComposition` only edits metadata (no media is
/// copied or decoded), so rebuilding after an import or reorder is near-instant.
enum CompositionBuilder {

    struct Source {
        var url: URL
        var duration: CMTime
    }

    private struct PlacedVideo {
        var track: AVAssetTrack
        var sourceRange: CMTimeRange
        var timelineStart: CMTime
        var naturalSize: CGSize
        var transform: CGAffineTransform
    }

    static func makePlayerItem(for sources: [Source]) async throws -> AVPlayerItem {
        let composition = AVMutableComposition()
        let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var videos: [PlacedVideo] = []
        var timelineRanges: [CMTimeRange] = []
        var cursor = CMTime.zero

        for source in sources where source.duration.isNumeric && source.duration > .zero {
            let asset = AVURLAsset(url: source.url)
            let clipRange = CMTimeRange(start: .zero, duration: source.duration)

            if let audio = try await asset.loadTracks(withMediaType: .audio).first {
                let available = try await audio.load(.timeRange).intersection(clipRange)
                if available.duration > .zero {
                    try audioTrack?.insertTimeRange(available, of: audio, at: cursor + available.start)
                }
            }
            if let video = try await asset.loadTracks(withMediaType: .video).first {
                let (timeRange, naturalSize, transform) = try await video.load(.timeRange, .naturalSize, .preferredTransform)
                let available = timeRange.intersection(clipRange)
                if available.duration > .zero {
                    videos.append(PlacedVideo(
                        track: video,
                        sourceRange: available,
                        timelineStart: cursor + available.start,
                        naturalSize: naturalSize,
                        transform: transform
                    ))
                }
            }
            timelineRanges.append(CMTimeRange(start: cursor, duration: source.duration))
            cursor = cursor + source.duration
        }

        guard let first = videos.first else {
            return AVPlayerItem(asset: composition)
        }

        let isUniform = videos.allSatisfy { $0.naturalSize == first.naturalSize && $0.transform == first.transform }
        if isUniform {
            // Fast path: one track, rotation via preferredTransform, no video compositor.
            let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            for video in videos {
                try track?.insertTimeRange(video.sourceRange, of: video.track, at: video.timelineStart)
            }
            track?.preferredTransform = first.transform
            return AVPlayerItem(asset: composition)
        }

        // Mixed sizes/orientations: one track per clip, each aspect-fitted into
        // the first clip's frame by a video composition.
        let renderSize = presentationSize(naturalSize: first.naturalSize, transform: first.transform)
        var compositionTracks: [(AVMutableCompositionTrack, PlacedVideo)] = []
        for video in videos {
            guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try track.insertTimeRange(video.sourceRange, of: video.track, at: video.timelineStart)
            compositionTracks.append((track, video))
        }

        var configuration = try await AVVideoComposition.Configuration(for: composition, prototypeInstruction: nil)
        configuration.renderSize = renderSize
        configuration.instructions = timelineRanges.map { range in
            let layers = compositionTracks
                .filter { CMTimeRangeContainsTime(range, time: $0.1.timelineStart) }
                .map { track, video in
                    var layer = AVVideoCompositionLayerInstruction.Configuration(trackID: track.trackID)
                    layer.setTransform(
                        aspectFitTransform(naturalSize: video.naturalSize, transform: video.transform, into: renderSize),
                        at: range.start
                    )
                    return AVVideoCompositionLayerInstruction(configuration: layer)
                }
            return AVVideoCompositionInstruction(configuration: .init(layerInstructions: layers, timeRange: range))
        }

        let item = AVPlayerItem(asset: composition)
        item.videoComposition = AVVideoComposition(configuration: configuration)
        return item
    }

    /// Display size of a track once its rotation is applied.
    nonisolated static func presentationSize(naturalSize: CGSize, transform: CGAffineTransform) -> CGSize {
        let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    /// Rotates a track upright, scales it to fit `renderSize`, and centers it.
    nonisolated static func aspectFitTransform(naturalSize: CGSize, transform: CGAffineTransform, into renderSize: CGSize) -> CGAffineTransform {
        let rotated = CGRect(origin: .zero, size: naturalSize).applying(transform)
        guard rotated.width > 0, rotated.height > 0 else { return transform }
        let scale = min(renderSize.width / rotated.width, renderSize.height / rotated.height)
        let offsetX = (renderSize.width - rotated.width * scale) / 2
        let offsetY = (renderSize.height - rotated.height * scale) / 2
        return transform
            .concatenating(CGAffineTransform(translationX: -rotated.minX, y: -rotated.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: offsetX, y: offsetY))
    }
}
