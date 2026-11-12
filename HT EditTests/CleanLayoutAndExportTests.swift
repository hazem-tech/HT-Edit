//
//  CleanLayoutAndExportTests.swift
//  HT EditTests
//
//  The Clean layout's edit map, line selection, the AI transcript review and
//  the FCPXML export.
//

import CoreMedia
import Foundation
import Testing
@testable import HT_Edit

private func range(_ start: Double, _ end: Double) -> CMTimeRange {
    CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 48_000), end: CMTime(seconds: end, preferredTimescale: 48_000))
}

private func close(_ a: Double, _ b: Double) -> Bool { isClose(a, b, tolerance: 0.001) }

struct EditMapTests {

    @Test func keepsWhatIsntSkipped() {
        let map = EditMap(skips: [range(1, 2), range(3, 3.5)], duration: 5)
        #expect(map.pieces.map(\.source) == [0..<1, 2..<3, 3.5..<5])
        #expect(map.pieces.map(\.editedStart) == [0, 1, 2])
        #expect(close(map.editedDuration, 3.5))
    }

    @Test func skipsAtTheEdgesAndOverlappingSkips() {
        let map = EditMap(skips: [range(0, 1), range(0.5, 2), range(4, 6)], duration: 5)
        #expect(map.pieces.map(\.source) == [2..<4])
        #expect(close(map.editedDuration, 2))
        #expect(EditMap(skips: [range(0, 5)], duration: 5).pieces.isEmpty)
        #expect(EditMap(skips: [], duration: .nan) == .empty)
    }

    @Test func mapsBothWays() {
        let map = EditMap(skips: [range(1, 2), range(3, 3.5)], duration: 5)
        #expect(close(map.edited(fromSource: 0.5), 0.5))
        #expect(close(map.edited(fromSource: 2.5), 1.5))
        #expect(close(map.edited(fromSource: 4), 2.5))
        for edited in [0.0, 0.7, 1.2, 2.9, 3.4] {
            #expect(close(map.edited(fromSource: map.source(fromEdited: edited)), edited))
        }
        #expect(close(map.source(fromEdited: 1), 2), "a join shows the time after the cut")
        #expect(close(map.source(fromEdited: 99), 5))
    }

    @Test func aTimeInsideACutLandsWhereTheEditCarriesOn() {
        let map = EditMap(skips: [range(1, 2)], duration: 3)
        #expect(close(map.edited(fromSource: 1.5), 1))
        let tail = EditMap(skips: [range(2, 3)], duration: 3)
        #expect(close(tail.edited(fromSource: 2.5), 2))
    }

    @Test func piecesAreSplitAtClipBoundaries() {
        // Two clips, 0–3 and 3–5; kept 0–1, 2–4 and 4.5–5.
        let map = EditMap(skips: [range(1, 2), range(4, 4.5)], duration: 5)
        let pieces = EditDecisions.keptPieces(clipDurations: [3, 2], map: map, markers: [[0.5, 1.5], [1.8]])
        #expect(pieces.count == 2)
        #expect(pieces[0].map(\.range) == [0..<1, 2..<3])
        #expect(pieces[0][0].markers == [0.5], "a marker inside a cut isn't kept")
        #expect(pieces[1].count == 2)
        #expect(close(pieces[1][0].range.lowerBound, 0) && close(pieces[1][0].range.upperBound, 1))
        #expect(close(pieces[1][1].range.lowerBound, 1.5) && close(pieces[1][1].range.upperBound, 2))
        #expect(pieces[1][1].markers == [1.8])
    }
}

@MainActor
struct CleanLayoutTests {

    private func makeModel() -> EditorViewModel {
        EditorViewModel(
            analyzedClips: [makeClip(loud(1) + quiet(1) + loud(1), name: "a")],
            settings: settings()
        )
    }

    @Test func cleanShowsTheEditedTimeline() {
        let model = makeModel()
        #expect(isClose(model.displayDuration, 3))
        #expect(isClose(model.displaySeconds(forSource: 2.5), 2.5))

        model.layout = .clean
        #expect(isClose(model.displayDuration, 2, tolerance: 0.01))
        #expect(isClose(model.displaySeconds(forSource: 2.5), 1.5, tolerance: 0.01))
        #expect(isClose(model.sourceSeconds(forDisplay: 1.5), 2.5, tolerance: 0.01))

        model.settings.thresholdDB = -70
        #expect(isClose(model.displayDuration, 3), "nothing removed: the edit is the whole timeline")
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct TranscriptSelectionTests {

    private func makeModel(review: TranscriptReview = TranscriptReview(engine: StubReviewEngine())) async throws -> (EditorViewModel, URL) {
        let directory = makeTemporaryDirectory("select-lines")
        let audio = try await MediaFixtures.make(.audioOnly, in: directory, duration: 3)
        let engine = ScriptedEngine { _, _ in
            [TranscriptSegment(start: 0.2, end: 1.2, text: "one two"), TranscriptSegment(start: 1.5, end: 2.8, text: "three four five")]
        }
        let controller = TranscriptionController(engine: engine, cache: nil, defaults: nil, chunkLength: 3)
        let clip = Clip(url: audio, duration: CMTime(seconds: 3, preferredTimescale: 600))
        let model = EditorViewModel(analyzedClips: [(clip, makeLevels(loud(3)))], transcription: controller, review: review)
        model.cutsNonSpeech = false
        model.transcribeAll()
        #expect(await waitUntil { controller.phase == .finished && model.timelineWords.count == 5 })
        return (model, directory)
    }

    @Test func clickingALinesEmptySpaceSelectsTheLine() async throws {
        let (model, directory) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        let segments = model.timelineTranscript
        let words = model.timelineWords

        model.selectWords(inSegment: segments[1].id)
        #expect(model.selectedWordIDs == Set(words[2...4].map(\.id)))
        model.toggleSelectedWords()
        #expect(model.deletedWordIDs == Set(words[2...4].map(\.id)), "⌫ cuts the whole line")
        #expect(model.wordCuts.count == 1)

        model.selectWords(inSegment: "no such line")
        #expect(model.selectedWordIDs == Set(words[2...4].map(\.id)))
    }

    @Test func cleanSelectsOnlyTheWordsItShows() async throws {
        let (model, directory) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        let words = model.timelineWords
        model.toggleDeletion(of: [words[3].id])

        model.selectWord(at: 1)
        model.selectWord(at: 4, extending: true)
        #expect(model.selectedWordIDs.contains(words[3].id), "Full shows cut words, so they're selected too")

        model.layout = .clean
        #expect(!model.selectedWordIDs.contains(words[3].id), "switching to Clean drops hidden words")
        model.selectWord(at: 1)
        model.selectWord(at: 4, extending: true)
        #expect(model.selectedWordIDs == Set([words[1], words[2], words[4]].map(\.id)))
        model.selectWords(inSegment: model.timelineTranscript[1].id)
        #expect(model.selectedWordIDs == Set([words[2], words[4]].map(\.id)))
    }

    @Test func reviewHighlightsWordsUntilANewTranscript() async throws {
        let review = TranscriptReview(engine: StubReviewEngine(findings: [ReviewFinding(first: 1, last: 2, reason: "Repeated")]))
        let (model, directory) = try await makeModel(review: review)
        defer { try? FileManager.default.removeItem(at: directory) }
        let words = model.timelineWords

        model.runReview("Find repetition")
        #expect(review.isRunning)
        #expect(await waitUntil { !review.isRunning })
        #expect(review.errorMessage == nil)
        #expect(review.reasons == [words[1].id: "Repeated", words[2].id: "Repeated"])
        #expect(review.highlights.map(\.text) == ["two three"])

        model.selectHighlightedWords()
        #expect(model.selectedWordIDs == [words[1].id, words[2].id])

        model.transcribeAll()
        #expect(review.reasons.isEmpty, "a new transcript has new words")
    }

    @Test func aFailingReviewSaysWhy() async throws {
        let review = TranscriptReview(engine: StubReviewEngine(error: AgyError.notSignedIn))
        let (model, directory) = try await makeModel(review: review)
        defer { try? FileManager.default.removeItem(at: directory) }
        model.runReview("Grammar check")
        #expect(await waitUntil { !review.isRunning })
        #expect(review.errorMessage == AgyError.notSignedIn.localizedDescription)
        #expect(review.reasons.isEmpty)
    }
}

/// A review engine that answers with fixed findings (or fails).
nonisolated struct StubReviewEngine: TranscriptReviewEngine {
    var findings: [ReviewFinding] = []
    var error: AgyError?

    func review(transcript: String, instruction: String, model: String) async throws -> [ReviewFinding] {
        try await Task.sleep(for: .milliseconds(30))
        if let error { throw error }
        return findings
    }
}

struct TranscriptReviewTests {

    private let clip = UUID()

    private func word(_ index: Int, _ text: String) -> TimelineWord {
        TimelineWord(id: "w\(index)", clipID: clip, start: Double(index), end: Double(index) + 0.5, clipStart: Double(index), clipEnd: Double(index) + 0.5, text: text, isApproximate: false)
    }

    private var segments: [TimelineSegment] {
        [
            TimelineSegment(id: "s0", clipID: clip, start: 0, end: 2, text: "hello there", words: [word(0, "hello"), word(1, "there")]),
            TimelineSegment(id: "s1", clipID: clip, start: 65, end: 67, text: "general kenobi", words: [word(2, "general"), word(3, "kenobi")]),
        ]
    }

    @Test func documentNumbersEveryWordAndLeavesOutDeletedOnes() {
        let text = TranscriptReview.document(segments: segments, deleted: ["w1"])
        #expect(text == "[0:00] #0:hello\n[1:05] #2:general #3:kenobi")
        #expect(TranscriptReview.document(segments: segments, deleted: ["w0", "w1"]).hasPrefix("[1:05]"), "a line with nothing left is left out")
    }

    @Test func findingsBecomeHighlightedWords() {
        let words = segments.flatMap(\.words)
        let findings = [
            ReviewFinding(first: 3, last: 2, reason: "Backwards"),
            ReviewFinding(first: -4, last: 0, reason: "Clamped"),
            ReviewFinding(first: 9, last: 12, reason: "Out of range"),
            ReviewFinding(first: 1, last: 1, reason: "Deleted"),
        ]
        let highlights = TranscriptReview.highlights(findings, words: words, deleted: ["w1"])
        #expect(highlights.map(\.wordIDs) == [["w0"], ["w2", "w3"]])
        #expect(highlights.map(\.reason) == ["Clamped", "Backwards"])
        #expect(highlights[1].text == "general kenobi")
    }

    @Test func presetTitlesSendTheirFullInstruction() {
        #expect(ReviewPreset.instruction(for: " find repetition ") == ReviewPreset.repetition.instruction)
        #expect(ReviewPreset.instruction(for: "Is this funny?") == "Is this funny?")
    }

    @Test func reviewCommandIsHeadlessJSON() throws {
        let arguments = AgyCommand.review(fileName: "transcript.txt", instruction: "Find repetition", model: testModelID, timeout: .seconds(300))
        #expect(arguments.first == "-p")
        let prompt = try #require(arguments.dropFirst().first)
        #expect(prompt.contains("@transcript.txt"))
        #expect(prompt.contains("Find repetition"))
        let schema = try #require(arguments.firstIndex(of: "--json-schema").map { arguments[$0 + 1] })
        #expect((try? JSONSerialization.jsonObject(with: Data(schema.utf8))) != nil, "Schema must be valid JSON")
        #expect(arguments.firstIndex(of: "--model").map { arguments[$0 + 1] } == testModelID)
    }

    @Test func parsesReviewReplies() throws {
        let structured = #"{"status":"SUCCESS","structured_output":{"highlights":[{"first":2,"last":3,"reason":"Repeats line 1"}]}}"#
        #expect(try AgyOutputParser.findings(from: structured) == [ReviewFinding(first: 2, last: 3, reason: "Repeats line 1")])

        let text = ##"{"status":"SUCCESS","response":"Sure:\n```json\n{\"highlights\":[{\"first\":\"#4\",\"last\":5.0,\"reason\":\" Filler \"}]}\n```"}"##
        #expect(try AgyOutputParser.findings(from: text) == [ReviewFinding(first: 4, last: 5, reason: "Filler")])

        #expect(try AgyOutputParser.findings(from: #"{"status":"SUCCESS","structured_output":{"highlights":[]}}"#).isEmpty)
        #expect(throws: AgyError.failed("quota exceeded")) {
            try AgyOutputParser.findings(from: #"{"status":"ERROR","error":"quota exceeded"}"#)
        }
        #expect(throws: AgyError.self) {
            try AgyOutputParser.findings(from: "Nothing to see here.")
        }
    }
}

struct FCPXMLExporterTests {

    private let frame30 = CMTime(value: 1, timescale: 30)

    private func media(_ name: String, timecode: CMTime = .zero, video: Bool = true) -> FCPXMLMedia {
        FCPXMLMedia(
            url: URL(filePath: "/tmp/My Clips/\(name)"),
            name: name,
            duration: 10,
            videoSize: video ? CGSize(width: 1920, height: 1080) : nil,
            frameDuration: video ? frame30 : nil,
            timecodeStart: timecode
        )
    }

    @Test func timesAreReducedRationals() {
        #expect(FCPXMLExporter.timeString(.zero) == "0s")
        #expect(FCPXMLExporter.timeString(CMTime(value: 90, timescale: 30)) == "3s")
        #expect(FCPXMLExporter.timeString(CMTime(value: 2002, timescale: 60000)) == "1001/30000s")
        #expect(FCPXMLExporter.frames(1.02, of: frame30) == 31)
        #expect(FCPXMLExporter.frameDuration(forRate: 29.97) == CMTime(value: 1001, timescale: 30000))
        #expect(FCPXMLExporter.frameDuration(forRate: 25) == CMTime(value: 1, timescale: 25))
        #expect(FCPXMLExporter.frameDuration(forRate: 0) == FCPXMLExporter.defaultFrameDuration)
    }

    @Test func spineHoldsEveryKeptPieceBackToBack() throws {
        let clips = [
            FCPXMLClip(media: media("a.mov"), pieces: [
                KeptPiece(range: 0..<1.02),
                KeptPiece(range: 2..<2.01),          // under a frame: left out
                KeptPiece(range: 3..<4, markers: [3.5]),
            ]),
            FCPXMLClip(media: media("b.mov", timecode: CMTime(value: 3600, timescale: 1)), pieces: [KeptPiece(range: 1..<2)]),
        ]
        let xml = FCPXMLExporter.document(projectName: "Talk & <Notes>", clips: clips)
        let document = try XMLDocument(xmlString: xml)
        let root = try #require(document.rootElement())
        #expect(root.name == "fcpxml")
        #expect(root.attribute(forName: "version")?.stringValue == FCPXMLExporter.version)

        let assets = try document.nodes(forXPath: "//resources/asset") as? [XMLElement] ?? []
        #expect(assets.count == 2)
        #expect(assets[1].attribute(forName: "start")?.stringValue == "3600s")
        let src = try document.nodes(forXPath: "//media-rep/@src").first?.stringValue
        #expect(src == URL(filePath: "/tmp/My Clips/a.mov").absoluteString)

        let project = try document.nodes(forXPath: "//project/@name").first?.stringValue
        #expect(project == "Talk & <Notes>", "names are escaped and read back")

        let spine = try document.nodes(forXPath: "//spine/asset-clip") as? [XMLElement] ?? []
        func value(_ index: Int, _ name: String) -> String? { spine[index].attribute(forName: name)?.stringValue }
        #expect(spine.count == 3)
        #expect([value(0, "offset"), value(1, "offset"), value(2, "offset")] == ["0s", "31/30s", "61/30s"])
        #expect([value(0, "duration"), value(1, "duration"), value(2, "duration")] == ["31/30s", "1s", "1s"])
        #expect([value(0, "start"), value(1, "start"), value(2, "start")] == ["0s", "3s", "3601s"])
        #expect(value(2, "ref") == assets[1].attribute(forName: "id")?.stringValue)

        let markers = try document.nodes(forXPath: "//asset-clip/marker") as? [XMLElement] ?? []
        #expect(markers.count == 1)
        #expect(markers.first?.attribute(forName: "start")?.stringValue == "7/2s")

        let sequence = try #require(try document.nodes(forXPath: "//sequence").first as? XMLElement)
        #expect(sequence.attribute(forName: "duration")?.stringValue == "91/30s")
    }

    @Test func audioOnlyClipsHaveNoVideoFormat() throws {
        let xml = FCPXMLExporter.document(projectName: "Audio", clips: [FCPXMLClip(media: media("a.m4a", video: false), pieces: [KeptPiece(range: 0..<1)])])
        let document = try XMLDocument(xmlString: xml)
        let asset = try #require(try document.nodes(forXPath: "//resources/asset").first as? XMLElement)
        #expect(asset.attribute(forName: "hasVideo")?.stringValue == "0")
        #expect(asset.attribute(forName: "format") == nil)
        let format = try #require(try document.nodes(forXPath: "//resources/format").first as? XMLElement)
        #expect(format.attribute(forName: "width")?.stringValue == "1920", "the sequence still has a video format")
    }

    @Test func readsMediaFromARealFile() async throws {
        let directory = makeTemporaryDirectory("fcpxml-media")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await MediaFixtures.make(.h264Landscape, in: directory)
        let media = try await FCPXMLExporter.media(url: url, name: url.lastPathComponent, duration: 3)
        #expect(media.videoSize == CGSize(width: 1920, height: 1080))
        #expect(media.frameDuration != nil)
        #expect(media.hasAudio)
        #expect(media.timecodeStart == .zero)
    }
}
