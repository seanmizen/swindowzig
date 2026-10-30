#!/usr/bin/env bash
# chunk_border.sh: make sure that the terrain hides the chunk border lines
# of debug mode.
#
# Debug mode draws the 12 edges of the chunk of the player. The 4 corner
# lines go from the bottom of the world to the top. Each TAS run turned
# debug mode on. When the border pipeline had no depth test, the lines
# drew through the ground, from the top of the frame to the bottom, and
# they looked like a thin dark crack in the far terrain.
#
# Procedure: render the flatland_forward TAS on flatland two times, with
# --debug=off and with --debug=on. Compare rows 400 to 629 of the two
# frames. These rows show only near ground: they are below the debug panel
# and the keyboard HUD, above the hotbar, and below the foot of each corner
# line. Thus the two frames must be the same in these rows.
#
# Baseline (Metal): 0 pixels differ. With no depth test: 1242 pixels
# differ, on the 2 corner lines in front of the camera.
#
# Usage (from the repo root):
#   zig build native -Dexample=voxel
#   ./examples/voxel/tests/chunk_border.sh
set -euo pipefail

cd "$(dirname "$0")/../../.."  # the repo root

VOXEL=./zig-out/bin/voxel
TAS=examples/voxel/tests/flatland_forward.tas
OUT=${TMPDIR:-/tmp}

if [[ ! -x "$VOXEL" ]]; then
    echo "voxel binary missing. Run: zig build native -Dexample=voxel"
    exit 1
fi

OFF="$OUT/voxel_chunk_border_off.ppm"
ON="$OUT/voxel_chunk_border_on.ppm"

for mode in off on; do
    frame="$OUT/voxel_chunk_border_$mode.ppm"
    echo "render --debug=$mode"
    "$VOXEL" --headless --world=flatland --debug=$mode --tas "$TAS" \
        --dump-frame="$frame" >"$OUT/voxel_chunk_border_$mode.log" 2>&1 || {
            tail -20 "$OUT/voxel_chunk_border_$mode.log"
            exit 1
        }
done

python3 - "$OFF" "$ON" <<'PY'
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
    i += 1  # one whitespace byte after maxval
    return int(tokens[1]), int(tokens[2]), d[i:]

w, h, off = read_ppm(sys.argv[1])
w2, h2, on = read_ppm(sys.argv[2])
if (w, h) != (w2, h2):
    print(f"FAIL: the frame sizes are different: {w}x{h} and {w2}x{h2}")
    sys.exit(1)
y0, y1 = 400, 630
diff = 0
for y in range(y0, y1):
    for x in range(w):
        o = (y * w + x) * 3
        if off[o:o+3] != on[o:o+3]:
            diff += 1
print(f"rows {y0}-{y1 - 1}: {diff} pixels differ between --debug=off and --debug=on")
if diff != 0:
    print("FAIL: the chunk border lines draw through the ground")
    sys.exit(1)
print("PASS: the ground hides the chunk border lines")
PY
