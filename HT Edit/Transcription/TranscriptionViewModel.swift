//
//  TranscriptionViewModel.swift
//  HT Edit
//

import Foundation
import Observation
import os

/// Runs a transcription over the timeline's clips and keeps each clip's
/// segments (in clip time). Clips are transcribed one after another; each
/// clip's text appears as soon as it's done.
@Observable
final class TranscriptionViewModel {
    enum Status: Equatable {
        case idle
        case running(completed: Int, total: Int)
        case finished
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var segmentsByClip: [UUID: [TranscriptSegment]] = [:]
    /// Name of the model that produced the current transcript.
    private(set) var modelName: String?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    var isRunning: Bool {
        if case .running = status { true } else { false }
    }

    /// Transcribes `clips` (in timeline order), replacing any previous transcript.
    func start(clips: [(id: UUID, url: URL)], engine: any TranscriptionEngine, modelName: String) {
        cancel()
        guard !clips.isEmpty else { return }
        generation += 1
        let generation = generation
        let ids = clips.map(\.id)
        segmentsByClip = [:]
        self.modelName = modelName
        status = .running(completed: 0, total: ids.count)
        Log.transcription.notice("Transcribe \(ids.count) clip(s) with \(modelName, privacy: .public)")

        let stream = engine.transcribe(clips.map(\.url))
        task = Task {
            let clock = ContinuousClock()
            let started = clock.now
            var completed = 0
            do {
                for try await result in stream {
                    guard generation == self.generation else { return }
                    if ids.indices.contains(result.index) {
                        segmentsByClip[ids[result.index]] = result.segments
                    }
                    completed += 1
                    status = .running(completed: completed, total: ids.count)
                }
                guard generation == self.generation, !Task.isCancelled else { return }
                status = .finished
                Log.transcription.notice("Transcription finished in \((clock.now - started).description, privacy: .public)")
            } catch {
                guard generation == self.generation, !Task.isCancelled, !(error is CancellationError) else { return }
                Log.transcription.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
                status = .failed(error.localizedDescription)
            }
        }
    }

    /// Stops a running transcription, keeping the clips already done.
    func cancel() {
        task?.cancel()
        task = nil
        generation += 1
        if isRunning { status = .idle }
    }

    func removeClips(_ ids: Set<UUID>) {
        for id in ids { segmentsByClip[id] = nil }
    }

    func clear() {
        cancel()
        segmentsByClip = [:]
        modelName = nil
        status = .idle
    }
}
