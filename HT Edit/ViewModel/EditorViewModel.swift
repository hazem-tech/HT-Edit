//
//  EditorViewModel.swift
//  HT Edit
//

import AVFoundation
import Observation

/// Owns the clips on the timeline, their audio analysis, the detected
/// silences and the player.
///
/// - The timeline and playback are ready as soon as a clip's duration has
///   loaded (milliseconds); the waveform fills in while the audio is decoded
///   in parallel in the background.
/// - Settings changes only re-run the pure silence detector over cached
///   levels, so highlights update instantly.
/// - Playback always skips silences.
@Observable
final class EditorViewModel {

    // MARK: State

    let player: AVPlayer
    private(set) var clips: [Clip] = []
    private(set) var currentTime: CMTime = .zero
    private(set) var silences: [CMTimeRange] = []
    var errorMessage: String?

    var settings = SilenceSettings.default {
        didSet {
            if settings != oldValue { recomputeSilences() }
        }
    }

    // MARK: Derived

    var hasMedia: Bool { !clips.isEmpty }

    var isAnalyzing: Bool { clips.contains { $0.isAnalyzing } }

    var isPlaying: Bool { player.timeControlStatus != .paused }

    private var placedClips: [Clip] { clips.filter(\.isPlaced) }

    var timelineDuration: CMTime {
        placedClips.reduce(.zero) { $0 + $1.duration }
    }

    /// Lay the player beside the timeline when the (first) video is taller than wide.
    var isPortrait: Bool {
        clips.first { $0.presentationSize != .zero }?.isPortrait ?? false
    }

    /// Per-clip drawing data, positioned on the timeline.
    var lanes: [ClipLane] {
        let placed = placedClips
        let starts = ClipTimeline.starts(for: placed.map(\.duration))
        return zip(placed, starts).map { clip, start in
            ClipLane(id: clip.id, start: start.seconds, duration: clip.duration.seconds, levels: clip.levels)
        }
    }

    var totalSilenceDuration: CMTime { SilenceDetector.totalDuration(of: silences) }

    // MARK: Private state

    private let analyzer: AudioLevelAnalyzer
    @ObservationIgnored private var clipTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var compositionTask: Task<Void, Never>?
    @ObservationIgnored private var periodicObserver: Any?
    @ObservationIgnored private var boundaryObserver: Any?
    @ObservationIgnored private var securityScopedURLs: [URL] = []
    @ObservationIgnored private var isSkipping = false
    @ObservationIgnored private var lastProgressRecompute = ContinuousClock.now

    /// Boundary callbacks can fire a hair before the silence start; probing slightly
    /// ahead makes sure they still trigger the skip.
    private static let skipLookahead = CMTime(value: 1, timescale: 100)
    private static let progressRecomputeInterval: Duration = .milliseconds(50)

    init(analyzer: AudioLevelAnalyzer = AudioLevelAnalyzer()) {
        self.analyzer = analyzer
        self.player = AVPlayer()
        configurePlayer()
    }

    /// Creates a model with pre-analyzed clips (used by tests and previews).
    init(clips: [Clip], settings: SilenceSettings = .default) {
        self.analyzer = AudioLevelAnalyzer(cache: nil)
        self.player = AVPlayer()
        self.clips = clips.map { clip in
            var clip = clip
            clip.isAnalyzing = false
            return clip
        }
        self.settings = settings
        configurePlayer()
        recomputeSilences()
    }

    // MARK: Clips

    /// Appends media files to the end of the timeline.
    func add(urls: [URL]) {
        for url in urls {
            if url.startAccessingSecurityScopedResource() {
                securityScopedURLs.append(url)
            }
            let clip = Clip(url: url)
            clips.append(clip)
            load(clipID: clip.id, url: url)
        }
    }

    /// Reorders clips (drag in the sidebar). Timeline, silences and playback follow.
    func moveClips(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        clips = ClipTimeline.moving(clips, fromOffsets: offsets, toOffset: destination)
        recomputeSilences()
        rebuildPlayerItem()
    }

    private func load(clipID: UUID, url: URL) {
        let analyzer = analyzer
        clipTasks[clipID] = Task {
            do {
                // 1. Metadata only: enough to place the clip and start playback.
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration)
                var size = CGSize.zero
                if let video = try await asset.loadTracks(withMediaType: .video).first {
                    let (naturalSize, transform) = try await video.load(.naturalSize, .preferredTransform)
                    size = CompositionBuilder.presentationSize(naturalSize: naturalSize, transform: transform)
                }
                updateClip(clipID) {
                    $0.duration = duration
                    $0.presentationSize = size
                }
                rebuildPlayerItem()
                loadThumbnail(clipID: clipID, asset: asset)

                // 2. Audio levels, streamed in as parallel segments finish.
                for try await chunk in analyzer.levels(for: url) {
                    updateClip(clipID) { $0.levels.apply(chunk) }
                    recomputeSilencesThrottled()
                }
                updateClip(clipID) {
                    $0.levels.isComplete = true
                    $0.isAnalyzing = false
                }
                recomputeSilences()
            } catch is CancellationError {
                return
            } catch AnalysisError.noAudioTrack {
                updateClip(clipID) { $0.isAnalyzing = false }
            } catch {
                updateClip(clipID) { $0.isAnalyzing = false }
                errorMessage = "\(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    private func loadThumbnail(clipID: UUID, asset: AVURLAsset) {
        Task {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 160, height: 160)
            if let result = try? await generator.image(at: .zero) {
                updateClip(clipID) { $0.thumbnail = result.image }
            }
        }
    }

    private func updateClip(_ id: UUID, _ update: (inout Clip) -> Void) {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        update(&clips[index])
    }

    // MARK: Transport

    func togglePlayback() {
        guard hasMedia else { return }
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
        guard hasMedia else { return }
        let upper = timelineDuration
        var target = CMTimeMaximum(.zero, time)
        if upper > .zero { target = CMTimeMinimum(target, upper) }
        currentTime = target
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seek(toSeconds seconds: Double) {
        seek(to: CMTime(seconds: seconds, preferredTimescale: 48_000))
    }

    // MARK: Composition

    /// Rebuilds the seamless composition, keeping the playhead and play state.
    private func rebuildPlayerItem() {
        compositionTask?.cancel()
        let sources = placedClips.map { CompositionBuilder.Source(url: $0.url, duration: $0.duration) }
        compositionTask = Task {
            do {
                let item = try await CompositionBuilder.makePlayerItem(for: sources)
                guard !Task.isCancelled else { return }
                let time = player.currentTime()
                let wasPlaying = isPlaying
                player.replaceCurrentItem(with: item)
                if time > .zero {
                    _ = await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                }
                if wasPlaying { player.play() }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Silence detection

    private func recomputeSilences() {
        let placed = placedClips
        silences = ClipTimeline.silences(
            levels: placed.map(\.levels),
            durations: placed.map(\.duration),
            settings: settings
        )
        lastProgressRecompute = .now
        installBoundaryObserver()
    }

    /// While audio streams in, refresh highlights at most every 50 ms.
    private func recomputeSilencesThrottled() {
        if ContinuousClock.now - lastProgressRecompute >= Self.progressRecomputeInterval {
            recomputeSilences()
        }
    }

    // MARK: Playback observation

    private func configurePlayer() {
        // Local files: start immediately instead of buffering ahead.
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .pause
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
            player.removeTimeObserver(token)
            boundaryObserver = nil
        }
        guard !silences.isEmpty else { return }
        let times = silences.map { NSValue(time: $0.start) }
        boundaryObserver = player.addBoundaryTimeObserver(forTimes: times, queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                self?.skipIfInsideSilence()
            }
        }
    }

    private func skipIfInsideSilence() {
        guard !isSkipping, player.rate != 0 else { return }
        let probe = player.currentTime() + Self.skipLookahead
        guard let target = PlaybackSkipper.skipTarget(for: probe, in: silences) else { return }
        isSkipping = true
        Task {
            _ = await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            isSkipping = false
        }
    }
}
