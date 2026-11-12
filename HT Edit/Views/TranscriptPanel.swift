//
//  TranscriptPanel.swift
//  HT Edit
//

import AppKit
import CoreMedia
import SwiftUI

/// Inspector tab: pick a model, add optional context, transcribe, and read
/// the timestamped transcript. Clicking a line's time jumps the player there.
///
/// Every word can be selected and deleted: playback then skips it, cut at the
/// quietest point of the pauses around it. Click a word to select it (and
/// jump there), Shift-click to extend, Command-click to add or remove one.
struct TranscriptPanel: View {
    @Bindable var model: EditorViewModel
    @State private var selection: Set<String> = []
    @State private var anchor: Int?

    private var controller: TranscriptionController { model.transcription }

    var body: some View {
        @Bindable var transcription = model.transcription
        let segments = model.timelineTranscript
        Form {
            if let banner = EngineBanner(status: controller.engineStatus) {
                Section {
                    banner
                    Button("Check Again") {
                        Task { await controller.refreshStatus() }
                    }
                    .accessibilityIdentifier("checkAgainButton")
                }
            }

            Section {
                Picker("Model", selection: modelSelection) {
                    ForEach(Array(controller.availableModels.enumerated()), id: \.element.id) { index, option in
                        Text(index == 0 ? "\(option.displayName) (cheapest)" : option.displayName)
                            .tag(option.id)
                    }
                }
                .accessibilityIdentifier("transcriptModelPicker")

                TextField("Context", text: $transcription.context, prompt: Text("Names, terms or spellings (optional)"), axis: .vertical)
                    .lineLimit(2...5)
                    .accessibilityIdentifier("transcriptContextField")
            } header: {
                Text("Transcription")
            } footer: {
                Text("Runs on Antigravity with your Google account. Only models that can transcribe audio with timestamps are listed.")
                    .foregroundStyle(.secondary)
            }

            Section {
                runControls
            }

            Section {
                if segments.isEmpty {
                    Text(controller.isRunning ? "Transcribing…" : "Press Transcribe to get a timestamped transcript.")
                        .foregroundStyle(.secondary)
                } else {
                    editControls(words: segments.flatMap(\.words))
                    TranscriptRows(
                        segments: segments,
                        activeIndex: TranscriptTimeline.activeIndex(at: model.currentTime.seconds, in: segments),
                        time: model.currentTime.seconds,
                        selection: selection,
                        deleted: model.deletedWordIDs,
                        onSelectLine: { model.seek(toSeconds: $0.start) },
                        onSelectWord: { index in select(index, in: segments.flatMap(\.words)) }
                    )
                }
            } header: {
                HStack {
                    Text("Transcript")
                    Spacer()
                    Button("Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(TranscriptTimeline.plainText(segments), forType: .string)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(segments.isEmpty)
                    .help("Copy the transcript with timestamps")
                }
            } footer: {
                if !segments.isEmpty {
                    WordTimingNote(status: controller.wordTimingStatus, failure: controller.wordTimingFailure) {
                        Task { await controller.refreshStatus() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            if controller.engineStatus == .unknown { await controller.refreshStatus() }
        }
    }

    @ViewBuilder
    private var runControls: some View {
        if controller.isRunning {
            HStack {
                ProgressView(value: controller.progress)
                    .accessibilityIdentifier("transcriptProgress")
                Button("Cancel") { controller.cancel() }
            }
        } else {
            Button(model.timelineTranscript.isEmpty ? "Transcribe" : "Transcribe Again", systemImage: "waveform.and.mic") {
                selection = []
                anchor = nil
                model.transcribeAll()
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.placedClips.isEmpty || controller.engineStatus == .checking)
            .accessibilityIdentifier("transcribeButton")
        }

        if case .failed(let message) = controller.phase {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .accessibilityIdentifier("transcriptError")
        }
        if controller.hasFailedChunks, !controller.isRunning {
            VStack(alignment: .leading, spacing: 6) {
                Label("Some parts couldn't be transcribed.", systemImage: "exclamationmark.triangle")
                if let message = controller.lastFailureMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                Button("Retry Failed Parts") { controller.retryFailedChunks(model.placedClips) }
            }
        }
    }

    /// Delete or restore the selected words, and restore everything.
    @ViewBuilder
    private func editControls(words: [TimelineWord]) -> some View {
        let selected = selection.intersection(words.map(\.id))
        let allDeleted = !selected.isEmpty && selected.isSubset(of: model.deletedWordIDs)
        HStack {
            Button(allDeleted ? "Restore" : "Delete", systemImage: allDeleted ? "arrow.uturn.backward" : "scissors") {
                model.toggleDeletion(of: selected)
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(selected.isEmpty)
            .help(allDeleted ? "Put the selected words back (⌘⌫)" : "Cut the selected words: playback skips them (⌘⌫)")
            .accessibilityIdentifier("deleteWordsButton")

            Text(selected.isEmpty ? "Select words to cut them." : "\(selected.count) word\(selected.count == 1 ? "" : "s") selected")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if !model.deletedWordIDs.isEmpty {
                Button("Restore All") { model.restoreAllWords() }
                    .help("Put every deleted word back")
            }
        }
    }

    /// Click: select one word and jump there. Shift: extend from the last
    /// click. Command: add or remove one word.
    private func select(_ index: Int, in words: [TimelineWord]) {
        guard words.indices.contains(index) else { return }
        let id = words[index].id
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.shift), let anchor, words.indices.contains(anchor) {
            selection = Set(words[min(anchor, index)...max(anchor, index)].map(\.id))
        } else if modifiers.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = index
        } else {
            selection = [id]
            anchor = index
            model.seek(toSeconds: words[index].start)
        }
    }

    private var modelSelection: Binding<String> {
        Binding(
            get: { controller.selectedModel.id },
            set: { controller.preferredModelID = $0 }
        )
    }
}

/// The transcript lines. A separate view so playback ticks only redraw the rows.
///
/// Each line is one `Text`, with every word a link: the system lays it out,
/// so Arabic letters join and lines wrap right to left as they should.
private struct TranscriptRows: View {
    let segments: [TimelineSegment]
    let activeIndex: Int?
    /// Playhead, timeline seconds.
    let time: Double
    let selection: Set<String>
    let deleted: Set<String>
    let onSelectLine: (TimelineSegment) -> Void
    /// Index of the clicked word among all the lines' words.
    let onSelectWord: (Int) -> Void

    static let scheme = "htedit-word"

    var body: some View {
        let firstWord = Self.firstWordIndices(segments)
        ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
            let rightToLeft = Self.isRightToLeft(segment.text)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button { onSelectLine(segment) } label: {
                    Text(TimeFormatting.string(segment.start, fractionDigits: 0))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Jump to this line")

                line(segment, firstWord: firstWord[index], isActive: index == activeIndex)
                    .multilineTextAlignment(rightToLeft ? .trailing : .leading)
                    .frame(maxWidth: .infinity, alignment: rightToLeft ? .trailing : .leading)
                    .tint(.primary)
                    .environment(\.openURL, OpenURLAction { url in
                        guard url.scheme == Self.scheme, let word = Int(url.host() ?? url.path()) else { return .systemAction }
                        onSelectWord(word)
                        return .handled
                    })
            }
            .listRowBackground(index == activeIndex ? Color.accentColor.opacity(0.08) : nil)
            .accessibilityIdentifier("transcriptRow")
        }
    }

    private func line(_ segment: TimelineSegment, firstWord: Int, isActive: Bool) -> Text {
        guard !segment.words.isEmpty else { return Text(segment.text) }
        var text = AttributedString()
        for (offset, word) in segment.words.enumerated() {
            if offset > 0 { text += AttributedString(" ") }
            var run = AttributedString(word.text)
            run.link = URL(string: "\(Self.scheme)://\(firstWord + offset)")
            if deleted.contains(word.id) {
                run.strikethroughStyle = Text.LineStyle.single
                run.foregroundColor = Color.secondary
            }
            if selection.contains(word.id) {
                run.backgroundColor = Color.accentColor.opacity(0.35)
            } else if isActive, word.start <= time, time < word.end {
                run.backgroundColor = Color.accentColor.opacity(0.18)
            }
            if word.isApproximate {
                run.underlineStyle = Text.LineStyle(pattern: .dot, color: Color.secondary)
            }
            text += run
        }
        return Text(text)
    }

    /// For each line, the index of its first word among all the lines' words.
    static func firstWordIndices(_ segments: [TimelineSegment]) -> [Int] {
        var starts: [Int] = []
        var total = 0
        for segment in segments {
            starts.append(total)
            total += segment.words.count
        }
        return starts
    }

    /// Whether `text` reads right to left: its first letter is Arabic, Hebrew and the like.
    static func isRightToLeft(_ text: String) -> Bool {
        guard let letter = text.unicodeScalars.first(where: { CharacterSet.letters.contains($0) }) else { return false }
        return (0x0590...0x08FF).contains(letter.value) || (0xFB1D...0xFEFC).contains(letter.value)
    }
}

/// How word times were found, under the transcript.
private struct WordTimingNote: View {
    let status: WordTimingStatus
    let failure: String?
    let checkAgain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch status {
            case .ready:
                Text("Word times are measured on the audio. Cuts land in the quietest point between words.")
            case .notInstalled:
                Text("Word times are estimated (dotted). For exact word times, install uv once: in Terminal, run `brew install uv`, then press Check Again.")
            case .failed(let reason):
                Text("Word times are estimated (dotted): \(reason)")
            case .unknown, .checking:
                EmptyView()
            }
            if let failure {
                Text("Some lines' word times are estimated: \(failure)")
            }
            if status == .notInstalled || status.isFailure {
                Button("Check Again", action: checkAgain)
                    .controlSize(.small)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("wordTimingNote")
    }
}

/// Explains what to do when Antigravity can't be used yet.
private struct EngineBanner: View {
    let title: String
    let message: String
    let showsInstallLink: Bool

    init?(status: EngineStatus) {
        switch status {
        case .notInstalled:
            title = "Antigravity CLI isn't installed"
            message = "Install the Antigravity CLI and sign in once with your Google account. That's the only setup."
            showsInstallLink = true
        case .notSignedIn:
            title = "Sign in to Antigravity"
            message = "Open Terminal, run agy and sign in with your Google account. You only need to do this once."
            showsInstallLink = false
        case .failed(let reason):
            title = "Antigravity isn't responding"
            message = reason
            showsInstallLink = false
        case .unknown, .checking, .ready:
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
            if showsInstallLink, let url = URL(string: "https://antigravity.google") {
                Link("Get Antigravity", destination: url)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("engineBanner")
    }
}

private extension WordTimingStatus {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
