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
/// Removed parts (silences, cut words, no speech) look disabled: the same
/// blue waveform, dimmed, and a thin dark bar along each part's top
/// edge that the timeline shows a hover card for. Parts are split wherever
/// the reason changes, and each has its own bar.
///
/// With an `editMap` (the Clean layout), the timeline is drawn in edited
/// time: only the kept pieces, back to back, and nothing dimmed.
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
    /// Set in the Clean layout: draw only the kept pieces, in edited time.
    var editMap: EditMap? = nil
    /// Horizontal scroll offset of the visible slice, in points.
    let offset: CGFloat
    let pixelsPerSecond: CGFloat

    /// dBFS mapped to the bottom of the waveform; matches the threshold slider's minimum.
    static let floorDB = Float(SilenceSettings.thresholdRange.lowerBound)
    /// The waveform: a light blue peak layer behind a solid blue average (RMS) layer.
    static let peakColor = Color.accentColor.opacity(0.35)
    static let rmsColor = Color.accentColor
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

            var peaks = Path()
            var rms = Path()
            if let editMap {
                addKeptWaveform(editMap, wave: wave, visibleStart: visibleStart, visibleEnd: visibleEnd, peaks: &peaks, rms: &rms)
            } else {
                for lane in lanes where lane.start + lane.duration >= visibleStart && lane.start <= visibleEnd {
                    addWaveform(of: lane, from: lane.start, to: lane.start + lane.duration, shownAt: lane.start, wave: wave, visibleStart: visibleStart, peaks: &peaks, rms: &rms)
                }
            }
            if removedPath.isEmpty {
                context.fill(peaks, with: .color(Self.peakColor))
                context.fill(rms, with: .color(Self.rmsColor))
            } else {
                var kept = context
                kept.clip(to: removedPath, options: .inverse)
                kept.fill(peaks, with: .color(Self.peakColor))
                kept.fill(rms, with: .color(Self.rmsColor))

                // Removed parts: the same waveform, only dimmer. No gray band over them.
                var dimmed = context
                dimmed.clip(to: removedPath)
                dimmed.opacity = Self.disabledOpacity
                dimmed.fill(peaks, with: .color(Self.peakColor))
                dimmed.fill(rms, with: .color(Self.rmsColor))
            }
            // A thin, dark bar marks each removed part (and is what its hover card answers to).
            context.fill(bars, with: .color(.primary.opacity(0.2)))
            if !hoveredBar.isEmpty {
                context.fill(hoveredBar, with: .color(.primary.opacity(0.55)))
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

    /// Where full-timeline `seconds` is drawn: as is, or in edited time.
    private func shown(_ seconds: Double) -> Double {
        editMap?.edited(fromSource: seconds) ?? seconds
    }

    /// The Clean layout: each visible kept piece, with the part of each clip it covers.
    private func addKeptWaveform(_ map: EditMap, wave: CGRect, visibleStart: Double, visibleEnd: Double, peaks: inout Path, rms: inout Path) {
        let pieces = map.pieces
        for index in map.firstIndex(endingAfterEdited: visibleStart)..<pieces.count {
            let piece = pieces[index]
            if piece.editedStart > visibleEnd { break }
            for lane in lanes {
                let start = max(piece.source.lowerBound, lane.start)
                let end = min(piece.source.upperBound, lane.start + lane.duration)
                guard end > start else { continue }
                let shownAt = piece.editedStart + (start - piece.source.lowerBound)
                addWaveform(of: lane, from: start, to: end, shownAt: shownAt, wave: wave, visibleStart: visibleStart, peaks: &peaks, rms: &rms)
            }
        }
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
    /// full-timeline seconds `start..<end`, drawn from timeline position
    /// `shownAt`, for the columns they cover on screen, adding its bars to
    /// `peaks` and `rms`.
    private func addWaveform(
        of lane: ClipLane,
        from start: Double,
        to end: Double,
        shownAt: Double,
        wave: CGRect,
        visibleStart: Double,
        peaks peakPath: inout Path,
        rms rmsPath: inout Path
    ) {
        let levels = lane.levels
        guard levels.windowCount > 0, levels.windowSeconds > 0 else { return }
        let laneMinX = max(0, xPosition(for: shownAt, visibleStart: visibleStart))
        let laneMaxX = min(wave.width, xPosition(for: shownAt + (end - start), visibleStart: visibleStart))
        guard laneMinX.isFinite, laneMaxX.isFinite, laneMaxX > laneMinX else { return }

        let firstColumn = Int((laneMinX / Self.barStep).rounded(.down))
        let lastColumn = Int((laneMaxX / Self.barStep).rounded(.up))
        let columns = lastColumn - firstColumn
        guard columns > 0 else { return }

        let windowSeconds = levels.windowSeconds
        let windowsPerColumn = Double(Self.barStep / pixelsPerSecond) / windowSeconds
        // The first column's position on screen, then the same moment in the clip.
        let columnStartTime = visibleStart + Double(CGFloat(firstColumn) * Self.barStep / pixelsPerSecond)
        let clipTime = columnStartTime - shownAt + (start - lane.start)
        let startWindow = clipTime / windowSeconds
        guard windowsPerColumn.isFinite, startWindow.isFinite, abs(startWindow) < Double(Int.max / 4) else { return }

        let peaks = WaveformSampler.buckets(levels.peakDB, startWindow: startWindow, windowsPerBucket: windowsPerColumn, count: columns)
        let rms = WaveformSampler.buckets(levels.rmsDB, startWindow: startWindow, windowsPerBucket: windowsPerColumn, count: columns)

        let midY = wave.midY
        let halfHeight = wave.height / 2 - 2
        for column in 0..<columns {
            let x = CGFloat(firstColumn + column) * Self.barStep
            guard x >= laneMinX - Self.barStep, x < laneMaxX else { continue }
            let peakHeight = CGFloat(WaveformSampler.normalized(peaks[column], floorDB: Self.floorDB)) * halfHeight
            let rmsHeight = CGFloat(WaveformSampler.normalized(rms[column], floorDB: Self.floorDB)) * halfHeight
            if peakHeight > 0 {
                peakPath.addRect(CGRect(x: x, y: midY - peakHeight, width: Self.barWidth, height: peakHeight * 2))
            }
            if rmsHeight > 0 {
                rmsPath.addRect(CGRect(x: x, y: midY - rmsHeight, width: Self.barWidth, height: rmsHeight * 2))
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
        for lane in lanes.dropFirst() {
            let start = shown(lane.start)
            guard start >= visibleStart, start <= visibleEnd else { continue }
            let x = xPosition(for: start, visibleStart: visibleStart)
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
        for time in markerTimes.lazy.map({ shown($0) }) where time >= visibleStart && time <= visibleEnd {
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
