//
//  FinalCutExportSheet.swift
//  HT Edit
//

import SwiftUI

/// Asks how to build the Final Cut Pro project, then opens it there.
///
/// Captions: the transcript, three words per title, using the title template
/// the user types (Basic Title by default). An adjustment layer (a title
/// template, e.g. a free "Adjustment Layer" title) sits above the captions for
/// the whole length of the video.
struct FinalCutExportSheet: View {
    @Bindable var model: EditorViewModel
    @Environment(\.dismiss) private var dismiss

    @AppStorage("finalCut.removeSilences") private var removeSilences = true
    @AppStorage("finalCut.includeCaptions") private var includeCaptions = true
    @AppStorage("finalCut.captionTitle") private var captionTitleName = TitleTemplates.defaultCaptionTitle
    @AppStorage("finalCut.includeAdjustmentLayer") private var includeAdjustmentLayer = true
    @AppStorage("finalCut.adjustmentLayer") private var adjustmentLayerName = TitleTemplates.defaultAdjustmentLayer

    @State private var installed: [TitleTemplate] = []
    @State private var isExporting = false
    @State private var errorMessage: String?

    private var hasTranscript: Bool { !model.timelineTranscript.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle("Cut out silences", isOn: $removeSilences)
                        .accessibilityIdentifier("finalCutRemoveSilences")
                } header: {
                    Text("Timeline")
                } footer: {
                    Text(removeSilences
                         ? "\(model.silences.count) highlighted silence(s), \(TimeFormatting.string(model.totalSilenceDuration)) in all, are left out."
                         : "Every clip is sent whole.")
                        .foregroundStyle(.secondary)
                }

                Section {
                    if hasTranscript {
                        Toggle("Add the transcript as titles", isOn: $includeCaptions)
                        if includeCaptions {
                            templateField(
                                "Title",
                                text: $captionTitleName,
                                defaultName: TitleTemplates.defaultCaptionTitle,
                                identifier: "finalCutCaptionTitle"
                            )
                        }
                    } else {
                        Text("Transcribe first (Transcript tab) to add captions.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Captions")
                } footer: {
                    if hasTranscript && includeCaptions {
                        Text("Each title shows 3 words. Type the name of a different title if you want one.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Toggle("Add an adjustment layer", isOn: $includeAdjustmentLayer)
                    if includeAdjustmentLayer {
                        templateField(
                            "Name",
                            text: $adjustmentLayerName,
                            defaultName: TitleTemplates.defaultAdjustmentLayer,
                            identifier: "finalCutAdjustmentLayer"
                        )
                    }
                } header: {
                    Text("Adjustment Layer")
                } footer: {
                    if includeAdjustmentLayer {
                        Text("Placed above the captions, covering the entire video.")
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if isExporting { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open in Final Cut Pro") { export() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isExporting || model.placedClips.isEmpty)
                    .accessibilityIdentifier("finalCutOpenButton")
            }
            .padding()
        }
        .frame(width: 460)
        .frame(minHeight: 420)
        .task {
            installed = await Task.detached(priority: .userInitiated) { TitleTemplates.installed() }.value
        }
    }

    @ViewBuilder
    private func templateField(_ label: String, text: Binding<String>, defaultName: String, identifier: String) -> some View {
        HStack {
            TextField(label, text: text, prompt: Text(defaultName))
                .accessibilityIdentifier(identifier)
            Menu {
                ForEach(installed + TitleTemplates.builtIn.values.sorted { $0.name < $1.name }, id: \.uid) { template in
                    Button(template.name) { text.wrappedValue = template.name }
                }
            } label: {
                Image(systemName: "list.bullet")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Choose an installed title")
        }
        templateStatus(TitleTemplates.resolve(name(text.wrappedValue, default: defaultName), installed: installed))
    }

    private func templateStatus(_ template: TitleTemplate) -> some View {
        Group {
            switch template.source {
            case .builtIn:
                Label("Built into Final Cut Pro", systemImage: "checkmark.circle")
            case .installed:
                Label("Found in Motion Templates", systemImage: "checkmark.circle")
            case .notFound:
                Label("“\(template.name)” isn't installed in ~/Movies/Motion Templates. Final Cut will show it as missing until you install it.", systemImage: "exclamationmark.triangle")
            }
        }
        .font(.caption)
        .foregroundStyle(template.source == .notFound ? Color.orange : Color.secondary)
    }

    private func name(_ typed: String, default defaultName: String) -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultName : trimmed
    }

    private func export() {
        let options = FinalCutExportOptions(
            removeSilences: removeSilences,
            includeCaptions: includeCaptions,
            captionTitleName: name(captionTitleName, default: TitleTemplates.defaultCaptionTitle),
            includeAdjustmentLayer: includeAdjustmentLayer,
            adjustmentLayerName: name(adjustmentLayerName, default: TitleTemplates.defaultAdjustmentLayer)
        )
        let clips = model.placedClips
        let silences = model.silences
        let transcript = model.timelineTranscript
        isExporting = true
        errorMessage = nil
        Task {
            defer { isExporting = false }
            do {
                try await FinalCutExporter.open(clips: clips, silences: silences, transcript: transcript, options: options)
                dismiss()
            } catch {
                Log.export.error("Final Cut export failed: \(error.localizedDescription, privacy: .public)")
                errorMessage = error.localizedDescription
            }
        }
    }
}
