# HT Edit

A native macOS video editor built for Apple silicon. The first feature is **silence detection**: import a video, and every silent stretch is highlighted on the audio waveform right away. You can tune the highlights live.

## Features

- Import with **⌘O**, the toolbar button, or drag and drop.
- Video preview, plus a zoomable, scrollable waveform timeline. Pinch or use the zoom slider; click or drag on the timeline to seek.
- Silences are highlighted in red and update instantly as you move the sliders:
  - **Threshold (dB):** audio quieter than this counts as silence. The orange dashed line on the waveform shows it.
  - **Padding start:** audio kept after speech ends.
  - **Padding end:** audio kept before speech resumes.
  - **Minimum silence:** shorter pauses are ignored.
- **Skip silences** plays the video with the highlighted parts skipped, so you can hear the result.
- Stats: number of silences, total silence, and the length without silences.

## Architecture

| Layer | File(s) | Notes |
|---|---|---|
| Decode + measure | `Audio/AudioLevelAnalyzer.swift` | Async `AVAssetReaderOutput.Provider`, native sample rate, vDSP downmix/RMS/peak/dB, streamed as `AsyncThrowingStream` chunks, cancellable |
| Detection | `Analysis/SilenceDetector.swift` | Pure, single linear pass over cached levels; sample-accurate `CMTimeRange`s |
| Playback skipping | `Analysis/PlaybackSkipper.swift`, `ViewModel/EditorViewModel.swift` | O(log n) lookup; boundary time observers at each silence start |
| Waveform | `Waveform/WaveformSampler.swift`, `Views/WaveformCanvas.swift` | Draws only the visible viewport (cost independent of media length), Metal-backed `Canvas` |
| UI | `ContentView.swift`, `Views/*` | SwiftUI + Observation, inspector, `VideoPlayer` |

The audio is decoded once per import. After that, a slider change only re-runs `SilenceDetector` over the cached per-window levels (10 ms windows), which takes about a millisecond even for an hour of audio.

Project settings: Swift 6 language mode, MainActor-by-default isolation, macOS 27 deployment target. Heavy work runs in `@concurrent` functions off the main actor.

## Building and testing

Open `HT Edit.xcodeproj` in Xcode, then:
- **⌘R** to run the app.
- **⌘U** to run the unit tests (Swift Testing) and UI tests (XCTest).

The unit tests cover the detector, padding and threshold rules, dB math, windowing, waveform bucketing, playback skipping, time formatting, and the view model. They also include an end-to-end test that writes a tone/silence/tone audio file and analyzes it through AVFoundation.
