//
//  PlayerView.swift
//  HT Edit
//

import AVKit
import SwiftUI

/// AVKit's `AVPlayerView` with its built-in controls turned off: Apple's
/// supported way to put a player on screen in AppKit. Transport and scrubbing
/// live in the timeline.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.allowsPictureInPicturePlayback = false
        // Never let the video's own size (e.g. 1920 px wide) drive the layout.
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            view.setContentHuggingPriority(.init(1), for: orientation)
            view.setContentCompressionResistancePriority(.init(1), for: orientation)
        }
        view.player = player
        view.setAccessibilityIdentifier("playerView")
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }

    /// Fill exactly the space SwiftUI offers. `AVPlayerView` otherwise reports
    /// the video's natural size, which pushed the whole editor wider than the
    /// window and re-laid out the split views when a video loaded.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AVPlayerView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 480, height: proposal.height ?? 270)
    }
}
