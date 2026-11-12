//
//  NonSpeech.swift
//  HT Edit
//

import Foundation

/// Finds what isn't speech in a clip: everything outside its transcribed words.
///
/// Used once a clip's transcript is complete and its word times are measured,
/// so the edit keeps only speech: no silences, and no noises that aren't words.
nonisolated enum NonSpeechPlanner {
    /// Pauses between words shorter than this are kept, so speech flows naturally.
    static let minimumGap = 0.3
    /// Audio kept next to each word, so word edges a little off aren't clipped.
    static let padding = 0.1

    /// Clip-second ranges without speech, sorted and non-overlapping: before
    /// the first word, after the last, and every long pause between words.
    /// A clip without words gets none (nothing to tell speech from).
    static func ranges(words: [TimelineWord], clipDuration: Double, minimumGap: Double = minimumGap, padding: Double = padding) -> [Range<Double>] {
        guard clipDuration.isFinite, clipDuration > 0 else { return [] }
        let spoken = words
            .filter { $0.clipStart.isFinite && $0.clipEnd.isFinite }
            .sorted { $0.clipStart < $1.clipStart }
        guard let first = spoken.first else { return [] }

        var result: [Range<Double>] = []
        func add(_ lower: Double, _ upper: Double) {
            let lower = max(0, lower), upper = min(clipDuration, upper)
            guard upper > lower else { return }
            result.append(lower..<upper)
        }

        // Before the first word.
        if first.clipStart >= minimumGap {
            add(0, first.clipStart - padding)
        }
        // Between words: the running end handles words that overlap.
        var spokenUntil = first.clipEnd
        for word in spoken.dropFirst() {
            if word.clipStart - spokenUntil >= minimumGap {
                add(spokenUntil + padding, word.clipStart - padding)
            }
            spokenUntil = max(spokenUntil, word.clipEnd)
        }
        // After the last word.
        if clipDuration - spokenUntil >= minimumGap {
            add(spokenUntil + padding, clipDuration)
        }
        return result
    }
}
