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
    /// The chunk's text is in, but its word times couldn't be measured: they're estimated.
    case wordTimingFailed(clipID: UUID, chunk: Range<Double>, message: String)
}

/// Splits clips into chunks, exports each chunk's audio and sends it to the
/// engine, a few at a time. Results stream back as each chunk finishes.
///
/// - A chunk that fails is retried once, then reported; the other chunks still finish.
/// - A fatal engine error (not installed, not signed in) ends the whole run.
/// - With an aligner, each chunk's lines then get measured word times. If that
///   fails the text is kept and its word times are estimated.
/// - Clips transcribed completely are cached by file, model and context.
nonisolated struct Transcriber: Sendable {
    var engine: any TranscriptionEngine
    var cache: TranscriptCache? = .shared
    /// Seconds of audio per request. Shorter chunks keep timestamps from drifting.
    var chunkLength: Double = 180
    /// Requests running at once, so the subscription's rate limits aren't hit.
    var maxConcurrentChunks = 2
    var retries = 1
    /// Measures word times; `nil` estimates them from each line's time.
    var aligner: (any WordAligner)? = nil

    func run(_ jobs: [TranscriptionJob], model: String, context: String) -> AsyncThrowingStream<TranscriptionEvent, any Error> {
        let transcriber = self
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await transcriber.transcribe(jobs, model: model, context: context) { continuation.yield($0) }
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
        case finished(WorkItem, [TranscriptSegment], wordTimingError: String?)
        case failed(WorkItem, String)
    }

    /// Per clip: chunks still running, segments so far, and whether any chunk failed.
    private struct ClipProgress {
        var remaining: Int
        var segments: [TranscriptSegment] = []
        var hasFailure = false
        /// Some words were meant to be measured but are estimated: don't cache.
        var hasEstimatedWords = false
        var cacheKey: String?
    }

    @concurrent
    private func transcribe(_ jobs: [TranscriptionJob], model: String, context: String, emit: @Sendable (TranscriptionEvent) -> Void) async throws {
        let aligner = await usableAligner()
        let wordTiming = aligner == nil ? "" : TranscriptCache.alignedWordTiming

        var items: [WorkItem] = []
        var progress: [UUID: ClipProgress] = [:]
        for job in jobs {
            let cacheKey = job.chunks == nil ? TranscriptCache.key(for: job.url, model: model, context: context, wordTiming: wordTiming) : nil
            if let cache, let cacheKey, let segments = await cache.load(key: cacheKey) {
                emit(.cached(clipID: job.clipID, segments: segments))
                continue
            }
            let chunks = job.chunks ?? TranscriptTimeline.chunks(duration: job.duration, length: chunkLength)
            guard !chunks.isEmpty else { continue }
            emit(.planned(clipID: job.clipID, chunks: chunks))
            progress[job.clipID] = ClipProgress(remaining: chunks.count, cacheKey: cacheKey)
            for chunk in chunks {
                items.append(WorkItem(job: job, chunk: chunk, fileName: "chunk-\(items.count + 1).m4a"))
            }
        }
        guard !items.isEmpty else { return }
        Log.transcription.notice("Transcribing \(items.count) chunk(s) with \(model, privacy: .public)")

        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "Transcription-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        try await withThrowingTaskGroup(of: Outcome.self) { group in
            var queue = items.makeIterator()
            for _ in 0..<max(1, maxConcurrentChunks) {
                guard let item = queue.next() else { break }
                group.addTask { try await self.process(item, in: scratch, model: model, context: context, aligner: aligner) }
            }
            while let outcome = try await group.next() {
                switch outcome {
                case .finished(let item, let segments, let wordTimingError):
                    if let wordTimingError {
                        emit(.wordTimingFailed(clipID: item.job.clipID, chunk: item.chunk, message: wordTimingError))
                    }
                    emit(.chunkFinished(clipID: item.job.clipID, chunk: item.chunk, segments: segments))
                    progress[item.job.clipID]?.segments += segments
                    if aligner != nil, segments.contains(where: { $0.words == nil }) {
                        progress[item.job.clipID]?.hasEstimatedWords = true
                    }
                    await finishChunk(of: item.job.clipID, in: &progress)
                case .failed(let item, let message):
                    emit(.chunkFailed(clipID: item.job.clipID, chunk: item.chunk, message: message))
                    progress[item.job.clipID]?.hasFailure = true
                    await finishChunk(of: item.job.clipID, in: &progress)
                }
                if let item = queue.next() {
                    group.addTask { try await self.process(item, in: scratch, model: model, context: context, aligner: aligner) }
                }
            }
        }
    }

    /// The aligner, if it's ready to run.
    private func usableAligner() async -> (any WordAligner)? {
        guard let aligner else { return nil }
        let status = await aligner.checkStatus()
        guard status == .ready else {
            Log.transcription.notice("Word times are estimated: aligner is \(String(describing: status), privacy: .public)")
            return nil
        }
        return aligner
    }

    /// Counts a chunk as done and caches the clip once all of its chunks succeeded.
    private func finishChunk(of clipID: UUID, in progress: inout [UUID: ClipProgress]) async {
        guard var clip = progress[clipID] else { return }
        clip.remaining -= 1
        progress[clipID] = clip
        guard clip.remaining == 0, !clip.hasFailure, !clip.hasEstimatedWords, let cache, let key = clip.cacheKey else { return }
        await cache.store(clip.segments.sorted { $0.start < $1.start }, key: key)
    }

    /// Exports one chunk and transcribes it, retrying once, then measures its word times.
    private func process(_ item: WorkItem, in scratch: URL, model: String, context: String, aligner: (any WordAligner)?) async throws -> Outcome {
        let audio = scratch.appending(path: item.fileName, directoryHint: .notDirectory)
        defer { try? FileManager.default.removeItem(at: audio) }
        do {
            try await AudioChunkExporter.export(item.job.url, range: item.chunk, to: audio)
        } catch {
            try Task.checkCancellation()
            return .failed(item, error.localizedDescription)
        }

        let duration = item.chunk.upperBound - item.chunk.lowerBound
        var lastError: any Error = AgyError.failed("No attempt was made.")
        for attempt in 0...max(0, retries) {
            try Task.checkCancellation()
            do {
                let raw = try await engine.transcribe(audio: audio, duration: duration, model: model, context: context)
                let segments = TranscriptTimeline.normalize(raw, chunk: item.chunk)
                return try await withWordTimes(segments, of: item, in: scratch, aligner: aligner)
            } catch let error as AgyError where error.isFatal {
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

    /// `segments` with measured word times. An aligner failure keeps the text
    /// (word times are then estimated) and reports why.
    private func withWordTimes(_ segments: [TranscriptSegment], of item: WorkItem, in scratch: URL, aligner: (any WordAligner)?) async throws -> Outcome {
        guard let aligner, !segments.isEmpty else { return .finished(item, segments, wordTimingError: nil) }
        do {
            let aligned = try await aligner.align(segments, in: item.job.url, chunk: item.chunk, scratch: scratch)
            return .finished(item, aligned, wordTimingError: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            Log.transcription.error("Word timing for \(item.fileName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return .finished(item, segments, wordTimingError: error.localizedDescription)
        }
    }
}
