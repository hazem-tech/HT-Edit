//
//  TranscriptSections.swift
//  HT Edit
//

import AppKit
import CoreMedia
import SwiftUI

/// The inspector below the silence settings: the timestamped transcript,
/// filled in automatically as soon as a clip is imported, and the AI review.
/// Clicking a line's time jumps the player there. A Retry button appears only
/// if transcription failed or was cancelled. Sections only; the inspector's
/// `Form` holds them.
///
/// Every word can be selected and deleted: playback then skips it, cut at the
/// quietest point of the pauses around it. Click a word to select it (and
/// jump there), Shift-click to extend, Command-click to add or remove one, or
/// click a line's empty space to select the whole line. ⌫ cuts the
/// selection, or restores it if it's all cut already.
struct TranscriptSections: View {
    @Bindable var model: EditorViewModel

    private var controller: TranscriptionController { model.transcription }

    var body: some View {
        #if DEBUG
        let _ = BodyTrace.isEnabled ? Self._printChanges() : ()
        #endif
        // Nothing here reads the playhead: only `TranscriptRows` follows it.
        let segments = model.timelineTranscript
        Group {
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
                ReviewControls(model: model, review: model.review, hasTranscript: !segments.isEmpty)
            } header: {
                Text("AI Review")
            } footer: {
                Text("Highlights words in red; rest the pointer on a line to see why. Nothing is cut until you delete words.")
                    .foregroundStyle(.secondary)
            }

            Section {
                if segments.isEmpty {
                    Text(controller.isRunning ? "Transcribing…" : "The transcript appears here automatically.")
                        .foregroundStyle(.secondary)
                } else {
                    editControls
                    TranscriptRows(model: model, segments: segments, lines: TranscriptRows.lines(of: segments, model: model))
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

            Text(selected.isEmpty ? "Click words, or a line's empty space, to select." : "\(selected.count) word\(selected.count == 1 ? "" : "s") selected")
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
    /// A line as shown: which segment, and its time. Worked out where the
    /// playhead isn't read, so playback doesn't redo it 30 times a second.
    struct Line: Identifiable {
        /// The segment's id, so rows keep their identity as lines come and go.
        var id: String
        var index: Int
        var start: Double
        var shownStart: Double
    }

    let model: EditorViewModel
    let segments: [TimelineSegment]
    let lines: [Line]

    /// The lines to show: all of them, or in Clean the ones with words left,
    /// timed by their first kept word.
    static func lines(of segments: [TimelineSegment], model: EditorViewModel) -> [Line] {
        guard model.hidesRemoved else {
            return segments.indices.map { Line(id: segments[$0].id, index: $0, start: segments[$0].start, shownStart: segments[$0].start) }
        }
        let deleted = model.deletedWordIDs
        return segments.indices.compactMap { index in
            let segment = segments[index]
            let first = segment.words.first { !deleted.contains($0.id) }
            guard segment.words.isEmpty || first != nil else { return nil }
            let start = first?.start ?? segment.start
            return Line(id: segment.id, index: index, start: start, shownStart: model.displaySeconds(forSource: start))
        }
    }

    var body: some View {
        let time = model.currentTime.seconds
        let activeIndex = TranscriptTimeline.activeIndex(at: time, in: segments)
        let activeWordID = activeIndex.flatMap { index in
            segments[index].words.first { $0.start <= time && time < $0.end }?.id
        }
        let firstWord = TranscriptRow.firstWordIndices(segments)
        let selection = model.selectedWordIDs
        let deleted = model.deletedWordIDs
        let highlights = model.review.reasons
        let hidesDeleted = model.hidesRemoved
        ForEach(lines) { line in
            let index = line.index
            let segment = segments[index]
            let isActive = index == activeIndex
            TranscriptRow(
                model: model,
                state: TranscriptRow.RowState(
                    segment: segment,
                    firstWord: firstWord[index],
                    isActive: isActive,
                    activeWordID: isActive ? activeWordID : nil,
                    selection: selection,
                    deleted: deleted,
                    highlights: highlights,
                    hidesDeleted: hidesDeleted,
                    start: line.start,
                    shownStart: line.shownStart
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
        /// Why words are highlighted by the AI review (`TimelineWord.id` → reason).
        var highlights: [String: String]
        /// Clean: cut words are left out.
        var hidesDeleted: Bool
        /// Where the line's time jumps to (full timeline seconds), and the
        /// time it shows (edited time, in Clean).
        var start: Double
        var shownStart: Double
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
            Button { model.seek(toSeconds: state.start) } label: {
                Text(TimeFormatting.string(state.shownStart, fractionDigits: 0))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Jump to this line")

            line
                .multilineTextAlignment(rightToLeft ? .trailing : .leading)
                .frame(maxWidth: .infinity, alignment: rightToLeft ? .trailing : .leading)
                // The line's empty space selects the whole line; a word
                // click selects that word (and wins, see `lineClicked`).
                .contentShape(.rect)
                .simultaneousGesture(TapGesture().onEnded { lineClicked() })
                .tint(.primary)
                .environment(\.openURL, OpenURLAction { [model] url in
                    guard url.scheme == Self.scheme, let word = Int(url.host() ?? url.path()) else { return .systemAction }
                    model.lastWordClick = .now
                    let modifiers = NSEvent.modifierFlags
                    model.selectWord(at: word, extending: modifiers.contains(.shift), toggling: modifiers.contains(.command))
                    return .handled
                })
        }
        .modifier(HighlightHover(reasons: tooltip))
    }

    /// A click anywhere on the line. Both it and a word's link see a click on
    /// a word, in either order, so wait a moment: if no word was clicked, the
    /// click was on empty space and selects the whole line.
    private func lineClicked() {
        let clickedAt = ContinuousClock.now
        let segmentID = state.segment.id
        Task { [model] in
            try? await Task.sleep(for: Self.wordClickWindow)
            if let word = model.lastWordClick, word > clickedAt - Self.wordClickWindow * 2 { return }
            model.selectWords(inSegment: segmentID)
        }
    }

    private static let wordClickWindow: Duration = .milliseconds(80)

    /// Why the line's words are highlighted: one “passage”: reason per run of
    /// highlighted words, or `nil` when nothing is.
    private var tooltip: String? {
        guard !state.highlights.isEmpty else { return nil }
        var lines: [String] = []
        var run: [String] = []
        var runReason: String?
        func flush() {
            if let reason = runReason, !run.isEmpty { lines.append("“\(run.joined(separator: " "))”: \(reason)") }
            run = []
            runReason = nil
        }
        for word in state.segment.words {
            if state.hidesDeleted, state.deleted.contains(word.id) { continue }
            let reason = state.highlights[word.id]
            if reason != runReason { flush() }
            if let reason {
                runReason = reason
                run.append(word.text)
            }
        }
        flush()
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private var line: Text {
        let segment = state.segment
        guard !segment.words.isEmpty else { return Text(segment.text) }
        var text = AttributedString()
        var isFirst = true
        for (offset, word) in segment.words.enumerated() {
            let isDeleted = state.deleted.contains(word.id)
            // Clean leaves cut words out altogether.
            if isDeleted, state.hidesDeleted { continue }
            if !isFirst { text += AttributedString(" ") }
            isFirst = false
            var run = AttributedString(word.text)
            // The word's index among all the words, hidden ones included.
            run.link = URL(string: "\(Self.scheme)://\(state.firstWord + offset)")
            let isHighlighted = state.highlights[word.id] != nil
            if isDeleted {
                // Cut words look disabled, like removed parts on the timeline.
                run.strikethroughStyle = Text.LineStyle.single
                run.foregroundColor = Color.primary.opacity(WaveformCanvas.disabledOpacity)
            } else if isHighlighted {
                run.foregroundColor = Color.red
            }
            if state.selection.contains(word.id) {
                run.backgroundColor = Color.accentColor.opacity(0.35)
            } else if word.id == state.activeWordID {
                run.backgroundColor = Color.accentColor.opacity(0.18)
            } else if isHighlighted {
                run.backgroundColor = Color.red.opacity(0.15)
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

/// Shows why a line's words are highlighted, in a small card under the line,
/// as soon as the pointer rests on it. Lines without highlights get nothing,
/// not even hover tracking, so the list scrolls as lightly as before.
private struct HighlightHover: ViewModifier {
    let reasons: String?

    func body(content: Content) -> some View {
        if let reasons {
            content.modifier(HoverCard(text: reasons))
        } else {
            content
        }
    }
}

private struct HoverCard: ViewModifier {
    let text: String
    @State private var isShown = false
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                pending?.cancel()
                if inside {
                    pending = Task {
                        try? await Task.sleep(for: .milliseconds(150))
                        guard !Task.isCancelled else { return }
                        isShown = true
                    }
                } else {
                    isShown = false
                }
            }
            // A popover, not an overlay: list rows can't draw over their neighbors.
            .popover(isPresented: $isShown, arrowEdge: .bottom) {
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 280, alignment: .leading)
                    .padding(10)
                    .accessibilityIdentifier("highlightReason")
            }
    }
}

/// The AI review: a question about the transcript, typed or picked from the
/// presets. The answer highlights words; nothing is cut until they're deleted.
private struct ReviewControls: View {
    let model: EditorViewModel
    @Bindable var review: TranscriptReview
    let hasTranscript: Bool
    /// The field only has focus while it's clicked into: it would otherwise
    /// take the window's first focus, and Space, M and ⌫ go to whatever's
    /// being typed into.
    @FocusState private var isPromptFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TextField("Ask", text: $review.prompt, prompt: Text("Ask about the transcript…"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .focused($isPromptFocused)
                    .onSubmit(run)
                    .onExitCommand { isPromptFocused = false }
                    .onAppear { isPromptFocused = false }
                    .accessibilityIdentifier("reviewPromptField")
                Menu {
                    ForEach(ReviewPreset.allCases) { preset in
                        Button(preset.title) {
                            isPromptFocused = false
                            review.prompt = preset.title
                            model.runReview(preset.instruction)
                        }
                        .accessibilityIdentifier("reviewPreset-\(preset.rawValue)")
                    }
                } label: {
                    Label("Presets", systemImage: "wand.and.stars")
                }
                .menuIndicator(.visible)
                .fixedSize()
                .disabled(!hasTranscript || review.isRunning)
                .help("Ready-made questions: find repetition, pick the best or worst parts, grammar…")
                .accessibilityIdentifier("reviewPresetsMenu")
                if review.isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityIdentifier("reviewProgress")
                    Button("Cancel") { review.cancel() }
                        .controlSize(.small)
                } else {
                    Button("Run", systemImage: "sparkles", action: run)
                        .labelStyle(.iconOnly)
                        .disabled(!canRun)
                        .help("Highlight what this asks for (Return)")
                        .accessibilityIdentifier("reviewRunButton")
                }
            }

            if let error = review.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("reviewError")
            } else if review.answeredInstruction != nil {
                HStack {
                    let count = review.highlights.count
                    Text(count == 0 ? "Nothing found." : "\(count) highlight\(count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("reviewSummary")
                    Spacer()
                    if count > 0 {
                        Button("Select") { model.selectHighlightedWords() }
                            .controlSize(.small)
                            .help("Select every highlighted word, so ⌫ cuts them")
                            .accessibilityIdentifier("reviewSelectButton")
                    }
                    Button("Clear") { review.clear() }
                        .controlSize(.small)
                        .help("Remove the highlights")
                        .accessibilityIdentifier("reviewClearButton")
                }
            }
        }
    }

    private var canRun: Bool {
        hasTranscript && !review.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func run() {
        isPromptFocused = false
        guard canRun else { return }
        model.runReview(ReviewPreset.instruction(for: review.prompt))
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
