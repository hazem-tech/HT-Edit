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
/// 3. Once placed, the clip is transcribed automatically. When its transcript
///    and word timing are complete, everything that isn't speech is cut too.
///
/// Settings changes only re-run the pure silence detector over the stored
/// levels, so highlights update instantly. Playback skips silences, the words
/// deleted in the transcript, and what isn't speech (`removedRanges`).
@Observable
final class EditorViewModel {

    // MARK: State

    let player: AVPlayer
    /// Transcripts of the clips on the timeline.
    let transcription: TranscriptionController
    private(set) var clips: [Clip] = []
    private(set) var currentTime: CMTime = .zero
    private(set) var silences: [CMTimeRange] = []
    /// Words deleted in the transcript (`TimelineWord.id`).
    private(set) var deletedWordIDs: Set<String> = []
    /// Where the deleted words are cut, per clip in clip time.
    private(set) var wordCuts: [WordCut] = []
    /// Cut words on the timeline.
    private(set) var cutRanges: [CMTimeRange] = []
    /// Stretches without speech on the timeline (clips with a complete transcript only).
    private(set) var nonSpeechRanges: [CMTimeRange] = []
    /// Everything left out of the edit, with why: sorted, non-overlapping, and
    /// split wherever the reason changes (what the timeline shows and hovers).
    private(set) var removedRanges: [RemovedRange] = []
    /// What playback skips: `removedRanges` joined into whole stretches.
    private(set) var skipRanges: [CMTimeRange] = []
    /// Transcript lines at their timeline positions.
    private(set) var timelineTranscript: [TimelineSegment] = []
    /// Every word of `timelineTranscript`, in order.
    private(set) var timelineWords: [TimelineWord] = []
    /// Words selected in the transcript (`TimelineWord.id`).
    private(set) var selectedWordIDs: Set<String> = []
    /// Whether the timeline pages along with the playhead. Scrolling the
    /// timeline during playback turns it off until playback starts again.
    private(set) var followsPlayhead = true
    /// The removed stretch being previewed, if any: playback doesn't skip it.
    private(set) var previewRange: CMTimeRange?
    /// Markers, in the order they were added.
    private(set) var markers: [Marker] = []
    /// Marker positions on the timeline, in seconds, sorted.
    private(set) var markerTimes: [Double] = []
    private(set) var playbackStatus: PlaybackStatus = .idle
    /// Bumped whenever stored levels change, so views depending on them refresh.
    private(set) var levelsRevision = 0
    var errorMessage: String?
    /// The clip list has keyboard focus: Delete removes clips there, not words.
    @ObservationIgnored var isClipListFocused = false

    var settings = SilenceSettings.default {
        didSet {
            if settings != oldValue { recomputeSilences() }
        }
    }

    /// Cut what isn't speech once a clip's transcript is complete.
    var cutsNonSpeech = true {
        didSet {
            if cutsNonSpeech != oldValue { recomputeSkips() }
        }
    }

    // MARK: Derived

    var hasMedia: Bool { !clips.isEmpty }

    var isAnalyzing: Bool { clips.contains { $0.isAnalyzing } }

    var isPlaying: Bool { player.timeControlStatus != .paused }

    /// Clips on the timeline, in order (clips whose duration is still loading aren't placed yet).
    var placedClips: [Clip] { clips.filter(\.isPlaced) }

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
    @ObservationIgnored private var previewObserver: Any?
    /// The preview has reached its start and is playing towards its end.
    @ObservationIgnored private var isPreviewPlaying = false
    /// Index in `timelineWords` of the last plain or Command click, for Shift-click.
    @ObservationIgnored private var selectionAnchor: Int?
    @ObservationIgnored private var securityScopedURLs: [URL] = []
    @ObservationIgnored private var isSkipping = false
    @ObservationIgnored private var lastLevelsPublish = ContinuousClock.now
    @ObservationIgnored private var pendingLevelsPublish: Task<Void, Never>?

    /// Boundary callbacks can fire a hair before the silence start; probing slightly
    /// ahead makes sure they still trigger the skip.
    private static let skipLookahead = CMTime(value: 1, timescale: 100)
    private static let levelsPublishInterval: Duration = .milliseconds(50)
    private static let playerReadyTimeout: Duration = .seconds(15)

    init(analyzer: AudioLevelAnalyzer = AudioLevelAnalyzer(), transcription: TranscriptionController = .live()) {
        self.analyzer = analyzer
        self.transcription = transcription
        self.player = AVPlayer()
        configurePlayer()
        connectTranscription()
    }

    /// Creates a model with pre-analyzed clips (used by tests and previews).
    init(
        analyzedClips: [(clip: Clip, levels: AudioLevels)],
        settings: SilenceSettings = .default,
        transcription: TranscriptionController = TranscriptionController(engine: AgyEngine(), cache: nil, defaults: nil)
    ) {
        self.analyzer = AudioLevelAnalyzer(cache: nil)
        self.transcription = transcription
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
        connectTranscription()
        layoutDidChange()
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
        endPreview()
        clips = ClipTimeline.moving(clips, fromOffsets: offsets, toOffset: destination)
        layoutDidChange()
        rebuildPlayerItem()
    }

    /// Removes clips from the timeline (sidebar right-click ▸ Delete, or the Delete key).
    func removeClips(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        endPreview()
        for clip in clips where ids.contains(clip.id) {
            clipTasks.removeValue(forKey: clip.id)?.cancel()
            levelsStore.remove(clip.id)
            if let index = securityScopedURLs.firstIndex(of: clip.url) {
                securityScopedURLs.remove(at: index).stopAccessingSecurityScopedResource()
            }
        }
        clips.removeAll { ids.contains($0.id) }
        markers.removeAll { ids.contains($0.clipID) }
        let removedPrefixes = ids.map(\.uuidString)
        deletedWordIDs = deletedWordIDs.filter { id in !removedPrefixes.contains { id.hasPrefix($0) } }
        selectedWordIDs = selectedWordIDs.filter { id in !removedPrefixes.contains { id.hasPrefix($0) } }
        selectionAnchor = nil
        transcription.remove(ids)
        levelsRevision += 1
        layoutDidChange()

        if clips.isEmpty {
            transcription.cancel()
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
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                let hasAudio = !audioTracks.isEmpty
                try Task.checkCancellation()
                updateClip(clipID) {
                    $0.duration = duration
                    $0.presentationSize = size
                    $0.hasAudio = hasAudio
                }
                Log.importing.notice("\(name, privacy: .public): \(duration.seconds) s, \(Int(size.width))×\(Int(size.height))")

                // 2. Playback, thumbnail and transcript are prepared in their own
                //    tasks; the waveform never waits for them.
                layoutDidChange()
                rebuildPlayerItem()
                loadThumbnail(clipID: clipID, asset: asset)
                if let clip = clips.first(where: { $0.id == clipID }) {
                    transcription.enqueue([clip])
                }

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

    // MARK: Transcript editing

    /// Transcribes every clip on the timeline again (a different model was
    /// picked). Deleted words are restored: the new transcript has new words.
    func transcribeAll() {
        deletedWordIDs = []
        selectedWordIDs = []
        selectionAnchor = nil
        transcription.transcribe(placedClips)
        recomputeSkips()
    }

    /// Transcribes what's missing after a failed or cancelled run.
    func retryTranscription() {
        transcription.retry(placedClips)
    }

    /// Selects the word at `index` in `timelineWords`. A plain click selects
    /// just that word and jumps there; `extending` (Shift) selects everything
    /// from the last click; `toggling` (Command) adds or removes one word.
    func selectWord(at index: Int, extending: Bool = false, toggling: Bool = false) {
        let words = timelineWords
        guard words.indices.contains(index) else { return }
        let id = words[index].id
        if extending, let anchor = selectionAnchor, words.indices.contains(anchor) {
            selectedWordIDs = Set(words[min(anchor, index)...max(anchor, index)].map(\.id))
        } else if toggling {
            if selectedWordIDs.contains(id) { selectedWordIDs.remove(id) } else { selectedWordIDs.insert(id) }
            selectionAnchor = index
        } else {
            selectedWordIDs = [id]
            selectionAnchor = index
            seek(toSeconds: words[index].start)
        }
    }

    /// Cuts the selected words, or restores them if they're all cut already (⌫).
    func toggleSelectedWords() {
        toggleDeletion(of: selectedWordIDs)
    }

    /// Deletes `ids` from the edit (playback skips them), or restores them if
    /// they're all deleted already.
    func toggleDeletion(of ids: Set<String>) {
        guard !ids.isEmpty else { return }
        if ids.isSubset(of: deletedWordIDs) {
            deletedWordIDs.subtract(ids)
        } else {
            deletedWordIDs.formUnion(ids)
        }
        recomputeSkips()
    }

    func restoreAllWords() {
        deletedWordIDs = []
        recomputeSkips()
    }

    // MARK: Transport

    func togglePlayback() {
        guard hasMedia else { return }
        endPreview()
        if isPlaying {
            player.pause()
        } else {
            if timelineDuration > .zero, player.currentTime() >= timelineDuration {
                seek(to: .zero)
            }
            if !followsPlayhead { followsPlayhead = true }
            player.play()
        }
    }

    /// The user scrolled the timeline: stop paging it along with the playhead
    /// until playback starts again.
    func userScrolledTimeline() {
        if isPlaying, followsPlayhead { followsPlayhead = false }
    }

    /// Plays `range` (a removed stretch) without skipping it, then pauses at its end.
    func preview(_ range: CMTimeRange) {
        guard hasMedia, range.isValid, range.duration > .zero else { return }
        endPreview()
        player.pause()
        previewRange = range
        if !followsPlayhead { followsPlayhead = true }
        currentTime = range.start
        Task {
            _ = await player.seek(to: range.start, toleranceBefore: .zero, toleranceAfter: .zero)
            playPreview(range)
        }
    }

    /// The preview reached its start: play it, and pause at its end.
    private func playPreview(_ range: CMTimeRange) {
        guard previewRange == range else { return }
        isPreviewPlaying = true
        previewObserver = player.addBoundaryTimeObserver(forTimes: [NSValue(time: range.end)], queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                self?.finishPreview()
            }
        }
        player.play()
    }

    /// Adds a marker at the playhead (the M key). It belongs to the clip there.
    func addMarker() {
        let placed = placedClips
        guard !placed.isEmpty else { return }
        let now = player.currentItem == nil ? currentTime : player.currentTime()
        let time = CMTimeMaximum(.zero, now.isNumeric ? now : currentTime)
        let durations = placed.map(\.duration)
        let index = ClipTimeline.clipIndex(at: time, durations: durations) ?? placed.count - 1
        let clip = placed[index]
        let clipStart = ClipTimeline.starts(for: durations)[index]
        let clipTime = min(max(0, (time - clipStart).seconds), clip.duration.seconds)
        guard clipTime.isFinite else { return }
        let frame = 1.0 / 60
        guard !markers.contains(where: { $0.clipID == clip.id && abs($0.clipTime - clipTime) < frame }) else { return }
        markers.append(Marker(clipID: clip.id, clipTime: clipTime))
        recomputeMarkerTimes()
    }

    func seek(to time: CMTime) {
        guard hasMedia else { return }
        endPreview()
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
                // Always seek: it makes the player decode and display the frame
                // at the playhead right away instead of a black layer.
                _ = await player.seek(to: time.isNumeric ? time : .zero, toleranceBefore: .zero, toleranceAfter: .zero)
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
        recomputeSkips()
    }

    /// Clips were placed, moved or removed: everything positioned on the timeline follows.
    private func layoutDidChange() {
        rebuildTranscript()
        recomputeMarkerTimes()
        recomputeSilences()
    }

    /// Hooks the transcription up: new transcript text refreshes the cuts, and
    /// a different model transcribes everything again.
    private func connectTranscription() {
        transcription.onTranscriptsChange = { [weak self] in
            self?.transcriptDidChange()
        }
        transcription.onModelChange = { [weak self] in
            guard let self, self.hasMedia else { return }
            self.transcribeAll()
        }
    }

    private func transcriptDidChange() {
        rebuildTranscript()
        recomputeSkips()
    }

    private func rebuildTranscript() {
        let segments = transcription.timelineSegments(for: placedClips)
        timelineTranscript = segments
        timelineWords = segments.flatMap(\.words)
        if !selectedWordIDs.isEmpty {
            let current = Set(timelineWords.map(\.id))
            if !selectedWordIDs.isSubset(of: current) { selectedWordIDs.formIntersection(current) }
        }
    }

    private func recomputeMarkerTimes() {
        let placed = placedClips
        let starts = Dictionary(uniqueKeysWithValues: zip(placed.map(\.id), ClipTimeline.starts(for: placed.map(\.duration))))
        markerTimes = markers.compactMap { marker in
            starts[marker.clipID].map { $0.seconds + marker.clipTime }
        }.sorted()
    }

    /// Re-plans the word cuts (they snap to the quietest point of each pause,
    /// so they follow the levels), the stretches without speech, and what
    /// playback skips.
    private func recomputeSkips() {
        let placed = placedClips
        let starts = Dictionary(uniqueKeysWithValues: zip(placed.map(\.id), ClipTimeline.starts(for: placed.map(\.duration))))
        let wordsByClip = Dictionary(grouping: timelineWords, by: \.clipID)
        func onTimeline(_ clipID: UUID, _ start: Double, _ end: Double) -> CMTimeRange? {
            guard let clipStart = starts[clipID], start.isFinite, end.isFinite, end > start else { return nil }
            return CMTimeRange(
                start: clipStart + CMTime(seconds: start, preferredTimescale: 48_000),
                end: clipStart + CMTime(seconds: end, preferredTimescale: 48_000)
            )
        }

        var tagged: [(range: CMTimeRange, reason: RemovalReason)] = silences.map { (range: $0, reason: .silence) }

        if deletedWordIDs.isEmpty {
            wordCuts = []
        } else {
            wordCuts = placed.flatMap { clip in
                WordCutPlanner.cuts(
                    clipID: clip.id,
                    words: wordsByClip[clip.id] ?? [],
                    deleted: deletedWordIDs,
                    levels: levelsStore[clip.id],
                    clipDuration: clip.duration.seconds
                )
            }
        }
        var cuts: [CMTimeRange] = []
        for cut in wordCuts {
            guard let range = onTimeline(cut.clipID, cut.start, cut.end) else { continue }
            cuts.append(range)
            tagged.append((range: range, reason: .cutWords(cut.text)))
        }
        cutRanges = cuts

        var noSpeech: [CMTimeRange] = []
        if cutsNonSpeech {
            let complete = transcription.completedClipIDs
            for clip in placed where complete.contains(clip.id) {
                for gap in NonSpeechPlanner.ranges(words: wordsByClip[clip.id] ?? [], clipDuration: clip.duration.seconds) {
                    if let range = onTimeline(clip.id, gap.lowerBound, gap.upperBound) { noSpeech.append(range) }
                }
            }
        }
        nonSpeechRanges = noSpeech
        tagged += noSpeech.map { (range: $0, reason: .noSpeech) }

        removedRanges = RemovalPlanner.parts(tagged)
        // Playback seeks once across a whole stretch, whatever its parts.
        skipRanges = ClipTimeline.merged(removedRanges.map(\.range))
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
                if self.isPreviewPlaying, let preview = self.previewRange, time >= preview.end {
                    self.finishPreview()
                }
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
        guard !skipRanges.isEmpty else { return }
        let times = skipRanges.map { NSValue(time: $0.start) }
        boundaryObserver = player.addBoundaryTimeObserver(forTimes: times, queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                self?.skipIfInsideSilence()
            }
        }
    }

    private func skipIfInsideSilence() {
        guard !isSkipping, player.rate != 0 else { return }
        let probe = player.currentTime() + Self.skipLookahead
        if let preview = previewRange, probe >= preview.start, probe < preview.end + Self.skipLookahead { return }
        guard let target = PlaybackSkipper.skipTarget(for: probe, in: skipRanges) else { return }
        isSkipping = true
        Task {
            _ = await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            isSkipping = false
        }
    }

    /// The preview reached its end: pause there.
    private func finishPreview() {
        guard previewRange != nil, isPreviewPlaying else { return }
        player.pause()
        endPreview()
    }

    private func endPreview() {
        if let token = previewObserver {
            player.removeTimeObserver(token)
            previewObserver = nil
        }
        isPreviewPlaying = false
        if previewRange != nil { previewRange = nil }
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
