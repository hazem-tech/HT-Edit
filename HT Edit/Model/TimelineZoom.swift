//
//  TimelineZoom.swift
//  HT Edit
//

import CoreGraphics
import Foundation

/// Pure zoom math for the timeline, kept apart from the view so it can be
/// tested and so every value handed to layout is finite and bounded.
///
/// Zoom 1 fits the whole timeline in the visible width. The maximum zoom is
/// limited both by detail (pixels per second; past that the 10 ms analysis
/// windows just repeat) and by total content width (very wide scroll content
/// is what used to take the app down while dragging the zoom slider).
nonisolated enum TimelineZoom {
    /// No point drawing more than this many points per second of media.
    static let maxPixelsPerSecond: Double = 1_000
    /// Upper bound on the scroll content width, in points.
    static let maxContentWidth: Double = 1_000_000
    /// Upper bound on the zoom factor regardless of media length.
    static let maxZoomFactor: Double = 400

    /// Duration in seconds that's safe to divide by.
    static func safeDuration(_ seconds: Double) -> Double {
        seconds.isFinite && seconds > 0 ? seconds : 1
    }

    /// Width that's safe to multiply and divide by.
    static func safeWidth(_ width: CGFloat) -> Double {
        let value = Double(width)
        return value.isFinite && value >= 1 ? value : 1
    }

    /// The largest useful zoom for this media and viewport (always ≥ 1).
    static func maxZoom(duration: Double, visibleWidth: CGFloat) -> Double {
        let duration = safeDuration(duration)
        let width = safeWidth(visibleWidth)
        let byDetail = maxPixelsPerSecond * duration / width
        let byWidth = maxContentWidth / width
        let limit = min(maxZoomFactor, byDetail, byWidth)
        return limit.isFinite ? max(1, limit) : 1
    }

    static func clamp(_ zoom: Double, duration: Double, visibleWidth: CGFloat) -> Double {
        guard zoom.isFinite else { return 1 }
        return min(maxZoom(duration: duration, visibleWidth: visibleWidth), max(1, zoom))
    }

    static func contentWidth(zoom: Double, visibleWidth: CGFloat) -> CGFloat {
        let zoom = zoom.isFinite ? max(1, zoom) : 1
        return CGFloat(min(maxContentWidth, (safeWidth(visibleWidth) * zoom).rounded(.down)))
    }

    static func pixelsPerSecond(zoom: Double, visibleWidth: CGFloat, duration: Double) -> CGFloat {
        contentWidth(zoom: zoom, visibleWidth: visibleWidth) / CGFloat(safeDuration(duration))
    }

    // MARK: Slider

    /// Maps a 0…1 slider position to a zoom on a log scale, so each part of
    /// the slider changes zoom by the same ratio.
    static func zoom(forSlider position: Double, maxZoom: Double) -> Double {
        let position = position.isFinite ? min(1, max(0, position)) : 0
        let maxZoom = maxZoom.isFinite ? max(1, maxZoom) : 1
        return exp(position * log(maxZoom))
    }

    static func sliderPosition(forZoom zoom: Double, maxZoom: Double) -> Double {
        guard maxZoom.isFinite, maxZoom > 1, zoom.isFinite, zoom > 1 else { return 0 }
        return min(1, max(0, log(zoom) / log(maxZoom)))
    }

    // MARK: Anchoring

    /// The scroll offset that keeps `anchorSeconds` at the same on-screen x
    /// after zooming, clamped to the scrollable range.
    static func anchoredOffset(
        anchorSeconds: Double,
        oldPixelsPerSecond: CGFloat,
        newPixelsPerSecond: CGFloat,
        oldOffset: CGFloat,
        newContentWidth: CGFloat,
        visibleWidth: CGFloat
    ) -> CGFloat {
        let anchor = anchorSeconds.isFinite ? CGFloat(anchorSeconds) : 0
        let oldOffset = oldOffset.isFinite ? oldOffset : 0
        let screenX = anchor * oldPixelsPerSecond - oldOffset
        let target = anchor * newPixelsPerSecond - screenX
        let maxOffset = max(0, newContentWidth - visibleWidth)
        guard target.isFinite else { return 0 }
        return min(maxOffset, max(0, target))
    }
}
