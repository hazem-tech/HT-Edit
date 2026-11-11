//
//  TranscriberTests.swift
//  HT EditTests
//

import AVFoundation
import CoreMedia
import Foundation
import Synchronization
import Testing
@testable import HT_Edit

/// An engine whose behavior each test scripts; it records every call.
final class ScriptedEngine: TranscriptionEngine {
    struct Call: Sendable {
        var duration: Double
        var options: TranscriptionOptions
        var audioExisted: Bool
    }

    private let state = Mutex<(calls: [Call], running: Int, maxRunning: Int)>(([], 0, 0))
    private let status: EngineStatus
    private let reply: @Sendable (_ callIndex: Int, _ duration: Double) throws -> [TranscriptSegment]
    private let delay: Duration

    init(
        status: EngineStatus = .ready([]),
        delay: Duration = .milliseconds(50),
        reply: @escaping @Sendable (_ callIndex: Int, _ duration: Double) throws -> [TranscriptSegment] = { _, duration in
            [TranscriptSegment(start: 0.5, end: min(duration, 1.5), text: "words")]
        }
    ) {
        self.status = status
        self.delay = delay
        self.reply = reply
    }

    var calls: [Call] { state.withLock { $0.calls } }
    var maxConcurrentCalls: Int { state.withLock { $0.maxRunning } }

    func checkStatus() async -> EngineStatus { status }

    func transcribe(audio: URL, duration: Double, options: TranscriptionOptions) async throws -> [TranscriptSegment] {
        let index = state.withLock { state in
            state.calls.append(Call(duration: duration, options: options, audioExisted: FileManager.default.fileExists(atPath: audio.path)))
            state.running += 1
            state.maxRunning = max(state.maxRunning, state.running)
            return state.calls.count - 1
        }
        defer { state.withLock { $0.running -= 1 } }
        try await Task.sleep(for: delay)
        return try reply(index, duration)
    }
}

struct TestFailure: Error {}

/// An engine that plans its own chunks, like Whisper's speech windows.
struct PlanningEngine: TranscriptionEngine {
    var windows: [Range<Double>]
    func checkStatus() async -> EngineStatus { .ready([]) }
    func plan(_ url: URL, duration: Double) async throws -> [Range<Double>]? { windows }
    func transcribe(audio: URL, duration: Double, options: TranscriptionOptions) async throws -> [TranscriptSegment] {
        [TranscriptSegment(start: 0.1, end: duration - 0.1, text: "window")]
    }
}

/// A cleaner whose replies each test scripts; it records the lines it was given.
final class ScriptedCleaner: TranscriptCleaner {
    private let state = Mutex<[[String]]>([])
    private let status: EngineStatus
    private let reply: @Sendable ([String]) throws -> [String?]

    init(status: EngineStatus = .ready(TranscriptionModel.catalog), reply: @escaping @Sendable ([String]) throws -> [String?]) {
        self.status = status
        self.reply = reply
    }

    var calls: [[String]] { state.withLock { $0 } }

    func checkStatus() async -> EngineStatus { status }

    func clean(_ lines: [CleanupLine], model: String, context: String) async throws -> [String?] {
        let texts = lines.map(\.text)
        state.withLock { $0.append(texts) }
        return try reply(texts)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct TranscriberTests {

    /// A 7 s audio file: with 3 s chunks that's 0–3, 3–7 (the 1 s tail is folded in).
    private func makeAudio() async throws -> (url: URL, directory: URL) {
        let directory = makeTemporaryDirectory("transcriber")
        return (try await MediaFixtures.make(.audioOnly, in: directory, duration: 7), directory)
    }

    private func collect(_ stream: AsyncThrowingStream<TranscriptionEvent, any Error>) async throws -> [TranscriptionEvent] {
        var events: [TranscriptionEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    @Test func chunksAreExportedSentAndPlacedInClipTime() async throws {
        let (audio, directory) = try await makeAudio()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = ScriptedEngine()
        let transcriber = Transcriber(engine: engine, cache: nil, chunkLength: 3, maxConcurrentChunks: 2)
        let clipID = UUID()

        let events = try await collect(transcriber.run(
            [TranscriptionJob(clipID: clipID, url: audio, duration: 7, chunks: nil)], options: TranscriptionOptions(language: "ar", context: "names")
        ))

        #expect(events.first == .planned(clipID: clipID, chunks: [0..<3, 3..<7]))
        let finished = events.compactMap { event -> [TranscriptSegment]? in
            if case .chunkFinished(_, _, let segments) = event { return segments }
            return nil
        }
        #expect(finished.flatMap { $0 }.map(\.start).sorted() == [0.5, 3.5])
        #expect(engine.calls.count == 2)
        #expect(engine.calls.allSatisfy { $0.options == TranscriptionOptions(language: "ar", context: "names") && $0.audioExisted })
        #expect(engine.calls.map(\.duration).sorted() == [3, 4])
    }

    @Test func noMoreThanTheLimitRunAtOnce() async throws {
        let (audio, directory) = try await makeAudio()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = ScriptedEngine(delay: .milliseconds(200))
        let transcriber = Transcriber(engine: engine, cache: nil, chunkLength: 1, maxConcurrentChunks: 2)
        let jobs = (0..<2).map { _ in TranscriptionJob(clipID: UUID(), url: audio, duration: 7, chunks: nil) }

        _ = try await collect(transcriber.run(jobs, options: TranscriptionOptions()))
        // 6 chunks per clip: 0–1 … 4–5, and 5–7 with the short tail folded in.
        #expect(engine.calls.count == 12)
        #expect(engine.maxConcurrentCalls == 2)
    }

    @Test func aFailingChunkIsRetriedOnceThenReported() async throws {
        let (audio, directory) = try await makeAudio()
        defer { try? FileManager.default.removeItem(at: directory) }
        // The 4 s chunk (3–7) always fails; the other succeeds.
        let engine = ScriptedEngine { _, duration in
            if duration > 3.5 { throw WhisperError.failed("nope") }
            return [TranscriptSegment(start: 1, end: 2, text: "ok")]
        }
        let transcriber = Transcriber(engine: engine, cache: nil, chunkLength: 3)
        let clipID = UUID()

        let events = try await collect(transcriber.run([TranscriptionJob(clipID: clipID, url: audio, duration: 7, chunks: nil)], options: TranscriptionOptions()))
        #expect(events.contains(.chunkFinished(clipID: clipID, chunk: 0..<3, segments: [TranscriptSegment(start: 1, end: 2, text: "ok")])))
        #expect(events.contains { event in
            guard case .chunkFailed(let id, let chunk, _) = event else { return false }
            return id == clipID && chunk == 3..<7
        })
        #expect(engine.calls.count(where: { $0.duration > 3.5 }) == 2, "one try plus one retry")
    }

    @Test func aFatalErrorStopsTheWholeRun() async throws {
        let (audio, directory) = try await makeAudio()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = ScriptedEngine { _, _ in throw WhisperError.notSetUp }
        let transcriber = Transcriber(engine: engine, cache: nil, chunkLength: 1, maxConcurrentChunks: 1)

        await #expect(throws: WhisperError.notSetUp) {
            _ = try await collect(transcriber.run([TranscriptionJob(clipID: UUID(), url: audio, duration: 7, chunks: nil)], options: TranscriptionOptions()))
        }
        #expect(engine.calls.count == 1, "no retries and no further chunks after a fatal error")
    }

    @Test func completeClipsAreCachedPerModelAndContext() async throws {
        let (audio, directory) = try await makeAudio()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = TranscriptCache(directory: directory.appending(path: "cache"))
        let engine = ScriptedEngine()
        let transcriber = Transcriber(engine: engine, cache: cache, chunkLength: 3)
        let clipID = UUID()
        let job = TranscriptionJob(clipID: clipID, url: audio, duration: 7, chunks: nil)

        _ = try await collect(transcriber.run([job], options: TranscriptionOptions(context: "a")))
        let second = try await collect(transcriber.run([job], options: TranscriptionOptions(context: "a")))
        #expect(second == [.cached(clipID: clipID, segments: [
            TranscriptSegment(start: 0.5, end: 1.5, text: "words"),
            TranscriptSegment(start: 3.5, end: 4.5, text: "words"),
        ])])
        #expect(engine.calls.count == 2)

        _ = try await collect(transcriber.run([job], options: TranscriptionOptions(context: "different")))
        #expect(engine.calls.count == 4, "a different context is a different transcript")
    }

    @Test func chunksPlannedByTheEngineAreUsed() async throws {
        let (audio, directory) = try await makeAudio()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriber = Transcriber(engine: PlanningEngine(windows: [0.5..<2, 4..<6.5]), cache: nil, chunkLength: 3)
        let clipID = UUID()

        let events = try await collect(transcriber.run([TranscriptionJob(clipID: clipID, url: audio, duration: 7, chunks: nil)], options: TranscriptionOptions()))
        #expect(events.first == .planned(clipID: clipID, chunks: [0.5..<2, 4..<6.5]))
        let starts = events.compactMap { event -> [Double]? in
            if case .chunkFinished(_, _, let segments) = event { return segments.map(\.start) }
            return nil
        }
        #expect(starts.flatMap { $0 }.sorted() == [0.6, 4.1])
    }

    @Test func exportedChunkHasTheRequestedLength() async throws {
        let (audio, directory) = try await makeAudio()
        defer { try? FileManager.default.removeItem(at: directory) }
        let chunk = directory.appending(path: "chunk.m4a")
        try await AudioChunkExporter.export(audio, range: 2..<5.5, to: chunk)

        let asset = AVURLAsset(url: chunk)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 3.5) < 0.1)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(!tracks.isEmpty)
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct TranscriptionControllerTests {

    @Test func transcribingFillsInTimelineSegmentsAndProgress() async throws {
        let directory = makeTemporaryDirectory("controller")
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = try await MediaFixtures.make(.audioOnly, in: directory, duration: 7)
        let controller = TranscriptionController(engine: ScriptedEngine(), cache: nil, defaults: nil, chunkLength: 3)
        let clip = Clip(url: audio, duration: CMTime(seconds: 7, preferredTimescale: 600))
        let model = EditorViewModel(analyzedClips: [(clip, makeLevels(loud(7)))], transcription: controller)

        controller.transcribe(model.placedClips)
        #expect(controller.isRunning)
        #expect(await waitUntil { controller.phase == .finished })
        #expect(controller.progress == 1)
        #expect(model.timelineTranscript.map(\.start) == [0.5, 3.5])
        #expect(controller.engineStatus == .ready([]))
    }

    @Test func whisperNotSetUpFailsWithoutRunning() async throws {
        let engine = ScriptedEngine(status: .needsSetup)
        let controller = TranscriptionController(engine: engine, cache: nil, defaults: nil)
        controller.transcribe([Clip(url: URL(filePath: "/tmp/x.mov"), duration: CMTime(seconds: 5, preferredTimescale: 600))])
        #expect(await waitUntil { controller.phase != .running })
        #expect(controller.phase == .failed(WhisperError.notSetUp.localizedDescription))
        #expect(engine.calls.isEmpty)
    }

    @Test func modelChoiceFallsBackToTheCheapestAvailableAndIsRemembered() async throws {
        let defaults = try #require(UserDefaults(suiteName: "transcription-\(UUID().uuidString)"))
        let lite = TranscriptionModel.catalog[0]
        let flash = TranscriptionModel.catalog[2]
        let cleaner = ScriptedCleaner(status: .ready([lite, flash])) { $0 }
        let controller = TranscriptionController(engine: ScriptedEngine(), cleaner: cleaner, cache: nil, defaults: defaults)

        await controller.refreshStatus()
        #expect(controller.availableModels == [lite, flash])
        #expect(controller.selectedModel == lite, "defaults to the cheapest available")

        controller.preferredModelID = flash.id
        #expect(controller.selectedModel == flash)
        let relaunched = TranscriptionController(engine: ScriptedEngine(), cleaner: ScriptedCleaner(status: .ready([lite])) { $0 }, cache: nil, defaults: defaults)
        #expect(relaunched.preferredModelID == flash.id)
        await relaunched.refreshStatus()
        #expect(relaunched.selectedModel == lite, "a remembered model that's no longer offered falls back to the cheapest")
    }

    @Test func cleanupReplacesTextButNeverTimes() async throws {
        let directory = makeTemporaryDirectory("controller-cleanup")
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = try await MediaFixtures.make(.audioOnly, in: directory, duration: 7)
        let cleaner = ScriptedCleaner { lines in lines.enumerated().map { $0.offset == 0 ? "cleaned" : nil } }
        let controller = TranscriptionController(engine: ScriptedEngine(), cleaner: cleaner, cache: nil, defaults: nil, chunkLength: 3)
        let clip = Clip(url: audio, duration: CMTime(seconds: 7, preferredTimescale: 600))
        let model = EditorViewModel(analyzedClips: [(clip, makeLevels(loud(7)))], transcription: controller)

        controller.transcribe(model.placedClips)
        #expect(await waitUntil { controller.phase == .finished })
        #expect(cleaner.calls == [["words", "words"]])
        #expect(controller.transcripts[clip.id] == [
            TranscriptSegment(start: 0.5, end: 1.5, text: "cleaned"),
            TranscriptSegment(start: 3.5, end: 4.5, text: "words"),
        ])
    }

    @Test func failedCleanupKeepsWhisperText() async throws {
        let directory = makeTemporaryDirectory("controller-cleanup-fail")
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = try await MediaFixtures.make(.audioOnly, in: directory, duration: 3)
        let cleaner = ScriptedCleaner { _ in throw AgyError.timedOut }
        let controller = TranscriptionController(engine: ScriptedEngine(), cleaner: cleaner, cache: nil, defaults: nil, chunkLength: 3)
        let clip = Clip(url: audio, duration: CMTime(seconds: 3, preferredTimescale: 600))

        controller.transcribe([clip])
        #expect(await waitUntil { controller.phase == .finished })
        #expect(controller.transcripts[clip.id]?.map(\.text) == ["words"])
        #expect(controller.cleanupNote?.contains("Not cleaned up") == true)
    }

    @Test func cleanupCanBeTurnedOff() async throws {
        let directory = makeTemporaryDirectory("controller-cleanup-off")
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = try await MediaFixtures.make(.audioOnly, in: directory, duration: 3)
        let cleaner = ScriptedCleaner { $0 }
        let controller = TranscriptionController(engine: ScriptedEngine(), cleaner: cleaner, cache: nil, defaults: nil, chunkLength: 3)
        controller.cleanupEnabled = false

        controller.transcribe([Clip(url: audio, duration: CMTime(seconds: 3, preferredTimescale: 600))])
        #expect(await waitUntil { controller.phase == .finished })
        #expect(cleaner.calls.isEmpty)
    }

    @Test func removingAClipDropsItsTranscript() async throws {
        let directory = makeTemporaryDirectory("controller-remove")
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = try await MediaFixtures.make(.audioOnly, in: directory, duration: 3)
        let controller = TranscriptionController(engine: ScriptedEngine(), cache: nil, defaults: nil, chunkLength: 3)
        let clip = Clip(url: audio, duration: CMTime(seconds: 3, preferredTimescale: 600))
        let model = EditorViewModel(analyzedClips: [(clip, makeLevels(loud(3)))], transcription: controller)

        controller.transcribe(model.placedClips)
        #expect(await waitUntil { controller.phase == .finished })
        #expect(!model.timelineTranscript.isEmpty)

        model.removeClips([clip.id])
        #expect(model.timelineTranscript.isEmpty)
        #expect(controller.transcripts[clip.id] == nil)
    }
}
