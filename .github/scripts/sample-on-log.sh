#!/bin/bash
# Samples "HT Edit" a moment after a matching line appears in a growing log,
# so a stall that starts at a known event is captured in the act.
#   sample-on-log.sh <log-file> <pattern> <output-prefix> [delay-seconds]
set +e
log=$1
pattern=$2
prefix=$3
delay=${4:-2}
mkdir -p samples
n=0
tail -n 0 -F "$log" 2>/dev/null | grep --line-buffered -E "$pattern" | while read -r _; do
  n=$((n + 1))
  ( sleep "$delay"
    pid=$(pgrep -x "HT Edit" | head -1)
    [ -n "$pid" ] && sudo /usr/bin/sample "$pid" 3 5 -mayDie -file "$PWD/samples/$prefix-$n.txt" >> samples/sampler-errors.txt 2>&1
  ) &
done
