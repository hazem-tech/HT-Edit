//
//  TranscriptionController.swift
//  HT Edit
//

import CoreMedia
import Foundation
import Observation

/// Owns transcripts and the transcription run for the clips on the timeline.
///
/// A run has two steps:
/// 1. **Whisper**, on this Mac: each clip's speech is cut into windows of about
///    25 seconds at pauses and transcribed with word-accurate timestamps.
///    Lines appear as each window finishes.
/// 2. **Cleanup**, optional: Gemini through Antigravity proofreads the text
///    (misheard words, product names) while keeping the speaker's dialect.
///    It sees text only and can't change timing; lines it would shorten or
///    drop keep Whisper's version.
@Observable
final class TranscriptionController {

    enum Phase: Equatable {
        case idle
        case running
        case cleaning
        case finished
        case failed(String)
    }

    /// Spoken languages offered for Whisper. `nil` detects the language per window.
    static let languages: [(code: String?, name: String)] = [
        (nil, "Detect automatically"),
        ("ar", "Arabic"),
        ("en", "English"),
        ("fr", "French"),
        ("de", "German"),
        ("es", "Spanish"),
        ("tr", "Turkish"),
    ]

    // MARK: State

    /// Whisper's state: `.ready` once it's set up, `.needsSetup` before.
    private(set) var engineStatus: EngineStatus = .unknown
    /// Antigravity's state, for the cleanup step.
    private(set) var cleanupStatus: EngineStatus = .unknown
    private(set) var phase: Phase = .idle
    private(set) var isSettingUp = false
    private(set) var setupError: String?
    /// Clip-relative segments per clip, sorted by start.
    private(set) var transcripts: [UUID: [TranscriptSegment]] = [:]
    /// Chunks per clip in the current run, and those that failed.
    private(set) var plannedChunks: [UUID: [Range<Double>]] = [:]
    private(set) var finishedChunks: [UUID: Set<Double>] = [:]
    private(set) var failedChunks: [UUID: [Range<Double>]] = [:]
    private(set) var lastFailureMessage: String?
    /// Why the last cleanup didn't happen or didn't finish; the Whisper text is kept.
    private(set) var cleanupNote: String?

    /// Words, names or background; empty by default. Whisper is primed with it,
    /// and the cleanup uses it to get names and terms right.
    var context = ""

    /// The spoken language, remembered across launches; `nil` detects it.
    var language: String? {
        didSet { defaults?.set(language, forKey: Self.languageDefaultsKey) }
    }

    /// Whether Whisper reads each window twice (with and without the context) so the
    /// cleanup can recover dialect words; about twice as slow. Remembered across launches.
    var secondPass: Bool {
        didSet { defaults?.set(secondPass, forKey: Self.secondPassDefaultsKey) }
    }

    /// Whether Gemini proofreads Whisper's text, remembered across launches.
    var cleanupEnabled: Bool {
        didSet { defaults?.set(cleanupEnabled, forKey: Self.cleanupDefaultsKey) }
    }

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

    var isRunning: Bool { phase == .running || phase == .cleaning }

    /// Fraction of the current run's chunks that are done (finished or failed).
    var progress: Double {
        let total = plannedChunks.values.reduce(0) { $0 + $1.count }
        guard total > 0 else { return phase == .cleaning ? 1 : 0 }
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
    private let cleaner: (any TranscriptCleaner)?
    private let installation: WhisperInstallation?
    private let cache: TranscriptCache?
    private let transcriber: Transcriber
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    private static let modelDefaultsKey = "transcriptionModel"
    private static let languageDefaultsKey = "transcriptionLanguage"
    private static let cleanupDefaultsKey = "transcriptionCleanup"
    private static let secondPassDefaultsKey = "transcriptionSecondPass"

    /// - Parameters:
    ///   - cleaner: proofreads Whisper's text; `nil` skips that step.
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
        self.language = defaults?.string(forKey: Self.languageDefaultsKey)
        self.cleanupEnabled = defaults?.object(forKey: Self.cleanupDefaultsKey) as? Bool ?? true
        self.secondPass = defaults?.object(forKey: Self.secondPassDefaultsKey) as? Bool ?? true
    }

    /// The controller the app uses: local Whisper plus Antigravity cleanup, or a fake for UI tests.
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

    /// Checks whether Whisper is set up, and whether Antigravity can clean up (and with which models).
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
        lastFailureMessage = nil
        cleanupNote = nil
        guard !jobs.isEmpty else { return }
        phase = .running
        let wanted = Set(jobs.map(\.clipID))
        // The second pass only helps the cleanup, and only differs from the first when there's a context.
        let options = TranscriptionOptions(language: language, context: context, secondPass: secondPass && cleanupEnabled && cleaner != nil)

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
                for try await event in transcriber.run(jobs, options: options) {
                    apply(event, wanted: wanted)
                }
                guard !Task.isCancelled else { return }
                try await cleanUp(jobs.filter { failedChunks[$0.clipID]?.isEmpty ?? true }, context: options.context)
                guard !Task.isCancelled else { return }
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

    /// Proofreads each finished clip's Whisper text with Gemini. Failures keep Whisper's text.
    private func cleanUp(_ jobs: [TranscriptionJob], context: String) async throws {
        guard cleanupEnabled, let cleaner else { return }
        let jobs = jobs.filter { !(transcripts[$0.clipID] ?? []).isEmpty }
        guard !jobs.isEmpty else { return }
        phase = .cleaning
        if case .ready = cleanupStatus {} else { await refreshCleanupStatus() }
        guard case .ready = cleanupStatus else {
            cleanupNote = "Not cleaned up: " + Self.describe(cleanupStatus)
            return
        }
        let model = selectedModel.id
        for job in jobs {
            try Task.checkCancellation()
            guard let raw = transcripts[job.clipID] else { continue }
            // Edited instructions give a different cleanup, so they're part of the key.
            let key = TranscriptCache.cleanupKey(for: job.url, raw: raw, model: model, context: context, instructions: CleanupInstructions.current(defaults))
            if let cache, let key, let cached = await cache.load(key: key), cached.count == raw.count {
                transcripts[job.clipID] = cached
                continue
            }
            do {
                let corrected = try await cleaner.clean(raw.map { CleanupLine($0.text, alternative: $0.alternative) }, model: model, context: context)
                // The clip may have been removed or re-run meanwhile.
                guard transcripts[job.clipID] == raw else { continue }
                let cleaned = Self.applying(corrected, to: raw)
                transcripts[job.clipID] = cleaned
                if let cache, let key { await cache.store(cleaned, key: key) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                cleanupNote = "Not cleaned up: \(error.localizedDescription)"
                if let error = error as? AgyError, error.isFatal {
                    cleanupStatus = error == .notSignedIn ? .notSignedIn : .notInstalled
                    return
                }
            }
        }
    }

    /// `raw` with each corrected line's text swapped in; times never change.
    nonisolated static func applying(_ corrected: [String?], to raw: [TranscriptSegment]) -> [TranscriptSegment] {
        raw.enumerated().map { index, segment in
            guard index < corrected.count, let text = corrected[index] else { return segment }
            return TranscriptSegment(start: segment.start, end: segment.end, text: text, alternative: segment.alternative)
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
        }
    }
}
