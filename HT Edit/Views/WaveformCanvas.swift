//
//  WaveformCanvas.swift
//  HT Edit
//

import CoreMedia
import SwiftUI

/// Draws the ruler, waveform, removed parts, markers, clip boundaries and
/// threshold line for the visible slice of the timeline only, so cost is
/// independent of media length and clip count.
///
/// Removed parts (silences, cut words, no speech) look disabled: a faint gray
/// band with the waveform grayed out, and a gray bar along each part's top
/// edge that the timeline shows a hover card for. Parts are split wherever
/// the reason changes, and each has its own bar.
///
/// Inputs are plain values; SwiftUI only re-renders when they change, never
/// on playhead movement (the playhead lives in its own overlay).
struct WaveformCanvas: View {
    let lanes: [ClipLane]
    /// Everything left out of the edit, sorted.
    var removed: [RemovedRange] = []
    /// Marker positions, timeline seconds.
    var markerTimes: [Double] = []
    /// Index in `removed` whose top bar is hovered.
    var hoveredRemoval: Int? = nil
    let thresholdDB: Double
    /// Horizontal scroll offset of the visible slice, in points.
    let offset: CGFloat
    let pixelsPerSecond: CGFloat

    /// dBFS mapped to the bottom of the waveform; matches the threshold slider's minimum.
    static let floorDB = Float(SilenceSettings.thresholdRange.lowerBound)
    /// The waveform: white in dark mode (and near-black in light mode, where white wouldn't show).
    static let waveColor = Color.primary
    static let rulerHeight: CGFloat = 18
    /// The gray bar along the top of each removed part.
    static let removedBarHeight: CGFloat = 5
    /// How far below the ruler the pointer counts as hovering that bar.
    static let hoverStripHeight: CGFloat = 14
    /// Removed parts are drawn at this opacity.
    static let disabledOpacity = 0.3
    private static let barStep: CGFloat = 2
    private static let barWidth: CGFloat = 1.5
    private static let tickSteps: [Double] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800]
    private static let maximumTicks = 2_000

    var body: some View {
        Canvas { context, size in
            guard pixelsPerSecond.isFinite, pixelsPerSecond > 0, offset.isFinite,
                  size.width > 0, size.height > Self.rulerHeight else { return }
            let visibleStart = Double(offset / pixelsPerSecond)
            let visibleEnd = visibleStart + Double(size.width / pixelsPerSecond)
            guard visibleStart.isFinite, visibleEnd.isFinite else { return }
            let wave = CGRect(x: 0, y: Self.rulerHeight, width: size.width, height: size.height - Self.rulerHeight)

            context.fill(Path(roundedRect: wave, cornerRadius: 6), with: .color(.secondary.opacity(0.08)))

            let (removedPath, bars, hoveredBar) = removedShapes(wave: wave, visibleStart: visibleStart, visibleEnd: visibleEnd)
            context.fill(removedPath, with: .color(.gray.opacity(0.12)))

            var peaks = Path()
            for lane in lanes where lane.start + lane.duration >= visibleStart && lane.start <= visibleEnd {
                addWaveform(of: lane, wave: wave, visibleStart: visibleStart, peaks: &peaks)
            }
            if removedPath.isEmpty {
                context.fill(peaks, with: .color(Self.waveColor))
            } else {
                var kept = context
                kept.clip(to: removedPath, options: .inverse)
                kept.fill(peaks, with: .color(Self.waveColor))

                var disabled = context
                disabled.clip(to: removedPath)
                disabled.opacity = Self.disabledOpacity
                disabled.fill(peaks, with: .color(.gray))
            }
            context.fill(bars, with: .color(.gray.opacity(0.45)))
            if !hoveredBar.isEmpty {
                context.fill(hoveredBar, with: .color(.gray.opacity(0.9)))
            }

            drawThreshold(in: &context, wave: wave)
            drawClipBoundaries(in: &context, height: size.height, visibleStart: visibleStart, visibleEnd: visibleEnd)
            drawRuler(in: &context, visibleStart: visibleStart, visibleEnd: visibleEnd)
            drawMarkers(in: &context, height: size.height, visibleStart: visibleStart, visibleEnd: visibleEnd)
        }
    }

    private func xPosition(for seconds: Double, visibleStart: Double) -> CGFloat {
        CGFloat(seconds - visibleStart) * pixelsPerSecond
    }

    /// The visible removed parts over the wave area, their top bars, and the hovered bar.
    private func removedShapes(wave: CGRect, visibleStart: Double, visibleEnd: Double) -> (area: Path, bars: Path, hovered: Path) {
        var area = Path()
        var bars = Path()
        var hovered = Path()
        guard !removed.isEmpty else { return (area, bars, hovered) }
        for index in RemovalPlanner.firstIndex(endingAfter: visibleStart, in: removed)..<removed.count {
            let start = removed[index].range.start.seconds
            let end = removed[index].range.end.seconds
            if start > visibleEnd { break }
            if end < visibleStart { continue }
            let x0 = max(-1, xPosition(for: start, visibleStart: visibleStart))
            let x1 = min(wave.width + 1, xPosition(for: end, visibleStart: visibleStart))
            guard x0.isFinite, x1.isFinite else { continue }
            let width = max(1, x1 - x0)
            area.addRect(CGRect(x: x0, y: wave.minY, width: width, height: wave.height))
            // Each part has its own bar, with a hairline gap where parts touch,
            // so the timeline shows where the reason changes.
            let inset: CGFloat = width > 3 ? 0.5 : 0
            let bar = CGRect(x: x0 + inset, y: wave.minY, width: width - 2 * inset, height: Self.removedBarHeight)
            if index == hoveredRemoval { hovered.addRect(bar) } else { bars.addRect(bar) }
        }
        return (area, bars, hovered)
    }

    /// Samples one clip's own levels (each clip keeps its own sample rate) for
    /// the columns it covers on screen, adding its bars to `peaks`.
    ///
    /// Only the peak level is drawn: it's what word cuts are placed by (the
    /// quietest peak in a pause), so what you see is what cuts follow.
    private func addWaveform(of lane: ClipLane, wave: CGRect, visibleStart: Double, peaks peakPath: inout Path) {
        let levels = lane.levels
        guard levels.windowCount > 0, levels.windowSeconds > 0 else { return }
        let laneMinX = max(0, xPosition(for: lane.start, visibleStart: visibleStart))
        let laneMaxX = min(wave.width, xPosition(for: lane.start + lane.duration, visibleStart: visibleStart))
        guard laneMinX.isFinite, laneMaxX.isFinite, laneMaxX > laneMinX else { return }

        let firstColumn = Int((laneMinX / Self.barStep).rounded(.down))
        let lastColumn = Int((laneMaxX / Self.barStep).rounded(.up))
        let columns = lastColumn - firstColumn
        guard columns > 0 else { return }

        let windowSeconds = levels.windowSeconds
        let windowsPerColumn = Double(Self.barStep / pixelsPerSecond) / windowSeconds
        let columnStartTime = visibleStart + Double(CGFloat(firstColumn) * Self.barStep / pixelsPerSecond)
        let startWindow = (columnStartTime - lane.start) / windowSeconds
        guard windowsPerColumn.isFinite, startWindow.isFinite, abs(startWindow) < Double(Int.max / 4) else { return }

        let peaks = WaveformSampler.buckets(levels.peakDB, startWindow: startWindow, windowsPerBucket: windowsPerColumn, count: columns)

        let midY = wave.midY
        let halfHeight = wave.height / 2 - 2
        for column in 0..<columns {
            let x = CGFloat(firstColumn + column) * Self.barStep
            guard x >= laneMinX - Self.barStep, x < laneMaxX else { continue }
            let peakHeight = CGFloat(WaveformSampler.normalized(peaks[column], floorDB: Self.floorDB)) * halfHeight
            if peakHeight > 0 {
                peakPath.addRect(CGRect(x: x, y: midY - peakHeight, width: Self.barWidth, height: peakHeight * 2))
            }
        }
    }

    /// The threshold drawn on the same dB scale as the waveform, so users can see
    /// exactly which parts fall below it.
    private func drawThreshold(in context: inout GraphicsContext, wave: CGRect) {
        let level = CGFloat(WaveformSampler.normalized(Float(thresholdDB), floorDB: Self.floorDB)) * (wave.height / 2 - 2)
        var path = Path()
        path.move(to: CGPoint(x: 0, y: wave.midY - level))
        path.addLine(to: CGPoint(x: wave.width, y: wave.midY - level))
        path.move(to: CGPoint(x: 0, y: wave.midY + level))
        path.addLine(to: CGPoint(x: wave.width, y: wave.midY + level))
        context.stroke(path, with: .color(.orange.opacity(0.9)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
    }

    /// A yellow line where each clip after the first begins.
    private func drawClipBoundaries(in context: inout GraphicsContext, height: CGFloat, visibleStart: Double, visibleEnd: Double) {
        var path = Path()
        for lane in lanes.dropFirst() where lane.start >= visibleStart && lane.start <= visibleEnd {
            let x = xPosition(for: lane.start, visibleStart: visibleStart)
            path.addRect(CGRect(x: x - 1, y: 0, width: 2, height: height))
        }
        context.fill(path, with: .color(.yellow))
    }

    private func drawRuler(in context: inout GraphicsContext, visibleStart: Double, visibleEnd: Double) {
        let minimumSpacing: CGFloat = 80
        let step = Self.tickSteps.first { CGFloat($0) * pixelsPerSecond >= minimumSpacing } ?? Self.tickSteps.last!
        let fractionDigits = step < 1 ? (step < 0.25 ? 1 : 2) : 0
        var ticks = Path()
        var tick = (visibleStart / step).rounded(.down) * step
        var count = 0
        while tick <= visibleEnd, count < Self.maximumTicks {
            count += 1
            let x = xPosition(for: tick, visibleStart: visibleStart)
            ticks.move(to: CGPoint(x: x, y: Self.rulerHeight - 6))
            ticks.addLine(to: CGPoint(x: x, y: Self.rulerHeight))
            context.draw(
                Text(TimeFormatting.string(tick, fractionDigits: fractionDigits))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary),
                at: CGPoint(x: x + 3, y: (Self.rulerHeight - 4) / 2),
                anchor: .leading
            )
            tick += step
        }
        context.stroke(ticks, with: .color(.secondary), lineWidth: 1)
    }

    /// A blue line for each marker, with a small flag in the ruler.
    private func drawMarkers(in context: inout GraphicsContext, height: CGFloat, visibleStart: Double, visibleEnd: Double) {
        guard !markerTimes.isEmpty else { return }
        var lines = Path()
        var flags = Path()
        for time in markerTimes where time >= visibleStart && time <= visibleEnd {
            let x = xPosition(for: time, visibleStart: visibleStart)
            guard x.isFinite else { continue }
            lines.addRect(CGRect(x: x - 1, y: 0, width: 2, height: height))
            flags.move(to: CGPoint(x: x - 5, y: 0))
            flags.addLine(to: CGPoint(x: x + 5, y: 0))
            flags.addLine(to: CGPoint(x: x, y: 7))
            flags.closeSubpath()
        }
        context.fill(lines, with: .color(.blue))
        context.fill(flags, with: .color(.blue))
    }
}
