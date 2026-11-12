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

    /// Where reasons overlap, the lowest wins: words the user cut, then
    /// silence (which is also not speech), then no speech.
    var priority: Int {
        switch self {
        case .cutWords: 0
        case .silence: 1
        case .noSpeech: 2
        }
    }

    private static func shortened(_ text: String, limit: Int = 40) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// A stretch of the timeline that playback skips, and why.
nonisolated struct RemovedRange: Equatable, Sendable {
    var range: CMTimeRange
    var reason: RemovalReason
}

/// Combines what each feature removes into one sorted list.
nonisolated enum RemovalPlanner {
    /// Pieces shorter than this (where two boundaries nearly meet) join the part next to them.
    static let minimumPart = CMTime(value: 1, timescale: 100)

    /// Sorted, non-overlapping parts covering every tagged range, each with
    /// one reason. A stretch where reasons overlap takes the highest-priority
    /// one, and the timeline is split wherever the reason changes: silence
    /// inside a pause without speech reads "No speech", "Silence", "No speech".
    /// Touching parts with the same reason are one part.
    static func parts(_ tagged: [(range: CMTimeRange, reason: RemovalReason)]) -> [RemovedRange] {
        struct Event {
            var time: CMTime
            var delta: Int
            var reason: RemovalReason
        }
        let events = tagged
            .filter { $0.range.isValid && $0.range.start.isNumeric && $0.range.duration > .zero }
            .flatMap { [Event(time: $0.range.start, delta: 1, reason: $0.reason), Event(time: $0.range.end, delta: -1, reason: $0.reason)] }
            .sorted { $0.time < $1.time }

        var active: [RemovalReason: Int] = [:]
        var result: [RemovedRange] = []
        var index = 0
        while index < events.count {
            let time = events[index].time
            while index < events.count, events[index].time == time {
                let event = events[index]
                let count = active[event.reason, default: 0] + event.delta
                active[event.reason] = count > 0 ? count : nil
                index += 1
            }
            guard index < events.count, let reason = primary(of: active.keys) else { continue }
            append(RemovedRange(range: CMTimeRange(start: time, end: events[index].time), reason: reason), to: &result)
        }
        return result
    }

    /// The reason a stretch shows when several apply.
    static func primary(of reasons: some Collection<RemovalReason>) -> RemovalReason? {
        reasons.min { ($0.priority, $0.title) < ($1.priority, $1.title) }
    }

    /// Adds `part` after the parts so far, joining it to the last one when they
    /// touch and share a reason, or when either is only a sliver.
    private static func append(_ part: RemovedRange, to result: inout [RemovedRange]) {
        guard part.range.duration > .zero else { return }
        guard let last = result.last, last.range.end >= part.range.start else {
            result.append(part)
            return
        }
        if last.reason == part.reason || part.range.duration < minimumPart {
            result[result.count - 1].range = CMTimeRange(start: last.range.start, end: CMTimeMaximum(last.range.end, part.range.end))
        } else if last.range.duration < minimumPart {
            // A sliver that starts a stretch (touching slivers join the part
            // before them, above) takes this part's reason.
            result[result.count - 1] = RemovedRange(range: CMTimeRange(start: last.range.start, end: part.range.end), reason: part.reason)
        } else {
            result.append(part)
        }
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
