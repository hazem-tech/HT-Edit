//
//  SilenceSettingsPanel.swift
//  HT Edit
//

import SwiftUI

/// Inspector with the live silence-detection controls and resulting stats.
struct SilenceSettingsPanel: View {
    @Bindable var model: EditorViewModel

    var body: some View {
        Form {
            Section("Detection") {
                SettingSlider(
                    "Threshold",
                    value: $model.settings.thresholdDB,
                    in: SilenceSettings.thresholdRange,
                    step: 1,
                    help: "Audio quieter than this level is treated as silence."
                ) { "\(Int($0.rounded())) dB" }
                .accessibilityIdentifier("thresholdSlider")

                SettingSlider(
                    "Minimum silence",
                    value: $model.settings.minimumSilenceDuration,
                    in: SilenceSettings.minimumSilenceDurationRange,
                    step: 0.05,
                    help: "Shorter pauses are left alone."
                ) { Self.milliseconds($0) }
                .accessibilityIdentifier("minimumSilenceSlider")
            }

            Section("Padding") {
                SettingSlider(
                    "Padding start",
                    value: $model.settings.paddingStart,
                    in: SilenceSettings.paddingRange,
                    step: 0.01,
                    help: "Audio kept after speech ends, at the start of each silence."
                ) { Self.milliseconds($0) }
                .accessibilityIdentifier("paddingStartSlider")

                SettingSlider(
                    "Padding end",
                    value: $model.settings.paddingEnd,
                    in: SilenceSettings.paddingRange,
                    step: 0.01,
                    help: "Audio kept before speech resumes, at the end of each silence."
                ) { Self.milliseconds($0) }
                .accessibilityIdentifier("paddingEndSlider")
            }

            Section("Playback") {
                Toggle("Skip silences while playing", isOn: $model.skipSilences)
                    .accessibilityIdentifier("skipSilencesToggle")
            }

            Section("Result") {
                LabeledContent("Silences found", value: model.silences.count, format: .number)
                LabeledContent("Total silence", value: TimeFormatting.string(model.totalSilenceDuration))
                LabeledContent("Original length", value: TimeFormatting.string(model.timelineDuration))
                LabeledContent("Without silences", value: TimeFormatting.string(model.durationWithoutSilences))
            }

            Section {
                Button("Reset to Defaults", systemImage: "arrow.counterclockwise") {
                    model.resetSettings()
                }
                .disabled(model.settings == .default)
            }
        }
        .formStyle(.grouped)
        .monospacedDigit()
    }

    static func milliseconds(_ seconds: Double) -> String {
        "\(Int((seconds * 1000).rounded())) ms"
    }
}

/// A titled slider with a live value readout.
private struct SettingSlider: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let help: LocalizedStringKey
    let display: (Double) -> String

    init(
        _ title: LocalizedStringKey,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double,
        help: LocalizedStringKey,
        display: @escaping (Double) -> String
    ) {
        self.title = title
        self._value = value
        self.range = range
        self.step = step
        self.help = help
        self.display = display
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                Text(display(value))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step) {
                Text(title)
            }
            .labelsHidden()
        }
        .help(help)
    }
}
