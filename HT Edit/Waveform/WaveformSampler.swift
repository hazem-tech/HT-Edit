//
//  WaveformSampler.swift
//  HT Edit
//

import Accelerate

/// Reduces per-window levels to one value per on-screen column.
///
/// Only the visible slice is ever sampled, so drawing cost depends on the view
/// width, not on the media length.
nonisolated enum WaveformSampler {

    /// Returns `count` buckets, each the maximum of the windows it covers.
    ///
    /// - Parameters:
    ///   - levels: Per-window values (e.g. dBFS).
    ///   - startWindow: Fractional window index of the first bucket's left edge.
    ///   - windowsPerBucket: How many windows one bucket spans (may be < 1 when zoomed in).
    ///   - count: Number of buckets to produce.
    ///   - fill: Value used for buckets that fall outside `levels`.
    static func buckets(
        _ levels: [Float],
        startWindow: Double,
        windowsPerBucket: Double,
        count: Int,
        fill: Float = AudioLevels.floorDB
    ) -> [Float] {
        guard count > 0 else { return [] }
        guard !levels.isEmpty, windowsPerBucket.isFinite, windowsPerBucket > 0, startWindow.isFinite else {
            return Array(repeating: fill, count: count)
        }

        // Positions far outside the levels are clamped just past either end
        // before converting to Int, which traps on huge or non-finite values.
        let limit = Double(levels.count) + 1
        func windowIndex(_ position: Double) -> Int {
            Int(min(limit, max(-1, position)).rounded(.down))
        }

        return levels.withUnsafeBufferPointer { source in
            [Float](unsafeUninitializedCapacity: count) { output, initialized in
                for bucket in 0..<count {
                    let lower = windowIndex(startWindow + Double(bucket) * windowsPerBucket)
                    let upper = max(lower + 1, windowIndex(startWindow + Double(bucket + 1) * windowsPerBucket))
                    let clampedLower = max(0, lower)
                    let clampedUpper = min(source.count, upper)
                    if clampedLower < clampedUpper {
                        output[bucket] = vDSP.maximum(UnsafeBufferPointer(rebasing: source[clampedLower..<clampedUpper]))
                    } else {
                        output[bucket] = fill
                    }
                }
                initialized = count
            }
        }
    }

    /// Maps a dBFS value to 0...1 for drawing, where `floorDB` maps to 0 and 0 dBFS to 1.
    /// Non-finite values (e.g. `AudioLevels.unanalyzed`) map to 0 so they draw as empty.
    static func normalized(_ decibels: Float, floorDB: Float) -> Float {
        guard floorDB < 0, decibels.isFinite else { return 0 }
        return min(1, max(0, (decibels - floorDB) / -floorDB))
    }
}
