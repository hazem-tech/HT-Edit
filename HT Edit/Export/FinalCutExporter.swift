//
//  FinalCutExporter.swift
//  HT Edit
//

import AppKit
import AVFoundation
import os

enum FinalCutExportError: LocalizedError {
    case nothingToExport
    case finalCutNotInstalled(URL)

    var errorDescription: String? {
        switch self {
        case .nothingToExport:
            "There's nothing on the timeline to send to Final Cut Pro."
        case .finalCutNotInstalled(let file):
            "Final Cut Pro isn't installed. The project was saved to \(file.path(percentEncoded: false)); open it in Final Cut Pro with File ▸ Import ▸ XML."
        }
    }
}

/// Writes the timeline as FCPXML and opens it in Final Cut Pro.
enum FinalCutExporter {

    static let bundleIdentifiers = ["com.apple.FinalCut", "com.apple.FinalCutTrial"]

    static var finalCutURL: URL? {
        bundleIdentifiers.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    /// Builds the project (clips with the silences cut out, a full-length adjustment clip, and the
    /// transcript as 3-word titles), writes it next to HT Edit's other caches,
    /// and opens it in Final Cut Pro. Returns the written file.
    @discardableResult
    static func open(
        clips: [Clip],
        silences: [CMTimeRange],
        transcript: [TimelineSegment],
        captionTitle: String
    ) async throws -> URL {
        guard !clips.isEmpty else { throw FinalCutExportError.nothingToExport }

        var media: [FCPXML.Media] = []
        for clip in clips {
            media.append(try await mediaInfo(for: clip))
        }

        let projectName = projectName(for: clips)
        let input = FCPXML.Input(
            projectName: projectName,
            media: media,
            silences: silences.map { $0.start.seconds..<$0.end.seconds },
            transcript: transcript.map { FCPXML.Caption(start: $0.start, end: $0.end, text: $0.text) },
            wordsPerTitle: 3,
            captionTitle: TitleTemplates.resolve(captionTitle, installed: TitleTemplates.installed())
        )
        let xml = FCPXML.document(input)

        let directory = URL.cachesDirectory.appending(path: "HT Edit/Final Cut", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: safeFileName(projectName) + ".fcpxml")
        try Data(xml.utf8).write(to: file, options: .atomic)
        Log.export.notice("Wrote \(file.path(percentEncoded: false), privacy: .public)")

        guard let app = finalCutURL else { throw FinalCutExportError.finalCutNotInstalled(file) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        try await NSWorkspace.shared.open([file], withApplicationAt: app, configuration: configuration)
        return file
    }

    /// Project names are unique so Final Cut never refuses one that already exists.
    static func projectName(for clips: [Clip], date: Date = .now) -> String {
        let base = clips.first.map { ($0.name as NSString).deletingPathExtension } ?? "Timeline"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let stamp = formatter.string(from: date)
        return "\(base) (HT Edit \(stamp))"
    }

    private static func safeFileName(_ name: String) -> String {
        String(name.map { "/:\\".contains($0) ? "-" : $0 })
    }

    private static func mediaInfo(for clip: Clip) async throws -> FCPXML.Media {
        let asset = AVURLAsset(url: clip.url)
        var info = FCPXML.Media(
            url: clip.url,
            name: clip.name,
            duration: clip.duration.seconds,
            hasVideo: false,
            hasAudio: false,
            width: 1920,
            height: 1080,
            frameRate: .fps30,
            audioChannels: 2,
            audioRate: 48_000
        )
        if let video = try await asset.loadTracks(withMediaType: .video).first {
            let (naturalSize, transform, nominalRate) = try await video.load(.naturalSize, .preferredTransform, .nominalFrameRate)
            let size = CompositionBuilder.presentationSize(naturalSize: naturalSize, transform: transform)
            info.hasVideo = true
            info.width = Int(size.width.rounded())
            info.height = Int(size.height.rounded())
            info.frameRate = FrameRate.standard(nominal: Double(nominalRate))
        }
        if let audio = try await asset.loadTracks(withMediaType: .audio).first {
            info.hasAudio = true
            let descriptions = try await audio.load(.formatDescriptions)
            if let description = descriptions.first,
               let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                if basic.mChannelsPerFrame > 0 { info.audioChannels = Int(basic.mChannelsPerFrame) }
                if basic.mSampleRate > 0 { info.audioRate = Int(basic.mSampleRate) }
            }
        }
        return info
    }
}
