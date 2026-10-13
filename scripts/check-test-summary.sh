#!/bin/bash
# Regression check for the --test summary: start a 30 s test, interrupt it with SIGINT after 20 s, and verify
# that the reported cycle count matches 20 s × (sample rate / frames per cycle).
# Run from Terminal (the microphone permission is attributed to the app that launches the command).
set -euo pipefail
cd "$(dirname "$0")/.."

BIN=${1:-.build/debug/MicBridge}
STOP_AFTER=${STOP_AFTER:-20}
[[ -x "$BIN" ]] || { echo "build first: swift build"; exit 1; }

out=$(mktemp -t micbridge-check)
trap 'rm -f "$out"' EXIT

"$BIN" --test --seconds 30 >"$out" 2>&1 &
pid=$!
sleep "$STOP_AFTER"
kill -INT "$pid"
status=0
wait "$pid" || status=$?

summary=$(tr '\r' '\n' <"$out" | grep '^summary:' || true)
if [[ -z "$summary" ]]; then
    echo "FAIL: no summary line (exit $status)"; tr '\r' '\n' <"$out" | tail -20; exit 1
fi
echo "$summary"

field() { sed -E "s/.* $1=([^ ]+).*/\1/" <<<" ${summary#summary:}"; }
elapsed=$(field elapsed); cycles=$(field cycles); rate=$(field rate); frames=$(field frames)
interrupted=$(field interrupted)

python3 -I - "$elapsed" "$cycles" "$rate" "$frames" "$interrupted" "$STOP_AFTER" <<'PY'
import sys
elapsed, cycles, rate, frames, interrupted, stop = map(float, sys.argv[1:])
ok = True
def check(name, cond, detail):
    global ok
    print(("PASS" if cond else "FAIL"), name, "-", detail)
    ok &= cond
check("interrupted by SIGINT", interrupted == 1, f"interrupted={int(interrupted)}")
check("elapsed ≈ stop time", stop - 1.0 <= elapsed <= stop + 0.5, f"{elapsed:.2f} s for SIGINT at {stop:.0f} s")
per_cycle = rate / frames if frames else 0
exp_elapsed = elapsed * per_cycle
check("cycles match elapsed time", frames > 0 and abs(cycles - exp_elapsed) / exp_elapsed < 0.02,
      f"{cycles:.0f} cycles vs {exp_elapsed:.0f} expected ({per_cycle:.2f}/s × {elapsed:.2f} s)")
exp_stop = stop * per_cycle
check(f"cycles ≈ {stop:.0f} s × rate/frames", frames > 0 and abs(cycles - exp_stop) / exp_stop < 0.05,
      f"{cycles:.0f} vs {exp_stop:.0f} (±5 %, includes start-up time)")
sys.exit(0 if ok else 1)
PY
