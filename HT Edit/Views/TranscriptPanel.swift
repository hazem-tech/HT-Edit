//
//  TranscriptPanel.swift
//  HT Edit
//

import CoreMedia
import Foundation
import SwiftUI

/// Inspector tab with the Arabic transcript: timed segments, words that seek
/// when clicked, and the line being spoken highlighted during playback.
struct TranscriptPanel: View {
    let model: EditorViewModel
    let speechModels: SpeechModelStore
    @Binding var isModelPickerPresented: Bool

    var body: some View {
        #if DEBUG
        let _ = BodyTrace.isEnabled ? Self._printChanges() : ()
        #endif
        let lines = model.transcriptLines
        VStack(spacing: 0) {
            controls
                .padding()
            Divider()
            if lines.isEmpty {
                emptyState
            } else {
                TranscriptList(lines: lines, currentTime: model.currentTime.seconds) { seconds in
                    model.seek(toSeconds: seconds)
                }
            }
        }
        .task { await speechModels.refreshLocal() }
    }

    // MARK: Controls

    private var controls: some View {
        let transcription = model.transcription
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .foregroundStyle(.secondary)
                Text(speechModels.selectedModel?.displayName ?? String(localized: "No model selected"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(speechModels.selectedModel == nil ? .secondary : .primary)
                Spacer()
                Button("Models…") { isModelPickerPresented = true }
                    .accessibilityIdentifier("transcriptModelsButton")
            }

            if case .running(let completed, let total) = transcription.status {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(total > 1 ? "Transcribing clip \(min(completed + 1, total)) of \(total)…" : "Transcribing…")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop") { transcription.cancel() }
                }
            } else {
                Button("Transcribe Arabic", systemImage: "text.bubble") { startTranscription() }
                    .buttonStyle(.borderedProminent)
                    .disabled(speechModels.selectedModel == nil || !model.hasMedia)
                    .help("Turn the speech in every clip into timed Arabic text, on this Mac")
                    .accessibilityIdentifier("transcribeButton")
            }

            if case .failed(let message) = transcription.status {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let name = transcription.modelName, !transcription.isRunning, !model.transcriptLines.isEmpty {
                Text("Transcribed with \(name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if speechModels.selectedModel == nil {
            ContentUnavailableView {
                Label("No Speech Model", systemImage: "arrow.down.circle")
            } description: {
                Text("Download an Arabic model to transcribe locally on this Mac.")
            } actions: {
                Button("Choose a Model…") { isModelPickerPresented = true }
            }
        } else if model.transcription.isRunning {
            ContentUnavailableView(
                "Transcribing…",
                systemImage: "waveform",
                description: Text("Text appears here as each clip finishes.")
            )
        } else if model.transcription.status == .finished {
            ContentUnavailableView(
                "No Speech Found",
                systemImage: "waveform.slash",
                description: Text("The model didn't recognize any speech in these clips.")
            )
        } else {
            ContentUnavailableView(
                "No Transcript Yet",
                systemImage: "text.bubble",
                description: Text("Click Transcribe Arabic to turn speech into timed text.")
            )
        }
    }

    private func startTranscription() {
        guard let selected = speechModels.selectedModel else { return }
        model.transcribe(with: speechModels.engine(for: selected), modelName: selected.displayName)
    }
}

/// The segments, scrolling to follow playback.
private struct TranscriptList: View {
    let lines: [TranscriptLine]
    let currentTime: Double
    let seek: (Double) -> Void

    var body: some View {
        let currentIndex = TranscriptTimeline.lineIndex(at: currentTime, in: lines)
        ScrollViewReader { proxy in
            List {
                ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                    TranscriptRow(
                        segment: line.segment,
                        currentTime: index == currentIndex ? currentTime : nil,
                        seek: seek
                    )
                    .id(line.id)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .onChange(of: currentIndex) { _, newIndex in
                guard let newIndex, lines.indices.contains(newIndex) else { return }
                withAnimation { proxy.scrollTo(lines[newIndex].id, anchor: .center) }
            }
        }
        .accessibilityIdentifier("transcriptList")
    }
}

private struct TranscriptRow: View {
    let segment: TranscriptSegment
    /// Playhead time when this is the line being spoken, otherwise `nil`.
    let currentTime: Double?
    let seek: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                seek(segment.start)
            } label: {
                Text("\(TimeFormatting.string(segment.start)) – \(TimeFormatting.string(segment.end))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Jump to this line")

            Text(Self.attributedText(for: segment, currentTime: currentTime))
                .font(.title3)
                .tint(.primary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.layoutDirection, .rightToLeft)
                .environment(\.openURL, OpenURLAction { url in
                    if let seconds = TranscriptLink.seconds(from: url) { seek(seconds) }
                    return .handled
                })
                .textSelection(.enabled)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(currentTime != nil ? Color.accentColor.opacity(0.15) : .clear, in: .rect(cornerRadius: 6))
    }

    /// Each word links to its start time; the word being spoken is bold.
    static func attributedText(for segment: TranscriptSegment, currentTime: Double?) -> AttributedString {
        guard !segment.words.isEmpty else { return AttributedString(segment.text) }
        var text = AttributedString()
        for (index, word) in segment.words.enumerated() {
            if index > 0 { text += AttributedString(" ") }
            var piece = AttributedString(word.text)
            piece.link = TranscriptLink.url(seconds: word.start)
            if let time = currentTime, word.start <= time, time < word.end {
                piece.inlinePresentationIntent = .stronglyEmphasized
            }
            text += piece
        }
        return text
    }
}
