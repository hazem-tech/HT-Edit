//
//  PlaybackKeyMonitor.swift
//  HT Edit
//

import AppKit
import SwiftUI

/// App-wide transport keys: Space plays/pauses, J slows down, L speeds up.
///
/// A local event monitor sees every key press in the app before any view, so
/// the keys work wherever focus is (sidebar, inspector, timeline, nothing) and
/// are consumed, which means AppKit never plays its "can't do that" beep.
/// Keys pass through untouched while text is being edited (so the transcript
/// context field still gets spaces, j and l), and in panels and sheets such as
/// the open panel.
enum PlaybackKey: Equatable {
    case playPause
    case slower
    case faster

    /// The transport key for a key press, or `nil` if it isn't one.
    init?(characters: String?, modifiers: NSEvent.ModifierFlags) {
        let relevant = modifiers.intersection([.command, .control, .option, .shift, .function])
        guard relevant.isEmpty else { return nil }
        switch characters?.lowercased() {
        case " ": self = .playPause
        case "j": self = .slower
        case "l": self = .faster
        default: return nil
        }
    }

    /// Whether key presses in `window` should be left alone.
    static func passesThrough(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        if window is NSPanel || window.attachedSheet != nil { return true }
        return window.firstResponder is NSText
    }
}

private struct PlaybackKeyMonitorModifier: ViewModifier {
    let model: EditorViewModel
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear(perform: install)
            .onDisappear(perform: remove)
    }

    private func install() {
        guard monitor == nil else { return }
        let model = model
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let characters = event.charactersIgnoringModifiers
            let modifiers = event.modifierFlags
            let isRepeat = event.isARepeat
            let windowNumber = event.windowNumber
            let consumed = MainActor.assumeIsolated {
                guard let key = PlaybackKey(characters: characters, modifiers: modifiers),
                      !PlaybackKey.passesThrough(in: NSApp.window(withWindowNumber: windowNumber))
                else { return false }
                if !isRepeat { Self.handle(key, model: model) }
                return true
            }
            return consumed ? nil : event
        }
    }

    private func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private static func handle(_ key: PlaybackKey, model: EditorViewModel) {
        switch key {
        case .playPause: model.togglePlayback()
        case .slower: model.stepPlaybackRate(by: -1)
        case .faster: model.stepPlaybackRate(by: 1)
        }
    }
}

extension View {
    /// Handles Space / J / L for `model` anywhere in the app (see `PlaybackKey`).
    func playbackKeys(for model: EditorViewModel) -> some View {
        modifier(PlaybackKeyMonitorModifier(model: model))
    }
}
