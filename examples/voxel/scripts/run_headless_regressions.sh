#!/usr/bin/env bash
# run_headless_regressions.sh — CI-ready headless voxel regression runner
#
# Runs every enumerated TAS regression under `--headless --dump-frame` and
# diffs the result against a backend-specific golden PPM under
# examples/voxel/assets/goldens/<backend>/. Backend is detected from `uname`:
# Darwin → metal, Linux → lavapipe (the wgpu-native backend picks matches the
# host automatically; the label is for golden selection only).
#
# Usage (from utils/swindowzig):
#   ./examples/voxel/scripts/run_headless_regressions.sh           # compare mode
#   ./examples/voxel/scripts/run_headless_regressions.sh --update  # regenerate goldens for this backend
#
# Exit codes:
#   0 — all runs passed (or updated)
#   1 — one or more runs failed the diff (or crashed)
#   2 — missing golden(s) and not in --update mode, OR unsupported OS
#
# Tolerances for the pixel diff are baked into the per-run entries in the
# RUNS table below. Tighten/loosen individual tests there, not in voxel's
# --compare-golden flag defaults.

set -euo pipefail

# Resolve swindowzig root regardless of where the script is invoked from.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
cd "$ROOT"

case "$(uname -s)" in
    Darwin) BACKEND=metal ;;
    Linux)  BACKEND=lavapipe ;;
    *)
        echo "run_headless_regressions.sh: unsupported OS $(uname -s)"
        exit 2
        ;;
esac

BIN="./zig-out/bin/voxel"
GOLDENS_DIR="examples/voxel/assets/goldens/${BACKEND}"
TMP_DIR="$(mktemp -d -t voxel-headless-regression.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Goldens are stored as gzipped PPMs (.ppm.gz) to keep the repo under control
# — a full 1280×720 BGRA P6 is ~2.6 MB uncompressed, ~200 KB gzipped. voxel's
# --compare-golden only reads plain PPMs, so compare mode decompresses each
# golden into the temp dir once per run; update mode writes a plain PPM then
# gzips it into the goldens dir.

UPDATE=0
if [[ "${1:-}" == "--update" ]]; then
    UPDATE=1
    mkdir -p "$GOLDENS_DIR"
fi

if [[ ! -x "$BIN" ]]; then
    echo "[build] $BIN missing — running zig build native -Dexample=voxel"
    zig build native -Dexample=voxel
fi

# Regression table. Each row:
#   NAME | TAS_PATH | EXTRA_ARGS | MAX_DIFF_PCT | MAX_CHANNEL_DELTA
#
# NAME is used for both the captured PPM filename and the golden filename.
# EXTRA_ARGS is a single unquoted string (split on whitespace by the shell);
# keep values simple (no quoted spaces).
#
# Tolerances:
#   MAX_DIFF_PCT — percentage of pixels allowed to differ beyond MAX_CHANNEL_DELTA.
#   MAX_CHANNEL_DELTA — per-channel absolute delta below which a pixel is "equal".
# Both are forwarded to voxel's --golden-* flags.
declare -a RUNS=(
    "framespike|examples/voxel/framespike.tas|--aa=none|0.1|2"
    "msaa_flatland_none|examples/voxel/tests/msaa_flatland.tas|--aa=none --world=flatland|0.1|2"
    "msaa_flatland_fxaa|examples/voxel/tests/msaa_flatland.tas|--aa=fxaa --world=flatland|0.1|2"
    "msaa_flatland_msaa4|examples/voxel/tests/msaa_flatland.tas|--aa=msaa --msaa=4 --world=flatland|0.1|2"
    "ao_corners_none|examples/voxel/tests/ao_corners.tas|--aa=none --ao=none --world=flatland|0.1|2"
    "ao_corners_classic|examples/voxel/tests/ao_corners.tas|--aa=none --ao=classic --world=flatland|0.1|2"
    "ao_corners_moore|examples/voxel/tests/ao_corners.tas|--aa=none --ao=moore --world=flatland|0.1|2"
    "cave_skylight_none|examples/voxel/tests/cave_skylight.tas|--aa=none --lighting=none --world=flatland|0.1|2"
    "cave_skylight_skylight|examples/voxel/tests/cave_skylight.tas|--aa=none --lighting=skylight --world=flatland|0.1|2"
    "dig_relight|examples/voxel/tests/dig_relight.tas|--aa=none --world=flatland|0.1|2"
    # depth-stencil regression: capture the same scene under both on/off modes.
    # The goldens are captured with depth-stencil=on (the default); the off run
    # compares against a separate golden so any visual difference is explicit.
    "depth_stencil_on|examples/voxel/tests/depth_stencil_regression.tas|--aa=none --depth-stencil=on --world=flatland|0.1|2"
    "depth_stencil_off|examples/voxel/tests/depth_stencil_regression.tas|--aa=none --depth-stencil=off --world=flatland|2.0|4"
)

PASS=0; FAIL=0; MISS=0

# Pretty-print header
printf "\n== headless voxel regressions — backend: %s ==\n\n" "$BACKEND"
printf "%-28s %-9s %s\n" "TEST" "STATUS" "NOTES"
printf "%-28s %-9s %s\n" "----" "------" "-----"

for entry in "${RUNS[@]}"; do
    IFS='|' read -r name tas_path args max_diff_pct max_channel_delta <<< "$entry"
    out_ppm="${TMP_DIR}/${name}.ppm"
    out_log="${TMP_DIR}/${name}.log"
    golden_gz="${GOLDENS_DIR}/${name}.ppm.gz"
    golden_plain="${TMP_DIR}/${name}.golden.ppm"

    if [[ $UPDATE -eq 1 ]]; then
        # Regenerate the golden for this backend.
        # shellcheck disable=SC2086
        if ! "$BIN" --headless --tas "$tas_path" --dump-frame="$out_ppm" $args > "$out_log" 2>&1; then
            printf "%-28s %-9s %s\n" "$name" "ERROR" "capture crashed — see $out_log"
            FAIL=$((FAIL + 1))
            continue
        fi
        gzip -c "$out_ppm" > "$golden_gz"
        printf "%-28s %-9s %s\n" "$name" "UPDATED" "$golden_gz"
        PASS=$((PASS + 1))
        continue
    fi

    if [[ ! -f "$golden_gz" ]]; then
        printf "%-28s %-9s %s\n" "$name" "MISSING" "no golden at $golden_gz"
        MISS=$((MISS + 1))
        continue
    fi

    # Decompress golden → tmp dir, then hand the plain path to voxel.
    if ! gunzip -c "$golden_gz" > "$golden_plain"; then
        printf "%-28s %-9s %s\n" "$name" "ERROR" "gunzip failed for $golden_gz"
        FAIL=$((FAIL + 1))
        continue
    fi

    # Compare mode.
    set +e
    # shellcheck disable=SC2086
    "$BIN" --headless \
        --tas "$tas_path" \
        --dump-frame="$out_ppm" \
        --compare-golden="$golden_plain" \
        --golden-max-diff-pct="$max_diff_pct" \
        --golden-max-channel-delta="$max_channel_delta" \
        $args > "$out_log" 2>&1
    rc=$?
    set -e

    case $rc in
        0)
            printf "%-28s %-9s %s\n" "$name" "PASS" ""
            PASS=$((PASS + 1))
            ;;
        1)
            stats=$(grep -E "differing px|max Δ|mean Δ" "$out_log" | tr '\n' ' ' | sed 's/  */ /g')
            printf "%-28s %-9s %s\n" "$name" "FAIL" "$stats"
            FAIL=$((FAIL + 1))
            ;;
        *)
            printf "%-28s %-9s %s\n" "$name" "ERROR" "voxel exited $rc — see $out_log"
            FAIL=$((FAIL + 1))
            ;;
    esac
done

echo
echo "Summary: ${PASS} passed, ${FAIL} failed, ${MISS} missing (backend=${BACKEND})"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
if [[ $MISS -gt 0 && $UPDATE -eq 0 ]]; then
    echo
    echo "HINT: regenerate missing goldens with:"
    echo "  $0 --update"
    exit 2
fi
exit 0
