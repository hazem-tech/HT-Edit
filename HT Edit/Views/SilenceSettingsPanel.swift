//
//  SilenceSettingsPanel.swift
//  HT Edit
//

import SwiftUI

/// Inspector with the live silence-detection controls.
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
