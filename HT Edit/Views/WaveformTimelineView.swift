//
//  WaveformTimelineView.swift
//  HT Edit
//

import CoreMedia
import SwiftUI

/// Scrollable, zoomable timeline: waveform + silence highlights + playhead.
///
/// The scroll view only hosts an empty, correctly sized content view for
/// scrolling and hit-testing. The waveform is drawn behind it for just the
/// visible viewport, and the playhead is a separate lightweight overlay.
///
/// Layout: everything sits inside a `GeometryReader`, which always takes exactly
/// the space it is offered and never asks its content. The scroll content width
/// is derived from that width, so it can never feed back into the layout. (A bare
/// horizontal `ScrollView` reports its content width when a stack measures it
/// with an unbounded proposal, which caused a re-layout loop.)
struct WaveformTimelineView: View {
    let model: EditorViewModel

    @State private var zoom: Double = 1
    @State private var zoomAtGestureStart: Double?
    /// Horizontal scroll offset of the visible slice, in points.
    @State private var scrollOffset: CGFloat = 0
    @State private var scrollPosition = ScrollPosition(edge: .leading)
    /// Last measured visible width, used by `setZoom` outside of layout.
    @State private var visibleWidth: CGFloat = 0
    /// Whether playback pages the timeline to keep the playhead in view.
    /// Turned off when the user scrolls by hand; back on when playback starts.
    @State private var followsPlayhead = true
    /// Offset changes before this moment come from our own scrolling or
    /// zooming, so they aren't mistaken for the user scrolling.
    @State private var ignoreScrollChangesUntil = Date.distantPast

    private var durationSeconds: Double {
        TimelineZoom.safeDuration(model.timelineDuration.seconds)
    }

    private var maxZoom: Double {
        TimelineZoom.maxZoom(duration: durationSeconds, visibleWidth: visibleWidth)
    }

    private func contentWidth(visible width: CGFloat) -> CGFloat {
        TimelineZoom.contentWidth(zoom: zoom, visibleWidth: width)
    }

    private func pixelsPerSecond(visible width: CGFloat) -> CGFloat {
        TimelineZoom.pixelsPerSecond(zoom: zoom, visibleWidth: width, duration: durationSeconds)
    }

    var body: some View {
        #if DEBUG
        let _ = BodyTrace.isEnabled ? Self._printChanges() : ()
        #endif
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                timeline(visibleWidth: proxy.size.width.rounded(.down))
            }
            .frame(minHeight: 140, idealHeight: 180, maxHeight: .infinity)
            .accessibilityElement()
            .accessibilityLabel("Timeline")
            .accessibilityIdentifier("timeline")
            zoomControl
        }
        .onChange(of: model.isPlaying) { _, isPlaying in
            guard isPlaying else { return }
            followsPlayhead = true
            revealPlayhead()
        }
        .onChange(of: durationSeconds) { _, _ in
            suppressScrollTracking()
            zoom = TimelineZoom.clamp(zoom, duration: durationSeconds, visibleWidth: visibleWidth)
        }
    }

    private func timeline(visibleWidth width: CGFloat) -> some View {
        let scale = pixelsPerSecond(visible: width)
        return ScrollView(.horizontal) {
            Color.clear
                .frame(width: contentWidth(visible: width))
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard scale > 0 else { return }
                            model.seek(toSeconds: Double(value.location.x / scale))
                        }
                )
        }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x.rounded() } action: { oldValue, newValue in
            scrollOffset = newValue.isFinite ? newValue : 0
            if Date.now >= ignoreScrollChangesUntil, model.isPlaying, abs(newValue - oldValue) >= 1 {
                // A mouse wheel may scroll without reporting a scroll phase.
                followsPlayhead = false
            }
        }
        .onScrollPhaseChange { _, newPhase in
            if newPhase == .interacting { followsPlayhead = false }
        }
        .background {
            WaveformCanvas(
                lanes: model.lanes,
                silences: model.silences,
                thresholdDB: model.settings.thresholdDB,
                offset: scrollOffset,
                pixelsPerSecond: scale
            )
        }
        .overlay(alignment: .leading) {
            PlayheadOverlay(
                model: model,
                offset: scrollOffset,
                viewportWidth: width,
                pixelsPerSecond: scale,
                followsPlayhead: followsPlayhead,
                scrollTo: { scroll(to: $0) }
            )
            .allowsHitTesting(false)
        }
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    let base = zoomAtGestureStart ?? zoom
                    zoomAtGestureStart = base
                    setZoom(base * value.magnification)
                }
                .onEnded { _ in zoomAtGestureStart = nil }
        )
        // Remember the width for zooming. This only affects later zoom math,
        // never this view's size, so it can't cause a layout loop.
        .onChange(of: width, initial: true) { _, newWidth in
            visibleWidth = newWidth
            suppressScrollTracking()
            zoom = TimelineZoom.clamp(zoom, duration: durationSeconds, visibleWidth: newWidth)
        }
    }

    private var zoomControl: some View {
        HStack {
            Image(systemName: "minus.magnifyingglass")
            Slider(
                value: Binding(
                    get: { TimelineZoom.sliderPosition(forZoom: zoom, maxZoom: maxZoom) },
                    set: { setZoom(TimelineZoom.zoom(forSlider: $0, maxZoom: maxZoom)) }
                ),
                in: 0...1
            ) {
                Text("Zoom")
            }
            .labelsHidden()
            .frame(maxWidth: 240)
            .accessibilityIdentifier("zoomSlider")
            Image(systemName: "plus.magnifyingglass")
            Button("Fit") { setZoom(1) }
                .controlSize(.small)
                .accessibilityIdentifier("zoomFitButton")
            Spacer()
            if model.isAnalyzing {
                ProgressView()
                    .controlSize(.small)
                Text("Analyzing audio…")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    /// Changes zoom while keeping the playhead at the same on-screen position.
    private func setZoom(_ newZoom: Double) {
        guard visibleWidth > 0 else { return }
        let clamped = TimelineZoom.clamp(newZoom, duration: durationSeconds, visibleWidth: visibleWidth)
        guard clamped != zoom else { return }
        let playhead = model.currentTime.seconds
        let oldScale = pixelsPerSecond(visible: visibleWidth)
        let oldOffset = scrollOffset
        suppressScrollTracking()
        zoom = clamped
        let newOffset = TimelineZoom.anchoredOffset(
            anchorSeconds: playhead,
            oldPixelsPerSecond: oldScale,
            newPixelsPerSecond: pixelsPerSecond(visible: visibleWidth),
            oldOffset: oldOffset,
            newContentWidth: contentWidth(visible: visibleWidth),
            visibleWidth: visibleWidth
        )
        // Scroll after the new content width is laid out, never into the old one.
        DispatchQueue.main.async { scroll(to: newOffset) }
    }

    private func scroll(to x: CGFloat) {
        guard x.isFinite else { return }
        let target = x.rounded()
        guard abs(target - scrollOffset) >= 1 else { return }
        suppressScrollTracking()
        scrollPosition.scrollTo(x: max(0, target))
    }

    private func suppressScrollTracking() {
        ignoreScrollChangesUntil = Date.now.addingTimeInterval(0.3)
    }

    /// Brings the playhead into view if it's off screen (used when playback starts).
    private func revealPlayhead() {
        let seconds = model.currentTime.seconds
        guard visibleWidth > 0, seconds.isFinite else { return }
        let scale = pixelsPerSecond(visible: visibleWidth)
        let x = CGFloat(seconds) * scale - scrollOffset
        if x < 0 || x > visibleWidth {
            scroll(to: PlayheadOverlay.pageOffset(for: seconds, pixelsPerSecond: scale, viewportWidth: visibleWidth, contentWidth: contentWidth(visible: visibleWidth)))
        }
    }
}

/// The moving playhead. Isolated in its own view so 30 Hz time updates
/// re-render only this line, never the waveform.
private struct PlayheadOverlay: View {
    let model: EditorViewModel
    let offset: CGFloat
    let viewportWidth: CGFloat
    let pixelsPerSecond: CGFloat
    let followsPlayhead: Bool
    let scrollTo: (CGFloat) -> Void

    var body: some View {
        #if DEBUG
        let _ = BodyTrace.isEnabled ? Self._printChanges() : ()
        #endif
        let seconds = model.currentTime.seconds
        let x = (seconds.isFinite ? CGFloat(seconds) : 0) * pixelsPerSecond - offset
        Rectangle()
            .fill(.white)
            .shadow(color: .black.opacity(0.4), radius: 1)
            .frame(width: 2)
            .padding(.top, WaveformCanvas.rulerHeight)
            .offset(x: x.isFinite ? x - 1 : 0)
            .opacity(x >= -1 && x <= viewportWidth + 1 ? 1 : 0)
            .onChange(of: model.currentTime) { _, time in
                followPlayhead(time)
            }
    }

    /// Offset that puts the playhead near the left edge of the viewport.
    static func pageOffset(for seconds: Double, pixelsPerSecond: CGFloat, viewportWidth: CGFloat, contentWidth: CGFloat) -> CGFloat {
        let target = CGFloat(seconds) * pixelsPerSecond - viewportWidth * 0.05
        return min(max(0, contentWidth - viewportWidth), max(0, target))
    }

    /// Pages the timeline when the playhead leaves the visible area during
    /// playback, unless the user has scrolled away by hand.
    private func followPlayhead(_ time: CMTime) {
        guard followsPlayhead, model.isPlaying, viewportWidth > 0, time.seconds.isFinite else { return }
        let x = CGFloat(time.seconds) * pixelsPerSecond - offset
        if x > viewportWidth * 0.95 || x < 0 {
            let contentWidth = pixelsPerSecond * CGFloat(TimelineZoom.safeDuration(model.timelineDuration.seconds))
            scrollTo(Self.pageOffset(for: time.seconds, pixelsPerSecond: pixelsPerSecond, viewportWidth: viewportWidth, contentWidth: contentWidth))
        }
    }
}
