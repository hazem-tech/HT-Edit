//
//  TranscriptionEngine.swift
//  HT Edit
//
//  Transcription has two steps:
//  1. Speech to text with timestamps, on this Mac (`WhisperEngine`).
//  2. Optional proofreading of that text by Gemini through Antigravity
//     (`AgyCleaner`). It only sees text, never audio, and never changes times.
//

import Foundation

/// Whether a step can run, as far as it can tell.
nonisolated enum EngineStatus: Equatable, Sendable {
    case unknown
    case checking
    /// Ready. For the cleanup step, the models the picker should offer (cheapest first).
    case ready([TranscriptionModel])
    /// Whisper isn't set up yet (no environment or model on disk).
    case needsSetup
    case notInstalled
    case notSignedIn
    case failed(String)
}

/// What a run should produce.
nonisolated struct TranscriptionOptions: Sendable, Hashable {
    /// A Whisper language code such as `"ar"`; `nil` detects it per window.
    var language: String?
    /// Names, terms or spellings; also primes Whisper with the speaker's style.
    var context: String

    init(language: String? = nil, context: String = "") {
        self.language = language
        self.context = context
    }
}

/// Turns one audio file into timed segments (seconds from the start of that file).
nonisolated protocol TranscriptionEngine: Sendable {
    func checkStatus() async -> EngineStatus
    /// The chunks to send for a clip, in clip seconds; `nil` uses fixed-length chunks.
    func plan(_ url: URL, duration: Double) async throws -> [Range<Double>]?
    func transcribe(audio: URL, duration: Double, options: TranscriptionOptions) async throws -> [TranscriptSegment]
}

extension TranscriptionEngine {
    func plan(_ url: URL, duration: Double) async throws -> [Range<Double>]? { nil }
}

/// Errors that will fail every chunk the same way, so a run stops instead of retrying.
nonisolated protocol FatalTranscriptionError: Error {
    var isFatal: Bool { get }
}

/// A transcript line to proofread.
nonisolated struct CleanupLine: Sendable, Equatable {
    var text: String
    /// Another reading of the same audio (Whisper's unprompted pass), if any.
    var alternative: String?

    init(_ text: String, alternative: String? = nil) {
        self.text = text
        self.alternative = alternative
    }
}

/// Proofreads transcript lines without touching their timing.
nonisolated protocol TranscriptCleaner: Sendable {
    func checkStatus() async -> EngineStatus
    /// Corrected text per line, in the same order. A `nil` entry keeps that line as it is.
    func clean(_ lines: [CleanupLine], model: String, context: String) async throws -> [String?]
    /// A short context (topic, names, terms) worked out from a rough transcript,
    /// written in the speaker's own language, for when the user gave none.
    func topic(of lines: [String], model: String) async throws -> String
}
