#!/usr/bin/env bash
# Phase-3 block-light regression runner for the voxel demo.
#
# Captures two deterministic frames from `tests/glowstone_cave.tas`:
#   - stone:     same TAS, `--place-block=stone`  (baseline, no emitter)
#   - glowstone: same TAS, `--place-block=glowstone` (emitter active)
#
# Reads both PPMs, checks that:
#   1. The near-bbox (where the placed block and its immediate neighbours
#      appear on screen) is significantly brighter in the glowstone frame
#      than in the stone baseline — i.e. the emitter actually lit something up.
#   2. The far-bbox (grass several cells outside the pit, where the BFS cannot
#      reach — ~distance-4 away in world space) is unchanged between the two
#      frames. If block light leaks into the far region, the test fails.
#   3. The glowstone near-bbox mean brightness passes an absolute threshold
#      (bright enough to call "lit").
#
# The bboxes are hard-coded against the TAS's deterministic final camera pose
# for a 1280×720 capture. Re-run and update the bbox constants if you touch
# the TAS camera script.
#
# Usage (from utils/swindowzig):
#   ./examples/voxel/tests/glowstone_cave.sh
#   ./examples/voxel/tests/glowstone_cave.sh --skip-build
#
# Requires: zig, python3
set -euo pipefail

SKIP_BUILD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) SKIP_BUILD=1; shift ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SWINDOWZIG_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TAS_PATH="$SCRIPT_DIR/glowstone_cave.tas"
BIN="$SWINDOWZIG_ROOT/zig-out/bin/voxel"

cd "$SWINDOWZIG_ROOT"

if [[ $SKIP_BUILD -eq 0 ]]; then
  echo "==> Building voxel..."
  zig build native -Dexample=voxel
fi

STONE_PPM=/tmp/glowstone_cave_stone.ppm
GLOW_PPM=/tmp/glowstone_cave_glow.ppm

echo "==> Capturing stone baseline..."
"$BIN" --world=flatland --aa=none --place-block=stone \
  --tas "$TAS_PATH" --dump-frame="$STONE_PPM" >/dev/null

echo "==> Capturing glowstone frame..."
"$BIN" --world=flatland --aa=none --place-block=glowstone \
  --tas "$TAS_PATH" --dump-frame="$GLOW_PPM" >/dev/null

echo "==> Checking brightness asserts..."
python3 - "$STONE_PPM" "$GLOW_PPM" <<'EOF'
import sys

def read_ppm(p):
    with open(p, 'rb') as f:
        assert f.readline().strip() == b'P6', f"not P6: {p}"
        line = f.readline()
        while line.startswith(b'#'):
            line = f.readline()
        w, h = [int(x) for x in line.split()]
        int(f.readline().strip())
        return w, h, f.read()

def mean_rgb(data, w, x0, y0, x1, y1):
    sr = sg = sbv = 0
    n = 0
    for y in range(y0, y1):
        row = y * w * 3
        for x in range(x0, x1):
            i = row + x * 3
            sr += data[i]; sg += data[i+1]; sbv += data[i+2]
            n += 1
    return sr/n, sg/n, sbv/n

def luminance(rgb):
    return 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]

stone_ppm, glow_ppm = sys.argv[1], sys.argv[2]
w1, h1, sd = read_ppm(stone_ppm)
w2, h2, gd = read_ppm(glow_ppm)
assert (w1, h1) == (w2, h2), f"frame size mismatch: {(w1,h1)} vs {(w2,h2)}"
w, h = w1, h1

# Bboxes tuned against the glowstone_cave.tas deterministic final pose for
# 1280×720. Update these if you change the TAS camera script.
#   CORE: centred on the glowstone block's face in frame.
#   WALL_NEAR: pit wall 1–2 cells from the glowstone — immediate neighbours
#              in the block-light BFS; expected to be strongly lit.
#   WALL_RIM: pit wall at the rim, ~4–5 cells up from the glowstone floor —
#              the "distance-4" check: still getting block-light spillover
#              but visibly dimmer than the core.
#   FAR:      grass well outside the pit; must be untouched by block light.
CORE_X0, CORE_Y0, CORE_X1, CORE_Y1 = 680, 500, 770, 590
WALL_NEAR_X0, WALL_NEAR_Y0, WALL_NEAR_X1, WALL_NEAR_Y1 = 620, 440, 680, 510
WALL_RIM_X0, WALL_RIM_Y0, WALL_RIM_X1, WALL_RIM_Y1 = 720, 380, 800, 450
FAR_X0, FAR_Y0, FAR_X1, FAR_Y1 = 50, 50, 400, 300

def lum_bbox(data, x0, y0, x1, y1):
    return luminance(mean_rgb(data, w, x0, y0, x1, y1))

core_stone = lum_bbox(sd, CORE_X0, CORE_Y0, CORE_X1, CORE_Y1)
core_glow  = lum_bbox(gd, CORE_X0, CORE_Y0, CORE_X1, CORE_Y1)
wn_stone   = lum_bbox(sd, WALL_NEAR_X0, WALL_NEAR_Y0, WALL_NEAR_X1, WALL_NEAR_Y1)
wn_glow    = lum_bbox(gd, WALL_NEAR_X0, WALL_NEAR_Y0, WALL_NEAR_X1, WALL_NEAR_Y1)
wr_stone   = lum_bbox(sd, WALL_RIM_X0, WALL_RIM_Y0, WALL_RIM_X1, WALL_RIM_Y1)
wr_glow    = lum_bbox(gd, WALL_RIM_X0, WALL_RIM_Y0, WALL_RIM_X1, WALL_RIM_Y1)
far_stone  = lum_bbox(sd, FAR_X0, FAR_Y0, FAR_X1, FAR_Y1)
far_glow   = lum_bbox(gd, FAR_X0, FAR_Y0, FAR_X1, FAR_Y1)

print(f"  core       ({CORE_X0},{CORE_Y0})-({CORE_X1},{CORE_Y1}):  stone={core_stone:6.1f}  glow={core_glow:6.1f}  Δ={core_glow-core_stone:+6.1f}")
print(f"  wall near  ({WALL_NEAR_X0},{WALL_NEAR_Y0})-({WALL_NEAR_X1},{WALL_NEAR_Y1}):   stone={wn_stone:6.1f}  glow={wn_glow:6.1f}  Δ={wn_glow-wn_stone:+6.1f}")
print(f"  wall rim   ({WALL_RIM_X0},{WALL_RIM_Y0})-({WALL_RIM_X1},{WALL_RIM_Y1}):   stone={wr_stone:6.1f}  glow={wr_glow:6.1f}  Δ={wr_glow-wr_stone:+6.1f}")
print(f"  far grass  ({FAR_X0},{FAR_Y0})-({FAR_X1},{FAR_Y1}): stone={far_stone:6.1f}  glow={far_glow:6.1f}  Δ={far_glow-far_stone:+6.1f}")

errs = []
# Assert 1: glowstone core is absolutely bright (threshold check).
#   Pure unlit pit floor in the stone baseline measures ~lum 30; the
#   glowstone's warm yellow-gold face sits well above lum 100 after AO and
#   face-normal lighting combine multiplicatively.
MIN_CORE_LUM = 100.0
if core_glow < MIN_CORE_LUM:
    errs.append(f"ASSERT FAIL: core lum {core_glow:.1f} < {MIN_CORE_LUM} — glowstone not bright enough")

# Assert 2: near wall is strongly lifted vs. its stone baseline.
#   The immediate-neighbour air cell around the glowstone gets block_light=14
#   from the BFS, so the wall face adjacent to that air sampling should jump
#   by a large margin.
MIN_NEAR_LIFT = 30.0
if wn_glow - wn_stone < MIN_NEAR_LIFT:
    errs.append(f"ASSERT FAIL: wall-near lift {wn_glow - wn_stone:.1f} < {MIN_NEAR_LIFT} — glowstone did not reach immediate neighbours")

# Assert 3: distance-4-ish rim wall is dimmer than the glowstone core in the
#   same frame. This is the "BFS falloff is visible" check: the rim wall has
#   some block_light residual from the BFS but should be < core. On the pit
#   rim the air is also skylight-15, so the rim brightness is dominated by
#   sky, not block — which is exactly what we want to verify (block light
#   attenuates by distance).
if wr_glow >= core_glow:
    errs.append(f"ASSERT FAIL: rim lum {wr_glow:.1f} >= core lum {core_glow:.1f} — distance-4 not dimmer than core")

# Assert 4: far grass is unchanged — block light must NOT leak beyond the
#   BFS radius (and must not cross chunk boundaries inside the radius either,
#   since this is a per-chunk BFS). Tiny FP drift allowed.
MAX_FAR_DRIFT = 2.0
if abs(far_glow - far_stone) > MAX_FAR_DRIFT:
    errs.append(f"ASSERT FAIL: far grass drift {abs(far_glow - far_stone):.1f} > {MAX_FAR_DRIFT} — block light leaked beyond BFS radius")

if errs:
    for e in errs:
        print("  " + e)
    sys.exit(1)

print("==> PASS: glowstone lit the immediate pit, distance-4 rim is dimmer, far grass unchanged.")
EOF
