//
//  FinalCutExportSheet.swift
//  HT Edit
//

import os
import SwiftUI

/// Asks which title to use for the captions, then opens the timeline in
/// Final Cut Pro: the clips, Final Cut's adjustment clip over the whole video,
/// and the transcript as centered titles of 3 words each on top.
struct FinalCutExportSheet: View {
    @Bindable var model: EditorViewModel
    @Environment(\.dismiss) private var dismiss

    @AppStorage("finalCut.captionTitle") private var captionTitle = TitleTemplates.defaultCaptionTitle

    @State private var installed: [TitleTemplate] = []
    @State private var isInfoPresented = false
    @State private var isExporting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open in Final Cut Pro")
                .font(.headline)

            HStack {
                TextField("Title", text: $captionTitle, prompt: Text(TitleTemplates.defaultCaptionTitle))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(export)
                    .accessibilityIdentifier("finalCutCaptionTitle")
                Button("About the title", systemImage: "info.circle") { isInfoPresented.toggle() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Type a title's name or its path")
                    .popover(isPresented: $isInfoPresented, arrowEdge: .trailing) { info }
                    .accessibilityIdentifier("finalCutTitleInfo")
            }

            status(TitleTemplates.resolve(captionTitle, installed: installed))

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                if isExporting { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open in Final Cut Pro", action: export)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isExporting || model.placedClips.isEmpty)
                    .accessibilityIdentifier("finalCutOpenButton")
            }
        }
        .padding(20)
        .frame(width: 420)
        .task {
            installed = await Task.detached(priority: .userInitiated) { TitleTemplates.installed() }.value
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Caption title").font(.headline)
            Text("Type the name of a title, such as Basic Title, or the path to its .moti file or folder. HT Edit finds it in Final Cut's titles and in ~/Movies/Motion Templates.")
            Text("The transcript is split into titles of 3 words each, centered. An adjustment clip covers the whole video, between the video and the titles.")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .frame(width: 280, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding()
    }

    private func status(_ template: TitleTemplate) -> some View {
        Group {
            switch template.source {
            case .builtIn:
                Label("“\(template.name)” is built into Final Cut Pro.", systemImage: "checkmark.circle")
            case .installed:
                Label("Found “\(template.name)” in Motion Templates.", systemImage: "checkmark.circle")
            case .outsideMotionTemplates:
                Label("Final Cut only loads titles from ~/Movies/Motion Templates. Move “\(template.name)” there.", systemImage: "exclamationmark.triangle")
            case .notFound:
                Label("Couldn't find “\(template.name)”. Final Cut will show it as missing.", systemImage: "exclamationmark.triangle")
            }
        }
        .font(.caption)
        .foregroundStyle(template.source == .builtIn || template.source == .installed ? Color.secondary : Color.orange)
        .accessibilityIdentifier("finalCutTitleStatus")
    }

    private func export() {
        guard !isExporting, !model.placedClips.isEmpty else { return }
        let clips = model.placedClips
        let transcript = model.timelineTranscript
        let title = captionTitle
        isExporting = true
        errorMessage = nil
        Task {
            defer { isExporting = false }
            do {
                try await FinalCutExporter.open(clips: clips, transcript: transcript, captionTitle: title)
                dismiss()
            } catch {
                Log.export.error("Final Cut export failed: \(error.localizedDescription, privacy: .public)")
                errorMessage = error.localizedDescription
            }
        }
    }
}
