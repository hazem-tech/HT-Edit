//
//  InspectorView.swift
//  HT Edit
//

import SwiftUI

/// The editor's inspector: silence settings or the transcript.
struct InspectorView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case silence = "Silence"
        case transcript = "Transcript"

        var id: Self { self }
    }

    @Bindable var model: EditorViewModel
    @State private var tab = Tab.silence

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 12)
            .padding(.bottom, 4)
            .accessibilityIdentifier("inspectorTabs")

            switch tab {
            case .silence: SilenceSettingsPanel(model: model)
            case .transcript: TranscriptPanel(model: model)
            }
        }
    }
}
