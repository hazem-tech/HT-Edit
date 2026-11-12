//
//  TranscriptionController.swift
//  HT Edit
//

import CoreMedia
import Foundation
import Observation

/// Owns transcripts and the transcription runs for the clips on the timeline.
///
/// The editor hands it each clip as soon as it's placed; it checks the engine,
/// uses the selected model (cheapest available by default), and fills in each
/// clip's transcript chunk by chunk. Clips handed over while a run is going
/// wait their turn: nothing already running is cancelled.
@Observable
final class TranscriptionController {

    enum Phase: Equatable {
        case idle
        case running
        case finished
        case cancelled
        case failed(String)
    }

    // MARK: State

    private(set) var engineStatus: EngineStatus = .unknown
    /// Whether word times are measured on the audio or estimated.
    private(set) var wordTimingStatus: WordTimingStatus = .unknown
    /// Why word timing failed for part of the last run, if it did.
    private(set) var wordTimingFailure: String?
    private(set) var phase: Phase = .idle
    /// Clip-relative segments per clip, sorted by start.
    private(set) var transcripts: [UUID: [TranscriptSegment]] = [:]
    /// Chunks per clip in its latest run, and those that failed.
    private(set) var plannedChunks: [UUID: [Range<Double>]] = [:]
    private(set) var finishedChunks: [UUID: Set<Double>] = [:]
    private(set) var failedChunks: [UUID: [Range<Double>]] = [:]
    private(set) var lastFailureMessage: String?
    /// Clips whose transcript is complete: every chunk transcribed and its
    /// word timing done. Only these can tell speech from everything else.
    private(set) var completedClipIDs: Set<UUID> = []

    /// The user's pick, remembered across launches. `nil` means the cheapest available model.
    var preferredModelID: String? {
        didSet {
            defaults?.set(preferredModelID, forKey: Self.modelDefaultsKey)
            if model(preferring: oldValue) != selectedModel { onModelChange?() }
        }
    }

    /// Called whenever `transcripts` or `completedClipIDs` change.
    @ObservationIgnored var onTranscriptsChange: (() -> Void)?
    /// Called when the user picks a different model.
    @ObservationIgnored var onModelChange: (() -> Void)?

    // MARK: Derived

    /// Models to offer: the catalog narrowed to what the engine reports, cheapest first.
    var availableModels: [TranscriptionModel] {
        if case .ready(let models) = engineStatus { return models }
        return TranscriptionModel.catalog
    }

    /// The model a run will use: the user's pick if it's available, otherwise the cheapest.
    var selectedModel: TranscriptionModel { model(preferring: preferredModelID) }

    var isRunning: Bool { phase == .running }

    /// Fraction of the planned chunks that are done (finished or failed).
    var progress: Double {
        let total = plannedChunks.values.reduce(0) { $0 + $1.count }
        guard total > 0 else { return 0 }
        let done = finishedChunks.values.reduce(0) { $0 + $1.count } + failedChunks.values.reduce(0) { $0 + $1.count }
        return Double(done) / Double(total)
    }

    var hasFailedChunks: Bool { failedChunks.values.contains { !$0.isEmpty } }

    /// Whether some of `clips` still need a transcript and nothing is running for them:
    /// the run failed, was cancelled or left parts out.
    func needsRetry(for clips: [Clip]) -> Bool {
        !isRunning && clips.contains { $0.isPlaced && $0.hasAudio && !completedClipIDs.contains($0.id) }
    }

    /// Segments on the timeline for `clips` (placed clips, in timeline order).
    func timelineSegments(for clips: [Clip]) -> [TimelineSegment] {
        TranscriptTimeline.segments(transcripts: transcripts, clips: clips.map { ($0.id, $0.duration.seconds) })
    }

    // MARK: Private

    private let engine: any TranscriptionEngine
    private let aligner: (any WordAligner)?
    private let transcriber: Transcriber
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    /// Bumped by every new run, so a cancelled run's late events are ignored.
    @ObservationIgnored private var runGeneration = 0
    /// Clips in the current run, and jobs waiting for it to end.
    @ObservationIgnored private var runningClipIDs: Set<UUID> = []
    @ObservationIgnored private var queuedJobs: [TranscriptionJob] = []
    private static let modelDefaultsKey = "transcriptionModel"

    /// - Parameters:
    ///   - defaults: where the model choice is remembered; `nil` doesn't remember it (tests).
    ///   - aligner: measures word times; `nil` estimates them.
    init(
        engine: any TranscriptionEngine,
        cache: TranscriptCache? = .shared,
        defaults: UserDefaults? = .standard,
        chunkLength: Double = 180,
        aligner: (any WordAligner)? = nil
    ) {
        self.engine = engine
        self.aligner = aligner
        self.transcriber = Transcriber(engine: engine, cache: cache, chunkLength: chunkLength, aligner: aligner)
        self.defaults = defaults
        self.preferredModelID = defaults?.string(forKey: Self.modelDefaultsKey)
    }

    /// The controller the app uses: the installed Antigravity CLI, or a fake for UI tests.
    static func live() -> TranscriptionController {
        #if DEBUG
        if let engine = UITestSupport.fakeTranscriptionEngine() {
            return TranscriptionController(engine: engine, cache: nil, defaults: nil)
        }
        #endif
        return TranscriptionController(engine: AgyEngine(), aligner: UVWordAligner())
    }

    private func model(preferring id: String?) -> TranscriptionModel {
        let models = availableModels
        return models.first { $0.id == id } ?? models.first ?? TranscriptionModel.catalog[0]
    }

    // MARK: Actions

    /// Checks whether `agy` is installed and signed in, and which models it offers.
    func refreshStatus() async {
        guard engineStatus != .checking else { return }
        engineStatus = .checking
        if let aligner {
            wordTimingStatus = .checking
            async let timing = aligner.checkStatus()
            engineStatus = await engine.checkStatus()
            wordTimingStatus = await timing
        } else {
            engineStatus = await engine.checkStatus()
            wordTimingStatus = .notInstalled
        }
    }

    /// Transcribes `clips` that aren't transcribed or on their way yet. If a
    /// run is going, they start once it ends.
    func enqueue(_ clips: [Clip]) {
        let queued = Set(queuedJobs.map(\.clipID))
        let jobs = clips
            .filter { $0.isPlaced && $0.hasAudio }
            .filter { !runningClipIDs.contains($0.id) && !queued.contains($0.id) && !completedClipIDs.contains($0.id) }
            .map { TranscriptionJob(clipID: $0.id, url: $0.url, duration: $0.duration.seconds, chunks: nil) }
        guard !jobs.isEmpty else { return }
        if isRunning {
            queuedJobs += jobs
        } else {
            start(jobs)
        }
    }

    /// Transcribes `clips` from scratch, replacing earlier transcripts of them.
    /// Whatever was running or waiting is cancelled.
    func transcribe(_ clips: [Clip]) {
        stopRun()
        let jobs = clips.filter { $0.isPlaced && $0.hasAudio }.map {
            TranscriptionJob(clipID: $0.id, url: $0.url, duration: $0.duration.seconds, chunks: nil)
        }
        start(jobs)
    }

    /// Transcribes what's missing from `clips`: only the chunks that failed
    /// last time, or the whole clip if it never finished.
    func retry(_ clips: [Clip]) {
        stopRun()
        let jobs = clips.compactMap { clip -> TranscriptionJob? in
            guard clip.isPlaced, clip.hasAudio, !completedClipIDs.contains(clip.id) else { return nil }
            let failed = failedChunks[clip.id] ?? []
            let partial = !failed.isEmpty && transcripts[clip.id] != nil
            return TranscriptionJob(clipID: clip.id, url: clip.url, duration: clip.duration.seconds, chunks: partial ? failed : nil)
        }
        start(jobs)
    }

    func cancel() {
        let wasRunning = isRunning
        stopRun()
        if wasRunning { phase = .cancelled }
    }

    /// Forgets removed clips. Their chunks still in flight are ignored when they come back.
    func remove(_ ids: Set<UUID>) {
        for id in ids {
            transcripts[id] = nil
            plannedChunks[id] = nil
            finishedChunks[id] = nil
            failedChunks[id] = nil
            completedClipIDs.remove(id)
            runningClipIDs.remove(id)
        }
        queuedJobs.removeAll { ids.contains($0.clipID) }
        onTranscriptsChange?()
    }

    // MARK: Running

    private func stopRun() {
        runTask?.cancel()
        runTask = nil
        runGeneration += 1
        runningClipIDs = []
        queuedJobs = []
    }

    private func start(_ jobs: [TranscriptionJob]) {
        guard !jobs.isEmpty else { return }
        for job in jobs {
            if job.chunks == nil { transcripts[job.clipID] = nil }
            plannedChunks[job.clipID] = nil
            finishedChunks[job.clipID] = nil
            failedChunks[job.clipID] = nil
            completedClipIDs.remove(job.clipID)
        }
        lastFailureMessage = nil
        wordTimingFailure = nil
        phase = .running
        let wanted = Set(jobs.map(\.clipID))
        runningClipIDs = wanted
        runGeneration += 1
        let generation = runGeneration
        onTranscriptsChange?()

        runTask = Task {
            if case .ready = engineStatus {} else { await refreshStatus() }
            guard generation == runGeneration else { return }
            switch engineStatus {
            case .notInstalled:
                fail(AgyError.notInstalled.localizedDescription)
                return
            case .notSignedIn:
                fail(AgyError.notSignedIn.localizedDescription)
                return
            default:
                break
            }
            do {
                for try await event in transcriber.run(jobs, model: selectedModel.id, context: "") {
                    guard generation == runGeneration else { return }
                    apply(event, wanted: wanted)
                }
                guard !Task.isCancelled, generation == runGeneration else { return }
                finishRun(wanted)
            } catch is CancellationError {
                return
            } catch let error as AgyError where error.isFatal {
                guard generation == runGeneration else { return }
                engineStatus = error == .notSignedIn ? .notSignedIn : .notInstalled
                fail(error.localizedDescription)
            } catch {
                guard !Task.isCancelled, generation == runGeneration else { return }
                fail(error.localizedDescription)
            }
        }
    }

    /// Marks the run's clips complete (those that fully succeeded), then starts what's waiting.
    private func finishRun(_ clipIDs: Set<UUID>) {
        for id in clipIDs where transcripts[id] != nil && (failedChunks[id] ?? []).isEmpty {
            completedClipIDs.insert(id)
        }
        runningClipIDs = []
        runTask = nil
        let next = queuedJobs
        queuedJobs = []
        if next.isEmpty {
            phase = .finished
            onTranscriptsChange?()
        } else {
            onTranscriptsChange?()
            start(next)
        }
    }

    /// Ends the run and drops what was waiting: it would fail the same way. Retry runs it all again.
    private func fail(_ message: String) {
        runningClipIDs = []
        queuedJobs = []
        runTask = nil
        phase = .failed(message)
        onTranscriptsChange?()
    }

    private func apply(_ event: TranscriptionEvent, wanted: Set<UUID>) {
        switch event {
        case .cached(let clipID, let segments):
            guard wanted.contains(clipID), runningClipIDs.contains(clipID) else { return }
            transcripts[clipID] = segments
        case .planned(let clipID, let chunks):
            guard runningClipIDs.contains(clipID) else { return }
            plannedChunks[clipID] = chunks
        case .chunkFinished(let clipID, let chunk, let segments):
            // A clip removed mid-run is no longer planned: drop its late results.
            guard wanted.contains(clipID), plannedChunks[clipID] != nil else { return }
            transcripts[clipID] = TranscriptTimeline.merging(segments, into: transcripts[clipID] ?? [], chunk: chunk)
            finishedChunks[clipID, default: []].insert(chunk.lowerBound)
        case .chunkFailed(let clipID, let chunk, let message):
            guard wanted.contains(clipID), plannedChunks[clipID] != nil else { return }
            failedChunks[clipID, default: []].append(chunk)
            lastFailureMessage = message
        case .wordsMeasured(let clipID, let segments):
            guard wanted.contains(clipID), runningClipIDs.contains(clipID) else { return }
            transcripts[clipID] = segments
        case .wordTimingFailed(let clipID, _, let message):
            guard wanted.contains(clipID) else { return }
            wordTimingFailure = message
        }
        onTranscriptsChange?()
    }
}
