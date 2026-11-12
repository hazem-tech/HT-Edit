//
//  TranscriptPanel.swift
//  HT Edit
//

import AppKit
import CoreMedia
import SwiftUI

/// Inspector tab: the timestamped transcript, filled in automatically as
/// soon as a clip is imported. Clicking a line's time jumps the player there.
/// A Retry button appears only if transcription failed or was cancelled.
///
/// Every word can be selected and deleted: playback then skips it, cut at the
/// quietest point of the pauses around it. Click a word to select it (and
/// jump there), Shift-click to extend, Command-click to add or remove one.
/// ⌫ cuts the selection, or restores it if it's all cut already.
struct TranscriptPanel: View {
    @Bindable var model: EditorViewModel

    private var controller: TranscriptionController { model.transcription }

    var body: some View {
        #if DEBUG
        let _ = BodyTrace.isEnabled ? Self._printChanges() : ()
        #endif
        // Nothing here reads the playhead: only `TranscriptRows` follows it.
        let segments = model.timelineTranscript
        Form {
            if let banner = EngineBanner(status: controller.engineStatus) {
                Section {
                    banner
                    Button("Check Again") {
                        Task {
                            await controller.refreshStatus()
                            if case .ready = controller.engineStatus, controller.needsRetry(for: model.placedClips) {
                                model.retryTranscription()
                            }
                        }
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
            } header: {
                Text("Transcription")
            } footer: {
                Text("Clips are transcribed automatically on Antigravity, with your Google account. Only models that can transcribe audio with timestamps are listed; picking another one transcribes again.")
                    .foregroundStyle(.secondary)
            }

            if controller.isRunning || controller.needsRetry(for: model.placedClips) {
                Section {
                    runControls
                }
            }

            Section {
                if segments.isEmpty {
                    Text(controller.isRunning ? "Transcribing…" : "The transcript appears here automatically.")
                        .foregroundStyle(.secondary)
                } else {
                    editControls
                    TranscriptRows(model: model, segments: segments)
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

    /// Progress while transcribing; otherwise why it stopped, and Retry.
    @ViewBuilder
    private var runControls: some View {
        if controller.isRunning {
            HStack {
                ProgressView(value: controller.progress)
                    .accessibilityIdentifier("transcriptProgress")
                Button("Cancel") { controller.cancel() }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if let message = failureMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("transcriptError")
                }
                if controller.hasFailedChunks, let detail = controller.lastFailureMessage {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Button("Retry", systemImage: "arrow.clockwise") { model.retryTranscription() }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.engineStatus == .checking)
                    .accessibilityIdentifier("transcriptRetryButton")
            }
        }
    }

    private var failureMessage: String? {
        switch controller.phase {
        case .failed(let message): message
        case .cancelled: "Transcription was cancelled."
        default: controller.hasFailedChunks ? "Some parts couldn't be transcribed." : "Transcription didn't finish."
        }
    }

    /// Delete or restore the selected words, and restore everything.
    @ViewBuilder
    private var editControls: some View {
        let selected = model.selectedWordIDs
        let allDeleted = !selected.isEmpty && selected.isSubset(of: model.deletedWordIDs)
        HStack {
            Button(allDeleted ? "Restore" : "Delete", systemImage: allDeleted ? "arrow.uturn.backward" : "scissors") {
                model.toggleSelectedWords()
            }
            .disabled(selected.isEmpty)
            .help(allDeleted ? "Put the selected words back (⌫)" : "Cut the selected words: playback skips them (⌫)")
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

    private var modelSelection: Binding<String> {
        Binding(
            get: { controller.selectedModel.id },
            set: { controller.preferredModelID = $0 }
        )
    }
}

/// The transcript lines. The only part of the tab that follows the playhead:
/// each tick it finds the active line and word, and only rows whose inputs
/// changed are drawn again.
private struct TranscriptRows: View {
    let model: EditorViewModel
    let segments: [TimelineSegment]

    var body: some View {
        let time = model.currentTime.seconds
        let activeIndex = TranscriptTimeline.activeIndex(at: time, in: segments)
        let activeWordID = activeIndex.flatMap { index in
            segments[index].words.first { $0.start <= time && time < $0.end }?.id
        }
        let firstWord = TranscriptRow.firstWordIndices(segments)
        let selection = model.selectedWordIDs
        let deleted = model.deletedWordIDs
        ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
            let isActive = index == activeIndex
            TranscriptRow(
                model: model,
                state: TranscriptRow.RowState(
                    segment: segment,
                    firstWord: firstWord[index],
                    isActive: isActive,
                    activeWordID: isActive ? activeWordID : nil,
                    selection: selection,
                    deleted: deleted
                )
            )
            .equatable()
            .listRowBackground(isActive ? Color.accentColor.opacity(0.08) : nil)
            .accessibilityIdentifier("transcriptRow")
        }
    }
}

/// One transcript line.
///
/// One `Text`, with every word a link: the system lays it out, so Arabic
/// letters join and lines wrap right to left as they should.
private struct TranscriptRow: View, Equatable {
    /// Everything the row draws; rows are only redrawn when it changes.
    nonisolated struct RowState: Equatable, Sendable {
        var segment: TimelineSegment
        /// Index of the line's first word among all the lines' words.
        var firstWord: Int
        var isActive: Bool
        /// The word being spoken, on the active line only.
        var activeWordID: String?
        var selection: Set<String>
        var deleted: Set<String>
    }

    let model: EditorViewModel
    let state: RowState

    static let scheme = "htedit-word"

    nonisolated static func == (lhs: TranscriptRow, rhs: TranscriptRow) -> Bool {
        lhs.state == rhs.state
    }

    var body: some View {
        let segment = state.segment
        let rightToLeft = Self.isRightToLeft(segment.text)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button { model.seek(toSeconds: segment.start) } label: {
                Text(TimeFormatting.string(segment.start, fractionDigits: 0))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Jump to this line")

            line
                .multilineTextAlignment(rightToLeft ? .trailing : .leading)
                .frame(maxWidth: .infinity, alignment: rightToLeft ? .trailing : .leading)
                .tint(.primary)
                .environment(\.openURL, OpenURLAction { [model] url in
                    guard url.scheme == Self.scheme, let word = Int(url.host() ?? url.path()) else { return .systemAction }
                    let modifiers = NSEvent.modifierFlags
                    model.selectWord(at: word, extending: modifiers.contains(.shift), toggling: modifiers.contains(.command))
                    return .handled
                })
        }
    }

    private var line: Text {
        let segment = state.segment
        guard !segment.words.isEmpty else { return Text(segment.text) }
        var text = AttributedString()
        for (offset, word) in segment.words.enumerated() {
            if offset > 0 { text += AttributedString(" ") }
            var run = AttributedString(word.text)
            run.link = URL(string: "\(Self.scheme)://\(state.firstWord + offset)")
            if state.deleted.contains(word.id) {
                // Cut words look disabled, like removed parts on the timeline.
                run.strikethroughStyle = Text.LineStyle.single
                run.foregroundColor = Color.primary.opacity(WaveformCanvas.disabledOpacity)
            }
            if state.selection.contains(word.id) {
                run.backgroundColor = Color.accentColor.opacity(0.35)
            } else if word.id == state.activeWordID {
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
