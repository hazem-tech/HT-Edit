//
//  TimelineZoomTests.swift
//  HT EditTests
//

import CoreGraphics
import Testing
@testable import HT_Edit

struct TimelineZoomTests {

    private static let durations: [Double] = [0, 0.01, 0.5, 5, 60, 3_600, 3 * 3_600, .nan, .infinity, -1]
    private static let widths: [CGFloat] = [0, 0.5, 1, 320, 1_280, 4_000, .nan, .infinity]

    @Test func everyZoomStaysFiniteAndBounded() {
        for duration in Self.durations {
            for width in Self.widths {
                let maxZoom = TimelineZoom.maxZoom(duration: duration, visibleWidth: width)
                #expect(maxZoom.isFinite && maxZoom >= 1 && maxZoom <= TimelineZoom.maxZoomFactor)
                for requested in [-5, 0, 1, 7, 400, 1e12, .nan, .infinity] as [Double] {
                    let zoom = TimelineZoom.clamp(requested, duration: duration, visibleWidth: width)
                    #expect(zoom >= 1 && zoom <= maxZoom)
                    let content = TimelineZoom.contentWidth(zoom: zoom, visibleWidth: width)
                    #expect(content.isFinite && content >= 1 && Double(content) <= TimelineZoom.maxContentWidth)
                    let scale = TimelineZoom.pixelsPerSecond(zoom: zoom, visibleWidth: width, duration: duration)
                    #expect(scale.isFinite && scale > 0)
                }
            }
        }
    }

    @Test func maxZoomRespectsDetailAndWidthLimits() {
        // A 5 s clip in 1000 pt: at most 1000 px/s → 5× zoom.
        #expect(TimelineZoom.maxZoom(duration: 5, visibleWidth: 1_000) == 5)
        // A 3 h video: capped by the zoom factor.
        #expect(TimelineZoom.maxZoom(duration: 3 * 3_600, visibleWidth: 1_000) == TimelineZoom.maxZoomFactor)
        // A very wide viewport: capped by total content width.
        #expect(TimelineZoom.maxZoom(duration: 3 * 3_600, visibleWidth: 4_000) == TimelineZoom.maxContentWidth / 4_000)
        // Shorter than the viewport's worth of detail: no zoom beyond fit.
        #expect(TimelineZoom.maxZoom(duration: 0.01, visibleWidth: 1_000) == 1)
    }

    @Test func sliderIsLogarithmicAndRoundTrips() {
        let maxZoom = 400.0
        #expect(TimelineZoom.zoom(forSlider: 0, maxZoom: maxZoom) == 1)
        #expect(abs(TimelineZoom.zoom(forSlider: 1, maxZoom: maxZoom) - maxZoom) < 1e-9)
        #expect(abs(TimelineZoom.zoom(forSlider: 0.5, maxZoom: maxZoom) - 20) < 1e-9)
        for position in stride(from: 0.0, through: 1.0, by: 0.125) {
            let zoom = TimelineZoom.zoom(forSlider: position, maxZoom: maxZoom)
            #expect(abs(TimelineZoom.sliderPosition(forZoom: zoom, maxZoom: maxZoom) - position) < 1e-9)
        }
        #expect(TimelineZoom.zoom(forSlider: .nan, maxZoom: maxZoom) == 1)
        #expect(TimelineZoom.zoom(forSlider: 2, maxZoom: 1) == 1)
        #expect(TimelineZoom.sliderPosition(forZoom: 5, maxZoom: 1) == 0)
        #expect(TimelineZoom.sliderPosition(forZoom: .nan, maxZoom: maxZoom) == 0)
    }

    @Test func zoomKeepsTheAnchorAtTheSameScreenPosition() {
        // Playhead at 10 s, 10 px/s, scrolled to 50 → on screen at x = 50.
        let offset = TimelineZoom.anchoredOffset(
            anchorSeconds: 10, oldPixelsPerSecond: 10, newPixelsPerSecond: 40,
            oldOffset: 50, newContentWidth: 10_000, visibleWidth: 500
        )
        #expect(offset == 350) // 10 × 40 − 50
    }

    @Test func anchoredOffsetIsClampedToTheScrollableRange() {
        let end = TimelineZoom.anchoredOffset(
            anchorSeconds: 1_000, oldPixelsPerSecond: 1, newPixelsPerSecond: 100,
            oldOffset: 0, newContentWidth: 2_000, visibleWidth: 500
        )
        #expect(end == 1_500)
        let start = TimelineZoom.anchoredOffset(
            anchorSeconds: 0, oldPixelsPerSecond: 10, newPixelsPerSecond: 1,
            oldOffset: 0, newContentWidth: 2_000, visibleWidth: 500
        )
        #expect(start == 0)
        let invalid = TimelineZoom.anchoredOffset(
            anchorSeconds: .nan, oldPixelsPerSecond: .infinity, newPixelsPerSecond: 1,
            oldOffset: .nan, newContentWidth: 2_000, visibleWidth: 500
        )
        #expect(invalid.isFinite && invalid >= 0)
    }
}
