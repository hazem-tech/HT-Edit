//
//  FakeTranscriptionEngine.swift
//  HT Edit
//
//  Debug-only stand-in for Antigravity, so UI tests can run a whole
//  transcription without a Google sign-in. Enabled with the launch argument
//  `-UITestFakeTranscription 1`.
//

#if DEBUG
import Foundation

nonisolated struct FakeTranscriptionEngine: TranscriptionEngine {
    static let line = "Hello from the fake transcriber."

    func checkStatus() async -> EngineStatus {
        .ready(TranscriptionModel.catalog)
    }

    func transcribe(audio: URL, duration: Double, model: String, context: String) async throws -> [TranscriptSegment] {
        try await Task.sleep(for: .milliseconds(200))
        return [TranscriptSegment(start: 0.1, end: min(duration, 0.9), text: Self.line)]
    }
}

/// Highlights the first word, whatever the question.
nonisolated struct FakeReviewEngine: TranscriptReviewEngine {
    static let reason = "Fake review finding."

    func review(transcript: String, instruction: String, model: String) async throws -> [ReviewFinding] {
        try await Task.sleep(for: .milliseconds(200))
        return [ReviewFinding(first: 0, last: 0, reason: Self.reason)]
    }
}

extension UITestSupport {
    static func fakeTranscriptionEngine() -> (any TranscriptionEngine)? {
        UserDefaults.standard.bool(forKey: "UITestFakeTranscription") ? FakeTranscriptionEngine() : nil
    }

    static func fakeReviewEngine() -> (any TranscriptReviewEngine)? {
        UserDefaults.standard.bool(forKey: "UITestFakeTranscription") ? FakeReviewEngine() : nil
    }
}
#endif
