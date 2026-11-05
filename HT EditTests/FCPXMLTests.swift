//
//  FCPXMLTests.swift
//  HT EditTests
//

import Foundation
import Testing
@testable import HT_Edit

struct FCPXMLTests {

    private func media(_ name: String, duration: Double, rate: FrameRate = .fps30) -> FCPXML.Media {
        FCPXML.Media(
            url: URL(filePath: "/tmp/\(name).mov"),
            name: name,
            duration: duration,
            hasVideo: true,
            hasAudio: true,
            width: 1920,
            height: 1080,
            frameRate: rate,
            audioChannels: 2,
            audioRate: 48_000
        )
    }

    private let basicTitle = TitleTemplates.resolve("Basic Title", installed: [])
    private let adjustment = TitleTemplate(name: "Adjustment Layer", uid: "~/Titles.localized/Adjustment Layer/Adjustment Layer.moti", source: .installed)

    // MARK: Frame rates

    @Test(arguments: [
        (nominal: 29.97, expected: FrameRate.fps29_97),
        (nominal: 30.0, expected: FrameRate.fps30),
        (nominal: 23.98, expected: FrameRate.fps23_976),
        (nominal: 59.94, expected: FrameRate.fps59_94),
        (nominal: 0.0, expected: FrameRate.fps30),
    ])
    func standardRates(nominal: Double, expected: FrameRate) {
        #expect(FrameRate.standard(nominal: nominal) == expected)
    }

    @Test func timesAreWholeFrames() {
        #expect(FrameRate.fps29_97.time(0) == "0s")
        #expect(FrameRate.fps29_97.time(30) == "30030/30000s")
        #expect(FrameRate.fps30.time(1) == "100/3000s")
    }

    // MARK: Word groups

    @Test func linesAreSplitIntoThreeWordTitles() {
        let lines = [FCPXML.Caption(start: 2, end: 8, text: "one two three four five six seven")]
        let groups = FCPXML.wordGroups(lines, wordsPerTitle: 3)
        #expect(groups.map(\.text) == ["one two three", "four five six", "seven"])
        #expect(groups.first?.start == 2)
        #expect(isClose(groups.last?.end ?? 0, 8))
        // Back to back, no gaps.
        for (a, b) in zip(groups, groups.dropFirst()) { #expect(isClose(a.end, b.start)) }
        // The single word is on screen for less time than three words.
        #expect(groups[2].end - groups[2].start < groups[0].end - groups[0].start)
    }

    @Test func emptyLinesAreSkipped() {
        #expect(FCPXML.wordGroups([FCPXML.Caption(start: 0, end: 1, text: "   ")], wordsPerTitle: 3).isEmpty)
    }

    // MARK: Cutting silences

    @Test func silencesAreCutOut() {
        let pieces = FCPXML.pieces(media: [media("a", duration: 10)], silences: [2..<4], rate: .fps30)
        #expect(pieces.map(\.sourceStart) == [0, 120])
        #expect(pieces.map(\.duration) == [60, 180])
        #expect(pieces.map(\.offset) == [0, 60])
    }

    @Test func clipsAreBackToBackAndSilencesAcrossTheBoundarySplitBoth() {
        let pieces = FCPXML.pieces(media: [media("a", duration: 5), media("b", duration: 5)], silences: [4..<6], rate: .fps30)
        #expect(pieces.map(\.mediaIndex) == [0, 1])
        #expect(pieces.map(\.sourceStart) == [0, 30])
        #expect(pieces.map(\.duration) == [120, 120])
        #expect(pieces.map(\.offset) == [0, 120])
    }

    @Test func timesInsideACutLandWhereTheNextPieceStarts() {
        let pieces = FCPXML.pieces(media: [media("a", duration: 10)], silences: [2..<4], rate: .fps30)
        #expect(FCPXML.exportedFrame(for: 1, in: pieces, rate: .fps30) == 30)
        #expect(FCPXML.exportedFrame(for: 3, in: pieces, rate: .fps30) == 60)
        #expect(FCPXML.exportedFrame(for: 5, in: pieces, rate: .fps30) == 90)
        #expect(FCPXML.exportedFrame(for: 99, in: pieces, rate: .fps30) == 240)
    }

    @Test func captionsInsideACutAreDropped() {
        let input = FCPXML.Input(
            projectName: "p",
            media: [media("a", duration: 10)],
            silences: [2..<4],
            transcript: [
                FCPXML.Caption(start: 0, end: 1, text: "hello there you"),
                FCPXML.Caption(start: 2.5, end: 3.5, text: "lost in silence"),
                FCPXML.Caption(start: 5, end: 6, text: "after the cut"),
            ],
            captionTitle: basicTitle
        )
        let pieces = FCPXML.pieces(media: input.media, silences: input.silences, rate: .fps30)
        let placed = FCPXML.placedCaptions(input, pieces: pieces, rate: .fps30)
        #expect(placed.map(\.text) == ["hello there you", "after the cut"])
        #expect(placed.map(\.offset) == [0, 90])
        #expect(placed.map(\.duration) == [30, 30])
    }

    // MARK: Document

    @Test func documentHasTitlesAndAnAdjustmentLayerOverTheWholeVideo() {
        let input = FCPXML.Input(
            projectName: "Talk & <Demo>",
            media: [media("a", duration: 10), media("b", duration: 5)],
            silences: [2..<4],
            transcript: [FCPXML.Caption(start: 0, end: 1.5, text: "one two three four five six")],
            captionTitle: basicTitle,
            adjustmentLayer: adjustment
        )
        let xml = FCPXML.document(input)

        #expect(xml.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE fcpxml>"))
        #expect(xml.contains("<fcpxml version=\"\(FCPXML.version)\">"))
        #expect(xml.contains("name=\"Talk &amp; &lt;Demo&gt;\""))
        #expect(xml.contains("<text-style ref=\"ts1\">one two three</text-style>"))
        #expect(xml.contains("<text-style ref=\"ts2\">four five six</text-style>"))
        #expect(xml.components(separatedBy: "<asset-clip ").count - 1 == 3)
        // 13 s kept at 30 fps = 390 frames: sequence and adjustment layer match.
        #expect(xml.contains("<sequence format=\"r1\" duration=\"39000/3000s\""))
        #expect(xml.contains("lane=\"2\" offset=\"0s\" name=\"Adjustment Layer\" duration=\"39000/3000s\""))
        #expect(xml.contains(adjustment.uid))
        #expect(xml.contains(basicTitle.uid))
    }

    @Test func adjustmentLayerUsesLaneOneWithoutCaptions() {
        let input = FCPXML.Input(projectName: "p", media: [media("a", duration: 2)], adjustmentLayer: adjustment)
        let xml = FCPXML.document(input)
        #expect(xml.contains("lane=\"1\" offset=\"0s\" name=\"Adjustment Layer\" duration=\"6000/3000s\""))
        #expect(!xml.contains("<text>"))
    }

    // MARK: Title templates

    @Test func builtInAndUnknownTitles() {
        #expect(TitleTemplates.resolve("basic title", installed: []).source == .builtIn)
        let missing = TitleTemplates.resolve(" My Captions ", installed: [])
        #expect(missing.source == .notFound)
        #expect(missing.uid == "~/Titles.localized/My Captions/My Captions.moti")
    }

    @Test func installedTitlesAreFoundByName() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "titles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "Effects/Adjustment Layer")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appending(path: "Adjustment Layer.moti"))

        let installed = TitleTemplates.installed(in: root)
        #expect(installed.map(\.name) == ["Adjustment Layer"])
        let template = TitleTemplates.resolve("adjustment layer", installed: installed)
        #expect(template.source == .installed)
        #expect(template.uid == "~/Titles.localized/Effects/Adjustment Layer/Adjustment Layer.moti")
    }
}
