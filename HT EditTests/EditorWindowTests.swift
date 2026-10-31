//
//  EditorWindowTests.swift
//  HT EditTests
//
//  Imports into the real editor UI (ContentView in an on-screen window), so
//  rendering, the player view and the timeline run exactly as in the app.
//

import AppKit
import AVFoundation
import SwiftUI
import Testing
@testable import HT_Edit

@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct EditorWindowTests {

    @Test(arguments: [MediaFixtures.Kind.h264Landscape, .portrait])
    func importInTheRealWindowIsFast(kind: MediaFixtures.Kind) async throws {
        let directory = makeTemporaryDirectory("window")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await MediaFixtures.make(kind, in: directory)

        var analyzer = AudioLevelAnalyzer(cache: LevelsCache(directory: directory.appending(path: "cache")))
        analyzer.stallTimeout = .seconds(5)
        let model = EditorViewModel(analyzer: analyzer)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView(model: model))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        if kind == .portrait { setenv("HTEDIT_TRACE_BODIES", "1", 1) }
        defer { unsetenv("HTEDIT_TRACE_BODIES") }

        let clock = ContinuousClock()
        let start = clock.now
        model.add(urls: [url])

        let analyzed = await waitUntil(timeout: .seconds(20)) { !model.isAnalyzing }
        let analyzedAt = clock.now - start
        let ready = await waitUntil(timeout: .seconds(20)) { model.playbackStatus != .preparing && model.playbackStatus != .idle }
        let readyAt = clock.now - start
        print("[window] \(kind.rawValue): analyzed=\(analyzed) after \(analyzedAt), playback=\(model.playbackStatus) after \(readyAt), error=\(model.errorMessage ?? "none")")

        #expect(analyzed, "Analysis didn't finish in the real window")
        #expect(ready, "Playback never left .preparing in the real window")
        #expect(model.playbackStatus == .ready, "Playback: \(model.playbackStatus)")
        #expect(model.errorMessage == nil)
        #expect(analyzedAt < .seconds(5), "Analysis took \(analyzedAt)")
        #expect(readyAt < .seconds(5), "Playback took \(readyAt)")
        #expect(matches(model.silences, [(1, 2)], tolerance: 0.06))
        unsetenv("HTEDIT_TRACE_BODIES")

        // The video layer must actually have a frame to show (not a black layer).
        let playerView = try #require(Self.find(PlayerLayerView.self, in: window.contentView))
        let displayable = await waitUntil(timeout: .seconds(5)) { playerView.playerLayer.isReadyForDisplay }
        print("[window] \(kind.rawValue): layer frame=\(playerView.playerLayer.frame), readyForDisplay=\(playerView.playerLayer.isReadyForDisplay)")
        #expect(displayable, "AVPlayerLayer never became ready for display")
        #expect(playerView.playerLayer.frame.width > 100 && playerView.playerLayer.frame.height > 100)

        // Exercise playback in the window for a moment: it must skip the silence.
        model.seek(toSeconds: 0.8)
        model.togglePlayback()
        let skipped = await waitUntil(timeout: .seconds(5)) { model.currentTime.seconds >= 2 }
        model.togglePlayback()
        #expect(skipped, "Playback didn't pass the silence (at \(model.currentTime.seconds) s)")
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = find(type, in: subview) { return match }
        }
        return nil
    }
}
