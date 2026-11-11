//
//  Transcript.swift
//  HT Edit
//

import Foundation

/// One timed line of a transcript. Times are seconds within its clip.
nonisolated struct TranscriptSegment: Codable, Sendable, Equatable {
    var start: Double
    var end: Double
    var text: String
    /// Whisper's second, unprompted reading of the same moment, when it differs.
    /// Only the cleanup uses it; it's never shown.
    var alternative: String? = nil
}

/// A transcript line placed on the timeline, ready to display.
nonisolated struct TimelineSegment: Sendable, Equatable, Identifiable {
    var id: String
    var clipID: UUID
    /// Timeline position, in seconds.
    var start: Double
    var end: Double
    var text: String
}

/// Pure helpers for transcripts: chunk planning, cleaning up model output,
/// merging chunks and placing segments on the timeline.
nonisolated enum TranscriptTimeline {

    /// Splits a clip into chunks of at most `length` seconds. A trailing chunk
    /// shorter than `minimumTail` is folded into the one before it, so the model
    /// never gets a uselessly short piece of audio.
    static func chunks(duration: Double, length: Double, minimumTail: Double = 20) -> [Range<Double>] {
        guard duration.isFinite, duration > 0, length > 0 else { return [] }
        var ranges: [Range<Double>] = []
        var start = 0.0
        while start < duration {
            let end = min(duration, start + length)
            ranges.append(start..<end)
            start = end
        }
        if ranges.count > 1, let last = ranges.last, last.upperBound - last.lowerBound < minimumTail {
            ranges.removeLast()
            ranges[ranges.count - 1] = ranges[ranges.count - 1].lowerBound..<last.upperBound
        }
        return ranges
    }

    /// Turns segments timed relative to `chunk` into clip time.
    ///
    /// Model output is not trusted: empty lines and lines starting past the end
    /// of the chunk are dropped, times are clamped to the chunk, and an end
    /// before its start is pulled up to the start.
    static func normalize(_ segments: [TranscriptSegment], chunk: Range<Double>) -> [TranscriptSegment] {
        let length = chunk.upperBound - chunk.lowerBound
        return segments
            .compactMap { segment -> TranscriptSegment? in
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, segment.start.isFinite, segment.end.isFinite, segment.start < length else { return nil }
                let start = max(0, segment.start)
                let end = min(max(start, segment.end), length)
                return TranscriptSegment(start: chunk.lowerBound + start, end: chunk.lowerBound + end, text: text, alternative: segment.alternative)
            }
            .sorted { $0.start < $1.start }
    }

    /// `existing` with everything that starts inside `chunk` replaced by `segments`.
    /// Chunks can arrive in any order; the result stays sorted.
    static func merging(_ segments: [TranscriptSegment], into existing: [TranscriptSegment], chunk: Range<Double>) -> [TranscriptSegment] {
        let kept = existing.filter { !chunk.contains($0.start) }
        return (kept + segments).sorted { $0.start < $1.start }
    }

    /// Places each clip's segments at the clip's position on the timeline.
    /// `clips` are the placed clips in timeline order.
    static func segments(transcripts: [UUID: [TranscriptSegment]], clips: [(id: UUID, duration: Double)]) -> [TimelineSegment] {
        var result: [TimelineSegment] = []
        var clipStart = 0.0
        for clip in clips {
            for (index, segment) in (transcripts[clip.id] ?? []).enumerated() where segment.start < clip.duration {
                result.append(TimelineSegment(
                    id: "\(clip.id.uuidString)-\(index)",
                    clipID: clip.id,
                    start: clipStart + segment.start,
                    end: clipStart + min(segment.end, clip.duration),
                    text: segment.text
                ))
            }
            clipStart += clip.duration
        }
        return result
    }

    /// Index of the segment playing at `time`: the last one starting at or before it.
    static func activeIndex(at time: Double, in segments: [TimelineSegment]) -> Int? {
        var low = 0, high = segments.count
        while low < high {
            let mid = (low + high) / 2
            if segments[mid].start <= time { low = mid + 1 } else { high = mid }
        }
        return low == 0 ? nil : low - 1
    }

    /// Plain text with a `[m:ss]` stamp per line, for copying.
    static func plainText(_ segments: [TimelineSegment]) -> String {
        segments
            .map { "[\(TimeFormatting.string($0.start, fractionDigits: 0))] \($0.text)" }
            .joined(separator: "\n")
    }
}
