//
//  ContentView.swift
//  HT Edit
//
//  Created by Hazem on 10/31/26.
//

import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var model = EditorViewModel()
    @State private var isImporterPresented = false
    @State private var isInspectorPresented = true

    var body: some View {
        Group {
            if model.hasMedia {
                editor
            } else {
                emptyState
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .navigationTitle(model.fileName ?? "HT Edit")
        .toolbar { toolbar }
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.audiovisualContent]) { result in
            switch result {
            case .success(let url): model.load(url: url)
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: Self.isMediaFile) else { return }
            model.load(url: url)
        }
        .inspector(isPresented: inspectorBinding) {
            SilenceSettingsPanel(model: model)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: Sections

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Import a Video", systemImage: "film.stack")
        } description: {
            Text("Drop a video here or choose one to import. Silences are highlighted automatically.")
        } actions: {
            Button("Import Video…") { isImporterPresented = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("importButton")
        }
    }

    private var editor: some View {
        VSplitView {
            VideoPlayer(player: model.player)
                .frame(minHeight: 220)

            VStack(alignment: .leading, spacing: 10) {
                transportBar
                WaveformTimelineView(model: model)
            }
            .padding()
            .frame(minHeight: 230)
        }
    }

    private var transportBar: some View {
        HStack(spacing: 12) {
            Button(model.isPlaying ? "Pause" : "Play", systemImage: model.isPlaying ? "pause.fill" : "play.fill") {
                model.togglePlayback()
            }
            .labelStyle(.iconOnly)
            .accessibilityIdentifier("playPauseButton")

            Text("\(TimeFormatting.string(model.currentTime, fractionDigits: 2)) / \(TimeFormatting.string(model.timelineDuration, fractionDigits: 2))")
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Spacer()

            Text("\(model.silences.count) silences · \(TimeFormatting.string(model.totalSilenceDuration)) total")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Import", systemImage: "square.and.arrow.down") {
                isImporterPresented = true
            }
            .keyboardShortcut("o")
            .help("Import a video (⌘O)")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button(model.isPlaying ? "Pause" : "Play", systemImage: model.isPlaying ? "pause.fill" : "play.fill") {
                model.togglePlayback()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!model.hasMedia)
            .help("Play / Pause (Space)")

            Toggle("Skip Silences", systemImage: "forward.end.alt", isOn: $model.skipSilences)
                .disabled(!model.hasMedia)
                .help("Skip highlighted silences during playback")

            Button("Inspector", systemImage: "sidebar.trailing") {
                isInspectorPresented.toggle()
            }
            .disabled(!model.hasMedia)
            .help("Show or hide silence settings")
        }
    }

    // MARK: Helpers

    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: { isInspectorPresented && model.hasMedia },
            set: { isInspectorPresented = $0 }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

    private static func isMediaFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audiovisualContent)
    }
}

#Preview {
    ContentView()
}
