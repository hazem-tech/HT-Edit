//
//  WordCuts.swift
//  HT Edit
//

import CoreMedia
import Foundation

/// A stretch of a clip removed because its words were deleted in the transcript.
nonisolated struct WordCut: Sendable, Equatable {
    var clipID: UUID
    /// Clip seconds.
    var start: Double
    var end: Double
    /// The kept and deleted words run together (almost no pause between
    /// them), so the cut can't fall in a pause.
    var isTight: Bool
    /// The deleted words, as shown in the transcript.
    var text: String = ""
    /// Where each cut point may move when it's refined on the samples
    /// (`CutRefiner`), and where it should be if everything there is equally
    /// quiet: the middle of the pause. Clip seconds.
    var startSearch: ClosedRange<Double>? = nil
    var startPreferred: Double? = nil
    var endSearch: ClosedRange<Double>? = nil
    var endPreferred: Double? = nil
}

/// Turns deleted words into cuts that sound clean.
///
/// A cut doesn't sit on the aligner's word edges: those are good to a few
/// tens of milliseconds, and in connected speech there's often no exact
/// boundary anyway. Each cut point is moved to the 10 ms window with the
/// lowest *peak* in the pause between the last kept word and the first deleted
/// one (and the last deleted and the next kept). The peak, not the average:
/// a window can average quiet and still hold a click, a breath or the burst of
/// a "t", and cutting through any of those is audible.
///
/// That's the first pass, from the levels already measured, so the edit
/// updates at once. `CutRefiner` then reads the samples around each point and
/// moves it to the exact sample: a zero crossing in the quietest few
/// milliseconds.
nonisolated enum WordCutPlanner {
    /// How far past the pause the search may look, for word edges that are a bit off.
    static let searchMargin = 0.04
    /// With no word before (or after) the deletion, how far out the pause is assumed to reach.
    static let edgeReach = 0.25
    /// Pauses shorter than this make a tight cut.
    static let tightGap = 0.03
    /// Windows whose peak is within this of the lowest count as just as quiet;
    /// the one nearest the middle of the pause wins.
    static let quietTolerance: Float = 1

    /// Cuts for one clip. `words` are the clip's words in order; runs of
    /// consecutive deleted words become one cut each.
    static func cuts(clipID: UUID, words: [TimelineWord], deleted: Set<String>, levels: AudioLevels, clipDuration: Double) -> [WordCut] {
        var cuts: [WordCut] = []
        var index = 0
        while index < words.count {
            guard deleted.contains(words[index].id) else {
                index += 1
                continue
            }
            var last = index
            while last + 1 < words.count, deleted.contains(words[last + 1].id) { last += 1 }
            if let cut = cut(clipID: clipID, words: words, run: index...last, levels: levels, clipDuration: clipDuration) {
                cuts.append(cut)
            }
            index = last + 1
        }
        return cuts
    }

    static func cut(clipID: UUID, words: [TimelineWord], run: ClosedRange<Int>, levels: AudioLevels, clipDuration: Double) -> WordCut? {
        let first = words[run.lowerBound]
        let last = words[run.upperBound]
        let before = run.lowerBound > 0 ? words[run.lowerBound - 1] : nil
        let after = run.upperBound + 1 < words.count ? words[run.upperBound + 1] : nil

        // Pause before the deleted words.
        let previousEnd = before?.clipEnd ?? max(0, first.clipStart - edgeReach)
        let leading = pause(from: previousEnd, to: first.clipStart)
        let startSearch = bounded(max(before?.clipStart ?? 0, leading.lowerBound - searchMargin), min(first.clipEnd, leading.upperBound + searchMargin))
        let startPreferred = (leading.lowerBound + leading.upperBound) / 2
        let start = quietest(in: startSearch, preferring: startPreferred, levels: levels)

        // Pause after them.
        let nextStart = after?.clipStart ?? min(clipDuration, last.clipEnd + edgeReach)
        let trailing = pause(from: last.clipEnd, to: nextStart)
        let endSearch = bounded(max(last.clipStart, trailing.lowerBound - searchMargin), min(after?.clipEnd ?? clipDuration, trailing.upperBound + searchMargin))
        let endPreferred = (trailing.lowerBound + trailing.upperBound) / 2
        let end = quietest(in: endSearch, preferring: endPreferred, levels: levels)

        guard end > start else { return nil }
        let isTight = (before.map { first.clipStart - $0.clipEnd < tightGap } ?? false)
            || (after.map { $0.clipStart - last.clipEnd < tightGap } ?? false)
        let text = words[run].map(\.text).joined(separator: " ")
        return WordCut(
            clipID: clipID, start: start, end: end, isTight: isTight, text: text,
            startSearch: startSearch, startPreferred: startPreferred, endSearch: endSearch, endPreferred: endPreferred
        )
    }

    /// The quietest point in `range` (seconds): the middle of the analyzed
    /// window with the lowest peak, or `preferred` when nothing there is
    /// analyzed yet.
    static func quietest(in range: ClosedRange<Double>, preferring preferred: Double, levels: AudioLevels) -> Double {
        let fallback = min(max(preferred, range.lowerBound), range.upperBound)
        let seconds = levels.windowSeconds
        guard levels.windowCount > 0, seconds > 0 else { return fallback }
        let firstWindow = max(0, Int((range.lowerBound / seconds).rounded(.down)))
        let lastWindow = min(levels.windowCount - 1, Int((range.upperBound / seconds).rounded(.up)) - 1)
        guard firstWindow <= lastWindow else { return fallback }

        let windows = firstWindow...lastWindow
        let peaks = levels.peakDB
        guard peaks.count == levels.windowCount,
              let minimum = windows.map({ peaks[$0] }).filter(\.isFinite).min() else { return fallback }
        let center = { (window: Int) in (Double(window) + 0.5) * seconds }
        let best = windows
            .filter { peaks[$0].isFinite && peaks[$0] <= minimum + quietTolerance }
            .min { abs(center($0) - preferred) < abs(center($1) - preferred) } ?? firstWindow
        return min(max(center(best), range.lowerBound), range.upperBound)
    }

    /// Sorted, non-overlapping ranges covering everything in `a` and `b`.
    static func union(_ a: [CMTimeRange], _ b: [CMTimeRange]) -> [CMTimeRange] {
        let sorted = (a + b).filter { $0.duration > .zero }.sorted { $0.start < $1.start }
        var result: [CMTimeRange] = []
        for range in sorted {
            if let last = result.last, range.start <= last.end {
                result[result.count - 1] = CMTimeRange(start: last.start, end: CMTimeMaximum(last.end, range.end))
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// `lower...upper`, collapsed to `lower` if odd word times put them the wrong way round.
    private static func bounded(_ lower: Double, _ upper: Double) -> ClosedRange<Double> {
        lower...max(lower, upper)
    }

    /// Words run together when the next starts before the previous ends; the pause is then that overlap.
    private static func pause(from end: Double, to start: Double) -> ClosedRange<Double> {
        min(end, start)...max(end, start)
    }
}
