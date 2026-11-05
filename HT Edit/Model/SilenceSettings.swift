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
    var thresholdDB: Double = -70
    /// Seconds of audio kept after speech ends, before the silence region starts.
    var paddingStart: Double = 0
    /// Seconds of audio kept before speech resumes, after the silence region ends.
    var paddingEnd: Double = 0
    /// Silent stretches shorter than this (before padding) are ignored. Not exposed in the UI.
    var minimumSilenceDuration: Double = 0.30

    static let thresholdRange: ClosedRange<Double> = -80...0
    static let paddingRange: ClosedRange<Double> = 0...1

    static let `default` = SilenceSettings()

    // MARK: Remembering the last settings

    private static let thresholdKey = "silence.thresholdDB"
    private static let paddingStartKey = "silence.paddingStart"
    private static let paddingEndKey = "silence.paddingEnd"

    /// The settings last saved in `defaults`, clamped to the allowed ranges;
    /// `.default` for anything never saved.
    static func saved(in defaults: UserDefaults) -> SilenceSettings {
        var settings = SilenceSettings.default
        if let value = defaults.object(forKey: thresholdKey) as? Double, value.isFinite {
            settings.thresholdDB = value.clamped(to: thresholdRange)
        }
        if let value = defaults.object(forKey: paddingStartKey) as? Double, value.isFinite {
            settings.paddingStart = value.clamped(to: paddingRange)
        }
        if let value = defaults.object(forKey: paddingEndKey) as? Double, value.isFinite {
            settings.paddingEnd = value.clamped(to: paddingRange)
        }
        return settings
    }

    /// Remembers threshold and padding for the next launch.
    func save(to defaults: UserDefaults) {
        defaults.set(thresholdDB, forKey: Self.thresholdKey)
        defaults.set(paddingStart, forKey: Self.paddingStartKey)
        defaults.set(paddingEnd, forKey: Self.paddingEndKey)
    }
}

nonisolated private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
