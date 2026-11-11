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
- **Transcript with timestamps:** in the inspector, open the **Transcript** tab and press **Transcribe**. Whisper transcribes on your Mac; Gemini works out the topic and proofreads the text. Each line shows when it was spoken. Click a line to jump there. The line that's playing is highlighted, and **Copy** puts the whole transcript, with timestamps, on the clipboard.

## Transcription

Transcription is tuned for **Arabic speech** (English words inside it are kept as spoken) and its steps are fixed. The only thing you give it is an optional **context**.

1. **Main pass, on your Mac:** Whisper large-v3-turbo (`faster-whisper`) transcribes the speech without any hint. Without a hint, Whisper writes every word and every repeated take, in your dialect. This is the transcript you get, and its timestamps come from the audio, so they don't drift. Lines appear as each part finishes.
2. **Topic:** if the context field is empty, Gemini reads that transcript and writes a one-line context in your dialect, the way a person would skim it first. For example: "فيديو بالعامية المصرية عن ميزة الوضع الخفي في ChatGPT والـ privacy". It's shown under the field as **Topic found**.
3. **Context pass, on your Mac:** Whisper again, with the context as a hint. It gets names and terms right, like ChatGPT, but it tends to skip repeated takes and make speech formal, so it's never shown. It only serves as a second reading of each line.
4. **Cleanup:** Gemini, through your own **Antigravity CLI (`agy`)** under your Google account and subscription, proofreads the main transcript with the second reading beside every line. It fixes misheard words and names and keeps your dialect. It gets text only, never audio, and it can't change timing: each line keeps Whisper's timestamps, and a corrected line that drops or adds words is rejected in favor of Whisper's version. Repeats and false starts stay.

Gemini only reads text, a few calls per clip, so a run costs much less of your subscription than having Gemini listen to the audio.

On a 5½-minute Egyptian Arabic test video, with the context left empty, about 84% of the words matched a hand-checked transcript (Whisper alone: 65%), and every repeated take was kept. The whole run took about 5 minutes on an M1.

**One-time setup:**
- **Whisper:** open the **Transcript** tab and press **Set Up Whisper**. It creates a small Python environment and downloads the model (about 1.7 GB) into `~/Library/Application Support/HT Edit/Whisper`. You need Python 3.9–3.13 (for example `brew install python@3.12`). To do the same in Terminal, run `zsh "HT Edit/Transcription/Whisper/whisper_setup.sh"`, and pass an existing large-v3-turbo folder as the second argument to copy it instead of downloading.
- **Antigravity:** install the Antigravity CLI and sign in once (run `agy` in Terminal). Without it, you get the main Whisper pass only.

**Every time:** open the **Transcript** tab, optionally type a context (topic, names, terms, written the way you talk), and press **Transcribe**.

How it works:
- HT Edit measures each clip's loudness and cuts its speech into windows of about 25 seconds, always at pauses. Whisper handles these much better than one long pass, which loops on repeated takes, or short chunks, which lose context.
- Each window is written as 16 kHz mono WAV and sent to a Whisper helper (`whisper_server.py`). The helper loads the model once per session and returns lines with word timestamps. When a window comes back looped (one phrase over and over, one word many times in a row, or a long run of repeated letters), the helper redoes it without the hint, then with repeats blocked. It also drops lines Whisper typically invents over silence.
- The second reading is matched to each line by word timing. Cleanup runs 80 lines per request, together with the whole transcript for context.
- A failed window is retried once; anything that still fails can be retried on its own. If the topic or cleanup step fails, Whisper's text stays.
- Finished passes, topics and cleanups are cached per file, so running again is quick.

**Cleanup instructions** are editable in **HT Edit ▸ Settings…** (⌘,). HT Edit always adds the context, the second Whisper reading, the lines and the reply format after them. **Restore Default** brings back the built-in text, and empty instructions also fall back to it. Edited instructions get their own cache entries, so changing them never reuses an old cleanup.

To check Antigravity by hand, run `zsh scripts/agy-probe.sh`. It runs the exact cleanup command HT Edit uses.

Running Whisper and `agy` means HT Edit runs **without the App Sandbox**. Distribute it signed and notarized, outside the Mac App Store. Hardened runtime stays on.

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
| Transcription | `Transcription/Whisper/` (`SpeechWindows.swift` plans windows at pauses, `WhisperEngine.swift` runs `whisper_server.py`, `whisper_setup.sh` installs it), `AgyCleaner.swift` (Gemini cleanup through `agy`, with a guard against dropped words), `Transcriber.swift` (windows, concurrency, retries), `TranscriptionController.swift` (runs Whisper, then cleanup), `TranscriptionEngine.swift`, `TranscriptionModel.swift` (cleanup model catalog), `TranscriptCache.swift`, `Model/Transcript.swift` |
| UI | `ContentView.swift`, `Views/*` (including `InspectorView`, `TranscriptPanel`, `SettingsView`), `App/WarmUp.swift` |

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
