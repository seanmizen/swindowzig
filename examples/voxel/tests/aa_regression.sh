#!/usr/bin/env bash
# AA regression runner for the voxel demo.
#
# Builds voxel, captures three deterministic frames (none / fxaa / msaa4) from
# the flatland TAS, produces both normalized and amplified diffs, and prints
# pixel-coverage stats. Prints results only — does NOT gate on thresholds yet
# (see README.md TODO: resolve headless GPU path before making this mandatory).
#
# Usage:
#   ./examples/voxel/tests/aa_regression.sh
#   ./examples/voxel/tests/aa_regression.sh --output-dir docs/assets   # refresh embedded PNGs
#   ./examples/voxel/tests/aa_regression.sh --skip-build               # reuse existing binary
#
# Requires: zig, magick (ImageMagick 7), python3
# Must be run from the swindowzig root (utils/swindowzig).
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
TAS_PATH="$SCRIPT_DIR/msaa_flatland.tas"
BIN="$SWINDOWZIG_ROOT/zig-out/bin/voxel"

cd "$SWINDOWZIG_ROOT"

if [[ $SKIP_BUILD -eq 0 ]]; then
  echo "==> Building voxel..."
  zig build native -Dexample=voxel
fi

mkdir -p "$OUTPUT_DIR"

echo "==> Capturing frames (/tmp/aa_{none,fxaa,msaa}.ppm)..."
"$BIN" --world=flatland --aa=none             --tas "$TAS_PATH" --dump-frame=/tmp/aa_none.ppm >/dev/null
"$BIN" --world=flatland --aa=fxaa             --tas "$TAS_PATH" --dump-frame=/tmp/aa_fxaa.ppm >/dev/null
"$BIN" --world=flatland --aa=msaa  --msaa=4   --tas "$TAS_PATH" --dump-frame=/tmp/aa_msaa.ppm >/dev/null

echo "==> Writing reference PNGs to $OUTPUT_DIR..."
magick /tmp/aa_none.ppm "$OUTPUT_DIR/ref_none.png"
magick /tmp/aa_fxaa.ppm "$OUTPUT_DIR/ref_fxaa.png"
magick /tmp/aa_msaa.ppm "$OUTPUT_DIR/ref_msaa.png"

echo "==> Writing normalized diffs (brightest delta -> white)..."
magick /tmp/aa_none.ppm /tmp/aa_fxaa.ppm -compose difference -composite -normalize "$OUTPUT_DIR/diff_fxaa_norm.png"
magick /tmp/aa_none.ppm /tmp/aa_msaa.ppm -compose difference -composite -normalize "$OUTPUT_DIR/diff_msaa_norm.png"

echo "==> Writing amplified x20 diffs (relative magnitudes preserved)..."
magick /tmp/aa_none.ppm /tmp/aa_fxaa.ppm -compose difference -composite -evaluate Multiply 20 "$OUTPUT_DIR/diff_fxaa_amp20.png"
magick /tmp/aa_none.ppm /tmp/aa_msaa.ppm -compose difference -composite -evaluate Multiply 20 "$OUTPUT_DIR/diff_msaa_amp20.png"

echo "==> Coverage stats:"
python3 - <<'EOF'
def read_ppm(p):
    with open(p, 'rb') as f:
        assert f.readline().strip() == b'P6', f"not P6: {p}"
        line = f.readline()
        while line.startswith(b'#'):
            line = f.readline()
        w, h = [int(x) for x in line.split()]
        maxval = int(f.readline().strip())
        return w, h, f.read()

def stats(ref, other):
    w1, h1, d1 = read_ppm(ref)
    w2, h2, d2 = read_ppm(other)
    assert (w1, h1) == (w2, h2)
    total = w1 * h1
    differing = 0
    max_delta = 0
    for i in range(0, len(d1), 3):
        m = max(abs(d1[i] - d2[i]), abs(d1[i+1] - d2[i+1]), abs(d1[i+2] - d2[i+2]))
        if m > 0:
            differing += 1
        if m > max_delta:
            max_delta = m
    return total, differing, max_delta

for label, path in (('fxaa', '/tmp/aa_fxaa.ppm'), ('msaa4', '/tmp/aa_msaa.ppm')):
    total, diff, md = stats('/tmp/aa_none.ppm', path)
    pct = 100.0 * diff / total
    print(f"  {label:6s}: {diff:>7} / {total} differing pixels = {pct:5.2f}%   max channel delta = {md}")
EOF

echo "==> Done. Outputs in $OUTPUT_DIR"
