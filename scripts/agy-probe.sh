#!/bin/zsh
# Checks that the installed Antigravity CLI can do what HT Edit asks of it:
# headless mode, JSON output, model choice, and proofreading transcript lines
# without dropping words or changing the dialect.
#
# Run once on your Mac, after installing agy and signing in:
#   zsh scripts/agy-probe.sh [model]
#
# It runs the same command HT Edit runs (see AgyCommand in
# "HT Edit/Transcription/AgyCleaner.swift"); keep the two in sync.

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

schema='{"type":"object","properties":{"lines":{"type":"array","items":{"type":"object","properties":{"id":{"type":"integer"},"text":{"type":"string"}},"required":["id","text"]}}},"required":["lines"]}'
prompt='You are proofreading an automatic speech-to-text transcript. A speech recognizer wrote each line below; each has an id.
Fix only words the recognizer clearly misheard, using the meaning of the surrounding lines, the whole transcript and the context.
Rules:
- Keep the speaker'"'"'s own dialect and wording. If they speak a dialect (for example Egyptian Arabic), keep that dialect: never rewrite it into the standard or formal language, and never make it more formal.
- Never drop, summarize, shorten, merge, split, reorder or add anything. Repeated words, false starts and filler stay. Every input line gets exactly one output line with the same id.
- When the speaker says an English word or a product name, write it the usual way in Latin letters (for example ChatGPT, Gemini, privacy), even inside an Arabic line.
- If a line is already right, or you aren'"'"'t sure, return it unchanged.
- Don'"'"'t run commands, and don'"'"'t read or change any files.
Lines to proofread (JSON):
[{"id":0,"text":"لو انت مهتم قوي بالخصوصية والبرايفيسي"},{"id":1,"text":"فدي حاجة لازم تعملها على شاتي بيتي"}]
Reply only with JSON of the form {"lines":[{"id":0,"text":"..."}]}.'

echo "\n== Proofreading two lines with $model (what HT Edit runs) =="
cd "$work"
"$agy" -p "$prompt" --output-format json --json-schema "$schema" --model "$model" --print-timeout 300s
status=$?
echo "\n(exit status $status)"
echo "\nExpected: JSON with lines 0 and 1, still in Egyptian Arabic, with \"شاتي بيتي\" written as ChatGPT."
