//
//  AudioLevels.swift
//  HT Edit
//

import CoreMedia

/// A batch of analyzed windows emitted by `AudioLevelAnalyzer`.
///
/// Segments of a file are decoded in parallel, so chunks can arrive in any
/// order; `windowOffset` says where each one belongs.
nonisolated struct AudioLevelsChunk: Sendable, Equatable {
    /// Sample rate of the analyzed audio, in Hz. Used as the `CMTime` timescale.
    var sampleRate: Int32
    /// Number of audio frames in every window (the last window of a file may be shorter).
    var framesPerWindow: Int
    /// Window count of the whole track, so storage can be allocated up front.
    var totalWindows: Int
    /// Audio frame count of the whole track.
    var totalFrames: Int
    /// Index of the first window in this chunk.
    var windowOffset: Int
    /// RMS level of each window, in dBFS (floored at `AudioLevels.floorDB`).
    var rmsDB: [Float]
    /// Peak level of each window, in dBFS (floored at `AudioLevels.floorDB`).
    var peakDB: [Float]
}

/// Per-window loudness of an audio track.
///
/// Storage covers the whole track from the first chunk on. Windows that have
/// not been analyzed yet hold `AudioLevels.unanalyzed` (+∞): never silent,
/// and drawn as empty.
///
/// Times are exact: window `i` starts at `i * framesPerWindow / sampleRate`.
nonisolated struct AudioLevels: Sendable, Equatable {
    static let floorDB: Float = -120
    static let unanalyzed: Float = .infinity

    var sampleRate: Int32 = 48_000
    var framesPerWindow: Int = 480
    var rmsDB: [Float] = []
    var peakDB: [Float] = []
    /// Audio frame count of the whole track.
    var frameCount: Int = 0
    /// `true` once every window has been analyzed.
    var isComplete = false

    static let empty = AudioLevels()

    var windowCount: Int { rmsDB.count }

    var windowDuration: CMTime {
        CMTime(value: CMTimeValue(framesPerWindow), timescale: sampleRate)
    }

    var windowSeconds: Double { Double(framesPerWindow) / Double(sampleRate) }

    var duration: CMTime {
        CMTime(value: CMTimeValue(frameCount), timescale: sampleRate)
    }

    /// Start time of window `index`, clamped to the track duration.
    func time(ofWindow index: Int) -> CMTime {
        let frame = min(index * framesPerWindow, frameCount)
        return CMTime(value: CMTimeValue(frame), timescale: sampleRate)
    }

    /// Writes `chunk` into place, allocating storage for the whole track on first use.
    mutating func apply(_ chunk: AudioLevelsChunk) {
        if rmsDB.count != chunk.totalWindows || sampleRate != chunk.sampleRate || framesPerWindow != chunk.framesPerWindow {
            sampleRate = chunk.sampleRate
            framesPerWindow = chunk.framesPerWindow
            frameCount = chunk.totalFrames
            rmsDB = Array(repeating: Self.unanalyzed, count: chunk.totalWindows)
            peakDB = Array(repeating: Self.unanalyzed, count: chunk.totalWindows)
        }
        let lower = max(0, chunk.windowOffset)
        let upper = min(rmsDB.count, chunk.windowOffset + chunk.rmsDB.count)
        guard lower < upper else { return }
        let source = (lower - chunk.windowOffset)..<(upper - chunk.windowOffset)
        rmsDB.replaceSubrange(lower..<upper, with: chunk.rmsDB[source])
        peakDB.replaceSubrange(lower..<upper, with: chunk.peakDB[source])
    }
}
