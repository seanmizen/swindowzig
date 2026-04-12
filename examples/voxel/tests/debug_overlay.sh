#!/usr/bin/env bash
# debug_overlay.sh — verify the F3-style debug info panel actually renders
# when Cmd+D debug mode is on.
#
# Strategy: run the same TAS twice — once with --debug=off (default) and
# once with --debug=on. Compare the top-left 320×320 corner of the resulting
# PPM dumps. If the panel rendered, the corner brightness must change
# noticeably: white text (0.95, 0.95, 0.95) dominates the translucent black
# background, so panel-on is BRIGHTER than baseline by ~5–10/255.
#
# The keyboard HUD also paints in --debug=on, but it lives in the bottom
# half of the screen, so it does not affect the top-left sample region.
# Chunk borders are 3D world geometry — they show up wherever the camera
# happens to look, but the camera in this TAS faces the default spawn
# vista where the borders sit well below the top of the frame.
set -euo pipefail

cd "$(dirname "$0")/../../.."  # → utils/swindowzig

VOXEL=./zig-out/bin/voxel
TAS=examples/voxel/tests/debug_overlay.tas

if [[ ! -x "$VOXEL" ]]; then
    echo "voxel binary missing — run: zig build native -Dexample=voxel"
    exit 1
fi

BASELINE=/tmp/voxel_dbg_panel_baseline.ppm
PANEL=/tmp/voxel_dbg_panel_on.ppm

echo "[1/2] baseline (--debug=off, no panel)"
"$VOXEL" --debug=off --tas "$TAS" --dump-frame="$BASELINE" \
    >/tmp/voxel_dbg_panel_baseline.log 2>&1 || {
        tail -20 /tmp/voxel_dbg_panel_baseline.log
        exit 1
    }

echo "[2/2] panel (--debug=on, F3 info panel rendered)"
"$VOXEL" --debug=on --tas "$TAS" --dump-frame="$PANEL" \
    >/tmp/voxel_dbg_panel_on.log 2>&1 || {
        tail -20 /tmp/voxel_dbg_panel_on.log
        exit 1
    }

python3 - "$BASELINE" "$PANEL" <<'PY'
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
panel = sys.argv[2]
a = avg_corner(baseline, 320, 320)
b = avg_corner(panel, 320, 320)
delta = b - a  # panel run should be BRIGHTER than baseline (white text wins)
print(f"top-left avg  baseline={a:.2f}  panel={b:.2f}  delta={delta:+.2f}")
if delta < 2.0:
    print("FAIL: top-left brightness delta < 2.0 — F3 panel did not render")
    sys.exit(1)
print("PASS: F3 debug info panel rendered as expected")
PY
