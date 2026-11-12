//
//  TranscriptionController.swift
//  HT Edit
//

import CoreMedia
import Foundation
import Observation

/// Owns transcripts and the transcription run for the clips on the timeline.
///
/// The editor hands it the placed clips; it checks the engine, offers only
/// models that can transcribe with timestamps (cheapest selected by default),
/// and fills in each clip's transcript chunk by chunk.
@Observable
final class TranscriptionController {

    enum Phase: Equatable {
        case idle
        case running
        case finished
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
    /// Chunks per clip in the current run, and those that failed.
    private(set) var plannedChunks: [UUID: [Range<Double>]] = [:]
    private(set) var finishedChunks: [UUID: Set<Double>] = [:]
    private(set) var failedChunks: [UUID: [Range<Double>]] = [:]
    private(set) var lastFailureMessage: String?

    /// Words, names or background that help the model; empty by default.
    var context = ""

    /// The user's pick, remembered across launches. `nil` means the cheapest available model.
    var preferredModelID: String? {
        didSet { defaults?.set(preferredModelID, forKey: Self.modelDefaultsKey) }
    }

    // MARK: Derived

    /// Models to offer: the catalog narrowed to what the engine reports, cheapest first.
    var availableModels: [TranscriptionModel] {
        if case .ready(let models) = engineStatus { return models }
        return TranscriptionModel.catalog
    }

    /// The model a run will use: the user's pick if it's available, otherwise the cheapest.
    var selectedModel: TranscriptionModel {
        let models = availableModels
        return models.first { $0.id == preferredModelID } ?? models.first ?? TranscriptionModel.catalog[0]
    }

    var isRunning: Bool { phase == .running }

    /// Fraction of the current run's chunks that are done (finished or failed).
    var progress: Double {
        let total = plannedChunks.values.reduce(0) { $0 + $1.count }
        guard total > 0 else { return 0 }
        let done = finishedChunks.values.reduce(0) { $0 + $1.count } + failedChunks.values.reduce(0) { $0 + $1.count }
        return Double(done) / Double(total)
    }

    var hasFailedChunks: Bool { failedChunks.values.contains { !$0.isEmpty } }

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

    /// Transcribes `clips` from scratch (replacing earlier transcripts of them).
    func transcribe(_ clips: [Clip]) {
        let jobs = clips.filter(\.isPlaced).map {
            TranscriptionJob(clipID: $0.id, url: $0.url, duration: $0.duration.seconds, chunks: nil)
        }
        for job in jobs { transcripts[job.clipID] = nil }
        start(jobs)
    }

    /// Runs only the chunks that failed last time.
    func retryFailedChunks(_ clips: [Clip]) {
        let jobs = clips.compactMap { clip -> TranscriptionJob? in
            guard let chunks = failedChunks[clip.id], !chunks.isEmpty else { return nil }
            return TranscriptionJob(clipID: clip.id, url: clip.url, duration: clip.duration.seconds, chunks: chunks)
        }
        start(jobs)
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
        if phase == .running { phase = .idle }
    }

    /// Forgets removed clips. Their chunks still in flight are ignored when they come back.
    func remove(_ ids: Set<UUID>) {
        for id in ids {
            transcripts[id] = nil
            plannedChunks[id] = nil
            finishedChunks[id] = nil
            failedChunks[id] = nil
        }
    }

    // MARK: Running

    private func start(_ jobs: [TranscriptionJob]) {
        runTask?.cancel()
        plannedChunks = [:]
        finishedChunks = [:]
        failedChunks = [:]
        lastFailureMessage = nil
        wordTimingFailure = nil
        guard !jobs.isEmpty else { return }
        phase = .running
        let wanted = Set(jobs.map(\.clipID))

        runTask = Task {
            if case .ready = engineStatus {} else { await refreshStatus() }
            switch engineStatus {
            case .notInstalled:
                phase = .failed(AgyError.notInstalled.localizedDescription)
                return
            case .notSignedIn:
                phase = .failed(AgyError.notSignedIn.localizedDescription)
                return
            default:
                break
            }
            do {
                for try await event in transcriber.run(jobs, model: selectedModel.id, context: context) {
                    apply(event, wanted: wanted)
                }
                guard !Task.isCancelled else { return }
                phase = .finished
            } catch is CancellationError {
                return
            } catch let error as AgyError where error.isFatal {
                engineStatus = error == .notSignedIn ? .notSignedIn : .notInstalled
                phase = .failed(error.localizedDescription)
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func apply(_ event: TranscriptionEvent, wanted: Set<UUID>) {
        switch event {
        case .cached(let clipID, let segments):
            transcripts[clipID] = segments
        case .planned(let clipID, let chunks):
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
            guard wanted.contains(clipID) else { return }
            transcripts[clipID] = segments
        case .wordTimingFailed(let clipID, _, let message):
            guard wanted.contains(clipID) else { return }
            wordTimingFailure = message
        }
    }
}
