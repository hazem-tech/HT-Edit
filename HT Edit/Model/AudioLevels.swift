//
//  AudioLevels.swift
//  HT Edit
//

import CoreMedia

/// A batch of newly analyzed windows emitted by `AudioLevelAnalyzer` while it reads a file.
nonisolated struct AudioLevelsChunk: Sendable, Equatable {
    /// Sample rate of the analyzed audio, in Hz. Used as the `CMTime` timescale.
    var sampleRate: Int32
    /// Number of audio frames in every window (the last window of a file may be shorter).
    var framesPerWindow: Int
    /// RMS level of each new window, in dBFS (floored at `AudioLevels.floorDB`).
    var rmsDB: [Float]
    /// Peak level of each new window, in dBFS (floored at `AudioLevels.floorDB`).
    var peakDB: [Float]
    /// Audio frames contained in this chunk.
    var frameCount: Int
}

/// Per-window loudness of an audio track, accumulated progressively.
///
/// Times are exact: window `i` starts at `i * framesPerWindow / sampleRate`.
nonisolated struct AudioLevels: Sendable, Equatable {
    static let floorDB: Float = -120

    var sampleRate: Int32 = 48_000
    var framesPerWindow: Int = 480
    var rmsDB: [Float] = []
    var peakDB: [Float] = []
    /// Total audio frames analyzed so far.
    var frameCount: Int = 0
    /// `true` once the analyzer reached the end of the track.
    var isComplete = false

    static let empty = AudioLevels()

    var windowCount: Int { rmsDB.count }

    var windowDuration: CMTime {
        CMTime(value: CMTimeValue(framesPerWindow), timescale: sampleRate)
    }

    var windowSeconds: Double { Double(framesPerWindow) / Double(sampleRate) }

    /// Duration of the audio analyzed so far.
    var duration: CMTime {
        CMTime(value: CMTimeValue(frameCount), timescale: sampleRate)
    }

    /// Start time of window `index`, clamped to the analyzed duration.
    func time(ofWindow index: Int) -> CMTime {
        let frame = min(index * framesPerWindow, frameCount)
        return CMTime(value: CMTimeValue(frame), timescale: sampleRate)
    }

    mutating func append(_ chunk: AudioLevelsChunk) {
        if rmsDB.isEmpty {
            sampleRate = chunk.sampleRate
            framesPerWindow = chunk.framesPerWindow
        }
        rmsDB.append(contentsOf: chunk.rmsDB)
        peakDB.append(contentsOf: chunk.peakDB)
        frameCount += chunk.frameCount
    }
}
