//
//  EditDecisions.swift
//  HT Edit
//

import Foundation

/// A kept piece of one clip, in clip seconds, with the markers inside it.
nonisolated struct KeptPiece: Equatable, Sendable {
    var range: Range<Double>
    /// Marker positions, clip seconds, sorted.
    var markers: [Double] = []
}

/// What an export writes: for each clip on the timeline, the pieces of it
/// that stay in the edit.
nonisolated enum EditDecisions {

    /// The kept pieces of each clip, in clip seconds.
    ///
    /// - Parameters:
    ///   - clipDurations: the placed clips' durations, in timeline order.
    ///   - map: what's kept, on the whole timeline.
    ///   - markers: each clip's markers, in clip seconds.
    static func keptPieces(clipDurations: [Double], map: EditMap, markers: [[Double]] = []) -> [[KeptPiece]] {
        var result: [[KeptPiece]] = []
        var clipStart = 0.0
        for (index, duration) in clipDurations.enumerated() {
            guard duration.isFinite, duration > 0 else {
                result.append([])
                continue
            }
            let clipMarkers = (index < markers.count ? markers[index] : []).sorted()
            let pieces = map.pieces(within: clipStart..<(clipStart + duration)).map { range in
                let local = (range.lowerBound - clipStart)..<(range.upperBound - clipStart)
                return KeptPiece(range: local, markers: clipMarkers.filter { local.contains($0) })
            }
            result.append(pieces)
            clipStart += duration
        }
        return result
    }
}
