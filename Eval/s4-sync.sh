#!/bin/bash
# S4 sync check (§11.2, DEMO_PLAN S06): stroke onset within 150 ms of the anchor word, p95.
# Reads the app's `🖍️ sync` lines from the unified log. Run "Test drawing (S4)" from the
# panel (Debug build) a few times, then: Eval/s4-sync.sh [minutes, default 10]
# Measured from the TTS word callback to the stroke (or the pen flying to it, D50) being handed to
# Core Animation; the first frame appears at the next display refresh (≤ 17 ms later at 60 Hz).
# With the pen, ink starts penApproachMs later; that is reported as "ink" but not gated.
set -euo pipefail
minutes="${1:-10}"
log show --last "${minutes}m" --info --style compact \
  --predicate 'subsystem == "com.chalk.app" AND category == "sync"' 2>/dev/null \
  | grep "🖍️ sync" \
  | awk '
    BEGIN { n = 0; misses = 0 }
    /strokeDelayMs=/ {
      match($0, /strokeDelayMs=[0-9.]+/); delay = substr($0, RSTART + 14, RLENGTH - 14) + 0
      approach = 0
      if (match($0, /penApproachMs=[0-9.]+/)) approach = substr($0, RSTART + 14, RLENGTH - 14) + 0
      delays[n] = delay; inks[n] = delay + approach; n++
    }
    /miss=/ { misses++ }
    END {
      total = n + misses
      if (total == 0) { print "No sync lines. Run \"Test drawing (S4)\" in a Debug build first."; exit 1 }
      # insertion sort (small n)
      for (i = 1; i < n; i++) { v = delays[i]; j = i - 1; while (j >= 0 && delays[j] > v) { delays[j + 1] = delays[j]; j-- } delays[j + 1] = v }
      for (i = 1; i < n; i++) { v = inks[i]; j = i - 1; while (j >= 0 && inks[j] > v) { inks[j + 1] = inks[j]; j-- } inks[j + 1] = v }
      p50 = n ? delays[int((n - 1) * 0.5)] : -1
      p95 = n ? delays[int((n - 1) * 0.95 + 0.999)] : -1
      printf "anchored drawings: %d timed, %d missed (late or utterance end)\n", n, misses + 0
      if (n) printf "onset (mark or pen moving) p50 %.1f ms, p95 %.1f ms, max %.1f ms\n", p50, p95, delays[n - 1]
      if (n) printf "ink after the pen arrives  p50 %.1f ms, p95 %.1f ms\n", inks[int((n - 1) * 0.5)], inks[int((n - 1) * 0.95 + 0.999)]
      pass = (n > 0 && p95 <= 150 && misses == 0)
      print (pass ? "S4 PASS (p95 ≤ 150 ms, no misses)" : "S4 FAIL")
      exit (pass ? 0 : 2)
    }'
