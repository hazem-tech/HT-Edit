//
//  InspectorView.swift
//  HT Edit
//

import SwiftUI

enum InspectorTab: Hashable {
    case silence
    case transcript
}

/// The inspector: silence settings and the Arabic transcript, as tabs.
struct InspectorView: View {
    let model: EditorViewModel
    let speechModels: SpeechModelStore
    @Binding var tab: InspectorTab
    @Binding var isModelPickerPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $tab) {
                Text("Silence").tag(InspectorTab.silence)
                Text("Transcript").tag(InspectorTab.transcript)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.top, 10)
            .accessibilityIdentifier("inspectorTabs")

            switch tab {
            case .silence:
                SilenceSettingsPanel(model: model)
            case .transcript:
                TranscriptPanel(model: model, speechModels: speechModels, isModelPickerPresented: $isModelPickerPresented)
            }
        }
    }
}
