//
//  EditorViewModel.swift
//  HT Edit
//

import AVFoundation
import Observation

/// Owns the loaded media, its audio analysis, and the detected silences.
///
/// Audio is decoded once per import (off the main actor, streamed in chunks).
/// Every settings change after that only re-runs the pure `SilenceDetector`
/// over cached levels, which is why the highlights update instantly.
@Observable
final class EditorViewModel {

    // MARK: Media

    private(set) var player: AVPlayer?
    private(set) var fileName: String?
    private(set) var duration: CMTime = .zero
    private(set) var currentTime: CMTime = .zero

    // MARK: Analysis

    private(set) var levels = AudioLevels.empty
    private(set) var silences: [CMTimeRange] = []
    private(set) var isAnalyzing = false
    var errorMessage: String?

    var settings = SilenceSettings.default {
        didSet {
            if settings != oldValue { recomputeSilences() }
        }
    }

    /// When on, playback jumps over every highlighted silence.
    var skipSilences = false {
        didSet {
            if skipSilences != oldValue { installBoundaryObserver() }
        }
    }

    // MARK: Derived

    var hasMedia: Bool { player != nil }

    var isPlaying: Bool {
        guard let player else { return false }
        return player.timeControlStatus != .paused
    }

    var totalSilenceDuration: CMTime { SilenceDetector.totalDuration(of: silences) }

    /// Media length once the highlighted silences are removed.
    var durationWithoutSilences: CMTime {
        let total = timelineDuration
        let silence = totalSilenceDuration
        return silence < total ? total - silence : .zero
    }

    /// The best known duration: the asset's, or the analyzed audio's if longer / unknown.
    var timelineDuration: CMTime {
        let audio = levels.duration
        guard duration.isNumeric, duration > .zero else { return audio }
        return CMTimeMaximum(duration, audio)
    }

    // MARK: Private state

    private let analyzer: AudioLevelAnalyzer
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private var periodicObserver: Any?
    @ObservationIgnored private var boundaryObserver: Any?
    @ObservationIgnored private var observedPlayer: AVPlayer?
    @ObservationIgnored private var securityScopedURL: URL?
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var isSkipping = false

    /// Seconds before a silence at which the boundary observer already counts as "inside",
    /// so callbacks that fire a hair early still trigger the skip.
    private static let skipLookahead = CMTime(value: 1, timescale: 100)

    init(analyzer: AudioLevelAnalyzer = AudioLevelAnalyzer()) {
        self.analyzer = analyzer
    }

    /// Creates a model with pre-computed levels (used by tests and previews).
    init(levels: AudioLevels, settings: SilenceSettings = .default) {
        self.analyzer = AudioLevelAnalyzer()
        self.levels = levels
        self.settings = settings
        self.duration = levels.duration
        recomputeSilences()
    }

    // MARK: Loading

    func load(url: URL) {
        analysisTask?.cancel()
        removeObservers()
        player?.pause()
        stopAccessingSecurityScope()
        if url.startAccessingSecurityScopedResource() {
            securityScopedURL = url
        }

        loadGeneration += 1
        let generation = loadGeneration

        fileName = url.lastPathComponent
        errorMessage = nil
        levels = .empty
        silences = []
        currentTime = .zero
        duration = .zero

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        self.player = player
        installPeriodicObserver(on: player)

        isAnalyzing = true
        let analyzer = analyzer
        analysisTask = Task {
            do {
                let assetDuration = try await item.asset.load(.duration)
                guard generation == loadGeneration else { return }
                duration = assetDuration

                for try await chunk in analyzer.levels(for: url) {
                    guard generation == loadGeneration else { return }
                    levels.append(chunk)
                    recomputeSilences()
                }
                guard generation == loadGeneration, !Task.isCancelled else { return }
                levels.isComplete = true
                recomputeSilences()
            } catch is CancellationError {
                return
            } catch {
                guard generation == loadGeneration else { return }
                errorMessage = error.localizedDescription
            }
            if generation == loadGeneration {
                isAnalyzing = false
            }
        }
    }

    // MARK: Transport

    func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            if timelineDuration > .zero, player.currentTime() >= timelineDuration {
                seek(to: .zero)
            }
            player.play()
        }
    }

    func seek(to time: CMTime) {
        guard let player else { return }
        let upper = timelineDuration
        var target = CMTimeMaximum(.zero, time)
        if upper > .zero { target = CMTimeMinimum(target, upper) }
        currentTime = target
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seek(toSeconds seconds: Double) {
        seek(to: CMTime(seconds: seconds, preferredTimescale: levels.sampleRate))
    }

    func resetSettings() {
        settings = .default
    }

    // MARK: Silence detection

    private func recomputeSilences() {
        silences = SilenceDetector.detect(levels: levels, settings: settings)
        installBoundaryObserver()
    }

    // MARK: Playback observation

    private func installPeriodicObserver(on player: AVPlayer) {
        observedPlayer = player
        periodicObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time
                self.skipIfInsideSilence()
            }
        }
    }

    /// Boundary observers fire exactly when playback crosses each silence start,
    /// so skips are precise without polling. The periodic observer is a fallback
    /// for playback that starts inside a silence.
    private func installBoundaryObserver() {
        if let token = boundaryObserver {
            observedPlayer?.removeTimeObserver(token)
            boundaryObserver = nil
        }
        guard skipSilences, let player, !silences.isEmpty else { return }
        let times = silences.map { NSValue(time: $0.start) }
        boundaryObserver = player.addBoundaryTimeObserver(forTimes: times, queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                self?.skipIfInsideSilence()
            }
        }
    }

    private func skipIfInsideSilence() {
        guard skipSilences, !isSkipping, let player, player.rate != 0 else { return }
        let probe = player.currentTime() + Self.skipLookahead
        guard let target = PlaybackSkipper.skipTarget(for: probe, in: silences) else { return }
        isSkipping = true
        Task {
            _ = await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            isSkipping = false
        }
    }

    private func removeObservers() {
        if let token = periodicObserver { observedPlayer?.removeTimeObserver(token) }
        if let token = boundaryObserver { observedPlayer?.removeTimeObserver(token) }
        periodicObserver = nil
        boundaryObserver = nil
        observedPlayer = nil
    }

    private func stopAccessingSecurityScope() {
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
    }
}
