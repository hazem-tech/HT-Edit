//
//  SpeechModelPickerView.swift
//  HT Edit
//

import Foundation
import SwiftUI

/// Lists every Arabic speech model that runs offline and gives timestamps.
/// The user downloads the ones they want to try and picks one to use.
struct SpeechModelPickerView: View {
    let store: SpeechModelStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding()
            Divider()
            content
            Divider()
            footer
                .padding()
        }
        .frame(minWidth: 560, idealWidth: 600, minHeight: 520, idealHeight: 640)
        .task { await store.refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Arabic Speech Models")
                .font(.title2.bold())
            Text("Only models that run offline on this Mac, understand Arabic and give timestamps are listed. Download the ones you want to try, then choose one to use.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        if store.allModels.isEmpty {
            switch store.catalogState {
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't Load Models", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await store.refresh() } }
                }
                .frame(maxHeight: .infinity)
            default:
                ProgressView("Loading models…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            List {
                Section {
                    ForEach(store.whisperModels) { model in
                        SpeechModelRow(model: model, store: store)
                    }
                    if store.catalogState == .loading {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                    }
                } header: {
                    Text("Whisper – Hugging Face")
                } footer: {
                    Text("OpenAI Whisper converted to Core ML by Argmax (argmaxinc/whisperkit-coreml). English-only models are hidden.")
                }

                Section {
                    if store.appleModels.isEmpty {
                        Text("Not available: Apple's on-device speech model on this Mac doesn't support Arabic.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.appleModels) { model in
                            SpeechModelRow(model: model, store: store)
                        }
                    }
                } header: {
                    Text("Apple On-Device")
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private var footer: some View {
        HStack {
            if let message = store.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if case .failed = store.catalogState, !store.allModels.isEmpty {
                Label("Offline: showing downloaded models only.", systemImage: "wifi.slash")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("speechModelsDoneButton")
        }
    }
}

/// One model: select it, download it (with progress) or delete it.
private struct SpeechModelRow: View {
    let model: SpeechModel
    let store: SpeechModelStore

    var body: some View {
        let isDownloaded = store.isDownloaded(model)
        let isSelected = store.selectedModelID == model.id && isDownloaded
        HStack(alignment: .top, spacing: 12) {
            Button {
                store.selectedModelID = model.id
            } label: {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .imageScale(.large)
                    .foregroundStyle(isDownloaded ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!isDownloaded)
            .help(isDownloaded ? "Use this model" : "Download this model first")
            .accessibilityLabel(isSelected ? "Selected" : "Select")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.displayName).font(.headline)
                    if model.isRecommended { Badge("Recommended", color: .green) }
                    if isDownloaded { Badge("Downloaded", color: .blue) }
                }
                Text(model.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Label("Arabic", systemImage: "checkmark")
                    Label("Timestamps", systemImage: "checkmark")
                    Label("Offline", systemImage: "checkmark")
                    if let size = model.sizeMB {
                        Text(Self.sizeText(megabytes: size))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)
            action(isDownloaded: isDownloaded)
                .frame(minWidth: 110, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("speechModel-\(model.variant)")
    }

    @ViewBuilder
    private func action(isDownloaded: Bool) -> some View {
        if store.isPreparing(model) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Preparing…").font(.caption).foregroundStyle(.secondary)
            }
        } else if store.isDownloading(model) {
            HStack(spacing: 6) {
                ProgressView(value: store.downloadProgress[model.id] ?? 0)
                    .frame(width: 80)
                Button("Cancel", systemImage: "xmark.circle.fill") { store.cancelDownload(model) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Cancel download")
            }
        } else if isDownloaded {
            Button(model.engine == .apple ? "Remove" : "Delete", systemImage: "trash", role: .destructive) {
                store.delete(model)
            }
            .help(model.engine == .apple ? "Release this model to macOS" : "Delete the downloaded files")
        } else {
            Button("Download", systemImage: "arrow.down.circle") { store.download(model) }
                .accessibilityIdentifier("download-\(model.variant)")
        }
    }

    static func sizeText(megabytes: Int) -> String {
        megabytes >= 1_000
            ? String(format: "%.1f GB", Double(megabytes) / 1_000)
            : "\(megabytes) MB"
    }
}

private struct Badge: View {
    let title: LocalizedStringKey
    let color: Color

    init(_ title: LocalizedStringKey, color: Color) {
        self.title = title
        self.color = color
    }

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: .capsule)
            .foregroundStyle(color)
    }
}
