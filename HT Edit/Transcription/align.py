# /// script
# requires-python = ">=3.10,<3.14"
# dependencies = [
#     "torch==2.8.0",
#     "torchaudio==2.8.0",
#     "uroman==1.3.1.1",
#     "numpy",
# ]
# ///
"""Word timing for HT Edit: forced alignment of known text to audio.

HT Edit already has the words (from Gemini) and roughly when each sentence
was said. This script finds, from the waveform itself, where each word starts
and ends. It uses Meta's MMS forced-alignment model (wav2vec2, trained on
1,100+ languages, Arabic included), which listens in 20 ms frames.

Run by HT Edit through uv, which installs a private Python and these
dependencies on first use (nothing touches the system Python):

    uv run --script align.py AUDIO.wav REQUEST.json

AUDIO.wav  16 kHz mono 16-bit PCM.
REQUEST    {"padding": 1.0,
            "segments": [{"start": 1.2, "end": 4.8, "words": ["...", "..."]}]}
           Times are seconds within AUDIO.wav.

Prints   {"segments": [{"words": [{"start": s, "end": e, "score": p} | null, ...]} | null]}
         Times are seconds within AUDIO.wav. A null segment couldn't be aligned;
         a null word had nothing to align (digits, symbols). HT Edit fills those in.

Progress and errors go to stderr. Exit status 0 means stdout holds the answer.
"""

import json
import math
import os
import re
import sys
import unicodedata
import warnings
import wave

SAMPLE_RATE = 16_000
# Below these average letter confidences the text wasn't found in the audio
# (wrong line times, say): better to estimate than to trust the placement.
# Real speech scores well above them, even sung or recited.
MIN_SEGMENT_SCORE = 0.05
MIN_WORD_SCORE = 0.02
ARABIC = re.compile(r"[؀-ۿݐ-ݿࢠ-ࣿﭐ-﷿ﹰ-﻿]")
TATWEEL = "ـ"


def log(message):
    print(message, file=sys.stderr, flush=True)


def read_wav(path):
    import numpy

    with wave.open(path, "rb") as file:
        if file.getnchannels() != 1 or file.getsampwidth() != 2 or file.getframerate() != SAMPLE_RATE:
            raise ValueError("expected 16 kHz mono 16-bit PCM")
        frames = file.readframes(file.getnframes())
    return numpy.frombuffer(frames, dtype="<i2").astype(numpy.float32) / 32768.0


class Romanizer:
    """Turns a written word into the letters the model knows (a–z and ')."""

    def __init__(self, labels):
        import uroman

        self.uroman = uroman.Uroman()
        # "-" is the model's blank and "*" its star: never letters of a word.
        self.known = set(labels) - {"-", "*"}

    def letters(self, word):
        text = unicodedata.normalize("NFC", word).replace(TATWEEL, "")
        language = "ara" if ARABIC.search(text) else None
        text = self.uroman.romanize_string(text, lcode=language)
        text = text.lower().replace("’", "'")
        return [c for c in text if c in self.known]


def load_model():
    import torch
    import torchaudio

    bundle = torchaudio.pipelines.MMS_FA
    model = bundle.get_model(with_star=False)
    device = "cpu"
    if torch.backends.mps.is_available():
        try:
            model = model.to("mps")
            device = "mps"
        except Exception as error:  # noqa: BLE001 - any failure: stay on the CPU
            log(f"MPS unavailable ({error}); using the CPU")
    model.eval()
    dictionary = bundle.get_dict(star=None)
    return model, dictionary, device


def emission_for(model, device, samples):
    """Log-probabilities per 20 ms frame, with a free 'star' column appended.

    The star token matches anything at no cost. Putting one before and after
    the words lets padding that holds other speech (the end of the previous
    sentence, the start of the next) be absorbed instead of pulling words
    out of place.
    """
    import torch

    with torch.inference_mode():
        waveform = torch.from_numpy(samples).unsqueeze(0).to(device)
        emission, _ = model(waveform)
        emission = torch.log_softmax(emission.float(), dim=-1).cpu()[0]
    star = torch.zeros((emission.shape[0], 1))
    return torch.cat([emission, star], dim=1)


def align_segment(model, device, dictionary, romanizer, samples, segment, padding):
    import torch
    import torchaudio.functional as F

    total = len(samples) / SAMPLE_RATE
    start = max(0.0, float(segment["start"]) - padding)
    end = min(total, float(segment["end"]) + padding)
    words = segment.get("words") or []
    if end - start < 0.05 or not words:
        return None

    letters = [romanizer.letters(word) for word in words]
    if not any(letters):
        return None

    first = int(start * SAMPLE_RATE)
    last = int(math.ceil(end * SAMPLE_RATE))
    emission = emission_for(model, device, samples[first:last])
    star = emission.shape[1] - 1
    seconds_per_frame = (last - first) / SAMPLE_RATE / emission.shape[0]

    targets = [star]
    for word in letters:
        targets.extend(dictionary[c] for c in word)
    targets.append(star)
    try:
        path, scores = F.forced_align(
            emission.unsqueeze(0), torch.tensor([targets], dtype=torch.int32), blank=0
        )
    except Exception as error:  # noqa: BLE001 - too little audio for the text, and the like
        log(f"segment at {segment['start']:.2f}s not aligned: {error}")
        return None

    spans = F.merge_tokens(path[0], scores[0].exp())
    # merge_tokens returns one span per target token, in order: the star, the
    # letters of each word, then the star again.
    spans = spans[1:-1] if len(spans) == len(targets) else None
    if spans is None:
        return None

    result = []
    index = 0
    for word in letters:
        if not word:
            result.append(None)
            continue
        own = spans[index:index + len(word)]
        index += len(word)
        score = sum(s.score for s in own) / len(own)
        result.append(None if score < MIN_WORD_SCORE else {
            "start": round(start + own[0].start * seconds_per_frame, 3),
            "end": round(start + own[-1].end * seconds_per_frame, 3),
            "score": round(score, 3),
        })

    letter_spans = spans[:index]
    if sum(s.score for s in letter_spans) / len(letter_spans) < MIN_SEGMENT_SCORE:
        log(f"segment at {segment['start']:.2f}s: text not found in the audio")
        return None
    return {"words": result}


def main():
    if len(sys.argv) != 3:
        log("usage: align.py AUDIO.wav REQUEST.json")
        return 2
    with open(sys.argv[2], encoding="utf-8") as file:
        request = json.load(file)
    samples = read_wav(sys.argv[1])
    padding = float(request.get("padding", 1.0))
    segments = request.get("segments") or []

    log(f"Aligning {len(segments)} segment(s) in {len(samples) / SAMPLE_RATE:.1f}s of audio")
    model, dictionary, device = load_model()
    romanizer = Romanizer(dictionary.keys())

    results = []
    for segment in segments:
        try:
            results.append(align_segment(model, device, dictionary, romanizer, samples, segment, padding))
        except Exception as error:  # noqa: BLE001 - one bad segment shouldn't sink the rest
            log(f"segment failed: {error}")
            results.append(None)
    json.dump({"segments": results}, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
    # torchaudio 2.8 warns that forced_align moves elsewhere in 2.9; it's pinned to 2.8.
    warnings.filterwarnings("ignore", category=UserWarning)
    sys.exit(main())
