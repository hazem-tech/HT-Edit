//
//  Transcript.swift
//  HT Edit
//

import Foundation

/// One recognized word, with its time in the clip (seconds).
nonisolated struct TranscriptWord: Sendable, Hashable {
    var text: String
    var start: Double
    var end: Double
}

/// A phrase of recognized speech, with its time in the clip (seconds) and,
/// when the engine provides them, per-word timings.
nonisolated struct TranscriptSegment: Sendable, Hashable {
    var text: String
    var start: Double
    var end: Double
    var words: [TranscriptWord] = []

    /// The same segment moved by `offset` seconds (clip time → timeline time).
    func shifted(by offset: Double) -> TranscriptSegment {
        TranscriptSegment(
            text: text,
            start: start + offset,
            end: end + offset,
            words: words.map { TranscriptWord(text: $0.text, start: $0.start + offset, end: $0.end + offset) }
        )
    }
}

/// What an engine produced for the file at `index` of its input.
nonisolated struct ClipTranscript: Sendable {
    var index: Int
    var segments: [TranscriptSegment]
}

/// A transcript segment placed on the seamless timeline.
nonisolated struct TranscriptLine: Identifiable, Sendable, Hashable {
    var id: String
    var clipID: UUID
    /// Times are timeline seconds.
    var segment: TranscriptSegment
}

/// Pure helpers for turning engine output into timeline lines.
nonisolated enum TranscriptTimeline {

    /// Each clip's segments, shifted to where the clip sits on the timeline.
    /// `clips` are in timeline order; clips without a transcript are skipped.
    static func lines(clips: [(id: UUID, duration: Double)], segments: [UUID: [TranscriptSegment]]) -> [TranscriptLine] {
        var lines: [TranscriptLine] = []
        var clipStart = 0.0
        for clip in clips {
            for (index, segment) in (segments[clip.id] ?? []).enumerated() where segment.start < clip.duration {
                lines.append(TranscriptLine(
                    id: "\(clip.id.uuidString)-\(index)",
                    clipID: clip.id,
                    segment: segment.shifted(by: clipStart)
                ))
            }
            clipStart += clip.duration
        }
        return lines
    }

    /// Index of the line being spoken at `time` (timeline seconds), if any.
    static func lineIndex(at time: Double, in lines: [TranscriptLine]) -> Int? {
        lines.lastIndex { $0.segment.start <= time && time < $0.segment.end }
    }

    /// Builds a segment from raw engine output: special tokens such as
    /// `<|0.00|>` are removed and empty words dropped. Returns `nil` when no
    /// text is left.
    static func segment(text: String, start: Double, end: Double, words: [(text: String, start: Double, end: Double)]) -> TranscriptSegment? {
        let cleanText = clean(text)
        let cleanWords = words.compactMap { word -> TranscriptWord? in
            let text = clean(word.text)
            return text.isEmpty ? nil : TranscriptWord(text: text, start: word.start, end: word.end)
        }
        guard !cleanText.isEmpty || !cleanWords.isEmpty else { return nil }
        return TranscriptSegment(
            text: cleanText.isEmpty ? cleanWords.map(\.text).joined(separator: " ") : cleanText,
            start: start,
            end: max(start, end),
            words: cleanWords
        )
    }

    /// Removes Whisper special tokens (`<|…|>`) and surrounding whitespace.
    static func clean(_ text: String) -> String {
        text.replacing(#/<\|[^|]*\|>/#, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Word links inside transcript text: clicking a word seeks to it.
nonisolated enum TranscriptLink {
    static let scheme = "htedit-seek"

    static func url(seconds: Double) -> URL? {
        URL(string: "\(scheme):\(seconds)")
    }

    static func seconds(from url: URL) -> Double? {
        guard url.scheme == scheme else { return nil }
        return Double(url.absoluteString.dropFirst(scheme.count + 1))
    }
}
