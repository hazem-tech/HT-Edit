#!/usr/bin/env python3
"""HT Edit's local Whisper helper.

Started by HT Edit (WhisperServer.swift) with the venv's Python:

    python whisper_server.py <model-dir>

It loads faster-whisper once, prints {"ready": true} and then answers one JSON
request per stdin line with one JSON reply per stdout line:

    -> {"id": 1, "wav": "/path/window.wav", "language": "ar", "prompt": "...", "second_pass": true}
    <- {"id": 1, "segments": [{"start": 0.0, "end": 2.1, "text": "...", "alternative": "..."}]}

With `second_pass`, the window is transcribed again without the prompt. The
prompt helps with names and topic but pushes Whisper toward formal language;
the plain pass keeps more of the speaker's dialect. Each line gets the plain
pass's words for the same moment as `alternative`, for the cleanup to weigh.
    <- {"id": 1, "error": "..."}

`wav` must be 16 kHz mono 16-bit PCM (HT Edit writes it). HT Edit already cut
the audio into windows of about 25 seconds at pauses, which keeps Whisper from
looping on repeated takes; this script only transcribes one window per request.
Times in the reply are seconds from the start of that window.
Diagnostics go to stderr; stdout carries nothing but replies.
"""
import json
import os
import sys
import wave

os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")

import numpy as np  # noqa: E402
from faster_whisper import WhisperModel  # noqa: E402

# Line breaking: a new line starts after a pause, a long line, or sentence punctuation.
LINE_GAP = 0.5
LINE_MAX_SECONDS = 7.0
LINE_MAX_WORDS = 14
SENTENCE_END = (".", "?", "!", "؟", "…")

# Lines Whisper invents over silence or noise (subtitle credits, "subscribe"…).
HALLUCINATIONS = (
    "ترجمة نانسي قنقر", "اشتركوا في القناة", "شكرا للمشاهدة", "شكراً للمشاهدة", "نانسي قنقر",
    "thanks for watching", "thank you for watching", "subscribe to", "subtitles by", "amara.org",
)


def log(*parts):
    print(*parts, file=sys.stderr, flush=True)


def reply(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def read_wav(path):
    with wave.open(path, "rb") as w:
        if w.getframerate() != 16000 or w.getnchannels() != 1 or w.getsampwidth() != 2:
            raise ValueError("expected 16 kHz mono 16-bit WAV")
        data = w.readframes(w.getnframes())
    return np.frombuffer(data, dtype=np.int16).astype(np.float32) / 32768.0


def attach_alternatives(lines, words):
    """Gives each line the second pass's words that fall in its time span."""
    for line in lines:
        picked = [w["text"] for w in words
                  if line["start"] - 0.15 <= (w["start"] + w["end"]) / 2 <= line["end"] + 0.15]
        alternative = " ".join(picked)
        if alternative and alternative != line["text"]:
            line["alternative"] = alternative
    return lines


def lines_from_words(words):
    lines, current = [], []
    for word in words:
        if current:
            gap = word["start"] - current[-1]["end"]
            too_long = word["end"] - current[0]["start"] > LINE_MAX_SECONDS
            if gap >= LINE_GAP or too_long or len(current) >= LINE_MAX_WORDS:
                lines.append(current)
                current = []
        current.append(word)
        if word["text"].endswith(SENTENCE_END):
            lines.append(current)
            current = []
    if current:
        lines.append(current)
    return [
        {"start": round(ws[0]["start"], 3), "end": round(ws[-1]["end"], 3), "text": " ".join(w["text"] for w in ws)}
        for ws in lines
    ]


def looks_looped(words):
    """True when a window's text is mostly one phrase repeated (Whisper got stuck)."""
    tokens = [w["text"] for w in words]
    if len(tokens) < 12:
        return False
    return len(set(tokens)) / len(tokens) < 0.3


def is_hallucination(text):
    lowered = text.lower()
    return any(phrase in lowered for phrase in HALLUCINATIONS)


def run_whisper(model, audio, language, prompt, strict):
    segments, _ = model.transcribe(
        audio,
        language=language,
        initial_prompt=prompt,
        beam_size=5,
        word_timestamps=True,
        vad_filter=False,  # HT Edit already sends speech-only windows
        condition_on_previous_text=False,
        temperature=[0.0, 0.2, 0.4, 0.6],
        compression_ratio_threshold=2.4,
        # The retry for a looped window blocks repeats outright.
        no_repeat_ngram_size=3 if strict else 0,
        repetition_penalty=1.15 if strict else 1.0,
    )
    words = []
    for segment in segments:
        # Over silence or noise Whisper invents lines; drop unsure and known ones.
        if segment.no_speech_prob > 0.5 and segment.avg_logprob < -0.7:
            continue
        if segment.avg_logprob < -1.2 or is_hallucination(segment.text):
            continue
        for w in segment.words or []:
            text = w.word.strip()
            if text:
                words.append({"start": float(w.start), "end": float(w.end), "text": text})
    return words


def transcribe(model, request):
    audio = read_wav(request["wav"])
    if len(audio) < 1600:  # under 0.1 s
        return []
    language = request.get("language") or None
    prompt = request.get("prompt") or None
    words = run_whisper(model, audio, language, prompt, strict=False)
    # The prompt can push Whisper into a loop on repeated takes: retry without
    # it, and if it still loops, with repeats blocked (spelling suffers a little).
    for attempt_prompt, strict in ((None, False), (None, True)):
        if not looks_looped(words):
            break
        log(f"window looped; retrying (strict={strict})")
        retry = run_whisper(model, audio, language, attempt_prompt, strict=strict)
        if not looks_looped(retry) or strict:
            words = retry if not looks_looped(retry) else words
    lines = lines_from_words(words)
    if request.get("second_pass") and prompt:
        plain = run_whisper(model, audio, language, None, strict=False)
        if not looks_looped(plain):
            attach_alternatives(lines, plain)
    return lines


def main():
    if len(sys.argv) != 2:
        log("usage: whisper_server.py <model-dir>")
        return 2
    threads = max(1, (os.cpu_count() or 4) - 2)
    log(f"loading {sys.argv[1]} with {threads} threads")
    model = WhisperModel(sys.argv[1], device="cpu", compute_type="int8", cpu_threads=threads)
    reply({"ready": True})
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        request_id = None
        try:
            request = json.loads(line)
            request_id = request.get("id")
            reply({"id": request_id, "segments": transcribe(model, request)})
        except Exception as error:  # report and keep serving
            log(f"request {request_id} failed: {error!r}")
            reply({"id": request_id, "error": str(error) or type(error).__name__})
    return 0


if __name__ == "__main__":
    sys.exit(main())
