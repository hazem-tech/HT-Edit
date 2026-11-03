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

extension UITestSupport {
    static func fakeTranscriptionEngine() -> (any TranscriptionEngine)? {
        UserDefaults.standard.bool(forKey: "UITestFakeTranscription") ? FakeTranscriptionEngine() : nil
    }
}
#endif
