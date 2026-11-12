//
//  InspectorView.swift
//  HT Edit
//

import SwiftUI

/// The editor's inspector, all in one place: the silence settings on top,
/// then the transcript (with the AI review) below them.
struct InspectorView: View {
    @Bindable var model: EditorViewModel

    var body: some View {
        Form {
            SilenceSections(model: model)
            TranscriptSections(model: model)
        }
        .formStyle(.grouped)
        .task {
            let controller = model.transcription
            if controller.engineStatus == .unknown { await controller.refreshStatus() }
        }
    }
}
