//
//  EditorViewModelTests.swift
//  HT EditTests
//

import CoreMedia
import Testing
@testable import HT_Edit

@MainActor
struct EditorViewModelTests {

    private func makeModel() -> EditorViewModel {
        EditorViewModel(
            levels: makeLevels(loud(1) + quiet(1) + loud(1) + quiet(0.5) + loud(1)),
            settings: settings()
        )
    }

    @Test func detectsSilencesOnInit() {
        let model = makeModel()
        #expect(matches(model.silences, [(1, 2), (3, 3.5)]))
    }

    @Test func thresholdChangeRecomputesImmediately() {
        let model = makeModel()
        model.settings.thresholdDB = -70
        #expect(model.silences.isEmpty)
        model.settings.thresholdDB = -40
        #expect(model.silences.count == 2)
    }

    @Test func paddingSlidersMoveOppositeEdges() {
        let model = makeModel()
        model.settings.paddingStart = 0.1
        #expect(matches(model.silences, [(1.1, 2), (3.1, 3.5)]))
        model.settings.paddingEnd = 0.2
        #expect(matches(model.silences, [(1.1, 1.8), (3.1, 3.3)]))
    }

    @Test func minimumDurationChangeRecomputes() {
        let model = makeModel()
        model.settings.minimumSilenceDuration = 0.8
        #expect(matches(model.silences, [(1, 2)]))
    }

    @Test func statsReflectSilences() {
        let model = makeModel()
        #expect(isClose(model.timelineDuration.seconds, 4.5))
        #expect(isClose(model.totalSilenceDuration.seconds, 1.5))
        #expect(isClose(model.durationWithoutSilences.seconds, 3))
    }

    @Test func resetRestoresDefaults() {
        let model = makeModel()
        model.settings.thresholdDB = -10
        model.resetSettings()
        #expect(model.settings == .default)
    }

    @Test func togglingSkipWithoutMediaIsSafe() {
        let model = makeModel()
        model.skipSilences = true
        model.togglePlayback()
        model.seek(toSeconds: 1)
        #expect(model.hasMedia == false)
        #expect(model.isPlaying == false)
    }
}
