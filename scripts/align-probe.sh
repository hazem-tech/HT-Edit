#!/bin/zsh
# Checks that word timing works on this Mac: uv is installed, and the aligner
# HT Edit bundles can measure the words of a short clip with speech.
#
# Run once on your Mac:
#   zsh scripts/align-probe.sh
#
# The first run downloads a private Python, PyTorch and the alignment model (from Hugging Face)
# (about 2–3 GB in all) into uv's and Hugging Face's caches; later runs are offline.
# It runs the same command HT Edit runs (see UVWordAligner in
# "HT Edit/Transcription/WordAligner.swift"); keep the two in sync.

set -u
here="${0:A:h}"
script="$here/../HT Edit/Transcription/align.py"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

uv="$(command -v uv || true)"
[[ -z "$uv" && -x "$HOME/.local/bin/uv" ]] && uv="$HOME/.local/bin/uv"
if [[ -z "$uv" ]]; then
  echo "✗ uv not found. Install it with:  brew install uv   (or: curl -LsSf https://astral.sh/uv/install.sh | sh)"
  exit 1
fi
echo "✓ uv: $uv ($("$uv" --version))"

echo "\n== Making a test clip with speech =="
say -v Majed -o "$work/speech.aiff" "مرحبا بكم في هذا الاختبار" 2>/dev/null \
  || say -o "$work/speech.aiff" "Hello and welcome to this test"
afconvert -f WAVE -d LEI16@16000 -c 1 "$work/speech.aiff" "$work/speech.wav"
if say -v '?' | grep -q Majed; then words='["مرحبا","بكم","في","هذا","الاختبار"]'; else words='["Hello","and","welcome","to","this","test"]'; fi
duration="$(afinfo "$work/speech.wav" | awk '/estimated duration/ {print $3}')"
echo "{\"padding\":0.5,\"segments\":[{\"start\":0,\"end\":$duration,\"words\":$words}]}" > "$work/request.json"
echo "✓ $duration s, words: $words"

echo "\n== Aligning (the first run downloads everything; give it a few minutes) =="
UV_PYTHON_PREFERENCE=only-managed PYTORCH_ENABLE_MPS_FALLBACK=1 \
  "$uv" run --quiet --script "$script" "$work/speech.wav" "$work/request.json" || {
  echo "✗ The aligner failed (see above)."
  exit 1
}
echo "\n✓ Word timing works. Each word above has its start and end in seconds."
