//
//  WaveformCanvas.swift
//  HT Edit
//

import CoreMedia
import SwiftUI

/// Draws the ruler, waveform, silence highlights, clip boundaries and threshold
/// line for the visible slice of the timeline only, so cost is independent of
/// media length and clip count.
///
/// Inputs are plain values; SwiftUI only re-renders when they change, never
/// on playhead movement (the playhead lives in its own overlay).
struct WaveformCanvas: View {
    let lanes: [ClipLane]
    let silences: [CMTimeRange]
    let thresholdDB: Double
    /// Horizontal scroll offset of the visible slice, in points.
    let offset: CGFloat
    let pixelsPerSecond: CGFloat

    /// dBFS mapped to the bottom of the waveform; matches the threshold slider's minimum.
    static let floorDB = Float(SilenceSettings.thresholdRange.lowerBound)
    static let rulerHeight: CGFloat = 18
    private static let barStep: CGFloat = 2
    private static let barWidth: CGFloat = 1.5
    private static let tickSteps: [Double] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800]

    var body: some View {
        Canvas { context, size in
            guard pixelsPerSecond > 0, size.width > 0 else { return }
            let visibleStart = Double(offset / pixelsPerSecond)
            let visibleEnd = visibleStart + Double(size.width / pixelsPerSecond)
            let wave = CGRect(x: 0, y: Self.rulerHeight, width: size.width, height: size.height - Self.rulerHeight)

            context.fill(Path(roundedRect: wave, cornerRadius: 6), with: .color(.secondary.opacity(0.08)))
            drawSilences(in: &context, wave: wave, visibleStart: visibleStart, visibleEnd: visibleEnd)
            for lane in lanes where lane.start + lane.duration >= visibleStart && lane.start <= visibleEnd {
                drawWaveform(of: lane, in: &context, wave: wave, visibleStart: visibleStart)
            }
            drawThreshold(in: &context, wave: wave)
            drawClipBoundaries(in: &context, height: size.height, visibleStart: visibleStart, visibleEnd: visibleEnd)
            drawRuler(in: &context, visibleStart: visibleStart, visibleEnd: visibleEnd)
        }
    }

    private func xPosition(for seconds: Double, visibleStart: Double) -> CGFloat {
        CGFloat(seconds - visibleStart) * pixelsPerSecond
    }

    private func drawSilences(in context: inout GraphicsContext, wave: CGRect, visibleStart: Double, visibleEnd: Double) {
        var fill = Path()
        var edges = Path()
        for range in silences {
            let start = range.start.seconds
            let end = range.end.seconds
            if end < visibleStart { continue }
            if start > visibleEnd { break }
            let x0 = xPosition(for: start, visibleStart: visibleStart)
            let x1 = xPosition(for: end, visibleStart: visibleStart)
            let rect = CGRect(x: x0, y: wave.minY, width: max(1, x1 - x0), height: wave.height)
            fill.addRect(rect)
            edges.addRect(CGRect(x: rect.minX, y: wave.minY, width: rect.width, height: 3))
        }
        context.fill(fill, with: .color(.red.opacity(0.22)))
        context.fill(edges, with: .color(.red.opacity(0.8)))
    }

    /// Samples one clip's own levels (each clip keeps its own sample rate) for
    /// the columns it covers on screen.
    private func drawWaveform(of lane: ClipLane, in context: inout GraphicsContext, wave: CGRect, visibleStart: Double) {
        let levels = lane.levels
        guard levels.windowCount > 0 else { return }
        let laneMinX = max(0, xPosition(for: lane.start, visibleStart: visibleStart))
        let laneMaxX = min(wave.width, xPosition(for: lane.start + lane.duration, visibleStart: visibleStart))
        guard laneMaxX > laneMinX else { return }

        let firstColumn = Int((laneMinX / Self.barStep).rounded(.down))
        let lastColumn = Int((laneMaxX / Self.barStep).rounded(.up))
        let columns = lastColumn - firstColumn
        guard columns > 0 else { return }

        let windowSeconds = levels.windowSeconds
        let windowsPerColumn = Double(Self.barStep / pixelsPerSecond) / windowSeconds
        let columnStartTime = visibleStart + Double(CGFloat(firstColumn) * Self.barStep / pixelsPerSecond)
        let startWindow = (columnStartTime - lane.start) / windowSeconds

        let peaks = WaveformSampler.buckets(levels.peakDB, startWindow: startWindow, windowsPerBucket: windowsPerColumn, count: columns)
        let rms = WaveformSampler.buckets(levels.rmsDB, startWindow: startWindow, windowsPerBucket: windowsPerColumn, count: columns)

        let midY = wave.midY
        let halfHeight = wave.height / 2 - 2
        var peakPath = Path()
        var rmsPath = Path()
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
        context.fill(peakPath, with: .color(.accentColor.opacity(0.35)))
        context.fill(rmsPath, with: .color(.accentColor))
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
        while tick <= visibleEnd {
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
}
