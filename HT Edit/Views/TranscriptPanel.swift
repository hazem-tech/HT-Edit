//
//  TranscriptPanel.swift
//  HT Edit
//

import AppKit
import CoreMedia
import SwiftUI

/// Inspector tab: set up Whisper once, add an optional context, transcribe, and
/// read the timestamped transcript. Clicking a line jumps the player there.
/// The pipeline itself is fixed (see `TranscriptionController`).
struct TranscriptPanel: View {
    @Bindable var model: EditorViewModel

    private var controller: TranscriptionController { model.transcription }

    var body: some View {
        @Bindable var transcription = model.transcription
        let segments = model.timelineTranscript
        Form {
            if let banner = WhisperBanner(status: controller.engineStatus) {
                Section {
                    banner
                    if controller.engineStatus == .needsSetup, controller.canSetUp {
                        if controller.isSettingUp {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Setting up Whisper… The first time downloads about 1.7 GB.")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Button("Set Up Whisper", systemImage: "arrow.down.circle") {
                                Task { await controller.setUpWhisper() }
                            }
                            .accessibilityIdentifier("setUpWhisperButton")
                        }
                    }
                    if let error = controller.setupError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    Button("Check Again") {
                        Task { await controller.refreshStatus() }
                    }
                    .disabled(controller.isSettingUp)
                    .accessibilityIdentifier("checkAgainButton")
                }
            }

            Section {
                TextField("Context", text: $transcription.context, prompt: Text("Optional: topic, names, terms, the way you say them"), axis: .vertical)
                    .lineLimit(2...5)
                    .accessibilityIdentifier("transcriptContextField")
                if let detected = controller.detectedContext, controller.context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    LabeledContent("Topic found") {
                        Text(detected).textSelection(.enabled)
                    }
                    .font(.caption)
                    .accessibilityIdentifier("detectedContext")
                }
                if controller.hasCleaner {
                    Picker("Cleanup model", selection: modelSelection) {
                        ForEach(Array(controller.availableModels.enumerated()), id: \.element.id) { index, option in
                            Text(index == 0 ? "\(option.displayName) (cheapest)" : option.displayName)
                                .tag(option.id)
                        }
                    }
                    .accessibilityIdentifier("transcriptModelPicker")
                    if let problem = CleanupProblem(status: controller.cleanupStatus) {
                        problem
                    }
                }
            } header: {
                Text("Transcription")
            } footer: {
                Text("Arabic speech, with English words kept as spoken. Whisper transcribes on this Mac, twice: without and with the context. Gemini, through Antigravity with your Google account, works out the topic when the context is empty and fixes misheard words. It keeps your dialect and never changes timestamps or drops lines.")
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
            if let step = controller.stepDescription {
                Text(step)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("transcriptStep")
            }
        } else {
            Button(model.timelineTranscript.isEmpty ? "Transcribe" : "Transcribe Again", systemImage: "waveform.and.mic") {
                controller.transcribe(model.placedClips)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.placedClips.isEmpty || controller.engineStatus == .checking || controller.engineStatus == .needsSetup)
            .accessibilityIdentifier("transcribeButton")
        }

        if let note = controller.cleanupNote, !controller.isRunning {
            Label(note, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("cleanupNote")
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

/// Explains what to do when Whisper can't be used yet.
private struct WhisperBanner: View {
    let title: String
    let message: String

    init?(status: EngineStatus) {
        switch status {
        case .needsSetup:
            title = "Set up Whisper"
            message = "Whisper transcribes on this Mac. Setting it up installs a small Python environment and the large-v3-turbo model (about 1.7 GB, once)."
        case .failed(let reason):
            title = "Whisper isn't available"
            message = reason
        case .notInstalled, .notSignedIn, .unknown, .checking, .ready:
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "waveform.badge.exclamationmark")
                .font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("engineBanner")
    }
}

/// Explains why Antigravity can't clean up yet; transcription still works without it.
private struct CleanupProblem: View {
    let message: String
    let showsInstallLink: Bool

    init?(status: EngineStatus) {
        switch status {
        case .notInstalled:
            message = "Install the Antigravity CLI and sign in once with your Google account to turn on cleanup."
            showsInstallLink = true
        case .notSignedIn:
            message = "Open Terminal, run agy and sign in with your Google account. You only need to do this once."
            showsInstallLink = false
        case .failed(let reason):
            message = reason
            showsInstallLink = false
        case .unknown, .checking, .ready, .needsSetup:
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
            if showsInstallLink, let url = URL(string: "https://antigravity.google") {
                Link("Get Antigravity", destination: url).font(.caption)
            }
        }
        .accessibilityIdentifier("cleanupProblem")
    }
}
