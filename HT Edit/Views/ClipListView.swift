//
//  ClipListView.swift
//  HT Edit
//

import SwiftUI

/// Sidebar listing the clips in timeline order.
/// Drag rows to reorder; right-click ▸ Delete or press Delete to remove.
struct ClipListView: View {
    let model: EditorViewModel
    @State private var selection = Set<Clip.ID>()

    var body: some View {
        List(selection: $selection) {
            Section("Clips") {
                ForEach(model.clips) { clip in
                    ClipRow(clip: clip)
                        .tag(clip.id)
                        .accessibilityIdentifier("clipRow")
                }
                .onMove { offsets, destination in
                    model.moveClips(fromOffsets: offsets, toOffset: destination)
                }
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: Clip.ID.self) { ids in
            if !ids.isEmpty {
                Button(ids.count == 1 ? "Delete Clip" : "Delete \(ids.count) Clips", systemImage: "trash", role: .destructive) {
                    delete(ids)
                }
            }
        }
        .onDeleteCommand {
            delete(selection)
        }
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            guard !selection.isEmpty else { return .ignored }
            delete(selection)
            return .handled
        }
        .accessibilityIdentifier("clipList")
        .overlay {
            if model.clips.isEmpty {
                Text("No clips yet")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func delete(_ ids: Set<Clip.ID>) {
        model.removeClips(ids)
        selection.subtract(ids)
    }
}

private struct ClipRow: View {
    let clip: Clip

    var body: some View {
        HStack(spacing: 10) {
            thumbnail
                .frame(width: 56, height: 36)
                .clipShape(.rect(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(clip.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(clip.isPlaced ? TimeFormatting.string(clip.duration) : "…")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = clip.thumbnail {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFill()
        } else {
            Rectangle()
                .fill(.quaternary)
                .overlay {
                    Image(systemName: clip.presentationSize == .zero ? "waveform" : "film")
                        .foregroundStyle(.secondary)
                }
        }
    }
}
