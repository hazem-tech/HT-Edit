//
//  PlayerView.swift
//  HT Edit
//

import AppKit
import AVFoundation
import SwiftUI

/// Video surface: an `AVPlayerLayer` in a plain view. Apple's recommended
/// approach when the app provides its own transport controls (ours are the
/// timeline and toolbar).
///
/// The view has no intrinsic size and no internal Auto Layout constraints, so
/// it simply fills whatever SwiftUI offers. (`AVPlayerView` fed a constraint
/// update loop with SwiftUI's hosting when a video loaded: AppKit eventually
/// threw "more Update Constraints in Window passes than there are views".)
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PlayerLayerView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 480, height: proposal.height ?? 270)
    }
}

final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Video")
        setAccessibilityIdentifier("playerView")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func layout() {
        super.layout()
        // Resize without the implicit animation.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}
