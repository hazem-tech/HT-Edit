#!/bin/zsh
# Checks that the installed Antigravity CLI can do what HT Edit asks of it:
# headless mode, JSON output, model choice, and hearing an audio file.
#
# Run once on your Mac, after installing agy and signing in:
#   zsh scripts/agy-probe.sh [model]
#
# It runs the same command HT Edit runs (see AgyCommand in
# "HT Edit/Transcription/AgyEngine.swift"); keep the two in sync.

set -u
model="${1:-gemini-3.8-flash-low}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

agy="$(command -v agy || true)"
[[ -z "$agy" && -x "$HOME/.local/bin/agy" ]] && agy="$HOME/.local/bin/agy"
if [[ -z "$agy" ]]; then
  echo "✗ agy not found. Install the Antigravity CLI, sign in, and run this again."
  exit 1
fi
echo "✓ agy: $agy ($("$agy" --version 2>&1 | head -1))"

echo "\n== agy models =="
if ! "$agy" models; then
  echo "✗ 'agy models' failed: run agy once in Terminal to sign in."
  exit 1
fi

echo "\n== Making a test clip with speech =="
say -o "$work/probe.aiff" "Hello from H T Edit. This is the second sentence."
afconvert -f m4af -d aac "$work/probe.aiff" "$work/chunk-1.m4a"
rm "$work/probe.aiff"
echo "✓ $work/chunk-1.m4a"

schema='{"type":"object","properties":{"segments":{"type":"array","items":{"type":"object","properties":{"start":{"type":"number"},"end":{"type":"number"},"text":{"type":"string"}},"required":["start","end","text"]}}},"required":["segments"]}'
prompt="Transcribe the speech in the audio file @chunk-1.m4a verbatim, in the language that is spoken.
The file is 4.0 seconds long.
Split the speech into short segments at sentence or phrase boundaries, each at most about 10 seconds.
For each segment give start and end in seconds from the beginning of this file, and the text.
If there is no speech, return an empty list.
Only read that file: don't run commands or change any files.
Reply only with JSON of the form {\"segments\":[{\"start\":0.0,\"end\":2.5,\"text\":\"...\"}]}."

echo "\n== Transcribing with $model (what HT Edit runs) =="
cd "$work"
"$agy" -p "$prompt" --output-format json --json-schema "$schema" --model "$model" --print-timeout 300s
status=$?
echo "\n(exit status $status)"
echo "\nExpected: JSON with two segments, \"Hello from HT Edit.\" then \"This is the second sentence.\", with increasing start times."
echo "If the reply says it can't hear or open the file, send this whole output to the HT Edit developer."
