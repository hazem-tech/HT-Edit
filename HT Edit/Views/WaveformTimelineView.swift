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
    @State private var viewport = Viewport()
    @State private var scrollPosition = ScrollPosition(edge: .leading)

    static let zoomRange: ClosedRange<Double> = 1...400

    struct Viewport: Equatable {
        var offset: CGFloat = 0
        var width: CGFloat = 0
    }

    private var durationSeconds: Double {
        let seconds = model.timelineDuration.seconds
        return seconds.isFinite && seconds > 0 ? seconds : 1
    }

    private var contentWidth: CGFloat { max(viewport.width, 1) * zoom }
    private var pixelsPerSecond: CGFloat { contentWidth / durationSeconds }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            timeline
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
        .onScrollGeometryChange(for: Viewport.self) { geometry in
            Viewport(offset: geometry.contentOffset.x, width: geometry.containerSize.width)
        } action: { _, newValue in
            viewport = newValue
        }
        .background {
            WaveformCanvas(
                levels: model.levels,
                silences: model.silences,
                thresholdDB: model.settings.thresholdDB,
                offset: viewport.offset,
                pixelsPerSecond: pixelsPerSecond
            )
        }
        .overlay(alignment: .leading) {
            PlayheadOverlay(
                model: model,
                offset: viewport.offset,
                viewportWidth: viewport.width,
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
        .frame(minHeight: 140, idealHeight: 180)
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
        let screenX = CGFloat(playhead) * pixelsPerSecond - viewport.offset
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
