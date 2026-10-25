#!/usr/bin/env bash
# Depth-stencil on/off regression runner for the voxel demo.
#
# Captures the same deterministic scene under two depth-stencil strategies:
#   - depth_on:  --depth-stencil=on  (hardware depth test, the default)
#   - depth_off: --depth-stencil=off (painter's-algorithm sort only, no depth texture)
#
# Asserts that:
#   1. Both frames render without crashing.
#   2. The frames are visually close on flat open terrain — the painter's sort
#      produces stable depth order from this viewpoint so < 2% of pixels should
#      differ beyond a small tolerance.
#   3. Mean brightness of the sky region is roughly equal in both frames,
#      confirming the depth test does not perceptibly change lit geometry.
#
# Usage (from utils/swindowzig):
#   ./examples/voxel/tests/depth_stencil_regression.sh
#   ./examples/voxel/tests/depth_stencil_regression.sh --skip-build
#
# Requires: zig, python3
# Must be run from the swindowzig root (utils/swindowzig) or any subdirectory;
# the script resolves the root from its own location.
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
TAS_PATH="$SCRIPT_DIR/depth_stencil_regression.tas"
BIN="$SWINDOWZIG_ROOT/zig-out/bin/voxel"

cd "$SWINDOWZIG_ROOT"

if [[ $SKIP_BUILD -eq 0 ]]; then
  echo "==> Building voxel..."
  zig build native -Dexample=voxel
fi

DS_ON_PPM=/tmp/depth_stencil_on.ppm
DS_OFF_PPM=/tmp/depth_stencil_off.ppm

echo "==> Capturing frame with --depth-stencil=on (hardware depth test)..."
"$BIN" --world=flatland --aa=none --depth-stencil=on \
  --tas "$TAS_PATH" --dump-frame="$DS_ON_PPM" >/dev/null

echo "==> Capturing frame with --depth-stencil=off (painter's sort only)..."
"$BIN" --world=flatland --aa=none --depth-stencil=off \
  --tas "$TAS_PATH" --dump-frame="$DS_OFF_PPM" >/dev/null

# Threshold: on open flatland the painter's sort is stable and the two modes
# should produce near-identical frames. Allow up to 2% pixel difference
# (handles minor floating-point sort variations at depth-equal surfaces).
MAX_DIFF_PCT=2.0
# Brightness tolerance for the sky-region check (luminance 0-255 scale).
MAX_SKY_DELTA=5.0

echo "==> Checking visual regression..."
python3 - "$DS_ON_PPM" "$DS_OFF_PPM" "$MAX_DIFF_PCT" "$MAX_SKY_DELTA" <<'EOF'
import sys

def read_ppm(p):
    with open(p, 'rb') as f:
        assert f.readline().strip() == b'P6', f"not P6: {p}"
        line = f.readline()
        while line.startswith(b'#'):
            line = f.readline()
        w, h = [int(x) for x in line.split()]
        _ = int(f.readline().strip())  # maxval
        return w, h, f.read()

def mean_lum_bbox(data, w, x0, y0, x1, y1):
    total = 0.0
    n = 0
    for y in range(y0, y1):
        row = y * w * 3
        for x in range(x0, x1):
            i = row + x * 3
            r, g, b = data[i], data[i+1], data[i+2]
            total += 0.2126 * r + 0.7152 * g + 0.0722 * b
            n += 1
    return total / n if n > 0 else 0.0

ds_on_ppm, ds_off_ppm, max_diff_pct_s, max_sky_delta_s = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
max_diff_pct = float(max_diff_pct_s)
max_sky_delta = float(max_sky_delta_s)

w1, h1, d1 = read_ppm(ds_on_ppm)
w2, h2, d2 = read_ppm(ds_off_ppm)
assert (w1, h1) == (w2, h2), f"frame size mismatch: {(w1,h1)} vs {(w2,h2)}"
w, h = w1, h1

total = w * h
differing = 0
max_delta = 0
for i in range(0, len(d1), 3):
    m = max(abs(d1[i] - d2[i]), abs(d1[i+1] - d2[i+1]), abs(d1[i+2] - d2[i+2]))
    if m > 0:
        differing += 1
    if m > max_delta:
        max_delta = m

diff_pct = 100.0 * differing / total

# Sky region: top quarter of the frame — should be sky-blue in both modes.
sky_lum_on  = mean_lum_bbox(d1, w, 0, 0, w, h // 4)
sky_lum_off = mean_lum_bbox(d2, w, 0, 0, w, h // 4)
sky_delta = abs(sky_lum_on - sky_lum_off)

print(f"  depth_on:  {ds_on_ppm}")
print(f"  depth_off: {ds_off_ppm}")
print(f"  differing pixels: {differing}/{total} = {diff_pct:.2f}%  (limit: {max_diff_pct:.1f}%)")
print(f"  max channel delta: {max_delta}/255")
print(f"  sky luminance: on={sky_lum_on:.1f}  off={sky_lum_off:.1f}  delta={sky_delta:.1f}  (limit: {max_sky_delta:.1f})")

errs = []

if diff_pct > max_diff_pct:
    errs.append(
        f"ASSERT FAIL: pixel diff {diff_pct:.2f}% > {max_diff_pct:.1f}% — "
        "depth-stencil mode change caused unexpected visual difference"
    )

if sky_delta > max_sky_delta:
    errs.append(
        f"ASSERT FAIL: sky luminance delta {sky_delta:.1f} > {max_sky_delta:.1f} — "
        "depth-stencil mode change altered sky brightness"
    )

if errs:
    for e in errs:
        print("  " + e)
    sys.exit(1)

print("==> PASS: depth-stencil on/off produces visually equivalent output on flatland.")
EOF
