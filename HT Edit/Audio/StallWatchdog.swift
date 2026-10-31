//
//  StallWatchdog.swift
//  HT Edit
//

import Foundation
import Synchronization

/// Records when an operation last made progress.
nonisolated final class ProgressMarker: Sendable {
    private let lastProgress = Mutex(ContinuousClock.now)

    func touch() {
        lastProgress.withLock { $0 = .now }
    }

    var idleTime: Duration {
        ContinuousClock.now - lastProgress.withLock { $0 }
    }
}

/// Runs `operation` and fails with `AnalysisError.stalled` if it stops making
/// progress (no `ProgressMarker.touch()`) for longer than `timeout`.
///
/// AVFoundation readers have known cases where a read never returns. A
/// structured task group can't abandon such a child (it waits for every child),
/// so the operation runs as an unstructured task that is cancelled and
/// abandoned on a stall, and the caller resumes right away.
nonisolated enum StallWatchdog {

    static func run<T: Sendable>(
        timeout: Duration,
        progress: ProgressMarker,
        checkInterval: Duration = .milliseconds(250),
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let work = Task { try await operation() }
        let gate = ResumeOnce<T>()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)

                Task {
                    let result = await work.result
                    gate.resume(with: result)
                }

                Task {
                    while !gate.isResumed {
                        try? await Task.sleep(for: checkInterval)
                        if progress.idleTime > timeout {
                            work.cancel()
                            gate.resume(with: .failure(AnalysisError.stalled))
                            return
                        }
                    }
                }
            }
        } onCancel: {
            work.cancel()
            gate.resume(with: .failure(CancellationError()))
        }
    }
}

/// Resumes a continuation exactly once, whichever side finishes first.
private nonisolated final class ResumeOnce<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, any Error>?
        var pending: Result<T, any Error>?
        var isResumed = false
    }

    private let state = Mutex(State())

    var isResumed: Bool { state.withLock { $0.isResumed } }

    func install(_ continuation: CheckedContinuation<T, any Error>) {
        let early = state.withLock { state -> Result<T, any Error>? in
            if let pending = state.pending {
                state.pending = nil
                return pending
            }
            state.continuation = continuation
            return nil
        }
        if let early {
            continuation.resume(with: early)
        }
    }

    func resume(with result: Result<T, any Error>) {
        let continuation = state.withLock { state -> CheckedContinuation<T, any Error>? in
            guard !state.isResumed else { return nil }
            state.isResumed = true
            guard let continuation = state.continuation else {
                state.pending = result
                return nil
            }
            state.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}
