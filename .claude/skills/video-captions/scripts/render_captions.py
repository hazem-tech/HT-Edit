#!/usr/bin/env python3
"""Render one-word-at-a-time captions to a transparent ProRes 4444 .mov.

Input is a words JSON file:
    {"words": [{"text": "النهارده", "start": 0.42, "end": 0.81, "highlight": false}, ...]}
(times in seconds from the start of the audio). Words with "highlight": true are
drawn yellow, the rest white. Each word pops in over --anim seconds (default 0.1):
a slight scale-up and fade, small enough that nobody notices it.

The .mov starts at 0 and lasts as long as the audio (--duration), so placing it at
the same timeline position as the audio in DaVinci Resolve lines everything up.
Its alpha channel is kept, so it sits on top of the video with no keying.

Usage:
    python3 render_captions.py words.json out.mov --duration 312.4 \
        --width 1080 --height 1920 --fps 30
"""

from __future__ import annotations

import argparse
import json
import math
import subprocess
import sys
from fractions import Fraction
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont, features

SKILL_DIR = Path(__file__).resolve().parent.parent
DEFAULT_FONT = SKILL_DIR / "fonts" / "Cairo.ttf"

WHITE = (255, 255, 255)
YELLOW = (255, 214, 10)


def parse_color(value: str) -> tuple[int, int, int]:
    value = value.lstrip("#")
    return tuple(int(value[i : i + 2], 16) for i in (0, 2, 4))  # type: ignore[return-value]


def ease_out_cubic(t: float) -> float:
    return 1 - (1 - t) ** 3


def load_font(path: Path, size: int, weight: str) -> ImageFont.FreeTypeFont:
    engine = ImageFont.Layout.RAQM if features.check("raqm") else ImageFont.Layout.BASIC
    if engine is ImageFont.Layout.BASIC:
        print("warning: libraqm not available; Arabic letters will not join correctly", file=sys.stderr)
    font = ImageFont.truetype(str(path), size, layout_engine=engine)
    try:
        font.set_variation_by_name(weight)
    except Exception:
        pass  # not a variable font, or no such named instance
    return font


def render_word(text: str, font: ImageFont.FreeTypeFont, color, shadow: bool) -> Image.Image:
    """The word, tightly cropped on a transparent background (with padding for the shadow)."""
    left, top, right, bottom = font.getbbox(text)
    pad = max(8, font.size // 6)
    img = Image.new("RGBA", (right - left + 2 * pad, bottom - top + 2 * pad), (0, 0, 0, 0))
    origin = (pad - left, pad - top)
    if shadow:
        sh = Image.new("RGBA", img.size, (0, 0, 0, 0))
        ImageDraw.Draw(sh).text((origin[0], origin[1] + font.size // 30), text, font=font, fill=(0, 0, 0, 150))
        img = Image.alpha_composite(img, sh.filter(ImageFilter.GaussianBlur(font.size / 18)))
    ImageDraw.Draw(img).text(origin, text, font=font, fill=color + (255,))
    return img


def build_cues(words: list[dict], duration: float, max_gap: float, tail: float) -> list[tuple[float, float, dict]]:
    """When each word is on screen. A word stays up until the next one starts, unless
    the pause is longer than max_gap, in which case it leaves `tail` after it ends."""
    cues = []
    words = sorted((w for w in words if str(w.get("text", "")).strip()), key=lambda w: float(w["start"]))
    for i, w in enumerate(words):
        start = max(0.0, float(w["start"]))
        end = max(float(w.get("end", start)), start + 0.08)
        nxt = float(words[i + 1]["start"]) if i + 1 < len(words) else None
        if nxt is not None and nxt - end <= max_gap:
            stop = nxt
        else:
            stop = end + tail
            if nxt is not None:
                stop = min(stop, nxt)
        stop = min(stop, duration)
        if stop > start:
            cues.append((start, stop, w))
    return cues


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("words_json")
    ap.add_argument("out_mov")
    ap.add_argument("--duration", type=float, help="length of the audio in seconds (default: last word end + 1s)")
    ap.add_argument("--width", type=int, default=1080)
    ap.add_argument("--height", type=int, default=1920)
    ap.add_argument("--fps", default="30", help="timeline frame rate, e.g. 30, 25, 29.97, 24000/1001")
    ap.add_argument("--font", type=Path, default=DEFAULT_FONT)
    ap.add_argument("--weight", default="Bold", help="named instance of a variable font (Cairo: Regular..Black)")
    ap.add_argument("--font-size", type=int, help="pixels (default: 9%% of the shorter side)")
    ap.add_argument("--y", type=float, default=0.5, help="vertical centre of the word, 0=top 1=bottom")
    ap.add_argument("--color", default="#FFFFFF")
    ap.add_argument("--highlight-color", default="#FFD60A")
    ap.add_argument("--anim", type=float, default=0.1, help="pop-in length in seconds")
    ap.add_argument("--scale-from", type=float, default=0.92, help="starting scale of the pop-in")
    ap.add_argument("--shadow", action="store_true", help="soft drop shadow for readability on bright footage")
    ap.add_argument("--max-gap", type=float, default=0.6)
    ap.add_argument("--tail", type=float, default=0.25)
    args = ap.parse_args()

    data = json.loads(Path(args.words_json).read_text(encoding="utf-8"))
    words = data["words"] if isinstance(data, dict) else data
    if not words:
        sys.exit("no words in input")
    duration = args.duration or (max(float(w.get("end", w["start"])) for w in words) + 1.0)

    fps = Fraction({"29.97": "30000/1001", "23.976": "24000/1001", "59.94": "60000/1001"}.get(args.fps, args.fps))
    total_frames = math.ceil(duration * fps)
    W, H = args.width, args.height
    font = load_font(args.font, args.font_size or int(min(W, H) * 0.09), args.weight)
    colors = {False: parse_color(args.color), True: parse_color(args.highlight_color)}
    anim_frames = max(1, round(args.anim * fps))
    cy = int(H * args.y)

    cues = build_cues(words, duration, args.max_gap, args.tail)
    # frame index -> (cue index, frames since the word appeared)
    first = [math.floor(s * fps) for s, _, _ in cues]
    last = [max(first[i] + 1, math.floor(e * fps)) for i, (_, e, _) in enumerate(cues)]

    cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-f", "rawvideo", "-pix_fmt", "rgba", "-s", f"{W}x{H}", "-r", str(fps), "-i", "-",
        "-c:v", "prores_ks", "-profile:v", "4444", "-pix_fmt", "yuva444p10le",
        "-vendor", "apl0", "-alpha_bits", "16", "-r", str(fps), args.out_mov,
    ]
    ff = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    blank = bytes(W * H * 4)

    def frame_for(word_img: Image.Image, k: int) -> bytes:
        t = ease_out_cubic(min(1.0, (k + 1) / anim_frames))
        scale = args.scale_from + (1 - args.scale_from) * t
        img = word_img
        if scale != 1.0:
            img = word_img.resize((max(1, round(word_img.width * scale)), max(1, round(word_img.height * scale))), Image.LANCZOS)
        if t < 1.0:
            a = img.getchannel("A").point(lambda v: int(v * t))
            img.putalpha(a)
        canvas = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        canvas.alpha_composite(img, ((W - img.width) // 2, cy - img.height // 2))
        return canvas.tobytes()

    ci = 0
    cached: tuple[int, list[bytes]] | None = None
    try:
        for f in range(total_frames):
            while ci < len(cues) and f >= last[ci]:
                ci += 1
            if ci < len(cues) and first[ci] <= f < last[ci]:
                if cached is None or cached[0] != ci:
                    w = cues[ci][2]
                    word_img = render_word(str(w["text"]).strip(), font, colors[bool(w.get("highlight"))], args.shadow)
                    if word_img.width > W * 0.92:  # very long word: shrink to fit
                        r = W * 0.92 / word_img.width
                        word_img = word_img.resize((int(word_img.width * r), int(word_img.height * r)), Image.LANCZOS)
                    cached = (ci, [frame_for(word_img, k) for k in range(anim_frames)])
                k = f - first[ci]
                ff.stdin.write(cached[1][min(k, anim_frames - 1)])
            else:
                ff.stdin.write(blank)
            if f % 1000 == 0:
                print(f"\rframe {f}/{total_frames}", end="", file=sys.stderr, flush=True)
    finally:
        ff.stdin.close()
        rc = ff.wait()
    print(f"\rframe {total_frames}/{total_frames}", file=sys.stderr)
    if rc != 0:
        sys.exit(f"ffmpeg failed with exit status {rc}")
    print(f"wrote {args.out_mov}: {W}x{H} @ {fps} fps, {duration:.2f}s, {len(cues)} words")


if __name__ == "__main__":
    main()
