//
//  Clip.swift
//  HT Edit
//

import CoreGraphics
import CoreMedia
import Foundation

/// One imported media file placed on the timeline.
struct Clip: Identifiable {
    let id: UUID
    let url: URL
    var name: String
    /// `.zero` until the asset's duration has loaded; such clips aren't placed yet.
    var duration: CMTime = .zero
    /// Display size with the track's rotation applied; `.zero` for audio-only files.
    var presentationSize: CGSize = .zero
    var levels: AudioLevels = .empty
    var isAnalyzing = true
    var thumbnail: CGImage?

    init(id: UUID = UUID(), url: URL, name: String? = nil, duration: CMTime = .zero, levels: AudioLevels = .empty) {
        self.id = id
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.duration = duration
        self.levels = levels
    }

    var isPlaced: Bool { duration.isNumeric && duration > .zero }
    var isPortrait: Bool { presentationSize.height > presentationSize.width }
}

/// What the waveform needs to draw one clip.
nonisolated struct ClipLane: Equatable, Sendable, Identifiable {
    var id: UUID
    /// Timeline position, in seconds.
    var start: Double
    var duration: Double
    var levels: AudioLevels
}
