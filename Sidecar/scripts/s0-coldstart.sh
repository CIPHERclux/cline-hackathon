#!/bin/sh
# Spike S0 (§15): cold start of the compiled tutor-engine, launch → first `pong`.
# Pass: p50 ≤ 600 ms over 10 runs. Runs with an empty environment (no Node/bun on PATH) and a
# fresh CLINE_DIR each time, like a first launch from the Swift app (§7.3 Launch).
# Usage: scripts/s0-coldstart.sh [path/to/tutor-engine] [runs]
set -eu
ENGINE="${1:-$(dirname "$0")/../dist/tutor-engine}"
RUNS="${2:-10}"
[ -x "$ENGINE" ] || { echo "no engine binary at $ENGINE (run: bun run build:bin)" >&2; exit 2; }

/usr/bin/python3 - "$ENGINE" "$RUNS" <<'PY'
import os, statistics, subprocess, sys, tempfile, time
engine, runs = os.path.abspath(sys.argv[1]), int(sys.argv[2])
timings = []
for run in range(1, runs + 1):
    with tempfile.TemporaryDirectory(prefix="chalk-coldstart-") as cline_dir:
        env = {"PATH": "/usr/bin:/bin", "HOME": cline_dir, "CLINE_DIR": cline_dir}
        started = time.perf_counter()
        child = subprocess.Popen([engine], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env)
        child.stdin.write(b'{"id":"cold","op":"ping"}\n'); child.stdin.flush()
        line = child.stdout.readline()
        elapsed_ms = (time.perf_counter() - started) * 1000
        child.stdin.close(); child.wait(timeout=10)
        if b'"pong"' not in line:
            print(f"run {run}: no pong, got {line!r}"); sys.exit(1)
        timings.append(elapsed_ms)
        print(f"run {run:2d}: {elapsed_ms:6.1f} ms")
p50 = statistics.median(timings)
print(f"p50 {p50:.1f} ms | min {min(timings):.1f} | max {max(timings):.1f} | threshold 600 ms")
sys.exit(0 if p50 <= 600 else 1)
PY
