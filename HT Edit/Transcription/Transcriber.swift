//
//  Transcriber.swift
//  HT Edit
//

import Foundation
import os

/// A clip to transcribe.
nonisolated struct TranscriptionJob: Sendable {
    var clipID: UUID
    var url: URL
    /// Seconds.
    var duration: Double
    /// Specific chunks to redo (a retry); `nil` transcribes the whole clip and may use the cache.
    var chunks: [Range<Double>]?
}

/// Progress reported while transcribing; all times are clip seconds.
nonisolated enum TranscriptionEvent: Sendable, Equatable {
    /// The clip came from the cache, complete.
    case cached(clipID: UUID, segments: [TranscriptSegment])
    /// The clip will be sent as these chunks.
    case planned(clipID: UUID, chunks: [Range<Double>])
    case chunkFinished(clipID: UUID, chunk: Range<Double>, segments: [TranscriptSegment])
    case chunkFailed(clipID: UUID, chunk: Range<Double>, message: String)
}

/// Splits clips into chunks, exports each chunk's audio and sends it to the
/// engine, a few at a time. Results stream back as each chunk finishes.
///
/// - A chunk that fails is retried once, then reported; the other chunks still finish.
/// - A fatal engine error (not set up, helper crashed) ends the whole run.
/// - Clips transcribed completely are cached by file, language and context.
nonisolated struct Transcriber: Sendable {
    var engine: any TranscriptionEngine
    var cache: TranscriptCache? = .shared
    /// Seconds of audio per request when the engine doesn't plan its own chunks.
    var chunkLength: Double = 180
    /// Requests in flight at once. Whisper works on one at a time; a second one lets the next chunk export meanwhile.
    var maxConcurrentChunks = 2
    var retries = 1

    func run(_ jobs: [TranscriptionJob], options: TranscriptionOptions) -> AsyncThrowingStream<TranscriptionEvent, any Error> {
        let transcriber = self
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await transcriber.transcribe(jobs, options: options) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Pipeline

    private struct WorkItem: Sendable {
        var job: TranscriptionJob
        var chunk: Range<Double>
        var fileName: String
    }

    private enum Outcome: Sendable {
        case finished(WorkItem, [TranscriptSegment])
        case failed(WorkItem, String)
    }

    /// Per clip: chunks still running, segments so far, and whether any chunk failed.
    private struct ClipProgress {
        var remaining: Int
        var segments: [TranscriptSegment] = []
        var hasFailure = false
        var cacheKey: String?
    }

    @concurrent
    private func transcribe(_ jobs: [TranscriptionJob], options: TranscriptionOptions, emit: @Sendable (TranscriptionEvent) -> Void) async throws {
        var items: [WorkItem] = []
        var progress: [UUID: ClipProgress] = [:]
        for job in jobs {
            let cacheKey = job.chunks == nil ? TranscriptCache.key(for: job.url, options: options) : nil
            if let cache, let cacheKey, let segments = await cache.load(key: cacheKey) {
                emit(.cached(clipID: job.clipID, segments: segments))
                continue
            }
            let chunks: [Range<Double>]
            if let retry = job.chunks { chunks = retry } else { chunks = try await planChunks(for: job) }
            guard !chunks.isEmpty else { continue }
            emit(.planned(clipID: job.clipID, chunks: chunks))
            progress[job.clipID] = ClipProgress(remaining: chunks.count, cacheKey: cacheKey)
            for chunk in chunks {
                items.append(WorkItem(job: job, chunk: chunk, fileName: "chunk-\(items.count + 1).m4a"))
            }
        }
        guard !items.isEmpty else { return }
        Log.transcription.notice("Transcribing \(items.count) chunk(s), language \(options.language ?? "auto", privacy: .public)")

        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "Transcription-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        try await withThrowingTaskGroup(of: Outcome.self) { group in
            var queue = items.makeIterator()
            for _ in 0..<max(1, maxConcurrentChunks) {
                guard let item = queue.next() else { break }
                group.addTask { try await self.process(item, in: scratch, options: options) }
            }
            while let outcome = try await group.next() {
                switch outcome {
                case .finished(let item, let segments):
                    emit(.chunkFinished(clipID: item.job.clipID, chunk: item.chunk, segments: segments))
                    progress[item.job.clipID]?.segments += segments
                    await finishChunk(of: item.job.clipID, in: &progress)
                case .failed(let item, let message):
                    emit(.chunkFailed(clipID: item.job.clipID, chunk: item.chunk, message: message))
                    progress[item.job.clipID]?.hasFailure = true
                    await finishChunk(of: item.job.clipID, in: &progress)
                }
                if let item = queue.next() {
                    group.addTask { try await self.process(item, in: scratch, options: options) }
                }
            }
        }
    }

    /// The engine's own chunks (speech windows) if it plans them, otherwise fixed-length ones.
    private func planChunks(for job: TranscriptionJob) async throws -> [Range<Double>] {
        do {
            if let planned = try await engine.plan(job.url, duration: job.duration) { return planned }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Log.transcription.error("Planning \(job.url.lastPathComponent, privacy: .public) failed, using fixed chunks: \(error.localizedDescription, privacy: .public)")
        }
        return TranscriptTimeline.chunks(duration: job.duration, length: chunkLength)
    }

    /// Counts a chunk as done and caches the clip once all of its chunks succeeded.
    private func finishChunk(of clipID: UUID, in progress: inout [UUID: ClipProgress]) async {
        guard var clip = progress[clipID] else { return }
        clip.remaining -= 1
        progress[clipID] = clip
        guard clip.remaining == 0, !clip.hasFailure, let cache, let key = clip.cacheKey else { return }
        await cache.store(clip.segments.sorted { $0.start < $1.start }, key: key)
    }

    /// Exports one chunk and transcribes it, retrying once.
    private func process(_ item: WorkItem, in scratch: URL, options: TranscriptionOptions) async throws -> Outcome {
        let audio = scratch.appending(path: item.fileName, directoryHint: .notDirectory)
        defer { try? FileManager.default.removeItem(at: audio) }
        do {
            try await AudioChunkExporter.export(item.job.url, range: item.chunk, to: audio)
        } catch {
            try Task.checkCancellation()
            return .failed(item, error.localizedDescription)
        }

        let duration = item.chunk.upperBound - item.chunk.lowerBound
        var lastError: any Error = WhisperError.failed("No attempt was made.")
        for attempt in 0...max(0, retries) {
            try Task.checkCancellation()
            do {
                let raw = try await engine.transcribe(audio: audio, duration: duration, options: options)
                return .finished(item, TranscriptTimeline.normalize(raw, chunk: item.chunk))
            } catch let error as any FatalTranscriptionError where error.isFatal {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Log.transcription.error("Chunk \(item.fileName, privacy: .public) attempt \(attempt + 1) failed: \(error.localizedDescription, privacy: .public)")
                lastError = error
            }
        }
        return .failed(item, lastError.localizedDescription)
    }
}
