//
//  TranscriptionController.swift
//  HT Edit
//

import CoreMedia
import Foundation
import Observation

/// Owns transcripts and the transcription run for the clips on the timeline.
///
/// Each clip goes through the same fixed steps; the user only gives an optional context:
/// 1. **Main pass:** Whisper on this Mac, in Arabic, without any context. Each clip's speech
///    is cut into windows of about 25 seconds at pauses, and lines appear as windows finish.
///    Without a context, Whisper writes every word and every repeated take, in the speaker's
///    dialect. This is the transcript the user gets; the later steps only correct its words.
/// 2. **Topic:** when the user gave no context, Gemini reads that transcript and writes a
///    short one (topic, names, terms) in the speaker's own dialect.
/// 3. **Context pass:** Whisper again, primed with that context. It gets names and terms
///    right, but tends to skip repeated takes and make speech formal, so it's only used as
///    a second reading of each line, never shown.
/// 4. **Cleanup:** Gemini proofreads the main pass with the second reading beside every line.
///    It sees text only and can't change timing; a line it would shorten or pad keeps
///    Whisper's version, so repeats and false starts stay.
///
/// Without Antigravity, there's a single Whisper pass (with the user's context, if any).
@Observable
final class TranscriptionController {

    enum Phase: Equatable {
        case idle
        case running
        case findingTopic
        case cleaning
        case finished
        case failed(String)
    }

    /// The spoken language. Fixed: HT Edit is tuned for Arabic (English words inside it are kept).
    nonisolated static let language = "ar"

    // MARK: State

    /// Whisper's state: `.ready` once it's set up, `.needsSetup` before.
    private(set) var engineStatus: EngineStatus = .unknown
    /// Antigravity's state, for the topic and cleanup steps.
    private(set) var cleanupStatus: EngineStatus = .unknown
    private(set) var phase: Phase = .idle
    private(set) var isSettingUp = false
    private(set) var setupError: String?
    /// Clip-relative segments per clip, sorted by start.
    private(set) var transcripts: [UUID: [TranscriptSegment]] = [:]
    /// Chunks per clip in the current Whisper pass, and those that failed in any pass.
    private(set) var plannedChunks: [UUID: [Range<Double>]] = [:]
    private(set) var finishedChunks: [UUID: Set<Double>] = [:]
    private(set) var failedChunks: [UUID: [Range<Double>]] = [:]
    private(set) var lastFailureMessage: String?
    /// Why the topic or cleanup step didn't happen or didn't finish; Whisper's text is kept.
    private(set) var cleanupNote: String?
    /// The context Gemini worked out when the user left the field empty.
    private(set) var detectedContext: String?
    /// Whisper passes done in this run, out of `passCount`.
    private(set) var passesDone = 0
    private(set) var passCount = 1

    /// Topic, names, terms or spellings, written the way the speaker talks. Empty by
    /// default; when empty, Gemini works one out from the rough transcript.
    var context = ""

    /// The user's cleanup model, remembered across launches. `nil` means the cheapest available.
    var preferredModelID: String? {
        didSet { defaults?.set(preferredModelID, forKey: Self.modelDefaultsKey) }
    }

    // MARK: Derived

    /// Cleanup models to offer: the catalog narrowed to what Antigravity reports, cheapest first.
    var availableModels: [TranscriptionModel] {
        if case .ready(let models) = cleanupStatus, !models.isEmpty { return models }
        return TranscriptionModel.catalog
    }

    /// The cleanup model a run will use: the user's pick if it's available, otherwise the cheapest.
    var selectedModel: TranscriptionModel {
        let models = availableModels
        return models.first { $0.id == preferredModelID } ?? models.first ?? TranscriptionModel.catalog[0]
    }

    var isRunning: Bool { phase == .running || phase == .findingTopic || phase == .cleaning }

    /// Fraction of the current run done: finished Whisper passes plus the current pass's windows.
    var progress: Double {
        let total = plannedChunks.values.reduce(0) { $0 + $1.count }
        let done = finishedChunks.values.reduce(0) { $0 + $1.count } + failedInPass
        let current = phase == .running && total > 0 ? Double(done) / Double(total) : 0
        return min(1, (Double(passesDone) + current) / Double(max(1, passCount)))
    }

    /// What the run is doing, for the caption under the progress bar.
    var stepDescription: String? {
        switch phase {
        case .running:
            passCount > 1 ? "Whisper pass \(min(passesDone + 1, passCount)) of \(passCount)…" : "Transcribing with Whisper…"
        case .findingTopic: "Working out the topic with Gemini…"
        case .cleaning: "Cleaning up with Gemini…"
        default: nil
        }
    }

    var hasFailedChunks: Bool { failedChunks.values.contains { !$0.isEmpty } }

    /// Segments on the timeline for `clips` (placed clips, in timeline order).
    func timelineSegments(for clips: [Clip]) -> [TimelineSegment] {
        TranscriptTimeline.segments(transcripts: transcripts, clips: clips.map { ($0.id, $0.duration.seconds) })
    }

    // MARK: Private

    private let engine: any TranscriptionEngine
    private let cleaner: (any TranscriptCleaner)?
    private let installation: WhisperInstallation?
    private let cache: TranscriptCache?
    private let transcriber: Transcriber
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    /// Chunks that failed in the current pass (for progress).
    private var failedInPass = 0
    private static let modelDefaultsKey = "transcriptionModel"

    /// - Parameters:
    ///   - cleaner: works out the topic and proofreads Whisper's text; `nil` gives one plain Whisper pass.
    ///   - installation: where `Set Up Whisper` installs; `nil` hides setup (tests).
    ///   - defaults: where choices are remembered; `nil` doesn't remember them (tests).
    init(
        engine: any TranscriptionEngine,
        cleaner: (any TranscriptCleaner)? = nil,
        installation: WhisperInstallation? = nil,
        cache: TranscriptCache? = .shared,
        defaults: UserDefaults? = .standard,
        chunkLength: Double = 180
    ) {
        self.engine = engine
        self.cleaner = cleaner
        self.installation = installation
        self.cache = cache
        self.transcriber = Transcriber(engine: engine, cache: cache, chunkLength: chunkLength)
        self.defaults = defaults
        self.preferredModelID = defaults?.string(forKey: Self.modelDefaultsKey)
    }

    /// The controller the app uses: local Whisper plus Antigravity, or a fake for UI tests.
    static func live() -> TranscriptionController {
        #if DEBUG
        if let engine = UITestSupport.fakeTranscriptionEngine() {
            return TranscriptionController(engine: engine, cache: nil, defaults: nil)
        }
        #endif
        return TranscriptionController(engine: WhisperEngine(), cleaner: AgyCleaner(), installation: .standard)
    }

    var canSetUp: Bool { installation != nil }
    var hasCleaner: Bool { cleaner != nil }

    // MARK: Actions

    /// Checks whether Whisper is set up, and whether Antigravity can help (and with which models).
    func refreshStatus() async {
        guard engineStatus != .checking else { return }
        engineStatus = .checking
        engineStatus = await engine.checkStatus()
        await refreshCleanupStatus()
    }

    func refreshCleanupStatus() async {
        guard let cleaner, cleanupStatus != .checking else { return }
        cleanupStatus = .checking
        cleanupStatus = await cleaner.checkStatus()
    }

    /// Installs Whisper (Python environment and model) where the app looks for it.
    func setUpWhisper() async {
        guard let installation, !isSettingUp else { return }
        isSettingUp = true
        setupError = nil
        defer { isSettingUp = false }
        do {
            try await installation.setUp()
        } catch {
            setupError = error.localizedDescription
        }
        engineStatus = await engine.checkStatus()
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
        if isRunning { phase = .idle }
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
        failedInPass = 0
        lastFailureMessage = nil
        cleanupNote = nil
        detectedContext = nil
        guard !jobs.isEmpty else { return }
        phase = .running
        passesDone = 0
        passCount = jobs.count * (cleaner == nil ? 1 : 2)
        let userContext = context.trimmingCharacters(in: .whitespacesAndNewlines)

        runTask = Task {
            if case .ready = engineStatus {} else { await refreshStatus() }
            switch engineStatus {
            case .needsSetup:
                phase = .failed(WhisperError.notSetUp.localizedDescription)
                return
            case .failed(let reason):
                phase = .failed(reason)
                return
            default:
                break
            }
            do {
                for job in jobs {
                    if cleaner == nil {
                        _ = try await whisperPass(job, options: TranscriptionOptions(language: Self.language, context: userContext))
                    } else {
                        try await process(job, userContext: userContext)
                    }
                    try Task.checkCancellation()
                }
                phase = .finished
            } catch is CancellationError {
                return
            } catch let error as any FatalTranscriptionError where error.isFatal {
                if error as? WhisperError == .notSetUp { engineStatus = .needsSetup }
                phase = .failed(error.localizedDescription)
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Rough pass, topic, context pass and cleanup for one clip.
    private func process(_ job: TranscriptionJob, userContext: String) async throws {
        let rough = try await whisperPass(job, options: TranscriptionOptions(language: Self.language))
        try Task.checkCancellation()

        var context = userContext
        if context.isEmpty, !rough.isEmpty {
            phase = .findingTopic
            context = await findTopic(job, rough: rough)
            if !context.isEmpty { detectedContext = context }
        }
        guard !context.isEmpty else {
            passesDone += 1   // no context to prime a second pass with: keep the rough pass
            return
        }

        let primed = try await whisperPass(job, options: TranscriptionOptions(language: Self.language, context: context), shown: false)
        try Task.checkCancellation()
        guard transcripts[job.clipID] != nil else { return }   // removed meanwhile
        transcripts[job.clipID] = TranscriptTimeline.attachingAlternatives(from: primed, to: rough)

        guard failedChunks[job.clipID]?.isEmpty ?? true else { return }
        try await cleanUp(job, context: context)
    }

    /// Runs Whisper over the job's chunks and returns the clip's lines. With `shown`, lines
    /// replace the clip's transcript as they arrive; otherwise they're only returned.
    private func whisperPass(_ job: TranscriptionJob, options: TranscriptionOptions, shown: Bool = true) async throws -> [TranscriptSegment] {
        phase = .running
        plannedChunks[job.clipID] = nil
        finishedChunks[job.clipID] = nil
        failedInPass = 0
        var lines = shown ? (transcripts[job.clipID] ?? []) : []
        for try await event in transcriber.run([job], options: options) {
            if case .cached(_, let segments) = event { lines = segments }
            if case .chunkFinished(let clipID, let chunk, let segments) = event, clipID == job.clipID, plannedChunks[clipID] != nil {
                lines = TranscriptTimeline.merging(segments, into: lines, chunk: chunk)
            }
            apply(event, clipID: job.clipID, shown: shown)
        }
        passesDone += 1
        plannedChunks[job.clipID] = nil
        finishedChunks[job.clipID] = nil
        failedInPass = 0
        return lines
    }

    /// Asks Gemini for a short context from the rough transcript. Failures leave it empty.
    private func findTopic(_ job: TranscriptionJob, rough: [TranscriptSegment]) async -> String {
        guard let cleaner else { return "" }
        if case .ready = cleanupStatus {} else { await refreshCleanupStatus() }
        guard case .ready = cleanupStatus else {
            cleanupNote = "Not cleaned up: " + Self.describe(cleanupStatus)
            return ""
        }
        let model = selectedModel.id
        let key = TranscriptCache.topicKey(for: job.url, rough: rough, model: model)
        if let cache, let key, let cached = await cache.load(key: key), let topic = cached.first?.text {
            return topic
        }
        do {
            let topic = try await cleaner.topic(of: rough.map(\.text), model: model)
            if let cache, let key, !topic.isEmpty {
                await cache.store([TranscriptSegment(start: 0, end: 0, text: topic)], key: key)
            }
            return topic
        } catch is CancellationError {
            return ""
        } catch {
            cleanupNote = "Couldn't work out the topic: \(error.localizedDescription)"
            return ""
        }
    }

    /// Proofreads the clip's lines with Gemini. Failures keep Whisper's text.
    private func cleanUp(_ job: TranscriptionJob, context: String) async throws {
        guard let cleaner, let raw = transcripts[job.clipID], !raw.isEmpty else { return }
        phase = .cleaning
        if case .ready = cleanupStatus {} else { await refreshCleanupStatus() }
        guard case .ready = cleanupStatus else {
            cleanupNote = "Not cleaned up: " + Self.describe(cleanupStatus)
            return
        }
        let model = selectedModel.id
        // Edited instructions give a different cleanup, so they're part of the key.
        let key = TranscriptCache.cleanupKey(for: job.url, raw: raw, model: model, context: context, instructions: CleanupInstructions.current(defaults))
        if let cache, let key, let cached = await cache.load(key: key), cached.count == raw.count {
            transcripts[job.clipID] = cached
            return
        }
        do {
            let corrected = try await cleaner.clean(raw.map { CleanupLine($0.text, alternative: $0.alternative) }, model: model, context: context)
            // The clip may have been removed or re-run meanwhile.
            guard transcripts[job.clipID] == raw else { return }
            let cleaned = Self.applying(corrected, to: raw)
            transcripts[job.clipID] = cleaned
            if let cache, let key { await cache.store(cleaned, key: key) }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            cleanupNote = "Not cleaned up: \(error.localizedDescription)"
            if let error = error as? AgyError, error.isFatal {
                cleanupStatus = error == .notSignedIn ? .notSignedIn : .notInstalled
            }
        }
    }

    /// `raw` with each corrected line's text swapped in; times never change.
    nonisolated static func applying(_ corrected: [String?], to raw: [TranscriptSegment]) -> [TranscriptSegment] {
        raw.enumerated().map { index, segment in
            guard index < corrected.count, let text = corrected[index] else { return segment }
            var segment = segment
            segment.text = text
            return segment
        }
    }

    private static func describe(_ status: EngineStatus) -> String {
        switch status {
        case .notInstalled: AgyError.notInstalled.localizedDescription
        case .notSignedIn: AgyError.notSignedIn.localizedDescription
        case .failed(let reason): reason
        default: "Antigravity isn't available."
        }
    }

    private func apply(_ event: TranscriptionEvent, clipID wanted: UUID, shown: Bool) {
        switch event {
        case .cached(let clipID, let segments):
            if shown { transcripts[clipID] = segments }
        case .planned(let clipID, let chunks):
            plannedChunks[clipID] = chunks
        case .chunkFinished(let clipID, let chunk, let segments):
            // A clip removed mid-run is no longer planned: drop its late results.
            guard clipID == wanted, plannedChunks[clipID] != nil else { return }
            if shown { transcripts[clipID] = TranscriptTimeline.merging(segments, into: transcripts[clipID] ?? [], chunk: chunk) }
            finishedChunks[clipID, default: []].insert(chunk.lowerBound)
        case .chunkFailed(let clipID, let chunk, let message):
            guard clipID == wanted, plannedChunks[clipID] != nil else { return }
            if !(failedChunks[clipID]?.contains(chunk) ?? false) {
                failedChunks[clipID, default: []].append(chunk)
            }
            failedInPass += 1
            lastFailureMessage = message
        }
    }
}
