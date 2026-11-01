//
//  SilenceDetector.swift
//  HT Edit
//

import CoreMedia

/// Pure, allocation-light silence detection over pre-computed window levels.
///
/// Runs in a single linear pass, so re-running it on every slider tick is cheap
/// even for hour-long recordings (~360k windows at 10 ms).
nonisolated enum SilenceDetector {

    /// Ranges of consecutive window indices whose level is strictly below `thresholdDB`.
    static func silentRuns(in levelsDB: [Float], thresholdDB: Float) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var runStart: Int?
        levelsDB.withUnsafeBufferPointer { levels in
            for index in levels.indices {
                if levels[index] < thresholdDB {
                    if runStart == nil { runStart = index }
                } else if let start = runStart {
                    runs.append(start..<index)
                    runStart = nil
                }
            }
        }
        if let start = runStart {
            runs.append(start..<levelsDB.count)
        }
        return runs
    }

    /// Silence ranges for `levels`, with minimum-duration filtering and padding applied.
    ///
    /// - Padding is not applied at the very start of the media (there is no speech
    ///   before it to protect), nor at the very end once analysis is complete.
    /// - Returned ranges are sorted, non-overlapping, and use the audio sample rate
    ///   as timescale so they are sample-accurate.
    static func detect(levels: AudioLevels, settings: SilenceSettings) -> [CMTimeRange] {
        guard levels.windowCount > 0 else { return [] }

        let rate = Double(levels.sampleRate)
        let timescale = levels.sampleRate
        let framesPerWindow = levels.framesPerWindow
        let totalFrames = levels.frameCount
        let minimumFrames = frames(settings.minimumSilenceDuration, rate: rate)
        let paddingStartFrames = frames(settings.paddingStart, rate: rate)
        let paddingEndFrames = frames(settings.paddingEnd, rate: rate)

        let runs = silentRuns(in: levels.rmsDB, thresholdDB: Float(settings.thresholdDB))
        var result: [CMTimeRange] = []
        result.reserveCapacity(runs.count)

        for run in runs {
            var startFrame = run.lowerBound * framesPerWindow
            var endFrame = min(run.upperBound * framesPerWindow, totalFrames)
            guard endFrame - startFrame >= minimumFrames else { continue }

            if startFrame > 0 {
                startFrame += paddingStartFrames
            }
            let reachesEndOfMedia = levels.isComplete && endFrame >= totalFrames
            if !reachesEndOfMedia {
                endFrame -= paddingEndFrames
            }
            guard endFrame > startFrame else { continue }

            result.append(CMTimeRange(
                start: CMTime(value: CMTimeValue(startFrame), timescale: timescale),
                end: CMTime(value: CMTimeValue(endFrame), timescale: timescale)
            ))
        }
        return result
    }

    /// Sum of the durations of `ranges`.
    static func totalDuration(of ranges: [CMTimeRange]) -> CMTime {
        ranges.reduce(.zero) { $0 + $1.duration }
    }

    private static func frames(_ seconds: Double, rate: Double) -> Int {
        Int((max(0, seconds) * rate).rounded())
    }
}
