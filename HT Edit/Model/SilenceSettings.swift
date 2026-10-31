//
//  SilenceSettings.swift
//  HT Edit
//

import Foundation

/// User-tunable parameters for silence detection.
///
/// Padding is *kept* audio: `paddingStart` is trimmed off the beginning of each
/// silence (so the tail of the previous word survives) and `paddingEnd` is
/// trimmed off the end of each silence (so the breath before the next word survives).
nonisolated struct SilenceSettings: Equatable, Hashable, Sendable {
    /// Windows whose RMS level is below this value (dBFS) are considered silent.
    var thresholdDB: Double = -40
    /// Seconds of audio kept after speech ends, before the silence region starts.
    var paddingStart: Double = 0.10
    /// Seconds of audio kept before speech resumes, after the silence region ends.
    var paddingEnd: Double = 0.10
    /// Silent stretches shorter than this (before padding) are ignored.
    var minimumSilenceDuration: Double = 0.30

    static let thresholdRange: ClosedRange<Double> = -80...0
    static let paddingRange: ClosedRange<Double> = 0...1
    static let minimumSilenceDurationRange: ClosedRange<Double> = 0.05...3

    static let `default` = SilenceSettings()
}
