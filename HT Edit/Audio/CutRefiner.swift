//
//  CutRefiner.swift
//  HT Edit
//

import AVFoundation

/// Moves word cut points to the exact sample, the way editors cut cleanly
/// without fades:
///
/// 1. In the pause around the cut, find the quietest few milliseconds by
///    **peak** (the loudest sample in them), so nothing sharp — a click, a
///    breath, the burst of a "t", the hiss of an "s" — is in the way.
///    Among equally quiet stretches, the one nearest the middle of the pause.
/// 2. Inside it, cut on a **zero crossing**: the sample where the wave passes
///    through zero. Cutting anywhere else leaves a jump in the wave, which is
///    heard as a click.
/// 3. The cut's end point takes a crossing going the same way (rising or
///    falling) as its start, so the wave carries on smoothly across the join.
///
/// `WordCutPlanner` places cuts from the 10 ms levels first, so the edit
/// updates at once; this refines them from the samples.
nonisolated enum CutRefiner {
    /// The stretch whose peak is compared.
    static let windowSeconds = 0.005
    /// How far apart compared stretches start.
    static let stepSeconds = 0.001
    /// Stretches whose peak is within this factor of the lowest (1 dB) count as just as quiet.
    static let quietFactor: Float = 1.122
    /// The most audio read around one cut point.
    static let maximumSearch = 2.0

    /// A cut point on the samples.
    struct Point: Equatable, Sendable {
        /// Seconds, in the same time as the samples' `startTime`.
        var time: Double
        /// Whether the wave rises through zero here; `nil` when there's no crossing.
        var rising: Bool?
    }

    // MARK: Pure

    /// The best cut point in `search` (seconds) of `samples`, which start at
    /// `startTime`. `preferred` breaks ties between equally quiet stretches;
    /// `direction` is the crossing direction to prefer, if any.
    static func point(
        in samples: [Float],
        sampleRate: Double,
        startTime: Double,
        search: ClosedRange<Double>,
        preferred: Double,
        direction: Bool? = nil
    ) -> Point? {
        guard sampleRate > 0, !samples.isEmpty else { return nil }
        func index(_ time: Double) -> Int { Int(((time - startTime) * sampleRate).rounded()) }
        let lower = max(0, index(search.lowerBound))
        let upper = min(samples.count, index(search.upperBound))
        guard upper - lower >= 2 else { return nil }

        let window = max(2, Int((windowSeconds * sampleRate).rounded()))
        let step = max(1, Int((stepSeconds * sampleRate).rounded()))

        // Peak of each window start, the last one clamped to the range.
        var starts: [Int] = Array(stride(from: lower, through: max(lower, upper - window), by: step))
        if let last = starts.last, last + window < upper { starts.append(upper - window) }
        let peaks = starts.map { start in
            samples[start..<min(upper, start + window)].reduce(Float(0)) { max($0, abs($1)) }
        }
        guard let minimum = peaks.min() else { return nil }
        let preferredIndex = Double(index(preferred))
        let chosen = zip(starts, peaks)
            .filter { $0.1 <= minimum * quietFactor + .ulpOfOne }
            .min { abs(Double($0.0 + window / 2) - preferredIndex) < abs(Double($1.0 + window / 2) - preferredIndex) }?.0 ?? starts[0]

        let windowRange = chosen..<min(upper, chosen + window)
        let center = Double(windowRange.lowerBound + windowRange.upperBound) / 2
        func time(_ sample: Int) -> Double { startTime + Double(sample) / sampleRate }

        // Zero crossings in the window: between i and i + 1, the sign changes.
        var crossings: [(sample: Int, rising: Bool)] = []
        for i in windowRange.lowerBound..<(windowRange.upperBound - 1) {
            let a = samples[i], b = samples[i + 1]
            guard (a <= 0 && b > 0) || (a >= 0 && b < 0) else { continue }
            // Cut on whichever of the two is nearer zero.
            crossings.append((sample: abs(a) <= abs(b) ? i : i + 1, rising: b > a))
        }
        let matching = direction.map { want in crossings.filter { $0.rising == want } } ?? []
        let pool = matching.isEmpty ? crossings : matching
        if let best = pool.min(by: { abs(Double($0.sample) - center) < abs(Double($1.sample) - center) }) {
            return Point(time: time(best.sample), rising: best.rising)
        }
        // No crossing (digital silence, or an offset): the sample nearest zero.
        let quietest = windowRange.min { abs(samples[$0]) < abs(samples[$1]) } ?? windowRange.lowerBound
        return Point(time: time(quietest), rising: nil)
    }

    // MARK: Refining a cut

    /// `cut` with both points moved to the exact sample, reading the audio of
    /// `source` around them. Points without a search range are left as they are.
    @concurrent
    static func refine(_ cut: WordCut, source: URL) async throws -> WordCut {
        var cut = cut
        var direction: Bool?
        if let search = cut.startSearch {
            let audio = try await samples(of: source, around: search)
            if let point = point(
                in: audio.samples, sampleRate: audio.sampleRate, startTime: audio.startTime,
                search: search, preferred: cut.startPreferred ?? cut.start
            ) {
                cut.start = point.time
                direction = point.rising
            }
        }
        if let search = cut.endSearch {
            let audio = try await samples(of: source, around: search)
            if let point = point(
                in: audio.samples, sampleRate: audio.sampleRate, startTime: audio.startTime,
                search: search, preferred: cut.endPreferred ?? cut.end, direction: direction
            ) {
                cut.end = point.time
            }
        }
        return cut
    }

    /// Mono samples of `source` covering `range` (seconds, capped at
    /// `maximumSearch`), at the file's own sample rate so nothing is resampled.
    @concurrent
    static func samples(of source: URL, around range: ClosedRange<Double>) async throws -> (samples: [Float], sampleRate: Double, startTime: Double) {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AnalysisError.noAudioTrack
        }
        let formats = try await track.load(.formatDescriptions)
        guard let rate = formats.first?.audioStreamBasicDescription?.mSampleRate, rate > 0 else {
            throw AnalysisError.unsupportedFormat
        }
        let start = max(0, range.lowerBound)
        let duration = min(maximumSearch, max(0, range.upperBound - start))
        let timescale = CMTimeScale(rate.rounded())
        let expected = Int((duration * rate).rounded())
        guard expected > 0 else { return ([], rate, start) }

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: timescale),
            duration: CMTime(value: CMTimeValue(expected), timescale: timescale)
        )
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        let provider = reader.outputProvider(for: output)
        try reader.start()
        defer {
            if reader.status == .reading { reader.cancelReading() }
        }

        var samples: [Float] = []
        samples.reserveCapacity(expected)
        // Stop once every sample is in instead of waiting for the end of data.
        while samples.count < expected, let sampleBuffer = try await provider.next() {
            try Task.checkCancellation()
            try sampleBuffer.withUnsafeSampleBuffer { buffer in
                try buffer.withAudioBufferList { list, _ in
                    for channel in list {
                        guard let data = channel.mData else { continue }
                        let count = Int(channel.mDataByteSize) / MemoryLayout<Float>.stride
                        samples.append(contentsOf: UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
                    }
                }
            }
        }
        guard reader.status != .failed else { throw reader.error ?? AnalysisError.unsupportedFormat }
        return (Array(samples.prefix(expected)), rate, start)
    }
}
