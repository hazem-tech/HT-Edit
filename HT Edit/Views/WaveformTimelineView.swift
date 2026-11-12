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
///
/// Layout: in Clean, the timeline shows edited time (only what's kept, back
/// to back). The playhead and seeking go through the model's
/// `displaySeconds(forSource:)` / `sourceSeconds(forDisplay:)`.
///
/// Scroll offset: only the scroll view's own geometry writes `scrollOffset`.
/// The zoom bar never writes it and never asks for a scroll position the
/// content can't reach yet: it changes the zoom, waits for the content's new
/// width to be laid out, then scrolls once to keep its anchor in place.
struct WaveformTimelineView: View {
    let model: EditorViewModel

    @State private var zoom: Double = 1
    @State private var zoomAtGestureStart: Double?
    /// Horizontal scroll offset of the visible slice, in points, as the scroll view reports it.
    @State private var scrollOffset: CGFloat = 0
    @State private var scrollPosition = ScrollPosition(edge: .leading)
    /// Last measured visible width, used by the zoom math outside of layout.
    @State private var visibleWidth: CGFloat = 0
    /// The zoom slider's position, 0...1 on a log scale.
    @State private var sliderPosition: Double = 0
    /// What stays put on screen while the zoom slider is dragged, fixed when the drag starts.
    @State private var sliderAnchor: ZoomAnchor?
    /// A zoom bar change waiting for the content's new width; scrolled to once it's laid out.
    @State private var awaitingAnchor: ZoomAnchor?
    /// When the hover card for a removed part shows.
    @State private var hover = RemovalHover()
    /// Pointer position, timers and the latest zoom request: bookkeeping that
    /// must not redraw the view each time it changes.
    @State private var scratch = TimelineScratch()

    static let zoomRange: ClosedRange<Double> = TimelineZoom.range

    /// Length of the timeline as shown (the edit, in Clean).
    private var durationSeconds: Double {
        let seconds = model.displayDuration
        return seconds.isFinite && seconds > 0 ? seconds : 1
    }

    /// The playhead's position on the timeline as shown.
    private var playheadSeconds: Double {
        let seconds = model.currentTime.seconds
        return seconds.isFinite ? model.displaySeconds(forSource: seconds) : 0
    }

    private func contentWidth(visible width: CGFloat) -> CGFloat {
        (max(width, 1) * zoom).rounded(.down)
    }

    private func pixelsPerSecond(visible width: CGFloat) -> CGFloat {
        contentWidth(visible: width) / durationSeconds
    }

    /// The offset to draw at: where a pending zoom will scroll to, otherwise
    /// where the scroll view is. Only ever drawn, never fed back to the scroll view.
    private func shownOffset(visible width: CGFloat) -> CGFloat {
        guard let anchor = awaitingAnchor else { return scrollOffset }
        let content = contentWidth(visible: width)
        return TimelineZoom.anchoredOffset(
            anchorTime: anchor.time,
            anchorX: anchor.x,
            pixelsPerSecond: content / CGFloat(durationSeconds),
            contentWidth: content,
            viewportWidth: width
        )
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
        let offset = shownOffset(visible: width)
        // Clean leaves removed parts out: nothing to gray out or hover.
        let hidesRemoved = model.hidesRemoved
        let removed = hidesRemoved ? [] : model.removedRanges
        let shownPart = hover.shown.flatMap { removed.indices.contains($0) ? $0 : nil }
        return ScrollView(.horizontal) {
            Color.clear
                .frame(width: contentWidth(visible: width))
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            model.seek(toSeconds: model.sourceSeconds(forDisplay: Double(value.location.x / scale)))
                        }
                )
                .onContinuousHover(coordinateSpace: .local) { phase in
                    if case .active(let location) = phase {
                        pointerMoved(to: location, scale: scale, removed: removed)
                    } else {
                        pointerMoved(to: nil, scale: scale, removed: removed)
                    }
                }
        }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: ViewportGeometry.self) { geometry in
            ViewportGeometry(
                offset: geometry.contentOffset.x.rounded(),
                contentWidth: geometry.contentSize.width.rounded(),
                containerWidth: geometry.containerSize.width.rounded()
            )
        } action: { old, new in
            scrollOffset = new.offset
            // The zoom's new content width is laid out: now its anchor can be
            // scrolled to without the scroll view clamping it.
            if let anchor = awaitingAnchor, new.contentWidth != old.contentWidth {
                awaitingAnchor = nil
                scroll(to: anchor, contentWidth: new.contentWidth, viewportWidth: new.containerWidth)
            }
        }
        .onScrollPhaseChange { _, phase in
            switch phase {
            case .tracking, .interacting, .decelerating:
                // The user is scrolling: stop paging along with the playhead.
                model.userScrolledTimeline()
                awaitingAnchor = nil
                dismissHover()
            default:
                break
            }
        }
        .background {
            WaveformCanvas(
                lanes: model.lanes,
                removed: removed,
                markerTimes: model.markerTimes,
                hoveredRemoval: shownPart,
                thresholdDB: model.settings.thresholdDB,
                editMap: hidesRemoved ? model.editMap : nil,
                offset: offset,
                pixelsPerSecond: scale
            )
        }
        .overlay(alignment: .leading) {
            PlayheadOverlay(
                model: model,
                offset: offset,
                viewportWidth: width,
                pixelsPerSecond: scale,
                scrollPosition: $scrollPosition
            )
            .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            if let shownPart {
                let part = removed[shownPart]
                RemovalCard(reason: part.reason) {
                    model.preview(part.range)
                }
                .onHover { inside in
                    updateHover { $0.card(isInside: inside) }
                }
                .offset(
                    x: min(max(0, scratch.cardX - RemovalCard.width / 2), max(0, width - RemovalCard.width)),
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
            dismissHover()
            // Pinch and Fit move the slider; while it's dragged, it leads.
            if sliderAnchor == nil {
                sliderPosition = TimelineZoom.sliderPosition(forZoom: newZoom)
            }
        }
        // Parts are recomputed (settings, transcript): a card's index may now be another part.
        .onChange(of: removed) {
            dismissHover()
        }
        .onChange(of: model.layout) { old, _ in
            layoutDidSwitch(from: old)
        }
    }

    /// Full ↔ Clean: the playhead keeps its place on screen. The content width
    /// depends only on the zoom, so the new offset is always reachable.
    private func layoutDidSwitch(from old: EditorLayout) {
        dismissHover()
        awaitingAnchor = nil
        guard visibleWidth > 0 else { return }
        let source = model.currentTime.seconds.isFinite ? model.currentTime.seconds : 0
        let oldTime = old == .clean ? model.editMap.edited(fromSource: source) : source
        let oldDuration = old == .clean ? model.editMap.editedDuration : model.timelineDuration.seconds
        let content = contentWidth(visible: visibleWidth)
        let oldScale = oldDuration.isFinite && oldDuration > 0 ? content / CGFloat(oldDuration) : 0
        var x = CGFloat(oldTime) * oldScale - scrollOffset
        if !(x.isFinite && x >= 0 && x <= visibleWidth) { x = visibleWidth / 2 }
        scroll(to: ZoomAnchor(time: playheadSeconds, x: x), contentWidth: content, viewportWidth: visibleWidth)
    }

    // MARK: Zoom bar

    private var zoomControl: some View {
        HStack {
            Button("Zoom Out", systemImage: "minus.magnifyingglass") {
                requestZoom(zoom / TimelineZoom.step, anchor: currentAnchor())
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
                requestZoom(zoom * TimelineZoom.step, anchor: currentAnchor())
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(zoom >= TimelineZoom.range.upperBound)
            .help("Zoom in")

            Button("Fit") { requestZoom(1, anchor: currentAnchor()) }
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
                requestZoom(TimelineZoom.zoom(forSliderPosition: position), anchor: sliderAnchor ?? currentAnchor())
            }
        )
    }

    /// The playhead if it's on screen, otherwise the middle of the view.
    private func currentAnchor() -> ZoomAnchor {
        let width = max(visibleWidth, 1)
        let scale = pixelsPerSecond(visible: width)
        let offset = shownOffset(visible: width)
        let playhead = playheadSeconds
        if playhead.isFinite {
            let x = CGFloat(playhead) * scale - offset
            if x >= 0, x <= width { return ZoomAnchor(time: playhead, x: x) }
        }
        let center = Double((offset + width / 2) / scale)
        return ZoomAnchor(time: center.isFinite ? center : 0, x: width / 2)
    }

    /// Zoom bar changes arrive with every mouse move while dragging: keep only
    /// the latest, and apply it at most once a frame so each layout settles.
    private func requestZoom(_ target: Double, anchor: ZoomAnchor) {
        scratch.pendingZoom = (target, anchor)
        guard scratch.zoomTask == nil else { return }
        scratch.zoomTask = Task {
            try? await Task.sleep(for: .milliseconds(16))
            scratch.zoomTask = nil
            guard let pending = scratch.pendingZoom else { return }
            scratch.pendingZoom = nil
            applyZoom(pending.target, anchor: pending.anchor)
        }
    }

    /// Changes the zoom so `anchor.time` stays at `anchor.x` on screen. The
    /// scroll happens once the new content width is laid out (see
    /// `onScrollGeometryChange`), so its target is always reachable.
    private func applyZoom(_ target: Double, anchor: ZoomAnchor) {
        let newZoom = TimelineZoom.clamped(target)
        guard newZoom != zoom, visibleWidth > 0 else { return }
        let oldContentWidth = contentWidth(visible: visibleWidth)
        zoom = newZoom
        let newContentWidth = contentWidth(visible: visibleWidth)
        if newContentWidth == oldContentWidth {
            // Same width: no layout to wait for.
            awaitingAnchor = nil
            scroll(to: anchor, contentWidth: newContentWidth, viewportWidth: visibleWidth)
        } else {
            awaitingAnchor = anchor
        }
    }

    /// Scrolls so `anchor` is back in place, within what the content can scroll to.
    private func scroll(to anchor: ZoomAnchor, contentWidth: CGFloat, viewportWidth: CGFloat) {
        let offset = TimelineZoom.anchoredOffset(
            anchorTime: anchor.time,
            anchorX: anchor.x,
            pixelsPerSecond: contentWidth / CGFloat(durationSeconds),
            contentWidth: contentWidth,
            viewportWidth: viewportWidth
        )
        scrollPosition.scrollTo(x: offset)
    }

    /// Changes zoom while keeping the playhead at the same on-screen position (pinch).
    private func setZoom(_ newZoom: Double) {
        let clamped = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, newZoom))
        guard clamped != zoom else { return }
        let playhead = playheadSeconds
        let screenX = CGFloat(playhead) * pixelsPerSecond(visible: visibleWidth) - scrollOffset
        zoom = clamped
        let newOffset = CGFloat(playhead) * pixelsPerSecond(visible: visibleWidth) - screenX
        scrollPosition.scrollTo(x: max(0, newOffset))
    }

    // MARK: Hover

    /// `location` is in content coordinates (x includes the scroll offset), or
    /// `nil` when the pointer left the timeline.
    private func pointerMoved(to location: CGPoint?, scale: CGFloat, removed: [RemovedRange]) {
        var part: Int?
        if let location, scale > 0,
           location.y >= WaveformCanvas.rulerHeight - 2,
           location.y <= WaveformCanvas.rulerHeight + WaveformCanvas.hoverStripHeight {
            part = RemovalPlanner.index(containing: Double(location.x / scale), in: removed)
            if part != nil { scratch.pointerX = location.x - shownOffset(visible: visibleWidth) }
        }
        updateHover { $0.pointer(over: part) }
    }

    /// Applies a hover change, writing state only when something changed (the
    /// pointer moves constantly), and runs the timer it asks for.
    private func updateHover(_ change: (inout RemovalHover) -> RemovalHover.Timer?) {
        var next = hover
        let timer = change(&next)
        if next != hover {
            if next.shown != hover.shown { scratch.cardX = scratch.pointerX }
            hover = next
        }
        switch timer {
        case .dwell(let part)?:
            scratch.dwellTask?.cancel()
            scratch.dwellTask = Task {
                try? await Task.sleep(for: RemovalHover.dwell)
                guard !Task.isCancelled else { return }
                updateHover { $0.dwellElapsed(for: part); return nil }
            }
        case .grace?:
            scratch.graceTask?.cancel()
            scratch.graceTask = Task {
                try? await Task.sleep(for: RemovalHover.grace)
                guard !Task.isCancelled else { return }
                updateHover { $0.graceElapsed(); return nil }
            }
        case nil:
            break
        }
    }

    private func dismissHover() {
        scratch.dwellTask?.cancel()
        scratch.graceTask?.cancel()
        if hover != RemovalHover() { hover.dismiss() }
    }
}

/// A point on screen that stays put while zooming.
private struct ZoomAnchor {
    /// Timeline seconds.
    var time: Double
    /// Points from the left edge of the view.
    var x: CGFloat
}

/// What the scroll view reports about itself, rounded to whole points.
nonisolated private struct ViewportGeometry: Equatable {
    var offset: CGFloat
    var contentWidth: CGFloat
    var containerWidth: CGFloat
}

/// Bookkeeping for the timeline that changes often and must not redraw it:
/// a plain object, so writing its properties doesn't invalidate the view.
@MainActor
private final class TimelineScratch {
    /// Pointer x over a removed part's bar, in view coordinates.
    var pointerX: CGFloat = 0
    /// Where the card sits: the pointer's x when it appeared.
    var cardX: CGFloat = 0
    var dwellTask: Task<Void, Never>?
    var graceTask: Task<Void, Never>?
    /// The latest zoom bar request, applied by `zoomTask`.
    var pendingZoom: (target: Double, anchor: ZoomAnchor)?
    var zoomTask: Task<Void, Never>?
}

/// The small card shown over a removed part: why it was removed, and a preview.
private struct RemovalCard: View {
    static let width: CGFloat = 200

    let reason: RemovalReason
    let preview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(reason.title)
                .font(.callout)
                .lineLimit(2)
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
        let shown = seconds.isFinite ? model.displaySeconds(forSource: seconds) : 0
        let x = CGFloat(shown) * pixelsPerSecond - offset
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
        let shown = CGFloat(model.displaySeconds(forSource: time.seconds))
        let x = shown * pixelsPerSecond - offset
        if x > viewportWidth * 0.95 || x < 0 {
            scrollPosition.scrollTo(x: max(0, shown * pixelsPerSecond - viewportWidth * 0.05))
        }
    }
}
