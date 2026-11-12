//
//  TranscriptReview.swift
//  HT Edit
//
//  Asks the model a question about the transcript ("find repetition", "pick
//  the worst parts"…) through Antigravity, and highlights the words it points
//  at. Highlights only mark words: nothing is cut until the user deletes them.
//

import Foundation
import Observation
import os

/// A ready-made question for the transcript review.
nonisolated enum ReviewPreset: String, CaseIterable, Identifiable, Sendable {
    case repetition
    case bestParts
    case worstParts
    case grammar
    case fillers
    case offTopic

    var id: Self { self }

    var title: String {
        switch self {
        case .repetition: "Find repetition"
        case .bestParts: "Pick best parts"
        case .worstParts: "Pick worst parts"
        case .grammar: "Grammar check"
        case .fillers: "Filler words"
        case .offTopic: "Off-topic"
        }
    }

    /// What to send for `prompt`: a preset's full instruction when the prompt
    /// is its title, otherwise the prompt as typed.
    static func instruction(for prompt: String) -> String {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return allCases.first { $0.title.caseInsensitiveCompare(prompt) == .orderedSame }?.instruction ?? prompt
    }

    /// What's sent to the model.
    var instruction: String {
        switch self {
        case .repetition:
            "Find repetition: sentences or phrases said more than once (retakes, false starts, restarts). Point at every take except the best one, and say which take it repeats."
        case .bestParts:
            "Pick the best parts: the strongest, clearest and most engaging passages worth keeping in a short cut."
        case .worstParts:
            "Pick the worst parts: weak, rambling, unclear or boring passages that should be cut."
        case .grammar:
            "Grammar check: point at words or phrases with grammar, wording or pronunciation mistakes, and give the correction in the reason."
        case .fillers:
            "Find filler words and verbal tics (um, uh, like, you know, so, basically, and their equivalents in the spoken language)."
        case .offTopic:
            "Find passages that are off-topic or tangents that don't serve the main point of the video."
        }
    }
}

/// The transcript review: what was asked, and which words it highlighted.
@Observable
final class TranscriptReview {

    /// A highlighted passage.
    nonisolated struct Highlight: Equatable, Sendable {
        /// `TimelineWord.id`s, in order.
        var wordIDs: [String]
        var text: String
        var reason: String
    }

    /// The question being typed.
    var prompt = ""
    private(set) var isRunning = false
    private(set) var errorMessage: String?
    /// Highlighted passages, in transcript order.
    private(set) var highlights: [Highlight] = []
    /// Why each highlighted word is highlighted (`TimelineWord.id` → reason).
    private(set) var reasons: [String: String] = [:]
    /// The question the highlights answer.
    private(set) var answeredInstruction: String?

    private let engine: any TranscriptReviewEngine
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Bumped by every run, so a cancelled run's late answer is ignored.
    @ObservationIgnored private var generation = 0

    init(engine: any TranscriptReviewEngine) {
        self.engine = engine
    }

    /// The review the app uses: the installed Antigravity CLI, or a fake for UI tests.
    static func live() -> TranscriptReview {
        #if DEBUG
        if let engine = UITestSupport.fakeReviewEngine() {
            return TranscriptReview(engine: engine)
        }
        #endif
        return TranscriptReview(engine: AgyEngine())
    }

    // MARK: Actions

    /// Asks `instruction` about the words of `segments` that aren't `deleted`,
    /// and highlights what the answer points at. Replaces any run going on.
    func run(_ instruction: String, segments: [TimelineSegment], deleted: Set<String>, model: String) {
        let instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        task?.cancel()
        generation += 1
        let run = generation
        let words = segments.flatMap(\.words)
        let document = Self.document(segments: segments, deleted: deleted)
        errorMessage = nil
        guard !document.isEmpty else {
            isRunning = false
            errorMessage = "There's no transcript to review yet."
            return
        }
        isRunning = true
        let engine = engine
        task = Task {
            do {
                let findings = try await engine.review(transcript: document, instruction: instruction, model: model)
                guard run == generation, !Task.isCancelled else { return }
                apply(Self.highlights(findings, words: words, deleted: deleted), answering: instruction)
                Log.transcription.notice("Review: \(findings.count) passage(s)")
            } catch {
                guard run == generation, !(error is CancellationError), !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                Log.transcription.error("Review failed: \(error.localizedDescription, privacy: .public)")
            }
            if run == generation { isRunning = false }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        generation += 1
        isRunning = false
    }

    /// Removes every highlight (and stops a run going on).
    func clear() {
        cancel()
        errorMessage = nil
        answeredInstruction = nil
        if !highlights.isEmpty { highlights = [] }
        if !reasons.isEmpty { reasons = [:] }
    }

    /// Drops the highlights on words that are gone (their clip was removed).
    func forgetWords(where isGone: (String) -> Bool) {
        guard reasons.keys.contains(where: isGone) else { return }
        highlights = highlights.compactMap { highlight in
            var highlight = highlight
            highlight.wordIDs.removeAll(where: isGone)
            return highlight.wordIDs.isEmpty ? nil : highlight
        }
        reasons = reasons.filter { !isGone($0.key) }
    }

    private func apply(_ highlights: [Highlight], answering instruction: String) {
        self.highlights = highlights
        var reasons: [String: String] = [:]
        for highlight in highlights {
            for id in highlight.wordIDs {
                reasons[id] = reasons[id].map { "\($0) · \(highlight.reason)" } ?? highlight.reason
            }
        }
        self.reasons = reasons
        answeredInstruction = instruction
    }

    // MARK: Pure helpers

    /// The transcript as the model reads it: one line per segment, with its
    /// time, and every kept word written `#N:word`, N being its index among
    /// all the words. Deleted words are left out but keep their numbers, so
    /// an answer's numbers point straight back at the words.
    nonisolated static func document(segments: [TimelineSegment], deleted: Set<String>) -> String {
        var lines: [String] = []
        var index = 0
        for segment in segments {
            var words: [String] = []
            for word in segment.words {
                defer { index += 1 }
                guard !deleted.contains(word.id) else { continue }
                let text = word.text.replacing("\n", with: " ")
                words.append("#\(index):\(text)")
            }
            guard !words.isEmpty else { continue }
            lines.append("[\(TimeFormatting.string(segment.start, fractionDigits: 0))] " + words.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }

    /// The highlighted passages for `findings`: numbers outside the transcript
    /// are clamped or dropped, and deleted words are skipped.
    nonisolated static func highlights(_ findings: [ReviewFinding], words: [TimelineWord], deleted: Set<String>) -> [Highlight] {
        guard !words.isEmpty else { return [] }
        let upper = words.count - 1
        var result: [Highlight] = []
        for finding in findings {
            let low = min(finding.first, finding.last)
            let high = max(finding.first, finding.last)
            guard high >= 0, low <= upper else { continue }
            let passage = words[max(0, low)...min(upper, high)].filter { !deleted.contains($0.id) }
            guard !passage.isEmpty else { continue }
            let reason = finding.reason.isEmpty ? "Highlighted" : finding.reason
            result.append(Highlight(wordIDs: passage.map(\.id), text: passage.map(\.text).joined(separator: " "), reason: reason))
        }
        let order = Dictionary(words.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        return result.sorted { (order[$0.wordIDs[0]] ?? 0) < (order[$1.wordIDs[0]] ?? 0) }
    }
}
