//
//  FCPXML.swift
//  HT Edit
//

import Foundation

/// Frame rate as one frame's duration, `frameValue / timescale` seconds
/// (the form FCPXML writes as `frameDuration="1001/30000s"`).
nonisolated struct FrameRate: Equatable, Hashable, Sendable {
    var frameValue: Int64
    var timescale: Int64

    var framesPerSecond: Double { Double(timescale) / Double(frameValue) }

    static let fps23_976 = FrameRate(frameValue: 1001, timescale: 24_000)
    static let fps24 = FrameRate(frameValue: 100, timescale: 2_400)
    static let fps25 = FrameRate(frameValue: 100, timescale: 2_500)
    static let fps29_97 = FrameRate(frameValue: 1001, timescale: 30_000)
    static let fps30 = FrameRate(frameValue: 100, timescale: 3_000)
    static let fps50 = FrameRate(frameValue: 100, timescale: 5_000)
    static let fps59_94 = FrameRate(frameValue: 1001, timescale: 60_000)
    static let fps60 = FrameRate(frameValue: 100, timescale: 6_000)

    /// The standard Final Cut rate closest to a track's nominal rate (30 fps if unknown).
    static func standard(nominal: Double) -> FrameRate {
        let all: [FrameRate] = [.fps23_976, .fps24, .fps25, .fps29_97, .fps30, .fps50, .fps59_94, .fps60]
        guard nominal.isFinite, nominal > 1 else { return .fps30 }
        return all.min { abs($0.framesPerSecond - nominal) < abs($1.framesPerSecond - nominal) } ?? .fps30
    }

    /// `frames` as an FCPXML time, e.g. `"3003/30000s"` or `"0s"`.
    func time(_ frames: Int64) -> String {
        frames == 0 ? "0s" : "\(frames * frameValue)/\(timescale)s"
    }

    /// Nearest whole frame to `seconds`.
    func frames(_ seconds: Double) -> Int64 {
        guard seconds.isFinite else { return 0 }
        return Int64((seconds * framesPerSecond).rounded())
    }
}

/// A Final Cut title template, as FCPXML references it.
nonisolated struct TitleTemplate: Equatable, Sendable {
    nonisolated enum Source: Equatable, Sendable {
        /// Ships with Final Cut Pro.
        case builtIn
        /// Installed in ~/Movies/Motion Templates.
        case installed
        /// A `.moti` file outside ~/Movies/Motion Templates, where Final Cut doesn't look.
        case outsideMotionTemplates
        /// Not found on this Mac: Final Cut will show it as missing.
        case notFound
    }

    var name: String
    var uid: String
    var source: Source
}

/// Pure FCPXML generation: clips back to back with the silences cut out,
/// Final Cut's native adjustment
/// clip over the whole video, and the transcript as centered titles of a few
/// words each on top.
///
/// Lanes, bottom to top: video (spine) → adjustment clip (lane 1) → titles (lane 2).
nonisolated enum FCPXML {

    /// The FCPXML version written (Final Cut Pro 12 and later).
    static let version = "1.14"

    /// Final Cut's built-in adjustment clip (Edit ▸ Add Adjustment Clip, Final Cut Pro 11.1+).
    static let adjustmentEffectName = "Adjustment Clip"
    static let adjustmentEffectUID = "FFAdjustmentEffect"

    nonisolated struct Media: Equatable, Sendable {
        var url: URL
        var name: String
        /// Seconds.
        var duration: Double
        var hasVideo: Bool
        var hasAudio: Bool
        var width: Int
        var height: Int
        var frameRate: FrameRate
        var audioChannels: Int
        var audioRate: Int
    }

    nonisolated struct Caption: Equatable, Sendable {
        /// Timeline seconds (before silences are cut).
        var start: Double
        var end: Double
        var text: String
    }

    nonisolated struct Input: Sendable {
        var projectName: String
        var eventName = "HT Edit"
        /// Clips in timeline order.
        var media: [Media]
        /// Timeline seconds to cut out.
        var silences: [Range<Double>] = []
        /// Transcript lines, in timeline seconds.
        var transcript: [Caption] = []
        var wordsPerTitle = 3
        /// Template for the captions (used when there is a transcript).
        var captionTitle: TitleTemplate
    }

    /// One kept stretch of a clip, placed on the exported timeline.
    nonisolated struct Piece: Equatable, Sendable {
        var mediaIndex: Int
        /// Original timeline seconds this piece covers.
        var timelineStart: Double
        var timelineEnd: Double
        /// Frames into the source file.
        var sourceStart: Int64
        /// Frames.
        var duration: Int64
        /// Frames from the start of the timeline.
        var offset: Int64
    }

    /// A caption placed on the exported timeline, in frames.
    nonisolated struct PlacedCaption: Equatable, Sendable {
        var offset: Int64
        var duration: Int64
        var text: String
    }

    // MARK: Timeline

    /// The kept stretches of each clip (everything but `silences`), back to back, in whole frames.
    static func pieces(media: [Media], silences: [Range<Double>], rate: FrameRate) -> [Piece] {
        var result: [Piece] = []
        var clipStart = 0.0
        var offset: Int64 = 0
        let sorted = silences.sorted { $0.lowerBound < $1.lowerBound }
        for (index, item) in media.enumerated() {
            let clipEnd = clipStart + item.duration
            let available = rate.frames(item.duration)
            for kept in subtracting(sorted, from: clipStart..<clipEnd) {
                let start = rate.frames(kept.lowerBound - clipStart)
                let end = min(available, rate.frames(kept.upperBound - clipStart))
                guard end > start else { continue }
                result.append(Piece(
                    mediaIndex: index,
                    timelineStart: kept.lowerBound,
                    timelineEnd: kept.upperBound,
                    sourceStart: start,
                    duration: end - start,
                    offset: offset
                ))
                offset += end - start
            }
            clipStart = clipEnd
        }
        return result
    }

    /// `range` without the (sorted) `holes`.
    static func subtracting(_ holes: [Range<Double>], from range: Range<Double>) -> [Range<Double>] {
        var result: [Range<Double>] = []
        var cursor = range.lowerBound
        for hole in holes where hole.upperBound > cursor && hole.lowerBound < range.upperBound {
            if hole.lowerBound > cursor { result.append(cursor..<hole.lowerBound) }
            cursor = max(cursor, hole.upperBound)
        }
        if cursor < range.upperBound { result.append(cursor..<range.upperBound) }
        return result
    }

    /// Where original timeline second `time` lands on the exported timeline, in
    /// frames. A time inside a cut lands where the next kept piece starts.
    static func exportedFrame(for time: Double, in pieces: [Piece], rate: FrameRate) -> Int64 {
        for piece in pieces where time < piece.timelineEnd {
            if time <= piece.timelineStart { return piece.offset }
            return piece.offset + min(piece.duration, rate.frames(time - piece.timelineStart))
        }
        return pieces.last.map { $0.offset + $0.duration } ?? 0
    }

    // MARK: Captions

    /// Splits each line into groups of `wordsPerTitle` words, sharing the
    /// line's time between them by length (longer groups are on screen longer).
    static func wordGroups(_ lines: [Caption], wordsPerTitle: Int) -> [Caption] {
        let size = max(1, wordsPerTitle)
        var result: [Caption] = []
        for line in lines {
            let words = line.text.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !words.isEmpty else { continue }
            let groups = stride(from: 0, to: words.count, by: size).map {
                words[$0..<min($0 + size, words.count)].joined(separator: " ")
            }
            let weights = groups.map { Double($0.count + 1) }
            let total = weights.reduce(0, +)
            let length = max(0, line.end - line.start)
            var cursor = line.start
            for (group, weight) in zip(groups, weights) {
                let end = cursor + length * weight / total
                result.append(Caption(start: cursor, end: end, text: group))
                cursor = end
            }
        }
        return result
    }

    /// Word groups on the cut timeline: words spoken inside a cut are dropped,
    /// groups never overlap, and anything shorter than a frame is dropped.
    static func placedCaptions(_ input: Input, pieces: [Piece], rate: FrameRate) -> [PlacedCaption] {
        let groups = wordGroups(input.transcript, wordsPerTitle: input.wordsPerTitle)
            .sorted { $0.start < $1.start }
        var placed = groups.map { group in
            let start = exportedFrame(for: group.start, in: pieces, rate: rate)
            let end = exportedFrame(for: group.end, in: pieces, rate: rate)
            return PlacedCaption(offset: start, duration: end - start, text: group.text)
        }
        for index in placed.indices.dropLast() {
            let limit = placed[index + 1].offset - placed[index].offset
            placed[index].duration = min(placed[index].duration, max(0, limit))
        }
        return placed.filter { $0.duration > 0 }
    }

    // MARK: Document

    static func document(_ input: Input) -> String {
        let rate = input.media.first { $0.hasVideo }?.frameRate ?? .fps30
        let pieces = Self.pieces(media: input.media, silences: input.silences, rate: rate)
        let total = pieces.last.map { $0.offset + $0.duration } ?? 0
        let sequenceVideo = input.media.first { $0.hasVideo }

        // Resources
        var resources: [XMLElementNode] = []
        var nextID = 1
        func makeID() -> String {
            defer { nextID += 1 }
            return "r\(nextID)"
        }

        let sequenceFormatID = makeID()
        resources.append(XMLElementNode("format", [
            ("id", sequenceFormatID),
            ("frameDuration", rate.time(1)),
            ("width", String(sequenceVideo?.width ?? 1920)),
            ("height", String(sequenceVideo?.height ?? 1080)),
        ]))
        var formatIDs: [String: String] = ["\(sequenceVideo?.width ?? 1920)x\(sequenceVideo?.height ?? 1080)@\(rate.frameValue)/\(rate.timescale)": sequenceFormatID]

        var assetIDs: [String] = []
        for item in input.media {
            var formatID = sequenceFormatID
            if item.hasVideo {
                let key = "\(item.width)x\(item.height)@\(item.frameRate.frameValue)/\(item.frameRate.timescale)"
                if let existing = formatIDs[key] {
                    formatID = existing
                } else {
                    formatID = makeID()
                    formatIDs[key] = formatID
                    resources.append(XMLElementNode("format", [
                        ("id", formatID),
                        ("frameDuration", item.frameRate.time(1)),
                        ("width", String(item.width)),
                        ("height", String(item.height)),
                    ]))
                }
            }
            let id = makeID()
            assetIDs.append(id)
            var attributes: [(String, String)] = [
                ("id", id),
                ("name", item.name),
                ("start", "0s"),
                ("duration", rate.time(max(1, Int64((item.duration * rate.framesPerSecond).rounded(.up))))),
                ("hasVideo", item.hasVideo ? "1" : "0"),
                ("format", formatID),
            ]
            if item.hasVideo { attributes.append(("videoSources", "1")) }
            attributes.append(("hasAudio", item.hasAudio ? "1" : "0"))
            if item.hasAudio {
                attributes += [
                    ("audioSources", "1"),
                    ("audioChannels", String(item.audioChannels)),
                    ("audioRate", String(item.audioRate)),
                ]
            }
            resources.append(XMLElementNode("asset", attributes, children: [
                XMLElementNode("media-rep", [("kind", "original-media"), ("src", item.url.absoluteString)]),
            ]))
        }

        let adjustmentEffectID = makeID()
        resources.append(XMLElementNode("effect", [
            ("id", adjustmentEffectID),
            ("name", adjustmentEffectName),
            ("uid", adjustmentEffectUID),
        ]))

        let captions = placedCaptions(input, pieces: pieces, rate: rate)
        var captionEffectID: String?
        if !captions.isEmpty {
            let id = makeID()
            captionEffectID = id
            resources.append(XMLElementNode("effect", [
                ("id", id),
                ("name", input.captionTitle.name),
                ("uid", input.captionTitle.uid),
            ]))
        }

        // Connected clips, attached to the spine clip they start over.
        // Their offsets are in the parent clip's source time.
        var connected: [[XMLElementNode]] = Array(repeating: [], count: pieces.count)
        func attach(_ node: (_ localOffset: Int64) -> XMLElementNode, at frame: Int64) {
            guard let index = pieces.lastIndex(where: { $0.offset <= frame }) else { return }
            let piece = pieces[index]
            connected[index].append(node(piece.sourceStart + frame - piece.offset))
        }

        // Lane 1: the adjustment clip, between the video and the titles, for the whole video.
        if total > 0 {
            attach({ local in
                XMLElementNode("video", [
                    ("ref", adjustmentEffectID),
                    ("lane", "1"),
                    ("offset", rate.time(local)),
                    ("name", adjustmentEffectName),
                    ("start", "0s"),
                    ("duration", rate.time(total)),
                    ("role", "adjustments"),
                ])
            }, at: 0)
        }

        // Lane 2: captions, centered.
        if let captionEffectID {
            for (index, caption) in captions.enumerated() {
                let styleID = "ts\(index + 1)"
                attach({ local in
                    XMLElementNode("title", [
                        ("ref", captionEffectID),
                        ("lane", "2"),
                        ("offset", rate.time(local)),
                        ("name", "\(caption.text) - \(input.captionTitle.name)"),
                        ("duration", rate.time(caption.duration)),
                    ], children: [
                        XMLElementNode("text", children: [XMLElementNode("text-style", [("ref", styleID)], text: caption.text)]),
                        XMLElementNode("text-style-def", [("id", styleID)], children: [
                            XMLElementNode("text-style", [("alignment", "center")]),
                        ]),
                    ])
                }, at: caption.offset)
            }
        }

        // Spine
        let spine = pieces.enumerated().map { index, piece in
            let item = input.media[piece.mediaIndex]
            return XMLElementNode("asset-clip", [
                ("ref", assetIDs[piece.mediaIndex]),
                ("offset", rate.time(piece.offset)),
                ("name", item.name),
                ("start", rate.time(piece.sourceStart)),
                ("duration", rate.time(piece.duration)),
                ("tcFormat", "NDF"),
            ], children: connected[index])
        }

        let root = XMLElementNode("fcpxml", [("version", version)], children: [
            XMLElementNode("resources", children: resources),
            XMLElementNode("library", children: [
                XMLElementNode("event", [("name", input.eventName)], children: [
                    XMLElementNode("project", [("name", input.projectName)], children: [
                        XMLElementNode("sequence", [
                            ("format", sequenceFormatID),
                            ("duration", rate.time(total)),
                            ("tcStart", "0s"),
                            ("tcFormat", "NDF"),
                            ("audioLayout", "stereo"),
                            ("audioRate", "48k"),
                        ], children: [XMLElementNode("spine", children: spine)]),
                    ]),
                ]),
            ]),
        ])

        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE fcpxml>\n\n" + root.rendered() + "\n"
    }
}

nonisolated struct XMLElementNode: Sendable {
    var name: String
    var attributes: [(String, String)]
    var children: [XMLElementNode]
    var text: String?

    init(_ name: String, _ attributes: [(String, String)] = [], children: [XMLElementNode] = [], text: String? = nil) {
        self.name = name
        self.attributes = attributes
        self.children = children
        self.text = text
    }

    func rendered(indent: Int = 0) -> String {
        let pad = String(repeating: "    ", count: indent)
        let attrs = attributes.map { " \($0.0)=\"\(Self.escape($0.1))\"" }.joined()
        if let text {
            return "\(pad)<\(name)\(attrs)>\(Self.escape(text))</\(name)>"
        }
        if children.isEmpty {
            return "\(pad)<\(name)\(attrs)/>"
        }
        let inner = children.map { $0.rendered(indent: indent + 1) }.joined(separator: "\n")
        return "\(pad)<\(name)\(attrs)>\n\(inner)\n\(pad)</\(name)>"
    }

    static func escape(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.count)
        for character in string {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            case "\n": result += "&#10;"
            default: result.append(character)
            }
        }
        return result
    }
}
