//
//  FCPXMLExporter.swift
//  HT Edit
//
//  Writes the edit as Final Cut Pro XML (FCPXML 1.10): one project whose
//  spine holds a clip for each kept piece, referencing the original files.
//  Final Cut Pro, DaVinci Resolve and others import it. Nothing is rendered.
//

import AVFoundation
import CoreMedia
import SwiftUI
import UniformTypeIdentifiers

/// What the export needs to know about one media file.
nonisolated struct FCPXMLMedia: Equatable, Sendable {
    var url: URL
    var name: String
    /// Seconds.
    var duration: Double
    /// Display size (rotation applied); `nil` for audio only.
    var videoSize: CGSize?
    /// One video frame; `nil` for audio only.
    var frameDuration: CMTime?
    var hasAudio = true
    var audioChannels = 2
    var audioRate = 48_000
    /// The file's start timecode, as a time (`.zero` without a timecode track).
    var timecodeStart: CMTime = .zero
}

/// One clip on the timeline, as exported.
nonisolated struct FCPXMLClip: Equatable, Sendable {
    var media: FCPXMLMedia
    /// The kept pieces, in clip seconds.
    var pieces: [KeptPiece]
}

nonisolated enum FCPXMLExporter {

    static let version = "1.10"
    /// Used when no clip has video.
    static let defaultFrameDuration = CMTime(value: 1, timescale: 30)
    static let defaultSize = CGSize(width: 1920, height: 1080)

    // MARK: Document

    /// The FCPXML document for `clips` (in timeline order). Every time is
    /// snapped to the sequence's frames; pieces shorter than a frame are left out.
    static func document(projectName: String, clips: [FCPXMLClip]) -> String {
        let firstVideo = clips.first { $0.media.frameDuration != nil && $0.media.videoSize != nil }?.media
        let sequenceFrame = firstVideo?.frameDuration ?? defaultFrameDuration
        let sequenceSize = firstVideo?.videoSize ?? defaultSize

        // Resources: formats (shared by matching clips), then one asset per file.
        var resources: [String] = []
        var formatIDs: [FormatKey: String] = [:]
        var nextID = 1
        func formatID(size: CGSize, frame: CMTime) -> String {
            let key = FormatKey(width: Int(size.width.rounded()), height: Int(size.height.rounded()), frameValue: frame.value, frameScale: frame.timescale)
            if let id = formatIDs[key] { return id }
            let id = "r\(nextID)"
            nextID += 1
            formatIDs[key] = id
            resources.append(#"<format id="\#(id)" frameDuration="\#(timeString(frame))" width="\#(key.width)" height="\#(key.height)"/>"#)
            return id
        }
        let sequenceFormat = formatID(size: sequenceSize, frame: sequenceFrame)

        var assetIDs: [URL: String] = [:]
        var assetFormats: [URL: String] = [:]
        for clip in clips where assetIDs[clip.media.url] == nil {
            let media = clip.media
            var format: String?
            if let size = media.videoSize, let frame = media.frameDuration {
                format = formatID(size: size, frame: frame)
            }
            let id = "r\(nextID)"
            nextID += 1
            assetIDs[media.url] = id
            assetFormats[media.url] = format
            var attributes = [
                ("id", id),
                ("name", media.name),
                ("start", timeString(media.timecodeStart)),
                ("duration", timeString(snap(media.duration, to: media.frameDuration ?? sequenceFrame))),
                ("hasVideo", format == nil ? "0" : "1"),
            ]
            if let format { attributes.append(("format", format)) }
            if media.hasAudio {
                attributes += [
                    ("hasAudio", "1"),
                    ("audioSources", "1"),
                    ("audioChannels", "\(media.audioChannels)"),
                    ("audioRate", "\(media.audioRate)"),
                ]
            } else {
                attributes.append(("hasAudio", "0"))
            }
            resources.append("<asset \(attributeString(attributes))>\n"
                + "    <media-rep kind=\"original-media\" src=\"\(escape(media.url.absoluteString))\"/>\n"
                + "</asset>")
        }

        // The spine: one asset clip per kept piece, back to back.
        var spine: [String] = []
        var offsetFrames: Int64 = 0
        var markerCount = 0
        for clip in clips {
            guard let ref = assetIDs[clip.media.url] else { continue }
            for piece in clip.pieces {
                let startFrames = frames(piece.range.lowerBound, of: sequenceFrame)
                let endFrames = frames(piece.range.upperBound, of: sequenceFrame)
                let lengthFrames = endFrames - startFrames
                guard lengthFrames > 0 else { continue }
                let start = CMTimeAdd(clip.media.timecodeStart, time(frames: startFrames, of: sequenceFrame))
                var attributes = [
                    ("ref", ref),
                    ("offset", timeString(time(frames: offsetFrames, of: sequenceFrame))),
                    ("name", clip.media.name),
                    ("start", timeString(start)),
                    ("duration", timeString(time(frames: lengthFrames, of: sequenceFrame))),
                ]
                if let format = assetFormats[clip.media.url] { attributes.append(("format", format)) }
                attributes.append(("tcFormat", "NDF"))

                var markers: [String] = []
                for seconds in piece.markers {
                    let markerFrames = frames(seconds, of: sequenceFrame)
                    guard markerFrames >= startFrames, markerFrames < endFrames else { continue }
                    markerCount += 1
                    let markerStart = CMTimeAdd(clip.media.timecodeStart, time(frames: markerFrames, of: sequenceFrame))
                    markers.append("    <marker start=\"\(timeString(markerStart))\" duration=\"\(timeString(sequenceFrame))\" value=\"Marker \(markerCount)\"/>")
                }
                if markers.isEmpty {
                    spine.append("<asset-clip \(attributeString(attributes))/>")
                } else {
                    spine.append("<asset-clip \(attributeString(attributes))>\n" + markers.joined(separator: "\n") + "\n</asset-clip>")
                }
                offsetFrames += lengthFrames
            }
        }

        let sequenceAttributes = [
            ("format", sequenceFormat),
            ("duration", timeString(time(frames: offsetFrames, of: sequenceFrame))),
            ("tcStart", "0s"),
            ("tcFormat", "NDF"),
            ("audioLayout", "stereo"),
            ("audioRate", "48k"),
        ]
        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            "<!DOCTYPE fcpxml>",
            #"<fcpxml version="\#(version)">"#,
            "    <resources>",
        ]
        lines += resources.map { indent($0, by: 2) }
        lines += [
            "    </resources>",
            "    <library>",
            "        <event name=\"HT Edit\">",
            "            <project name=\"\(escape(projectName))\">",
            "                <sequence \(attributeString(sequenceAttributes))>",
            "                    <spine>",
        ]
        lines += spine.map { indent($0, by: 6) }
        lines += [
            "                    </spine>",
            "                </sequence>",
            "            </project>",
            "        </event>",
            "    </library>",
            "</fcpxml>",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    private struct FormatKey: Hashable {
        var width: Int
        var height: Int
        var frameValue: CMTimeValue
        var frameScale: CMTimeScale
    }

    // MARK: Time

    /// Whole frames of `frame` nearest to `seconds`.
    static func frames(_ seconds: Double, of frame: CMTime) -> Int64 {
        guard seconds.isFinite, frame.value > 0, frame.timescale > 0 else { return 0 }
        return Int64((seconds * Double(frame.timescale) / Double(frame.value)).rounded())
    }

    static func time(frames: Int64, of frame: CMTime) -> CMTime {
        CMTime(value: frames * frame.value, timescale: frame.timescale)
    }

    /// `seconds` on a frame of `frame`.
    static func snap(_ seconds: Double, to frame: CMTime) -> CMTime {
        time(frames: frames(seconds, of: frame), of: frame)
    }

    /// A time as FCPXML writes it: `0s`, `3s` or `1001/30000s`, reduced.
    static func timeString(_ time: CMTime) -> String {
        guard time.isNumeric, time.value != 0, time.timescale > 0 else { return "0s" }
        let divisor = gcd(abs(time.value), Int64(time.timescale))
        let value = time.value / divisor
        let scale = Int64(time.timescale) / divisor
        return scale == 1 ? "\(value)s" : "\(value)/\(scale)s"
    }

    private static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
        var (a, b) = (a, b)
        while b != 0 { (a, b) = (b, a % b) }
        return max(a, 1)
    }

    /// The usual frame duration for a frame rate: NTSC rates as `1001/N000`.
    static func frameDuration(forRate rate: Float) -> CMTime {
        guard rate.isFinite, rate > 1 else { return defaultFrameDuration }
        for base in [24, 30, 48, 60, 120] where abs(Double(rate) - Double(base) * 1000 / 1001) < 0.01 {
            return CMTime(value: 1001, timescale: CMTimeScale(base * 1000))
        }
        return CMTime(value: 1, timescale: CMTimeScale(rate.rounded()))
    }

    // MARK: XML

    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            case "\n", "\r", "\t": result += " "
            default: result.append(character)
            }
        }
        return result
    }

    private static func attributeString(_ attributes: [(String, String)]) -> String {
        attributes.map { "\($0.0)=\"\(escape($0.1))\"" }.joined(separator: " ")
    }

    private static func indent(_ block: String, by levels: Int) -> String {
        let prefix = String(repeating: "    ", count: levels)
        return block.split(separator: "\n", omittingEmptySubsequences: false).map { prefix + $0 }.joined(separator: "\n")
    }

    // MARK: Media

    /// Reads what the export needs from the file: video size and frame rate,
    /// audio layout and start timecode.
    @concurrent
    static func media(url: URL, name: String, duration: Double) async throws -> FCPXMLMedia {
        let asset = AVURLAsset(url: url)
        var media = FCPXMLMedia(url: url, name: name, duration: duration)
        if let video = try await asset.loadTracks(withMediaType: .video).first {
            let (naturalSize, transform, rate) = try await video.load(.naturalSize, .preferredTransform, .nominalFrameRate)
            media.videoSize = CompositionBuilder.presentationSize(naturalSize: naturalSize, transform: transform)
            media.frameDuration = frameDuration(forRate: rate)
        }
        if let audio = try await asset.loadTracks(withMediaType: .audio).first {
            let descriptions = try await audio.load(.formatDescriptions)
            if let description = descriptions.first,
               let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                if format.mSampleRate > 0 { media.audioRate = Int(format.mSampleRate.rounded()) }
                if format.mChannelsPerFrame > 0 { media.audioChannels = Int(format.mChannelsPerFrame) }
            }
        } else {
            media.hasAudio = false
        }
        media.timecodeStart = await timecodeStart(of: asset)
        return media
    }

    /// The time of the file's first timecode sample, or `.zero` if it has none.
    @concurrent
    static func timecodeStart(of asset: AVURLAsset) async -> CMTime {
        guard let track = try? await asset.loadTracks(withMediaType: .timecode).first,
              let reader = try? AVAssetReader(asset: asset) else { return .zero }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { return .zero }
        reader.add(output)
        guard reader.startReading() else { return .zero }
        defer { reader.cancelReading() }
        guard let sample = output.copyNextSampleBuffer(),
              let block = CMSampleBufferGetDataBuffer(sample),
              let format = CMSampleBufferGetFormatDescription(sample) else { return .zero }

        let frameNumber: Int64
        switch CMFormatDescriptionGetMediaSubType(format) {
        case kCMTimeCodeFormatType_TimeCode32:
            var value: Int32 = 0
            let status = withUnsafeMutableBytes(of: &value) { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 4, destination: $0.baseAddress!) }
            guard status == kCMBlockBufferNoErr else { return .zero }
            frameNumber = Int64(Int32(bigEndian: value))
        case kCMTimeCodeFormatType_TimeCode64:
            var value: Int64 = 0
            let status = withUnsafeMutableBytes(of: &value) { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 8, destination: $0.baseAddress!) }
            guard status == kCMBlockBufferNoErr else { return .zero }
            frameNumber = Int64(bigEndian: value)
        default:
            return .zero
        }
        let frame = CMTimeCodeFormatDescriptionGetFrameDuration(format)
        guard frameNumber > 0, frame.isNumeric, frame.value > 0 else { return .zero }
        return CMTime(value: frameNumber * frame.value, timescale: frame.timescale)
    }

    /// Loads each clip's media and writes the document.
    static func document(projectName: String, sources: [(url: URL, name: String, duration: Double, pieces: [KeptPiece])]) async throws -> String {
        var clips: [FCPXMLClip] = []
        for source in sources {
            let loaded = try await media(url: source.url, name: source.name, duration: source.duration)
            clips.append(FCPXMLClip(media: loaded, pieces: source.pieces))
        }
        return document(projectName: projectName, clips: clips)
    }
}

/// An `.fcpxml` file, for the save panel.
nonisolated struct FCPXMLFile: FileDocument {
    static let contentType = UTType(filenameExtension: "fcpxml") ?? .xml
    static var readableContentTypes: [UTType] { [contentType] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
