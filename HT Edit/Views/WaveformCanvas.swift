//
//  WaveformCanvas.swift
//  HT Edit
//

import CoreMedia
import SwiftUI

/// Draws the ruler, waveform, silence highlights and threshold line for the
/// visible slice of the timeline only, so cost is independent of media length.
///
/// Inputs are plain values; SwiftUI only re-renders when they change, never
/// on playhead movement (the playhead lives in its own overlay).
struct WaveformCanvas: View {
    let levels: AudioLevels
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
            drawWaveform(in: &context, wave: wave, visibleStart: visibleStart)
            drawThreshold(in: &context, wave: wave)
            drawRuler(in: &context, width: size.width, visibleStart: visibleStart, visibleEnd: visibleEnd)
        }
        .drawingGroup()
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

    private func drawWaveform(in context: inout GraphicsContext, wave: CGRect, visibleStart: Double) {
        guard levels.windowCount > 0 else { return }
        let columns = Int(wave.width / Self.barStep) + 1
        let windowSeconds = levels.windowSeconds
        let windowsPerColumn = Double(Self.barStep / pixelsPerSecond) / windowSeconds
        let startWindow = visibleStart / windowSeconds

        let peaks = WaveformSampler.buckets(levels.peakDB, startWindow: startWindow, windowsPerBucket: windowsPerColumn, count: columns)
        let rms = WaveformSampler.buckets(levels.rmsDB, startWindow: startWindow, windowsPerBucket: windowsPerColumn, count: columns)

        let midY = wave.midY
        let halfHeight = wave.height / 2 - 2
        var peakPath = Path()
        var rmsPath = Path()
        for column in 0..<columns {
            let x = CGFloat(column) * Self.barStep
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

    private func drawRuler(in context: inout GraphicsContext, width: CGFloat, visibleStart: Double, visibleEnd: Double) {
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
