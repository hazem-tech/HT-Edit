//
//  Transcript.swift
//  HT Edit
//

import Foundation

/// One recognized word, in seconds from the start of its clip.
nonisolated struct TranscriptWord: Codable, Equatable, Sendable {
    var text: String
    var start: Double
    var end: Double
}

/// A short run of words (a sentence or part of one) that is highlighted and
/// clicked as a unit. Times are in seconds from the start of its clip.
nonisolated struct TranscriptPhrase: Codable, Equatable, Sendable, Identifiable {
    /// Position within the clip's transcript.
    var id: Int
    var text: String
    var start: Double
    var end: Double
}

/// A phrase placed on the timeline (clip start added).
nonisolated struct TimelinePhrase: Equatable, Sendable, Identifiable {
    var id: String
    var clipID: UUID
    var text: String
    var start: Double
    var end: Double
}

/// Pure helpers that turn word timings into phrases and place them on the timeline.
nonisolated enum TranscriptBuilder {
    /// A pause at least this long between words starts a new phrase.
    static let maximumPause = 0.7
    /// Phrases are split once they reach this many words…
    static let maximumWords = 14
    /// …or this many seconds.
    static let maximumDuration = 6.0
    /// Past this many words, a comma also ends the phrase.
    static let commaSplitWords = 7
    /// How long a caption stays up after its phrase ends.
    static let captionHold = 0.6

    // MARK: Phrases

    /// Groups words into phrases at sentence ends, pauses and length limits.
    static func phrases(from words: [TranscriptWord]) -> [TranscriptPhrase] {
        var phrases: [TranscriptPhrase] = []
        var current: [TranscriptWord] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            phrases.append(TranscriptPhrase(id: phrases.count, text: join(current.map(\.text)), start: first.start, end: max(first.start, last.end)))
            current.removeAll(keepingCapacity: true)
        }

        for word in words {
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let previous = current.last, word.start - previous.end >= maximumPause {
                flush()
            }
            current.append(TranscriptWord(text: text, start: word.start, end: word.end))

            let duration = word.end - (current.first?.start ?? word.start)
            if endsSentence(text)
                || current.count >= maximumWords
                || duration >= maximumDuration
                || (current.count >= commaSplitWords && endsClause(text)) {
                flush()
            }
        }
        flush()
        return phrases
    }

    /// Joins words with spaces, except around CJK characters (written without spaces).
    static func join(_ words: [String]) -> String {
        var result = ""
        for word in words {
            if let last = result.unicodeScalars.last, let first = word.unicodeScalars.first,
               !(isCJK(last) && isCJK(first)) {
                result += " "
            }
            result += word
        }
        return result
    }

    private static func endsSentence(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return ".?!…。？！؟".contains(last)
    }

    private static func endsClause(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return ",;:，、؛".contains(last)
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF: true
        default: false
        }
    }

    /// Replaces phrase texts with `corrections` (by phrase id). Timings never change;
    /// missing or empty corrections keep the original text.
    static func applying(_ corrections: [Int: String], to phrases: [TranscriptPhrase]) -> [TranscriptPhrase] {
        phrases.map { phrase in
            var phrase = phrase
            if let text = corrections[phrase.id]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                phrase.text = text
            }
            return phrase
        }
    }

    // MARK: Timeline

    /// Where one clip sits on the timeline, with its transcript.
    nonisolated struct ClipEntry: Sendable {
        var clipID: UUID
        var start: Double
        var duration: Double
        var phrases: [TranscriptPhrase]
    }

    /// Shifts each clip's phrases to its timeline position, clamped to the clip.
    static func timeline(_ clips: [ClipEntry]) -> [TimelinePhrase] {
        var result: [TimelinePhrase] = []
        for clip in clips {
            for phrase in clip.phrases where phrase.start < clip.duration {
                result.append(TimelinePhrase(
                    id: "\(clip.clipID.uuidString)-\(phrase.id)",
                    clipID: clip.clipID,
                    text: phrase.text,
                    start: clip.start + max(0, phrase.start),
                    end: clip.start + min(clip.duration, max(phrase.start, phrase.end))
                ))
            }
        }
        return result
    }

    /// Index of the last phrase starting at or before `seconds` (the one to highlight),
    /// or `nil` before the first phrase.
    static func phraseIndex(at seconds: Double, in phrases: [TimelinePhrase]) -> Int? {
        var low = 0, high = phrases.count
        while low < high {
            let mid = (low + high) / 2
            if phrases[mid].start <= seconds { low = mid + 1 } else { high = mid }
        }
        return low == 0 ? nil : low - 1
    }

    /// Index of the phrase to show as a caption at `seconds`: the highlighted
    /// phrase while it is spoken, plus a short hold.
    static func captionIndex(at seconds: Double, in phrases: [TimelinePhrase]) -> Int? {
        guard let index = phraseIndex(at: seconds, in: phrases),
              seconds <= phrases[index].end + captionHold else { return nil }
        return index
    }
}
