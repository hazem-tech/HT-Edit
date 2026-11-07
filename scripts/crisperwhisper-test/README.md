# CrisperWhisper test

A throwaway tool for trying [CrisperWhisper 2.0](https://github.com/nyrahealth/CrisperWhisper) on your own clips before anything goes into HT Edit. It gives a word-for-word (verbatim) transcript: fillers, repeats, stutters and false starts stay in. Every word gets its own timestamp, and a page plays the audio and highlights each word as it's spoken.

## Setup (once, on your Mac)

```sh
brew install ffmpeg python@3.12          # if you don't have them
cd scripts/crisperwhisper-test
python3.12 -m venv .venv
source .venv/bin/activate
pip install "crisperwhisper[transformers]>=2.0.4"
```

The first run downloads the model: about 3 GB for `large`, 1.6 GB for `turbo`.

## Run

```sh
source .venv/bin/activate
python transcribe.py ~/Movies/clip.mp4                          # Arabic, large, verbatim
python transcribe.py ~/Movies/clip.mp4 --model turbo            # faster
python transcribe.py ~/Movies/clip.mp4 --compare                # also shows the clean version
python transcribe.py ~/Movies/clip.mp4 --start 60 --duration 90 # just a part
python transcribe.py ~/Movies/clip.mp4 --device mps             # try the Mac GPU
```

The results go to `clip-crisperwhisper/` next to the clip, and `index.html` opens in your browser:

- Words light up as the audio plays. Click a word to jump there.
- **Show times** puts each word's start time above it.
- Words the model was unsure about (under 50 %) get a wavy underline.
- Hover over a word to see its start, end and confidence.
- Slow the playback down to 0.5× to check the timing closely.

## What to look for

- **Verbatim:** are the fillers (آآ، إممم، يعني), repeated words and false starts there? In English it writes sounds like um/uh as tags such as `[UM]` and `[UH]`. How it writes Arabic fillers is something this test will show.
- **Dialect:** are dialect words written as spoken, or turned into Modern Standard Arabic?
- **Timing:** at 0.5×, does each word light up as it starts?
- **Errors:** are there wrong words, and does it invent words during silence or music?

Start with a 1–2 minute part (`--start/--duration`) so you don't wait long. Speed is a concern: without an NVIDIA GPU, `large` can be slow. Compare `turbo` against `large`.

## Note

The model weights are under Nyra Health's **non-commercial research license**. Testing is fine. Shipping the model in HT Edit would need a commercial license from Nyra Health.
