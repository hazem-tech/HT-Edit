//
//  TimelineZoom.swift
//  HT Edit
//

import CoreGraphics
import Foundation

/// Pure math for the timeline's zoom bar.
///
/// The slider is logarithmic: each step of the slider zooms by the same
/// factor, so 1×→2× takes as much travel as 200×→400×. Every result is
/// clamped and finite, however fast or far the slider is dragged.
nonisolated enum TimelineZoom {
    /// Same range as pinch zoom.
    static let range: ClosedRange<Double> = 1...400
    /// What the − and + buttons zoom by.
    static let step = 1.5

    static func clamped(_ zoom: Double, to range: ClosedRange<Double> = range) -> Double {
        guard zoom.isFinite else { return range.lowerBound }
        return min(range.upperBound, max(range.lowerBound, zoom))
    }

    /// Zoom for a slider position in 0...1.
    static func zoom(forSliderPosition position: Double, in range: ClosedRange<Double> = range) -> Double {
        guard position.isFinite, range.lowerBound > 0 else { return range.lowerBound }
        let t = min(1, max(0, position))
        return clamped(range.lowerBound * pow(range.upperBound / range.lowerBound, t), to: range)
    }

    /// Slider position in 0...1 for `zoom`.
    static func sliderPosition(forZoom zoom: Double, in range: ClosedRange<Double> = range) -> Double {
        guard range.lowerBound > 0, range.upperBound > range.lowerBound else { return 0 }
        let ratio = log(clamped(zoom, to: range) / range.lowerBound) / log(range.upperBound / range.lowerBound)
        return ratio.isFinite ? min(1, max(0, ratio)) : 0
    }

    /// The scroll offset that keeps `anchorTime` at `anchorX` on screen,
    /// within what the content can scroll to.
    static func anchoredOffset(
        anchorTime: Double,
        anchorX: CGFloat,
        pixelsPerSecond: CGFloat,
        contentWidth: CGFloat,
        viewportWidth: CGFloat
    ) -> CGFloat {
        let maxOffset = max(0, contentWidth - viewportWidth)
        let raw = CGFloat(anchorTime) * pixelsPerSecond - anchorX
        guard raw.isFinite, maxOffset.isFinite else { return 0 }
        return min(maxOffset, max(0, raw))
    }
}
