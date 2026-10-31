//
//  PlaybackSkipper.swift
//  HT Edit
//

import CoreMedia

/// Decides where playback should jump to when it enters a silence.
nonisolated enum PlaybackSkipper {

    /// If `time` lies inside one of the sorted, non-overlapping `silences`
    /// (`start <= time < end`), returns that silence's end. Otherwise `nil`.
    ///
    /// O(log n) binary search, safe to call from a 30 Hz time observer.
    static func skipTarget(for time: CMTime, in silences: [CMTimeRange]) -> CMTime? {
        guard time.isNumeric else { return nil }
        var low = 0
        var high = silences.count
        // First silence whose end is after `time`.
        while low < high {
            let mid = (low + high) / 2
            if silences[mid].end <= time {
                low = mid + 1
            } else {
                high = mid
            }
        }
        guard low < silences.count else { return nil }
        let candidate = silences[low]
        return candidate.start <= time ? candidate.end : nil
    }
}
