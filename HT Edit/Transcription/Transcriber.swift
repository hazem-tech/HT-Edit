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
    /// A clip whose text came from the cache now has measured word times.
    case wordsMeasured(clipID: UUID, segments: [TranscriptSegment])
}

/// Splits clips into chunks, exports each chunk's audio and sends it to the
/// engine, a few at a time. Results stream back as each chunk finishes.
///
/// - A chunk that fails is retried once, then reported; the other chunks still finish.
/// - A fatal engine error (not installed, not signed in) ends the whole run.
/// - With an aligner, each chunk's lines then get measured word times. If that
///   fails the text is kept and its word times are estimated.
/// - Clips transcribed completely are cached by file, model and context, even
///   when their word times are estimated. A clip whose text is cached but
///   whose word times aren't measured yet is only aligned again: the engine
///   isn't asked for the same text twice.
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
        /// Some words were meant to be measured but are estimated: cache the text only.
        var hasEstimatedWords = false
        /// The transcript, whatever its word times.
        var textKey: String?
        /// The transcript with measured word times (only with an aligner).
        var alignedKey: String?
    }

    /// A clip whose text came from the cache, to be aligned again.
    private struct Realignment: Sendable {
        var job: TranscriptionJob
        var segments: [TranscriptSegment]
        var alignedKey: String?
    }

    @concurrent
    private func transcribe(_ jobs: [TranscriptionJob], model: String, context: String, emit: @Sendable (TranscriptionEvent) -> Void) async throws {
        let aligner = await usableAligner()

        var items: [WorkItem] = []
        var realignments: [Realignment] = []
        var progress: [UUID: ClipProgress] = [:]
        for job in jobs {
            let wholeClip = job.chunks == nil
            let textKey = wholeClip ? TranscriptCache.key(for: job.url, model: model, context: context) : nil
            let alignedKey = wholeClip && aligner != nil
                ? TranscriptCache.key(for: job.url, model: model, context: context, wordTiming: TranscriptCache.alignedWordTiming)
                : nil
            if let cache, let alignedKey, let segments = await cache.load(key: alignedKey) {
                emit(.cached(clipID: job.clipID, segments: segments))
                continue
            }
            if let cache, let textKey, let segments = await cache.load(key: textKey) {
                emit(.cached(clipID: job.clipID, segments: segments))
                if aligner != nil, !segments.isEmpty {
                    realignments.append(Realignment(job: job, segments: segments, alignedKey: alignedKey))
                }
                continue
            }
            let chunks = job.chunks ?? TranscriptTimeline.chunks(duration: job.duration, length: chunkLength)
            guard !chunks.isEmpty else { continue }
            emit(.planned(clipID: job.clipID, chunks: chunks))
            progress[job.clipID] = ClipProgress(remaining: chunks.count, textKey: textKey, alignedKey: alignedKey)
            for chunk in chunks {
                items.append(WorkItem(job: job, chunk: chunk, fileName: "chunk-\(items.count + 1).m4a"))
            }
        }
        guard !items.isEmpty || !realignments.isEmpty else { return }

        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "Transcription-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        if let aligner {
            for realignment in realignments {
                try await realign(realignment, in: scratch, aligner: aligner, emit: emit)
            }
        }
        guard !items.isEmpty else { return }
        Log.transcription.notice("Transcribing \(items.count) chunk(s) with \(model, privacy: .public)")

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

    /// Counts a chunk as done and caches the clip once all of its chunks
    /// succeeded: its text always, and with its word times once they're all measured.
    private func finishChunk(of clipID: UUID, in progress: inout [UUID: ClipProgress]) async {
        guard var clip = progress[clipID] else { return }
        clip.remaining -= 1
        progress[clipID] = clip
        guard clip.remaining == 0, !clip.hasFailure, let cache else { return }
        let segments = clip.segments.sorted { $0.start < $1.start }
        if let key = clip.textKey {
            await cache.store(segments, key: key)
        }
        if !clip.hasEstimatedWords, let key = clip.alignedKey {
            await cache.store(segments, key: key)
        }
    }

    /// Measures the word times of a clip whose text came from the cache, chunk
    /// by chunk as if it had just been transcribed, without asking the engine.
    private func realign(_ realignment: Realignment, in scratch: URL, aligner: any WordAligner, emit: @Sendable (TranscriptionEvent) -> Void) async throws {
        let job = realignment.job
        let chunks = TranscriptTimeline.chunks(duration: job.duration, length: chunkLength)
        guard !chunks.isEmpty else { return }
        Log.transcription.notice("Measuring word times of a cached transcript (\(chunks.count) chunk(s))")

        var remaining = realignment.segments.sorted { $0.start < $1.start }
        var measured: [TranscriptSegment] = []
        var hasEstimatedWords = false
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            // Each line goes with the chunk it starts in; the last chunk takes the rest.
            let isLast = index == chunks.count - 1
            let inChunk = remaining.prefix { isLast || $0.start < chunk.upperBound }
            remaining.removeFirst(inChunk.count)
            guard !inChunk.isEmpty else { continue }
            let item = WorkItem(job: job, chunk: chunk, fileName: "realign-\(index + 1)")
            guard case .finished(_, let segments, let error) = try await withWordTimes(Array(inChunk), of: item, in: scratch, aligner: aligner) else { continue }
            if let error {
                emit(.wordTimingFailed(clipID: job.clipID, chunk: chunk, message: error))
            }
            if segments.contains(where: { $0.words == nil }) {
                hasEstimatedWords = true
            }
            measured += segments
        }
        emit(.wordsMeasured(clipID: job.clipID, segments: measured))
        if !hasEstimatedWords, let cache, let key = realignment.alignedKey {
            await cache.store(measured, key: key)
        }
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
