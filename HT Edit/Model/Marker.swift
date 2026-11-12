//
//  Marker.swift
//  HT Edit
//

import Foundation

/// A point the user marked on the timeline (the M key).
///
/// Stored against its clip, so it moves with the clip when clips are
/// reordered and is ready to be written out per clip when exporting.
nonisolated struct Marker: Identifiable, Equatable, Sendable {
    let id: UUID
    var clipID: UUID
    /// Seconds within the clip.
    var clipTime: Double

    init(id: UUID = UUID(), clipID: UUID, clipTime: Double) {
        self.id = id
        self.clipID = clipID
        self.clipTime = clipTime
    }
}
