# HT Edit

A native macOS video editor built for Apple silicon. The first feature is **silence detection**: import one or more videos, and every silent stretch is highlighted on the audio waveform right away. You can tune the highlights live, and playback skips the silences.

## Screenshots

Two clips on one timeline. Silences are highlighted on the waveform, and a yellow line marks where the second clip starts:

![Two landscape clips on the timeline, with silences highlighted](docs/screenshots/landscape.png)

| Vertical video | Empty editor |
|---|---|
| ![A portrait clip, with the player beside the timeline](docs/screenshots/portrait.png) | ![The editor before anything is imported](docs/screenshots/empty-state.png) |

The clips are test videos the app generates itself: solid green frames, with a tone, then silence, then a tone. CI captures these screenshots by running the `ReadmeScreenshots` UI tests. To refresh them, run the **README screenshots** workflow.

## Features

- **Import:** ⌘O, the **+** toolbar button, or drag and drop. You can import several files at once; new clips are added to the end.
- **One seamless timeline:** a yellow line marks where each clip starts.
- **Clip sidebar:** shows each clip's thumbnail, name and length. Drag clips to reorder them. Show or hide it with the system sidebar button.
- **Vertical video:** if the video is taller than it is wide, the player sits beside the timeline instead of above it. This is automatic.
- **Live settings:** threshold (dB), padding start and padding end. Highlights update instantly.
- **Playback:** always skips the highlighted silences.
- **Transcript with timestamps:** in the inspector, open the **Transcript** tab and press **Transcribe**. Each line shows when it was spoken. Click a line to jump there. The line that's playing is highlighted, and **Copy** puts the whole transcript, with timestamps, on the clipboard.

- **Open in Final Cut Pro:** the film toolbar button (⌘E) sends the timeline to Final Cut Pro as FCPXML 1.14 (Final Cut Pro 12 or later). See below.

## Open in Final Cut Pro

Press the **Open in Final Cut Pro** toolbar button (⌘E), type the title to use for captions (or keep **Basic Title**), and press **Open in Final Cut Pro**. Final Cut opens a project with three layers, from bottom to top:

1. **The video:** your clips, back to back.
2. **An adjustment clip:** Final Cut's built-in adjustment clip, covering the entire video.
3. **Captions:** if the timeline has a transcript, it's split into titles of **3 words each**, centered and timed to the speech.

You can type a title's **name** (a built-in title, or any title installed in `~/Movies/Motion Templates.localized`) or the **path** to its `.moti` file or folder. Under the box, HT Edit says whether it found the title. The **ⓘ** button explains this.

The FCPXML file is written to `~/Library/Caches/HT Edit/Final Cut/`. If Final Cut Pro isn't installed, HT Edit tells you where the file is so you can import it with **File ▸ Import ▸ XML**.

## Transcription

Transcription runs through your own **Antigravity CLI (`agy`)**, under your Google account and subscription. There are no API keys, and nothing is charged per request. (Gemini CLI no longer serves individual accounts; Antigravity CLI replaced it.)

**One-time setup:** install the Antigravity CLI and sign in once with your Google account (run `agy` in Terminal). That's all.

**Every time:** everything happens in HT Edit.
1. Open the **Transcript** tab and press **Transcribe**.
2. Optional: pick another **model**. Only models that can transcribe audio with timestamps are listed, and the cheapest one your account offers is selected by default. Your choice is remembered.
3. Optional: type **context**, such as names, jargon or spellings. It's empty by default.

How it works:
- Each clip's audio is cut into 3-minute chunks (`.m4a`).
- HT Edit runs `agy -p … --output-format json --json-schema …` on two chunks at a time.
- The timestamped segments are placed on the timeline as they arrive.
- A failed chunk is retried once; anything that still fails can be retried on its own.
- Finished transcripts are cached per file, model and context.

To check your installation by hand, run `zsh scripts/agy-probe.sh`. It runs the exact command HT Edit uses on a short clip with speech.

Running `agy` and reading your sign-in means HT Edit runs **without the App Sandbox**. Distribute it signed and notarized, outside the Mac App Store. Hardened runtime stays on.

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
| Transcription | `Transcription/AgyEngine.swift` (runs `agy`, parses its JSON), `Transcriber.swift` (chunks, concurrency, retries), `AudioChunkExporter.swift`, `TranscriptionController.swift`, `TranscriptionModel.swift` (model catalog), `TranscriptCache.swift`, `Model/Transcript.swift` |
| UI | `ContentView.swift`, `Views/*` (including `InspectorView`, `TranscriptPanel`), `App/WarmUp.swift` |

Project settings: Swift 6, MainActor-by-default, macOS 27.

## Building and testing

Open `HT Edit.xcodeproj` in Xcode, then:
- **⌘R** to run the app.
- **⌘U** to run the unit tests (Swift Testing) and UI tests (XCTest).

### Continuous integration

Every push runs `.github/workflows/ci.yml` on GitHub's `xcode-27` runner (macOS 27, Xcode 27):
- The build treats **all warnings as errors**, so deprecated APIs and concurrency warnings fail CI.
- Unit tests include end-to-end imports of generated H.264, HEVC, portrait and audio-only files. They check that playback becomes ready, that frames are not black, that analysis finishes, and that silences are found.
- Transcription tests run the real `agy` runner against fake `agy` scripts: success, signed out, errors, hangs, cancellation and large output. They also cover the chunking, the limit of two requests at a time, the retry and the cache, using real exported audio. CI has no Google sign-in, so a real transcription is checked by hand with `scripts/agy-probe.sh`.
- UI tests launch the app with `-UITestFixture <kind>` (Debug builds only), which makes the app generate and import a file. They check the clip row, that analysis finishes, the video pixels, right-click Delete, the Delete key, and the **+** and Import buttons. With `-UITestFakeTranscription 1`, a built-in fake stands in for Antigravity, and the Transcript tab is tested end to end.

### Diagnostics

The app logs each import stage under the subsystem `ht.edit`, with the categories `import`, `analysis` and `playback`. It also emits signposts ("Analyze audio", "Prepare playback").
- To watch the logs, open Console.app and filter on `subsystem:ht.edit`.
- To see timings, use Instruments ▸ Points of Interest.
- To find re-render loops (Debug builds only), launch with the environment variable `HTEDIT_TRACE_BODIES=1`. Each re-render of the main views is then logged with the reason (SwiftUI's `_printChanges`).
