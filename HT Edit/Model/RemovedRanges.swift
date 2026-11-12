//
//  RemovedRanges.swift
//  HT Edit
//

import CoreMedia
import Foundation

/// Why a stretch of the timeline is left out of the edit.
nonisolated enum RemovalReason: Hashable, Sendable {
    /// Quieter than the silence threshold.
    case silence
    /// No transcribed word: not speech.
    case noSpeech
    /// Words deleted in the transcript.
    case cutWords(String)

    /// What the timeline's hover card says.
    var title: String {
        switch self {
        case .silence: "Silence"
        case .noSpeech: "No speech"
        case .cutWords(let text): "Cut words: “\(Self.shortened(text))”"
        }
    }

    private static func shortened(_ text: String, limit: Int = 40) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// A stretch of the timeline that playback skips, and every reason it does.
nonisolated struct RemovedRange: Equatable, Sendable {
    var range: CMTimeRange
    /// In the order they were first found, without duplicates.
    var reasons: [RemovalReason]
}

/// Combines what each feature removes into one sorted list.
nonisolated enum RemovalPlanner {

    /// Sorted, non-overlapping ranges covering every tagged range. Ranges that
    /// overlap or touch are merged, and their reasons collected.
    static func merge(_ tagged: [(range: CMTimeRange, reason: RemovalReason)]) -> [RemovedRange] {
        let sorted = tagged
            .filter { $0.range.isValid && $0.range.duration > .zero }
            .sorted { $0.range.start < $1.range.start }
        var result: [RemovedRange] = []
        for entry in sorted {
            if let last = result.last, entry.range.start <= last.range.end {
                var merged = last
                merged.range = CMTimeRange(start: last.range.start, end: CMTimeMaximum(last.range.end, entry.range.end))
                if !merged.reasons.contains(entry.reason) { merged.reasons.append(entry.reason) }
                result[result.count - 1] = merged
            } else {
                result.append(RemovedRange(range: entry.range, reasons: [entry.reason]))
            }
        }
        return result
    }

    /// Index of the first range ending after `seconds` (`ranges.count` if none), by binary search.
    static func firstIndex(endingAfter seconds: Double, in ranges: [RemovedRange]) -> Int {
        var low = 0, high = ranges.count
        while low < high {
            let mid = (low + high) / 2
            if ranges[mid].range.end.seconds <= seconds { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Index of the range containing `seconds` (`start <= seconds < end`).
    static func index(containing seconds: Double, in ranges: [RemovedRange]) -> Int? {
        guard seconds.isFinite else { return nil }
        let index = firstIndex(endingAfter: seconds, in: ranges)
        guard index < ranges.count, ranges[index].range.start.seconds <= seconds else { return nil }
        return index
    }
}
