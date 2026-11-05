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

    // MARK: Timeline

    @Test func clipsAreBackToBack() {
        let pieces = FCPXML.pieces(media: [media("a", duration: 5), media("b", duration: 2.5)], silences: [], rate: .fps30)
        #expect(pieces.map(\.offset) == [0, 150])
        #expect(pieces.map(\.duration) == [150, 75])
        #expect(FCPXML.exportedFrame(for: 6, in: pieces, rate: .fps30) == 180)
        #expect(FCPXML.exportedFrame(for: 99, in: pieces, rate: .fps30) == 225)
    }

    @Test func overlappingCaptionsAreTrimmed() {
        let input = FCPXML.Input(
            projectName: "p",
            media: [media("a", duration: 10)],
            transcript: [
                FCPXML.Caption(start: 0, end: 2, text: "hello there you"),
                FCPXML.Caption(start: 1, end: 3, text: "next line here"),
            ],
            captionTitle: basicTitle
        )
        let pieces = FCPXML.pieces(media: input.media, silences: [], rate: .fps30)
        let placed = FCPXML.placedCaptions(input, pieces: pieces, rate: .fps30)
        #expect(placed.map(\.offset) == [0, 30])
        #expect(placed.map(\.duration) == [30, 60])
    }

    // MARK: Cutting silences

    @Test func silencesAreCutOut() {
        let pieces = FCPXML.pieces(media: [media("a", duration: 10)], silences: [2..<4], rate: .fps30)
        #expect(pieces.map(\.sourceStart) == [0, 120])
        #expect(pieces.map(\.duration) == [60, 180])
        #expect(pieces.map(\.offset) == [0, 60])
    }

    @Test func aSilenceAcrossAClipBoundaryTrimsBothClips() {
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

    @Test func captionsSpokenInsideACutAreDropped() {
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

    @Test func cutTimelineInTheDocument() {
        let input = FCPXML.Input(
            projectName: "p",
            media: [media("a", duration: 10)],
            silences: [2..<4],
            transcript: [FCPXML.Caption(start: 5, end: 6, text: "after the cut")],
            captionTitle: basicTitle
        )
        let xml = FCPXML.document(input)
        // Two pieces: 0–2 s and 4–10 s of the file, 8 s (240 frames) in all.
        #expect(xml.contains("offset=\"0s\" name=\"a\" start=\"0s\" duration=\"6000/3000s\""))
        #expect(xml.contains("offset=\"6000/3000s\" name=\"a\" start=\"12000/3000s\" duration=\"18000/3000s\""))
        #expect(xml.contains("<sequence format=\"r1\" duration=\"24000/3000s\""))
        // The adjustment clip covers the cut length; the title sits at 5 s of the file (3 s on the timeline).
        #expect(xml.contains("name=\"Adjustment Clip\" start=\"0s\" duration=\"24000/3000s\""))
        #expect(xml.contains("lane=\"2\" offset=\"15000/3000s\""))
    }

    // MARK: Document

    @Test func adjustmentClipSitsBetweenVideoAndCenteredTitles() {
        let input = FCPXML.Input(
            projectName: "Talk & <Demo>",
            media: [media("a", duration: 10), media("b", duration: 5)],
            transcript: [FCPXML.Caption(start: 0, end: 1.5, text: "one two three four five six")],
            captionTitle: basicTitle
        )
        let xml = FCPXML.document(input)

        #expect(xml.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE fcpxml>"))
        #expect(xml.contains("<fcpxml version=\"1.14\">"))
        #expect(xml.contains("name=\"Talk &amp; &lt;Demo&gt;\""))
        #expect(xml.components(separatedBy: "<asset-clip ").count - 1 == 2)
        // Native adjustment clip on lane 1, covering all 15 s (450 frames).
        #expect(xml.contains("name=\"Adjustment Clip\" uid=\"FFAdjustmentEffect\""))
        #expect(xml.contains("<sequence format=\"r1\" duration=\"45000/3000s\""))
        #expect(xml.contains("lane=\"1\" offset=\"0s\" name=\"Adjustment Clip\" start=\"0s\" duration=\"45000/3000s\" role=\"adjustments\""))
        // Titles on lane 2, 3 words each, centered.
        #expect(xml.components(separatedBy: "<title ref=").count - 1 == 2)
        #expect(xml.components(separatedBy: "lane=\"2\"").count - 1 == 2)
        #expect(xml.contains("<text-style ref=\"ts1\">one two three</text-style>"))
        #expect(xml.contains("<text-style ref=\"ts2\">four five six</text-style>"))
        #expect(xml.contains("<text-style alignment=\"center\"/>"))
        #expect(xml.contains(basicTitle.uid))
    }

    @Test func withoutATranscriptOnlyTheAdjustmentClipIsAdded() {
        let xml = FCPXML.document(FCPXML.Input(projectName: "p", media: [media("a", duration: 2)], captionTitle: basicTitle))
        #expect(xml.contains("lane=\"1\" offset=\"0s\" name=\"Adjustment Clip\" start=\"0s\" duration=\"6000/3000s\""))
        #expect(!xml.contains("<title "))
        #expect(!xml.contains(basicTitle.uid))
    }

    // MARK: Title templates

    @Test func builtInAndUnknownTitles() {
        #expect(TitleTemplates.resolve("basic title", installed: []).source == .builtIn)
        let missing = TitleTemplates.resolve(" My Captions ", installed: [])
        #expect(missing.source == .notFound)
        #expect(missing.uid == "~/Titles.localized/My Captions/My Captions.moti")
    }

    @Test func installedTitlesAreFoundByNameOrPath() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "templates-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "Titles.localized/Captions/Pop Words")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "Pop Words.moti")
        try Data().write(to: file)

        let installed = TitleTemplates.installed(in: root)
        #expect(installed.map(\.name) == ["Pop Words"])

        let byName = TitleTemplates.resolve("pop words", installed: installed, motionTemplates: root)
        #expect(byName.source == .installed)
        #expect(byName.uid == "~/Titles.localized/Captions/Pop Words/Pop Words.moti")

        let byFile = TitleTemplates.resolve(file.path(percentEncoded: false), installed: [], motionTemplates: root)
        #expect(byFile == byName)
        let byFolder = TitleTemplates.resolve(folder.path(percentEncoded: false), installed: [], motionTemplates: root)
        #expect(byFolder == byName)
    }

    @Test func titlesOutsideMotionTemplatesAreFlagged() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "loose-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "Loose.moti")
        try Data().write(to: file)

        let template = TitleTemplates.resolve(file.path(percentEncoded: false), installed: [], motionTemplates: root.appending(path: "elsewhere"))
        #expect(template.source == .outsideMotionTemplates)
        #expect(template.name == "Loose")
    }

    @Test func emptyNameMeansBasicTitle() {
        #expect(TitleTemplates.resolve("  ", installed: []).name == "Basic Title")
    }
}
