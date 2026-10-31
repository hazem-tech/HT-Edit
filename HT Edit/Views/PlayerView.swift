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
        view.player = player
        view.setAccessibilityIdentifier("playerView")
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }
}
