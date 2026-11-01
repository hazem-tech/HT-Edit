#!/bin/bash
# Prints the main-thread call graph of each sample whose main thread was busy
# (not just waiting in the run loop).
set +e
for f in $(ls samples/*.txt 2>/dev/null | grep -v sampler-errors | sort -V); do
  main=$(awk '/Call graph:/{cg=1} cg && /com.apple.main-thread/{m=1} m{print; c++} c>60{exit}' "$f")
  # An idle main thread sits in mach_msg within the first few frames of the run loop.
  if echo "$main" | head -14 | grep -q "mach_msg2_trap"; then
    echo "--- $f: main thread idle ---"
    continue
  fi
  echo "--- $f: main thread BUSY ---"
  echo "$main" | cut -c1-230
done
echo "--- sampler errors ---"
tail -5 samples/sampler-errors.txt 2>/dev/null
