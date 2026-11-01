//
//  ClipTimelineTests.swift
//  HT EditTests
//

import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import HT_Edit

struct ClipTimelineTests {

    private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 1_000) }

    @Test func startsAreCumulative() {
        let starts = ClipTimeline.starts(for: [time(2), time(3), time(1)])
        #expect(starts.map(\.seconds) == [0, 2, 5])
    }

    @Test(arguments: [
        (0.0, 0 as Int?),
        (1.99, 0),
        (2.0, 1),   // a clip owns its start
        (4.5, 1),
        (5.5, 2),
        (6.0, nil), // past the end
        (-1.0, nil),
    ] as [(Double, Int?)])
    func clipIndexAtTime(seconds: Double, expected: Int?) {
        #expect(ClipTimeline.clipIndex(at: time(seconds), durations: [time(2), time(3), time(1)]) == expected)
    }

    @Test func silencesAreShiftedToEachClipsPosition() {
        let a = makeLevels(loud(1) + quiet(0.5) + loud(0.5))   // 2 s, gap 1.0–1.5
        let b = makeLevels(loud(0.5) + quiet(1) + loud(0.5))   // 2 s, gap 0.5–1.5 → 2.5–3.5
        let result = ClipTimeline.silences(levels: [a, b], durations: [a.duration, b.duration], settings: settings())
        #expect(matches(result, [(1, 1.5), (2.5, 3.5)]))
    }

    @Test func silencesTouchingAcrossABoundaryMerge() {
        let a = makeLevels(loud(1) + quiet(1))   // trailing silence 1–2
        let b = makeLevels(quiet(0.5) + loud(1)) // leading silence 0–0.5 → 2–2.5
        let result = ClipTimeline.silences(levels: [a, b], durations: [a.duration, b.duration], settings: settings())
        #expect(matches(result, [(1, 2.5)]))
    }

    @Test func clipEdgesAreNotPadded() {
        let a = makeLevels(loud(1) + quiet(1))
        let b = makeLevels(quiet(1) + loud(1))
        let result = ClipTimeline.silences(
            levels: [a, b], durations: [a.duration, b.duration],
            settings: settings(paddingStart: 0.2, paddingEnd: 0.3)
        )
        // Start padding after speech in A, end padding before speech in B; nothing at the cut.
        #expect(matches(result, [(1.2, 2.7)]))
    }

    @Test func silencesAreClampedToClipDuration() {
        let a = makeLevels(loud(1) + quiet(1))  // audio is 2 s…
        let result = ClipTimeline.silences(levels: [a], durations: [time(1.5)], settings: settings()) // …video only 1.5 s
        #expect(matches(result, [(1, 1.5)]))
    }

    @Test func mergeKeepsSeparateRanges() {
        let ranges = [
            CMTimeRange(start: time(0), end: time(1)),
            CMTimeRange(start: time(1), end: time(2)),
            CMTimeRange(start: time(3), end: time(4)),
        ]
        #expect(matches(ClipTimeline.merged(ranges), [(0, 2), (3, 4)]))
    }

    @Test(arguments: [
        (IndexSet([0]), 3, ["b", "c", "a"]),
        (IndexSet([2]), 0, ["c", "a", "b"]),
        (IndexSet([1]), 1, ["a", "b", "c"]),
        (IndexSet([0, 1]), 3, ["c", "a", "b"]),
    ])
    func moving(offsets: IndexSet, destination: Int, expected: [String]) {
        #expect(ClipTimeline.moving(["a", "b", "c"], fromOffsets: offsets, toOffset: destination) == expected)
    }
}

struct CompositionGeometryTests {

    @Test func portraitPresentationSize() {
        // 1920×1080 recorded sideways (90° rotation) displays as 1080×1920.
        let rotate = CGAffineTransform(rotationAngle: .pi / 2)
        let size = CompositionBuilder.presentationSize(naturalSize: CGSize(width: 1920, height: 1080), transform: rotate)
        #expect(abs(size.width - 1080) < 0.5)
        #expect(abs(size.height - 1920) < 0.5)
    }

    @Test func aspectFitCentersInRenderSize() {
        // Landscape 1920×1080 into a portrait 1080×1920 frame: scaled to 1080 wide, centered vertically.
        let transform = CompositionBuilder.aspectFitTransform(
            naturalSize: CGSize(width: 1920, height: 1080),
            transform: .identity,
            into: CGSize(width: 1080, height: 1920)
        )
        let rect = CGRect(x: 0, y: 0, width: 1920, height: 1080).applying(transform)
        #expect(abs(rect.minX) < 0.5)
        #expect(abs(rect.width - 1080) < 0.5)
        #expect(abs(rect.midY - 960) < 0.5)
    }

    @Test func aspectFitUprightsRotatedVideo() {
        let rotate = CGAffineTransform(rotationAngle: .pi / 2)
        let transform = CompositionBuilder.aspectFitTransform(
            naturalSize: CGSize(width: 1920, height: 1080),
            transform: rotate,
            into: CGSize(width: 1080, height: 1920)
        )
        let rect = CGRect(x: 0, y: 0, width: 1920, height: 1080).applying(transform)
        #expect(abs(rect.minX) < 0.5 && abs(rect.minY) < 0.5)
        #expect(abs(rect.width - 1080) < 0.5 && abs(rect.height - 1920) < 0.5)
    }
}

struct LevelsCacheTests {

    @Test func encodeDecodeRoundTrip() {
        var levels = makeLevels(loud(1) + quiet(0.5))
        levels.peakDB[3] = -1
        let decoded = LevelsCache.decode(LevelsCache.encode(levels))
        #expect(decoded?.rmsDB == levels.rmsDB)
        #expect(decoded?.peakDB == levels.peakDB)
        #expect(decoded?.sampleRate == levels.sampleRate)
        #expect(decoded?.framesPerWindow == levels.framesPerWindow)
        #expect(decoded?.frameCount == levels.frameCount)
        #expect(decoded?.isComplete == true)
    }

    @Test func corruptDataIsRejected() {
        var data = LevelsCache.encode(makeLevels(loud(1)))
        data.removeLast(4)
        #expect(LevelsCache.decode(data) == nil)
        #expect(LevelsCache.decode(Data("nope".utf8)) == nil)
    }

    @Test func storeAndLoad() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "levels-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = LevelsCache(directory: directory)
        let levels = makeLevels(loud(1) + quiet(1))

        #expect(await cache.load(key: "abc") == nil)
        await cache.store(levels, key: "abc")
        #expect(await cache.load(key: "abc")?.rmsDB == levels.rmsDB)
    }

    @Test func keyChangesWhenTheFileChanges() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "key-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("one".utf8).write(to: url)
        let first = try #require(LevelsCache.key(for: url, windowDuration: 0.01))
        #expect(LevelsCache.key(for: url, windowDuration: 0.01) == first)
        #expect(LevelsCache.key(for: url, windowDuration: 0.02) != first)
        try Data("longer content".utf8).write(to: url)
        #expect(LevelsCache.key(for: url, windowDuration: 0.01) != first)
    }

    @Test func missingFileHasNoKey() {
        #expect(LevelsCache.key(for: URL(filePath: "/does/not/exist.mov"), windowDuration: 0.01) == nil)
    }
}
