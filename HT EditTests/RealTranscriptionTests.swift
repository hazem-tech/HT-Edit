//
//  RealTranscriptionTests.swift
//  HT EditTests
//
//  Runs the real pipeline (local Whisper, then Gemini cleanup through agy) on a
//  file of your choice. Skipped unless you ask for it, because it needs Whisper
//  set up and takes minutes:
//
//    TEST_RUNNER_HTEDIT_REAL_FILE=/path/video.mp4 \
//    TEST_RUNNER_HTEDIT_REAL_LANGUAGE=ar \
//    TEST_RUNNER_HTEDIT_REAL_CONTEXT="…" \
//    xcodebuild test -scheme "HT Edit" -only-testing:"HT EditTests/RealTranscriptionTests"
//
//  It writes the Whisper and cleaned transcripts next to the system temp folder
//  (paths are printed) so you can compare them.
//

import AVFoundation
import Foundation
import Testing
@testable import HT_Edit

private let environment = ProcessInfo.processInfo.environment
private let realFile = environment["HTEDIT_REAL_FILE"]

@Suite(.enabled(if: realFile != nil, "Set HTEDIT_REAL_FILE to run"), .timeLimit(.minutes(30)))
struct RealTranscriptionTests {

    @Test func transcribesAndCleansARealFile() async throws {
        let url = URL(filePath: try #require(realFile))
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        let options = TranscriptionOptions(language: environment["HTEDIT_REAL_LANGUAGE"], context: environment["HTEDIT_REAL_CONTEXT"] ?? "")

        let engine = WhisperEngine()
        #expect(await engine.checkStatus() == .ready([]), "Set up Whisper first")
        let clock = ContinuousClock()
        let start = clock.now
        let transcriber = Transcriber(engine: engine, cache: nil)
        var raw: [TranscriptSegment] = []
        var windows = 0
        for try await event in transcriber.run([TranscriptionJob(clipID: UUID(), url: url, duration: duration, chunks: nil)], options: options) {
            switch event {
            case .planned(_, let chunks): windows = chunks.count
            case .chunkFinished(_, let chunk, let segments): raw = TranscriptTimeline.merging(segments, into: raw, chunk: chunk)
            case .chunkFailed(_, let chunk, let message): Issue.record("Window \(chunk) failed: \(message)")
            case .cached: break
            }
        }
        let whisperTime = clock.now - start
        #expect(!raw.isEmpty)
        #expect(zip(raw, raw.dropFirst()).allSatisfy { $0.start <= $1.start }, "lines are in order")

        let cleaner = AgyCleaner()
        var cleaned = raw
        var cleanupTime: Duration = .zero
        if case .ready(let models) = await cleaner.checkStatus(), let model = models.first {
            let cleanStart = clock.now
            let corrected = try await cleaner.clean(raw.map(\.text), model: model.id, context: options.context)
            cleaned = TranscriptionController.applying(corrected, to: raw)
            cleanupTime = clock.now - cleanStart
            #expect(cleaned.map(\.start) == raw.map(\.start), "cleanup never moves timestamps")
            print("Cleanup with \(model.id) changed \(corrected.compactMap { $0 }.count) of \(raw.count) lines in \(cleanupTime)")
        } else {
            print("Antigravity isn't ready: cleanup skipped")
        }

        let out = FileManager.default.temporaryDirectory
        func write(_ segments: [TranscriptSegment], _ name: String) throws -> URL {
            let text = segments.map { String(format: "[%7.2f – %7.2f] ", $0.start, $0.end) + $0.text }.joined(separator: "\n")
            let file = out.appending(path: name)
            try text.write(to: file, atomically: true, encoding: .utf8)
            return file
        }
        let rawFile = try write(raw, "htedit-real-whisper.txt")
        let cleanFile = try write(cleaned, "htedit-real-cleaned.txt")
        print("Whisper: \(windows) windows, \(raw.count) lines in \(whisperTime) → \(rawFile.path)")
        print("Cleaned → \(cleanFile.path)")
    }
}
