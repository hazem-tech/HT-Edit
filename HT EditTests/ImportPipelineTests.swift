//
//  ImportPipelineTests.swift
//  HT EditTests
//
//  End-to-end: real generated media → EditorViewModel.add(urls:) → playback
//  ready, a visible (non-black) video frame, analysis finished, silences found.
//  These cover the "black video" and "Analyzing audio… forever" bugs.
//

import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import HT_Edit

@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct ImportPipelineTests {

    /// A model whose analysis uses a private cache directory and fast stall detection.
    private func makeModel(cacheDirectory: URL) -> EditorViewModel {
        var analyzer = AudioLevelAnalyzer(cache: LevelsCache(directory: cacheDirectory))
        analyzer.stallTimeout = .seconds(5)
        return EditorViewModel(analyzer: analyzer)
    }

    private func waitForImport(_ model: EditorViewModel, expectingVideo: Bool) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let finished = await waitUntil(timeout: .seconds(20)) {
            !model.isAnalyzing && (!expectingVideo || model.playbackStatus != .preparing)
        }
        print("Import finished=\(finished) in \(clock.now - start): status=\(model.playbackStatus), analyzing=\(model.isAnalyzing), error=\(model.errorMessage ?? "none")")
        #expect(finished, "Import didn't finish: analyzing=\(model.isAnalyzing), playback=\(model.playbackStatus)")
        #expect(model.errorMessage == nil)
    }

    @Test(arguments: [MediaFixtures.Kind.h264Landscape, .hevcMP4, .portrait])
    func importedVideoPlaysAndIsAnalyzed(kind: MediaFixtures.Kind) async throws {
        let directory = makeTemporaryDirectory("import")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await MediaFixtures.make(kind, in: directory)
        let model = makeModel(cacheDirectory: directory.appending(path: "cache"))

        model.add(urls: [url])
        try await waitForImport(model, expectingVideo: true)

        // Clip placed with the right duration and orientation.
        let clip = try #require(model.clips.first)
        #expect(isClose(clip.duration.seconds, 3, tolerance: 0.05))
        #expect(clip.presentationSize == kind.presentationSize)
        #expect(model.isPortrait == (kind == .portrait))

        // Playback ready.
        #expect(model.playbackStatus == .ready)
        let item = try #require(model.player.currentItem)
        #expect(item.status == .readyToPlay)

        // The composition renders real frames, not black.
        let color = try await Self.averageColor(of: item, at: CMTime(value: 1, timescale: 2))
        print("\(kind.rawValue) frame color: \(color)")
        #expect(color.green > 0.5, "Expected the green fixture frame, got \(color)")
        #expect(color.green > color.red && color.green > color.blue)

        // Audio analyzed: the 1–2 s gap is the only silence.
        #expect(!model.lanes.isEmpty)
        #expect(model.levels(for: clip.id).isComplete)
        #expect(!model.levels(for: clip.id).rmsDB.contains(AudioLevels.unanalyzed))
        #expect(matches(model.silences, [(1, 2)], tolerance: 0.06), "silences: \(seconds(model.silences))")
    }

    @Test func audioOnlyFileFinishesAnalyzing() async throws {
        let directory = makeTemporaryDirectory("import-audio")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await MediaFixtures.make(.audioOnly, in: directory)
        let model = makeModel(cacheDirectory: directory.appending(path: "cache"))

        model.add(urls: [url])
        try await waitForImport(model, expectingVideo: false)

        #expect(model.clips.first?.presentationSize == .zero)
        #expect(!model.isPortrait)
        #expect(matches(model.silences, [(1, 2)], tolerance: 0.06), "silences: \(seconds(model.silences))")
    }

    @Test func twoClipsMakeOneSeamlessTimeline() async throws {
        let directory = makeTemporaryDirectory("import-two")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try await MediaFixtures.make(.h264Landscape, in: directory)
        let second = try await MediaFixtures.make(.hevcMP4, in: directory)
        let model = makeModel(cacheDirectory: directory.appending(path: "cache"))

        model.add(urls: [first, second])
        try await waitForImport(model, expectingVideo: true)
        #expect(await waitUntil { model.playbackStatus == .ready })

        #expect(model.clips.count == 2)
        #expect(isClose(model.timelineDuration.seconds, 6, tolerance: 0.1))
        #expect(model.lanes.map(\.start).count == 2)
        #expect(matches(model.silences, [(1, 2), (4, 5)], tolerance: 0.1), "silences: \(seconds(model.silences))")

        let item = try #require(model.player.currentItem)
        let itemDuration = try await item.asset.load(.duration)
        #expect(isClose(itemDuration.seconds, 6, tolerance: 0.1))
        let color = try await Self.averageColor(of: item, at: CMTime(seconds: 4.5, preferredTimescale: 600))
        #expect(color.green > 0.5, "second clip frame: \(color)")

        // Delete the first clip: the second one moves to the start.
        model.removeClips([model.clips[0].id])
        #expect(await waitUntil { model.playbackStatus == .ready })
        #expect(isClose(model.timelineDuration.seconds, 3, tolerance: 0.05))
        #expect(matches(model.silences, [(1, 2)], tolerance: 0.06))
        let remaining = try await #require(model.player.currentItem).asset.load(.duration)
        #expect(isClose(remaining.seconds, 3, tolerance: 0.1))
    }

    @Test func mixedOrientationsStillRender() async throws {
        let directory = makeTemporaryDirectory("import-mixed")
        defer { try? FileManager.default.removeItem(at: directory) }
        let portrait = try await MediaFixtures.make(.portrait, in: directory)
        let landscape = try await MediaFixtures.make(.h264Landscape, in: directory)
        let model = makeModel(cacheDirectory: directory.appending(path: "cache"))

        model.add(urls: [portrait, landscape])
        try await waitForImport(model, expectingVideo: true)
        #expect(await waitUntil { model.playbackStatus == .ready })

        #expect(model.isPortrait)
        let item = try #require(model.player.currentItem)
        #expect(item.videoComposition != nil)
        let inPortrait = try await Self.averageColor(of: item, at: CMTime(value: 1, timescale: 2))
        let inLandscape = try await Self.averageColor(of: item, at: CMTime(seconds: 3.5, preferredTimescale: 600))
        #expect(inPortrait.green > 0.5, "portrait frame: \(inPortrait)")
        // Landscape is letterboxed inside the portrait frame, so less of it is green.
        #expect(inLandscape.green > 0.1, "landscape frame: \(inLandscape)")
    }

    @Test func reimportIsServedFromCache() async throws {
        let directory = makeTemporaryDirectory("import-cache")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await MediaFixtures.make(.h264Landscape, in: directory)
        let cache = directory.appending(path: "cache")

        let firstModel = makeModel(cacheDirectory: cache)
        firstModel.add(urls: [url])
        try await waitForImport(firstModel, expectingVideo: true)

        let clock = ContinuousClock()
        let start = clock.now
        let secondModel = makeModel(cacheDirectory: cache)
        secondModel.add(urls: [url])
        try await waitForImport(secondModel, expectingVideo: true)
        let elapsed = clock.now - start
        print("Cached re-import took \(elapsed)")
        #expect(matches(secondModel.silences, [(1, 2)], tolerance: 0.06))
        #expect(elapsed < .seconds(3))
    }

    // MARK: Helpers

    /// Average color (0…1 per channel) of the frame the player item would show at `time`.
    static func averageColor(of item: AVPlayerItem, at time: CMTime) async throws -> (red: Double, green: Double, blue: Double) {
        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.videoComposition = item.videoComposition
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 64, height: 64)
        let image = try await generator.image(at: time).image

        let context = CIContext(options: [.workingColorSpace: NSNull()])
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: input,
            kCIInputExtentKey: CIVector(cgRect: input.extent),
        ]), let output = filter.outputImage else {
            throw MediaFixtures.FixtureError.setup("CIAreaAverage")
        }
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
    }
}
