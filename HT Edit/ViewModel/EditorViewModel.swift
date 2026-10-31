//
//  EditorViewModel.swift
//  HT Edit
//

import AVFoundation
import os
import Observation

/// Where the player is in getting the current timeline ready.
enum PlaybackStatus: Equatable {
    case idle
    case preparing
    case ready
    case failed(String)
}

/// Owns the clips on the timeline, their audio analysis, the detected
/// silences and the player.
///
/// Import per clip:
/// 1. Metadata (duration, orientation): milliseconds. The clip is placed.
/// 2. In parallel: the seamless composition is (re)built for the player, and
///    audio levels stream in (the waveform refreshes at most 20×/s). Neither
///    waits for the other.
///
/// Settings changes only re-run the pure silence detector over the stored
/// levels, so highlights update instantly. Playback always skips silences.
@Observable
final class EditorViewModel {

    // MARK: State

    let player: AVPlayer
    private(set) var clips: [Clip] = []
    private(set) var currentTime: CMTime = .zero
    private(set) var silences: [CMTimeRange] = []
    private(set) var playbackStatus: PlaybackStatus = .idle
    /// Bumped whenever stored levels change, so views depending on them refresh.
    private(set) var levelsRevision = 0
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
        _ = levelsRevision
        let placed = placedClips
        let starts = ClipTimeline.starts(for: placed.map(\.duration))
        return zip(placed, starts).map { clip, start in
            ClipLane(id: clip.id, start: start.seconds, duration: clip.duration.seconds, levels: levelsStore[clip.id])
        }
    }

    func levels(for clipID: UUID) -> AudioLevels {
        _ = levelsRevision
        return levelsStore[clipID]
    }

    var totalSilenceDuration: CMTime { SilenceDetector.totalDuration(of: silences) }

    // MARK: Private state

    private let analyzer: AudioLevelAnalyzer
    /// Levels live outside the observed `clips` array: chunks are written in
    /// place without copying or re-rendering; `levelsRevision` publishes them.
    @ObservationIgnored private let levelsStore = LevelsStore()
    @ObservationIgnored private var clipTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var compositionTask: Task<Void, Never>?
    @ObservationIgnored private var compositionGeneration = 0
    @ObservationIgnored private var periodicObserver: Any?
    @ObservationIgnored private var boundaryObserver: Any?
    @ObservationIgnored private var securityScopedURLs: [URL] = []
    @ObservationIgnored private var isSkipping = false
    @ObservationIgnored private var lastLevelsPublish = ContinuousClock.now
    @ObservationIgnored private var pendingLevelsPublish: Task<Void, Never>?

    /// Boundary callbacks can fire a hair before the silence start; probing slightly
    /// ahead makes sure they still trigger the skip.
    private static let skipLookahead = CMTime(value: 1, timescale: 100)
    private static let levelsPublishInterval: Duration = .milliseconds(50)
    private static let playerReadyTimeout: Duration = .seconds(15)

    init(analyzer: AudioLevelAnalyzer = AudioLevelAnalyzer()) {
        self.analyzer = analyzer
        self.player = AVPlayer()
        configurePlayer()
    }

    /// Creates a model with pre-analyzed clips (used by tests and previews).
    init(analyzedClips: [(clip: Clip, levels: AudioLevels)], settings: SilenceSettings = .default) {
        self.analyzer = AudioLevelAnalyzer(cache: nil)
        self.player = AVPlayer()
        self.clips = analyzedClips.map { entry in
            var clip = entry.clip
            clip.isAnalyzing = false
            return clip
        }
        for entry in analyzedClips {
            levelsStore.set(entry.levels, for: entry.clip.id)
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
            Log.importing.notice("Import \(url.lastPathComponent, privacy: .public)")
            load(clipID: clip.id, url: url)
        }
    }

    /// Reorders clips (drag in the sidebar). Timeline, silences and playback follow.
    func moveClips(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        clips = ClipTimeline.moving(clips, fromOffsets: offsets, toOffset: destination)
        recomputeSilences()
        rebuildPlayerItem()
    }

    /// Removes clips from the timeline (sidebar right-click ▸ Delete, or the Delete key).
    func removeClips(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for clip in clips where ids.contains(clip.id) {
            clipTasks.removeValue(forKey: clip.id)?.cancel()
            levelsStore.remove(clip.id)
            if let index = securityScopedURLs.firstIndex(of: clip.url) {
                securityScopedURLs.remove(at: index).stopAccessingSecurityScopedResource()
            }
        }
        clips.removeAll { ids.contains($0.id) }
        levelsRevision += 1
        recomputeSilences()

        if clips.isEmpty {
            compositionTask?.cancel()
            compositionGeneration += 1
            player.pause()
            player.replaceCurrentItem(with: nil)
            currentTime = .zero
            playbackStatus = .idle
        } else {
            if currentTime > timelineDuration { seek(to: timelineDuration) }
            rebuildPlayerItem()
        }
    }

    private func load(clipID: UUID, url: URL) {
        let analyzer = analyzer
        let name = url.lastPathComponent
        clipTasks[clipID] = Task {
            // Whatever happens below, the clip never stays "analyzing".
            defer { updateClip(clipID) { $0.isAnalyzing = false } }
            do {
                // 1. Metadata only: enough to place the clip and start playback.
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration)
                var size = CGSize.zero
                if let video = try await asset.loadTracks(withMediaType: .video).first {
                    let (naturalSize, transform) = try await video.load(.naturalSize, .preferredTransform)
                    size = CompositionBuilder.presentationSize(naturalSize: naturalSize, transform: transform)
                }
                try Task.checkCancellation()
                updateClip(clipID) {
                    $0.duration = duration
                    $0.presentationSize = size
                }
                Log.importing.notice("\(name, privacy: .public): \(duration.seconds) s, \(Int(size.width))×\(Int(size.height))")

                // 2. Playback and thumbnail are prepared in their own tasks; the
                //    waveform never waits for them.
                rebuildPlayerItem()
                loadThumbnail(clipID: clipID, asset: asset)

                // 3. Audio levels, streamed in as segments finish.
                for try await chunk in analyzer.levels(for: url) {
                    levelsStore.apply(chunk, to: clipID)
                    publishLevelsThrottled()
                }
                levelsStore.markComplete(clipID)
                publishLevels()
            } catch is CancellationError {
                return
            } catch AnalysisError.noAudioTrack {
                Log.analysis.notice("\(name, privacy: .public): no audio track")
            } catch {
                Log.importing.error("\(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                errorMessage = "\(name): \(error.localizedDescription)"
                publishLevels()
            }
        }
    }

    private func loadThumbnail(clipID: UUID, asset: AVURLAsset) {
        Task(priority: .utility) {
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
        compositionGeneration += 1
        let generation = compositionGeneration
        let sources = placedClips.map { CompositionBuilder.Source(url: $0.url, duration: $0.duration) }
        playbackStatus = .preparing

        compositionTask = Task {
            let interval = Log.signposter.beginInterval("Prepare playback", id: Log.signposter.makeSignpostID())
            defer { Log.signposter.endInterval("Prepare playback", interval) }
            do {
                let item = try await CompositionBuilder.makePlayerItem(for: sources)
                guard generation == compositionGeneration else { return }
                let time = player.currentTime()
                let wasPlaying = isPlaying
                player.replaceCurrentItem(with: item)
                if time > .zero {
                    _ = await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                }
                if wasPlaying { player.play() }

                let status = await Self.waitForDecision(on: item, timeout: Self.playerReadyTimeout)
                guard generation == compositionGeneration else { return }
                switch status {
                case .readyToPlay:
                    playbackStatus = .ready
                    Log.playback.notice("Player ready (\(sources.count) clip(s))")
                case .failed:
                    let reason = item.error?.localizedDescription ?? "Unknown error"
                    playbackStatus = .failed(reason)
                    errorMessage = "Can't play the video: \(reason)"
                    Log.playback.error("Player item failed: \(reason, privacy: .public)")
                default:
                    playbackStatus = .failed("Timed out")
                    Log.playback.error("Player item not ready after \(Self.playerReadyTimeout.description, privacy: .public)")
                }
            } catch {
                guard generation == compositionGeneration, !(error is CancellationError) else { return }
                playbackStatus = .failed(error.localizedDescription)
                errorMessage = "Can't play the video: \(error.localizedDescription)"
                Log.playback.error("Composition failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Waits until `item` is ready or failed (or the timeout passes).
    static func waitForDecision(on item: AVPlayerItem, timeout: Duration) async -> AVPlayerItem.Status {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while item.status == .unknown, clock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return item.status
    }

    // MARK: Silence detection

    private func recomputeSilences() {
        let placed = placedClips
        silences = ClipTimeline.silences(
            levels: placed.map { levelsStore[$0.id] },
            durations: placed.map(\.duration),
            settings: settings
        )
        installBoundaryObserver()
    }

    /// Publishes stored levels to the UI and refreshes highlights.
    private func publishLevels() {
        pendingLevelsPublish?.cancel()
        pendingLevelsPublish = nil
        lastLevelsPublish = .now
        levelsRevision += 1
        recomputeSilences()
    }

    /// While audio streams in, publish at most every 50 ms, with a trailing
    /// publish so the last chunk of a burst is never left unseen.
    private func publishLevelsThrottled() {
        let elapsed = ContinuousClock.now - lastLevelsPublish
        if elapsed >= Self.levelsPublishInterval {
            publishLevels()
        } else if pendingLevelsPublish == nil {
            let wait = Self.levelsPublishInterval - elapsed
            pendingLevelsPublish = Task {
                try? await Task.sleep(for: wait)
                guard !Task.isCancelled else { return }
                pendingLevelsPublish = nil
                publishLevels()
            }
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

/// Per-clip audio levels, mutated in place as analysis chunks arrive.
final class LevelsStore {
    private var storage: [UUID: AudioLevels] = [:]

    subscript(id: UUID) -> AudioLevels {
        storage[id] ?? .empty
    }

    func apply(_ chunk: AudioLevelsChunk, to id: UUID) {
        storage[id, default: .empty].apply(chunk)
    }

    func set(_ levels: AudioLevels, for id: UUID) {
        storage[id] = levels
    }

    func markComplete(_ id: UUID) {
        storage[id]?.isComplete = true
    }

    func remove(_ id: UUID) {
        storage[id] = nil
    }
}
