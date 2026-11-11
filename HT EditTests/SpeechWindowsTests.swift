//
//  SpeechWindowsTests.swift
//  HT EditTests
//

import Foundation
import Testing
@testable import HT_Edit

struct SpeechWindowsTests {

    /// Loudness frames (20 ms each): speech at -20 dB, silence at -60 dB.
    private func frames(_ parts: [(speech: Bool, seconds: Double)]) -> [Float] {
        parts.flatMap { Array(repeating: $0.speech ? Float(-20) : -60, count: Int(($0.seconds / SpeechWindows.hop).rounded())) }
    }

    @Test func silenceGivesNoWindows() {
        #expect(SpeechWindows.plan(levels: frames([(false, 10)]), duration: 10).isEmpty)
    }

    @Test func shortTalkIsOneWindowWithPadding() {
        let windows = SpeechWindows.plan(levels: frames([(false, 1), (true, 3), (false, 0.5), (true, 2), (false, 2)]), duration: 8.5)
        #expect(windows.count == 1)
        #expect(abs(windows[0].lowerBound - 0.75) < 0.03)
        #expect(abs(windows[0].upperBound - 6.75) < 0.03)
    }

    @Test func windowsCloseAtPausesBeforeTheLimit() {
        // Five 8 s sentences separated by 1 s pauses: a 25 s window holds two of them.
        let parts = (0..<5).flatMap { _ in [(true, 8.0), (false, 1.0)] }
        let windows = SpeechWindows.plan(levels: frames(parts), duration: 45)
        #expect(windows.count == 3)
        for window in windows {
            #expect(window.upperBound - window.lowerBound <= 25.6)
        }
        for (a, b) in zip(windows, windows.dropFirst()) {
            #expect(a.upperBound <= b.lowerBound, "windows never overlap")
        }
    }

    @Test func longGapsStartANewWindow() {
        let windows = SpeechWindows.plan(levels: frames([(true, 3), (false, 8), (true, 3)]), duration: 14)
        #expect(windows.count == 2)
    }

    @Test func nonstopSpeechIsSplitBelowTheLimit() {
        var levels = frames([(true, 60)])
        levels[1500] = -60  // a quiet instant at 30 s
        let windows = SpeechWindows.plan(levels: levels, duration: 60)
        #expect(windows.count >= 3)
        #expect(windows.allSatisfy { $0.upperBound - $0.lowerBound <= 25.6 })
    }

    @Test func wavFileIs16kMono16Bit() async throws {
        let directory = makeTemporaryDirectory("wav")
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = try await MediaFixtures.make(.audioOnly, in: directory, duration: 2)
        let wav = directory.appending(path: "out.wav")
        try await MonoAudio.writeWAV(from: audio, to: wav)
        let data = try Data(contentsOf: wav)
        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
        let channels = data[22..<24].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
        let rate = data[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(channels == 1)
        #expect(rate == 16_000)
        #expect(abs(Double(data.count - 44) / 32_000 - 2) < 0.05)
    }
}
