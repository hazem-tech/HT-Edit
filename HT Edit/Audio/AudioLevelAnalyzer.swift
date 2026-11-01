//
//  AudioLevelAnalyzer.swift
//  HT Edit
//

import Accelerate
import AVFoundation
import os

nonisolated enum AnalysisError: LocalizedError, Equatable {
    case noAudioTrack
    case unsupportedFormat
    case readerFailed(String)
    /// A reader stopped delivering audio (a known AVFoundation failure mode).
    case stalled
    /// A segment produced no audio at all.
    case emptySegment

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: "This file has no audio track."
        case .unsupportedFormat: "The audio format of this file isn't supported."
        case .readerFailed(let reason): "Couldn't read the audio: \(reason)"
        case .stalled: "Reading the audio stopped responding."
        case .emptySegment: "Part of the audio couldn't be read."
        }
    }
}

/// Decodes the first audio track of a media file and measures its loudness
/// in fixed windows, streaming results as they become available.
///
/// - The track is split into window-aligned segments decoded **in parallel**
///   with the async `AVAssetReaderOutput.Provider` API. A shared
///   `ReaderLimiter` caps readers across all clips so playback stays smooth.
/// - Every reader runs under a `StallWatchdog`. If a segmented read stalls or
///   fails, the whole track is re-read with one reader; analysis always ends.
/// - Every segment emits its first windows immediately, so the waveform appears
///   at several places at once and fills in.
/// - All DSP (downmix, RMS, peak, dB conversion) runs through Accelerate/vDSP.
/// - Results are cached on disk; re-importing a file is instant.
nonisolated struct AudioLevelAnalyzer: Sendable {
    /// Length of one analysis window, in seconds.
    var windowDuration: Double = 0.010
    /// Minimum wall-clock time between chunks from one segment. `.zero` emits after every decoded buffer.
    var chunkInterval: Duration = .milliseconds(50)
    /// Number of parallel segments; `nil` uses the reader limit (short files use one).
    var segmentCount: Int?
    /// Shortest segment worth its own reader, in windows.
    var minimumWindowsPerSegment = AudioSegmentPlanner.minimumWindowsPerSegment
    /// On-disk cache of finished analyses; `nil` disables caching.
    var cache: LevelsCache? = .shared
    /// Shared cap on concurrently running readers.
    var limiter: ReaderLimiter = .shared
    /// A reader that delivers nothing for this long is abandoned.
    var stallTimeout: Duration = .seconds(8)

    /// Streams level chunks for the file at `url`. Cancelling the consuming task
    /// (or dropping the stream) stops decoding.
    func levels(for url: URL) -> AsyncThrowingStream<AudioLevelsChunk, any Error> {
        let analyzer = self
        return AsyncThrowingStream { continuation in
            let task = Task(priority: .utility) {
                do {
                    try await analyzer.analyze(url: url) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Convenience: analyzes the whole file and returns the finished levels.
    func analyzeAll(url: URL) async throws -> AudioLevels {
        var levels = AudioLevels.empty
        for try await chunk in self.levels(for: url) {
            levels.apply(chunk)
        }
        levels.isComplete = true
        return levels
    }

    // MARK: Pipeline

    struct TrackLayout: Sendable {
        var sampleRate: Int32
        var framesPerWindow: Int
        var totalFrames: Int
        var totalWindows: Int
        var trackStart: CMTime
    }

    @concurrent
    private func analyze(url: URL, emit: @escaping @Sendable (AudioLevelsChunk) -> Void) async throws {
        let name = url.lastPathComponent
        let signpostID = Log.signposter.makeSignpostID()
        let interval = Log.signposter.beginInterval("Analyze audio", id: signpostID)
        defer { Log.signposter.endInterval("Analyze audio", interval) }
        let clock = ContinuousClock()
        let started = clock.now

        let cacheKey = cache.flatMap { _ in LevelsCache.key(for: url, windowDuration: windowDuration) }
        if let cache, let cacheKey, let cached = await cache.load(key: cacheKey) {
            Log.analysis.notice("\(name, privacy: .public): served from cache")
            emit(AudioLevelsChunk(
                sampleRate: cached.sampleRate,
                framesPerWindow: cached.framesPerWindow,
                totalWindows: cached.windowCount,
                totalFrames: cached.frameCount,
                windowOffset: 0,
                rmsDB: cached.rmsDB,
                peakDB: cached.peakDB
            ))
            return
        }

        let layout = try await Self.layout(of: url, windowDuration: windowDuration)
        guard layout.totalWindows > 0 else {
            Log.analysis.notice("\(name, privacy: .public): empty audio track")
            return
        }

        let segments = AudioSegmentPlanner.segments(
            totalWindows: layout.totalWindows,
            count: segmentCount ?? limiter.limit,
            minimumWindowsPerSegment: minimumWindowsPerSegment
        )
        Log.analysis.notice("\(name, privacy: .public): \(layout.totalWindows) windows at \(layout.sampleRate) Hz in \(segments.count) segment(s)")

        var levels: AudioLevels
        do {
            levels = try await decode(url: url, segments: segments, layout: layout, emit: emit)
        } catch let error where segments.count > 1 && !(error is CancellationError) {
            // Parallel reads failed or stalled: re-read the whole track with one reader.
            Log.analysis.error("\(name, privacy: .public): segmented read failed (\(error.localizedDescription, privacy: .public)); falling back to one reader")
            levels = try await decode(url: url, segments: [0..<layout.totalWindows], layout: layout, emit: emit)
        }

        try Task.checkCancellation()
        Log.analysis.notice("\(name, privacy: .public): analyzed in \((clock.now - started).description, privacy: .public)")
        if let cache, let cacheKey {
            levels.isComplete = true
            await cache.store(levels, key: cacheKey)
        }
    }

    /// Decodes `segments` concurrently (bounded by the limiter) and returns the assembled levels.
    private func decode(
        url: URL,
        segments: [Range<Int>],
        layout: TrackLayout,
        emit: @escaping @Sendable (AudioLevelsChunk) -> Void
    ) async throws -> AudioLevels {
        let limiter = limiter
        let chunkInterval = chunkInterval
        let stallTimeout = stallTimeout

        var levels = AudioLevels.empty
        try await withThrowingTaskGroup(of: AudioLevelsChunk.self) { group in
            for segment in segments {
                group.addTask {
                    await limiter.acquire()
                    let progress = ProgressMarker()
                    do {
                        let result = try await StallWatchdog.run(timeout: stallTimeout, progress: progress) {
                            try await Self.decodeSegment(
                                url: url,
                                windows: segment,
                                isLast: segment.upperBound == layout.totalWindows,
                                layout: layout,
                                chunkInterval: chunkInterval,
                                progress: progress,
                                emit: emit
                            )
                        }
                        await limiter.release()
                        return result
                    } catch {
                        await limiter.release()
                        throw error
                    }
                }
            }
            for try await segmentResult in group {
                levels.apply(segmentResult)
            }
        }
        return levels
    }

    static func layout(of url: URL, windowDuration: Double) async throws -> TrackLayout {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AnalysisError.noAudioTrack
        }
        let (timeRange, formats) = try await track.load(.timeRange, .formatDescriptions)
        guard let rate = formats.first?.audioStreamBasicDescription?.mSampleRate, rate > 0 else {
            throw AnalysisError.unsupportedFormat
        }
        let timescale = Int32(rate.rounded())
        let totalFrames = Int(timeRange.duration.convertScale(timescale, method: .roundHalfAwayFromZero).value)
        let framesPerWindow = WindowAccumulator.framesPerWindow(sampleRate: rate, windowDuration: windowDuration)
        return TrackLayout(
            sampleRate: timescale,
            framesPerWindow: framesPerWindow,
            totalFrames: max(0, totalFrames),
            totalWindows: max(0, (totalFrames + framesPerWindow - 1) / framesPerWindow),
            trackStart: timeRange.start
        )
    }

    /// Decodes one segment, emitting progress chunks, and returns the whole segment
    /// padded/trimmed to exactly `windows.count` windows so timings stay exact.
    @concurrent
    private static func decodeSegment(
        url: URL,
        windows: Range<Int>,
        isLast: Bool,
        layout: TrackLayout,
        chunkInterval: Duration,
        progress: ProgressMarker,
        emit: @Sendable (AudioLevelsChunk) -> Void
    ) async throws -> AudioLevelsChunk {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AnalysisError.noAudioTrack
        }

        let reader = try AVAssetReader(asset: asset)
        let startFrame = windows.lowerBound * layout.framesPerWindow
        let endFrame = isLast ? layout.totalFrames : windows.upperBound * layout.framesPerWindow
        let expectedFrames = max(0, endFrame - startFrame)
        let isWholeTrack = windows.lowerBound == 0 && isLast
        if !isWholeTrack {
            // Always a finite range: an open-ended range never signals the end of data.
            reader.timeRange = CMTimeRange(
                start: layout.trackStart + CMTime(value: CMTimeValue(startFrame), timescale: layout.sampleRate),
                duration: CMTime(value: CMTimeValue(expectedFrames), timescale: layout.sampleRate)
            )
        }
        Log.analysis.notice("Segment \(windows.lowerBound)..<\(windows.upperBound): reading \(expectedFrames) frames")

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
        ])
        let provider = reader.outputProvider(for: output)
        try reader.start()
        defer {
            if reader.status == .reading { reader.cancelReading() }
        }

        var accumulator = WindowAccumulator(framesPerWindow: layout.framesPerWindow)
        var rms: [Float] = []
        var peak: [Float] = []
        rms.reserveCapacity(windows.count)
        peak.reserveCapacity(windows.count)

        let clock = ContinuousClock()
        var lastEmit: ContinuousClock.Instant?

        func chunk(rms: ArraySlice<Float>, peak: ArraySlice<Float>, at offset: Int) -> AudioLevelsChunk {
            AudioLevelsChunk(
                sampleRate: layout.sampleRate,
                framesPerWindow: layout.framesPerWindow,
                totalWindows: layout.totalWindows,
                totalFrames: layout.totalFrames,
                windowOffset: offset,
                rmsDB: Array(rms),
                peakDB: Array(peak)
            )
        }

        // Stop as soon as the segment has all its frames instead of asking the
        // provider for more: never depend on it signalling the end of data.
        var decodedFrames = 0
        while decodedFrames < expectedFrames, let sampleBuffer = try await provider.next() {
            try Task.checkCancellation()
            progress.touch()
            decodedFrames += sampleBuffer.sampleCount
            try sampleBuffer.withUnsafeSampleBuffer { buffer in
                try accumulator.consume(buffer)
            }
            let now = clock.now
            if lastEmit.map({ now - $0 >= chunkInterval }) ?? true, let batch = accumulator.drain() {
                let offset = rms.count
                let room = windows.count - offset
                rms.append(contentsOf: batch.rmsDB.prefix(room))
                peak.append(contentsOf: batch.peakDB.prefix(room))
                emit(chunk(rms: rms[offset...], peak: peak[offset...], at: windows.lowerBound + offset))
                lastEmit = now
            }
        }

        if reader.status == .failed {
            throw AnalysisError.readerFailed(reader.error?.localizedDescription ?? "Unknown error")
        }
        try Task.checkCancellation()
        Log.analysis.notice("Segment \(windows.lowerBound)..<\(windows.upperBound): decoded \(decodedFrames) frames")
        guard decodedFrames > 0 else { throw AnalysisError.emptySegment }

        let emittedCount = rms.count
        if let batch = accumulator.finish() {
            let room = windows.count - rms.count
            rms.append(contentsOf: batch.rmsDB.prefix(room))
            peak.append(contentsOf: batch.peakDB.prefix(room))
        }
        // Decoders can deliver a few frames less than requested; repeat the last
        // value so the segment keeps its exact length.
        if rms.count < windows.count {
            let missing = windows.count - rms.count
            rms.append(contentsOf: repeatElement(rms.last ?? AudioLevels.floorDB, count: missing))
            peak.append(contentsOf: repeatElement(peak.last ?? AudioLevels.floorDB, count: missing))
        }
        if rms.count > emittedCount {
            emit(chunk(rms: rms[emittedCount...], peak: peak[emittedCount...], at: windows.lowerBound + emittedCount))
        }
        return chunk(rms: rms[...], peak: peak[...], at: windows.lowerBound)
    }
}

/// A run of completed windows, in dBFS.
nonisolated struct WindowBatch: Sendable, Equatable {
    var rmsDB: [Float]
    var peakDB: [Float]
    var frameCount: Int
}

/// Turns arbitrary-sized PCM buffers into fixed-size loudness windows.
nonisolated struct WindowAccumulator {
    let framesPerWindow: Int

    /// Mono samples not yet forming a full window.
    private var pending: [Float] = []
    /// Linear RMS / peak of completed windows not yet drained.
    private var rms: [Float] = []
    private var peak: [Float] = []
    private var framesInBatch = 0

    init(framesPerWindow: Int) {
        self.framesPerWindow = max(1, framesPerWindow)
        pending.reserveCapacity(self.framesPerWindow * 2)
    }

    static func framesPerWindow(sampleRate: Double, windowDuration: Double) -> Int {
        max(1, Int((sampleRate * windowDuration).rounded()))
    }

    /// Downmixes a non-interleaved Float32 PCM sample buffer to mono and appends it.
    mutating func consume(_ buffer: CMSampleBuffer) throws {
        try buffer.withAudioBufferList { list, _ in
            guard let first = list.first else { return }
            guard first.mNumberChannels == 1 else { throw AnalysisError.unsupportedFormat }
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.stride
            guard frames > 0 else { return }

            let channels = list.compactMap { channel -> UnsafeBufferPointer<Float>? in
                guard let data = channel.mData else { return nil }
                return UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: frames)
            }
            appendMono(channels: channels, frames: frames)
        }
    }

    /// Appends the average of `channels` (each `frames` long) as mono samples.
    mutating func appendMono(channels: [UnsafeBufferPointer<Float>], frames: Int) {
        guard !channels.isEmpty, frames > 0 else { return }
        let offset = pending.count
        pending.append(contentsOf: repeatElement(0, count: frames))
        pending.withUnsafeMutableBufferPointer { storage in
            var mono = UnsafeMutableBufferPointer(rebasing: storage[offset..<(offset + frames)])
            for channel in channels {
                let current = UnsafeBufferPointer(mono)
                vDSP.add(current, channel, result: &mono)
            }
            if channels.count > 1 {
                let current = UnsafeBufferPointer(mono)
                vDSP.multiply(1 / Float(channels.count), current, result: &mono)
            }
        }
        processFullWindows()
    }

    /// Returns the windows completed since the last drain, or `nil` if there are none.
    mutating func drain() -> WindowBatch? {
        guard !rms.isEmpty else { return nil }
        let batch = WindowBatch(
            rmsDB: Self.decibels(rms),
            peakDB: Self.decibels(peak),
            frameCount: framesInBatch
        )
        rms.removeAll(keepingCapacity: true)
        peak.removeAll(keepingCapacity: true)
        framesInBatch = 0
        return batch
    }

    /// Flushes the trailing partial window and returns everything not yet drained.
    mutating func finish() -> WindowBatch? {
        if !pending.isEmpty {
            let (windowRMS, windowPeak) = pending.withUnsafeBufferPointer { samples in
                (vDSP.rootMeanSquare(samples), vDSP.maximumMagnitude(samples))
            }
            rms.append(windowRMS)
            peak.append(windowPeak)
            framesInBatch += pending.count
            pending.removeAll()
        }
        return drain()
    }

    /// Converts linear amplitudes to dBFS, flooring silence (and -inf) at `AudioLevels.floorDB`.
    static func decibels(_ amplitudes: [Float]) -> [Float] {
        guard !amplitudes.isEmpty else { return [] }
        let decibels = vDSP.amplitudeToDecibels(amplitudes, zeroReference: 1)
        return vDSP.clip(decibels, to: AudioLevels.floorDB...Float.greatestFiniteMagnitude)
    }

    private mutating func processFullWindows() {
        let windowCount = pending.count / framesPerWindow
        guard windowCount > 0 else { return }
        let size = framesPerWindow
        let (windowRMS, windowPeak) = pending.withUnsafeBufferPointer { samples in
            var windowRMS: [Float] = []
            var windowPeak: [Float] = []
            windowRMS.reserveCapacity(windowCount)
            windowPeak.reserveCapacity(windowCount)
            for window in 0..<windowCount {
                let slice = UnsafeBufferPointer(rebasing: samples[(window * size)..<((window + 1) * size)])
                windowRMS.append(vDSP.rootMeanSquare(slice))
                windowPeak.append(vDSP.maximumMagnitude(slice))
            }
            return (windowRMS, windowPeak)
        }
        rms.append(contentsOf: windowRMS)
        peak.append(contentsOf: windowPeak)
        pending.removeFirst(windowCount * size)
        framesInBatch += windowCount * size
    }
}
