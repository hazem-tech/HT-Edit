//
//  ContentView.swift
//  HT Edit
//
//  Created by Hazem on 10/31/26.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var model = EditorViewModel()
    @State private var isImporterPresented = false
    @State private var isInspectorPresented = true
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ClipListView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            Group {
                if model.hasMedia {
                    editor
                } else {
                    emptyState
                }
            }
            .inspector(isPresented: inspectorBinding) {
                SilenceSettingsPanel(model: model)
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
            }
        }
        .navigationTitle("HT Edit")
        .toolbar { toolbar }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.audiovisualContent],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): model.add(urls: urls)
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls: urls.filter(Self.isMediaFile))
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
            Label("Import Videos", systemImage: "film.stack")
        } description: {
            Text("Drop videos here or choose them to import. Silences are highlighted automatically.")
        } actions: {
            Button("Import Videos…") { isImporterPresented = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("importButton")
        }
    }

    /// Vertical video sits beside the timeline; landscape video sits above it.
    @ViewBuilder
    private var editor: some View {
        if model.isPortrait {
            HSplitView {
                PlayerView(player: model.player)
                    .frame(minWidth: 200, idealWidth: 340)
                timelinePane
                    .frame(minWidth: 420)
            }
        } else {
            VSplitView {
                PlayerView(player: model.player)
                    .frame(minHeight: 220)
                timelinePane
                    .frame(minHeight: 230)
            }
        }
    }

    private var timelinePane: some View {
        VStack(alignment: .leading, spacing: 10) {
            transportBar
            WaveformTimelineView(model: model)
        }
        .padding()
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
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Import", systemImage: "plus") {
                isImporterPresented = true
            }
            .keyboardShortcut("o")
            .help("Add videos to the timeline (⌘O)")

            Button(model.isPlaying ? "Pause" : "Play", systemImage: model.isPlaying ? "pause.fill" : "play.fill") {
                model.togglePlayback()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!model.hasMedia)
            .help("Play / Pause (Space)")

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
