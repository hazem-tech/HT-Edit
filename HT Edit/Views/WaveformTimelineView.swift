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

    static let zoomRange: ClosedRange<Double> = 1...400

    private var durationSeconds: Double {
        let seconds = model.timelineDuration.seconds
        return seconds.isFinite && seconds > 0 ? seconds : 1
    }

    private func contentWidth(visible width: CGFloat) -> CGFloat {
        (max(width, 1) * zoom).rounded(.down)
    }

    private func pixelsPerSecond(visible width: CGFloat) -> CGFloat {
        contentWidth(visible: width) / durationSeconds
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
                            model.seek(toSeconds: Double(value.location.x / scale))
                        }
                )
        }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x.rounded() } action: { _, newValue in
            scrollOffset = newValue
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
        // Remember the width for zooming. This only affects later zoom math,
        // never this view's size, so it can't cause a layout loop.
        .onChange(of: width, initial: true) { _, newWidth in
            visibleWidth = newWidth
        }
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
        let screenX = CGFloat(playhead) * pixelsPerSecond(visible: visibleWidth) - scrollOffset
        zoom = clamped
        let newOffset = CGFloat(playhead) * pixelsPerSecond(visible: visibleWidth) - screenX
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
