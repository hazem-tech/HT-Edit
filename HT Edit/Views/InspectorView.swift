//
//  InspectorView.swift
//  HT Edit
//

import SwiftUI

/// The inspector column: silence settings or the transcript.
struct InspectorView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case silence, transcript

        var id: String { rawValue }

        var title: String {
            switch self {
            case .silence: "Silence"
            case .transcript: "Transcript"
            }
        }
    }

    let model: EditorViewModel
    @AppStorage("inspectorTab") private var tab: Tab = .silence

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .accessibilityIdentifier("inspectorTabs")

            Divider()

            switch tab {
            case .silence:
                SilenceSettingsPanel(model: model)
            case .transcript:
                TranscriptPanel(editor: model, model: model.transcription)
            }
        }
    }
}
