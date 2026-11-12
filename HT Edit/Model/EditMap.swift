//
//  EditMap.swift
//  HT Edit
//

import CoreMedia
import Foundation

/// What's left of the timeline once everything playback skips is taken out:
/// the kept pieces, back to back. Maps between the full timeline ("source"
/// time, where the clips sit one after another) and the edited result.
///
/// The Clean layout draws the timeline in edited time, and the FCPXML export
/// writes one clip per kept piece.
nonisolated struct EditMap: Equatable, Sendable {
    /// A stretch of the full timeline that stays in the edit.
    struct Piece: Equatable, Sendable {
        /// Full-timeline seconds.
        var source: Range<Double>
        /// Where the piece starts in the edit, in seconds.
        var editedStart: Double

        var duration: Double { source.upperBound - source.lowerBound }
        var editedEnd: Double { editedStart + duration }
    }

    /// Sorted, non-overlapping, and never empty pieces.
    private(set) var pieces: [Piece]
    /// Length of the edit, in seconds.
    private(set) var editedDuration: Double

    static let empty = EditMap(pieces: [], editedDuration: 0)

    private init(pieces: [Piece], editedDuration: Double) {
        self.pieces = pieces
        self.editedDuration = editedDuration
    }

    /// The parts of `0..<duration` that aren't in `skips` (sorted, non-overlapping).
    init(skips: [CMTimeRange], duration: Double) {
        guard duration.isFinite, duration > 0 else {
            self.init(pieces: [], editedDuration: 0)
            return
        }
        var pieces: [Piece] = []
        var cursor = 0.0
        var edited = 0.0
        func keep(until limit: Double) {
            let upper = min(limit, duration)
            guard upper - cursor > Self.minimumPiece else { return }
            pieces.append(Piece(source: cursor..<upper, editedStart: edited))
            edited += upper - cursor
        }
        for skip in skips where skip.isValid && skip.start.isNumeric && skip.end.isNumeric {
            let start = skip.start.seconds
            let end = skip.end.seconds
            guard end > cursor else { continue }
            if start > cursor { keep(until: start) }
            cursor = max(cursor, end)
            if cursor >= duration { break }
        }
        if cursor < duration { keep(until: duration) }
        self.init(pieces: pieces, editedDuration: edited)
    }

    /// Kept pieces shorter than this (where two removed parts nearly meet) are dropped.
    static let minimumPiece = 0.000_5

    /// Where full-timeline `seconds` lands in the edit. A time inside a removed
    /// part lands where the edit carries on after it.
    func edited(fromSource seconds: Double) -> Double {
        guard seconds.isFinite, !pieces.isEmpty else { return 0 }
        let index = firstIndex(endingAfterSource: seconds)
        guard index < pieces.count else { return editedDuration }
        let piece = pieces[index]
        return piece.editedStart + max(0, seconds - piece.source.lowerBound)
    }

    /// The full-timeline time shown at edited `seconds`.
    func source(fromEdited seconds: Double) -> Double {
        guard seconds.isFinite, let last = pieces.last else { return 0 }
        guard seconds < editedDuration else { return last.source.upperBound }
        let piece = pieces[firstIndex(endingAfterEdited: seconds)]
        return piece.source.lowerBound + max(0, seconds - piece.editedStart)
    }

    /// Index of the first piece ending after full-timeline `seconds` (`pieces.count` if none).
    func firstIndex(endingAfterSource seconds: Double) -> Int {
        var low = 0, high = pieces.count
        while low < high {
            let mid = (low + high) / 2
            if pieces[mid].source.upperBound <= seconds { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Index of the first piece ending after edited `seconds` (`pieces.count` if none).
    func firstIndex(endingAfterEdited seconds: Double) -> Int {
        var low = 0, high = pieces.count
        while low < high {
            let mid = (low + high) / 2
            if pieces[mid].editedEnd <= seconds { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// The kept pieces inside full-timeline `range` (a clip), clipped to it.
    func pieces(within range: Range<Double>) -> [Range<Double>] {
        var result: [Range<Double>] = []
        var index = firstIndex(endingAfterSource: range.lowerBound)
        while index < pieces.count, pieces[index].source.lowerBound < range.upperBound {
            let source = pieces[index].source
            let start = max(source.lowerBound, range.lowerBound)
            let end = min(source.upperBound, range.upperBound)
            if end - start > Self.minimumPiece { result.append(start..<end) }
            index += 1
        }
        return result
    }
}
