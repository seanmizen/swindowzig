#!/usr/bin/env bash
# chunk_ao_teleport.sh — Build, teleport, capture, and report.
#
# Captures a PPM frame at (150, 80, 150) for chunk-shadow AO analysis.
# Pass --skip-build to reuse an existing binary.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/../../.."
BIN="$ROOT/zig-out/bin/voxel"
TAS="$SCRIPT_DIR/chunk_ao_teleport.tas"
OUT="${1:-/tmp/ao_teleport.ppm}"

if [[ "${1:-}" != "--skip-build" ]]; then
    echo "=== Building voxel (ReleaseFast) ==="
    (cd "$ROOT" && zig build native -Dexample=voxel -Doptimize=ReleaseFast)
fi

echo "=== Running TAS: teleport to (150, 80, 150) ==="
"$BIN" --headless \
    --tas "$TAS" \
    --dump-frame="$OUT" \
    2>&1 | grep -E '\[CMD\]|\[ASYNC\]|\[AO-REMESH\]|\[EVICT\]|\[CHUNK_STATS\]|dump-frame' || true

echo ""
echo "=== Frame captured: $OUT ==="
if command -v file &>/dev/null; then
    file "$OUT"
fi
echo "Open with: open $OUT  (macOS) or display $OUT (ImageMagick)"
