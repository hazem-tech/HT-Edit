//
//  MediaFixtures.swift
//  HT Edit
//
//  Debug-only generator of real media files for end-to-end tests: unit tests
//  use it through `@testable import`, and UI tests ask the app to generate one
//  inside its own sandbox via the `-UITestFixture` launch argument.
//

#if DEBUG
import AVFoundation
import CoreVideo
import os

nonisolated enum MediaFixtures {

    enum Kind: String, CaseIterable, Sendable {
        /// H.264 1920×1080 QuickTime movie.
        case h264Landscape
        /// HEVC 1280×720 MPEG-4.
        case hevcMP4
        /// 1920×1080 frames with a 90° rotation: displays as 1080×1920 (like iPhone footage).
        case portrait
        /// AAC audio only.
        case audioOnly

        var fileType: AVFileType {
            switch self {
            case .h264Landscape, .portrait: .mov
            case .hevcMP4: .mp4
            case .audioOnly: .m4a
            }
        }

        var fileExtension: String {
            switch self {
            case .h264Landscape, .portrait: "mov"
            case .hevcMP4: "mp4"
            case .audioOnly: "m4a"
            }
        }

        var hasVideo: Bool { self != .audioOnly }

        /// Encoded (pre-rotation) frame size.
        var frameSize: CGSize {
            switch self {
            case .h264Landscape, .portrait: CGSize(width: 1920, height: 1080)
            case .hevcMP4: CGSize(width: 1280, height: 720)
            case .audioOnly: .zero
            }
        }

        /// Size as displayed, after rotation.
        var presentationSize: CGSize {
            self == .portrait ? CGSize(width: frameSize.height, height: frameSize.width) : frameSize
        }

        var codec: AVVideoCodecType {
            self == .hevcMP4 ? .hevc : .h264
        }

        var transform: CGAffineTransform {
            guard self == .portrait else { return .identity }
            return CGAffineTransform(rotationAngle: .pi / 2)
                .concatenating(CGAffineTransform(translationX: frameSize.height, y: 0))
        }
    }

    /// Solid frame color (BGRA): bright green, easy to tell from black.
    static let frameColor: (blue: UInt8, green: UInt8, red: UInt8) = (40, 200, 60)

    /// Writes a 3 s file: tone 0–1 s, digital silence 1–2 s, tone 2–3 s,
    /// plus solid green video frames for kinds with video.
    @concurrent
    static func make(_ kind: Kind, in directory: URL, duration seconds: Double = 3) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = "fixture-\(kind.rawValue)-\(UUID().uuidString)"
        let output = directory.appending(path: "\(base).\(kind.fileExtension)", directoryHint: .notDirectory)
        let audioURL = directory.appending(path: "\(base)-audio.m4a", directoryHint: .notDirectory)
        try writeAudio(to: audioURL, seconds: seconds)

        guard kind.hasVideo else {
            try FileManager.default.moveItem(at: audioURL, to: output)
            return output
        }
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let videoURL = directory.appending(path: "\(base)-video.mov", directoryHint: .notDirectory)
        defer { try? FileManager.default.removeItem(at: videoURL) }
        try await writeVideo(to: videoURL, kind: kind, seconds: seconds)

        try await mux(video: videoURL, audio: audioURL, into: output, fileType: kind.fileType)
        return output
    }

    // MARK: Audio

    private static func writeAudio(to url: URL, seconds: Double) throws {
        let sampleRate = 48_000.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw FixtureError.setup("audio format")
        }
        let frames = AVAudioFrameCount(sampleRate * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channels = buffer.floatChannelData else {
            throw FixtureError.setup("audio buffer")
        }
        buffer.frameLength = frames
        for frame in 0..<Int(frames) {
            let time = Double(frame) / sampleRate
            let isSilent = time >= 1 && time < 2
            let value = isSilent ? 0 : Float(0.5 * sin(2 * .pi * 440 * time))
            channels[0][frame] = value
            channels[1][frame] = value
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
        file.close()
    }

    // MARK: Video

    private static func writeVideo(to url: URL, kind: Kind, seconds: Double) async throws {
        let size = kind.frameSize
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: kind.codec,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        input.transform = kind.transform
        guard writer.canAdd(input) else { throw FixtureError.setup("video input") }
        let receiver = writer.inputReceiver(for: input)
        try writer.start()
        writer.startSession(atSourceTime: .zero)

        let fps: Int32 = 30
        let frameCount = Int(seconds * Double(fps))
        let pixelBuffer = try makeSolidPixelBuffer(size: size)
        let format = try CMVideoFormatDescription(imageBuffer: pixelBuffer)

        for frame in 0..<frameCount {
            let timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: fps),
                presentationTimeStamp: CMTime(value: CMTimeValue(frame), timescale: fps),
                decodeTimeStamp: .invalid
            )
            // `appendImmediately` + a short sleep instead of the async `append`,
            // which has reports of never resuming.
            while true {
                // Every frame shares one read-only pixel buffer that is never
                // mutated after it's filled, so handing it to the writer is safe.
                nonisolated(unsafe) let sample = try CMSampleBuffer(imageBuffer: pixelBuffer, formatDescription: format, sampleTiming: timing)
                if try receiver.appendImmediately(CMReadySampleBuffer(unsafeBuffer: sample)) { break }
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        receiver.finish()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frameCount), timescale: fps))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw FixtureError.writer(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
    }

    private static func makeSolidPixelBuffer(size: CGSize) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, Int(size.width), Int(size.height),
            kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer
        )
        guard status == kCVReturnSuccess, let buffer else { throw FixtureError.setup("pixel buffer \(status)") }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw FixtureError.setup("pixel base address") }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let width = CVPixelBufferGetWidth(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            let line = pixels + row * bytesPerRow
            for column in 0..<width {
                let pixel = line + column * 4
                pixel[0] = frameColor.blue
                pixel[1] = frameColor.green
                pixel[2] = frameColor.red
                pixel[3] = 255
            }
        }
        return buffer
    }

    // MARK: Mux

    private static func mux(video: URL, audio: URL, into output: URL, fileType: AVFileType) async throws {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: audio)
        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
            throw FixtureError.setup("source tracks")
        }
        let (videoRange, transform) = try await videoTrack.load(.timeRange, .preferredTransform)
        let audioRange = try await audioTrack.load(.timeRange)

        let compositionVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        try compositionVideo?.insertTimeRange(videoRange, of: videoTrack, at: .zero)
        compositionVideo?.preferredTransform = transform
        let compositionAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        try compositionAudio?.insertTimeRange(audioRange, of: audioTrack, at: .zero)

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw FixtureError.setup("export session")
        }
        try await session.export(to: output, as: fileType)
    }

    enum FixtureError: Error, CustomStringConvertible {
        case setup(String)
        case writer(String)

        var description: String {
            switch self {
            case .setup(let what): "Fixture setup failed: \(what)"
            case .writer(let reason): "Fixture writer failed: \(reason)"
            }
        }
    }
}

/// Imports a generated fixture when UI tests launch the app with `-UITestFixture <kind>`.
enum UITestSupport {
    static func importFixtureIfRequested(into model: EditorViewModel) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-UITestFixture") else { return }
        let kinds = arguments.dropFirst(flag + 1)
            .prefix { !$0.hasPrefix("-") }
            .compactMap(MediaFixtures.Kind.init(rawValue:))
        let directory = FileManager.default.temporaryDirectory.appending(path: "UITestFixtures", directoryHint: .isDirectory)
        var urls: [URL] = []
        for kind in kinds.isEmpty ? [.h264Landscape] : Array(kinds) {
            let clock = ContinuousClock()
            let start = clock.now
            do {
                urls.append(try await MediaFixtures.make(kind, in: directory))
                Log.importing.notice("UI-test fixture \(kind.rawValue, privacy: .public) generated in \((clock.now - start).description, privacy: .public)")
            } catch {
                Log.importing.error("UI-test fixture \(kind.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                model.errorMessage = "UI test fixture: \(error)"
                return
            }
        }
        model.add(urls: urls)
    }
}
#endif
