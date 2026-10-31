//
//  ClipListView.swift
//  HT Edit
//

import SwiftUI

/// Sidebar listing the clips in timeline order. Drag rows to reorder.
struct ClipListView: View {
    let model: EditorViewModel

    var body: some View {
        List {
            Section("Clips") {
                ForEach(model.clips) { clip in
                    ClipRow(clip: clip)
                }
                .onMove { offsets, destination in
                    model.moveClips(fromOffsets: offsets, toOffset: destination)
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("clipList")
        .overlay {
            if model.clips.isEmpty {
                Text("No clips yet")
                    .foregroundStyle(.secondary)
            }
        }
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
