#!/usr/bin/env bash
# Cave cull, section cull and occlusion cull benchmark (REQ-VOXEL-020,
# REQ-VOXEL-024, REQ-VOXEL-025).
#
# For each TAS, the script captures three frames:
#   off   --cave-cull=off --occlusion=off: the frustum cull only.
#   cave  --cave-cull=on  --occlusion=off: the walk culls chunks and sections.
#   all   --cave-cull=on  --occlusion=on:  the default, with the box tests.
# The three frames must have the same bytes. The script shows the chunks
# that each run draws, and the chunks and sections that each cull removes.
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
  "hills|$ROOT/examples/voxel/framespike.tas|"
)

# mode|flags
MODES=(
  "off|--cave-cull=off --occlusion=off"
  "cave|--cave-cull=on --occlusion=off"
  "all|--cave-cull=on --occlusion=on"
)

field() { sed -E "s/.* $1=([0-9]+).*/\\1/" <<< "$2"; }

FAIL=0
printf "%-8s %-6s %-6s %-6s %-6s %-6s %-9s %s\n" "RUN" "FRAME" "DRAWN" "CAVE" "ALL" "CAVE_C" "SECTION_C" "OCCLUSION_C"
for entry in "${RUNS[@]}"; do
  IFS='|' read -r name tas args <<< "$entry"
  for m in "${MODES[@]}"; do
    IFS='|' read -r mode flags <<< "$m"
    # shellcheck disable=SC2086
    timeout 200 "$BIN" --headless --debug=off --aa=none $flags \
      --tas "$tas" --dump-frame="$OUT/$name.$mode.ppm" $args > "$OUT/$name.$mode.log" 2>&1
  done
  frame=same
  for mode in cave all; do
    cmp -s "$OUT/$name.off.ppm" "$OUT/$name.$mode.ppm" || { frame=DIFF; FAIL=1; }
  done
  line_off=$(grep "cave_culled=" "$OUT/$name.off.log" | tail -1)
  line_cave=$(grep "cave_culled=" "$OUT/$name.cave.log" | tail -1)
  line_all=$(grep "cave_culled=" "$OUT/$name.all.log" | tail -1)
  printf "%-8s %-6s %-6s %-6s %-6s %-6s %-9s %s\n" "$name" "$frame" \
    "$(field drawn "$line_off")" "$(field drawn "$line_cave")" "$(field drawn "$line_all")" \
    "$(field cave_culled "$line_all")" "$(field sections_culled "$line_all")" "$(field occlusion_culled "$line_all")"
done

if [[ $FAIL -ne 0 ]]; then
  echo "FAIL: a cull changed a frame. The frames are in $OUT" >&2
  exit 1
fi
rm -rf "$OUT"
echo "PASS: the culls did not change a frame"
