//
//  TranscriptPanel.swift
//  HT Edit
//

import AppKit
import SwiftUI

/// Transcript of the timeline: the phrase being spoken is highlighted and
/// follows playback; clicking a phrase jumps there. A summary sits below.
struct TranscriptPanel: View {
    let editor: EditorViewModel
    @Bindable var model: TranscriptionModel
    @State private var isSettingsPresented = false

    var body: some View {
        #if DEBUG
        let _ = BodyTrace.isEnabled ? Self._printChanges() : ()
        #endif
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(12)

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .accessibilityIdentifier("transcriptError")
            }

            Divider()

            if model.hasTranscript {
                PhraseList(editor: editor, model: model)
            } else {
                emptyState
            }

            Divider()

            SummarySection(model: model)
                .padding(12)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if model.isTranscribing {
                Button("Stop", systemImage: "stop.fill") { model.cancelTranscription() }
                ProgressView().controlSize(.small)
                Text(model.progressText ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Button(model.hasTranscript ? "Transcribe Again" : "Transcribe", systemImage: "waveform.and.mic") {
                    editor.transcribe()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.hasClips)
                .help("Transcribe every clip. Clips transcribed before are loaded from the cache without a request.")
                .accessibilityIdentifier("transcribeButton")
            }

            Spacer(minLength: 0)

            Button("Transcription Settings", systemImage: "gearshape") {
                isSettingsPresented.toggle()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Quality, context, captions and API key")
            .popover(isPresented: $isSettingsPresented, arrowEdge: .bottom) {
                TranscriptionSettingsView(model: model)
            }
            .accessibilityIdentifier("transcriptionSettingsButton")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Transcript", systemImage: "text.bubble")
        } description: {
            Text("Press Transcribe to turn speech into text. Each line is highlighted while it plays; click one to jump to it.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The phrases, highlighted and scrolled along with playback.
private struct PhraseList: View {
    let editor: EditorViewModel
    let model: TranscriptionModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.phrases.enumerated()), id: \.element.id) { index, phrase in
                        PhraseRow(phrase: phrase, isActive: index == model.activeIndex) {
                            editor.seek(toSeconds: phrase.start)
                        }
                        .id(phrase.id)
                    }
                }
                .padding(8)
            }
            .onChange(of: model.activeIndex) { _, index in
                guard editor.isPlaying, let index, model.phrases.indices.contains(index) else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(model.phrases[index].id, anchor: .center)
                }
            }
        }
        .accessibilityIdentifier("transcriptList")
    }
}

private struct PhraseRow: View {
    let phrase: TimelinePhrase
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(TimeFormatting.string(phrase.start, fractionDigits: 0))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    .frame(minWidth: 34, alignment: .leading)
                Text(phrase.text)
                    .fontWeight(isActive ? .semibold : .regular)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                isActive ? Color.accentColor.opacity(0.18) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Jump to \(TimeFormatting.string(phrase.start, fractionDigits: 1))")
    }
}

/// On-demand summary of the whole transcript.
private struct SummarySection: View {
    let model: TranscriptionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Summary").font(.headline)
                Spacer()
                if model.isSummarizing {
                    ProgressView().controlSize(.small)
                }
                if let summary = model.summary {
                    Button("Copy Summary", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(summary, forType: .string)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Copy the summary")
                }
                if model.summary == nil {
                    Button("Summarize") {
                        model.summarize()
                    }
                    .disabled(!model.hasTranscript || model.isSummarizing || model.isTranscribing)
                    .help("One request; the summary is cached.")
                    .accessibilityIdentifier("summarizeButton")
                }
            }

            if let summary = model.summary {
                ScrollView {
                    Text(summary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
            } else {
                Text(model.hasTranscript ? "Summarize the transcript with AI." : "Transcribe first to get a summary.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
