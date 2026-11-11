//
//  SettingsView.swift
//  HT Edit
//
//  The Settings window (HT Edit ▸ Settings…, ⌘,). For now it holds one thing:
//  the instructions Gemini follows when it cleans up a transcript.
//

import SwiftUI

struct SettingsView: View {
    @AppStorage(CleanupInstructions.defaultsKey) private var instructions = CleanupInstructions.defaultText

    private var isDefault: Bool {
        instructions.trimmingCharacters(in: .whitespacesAndNewlines) == CleanupInstructions.defaultText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cleanup Instructions")
                .font(.headline)
            Text("What Gemini is told when it proofreads Whisper's transcript. HT Edit adds your context, the second Whisper reading, the transcript lines and the reply format after these instructions. Changes apply to the next transcription.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $instructions)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.background, in: .rect(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                .accessibilityIdentifier("cleanupInstructionsEditor")

            HStack {
                if instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label("Empty instructions use the default.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Restore Default") { instructions = CleanupInstructions.defaultText }
                    .disabled(isDefault)
                    .accessibilityIdentifier("restoreDefaultInstructionsButton")
            }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 680, minHeight: 420, idealHeight: 520)
    }
}
