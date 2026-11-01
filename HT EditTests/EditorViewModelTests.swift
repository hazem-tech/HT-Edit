//
//  EditorViewModelTests.swift
//  HT EditTests
//

import CoreMedia
import Foundation
import Testing
@testable import HT_Edit

@MainActor
struct EditorViewModelTests {

    private func makeModel() -> EditorViewModel {
        EditorViewModel(
            analyzedClips: [
                makeClip(loud(1) + quiet(1) + loud(1), name: "a"),   // 3 s, gap 1–2
                makeClip(loud(0.5) + quiet(0.5) + loud(1), name: "b"), // 2 s, gap 0.5–1 → 3.5–4
            ],
            settings: settings()
        )
    }

    @Test func clipsFormOneSeamlessTimeline() {
        let model = makeModel()
        #expect(isClose(model.timelineDuration.seconds, 5))
        #expect(model.lanes.map(\.start) == [0, 3])
        #expect(matches(model.silences, [(1, 2), (3.5, 4)]))
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
        #expect(matches(model.silences, [(1.1, 2), (3.6, 4)]))
        model.settings.paddingEnd = 0.2
        #expect(matches(model.silences, [(1.1, 1.8), (3.6, 3.8)]))
    }

    @Test func reorderingMovesSilences() {
        let model = makeModel()
        model.moveClips(fromOffsets: IndexSet([1]), toOffset: 0)
        #expect(model.clips.map(\.name) == ["b", "a"])
        #expect(model.lanes.map(\.start) == [0, 2])
        #expect(matches(model.silences, [(0.5, 1), (3, 4)]))
    }

    @Test func removingClipsUpdatesTheTimeline() {
        let model = makeModel()
        let first = model.clips[0].id
        model.removeClips([first])
        #expect(model.clips.map(\.name) == ["b"])
        #expect(isClose(model.timelineDuration.seconds, 2))
        #expect(matches(model.silences, [(0.5, 1)]))

        model.removeClips(Set(model.clips.map(\.id)))
        #expect(!model.hasMedia)
        #expect(model.silences.isEmpty)
        #expect(model.playbackStatus == .idle)
    }

    @Test func removingNothingIsHarmless() {
        let model = makeModel()
        model.removeClips([])
        model.removeClips([UUID()])
        #expect(model.clips.count == 2)
    }

    @Test func defaultsMatchTheSpec() {
        let model = EditorViewModel(analyzedClips: [])
        #expect(model.settings.thresholdDB == -70)
        #expect(model.settings.paddingStart == 0)
        #expect(model.settings.paddingEnd == 0)
        #expect(!model.hasMedia)
    }

    @Test func orientationFollowsTheFirstVideo() {
        var portrait = makeClip(loud(1), name: "p")
        portrait.clip.presentationSize = CGSize(width: 1080, height: 1920)
        var landscape = makeClip(loud(1), name: "l")
        landscape.clip.presentationSize = CGSize(width: 1920, height: 1080)

        #expect(EditorViewModel(analyzedClips: [portrait, landscape]).isPortrait)
        #expect(!EditorViewModel(analyzedClips: [landscape, portrait]).isPortrait)
        #expect(!EditorViewModel(analyzedClips: []).isPortrait)
    }

    @Test func squareIsNotPortrait() {
        var square = makeClip(loud(1))
        square.clip.presentationSize = CGSize(width: 1080, height: 1080)
        #expect(!EditorViewModel(analyzedClips: [square]).isPortrait)
    }

    @Test func transportWithoutMediaIsSafe() {
        let model = EditorViewModel(analyzedClips: [])
        model.togglePlayback()
        model.seek(toSeconds: 1)
        #expect(model.isPlaying == false)
    }
}
