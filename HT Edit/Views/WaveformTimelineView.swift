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
struct WaveformTimelineView: View {
    let model: EditorViewModel

    @State private var zoom: Double = 1
    @State private var zoomAtGestureStart: Double?
    /// Horizontal scroll offset of the visible slice, in points.
    @State private var scrollOffset: CGFloat = 0
    @State private var scrollPosition = ScrollPosition(edge: .leading)

    static let zoomRange: ClosedRange<Double> = 1...400

    private var durationSeconds: Double {
        let seconds = model.timelineDuration.seconds
        return seconds.isFinite && seconds > 0 ? seconds : 1
    }

    /// Width available to the timeline: the single source of truth for both the
    /// scroll content width and the visible width. Whole points only, so the
    /// content never exceeds the container by a fraction and re-triggers layout.
    @State private var availableWidth: CGFloat = 0

    private var contentWidth: CGFloat { (max(availableWidth, 1) * zoom).rounded(.down) }
    private var pixelsPerSecond: CGFloat { contentWidth / durationSeconds }

    var body: some View {
        #if DEBUG
        let _ = BodyTrace.isEnabled ? Self._printChanges() : ()
        #endif
        VStack(alignment: .leading, spacing: 8) {
            timeline
                .onGeometryChange(for: CGFloat.self) { $0.size.width.rounded(.down) } action: { width in
                    if abs(width - availableWidth) >= 1 { availableWidth = width }
                }
            zoomControl
        }
    }

    private var timeline: some View {
        ScrollView(.horizontal) {
            Color.clear
                .frame(width: contentWidth)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            model.seek(toSeconds: Double(value.location.x / pixelsPerSecond))
                        }
                )
        }
        .scrollPosition($scrollPosition)
        // Only the offset comes from the scroll view; widths come from `availableWidth`.
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x.rounded() } action: { _, newValue in
            scrollOffset = newValue
        }
        .background {
            WaveformCanvas(
                lanes: model.lanes,
                silences: model.silences,
                thresholdDB: model.settings.thresholdDB,
                offset: scrollOffset,
                pixelsPerSecond: pixelsPerSecond
            )
        }
        .overlay(alignment: .leading) {
            PlayheadOverlay(
                model: model,
                offset: scrollOffset,
                viewportWidth: availableWidth,
                pixelsPerSecond: pixelsPerSecond,
                scrollPosition: $scrollPosition
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
        // The scroll content's width is derived from the visible width; pin the
        // preferred size so it can never feed back into the surrounding layout.
        .frame(minWidth: 0, idealWidth: 400, maxWidth: .infinity, minHeight: 140, idealHeight: 180, maxHeight: .infinity)
        .accessibilityElement()
        .accessibilityLabel("Timeline")
        .accessibilityIdentifier("timeline")
    }

    private var zoomControl: some View {
        HStack {
            Image(systemName: "minus.magnifyingglass")
            Slider(value: Binding(get: { zoom }, set: { setZoom($0) }), in: Self.zoomRange) {
                Text("Zoom")
            }
            .labelsHidden()
            .frame(maxWidth: 240)
            Image(systemName: "plus.magnifyingglass")
            Button("Fit") { setZoom(1) }
                .controlSize(.small)
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
        let clamped = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, newZoom))
        guard clamped != zoom else { return }
        let playhead = model.currentTime.seconds.isFinite ? model.currentTime.seconds : 0
        let screenX = CGFloat(playhead) * pixelsPerSecond - scrollOffset
        zoom = clamped
        let newOffset = CGFloat(playhead) * pixelsPerSecond - screenX
        scrollPosition.scrollTo(x: max(0, newOffset))
    }
}

/// The moving playhead. Isolated in its own view so 30 Hz time updates
/// re-render only this line, never the waveform.
private struct PlayheadOverlay: View {
    let model: EditorViewModel
    let offset: CGFloat
    let viewportWidth: CGFloat
    let pixelsPerSecond: CGFloat
    @Binding var scrollPosition: ScrollPosition

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
            .offset(x: x - 1)
            .opacity(x >= -1 && x <= viewportWidth + 1 ? 1 : 0)
            .onChange(of: model.currentTime) { _, time in
                followPlayhead(time)
            }
    }

    /// Pages the timeline when the playhead leaves the visible area during playback.
    private func followPlayhead(_ time: CMTime) {
        guard model.isPlaying, viewportWidth > 0, time.seconds.isFinite else { return }
        let x = CGFloat(time.seconds) * pixelsPerSecond - offset
        if x > viewportWidth * 0.95 || x < 0 {
            scrollPosition.scrollTo(x: max(0, CGFloat(time.seconds) * pixelsPerSecond - viewportWidth * 0.05))
        }
    }
}
