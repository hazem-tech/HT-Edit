#!/bin/zsh
# Sets up HT Edit's local Whisper: a Python venv with faster-whisper, and the
# large-v3-turbo model (about 1.6 GB). HT Edit runs this from its Transcript
# tab ("Set Up Whisper"); you can also run it yourself:
#
#   zsh "HT Edit/Transcription/Whisper/whisper_setup.sh" [root] [existing-model-dir]
#
# root               where to install (default: ~/Library/Application Support/HT Edit/Whisper)
# existing-model-dir a faster-whisper large-v3-turbo folder you already have
#                    (with model.bin); it's copied instead of downloaded.
#
# Running it again is safe: finished steps are skipped.

set -eu
root="${1:-$HOME/Library/Application Support/HT Edit/Whisper}"
existing="${2:-}"
model_name="large-v3-turbo"
venv="$root/venv"
model_dir="$root/models/$model_name"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

mkdir -p "$root/models"

python=""
for candidate in python3.12 python3.13 python3.11 python3.10 python3; do
  if command -v "$candidate" >/dev/null 2>&1; then
    if "$candidate" -c 'import sys; sys.exit(0 if (3, 9) <= sys.version_info[:2] <= (3, 13) else 1)' 2>/dev/null; then
      python="$(command -v "$candidate")"
      break
    fi
  fi
done
if [[ -z "$python" ]]; then
  echo "✗ No Python 3.9–3.13 found. Install one (for example: brew install python@3.12) and try again."
  exit 1
fi
echo "✓ Python: $python ($("$python" --version 2>&1))"

if [[ ! -x "$venv/bin/python" ]]; then
  echo "Creating the Python environment…"
  "$python" -m venv "$venv"
fi
if ! "$venv/bin/python" -c 'import faster_whisper' 2>/dev/null; then
  echo "Installing faster-whisper (about 100 MB)…"
  "$venv/bin/python" -m pip install --quiet --upgrade pip
  "$venv/bin/python" -m pip install --quiet faster-whisper
fi
echo "✓ faster-whisper $("$venv/bin/python" -c 'import faster_whisper; print(faster_whisper.__version__)')"

if [[ ! -f "$model_dir/model.bin" ]]; then
  if [[ -n "$existing" && -f "$existing/model.bin" ]]; then
    echo "Copying the model from $existing…"
    rm -rf "$model_dir.partial"
    cp -R "$existing" "$model_dir.partial"
  else
    echo "Downloading Whisper $model_name (about 1.6 GB)…"
    rm -rf "$model_dir.partial"
    HF_HUB_DISABLE_TELEMETRY=1 HF_HUB_DISABLE_PROGRESS_BARS=1 "$venv/bin/python" -c '
import sys
from faster_whisper import download_model
download_model(sys.argv[1], output_dir=sys.argv[2])
' "$model_name" "$model_dir.partial"
  fi
  rm -rf "$model_dir"
  mv "$model_dir.partial" "$model_dir"
fi
echo "✓ Model: $model_dir"
echo "Whisper is ready."
