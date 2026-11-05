//
//  SilenceSettingsPersistenceTests.swift
//  HT EditTests
//

import Foundation
import Testing
@testable import HT_Edit

struct SilenceSettingsPersistenceTests {

    private func freshDefaults() -> UserDefaults {
        let name = "SilenceSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func nothingSavedMeansDefaults() {
        #expect(SilenceSettings.saved(in: freshDefaults()) == .default)
    }

    @Test func savedSettingsComeBack() {
        let defaults = freshDefaults()
        var settings = SilenceSettings.default
        settings.thresholdDB = -42
        settings.paddingStart = 0.25
        settings.paddingEnd = 0.5
        settings.save(to: defaults)
        #expect(SilenceSettings.saved(in: defaults) == settings)
    }

    @Test func outOfRangeValuesAreClamped() {
        let defaults = freshDefaults()
        defaults.set(-500.0, forKey: "silence.thresholdDB")
        defaults.set(9.0, forKey: "silence.paddingStart")
        defaults.set(-1.0, forKey: "silence.paddingEnd")
        let settings = SilenceSettings.saved(in: defaults)
        #expect(settings.thresholdDB == SilenceSettings.thresholdRange.lowerBound)
        #expect(settings.paddingStart == SilenceSettings.paddingRange.upperBound)
        #expect(settings.paddingEnd == SilenceSettings.paddingRange.lowerBound)
    }

    @MainActor
    @Test func theEditorRemembersTheLastSettings() {
        let defaults = freshDefaults()
        let first = EditorViewModel(analyzer: AudioLevelAnalyzer(cache: nil), settingsDefaults: defaults)
        first.settings.thresholdDB = -33
        first.settings.paddingEnd = 0.2

        let second = EditorViewModel(analyzer: AudioLevelAnalyzer(cache: nil), settingsDefaults: defaults)
        #expect(second.settings.thresholdDB == -33)
        #expect(second.settings.paddingEnd == 0.2)
    }
}
