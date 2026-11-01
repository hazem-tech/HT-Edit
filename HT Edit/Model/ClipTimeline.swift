//
//  ClipTimeline.swift
//  HT Edit
//

import CoreMedia
import Foundation

/// Pure helpers for placing clips back to back on one seamless timeline.
nonisolated enum ClipTimeline {

    /// Start time of each clip when placed back to back.
    static func starts(for durations: [CMTime]) -> [CMTime] {
        var cursor = CMTime.zero
        return durations.map { duration in
            defer { cursor = cursor + duration }
            return cursor
        }
    }

    /// Index of the clip playing at `time`, or `nil` if outside the timeline.
    static func clipIndex(at time: CMTime, durations: [CMTime]) -> Int? {
        guard time >= .zero else { return nil }
        var cursor = CMTime.zero
        for (index, duration) in durations.enumerated() {
            let end = cursor + duration
            if time < end { return index }
            cursor = end
        }
        return nil
    }

    /// Silences for the whole timeline.
    ///
    /// Each clip is detected on its own (own sample rate; its start and end count
    /// as media edges for padding), clamped to the clip's duration, shifted to its
    /// timeline position, and ranges that touch across a clip boundary are merged.
    static func silences(levels: [AudioLevels], durations: [CMTime], settings: SilenceSettings) -> [CMTimeRange] {
        let starts = starts(for: durations)
        var all: [CMTimeRange] = []
        for index in levels.indices where index < durations.count {
            let clipRange = CMTimeRange(start: .zero, duration: durations[index])
            for range in SilenceDetector.detect(levels: levels[index], settings: settings) {
                let clamped = range.intersection(clipRange)
                guard clamped.duration > .zero else { continue }
                all.append(CMTimeRange(start: clamped.start + starts[index], duration: clamped.duration))
            }
        }
        return merged(all)
    }

    /// Merges sorted ranges that overlap or touch (within `tolerance`).
    static func merged(_ ranges: [CMTimeRange], tolerance: CMTime = CMTime(value: 1, timescale: 1_000)) -> [CMTimeRange] {
        var result: [CMTimeRange] = []
        result.reserveCapacity(ranges.count)
        for range in ranges {
            if let last = result.last, range.start <= last.end + tolerance {
                result[result.count - 1] = CMTimeRange(start: last.start, end: CMTimeMaximum(last.end, range.end))
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// `array` with the elements at `offsets` moved before `destination`
    /// (same semantics as SwiftUI's `move(fromOffsets:toOffset:)`).
    static func moving<Element>(_ array: [Element], fromOffsets offsets: IndexSet, toOffset destination: Int) -> [Element] {
        let moved = offsets.map { array[$0] }
        var remaining = array.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        let insertion = destination - offsets.count(in: 0..<destination)
        remaining.insert(contentsOf: moved, at: min(max(0, insertion), remaining.count))
        return remaining
    }
}
