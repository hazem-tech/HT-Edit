//
//  TranscriptionModel.swift
//  HT Edit
//

import Foundation
import Observation
import os

/// Transcript state for the editor: phrases on the timeline, the phrase being
/// spoken, the summary and the transcription settings.
///
/// Nothing here calls Gemini on its own. Requests are made only when the user
/// presses Transcribe or Summarize, and cached results are reused (imports
/// pick up cached transcripts without any request).
@Observable
final class TranscriptionModel {

    /// Where a clip sits on the timeline.
    struct ClipSlot: Equatable {
        var id: UUID
        var url: URL
        var name: String
        var start: Double
        var duration: Double

        var job: TranscriptionJob {
            TranscriptionJob(clipID: id, url: url, name: name, duration: duration)
        }
    }

    enum KeySource: Equatable {
        case custom, bundled, none
    }

    // MARK: State

    var settings: TranscriptionSettings {
        didSet {
            if settings != oldValue { settings.save(to: defaults) }
        }
    }

    /// All phrases on the timeline, in time order.
    private(set) var phrases: [TimelinePhrase] = []
    /// The phrase to highlight: the last one that started at the playhead.
    private(set) var activeIndex: Int?
    /// The phrase to show over the video: the one being spoken right now.
    private(set) var captionIndex: Int?
    private(set) var isTranscribing = false
    private(set) var progressText: String?
    var errorMessage: String?
    private(set) var summary: String?
    private(set) var isSummarizing = false
    private(set) var customAPIKey: String?

    var hasTranscript: Bool { !phrases.isEmpty }
    var hasClips: Bool { !slots.isEmpty }

    var captionText: String? {
        guard settings.showsCaptions, let index = captionIndex, phrases.indices.contains(index) else { return nil }
        return phrases[index].text
    }

    /// Call `loadKeyIfNeeded()` first (it reads the Keychain once).
    var keySource: KeySource {
        if customAPIKey != nil { return .custom }
        return APIKeyStore.defaultKey != nil ? .bundled : .none
    }

    /// Plain transcript text, for summaries and copying.
    var transcriptText: String { phrases.map(\.text).joined(separator: " ") }

    // MARK: Private state

    @ObservationIgnored private let service: TranscriptionService
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var slots: [ClipSlot] = []
    @ObservationIgnored private var clipPhrases: [UUID: [TranscriptPhrase]] = [:]
    @ObservationIgnored private var cacheLookups: Set<UUID> = []
    @ObservationIgnored private var playhead = 0.0
    @ObservationIgnored private var didLoadKey = false
    @ObservationIgnored private var transcribeTask: Task<Void, Never>?
    @ObservationIgnored private var summarySource = ""

    init(service: TranscriptionService = TranscriptionService(), defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
        self.settings = TranscriptionSettings.load(from: defaults)
    }

    // MARK: API key

    func loadKeyIfNeeded() {
        guard !didLoadKey else { return }
        didLoadKey = true
        customAPIKey = APIKeyStore.loadCustomKey()
    }

    /// Saves the user's own key; an empty key goes back to the default one.
    func setCustomAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        APIKeyStore.saveCustomKey(trimmed)
        didLoadKey = true
        customAPIKey = trimmed.isEmpty ? nil : trimmed
        if errorMessage == GeminiError.invalidAPIKey.errorDescription || errorMessage == GeminiError.missingAPIKey.errorDescription {
            errorMessage = nil
        }
    }

    private func makeClient() -> GeminiClient? {
        loadKeyIfNeeded()
        guard let key = customAPIKey ?? APIKeyStore.defaultKey else {
            errorMessage = GeminiError.missingAPIKey.errorDescription
            return nil
        }
        return GeminiClient(apiKey: key)
    }

    // MARK: Timeline

    /// Called when clips are placed, reordered or removed. Re-maps phrases
    /// (no requests) and picks up cached transcripts of newly added clips.
    func updateLayout(_ newSlots: [ClipSlot]) {
        guard newSlots != slots else { return }
        slots = newSlots
        let ids = Set(newSlots.map(\.id))
        clipPhrases = clipPhrases.filter { ids.contains($0.key) }
        cacheLookups.formIntersection(ids)
        rebuild()
        loadCachedTranscripts()
    }

    /// Updates the highlighted phrase and caption; cheap enough for every frame.
    func updatePlayhead(_ seconds: Double) {
        guard seconds.isFinite else { return }
        playhead = seconds
        let active = TranscriptBuilder.phraseIndex(at: seconds, in: phrases)
        if active != activeIndex { activeIndex = active }
        let caption = TranscriptBuilder.captionIndex(at: seconds, in: phrases)
        if caption != captionIndex { captionIndex = caption }
    }

    private func loadCachedTranscripts() {
        let pending = slots.filter { clipPhrases[$0.id] == nil && !cacheLookups.contains($0.id) }
        guard !pending.isEmpty else { return }
        cacheLookups.formUnion(pending.map(\.id))
        let settings = settings
        Task {
            for slot in pending {
                guard let cached = await service.cachedPhrases(for: slot.job, settings: settings),
                      clipPhrases[slot.id] == nil,
                      slots.contains(where: { $0.id == slot.id }) else { continue }
                clipPhrases[slot.id] = cached
                rebuild()
            }
        }
    }

    private func rebuild() {
        let entries = slots.map {
            TranscriptBuilder.ClipEntry(clipID: $0.id, start: $0.start, duration: $0.duration, phrases: clipPhrases[$0.id] ?? [])
        }
        let rebuilt = TranscriptBuilder.timeline(entries)
        if rebuilt != phrases { phrases = rebuilt }
        updatePlayhead(playhead)
        refreshSummaryForTranscript()
    }

    // MARK: Transcription

    /// Transcribes every clip on the timeline. Clips that were transcribed
    /// before come from the cache without a request.
    ///
    /// - Parameter silentClips: clips whose audio has no speech at all; they are skipped.
    func transcribe(silentClips: Set<UUID> = []) {
        guard !isTranscribing, !slots.isEmpty, let client = makeClient() else { return }
        let settings = settings
        let jobs = slots.map { slot in
            var job = slot.job
            job.isSilent = silentClips.contains(slot.id)
            return job
        }
        errorMessage = nil
        isTranscribing = true
        transcribeTask = Task {
            defer {
                isTranscribing = false
                progressText = nil
            }
            for (index, job) in jobs.enumerated() {
                progressText = jobs.count > 1 ? "Transcribing clip \(index + 1) of \(jobs.count)…" : "Transcribing…"
                do {
                    let result = try await service.phrases(for: job, settings: settings, client: client)
                    guard !Task.isCancelled else { return }
                    guard slots.contains(where: { $0.id == job.clipID }) else { continue }
                    clipPhrases[job.clipID] = result
                    rebuild()
                } catch {
                    if error is CancellationError || Task.isCancelled { return }
                    Log.transcription.error("\(job.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    errorMessage = jobs.count > 1 ? "\(job.name): \(error.localizedDescription)" : error.localizedDescription
                    if (error as? GeminiError)?.stopsBatch == true { return }
                }
            }
        }
    }

    func cancelTranscription() {
        transcribeTask?.cancel()
    }

    // MARK: Summary

    func summarize() {
        let text = transcriptText
        guard !text.isEmpty, !isSummarizing, let client = makeClient() else { return }
        let settings = settings
        errorMessage = nil
        isSummarizing = true
        Task {
            defer { isSummarizing = false }
            do {
                let result = try await service.summary(of: text, settings: settings, client: client)
                if text == transcriptText { summary = result }
            } catch {
                if error is CancellationError { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    /// A changed transcript invalidates the summary; a cached one for the new
    /// text is shown without a request.
    private func refreshSummaryForTranscript() {
        let text = transcriptText
        guard text != summarySource else { return }
        summarySource = text
        summary = nil
        guard !text.isEmpty else { return }
        let settings = settings
        Task {
            if let cached = await service.cachedSummary(of: text, settings: settings), text == transcriptText {
                summary = cached
            }
        }
    }
}
