//
//  TranscriptPanel.swift
//  HT Edit
//

import AppKit
import CoreMedia
import SwiftUI

/// Inspector tab: pick a model, add optional context, transcribe, and read
/// the timestamped transcript. Clicking a line jumps the player there.
struct TranscriptPanel: View {
    @Bindable var model: EditorViewModel

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
                    TranscriptRows(
                        segments: segments,
                        activeIndex: TranscriptTimeline.activeIndex(at: model.currentTime.seconds, in: segments)
                    ) { model.seek(toSeconds: $0.start) }
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
                controller.transcribe(model.placedClips)
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

    private var modelSelection: Binding<String> {
        Binding(
            get: { controller.selectedModel.id },
            set: { controller.preferredModelID = $0 }
        )
    }
}

/// The transcript lines. A separate view so playback ticks only redraw the rows.
private struct TranscriptRows: View {
    let segments: [TimelineSegment]
    let activeIndex: Int?
    let onSelect: (TimelineSegment) -> Void

    var body: some View {
        ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
            Button { onSelect(segment) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(TimeFormatting.string(segment.start, fractionDigits: 0))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(segment.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .listRowBackground(index == activeIndex ? Color.accentColor.opacity(0.15) : nil)
            .accessibilityIdentifier("transcriptRow")
        }
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
