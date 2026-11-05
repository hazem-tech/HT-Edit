---
name: video-captions
description: Make one-word-per-line video captions from an audio file (often a Google Drive link) and deliver them as a transparent ProRes 4444 .mov for the DaVinci Resolve timeline. Transcribes with Speko. Egyptian Arabic with English words kept in English; white words, important words yellow; a tiny 0.1 s pop-in. Use when the user asks for captions or subtitles for a video, or sends audio to caption.
---

# Video captions (Speko → transparent .mov for DaVinci)

The user's caption style. Don't change it unless they ask:

- **One word on screen at a time**, centred.
- **White** (`#FFFFFF`). **Yellow** (`#FFD60A`) for words the user stresses or that carry the point.
- **Language:** Egyptian Arabic, written the way it's spoken (عامية مصرية, not فصحى). **English words they say stay in English letters** (`AI`, `YouTube`, `project`, `content`), never transliterated (`بروجكت` → `project`).
- **Animation:** a pop-in over **0.1 s**: scale 92% → 100% and a fade from 0, eased out. It should be invisible to a casual viewer, so don't make it bigger or longer.
- **Output:** a `.mov` (ProRes 4444 with alpha). It starts at 0 and is as long as the audio, so it lines up when placed at the audio's start.

Scripts live in `.claude/skills/video-captions/scripts/`. Font: `fonts/Cairo.ttf` (SIL OFL, Arabic + Latin).

## 1. Get the audio

The user gives a Google Drive link. Take the file ID from it (`/file/d/<ID>/`, or `?id=<ID>`).
- Preferred: the Google Drive connector (`mcp__Google_Drive__get_file_metadata`, then `mcp__Google_Drive__download_file_content`). Load the tools with ToolSearch.
- Fallback, if the file is shared publicly: `curl -L "https://drive.usercontent.google.com/download?id=<ID>&export=download&confirm=t" -o audio.<ext>`.

Save it in a new, empty folder in the scratchpad. Check it with `ffprobe` (duration, that it has an audio stream).

## 2. Ask for the timeline settings (only if not already known)

Resolution and frame rate of their DaVinci timeline: for example 1080×1920 (Reels/TikTok/Shorts) or 1920×1080, and 30 / 25 / 29.97 / 24 fps. Matching them means no scaling or frame-rate conversion in Resolve. Defaults: 1080×1920 at 30 fps.

## 3. Transcribe with Speko (word timestamps)

**If the Speko MCP tools are connected** (ToolSearch `speko`, the tool is `audio.transcribe`): read its schema, then ask for word-level timestamps and an Arabic language hint (`ar`, or `ar-EG` if accepted). Convert the result to the words JSON below.

**Otherwise, use the REST script.** It needs `SPEKO_API_KEY` in the environment (keys: https://platform.speko.ai/agents/keys):

```bash
python3 .claude/skills/video-captions/scripts/speko_transcribe.py <audio> <work>/raw_words.json --language ar
```

It converts to 16 kHz mono WAV (the endpoint takes WAV only), cuts long audio at pauses into ~2-minute chunks, and calls `POST https://router.speko.dev/v1/stt/transcriptions` pinned to `gemini-3.5-transcribe` (the model that serves word timestamps). It writes:

```json
{"duration": 312.4, "words": [{"text": "النهارده", "start": 0.42, "end": 0.81}]}
```

If neither is available, stop and tell the user how to connect Speko: in Claude Code, `claude mcp add --transport http speko https://mcp.speko.ai/mcp`; in a cloud session, add `SPEKO_API_KEY` as an environment secret. Don't switch to another transcription service without asking.

## 4. Clean up the words (your judgement)

Read the whole transcript first, then write `<work>/words.json` with the same shape plus `"highlight"`:

1. **One word per entry.** If an entry holds several words, split it and share its time span between them in proportion to their length. Keep a clitic attached as it's written (`والفلوس`, `بالـ`).
2. **Egyptian spelling**, the way they said it: `ازاي`, `دلوقتي`, `عشان`, `كده`, `مش`, `النهارده`. Fix obvious mishearings from context. Don't rewrite into فصحى.
3. **English words in English.** Any word they said in English goes in Latin letters with normal casing (`AI`, `ChatGPT`, `YouTube`, `video`). Arabic grammar attached to an English word stays Arabic, as its own word if it's spoken separately.
4. **Drop pure fillers** (`اممم`, `ااه` used as a hesitation). Keep real words like `يعني` when they're part of the sentence.
5. **Highlight** (`"highlight": true`) the words that carry the point: the key noun or verb of a claim, numbers and prices, names, strong emotion or emphasis words (`أهم`, `مستحيل`, `ببلاش`). Be sparing: about 1 in 8–12 words, never two in a row unless it's one phrase (`100 ألف`). If the user names words to highlight, use exactly those.
6. **Don't touch the timing** except when splitting. Keep `start` and `end` in seconds.

Show the user a short excerpt (first ~30 words, with the yellow ones marked) only if something is unclear. Otherwise go straight to rendering.

## 5. Render the .mov

```bash
python3 .claude/skills/video-captions/scripts/render_captions.py <work>/words.json <out>/captions.mov \
  --duration <audio duration> --width 1080 --height 1920 --fps 30
```

Useful options: `--y 0.75` (lower on screen; default 0.5 is centre), `--font-size 110`, `--weight Black`, `--shadow` (soft drop shadow for bright footage; off by default because the user asked for plain white), `--anim 0.1`, `--scale-from 0.92`.

Each word stays on screen until the next one starts. After a pause longer than 0.6 s, it leaves 0.25 s after it ends (`--max-gap`, `--tail`).

**Check before delivering:** `ffprobe` should show `prores`, profile `4444`, a `yuva` pixel format, the right size and fps, and a duration equal to the audio's. Also composite two or three frames on grey and look at them: one mid pop-in, one white word, one yellow word. Check that the Arabic letters are joined and the English words read left to right:

```bash
ffmpeg -v error -y -f lavfi -i color=c=0x404040:s=1080x1920:r=30:d=<dur> -i captions.mov \
  -filter_complex "[0][1]overlay=format=auto,select='eq(n\,N1)+eq(n\,N2)+eq(n\,N3)',scale=540:-1,tile=3x1" \
  -frames:v 1 -vsync 0 check.png
```

Size: about 1.4 MB per second at 1080×1920 / 30 fps (≈ 0.9 GB for 10 minutes). That's normal for ProRes 4444.

## 6. Deliver

Send the `.mov` to the user (SendUserFile), and give these steps:

1. Drag `captions.mov` into the Media Pool, then onto a video track **above** the footage, starting at the **same frame as the audio** you sent.
2. Resolve reads the alpha channel on its own. If the background shows black, right-click the clip → **Clip Attributes** → **Alpha Mode: Straight**.
3. Move or resize it in the Inspector (Transform) if needed. Size, colour and animation are already baked in.

Also offer the `words.json`, in case they want a word changed. To fix a word, edit the JSON and run step 5 again.
