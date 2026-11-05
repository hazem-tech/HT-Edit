#!/usr/bin/env python3
"""Transcribe an audio/video file with Speko and write word timestamps as JSON.

Uses Speko's batch STT endpoint (POST https://router.speko.dev/v1/stt/transcriptions)
with word timestamps, pinned to the model that serves them (gemini-3.5-transcribe).
The endpoint takes WAV only, so the input is converted to 16 kHz mono PCM first,
and long audio is cut into chunks at pauses so no word is split.

Needs SPEKO_API_KEY (create one at https://platform.speko.ai/agents/keys).

Output (seconds from the start of the file):
    {"duration": 312.4, "words": [{"text": "...", "start": 0.42, "end": 0.81}, ...]}

Usage:
    python3 speko_transcribe.py input.m4a words.json [--language ar] [--chunk 120]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

ENDPOINT = os.environ.get("SPEKO_STT_URL", "https://router.speko.dev/v1/stt/transcriptions")


def probe_duration(path: Path) -> float:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", str(path)],
        capture_output=True, text=True, check=True,
    )
    return float(out.stdout.strip())


def silence_midpoints(path: Path) -> list[float]:
    out = subprocess.run(
        ["ffmpeg", "-hide_banner", "-i", str(path), "-af", "silencedetect=noise=-35dB:d=0.25", "-f", "null", "-"],
        capture_output=True, text=True,
    ).stderr
    starts = [float(x) for x in re.findall(r"silence_start: ([\d.]+)", out)]
    ends = [float(x) for x in re.findall(r"silence_end: ([\d.]+)", out)]
    return [(s + e) / 2 for s, e in zip(starts, ends)]


def plan_chunks(duration: float, target: float, pauses: list[float]) -> list[tuple[float, float]]:
    cuts, pos = [], 0.0
    while duration - pos > target * 1.25:
        goal = pos + target
        near = [p for p in pauses if goal - target * 0.3 <= p <= goal + target * 0.2]
        cut = min(near, key=lambda p: abs(p - goal)) if near else goal
        cuts.append(cut)
        pos = cut
    edges = [0.0, *cuts, duration]
    return list(zip(edges[:-1], edges[1:]))


def multipart(fields: list[tuple[str, str, str, bytes]]) -> tuple[bytes, str]:
    boundary = "speko" + uuid.uuid4().hex
    body = bytearray()
    for name, filename, ctype, data in fields:
        body += f"--{boundary}\r\n".encode()
        disp = f'form-data; name="{name}"' + (f'; filename="{filename}"' if filename else "")
        body += f"Content-Disposition: {disp}\r\nContent-Type: {ctype}\r\n\r\n".encode()
        body += data + b"\r\n"
    body += f"--{boundary}--\r\n".encode()
    return bytes(body), f"multipart/form-data; boundary={boundary}"


def transcribe_wav(wav: bytes, key: str, language: str | None) -> dict:
    req = {
        "routing": {"mode": "explicit", "provider": "gemini", "model": "gemini-3.5-transcribe"},
        "options": {"word_timestamps": True},
    }
    if language:
        req["language"] = language
    body, ctype = multipart([
        ("request", "", "application/json", json.dumps(req).encode()),
        ("audio", "audio.wav", "audio/wav", wav),
    ])
    idem = uuid.uuid4().hex
    for attempt in range(4):
        r = urllib.request.Request(ENDPOINT, data=body, method="POST", headers={
            "Authorization": f"Bearer {key}", "Idempotency-Key": idem, "Content-Type": ctype,
        })
        try:
            with urllib.request.urlopen(r, timeout=600) as resp:
                return json.loads(resp.read())
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")[:500]
            if e.code in (429, 500, 502, 503, 504) and attempt < 3:
                time.sleep(2 ** (attempt + 1))
                continue
            sys.exit(f"Speko returned HTTP {e.code}: {detail}")
        except urllib.error.URLError as e:
            if attempt < 3:
                time.sleep(2 ** (attempt + 1))
                continue
            sys.exit(f"could not reach Speko: {e}")
    raise AssertionError


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input")
    ap.add_argument("out_json")
    ap.add_argument("--language", default="ar", help="BCP-47 hint, e.g. ar, ar-EG; 'none' to auto-detect")
    ap.add_argument("--chunk", type=float, default=120.0, help="target chunk length in seconds")
    args = ap.parse_args()

    key = os.environ.get("SPEKO_API_KEY")
    if not key:
        sys.exit("SPEKO_API_KEY is not set")
    src = Path(args.input)
    duration = probe_duration(src)
    chunks = plan_chunks(duration, args.chunk, silence_midpoints(src) if duration > args.chunk * 1.25 else [])
    language = None if args.language.lower() == "none" else args.language

    words: list[dict] = []
    with tempfile.TemporaryDirectory() as tmp:
        for i, (a, b) in enumerate(chunks):
            wav_path = Path(tmp) / f"c{i}.wav"
            subprocess.run(
                ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-ss", f"{a:.3f}", "-to", f"{b:.3f}",
                 "-i", str(src), "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(wav_path)],
                check=True,
            )
            print(f"chunk {i + 1}/{len(chunks)}: {a:.1f}s-{b:.1f}s", file=sys.stderr)
            res = transcribe_wav(wav_path.read_bytes(), key, language)
            got = res.get("words") or []
            if not got and res.get("text"):
                print(f"warning: chunk {i + 1} came back without word timestamps", file=sys.stderr)
            for w in got:
                words.append({
                    "text": w["text"].strip(),
                    "start": round(a + w["start_ms"] / 1000, 3),
                    "end": round(a + w["end_ms"] / 1000, 3),
                })

    words = [w for w in words if w["text"]]
    Path(args.out_json).write_text(
        json.dumps({"duration": round(duration, 3), "words": words}, ensure_ascii=False, indent=1), encoding="utf-8"
    )
    print(f"wrote {args.out_json}: {len(words)} words, {duration:.1f}s")


if __name__ == "__main__":
    main()
