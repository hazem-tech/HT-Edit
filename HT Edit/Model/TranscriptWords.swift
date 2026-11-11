//
//  TranscriptWords.swift
//  HT Edit
//

import Foundation

/// Pure helpers for the words of a transcript line: splitting text into
/// words, estimating times when the aligner can't measure them, and filling
/// in what it couldn't place.
nonisolated enum TranscriptWords {

    /// The words of `text`, as they are shown and selected.
    ///
    /// Splits on whitespace. Punctuation written apart from a word (Arabic
    /// "،" or "؟", a dash, a lone quote) is joined to the word before it, so
    /// every token has letters or digits to say.
    static func tokenize(_ text: String) -> [String] {
        var words: [String] = []
        for token in text.split(whereSeparator: \.isWhitespace).map(String.init) {
            if !token.contains(where: { $0.isLetter || $0.isNumber }), let last = words.indices.last {
                words[last] += " " + token
            } else {
                words.append(token)
            }
        }
        return words
    }

    /// The words of `segment` spread over its time, by length: an estimate for
    /// a line the aligner hasn't measured. Every word is marked approximate.
    static func evenlySpread(_ segment: TranscriptSegment) -> [TranscriptWord] {
        let words = tokenize(segment.text)
        guard !words.isEmpty else { return [] }
        let weights = words.map { Double(max(1, spokenLength($0))) }
        let total = weights.reduce(0, +)
        let span = max(0, segment.end - segment.start)
        var start = segment.start
        return zip(words, weights).map { word, weight in
            let end = start + span * weight / total
            defer { start = end }
            return TranscriptWord(start: start, end: end, text: word, isApproximate: true)
        }
    }

    /// Combines `words` with the aligner's times for them (in the same order;
    /// `nil` for a word it couldn't place, such as digits).
    ///
    /// A missing time is filled from the neighbors: the word gets the gap
    /// between them, or shares the previous word's span when there's no gap.
    /// Times are kept in order and inside `segment`.
    static func filling(_ words: [String], times: [TranscriptWord?], in segment: TranscriptSegment) -> [TranscriptWord] {
        precondition(words.count == times.count)
        let lower = segment.start
        let upper = max(segment.start, segment.end)
        var result: [TranscriptWord] = []
        result.reserveCapacity(words.count)
        for (index, text) in words.enumerated() {
            let floor = result.last?.end ?? lower
            if let measured = times[index] {
                let start = min(max(measured.start, floor), upper)
                let end = min(max(measured.end, start), upper)
                result.append(TranscriptWord(start: start, end: end, text: text, isApproximate: false))
            } else {
                let next = times[(index + 1)...].lazy.compactMap { $0 }.first?.start ?? upper
                let end = min(max(next, floor), upper)
                result.append(TranscriptWord(start: floor, end: end, text: text, isApproximate: true))
            }
        }
        return result
    }

    /// A word's identity on the timeline: the clip, where the word starts (ms) and its text.
    static func id(clipID: UUID, word: TranscriptWord) -> String {
        "\(clipID.uuidString)@\(Int((word.start * 1000).rounded()))#\(word.text)"
    }

    /// Letters and digits in `word`, ignoring Arabic diacritics and tatweel,
    /// which take no time to say.
    static func spokenLength(_ word: String) -> Int {
        word.unicodeScalars.count(where: { scalar in
            guard CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) else { return false }
            return !isArabicMark(scalar)
        })
    }

    private static func isArabicMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0610...0x061A, 0x064B...0x065F, 0x0670, 0x06D6...0x06ED, 0x0640: true
        default: false
        }
    }
}
