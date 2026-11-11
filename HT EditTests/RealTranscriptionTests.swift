//
//  RealTranscriptionTests.swift
//  HT EditTests
//
//  Runs the real pipeline (local Whisper, then Gemini cleanup through agy) on a
//  file of your choice. Skipped unless you ask for it, because it needs Whisper
//  set up and takes minutes:
//
//    TEST_RUNNER_HTEDIT_REAL_FILE=/path/video.mp4 \
//    TEST_RUNNER_HTEDIT_REAL_CONTEXT="…"   (optional; empty like the app's default) \
//    xcodebuild test -scheme "HT Edit" -only-testing:"HT EditTests/RealTranscriptionTests"
//
//  It writes the finished transcript to the system temp folder (the path is printed).
//

import AVFoundation
import Foundation
import Testing
@testable import HT_Edit

private let environment = ProcessInfo.processInfo.environment
private let realFile = environment["HTEDIT_REAL_FILE"]

@Suite(.enabled(if: realFile != nil, "Set HTEDIT_REAL_FILE to run"), .timeLimit(.minutes(30)))
struct RealTranscriptionTests {

    /// The app's own pipeline (TranscriptionController with Whisper and agy), on a real file.
    /// The context comes from HTEDIT_REAL_CONTEXT and is empty by default, like in the app.
    @MainActor
    @Test func transcribesAndCleansARealFile() async throws {
        let url = URL(filePath: try #require(realFile))
        let duration = try await AVURLAsset(url: url).load(.duration)
        let controller = TranscriptionController(engine: WhisperEngine(), cleaner: AgyCleaner(), cache: nil, defaults: nil)
        controller.context = environment["HTEDIT_REAL_CONTEXT"] ?? ""
        let clip = Clip(url: url, duration: duration)

        let clock = ContinuousClock()
        let start = clock.now
        controller.transcribe([clip])
        #expect(await waitUntil(timeout: .seconds(1800)) { !controller.isRunning && controller.phase != .idle })
        #expect(controller.phase == .finished)
        let lines = controller.transcripts[clip.id] ?? []
        #expect(!lines.isEmpty)
        #expect(zip(lines, lines.dropFirst()).allSatisfy { $0.start <= $1.start }, "lines are in order")

        let text = lines.map { String(format: "[%7.2f – %7.2f] ", $0.start, $0.end) + $0.text }.joined(separator: "\n")
        let file = FileManager.default.temporaryDirectory.appending(path: "htedit-real-cleaned.txt")
        try text.write(to: file, atomically: true, encoding: .utf8)
        print("Topic found: \(controller.detectedContext ?? "(none)")")
        if let note = controller.cleanupNote { print("Note: \(note)") }
        print("\(lines.count) lines in \(clock.now - start) → \(file.path)")
    }
}
