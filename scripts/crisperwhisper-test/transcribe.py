#!/usr/bin/env python3
"""Try CrisperWhisper 2.0 on one of your own clips, outside HT Edit.

It transcribes word for word (verbatim: fillers, repeats, stutters, false
starts), with a timestamp for every word, and writes a page that plays the
audio and highlights each word as it is spoken. This is a test tool only, to
judge accuracy before anything goes into the app.

    python3 transcribe.py clip.mp4                  # Arabic, large model, verbatim
    python3 transcribe.py clip.mp4 --model turbo    # faster
    python3 transcribe.py clip.mp4 --compare        # also the clean ("intended") text
    python3 transcribe.py clip.mp4 --start 60 --duration 90   # just part of the clip

Output goes to a folder next to the clip: <name>-crisperwhisper/
    index.html   open in a browser: audio player with word-by-word highlight
    words.json   every word with start, end and confidence
    audio.wav    the audio that was transcribed (16 kHz mono)

The model weights are under Nyra Health's non-commercial research license.
"""

from __future__ import annotations

import argparse
import html
import json
import shutil
import subprocess
import sys
import time
from pathlib import Path


def extract_audio(source: Path, destination: Path, start: float | None, duration: float | None) -> None:
    """Writes 16 kHz mono WAV, the input Whisper models expect."""
    if shutil.which("ffmpeg"):
        command = ["ffmpeg", "-y", "-loglevel", "error"]
        if start is not None:
            command += ["-ss", str(start)]
        if duration is not None:
            command += ["-t", str(duration)]
        command += ["-i", str(source), "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(destination)]
        subprocess.run(command, check=True)
        return
    if start is not None or duration is not None:
        sys.exit("--start/--duration need ffmpeg (brew install ffmpeg).")
    if shutil.which("afconvert"):  # built into macOS; handles audio files and most .mov/.mp4
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(source), str(destination)], check=True)
        return
    sys.exit("Need ffmpeg to read this file (brew install ffmpeg).")


def run_model(audio: Path, args: argparse.Namespace):
    try:
        from crisperwhisper import CrisperWhisperModel
    except ImportError:
        sys.exit('crisperwhisper isn\'t installed. Run: pip install "crisperwhisper[transformers]>=2.0.4"')

    print(f"Loading CrisperWhisper 2.0 {args.model} (the first run downloads the weights)…", flush=True)
    kwargs = {"device": args.device} if args.device else {}
    model = CrisperWhisperModel(args.model, **kwargs)
    print(f"Backend: {getattr(model, 'backend', '?')}", flush=True)

    def transcribe(mode: str):
        print(f"Transcribing ({mode})…", flush=True)
        began = time.monotonic()
        result = model.transcribe(str(audio), language=args.language, mode=mode, word_confidence=True)
        print(f"  done in {time.monotonic() - began:.1f}s, {len(result.words or [])} words", flush=True)
        return result

    verbatim = transcribe("verbatim")
    intended = transcribe("intended") if args.compare else None
    return verbatim, intended


def words_of(result) -> list[dict]:
    return [
        {
            "word": w.word.strip(),
            "start": round(float(w.start), 3),
            "end": round(float(w.end), 3),
            "probability": round(float(getattr(w, "probability", 1.0) or 0.0), 3),
        }
        for w in (result.words or [])
        if w.word.strip()
    ]


PAGE = """<!doctype html>
<html lang="{lang}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>CrisperWhisper test</title>
<style>
  :root {{ color-scheme: light dark; --bg:#fff; --fg:#1d1d1f; --muted:#6e6e73; --hi:#ffd60a; --low:#ff453a; --card:#f5f5f7; }}
  @media (prefers-color-scheme: dark) {{ :root {{ --bg:#1c1c1e; --fg:#f5f5f7; --muted:#98989d; --hi:#9a7b00; --card:#2c2c2e; }} }}
  body {{ margin:0; background:var(--bg); color:var(--fg); font:16px/1.5 -apple-system, system-ui, sans-serif; }}
  header {{ position:sticky; top:0; background:var(--bg); padding:12px 16px; border-bottom:1px solid var(--card); z-index:1; }}
  header h1 {{ font-size:15px; margin:0 0 6px; }}
  header .meta {{ color:var(--muted); font-size:13px; }}
  audio {{ width:100%; margin-top:8px; }}
  label {{ font-size:13px; color:var(--muted); margin-inline-end:12px; }}
  main {{ padding:16px; max-width:900px; margin:auto; }}
  .text {{ font-size:22px; line-height:2; }}
  .w {{ cursor:pointer; border-radius:4px; padding:1px 2px; transition:background .05s; }}
  .w:hover {{ outline:1px solid var(--muted); }}
  .w.on {{ background:var(--hi); }}
  .lowconf .w.low {{ text-decoration:underline wavy var(--low); }}
  .stamps .w::before {{ content:attr(data-t); font-size:10px; color:var(--muted); vertical-align:super; margin-inline-end:2px; }}
  h2 {{ font-size:14px; color:var(--muted); margin-top:32px; }}
  .intended {{ background:var(--card); border-radius:8px; padding:12px; font-size:18px; }}
  #now {{ font-variant-numeric: tabular-nums; }}
</style>
</head>
<body>
<header>
  <h1>{title}</h1>
  <div class="meta">CrisperWhisper 2.0 {model} · {mode} · language {lang} · {count} words · took {seconds}s · <span id="now">0.00</span>s</div>
  <audio id="audio" controls src="audio.wav"></audio>
  <div>
    <label><input type="checkbox" id="stamps"> show times</label>
    <label><input type="checkbox" id="lowconf" checked> mark unsure words (&lt; 50%)</label>
    <label>speed <select id="rate"><option>0.5</option><option>0.75</option><option selected>1</option><option>1.25</option></select></label>
  </div>
</header>
<main>
  <div id="text" class="text lowconf" dir="auto"></div>
  {intended}
</main>
<script>
const words = {words};
const audio = document.getElementById('audio');
const box = document.getElementById('text');
const spans = words.map((w, i) => {{
  const s = document.createElement('span');
  s.className = 'w' + (w.probability < 0.5 ? ' low' : '');
  s.textContent = w.word;
  s.dataset.t = w.start.toFixed(2);
  s.title = `${{w.start.toFixed(2)}}–${{w.end.toFixed(2)}}s · ${{Math.round(w.probability * 100)}}%`;
  s.onclick = () => {{ audio.currentTime = w.start; audio.play(); }};
  box.append(s, ' ');
  return s;
}});
// Last word that has started and not yet ended; binary search, like HT Edit's activeIndex.
function activeAt(t) {{
  let lo = 0, hi = words.length;
  while (lo < hi) {{ const mid = (lo + hi) >> 1; if (words[mid].start <= t) lo = mid + 1; else hi = mid; }}
  const i = lo - 1;
  return i >= 0 && t <= words[i].end + 0.05 ? i : -1;
}}
let current = -1;
function tick() {{
  const t = audio.currentTime;
  document.getElementById('now').textContent = t.toFixed(2);
  const i = activeAt(t);
  if (i !== current) {{
    if (current >= 0) spans[current].classList.remove('on');
    if (i >= 0) {{ spans[i].classList.add('on'); spans[i].scrollIntoView({{block:'nearest'}}); }}
    current = i;
  }}
  requestAnimationFrame(tick);
}}
requestAnimationFrame(tick);
document.getElementById('stamps').onchange = e => box.classList.toggle('stamps', e.target.checked);
document.getElementById('lowconf').onchange = e => box.classList.toggle('lowconf', e.target.checked);
document.getElementById('rate').onchange = e => audio.playbackRate = parseFloat(e.target.value);
</script>
</body>
</html>
"""


def write_page(folder: Path, data: dict) -> Path:
    intended = ""
    if data.get("intended_text"):
        intended = f'<h2>Clean ("intended") version, for comparison</h2><div class="intended" dir="auto">{html.escape(data["intended_text"])}</div>'
    page = PAGE.format(
        lang=html.escape(data["language"]),
        title=html.escape(data["source"]),
        model=html.escape(data["model"]),
        mode="verbatim",
        count=len(data["words"]),
        seconds=data["seconds"],
        intended=intended,
        words=json.dumps(data["words"], ensure_ascii=False).replace("</", "<\\/"),
    )
    path = folder / "index.html"
    path.write_text(page, encoding="utf-8")
    return path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("clip", type=Path, help="audio or video file")
    parser.add_argument("--language", default="ar", help="Whisper language code (default: ar)")
    parser.add_argument("--model", default="large", choices=["large", "turbo", "medium", "small"])
    parser.add_argument("--device", help="e.g. mps or cpu (default: the library picks)")
    parser.add_argument("--compare", action="store_true", help="also run the clean 'intended' mode")
    parser.add_argument("--start", type=float, help="seconds into the clip to begin")
    parser.add_argument("--duration", type=float, help="seconds to transcribe")
    parser.add_argument("--rebuild", action="store_true", help="only rebuild index.html from an existing words.json")
    args = parser.parse_args()

    source = args.clip.expanduser().resolve()
    folder = source.with_name(f"{source.stem}-crisperwhisper")
    folder.mkdir(exist_ok=True)

    if args.rebuild:
        data = json.loads((folder / "words.json").read_text(encoding="utf-8"))
        print(f"Open: {write_page(folder, data)}")
        return

    if not source.exists():
        sys.exit(f"No such file: {source}")
    audio = folder / "audio.wav"
    print("Extracting audio…", flush=True)
    extract_audio(source, audio, args.start, args.duration)

    began = time.monotonic()
    verbatim, intended = run_model(audio, args)
    data = {
        "source": source.name,
        "model": args.model,
        "language": args.language,
        "offset": args.start or 0,
        "seconds": round(time.monotonic() - began, 1),
        "text": verbatim.text,
        "intended_text": intended.text if intended else None,
        "words": words_of(verbatim),
    }
    (folder / "words.json").write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    page = write_page(folder, data)
    print(f"\nOpen this in a browser:\n  {page}")
    if sys.platform == "darwin":
        subprocess.run(["open", str(page)], check=False)


if __name__ == "__main__":
    main()
