//
//  EditorKeyMonitor.swift
//  HT Edit
//

import AppKit
import SwiftUI

/// What a key press does in the editor window.
nonisolated enum EditorKeyCommand: Equatable, Sendable {
    /// Space: play or pause.
    case togglePlayback
    /// M: add a marker at the playhead.
    case addMarker
    /// ⌫ (or ⌦, ⌘⌫): cut the selected transcript words, or restore them.
    case toggleSelectedWords

    static let spaceKeyCode: UInt16 = 49
    static let deleteKeyCode: UInt16 = 51
    static let forwardDeleteKeyCode: UInt16 = 117
    /// Where M sits on an ANSI keyboard; used when the layout types another letter there (Arabic, for one).
    static let mKeyCode: UInt16 = 46

    /// The command for a key press, or `nil` to let it through.
    ///
    /// - Parameters:
    ///   - characters: the characters the key types, ignoring modifiers.
    ///   - isTextInputFocused: a text field is being edited; it gets every key.
    ///   - isListFocused: the clip list has focus; Delete removes clips there.
    ///   - hasWordSelection: transcript words are selected.
    static func command(
        keyCode: UInt16,
        characters: String?,
        modifiers: NSEvent.ModifierFlags,
        isTextInputFocused: Bool,
        isListFocused: Bool,
        hasWordSelection: Bool
    ) -> EditorKeyCommand? {
        guard !isTextInputFocused else { return nil }
        let flags = modifiers.intersection([.command, .option, .control, .shift])
        switch keyCode {
        case spaceKeyCode:
            return flags.isEmpty ? .togglePlayback : nil
        case deleteKeyCode, forwardDeleteKeyCode:
            guard flags.isEmpty || flags == .command, !isListFocused, hasWordSelection else { return nil }
            return .toggleSelectedWords
        default:
            guard flags.isEmpty else { return nil }
            let typed = characters?.lowercased() ?? ""
            // The M key on a layout that doesn't type Latin letters (Arabic, for one).
            let typesOtherScript = !typed.isEmpty && !typed.unicodeScalars.allSatisfy(\.isASCII)
            if typed == "m" || (keyCode == mKeyCode && typesOtherScript) {
                return .addMarker
            }
            return nil
        }
    }
}

/// Handles the editor's single-key shortcuts for its window, whatever has
/// focus (except a text field being edited):
/// - Space plays or pauses, even when a button, picker or list has focus.
/// - M adds a marker.
/// - ⌫ cuts or restores the selected transcript words (Delete still removes
///   clips while the clip list has focus).
///
/// A local event monitor sees key presses before any view, so focused
/// controls can't swallow them.
struct EditorKeyMonitor: NSViewRepresentable {
    let model: EditorViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.model = model
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator {
        var model: EditorViewModel
        weak var view: NSView?
        private var monitor: Any?

        init(model: EditorViewModel) {
            self.model = model
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.handle(event) else { return event }
                return nil
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// Runs the event's command; `true` when it was used up.
        private func handle(_ event: NSEvent) -> Bool {
            guard !event.isARepeat,
                  let window = view?.window,
                  event.window === window,
                  window.attachedSheet == nil,
                  NSApp.modalWindow == nil else { return false }
            let responder = window.firstResponder
            let command = EditorKeyCommand.command(
                keyCode: event.keyCode,
                characters: event.charactersIgnoringModifiers,
                modifiers: event.modifierFlags,
                isTextInputFocused: responder is NSText,
                isListFocused: model.isClipListFocused,
                hasWordSelection: !model.selectedWordIDs.isEmpty
            )
            switch command {
            case .togglePlayback:
                guard model.hasMedia else { return false }
                model.togglePlayback()
            case .addMarker:
                guard model.hasMedia else { return false }
                model.addMarker()
            case .toggleSelectedWords:
                model.toggleSelectedWords()
            case nil:
                return false
            }
            return true
        }
    }
}
