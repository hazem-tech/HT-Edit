//
//  AudioSegmentPlanner.swift
//  HT Edit
//

import Foundation

/// Splits a track into window-aligned segments that are decoded in parallel.
nonisolated enum AudioSegmentPlanner {

    /// Below this many windows per segment, the cost of an extra reader outweighs the gain.
    static let minimumWindowsPerSegment = 2_000 // 20 s at 10 ms windows

    /// Contiguous window ranges covering `0..<totalWindows`, at most `count` of them.
    static func segments(
        totalWindows: Int,
        count: Int,
        minimumWindowsPerSegment: Int = minimumWindowsPerSegment
    ) -> [Range<Int>] {
        guard totalWindows > 0 else { return [] }
        let byLength = max(1, totalWindows / max(1, minimumWindowsPerSegment))
        let segmentCount = max(1, min(count, byLength))
        let base = totalWindows / segmentCount
        let remainder = totalWindows % segmentCount

        var ranges: [Range<Int>] = []
        ranges.reserveCapacity(segmentCount)
        var start = 0
        for index in 0..<segmentCount {
            let length = base + (index < remainder ? 1 : 0)
            ranges.append(start..<(start + length))
            start += length
        }
        return ranges
    }

    /// Default parallelism: one reader per performance-relevant core.
    static var defaultSegmentCount: Int {
        max(1, ProcessInfo.processInfo.activeProcessorCount)
    }
}
