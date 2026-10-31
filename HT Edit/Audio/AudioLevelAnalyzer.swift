//
//  AudioLevelAnalyzer.swift
//  HT Edit
//

import Accelerate
import AVFoundation

nonisolated enum AnalysisError: LocalizedError, Equatable {
    case noAudioTrack
    case unsupportedFormat
    case readerFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: "This file has no audio track."
        case .unsupportedFormat: "The audio format of this file isn't supported."
        case .readerFailed(let reason): "Couldn't read the audio: \(reason)"
        }
    }
}

/// Decodes the first audio track of a media file and measures its loudness
/// in fixed windows, streaming results as they become available.
///
/// - Decoding uses the async `AVAssetReaderOutput.Provider` API.
/// - All DSP (downmix, RMS, peak, dB conversion) runs through Accelerate/vDSP.
/// - Audio is read at its native sample rate; nothing is resampled.
nonisolated struct AudioLevelAnalyzer: Sendable {
    /// Length of one analysis window, in seconds.
    var windowDuration: Double = 0.010
    /// Minimum wall-clock time between emitted chunks. `.zero` emits after every decoded buffer.
    var chunkInterval: Duration = .milliseconds(100)

    /// Streams level chunks for the file at `url`. Cancelling the consuming task
    /// (or dropping the stream) stops decoding.
    func levels(for url: URL) -> AsyncThrowingStream<AudioLevelsChunk, any Error> {
        let analyzer = self
        return AsyncThrowingStream { continuation in
            let task = Task {
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

    /// Convenience: analyzes the whole file and returns the accumulated levels.
    func analyzeAll(url: URL) async throws -> AudioLevels {
        var levels = AudioLevels.empty
        for try await chunk in self.levels(for: url) {
            levels.append(chunk)
        }
        levels.isComplete = true
        return levels
    }

    @concurrent
    private func analyze(url: URL, emit: @Sendable (AudioLevelsChunk) -> Void) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AnalysisError.noAudioTrack
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
        ])
        output.alwaysCopiesSampleData = false
        let provider = reader.outputProvider(for: output)
        try reader.start()
        defer {
            if reader.status == .reading { reader.cancelReading() }
        }

        var accumulator = WindowAccumulator(windowDuration: windowDuration)
        let clock = ContinuousClock()
        var lastEmit = clock.now

        while let sampleBuffer = try await provider.next() {
            try Task.checkCancellation()
            try sampleBuffer.withUnsafeSampleBuffer { buffer in
                try accumulator.consume(buffer)
            }
            let now = clock.now
            if now - lastEmit >= chunkInterval, let chunk = accumulator.drain() {
                emit(chunk)
                lastEmit = now
            }
        }

        if reader.status == .failed {
            throw AnalysisError.readerFailed(reader.error?.localizedDescription ?? "Unknown error")
        }
        try Task.checkCancellation()
        if let chunk = accumulator.finish() {
            emit(chunk)
        }
    }
}

/// Turns arbitrary-sized PCM buffers into fixed-size loudness windows.
nonisolated struct WindowAccumulator {
    let windowDuration: Double

    private(set) var sampleRate: Int32 = 0
    private(set) var framesPerWindow = 0
    /// Mono samples not yet forming a full window.
    private var pending: [Float] = []
    /// Linear RMS / peak of completed windows not yet emitted.
    private var rms: [Float] = []
    private var peak: [Float] = []
    private var framesInChunk = 0

    init(windowDuration: Double) {
        self.windowDuration = windowDuration
    }

    /// Configures the window size for `sampleRate`. Called automatically by `consume(_:)`.
    mutating func configure(sampleRate: Double) {
        guard framesPerWindow == 0 else { return }
        self.sampleRate = Int32(sampleRate.rounded())
        framesPerWindow = max(1, Int((sampleRate * windowDuration).rounded()))
        pending.reserveCapacity(framesPerWindow * 2)
    }

    /// Downmixes a non-interleaved Float32 PCM sample buffer to mono and appends it.
    mutating func consume(_ buffer: CMSampleBuffer) throws {
        if framesPerWindow == 0 {
            guard let rate = buffer.formatDescription?.audioStreamBasicDescription?.mSampleRate,
                  rate > 0 else {
                throw AnalysisError.unsupportedFormat
            }
            configure(sampleRate: rate)
        }

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
    mutating func drain() -> AudioLevelsChunk? {
        guard !rms.isEmpty else { return nil }
        let chunk = AudioLevelsChunk(
            sampleRate: sampleRate,
            framesPerWindow: framesPerWindow,
            rmsDB: Self.decibels(rms),
            peakDB: Self.decibels(peak),
            frameCount: framesInChunk
        )
        rms.removeAll(keepingCapacity: true)
        peak.removeAll(keepingCapacity: true)
        framesInChunk = 0
        return chunk
    }

    /// Flushes the trailing partial window and returns everything not yet drained.
    mutating func finish() -> AudioLevelsChunk? {
        if !pending.isEmpty {
            let (windowRMS, windowPeak) = pending.withUnsafeBufferPointer { samples in
                (vDSP.rootMeanSquare(samples), vDSP.maximumMagnitude(samples))
            }
            rms.append(windowRMS)
            peak.append(windowPeak)
            framesInChunk += pending.count
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
        framesInChunk += windowCount * size
    }
}
