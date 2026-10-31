//
//  ContentView.swift
//  HT Edit
//
//  Created by Hazem on 10/31/26.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var model: EditorViewModel
    @State private var isImporterPresented = false
    @State private var isInspectorPresented = true
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    init(model: EditorViewModel = EditorViewModel()) {
        _model = State(initialValue: model)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ClipListView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            // Toolbar, file importer and alert live inside the detail column:
            // presentations attached outside a split view's columns may never show on macOS.
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
            .alert("Something went wrong", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
        .navigationTitle("HT Edit")
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls: urls.filter(Self.isMediaFile))
        }
        #if DEBUG
        .task { await UITestSupport.importFixtureIfRequested(into: model) }
        #endif
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
    ///
    /// Plain SwiftUI stacks (not `HSplitView`/`VSplitView`): the split views host
    /// their panes in AppKit constraint-based hosting views, which fed a layout
    /// loop with the timeline once media loaded.
    @ViewBuilder
    private var editor: some View {
        if model.isPortrait {
            HStack(spacing: 0) {
                PlayerView(player: model.player)
                    .frame(minWidth: 220, idealWidth: 340, maxWidth: 420, maxHeight: .infinity)
                Divider()
                timelinePane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            VStack(spacing: 0) {
                PlayerView(player: model.player)
                    .frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
                Divider()
                timelinePane
                    .frame(maxWidth: .infinity)
                    .frame(height: 280)
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
            Button("Add Videos", systemImage: "plus") {
                isImporterPresented = true
            }
            .keyboardShortcut("o")
            .help("Add videos to the timeline (⌘O)")
            .accessibilityIdentifier("addButton")

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
