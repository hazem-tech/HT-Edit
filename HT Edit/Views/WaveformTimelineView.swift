//
//  WaveformTimelineView.swift
//  HT Edit
//

import CoreMedia
import SwiftUI

/// Scrollable, zoomable timeline: waveform, removed parts, markers and playhead.
///
/// The scroll view only hosts an empty, correctly sized content view for
/// scrolling, hit-testing and hover. The waveform is drawn behind it for just
/// the visible viewport, and the playhead is a separate lightweight overlay.
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
    /// The zoom slider's position, 0...1 on a log scale.
    @State private var sliderPosition: Double = 0
    /// What stays put on screen while the zoom slider is dragged, fixed when the drag starts.
    @State private var sliderAnchor: ZoomAnchor?
    /// The removed part whose top bar is hovered, and where its card sits.
    @State private var hover: HoveredRemoval?
    @State private var isPointerOnCard = false
    @State private var hideHoverTask: Task<Void, Never>?

    static let zoomRange: ClosedRange<Double> = TimelineZoom.range

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
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Timeline")
            .accessibilityIdentifier("timeline")
            zoomControl
        }
    }

    private func timeline(visibleWidth width: CGFloat) -> some View {
        let scale = pixelsPerSecond(visible: width)
        let removed = model.removedRanges
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
                .onContinuousHover(coordinateSpace: .local) { phase in
                    if case .active(let location) = phase {
                        updateHover(at: location, scale: scale, removed: removed)
                    } else {
                        scheduleHoverEnd()
                    }
                }
        }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x.rounded() } action: { _, newValue in
            scrollOffset = newValue
        }
        .onScrollPhaseChange { _, phase in
            switch phase {
            case .tracking, .interacting, .decelerating:
                // The user is scrolling: stop paging along with the playhead.
                model.userScrolledTimeline()
                if hover != nil { hover = nil }
            default:
                break
            }
        }
        .background {
            WaveformCanvas(
                lanes: model.lanes,
                removed: removed,
                markerTimes: model.markerTimes,
                hoveredRemoval: hoveredIndex(in: removed),
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
        .overlay(alignment: .topLeading) {
            if let hover {
                RemovalCard(reasons: hover.reasons) {
                    model.preview(hover.range)
                }
                .onHover { inside in
                    isPointerOnCard = inside
                    if inside { hideHoverTask?.cancel() } else { scheduleHoverEnd() }
                }
                .offset(
                    x: min(max(0, hover.x - RemovalCard.width / 2), max(0, width - RemovalCard.width)),
                    y: WaveformCanvas.rulerHeight + WaveformCanvas.hoverStripHeight
                )
            }
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
        .onChange(of: zoom) { _, newZoom in
            if hover != nil { hover = nil }
            // Pinch and Fit move the slider; while it's dragged, it leads.
            if sliderAnchor == nil {
                sliderPosition = TimelineZoom.sliderPosition(forZoom: newZoom)
            }
        }
    }

    // MARK: Zoom bar

    private var zoomControl: some View {
        HStack {
            Button("Zoom Out", systemImage: "minus.magnifyingglass") {
                applyZoom(zoom / TimelineZoom.step, anchor: currentAnchor())
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(zoom <= TimelineZoom.range.lowerBound)
            .help("Zoom out")

            Slider(value: sliderBinding, in: 0...1) {
                Text("Zoom")
            } onEditingChanged: { editing in
                sliderAnchor = editing ? currentAnchor() : nil
            }
            .labelsHidden()
            .frame(maxWidth: 240)
            .accessibilityIdentifier("zoomSlider")

            Button("Zoom In", systemImage: "plus.magnifyingglass") {
                applyZoom(zoom * TimelineZoom.step, anchor: currentAnchor())
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(zoom >= TimelineZoom.range.upperBound)
            .help("Zoom in")

            Button("Fit") { applyZoom(1, anchor: currentAnchor()) }
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

    /// Only the user moves the slider through this binding; it zooms around
    /// the anchor fixed when the drag started.
    private var sliderBinding: Binding<Double> {
        Binding(
            get: { sliderPosition },
            set: { position in
                let position = position.isFinite ? min(1, max(0, position)) : 0
                sliderPosition = position
                applyZoom(TimelineZoom.zoom(forSliderPosition: position), anchor: sliderAnchor ?? currentAnchor())
            }
        )
    }

    /// The playhead if it's on screen, otherwise the middle of the view.
    private func currentAnchor() -> ZoomAnchor {
        let width = max(visibleWidth, 1)
        let scale = pixelsPerSecond(visible: width)
        let playhead = model.currentTime.seconds
        if playhead.isFinite {
            let x = CGFloat(playhead) * scale - scrollOffset
            if x >= 0, x <= width { return ZoomAnchor(time: playhead, x: x) }
        }
        let center = Double((scrollOffset + width / 2) / scale)
        return ZoomAnchor(time: center.isFinite ? center : 0, x: width / 2)
    }

    /// Zooms so `anchor.time` stays at `anchor.x` on screen. The new offset is
    /// computed from the anchor alone (never from a scroll offset that may not
    /// have caught up yet), clamped to what can scroll, and applied at once.
    private func applyZoom(_ target: Double, anchor: ZoomAnchor) {
        let newZoom = TimelineZoom.clamped(target)
        guard newZoom != zoom else { return }
        zoom = newZoom
        guard visibleWidth > 0 else { return }
        let width = contentWidth(visible: visibleWidth)
        let offset = TimelineZoom.anchoredOffset(
            anchorTime: anchor.time,
            anchorX: anchor.x,
            pixelsPerSecond: width / CGFloat(durationSeconds),
            contentWidth: width,
            viewportWidth: visibleWidth
        )
        scrollOffset = offset
        scrollPosition.scrollTo(x: offset)
    }

    /// Changes zoom while keeping the playhead at the same on-screen position (pinch).
    private func setZoom(_ newZoom: Double) {
        let clamped = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, newZoom))
        guard clamped != zoom else { return }
        let playhead = model.currentTime.seconds.isFinite ? model.currentTime.seconds : 0
        let screenX = CGFloat(playhead) * pixelsPerSecond(visible: visibleWidth) - scrollOffset
        zoom = clamped
        let newOffset = CGFloat(playhead) * pixelsPerSecond(visible: visibleWidth) - screenX
        scrollPosition.scrollTo(x: max(0, newOffset))
    }

    // MARK: Hover

    /// `location` is in content coordinates: x includes the scroll offset.
    private func updateHover(at location: CGPoint, scale: CGFloat, removed: [RemovedRange]) {
        let top = WaveformCanvas.rulerHeight - 2
        let bottom = WaveformCanvas.rulerHeight + WaveformCanvas.hoverStripHeight
        guard scale > 0, location.y >= top, location.y <= bottom,
              let index = RemovalPlanner.index(containing: Double(location.x / scale), in: removed) else {
            scheduleHoverEnd()
            return
        }
        hideHoverTask?.cancel()
        let part = removed[index]
        if hover?.range != part.range {
            hover = HoveredRemoval(index: index, range: part.range, reasons: part.reasons, x: location.x - scrollOffset)
        }
    }

    /// Hides the card shortly after the pointer leaves, so it can move from the bar onto the card.
    private func scheduleHoverEnd() {
        guard hover != nil else { return }
        hideHoverTask?.cancel()
        hideHoverTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, !isPointerOnCard else { return }
            hover = nil
        }
    }

    private func hoveredIndex(in removed: [RemovedRange]) -> Int? {
        guard let hover, removed.indices.contains(hover.index), removed[hover.index].range == hover.range else { return nil }
        return hover.index
    }
}

/// A point on screen that stays put while zooming.
private struct ZoomAnchor {
    /// Timeline seconds.
    var time: Double
    /// Points from the left edge of the view.
    var x: CGFloat
}

private struct HoveredRemoval {
    var index: Int
    var range: CMTimeRange
    var reasons: [RemovalReason]
    /// Pointer x when the bar was entered, in view coordinates.
    var x: CGFloat
}

/// The small card shown over a removed part: why it was removed, and a preview.
private struct RemovalCard: View {
    static let width: CGFloat = 220

    let reasons: [RemovalReason]
    let preview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(reasons, id: \.self) { reason in
                Text(reason.title)
                    .font(.callout)
                    .lineLimit(2)
            }
            Button("Preview", systemImage: "play.fill", action: preview)
                .controlSize(.small)
                .accessibilityIdentifier("previewRemovedButton")
        }
        .padding(10)
        .frame(width: Self.width, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.separator)
        }
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("removalCard")
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

    /// Pages the timeline when the playhead leaves the visible area during
    /// playback, unless the user scrolled away (until playback starts again).
    private func followPlayhead(_ time: CMTime) {
        guard model.followsPlayhead, model.isPlaying, viewportWidth > 0, time.seconds.isFinite else { return }
        let x = CGFloat(time.seconds) * pixelsPerSecond - offset
        if x > viewportWidth * 0.95 || x < 0 {
            scrollPosition.scrollTo(x: max(0, CGFloat(time.seconds) * pixelsPerSecond - viewportWidth * 0.05))
        }
    }
}
