//
//  SplashView.swift
//  HT Edit
//

import SwiftUI

/// Shown while `WarmUp` primes the media pipeline at launch.
struct SplashView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(.tint)
            Text("HT Edit")
                .font(.largeTitle.bold())
            ProgressView()
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // Renders the waveform canvas once off-screen so its Metal pipeline is ready.
            WaveformCanvas(
                lanes: [ClipLane(id: UUID(), start: 0, duration: 1, levels: Self.sampleLevels)],
                silences: [],
                thresholdDB: SilenceSettings.default.thresholdDB,
                offset: 0,
                pixelsPerSecond: 200
            )
            .frame(width: 200, height: 60)
            .opacity(0.001)
            .accessibilityHidden(true)
        }
    }

    private static let sampleLevels: AudioLevels = {
        var levels = AudioLevels.empty
        let values = (0..<100).map { Float(-60 + 50 * sin(Double($0) / 8)) }
        levels.apply(AudioLevelsChunk(
            sampleRate: 1_000, framesPerWindow: 10, totalWindows: 100, totalFrames: 1_000,
            windowOffset: 0, rmsDB: values, peakDB: values
        ))
        return levels
    }()
}
