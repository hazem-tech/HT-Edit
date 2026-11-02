//
//  TranscriptionSettingsView.swift
//  HT Edit
//

import SwiftUI

/// Popover with the transcription options: quality, optional context and key
/// words, captions, and the Gemini API key.
struct TranscriptionSettingsView: View {
    @Bindable var model: TranscriptionModel
    @State private var keyDraft = ""

    var body: some View {
        Form {
            Section("Quality") {
                Picker("Quality", selection: $model.settings.tier) {
                    ForEach(TranscriptionTier.allCases) { tier in
                        Text(tier.title).tag(tier)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("transcriptionTierPicker")

                Text(model.settings.tier.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                TextField("What is this video about? Who is speaking?", text: $model.settings.context, axis: .vertical)
                    .lineLimit(2...5)
                    .accessibilityIdentifier("transcriptionContextField")
                TextField("Names and terms, separated by commas", text: $model.settings.keywords, axis: .vertical)
                    .lineLimit(1...3)
                    .accessibilityIdentifier("transcriptionKeywordsField")
            } header: {
                Text("Context (optional)")
            } footer: {
                Text(contextFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Video") {
                Toggle("Show captions on the video", isOn: $model.settings.showsCaptions)
            }

            Section {
                SecureField("Paste your API key", text: $keyDraft)
                    .onSubmit(saveKey)
                    .accessibilityIdentifier("apiKeyField")
                HStack {
                    Text(keyStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if model.keySource == .custom {
                        Button("Use Default Key") {
                            keyDraft = ""
                            model.setCustomAPIKey("")
                        }
                    }
                    Button("Save", action: saveKey)
                        .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines) == (model.customAPIKey ?? ""))
                }
            } header: {
                Text("Gemini API key")
            } footer: {
                Link("Get a free key at aistudio.google.com", destination: URL(string: "https://aistudio.google.com/apikey")!)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .frame(width: 360, height: 560)
        .onAppear {
            model.loadKeyIfNeeded()
            keyDraft = model.customAPIKey ?? ""
        }
    }

    private var contextFooter: String {
        if model.settings.tier == .low {
            return model.settings.hasContext
                ? "Context is set: after speech-to-text, one extra request fixes names and terms. Timings stay the same."
                : "Empty: one request per clip. Add context or key words to fix names and terms (one extra request)."
        }
        return "Used when the transcript is polished. Timings stay the same."
    }

    private var keyStatus: String {
        switch model.keySource {
        case .custom: "Using your key."
        case .bundled: "Using the default key."
        case .none: "No key yet. Paste one to transcribe."
        }
    }

    private func saveKey() {
        model.setCustomAPIKey(keyDraft)
    }
}
