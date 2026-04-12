#!/usr/bin/env bash
# debug_overlay.sh — verify the F3-style debug overlay actually renders.
#
# Strategy: run the same TAS twice, once with --debug-overlay=on (so the
# H-key toggle in the script flips it OFF) and once without the flag (so
# H toggles it ON). Compare the top-left 320×320 corner of the resulting
# PPM dumps. If the overlay rendered, the corner brightness must drop
# noticeably (the translucent black rect alone gives ~6/255).
#
# Run from the swindowzig directory (or any subdir — the script cds up).
set -euo pipefail

cd "$(dirname "$0")/../../.."  # → utils/swindowzig

VOXEL=./zig-out/bin/voxel
TAS=examples/voxel/tests/debug_overlay.tas

if [[ ! -x "$VOXEL" ]]; then
    echo "voxel binary missing — run: zig build native -Dexample=voxel"
    exit 1
fi

BASELINE=/tmp/voxel_dbg_overlay_baseline.ppm
OVERLAY=/tmp/voxel_dbg_overlay_on.ppm

echo "[1/2] baseline (overlay forced OFF via flag, then H toggles to OFF)"
"$VOXEL" --debug-overlay=on --tas "$TAS" --dump-frame="$BASELINE" \
    >/tmp/voxel_dbg_baseline.log 2>&1 || {
        tail -20 /tmp/voxel_dbg_baseline.log
        exit 1
    }

echo "[2/2] overlay (default OFF, H toggles to ON)"
"$VOXEL" --tas "$TAS" --dump-frame="$OVERLAY" \
    >/tmp/voxel_dbg_overlay.log 2>&1 || {
        tail -20 /tmp/voxel_dbg_overlay.log
        exit 1
    }

python3 - "$BASELINE" "$OVERLAY" <<'PY'
import sys

def read_ppm(p):
    with open(p, 'rb') as f:
        d = f.read()
    i = 0
    tokens = []
    while len(tokens) < 4:
        while d[i:i+1] in (b' ', b'\t', b'\n', b'\r'):
            i += 1
        if d[i:i+1] == b'#':
            while d[i:i+1] != b'\n':
                i += 1
            continue
        j = i
        while d[j:j+1] not in (b' ', b'\t', b'\n', b'\r'):
            j += 1
        tokens.append(d[i:j])
        i = j
    i += 1  # exactly one whitespace byte after maxval
    return int(tokens[1]), int(tokens[2]), d[i:]

def avg_corner(p, cw, ch):
    w, h, px = read_ppm(p)
    s, n = 0, 0
    for y in range(ch):
        base = y * w * 3
        for x in range(cw):
            o = base + x * 3
            s += px[o] + px[o+1] + px[o+2]
            n += 3
    return s / n

baseline = sys.argv[1]
overlay = sys.argv[2]
a = avg_corner(baseline, 320, 320)
b = avg_corner(overlay, 320, 320)
delta = a - b  # overlay should be DARKER than baseline
print(f"top-left avg  baseline={a:.2f}  overlay={b:.2f}  delta={delta:+.2f}")
if delta < 1.0:
    print("FAIL: top-left brightness delta < 1.0 — overlay did not render")
    sys.exit(1)
print("PASS: F3 debug overlay rendered as expected")
PY
