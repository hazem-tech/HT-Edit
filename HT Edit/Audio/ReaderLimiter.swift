//
//  ReaderLimiter.swift
//  HT Edit
//

import Foundation

/// Caps how many `AVAssetReader`s decode at once across *all* clips.
///
/// Many simultaneous readers don't decode faster than the cores available,
/// they compete with playback for the same media pipeline, and AVFoundation has
/// known stalls when too many readers run at once.
actor ReaderLimiter {
    nonisolated static let shared = ReaderLimiter(limit: defaultLimit)

    /// Half the cores (at least 1, at most 4): leaves room for playback, UI and the system.
    nonisolated static var defaultLimit: Int {
        min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
    }

    nonisolated let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            running = max(0, running - 1)
        } else {
            // Hand the permit straight to the next waiter.
            waiters.removeFirst().resume()
        }
    }

    var activeCount: Int { running }
}
