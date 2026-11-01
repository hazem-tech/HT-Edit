# HT Edit

A native macOS video editor built for Apple silicon. The first feature is **silence detection**: import one or more videos, and every silent stretch is highlighted on the audio waveform right away. You can tune the highlights live, and playback skips the silences.

## Features

- **Import:** ⌘O, the **+** toolbar button, or drag and drop. You can import several files at once; new clips are added to the end.
- **One seamless timeline:** a yellow line marks where each clip starts.
- **Clip sidebar:** shows each clip's thumbnail, name and length. Drag clips to reorder them. Show or hide it with the system sidebar button.
- **Vertical video:** if the video is taller than it is wide, the player sits beside the timeline instead of above it. This is automatic.
- **Live settings:** threshold (dB), padding start and padding end. Highlights update instantly.
- **Playback:** always skips the highlighted silences.
- **Arabic speech-to-text, on this Mac:** the **Speech Models** toolbar button lists every model that runs offline, understands Arabic and gives timestamps. Download the ones you want to try and pick one, then click **Transcribe Arabic** in the inspector's **Transcript** tab. Each clip's timed text appears as soon as it's done. Click a line or a word to jump there; the line being spoken is highlighted during playback.

## Speech-to-text models

Models download once, then transcription runs entirely offline.

| Source | Models listed | Why |
|---|---|---|
| [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) (Core ML Whisper from Hugging Face, `argmaxinc/whisperkit-coreml`) | Every multilingual variant this Mac supports: Tiny → Large v3, Large v3 Turbo, plus compressed and Turbo builds | Arabic and word timestamps |
| Apple `SpeechTranscriber` (Speech framework) | Arabic locales, only if this Mac's on-device model supports them | Word time ranges; installed and updated by macOS |

Not listed: English-only Whisper (`*.en`, Distil-Whisper); models without timestamps (Jais-ASR, Cohere Transcribe Arabic, omniASR, Moonshine Arabic) even though some are more accurate on Arabic; and models without Arabic (Parakeet, SenseVoice). Whisper models are stored in the app's Application Support folder. A model counts as downloaded only after it has been loaded once, which fetches its tokenizer and compiles it for this Mac.

## Speed

- **Parallel decoding:** each file's audio is split into segments that are decoded concurrently, one reader per core.
- **Progressive waveform:** each segment shows its first windows right away, so the waveform fills in from several places at once.
- **Instant playback:** the timeline and playback are ready as soon as the clip's duration has loaded. The video is drawn with a bare `AVPlayerLayer`.
- **Cache:** finished analyses are stored in the app's Caches folder, so re-importing a file is instant.
- **Warm-up at launch:** a splash screen runs the full import path once on a tiny generated clip. This loads the decoder, the reader, the player and the waveform canvas, so the first real import doesn't pay that cost.

## Architecture

| Layer | File(s) |
|---|---|
| Decode + measure | `Audio/AudioLevelAnalyzer.swift`, `Audio/AudioSegmentPlanner.swift`, `Audio/LevelsCache.swift` |
| Detection | `Analysis/SilenceDetector.swift`, `Model/ClipTimeline.swift` |
| Playback | `Playback/CompositionBuilder.swift` (`AVMutableComposition`; `AVVideoComposition.Configuration` for mixed orientations), `Analysis/PlaybackSkipper.swift` |
| Waveform | `Waveform/WaveformSampler.swift`, `Views/WaveformCanvas.swift` (draws only what's visible) |
| Speech-to-text | `Transcription/SpeechModelCatalog.swift` (which models qualify), `Transcription/SpeechModelStore.swift` (download, delete, selection), `Transcription/TranscriptionEngine.swift` (WhisperKit and Apple engines), `Transcription/SpeechAudioExtractor.swift` (16 kHz mono decode), `Transcription/TranscriptionViewModel.swift`, `Views/SpeechModelPickerView.swift`, `Views/TranscriptPanel.swift` |
| UI | `ContentView.swift`, `Views/*`, `App/WarmUp.swift` |

Project settings: Swift 6, MainActor-by-default, macOS 27. Swift package: WhisperKit (`argmax-oss-swift`, 1.x). The app sandbox allows outgoing connections, which are used only to download models.

## Building and testing

Open `HT Edit.xcodeproj` in Xcode, then:
- **⌘R** to run the app.
- **⌘U** to run the unit tests (Swift Testing) and UI tests (XCTest).

### Continuous integration

Every push runs `.github/workflows/ci.yml` on GitHub's `xcode-27` runner (macOS 27, Xcode 27):
- The build treats **all warnings as errors** (set on the app and test targets, so Swift packages aren't affected). Deprecated APIs and concurrency warnings fail CI.
- Unit tests include end-to-end imports of generated H.264, HEVC, portrait and audio-only files. They check that playback becomes ready, that frames are not black, that analysis finishes, and that silences are found.
- UI tests launch the app with `-UITestFixture <kind>` (Debug builds only), which imports a generated file inside the app's sandbox. They check the clip row, that analysis finishes, the video pixels, right-click Delete, the Delete key, and the **+** and Import buttons.

### Diagnostics

The app logs each import stage under the subsystem `ht.edit`, with the categories `import`, `analysis`, `playback` and `transcription`. It also emits signposts ("Analyze audio", "Prepare playback").
- To watch the logs, open Console.app and filter on `subsystem:ht.edit`.
- To see timings, use Instruments ▸ Points of Interest.
- To find re-render loops (Debug builds only), launch with the environment variable `HTEDIT_TRACE_BODIES=1`. Each re-render of the main views is then logged with the reason (SwiftUI's `_printChanges`).
