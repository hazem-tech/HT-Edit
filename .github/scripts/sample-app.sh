#!/bin/bash
# Samples the running "HT Edit" process every few seconds, so a stalled main
# thread shows up in CI with a full call stack.
#   sample-app.sh <output-prefix> <interval-seconds>
set +e
prefix=$1
interval=${2:-3}
mkdir -p samples
n=0
while true; do
  sleep "$interval"
  pid=$(pgrep -x "HT Edit" | head -1)
  [ -z "$pid" ] && continue
  n=$((n + 1))
  sudo /usr/bin/sample "$pid" 1 -mayDie -file "$PWD/samples/$prefix-$n.txt" >> samples/sampler-errors.txt 2>&1
done
