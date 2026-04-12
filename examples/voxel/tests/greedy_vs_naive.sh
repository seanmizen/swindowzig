#!/usr/bin/env bash
# Greedy-vs-naive meshing regression runner.
#
# Captures the same flatland scene through both meshers and verifies the
# resulting frames are visually identical. Greedy merges coplanar faces into
# larger quads, but the per-vertex AO + skylight signature gate means every
# merged quad is a set of naive faces that would have had identical lighting
# anyway, so the rendered output should match within floating-point tolerance.
#
# Usage:
#   ./examples/voxel/tests/greedy_vs_naive.sh
#   ./examples/voxel/tests/greedy_vs_naive.sh --output-dir docs/assets
#   ./examples/voxel/tests/greedy_vs_naive.sh --skip-build
#
# Requires: zig, magick (ImageMagick 7), python3.
# Must be run from the swindowzig root (utils/swindowzig) or any subdirectory;
# the script resolves the root from its own location.
set -euo pipefail

OUTPUT_DIR="/tmp"
SKIP_BUILD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SWINDOWZIG_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TAS_PATH="$SCRIPT_DIR/greedy_vs_naive.tas"
BIN="$SWINDOWZIG_ROOT/zig-out/bin/voxel"

cd "$SWINDOWZIG_ROOT"

if [[ $SKIP_BUILD -eq 0 ]]; then
  echo "==> Building voxel..."
  zig build native -Dexample=voxel
fi

mkdir -p "$OUTPUT_DIR"

NAIVE_PPM="/tmp/greedy_vs_naive_naive.ppm"
GREEDY_PPM="/tmp/greedy_vs_naive_greedy.ppm"

echo "==> Capturing frame with --meshing=naive..."
"$BIN" --world=flatland --aa=none --meshing=naive \
  --tas "$TAS_PATH" --dump-frame="$NAIVE_PPM" >/dev/null

echo "==> Capturing frame with --meshing=greedy..."
"$BIN" --world=flatland --aa=none --meshing=greedy \
  --tas "$TAS_PATH" --dump-frame="$GREEDY_PPM" >/dev/null

echo "==> Writing reference PNGs to $OUTPUT_DIR..."
magick "$NAIVE_PPM"  "$OUTPUT_DIR/ref_greedy_vs_naive_naive.png"
magick "$GREEDY_PPM" "$OUTPUT_DIR/ref_greedy_vs_naive_greedy.png"

echo "==> Writing amplified x20 diff..."
magick "$NAIVE_PPM" "$GREEDY_PPM" -compose difference -composite -evaluate Multiply 20 \
  "$OUTPUT_DIR/diff_greedy_vs_naive_amp20.png"

# Threshold: we require the RMS delta to be below 2/255 — small enough that
# it can only come from numerical drift, not a visible pattern change.
RMS_MAX_CHAN=2

echo "==> Computing coverage + RMS stats:"
python3 - "$NAIVE_PPM" "$GREEDY_PPM" "$RMS_MAX_CHAN" <<'EOF'
import sys, math

def read_ppm(p):
    with open(p, 'rb') as f:
        assert f.readline().strip() == b'P6', f"not P6: {p}"
        line = f.readline()
        while line.startswith(b'#'):
            line = f.readline()
        w, h = [int(x) for x in line.split()]
        _ = int(f.readline().strip())  # maxval
        return w, h, f.read()

naive_ppm, greedy_ppm, rms_limit_s = sys.argv[1], sys.argv[2], sys.argv[3]
rms_limit = float(rms_limit_s)

w1, h1, d1 = read_ppm(naive_ppm)
w2, h2, d2 = read_ppm(greedy_ppm)
assert (w1, h1) == (w2, h2), f"size mismatch {w1}x{h1} vs {w2}x{h2}"

total = w1 * h1
differing = 0
max_delta = 0
sq_sum = 0  # sum of squared per-channel deltas (RGB flattened)
for i in range(0, len(d1), 3):
    dr = abs(d1[i]   - d2[i])
    dg = abs(d1[i+1] - d2[i+1])
    db = abs(d1[i+2] - d2[i+2])
    m = max(dr, dg, db)
    if m > 0:
        differing += 1
    if m > max_delta:
        max_delta = m
    sq_sum += dr*dr + dg*dg + db*db

rms = math.sqrt(sq_sum / (total * 3))
pct = 100.0 * differing / total

print(f"  naive:  {naive_ppm}")
print(f"  greedy: {greedy_ppm}")
print(f"  differing pixels: {differing}/{total} = {pct:.3f}%")
print(f"  max channel delta: {max_delta}/255")
print(f"  RMS (per channel): {rms:.4f}  (limit: {rms_limit}/255)")

if rms > rms_limit:
    print("FAIL — RMS above threshold; greedy mesher is not visually identical.")
    sys.exit(1)

print("PASS — greedy matches naive within tolerance.")
EOF

echo "==> Done. Outputs in $OUTPUT_DIR"
