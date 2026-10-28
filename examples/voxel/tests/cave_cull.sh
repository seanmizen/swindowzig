#!/usr/bin/env bash
# Cave cull benchmark (REQ-VOXEL-020).
#
# For each TAS, the script captures one frame with --cave-cull=on and one
# frame with --cave-cull=off. The two frames must have the same bytes. The
# script shows the chunks that each run draws, and the chunks that the cave
# cull removes.
#
# Usage (from the repo root):
#   ./examples/voxel/tests/cave_cull.sh
#   ./examples/voxel/tests/cave_cull.sh --skip-build
#
# Requires: zig, cmp
set -euo pipefail

SKIP_BUILD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) SKIP_BUILD=1; shift ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BIN="$ROOT/zig-out/bin/voxel"
OUT="$(mktemp -d)"
cd "$ROOT"

if [[ $SKIP_BUILD -eq 0 ]]; then
  echo "==> Building voxel..."
  zig build native -Dexample=voxel
fi

# name|tas|args
RUNS=(
  "surface|$SCRIPT_DIR/flatland_forward.tas|--world=flatland"
  "shaft|$SCRIPT_DIR/cave_skylight.tas|--world=flatland"
  "dig|$SCRIPT_DIR/dig_relight.tas|--world=flatland"
  "terrain|$SCRIPT_DIR/frustum_look_down.tas|"
)

FAIL=0
printf "%-10s %-6s %-12s %-12s %s\n" "RUN" "FRAME" "DRAWN(on)" "DRAWN(off)" "CAVE_CULLED"
for entry in "${RUNS[@]}"; do
  IFS='|' read -r name tas args <<< "$entry"
  for mode in on off; do
    # shellcheck disable=SC2086
    timeout 200 "$BIN" --headless --debug=off --aa=none --cave-cull=$mode \
      --tas "$tas" --dump-frame="$OUT/$name.$mode.ppm" $args > "$OUT/$name.$mode.log" 2>&1
  done
  line_on=$(grep "cave_culled=" "$OUT/$name.on.log" | tail -1)
  line_off=$(grep "cave_culled=" "$OUT/$name.off.log" | tail -1)
  drawn_on=$(sed -E 's/.*drawn=([0-9]+).*/\1/' <<< "$line_on")
  drawn_off=$(sed -E 's/.*drawn=([0-9]+).*/\1/' <<< "$line_off")
  culled=$(sed -E 's/.*cave_culled=([0-9]+).*/\1/' <<< "$line_on")
  if cmp -s "$OUT/$name.on.ppm" "$OUT/$name.off.ppm"; then frame=same; else frame=DIFF; FAIL=1; fi
  printf "%-10s %-6s %-12s %-12s %s\n" "$name" "$frame" "$drawn_on" "$drawn_off" "$culled"
done

if [[ $FAIL -ne 0 ]]; then
  echo "FAIL: the cave cull changed a frame. The frames are in $OUT" >&2
  exit 1
fi
rm -rf "$OUT"
echo "PASS: the cave cull did not change a frame"
