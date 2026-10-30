#!/usr/bin/env bash
# tas_parse_fail.sh: a TAS script that does not parse stops voxel with no
# memory leak (REQ-VOXEL-033).
#
# Procedure: write a TAS script with an unknown command to a temp file.
# Run voxel headless with it, two times: with no other flags, and with the
# path flags that init copies (--dump-frame, --compare-golden,
# --profile-csv). Each run must exit with a non-zero code and must log no
# "leaked" line. A debug build of voxel gives its allocations to the
# DebugAllocator of sw_app, and the DebugAllocator logs each leak when the
# app exits. A release build has no leak check, so the script needs the
# debug build (`zig build native -Dexample=voxel`, the default mode).
#
# Baseline: before the init errdefers, the run logged 2 leaks (the in-flight
# array and the worker array of the chunk worker pool).
#
# Usage (from the repo root):
#   zig build native -Dexample=voxel
#   ./examples/voxel/tests/tas_parse_fail.sh
set -euo pipefail

cd "$(dirname "$0")/../../.."  # the repo root

VOXEL=./zig-out/bin/voxel
if [[ ! -x "$VOXEL" ]]; then
    echo "voxel binary missing. Run: zig build native -Dexample=voxel"
    exit 1
fi

TMP="$(mktemp -d -t voxel-tas-parse-fail.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
TAS="$TMP/bad.tas"
printf '1 wait 1\n2 no_such_command\n' > "$TAS"

status=0
run() {
    local name="$1"; shift
    local log="$TMP/$name.log"
    set +e
    timeout 120 "$VOXEL" --headless --world=flatland --tas "$TAS" "$@" >"$log" 2>&1
    local rc=$?
    set -e
    local leaks
    leaks=$(grep -c "leaked" "$log" || true)
    if ! grep -q "Failed to parse TAS script" "$log"; then
        echo "FAIL $name: voxel did not report the parse error (exit $rc)"
        tail -n 20 "$log"
        status=1
    elif [[ $rc -eq 0 ]]; then
        echo "FAIL $name: voxel exited 0 after a parse error"
        status=1
    elif [[ $rc -eq 124 ]]; then
        echo "FAIL $name: voxel did not stop in 120 s"
        status=1
    elif [[ $leaks -ne 0 ]]; then
        echo "FAIL $name: $leaks leak reports"
        grep -A4 "leaked" "$log" | head -n 40
        status=1
    else
        echo "PASS $name: exit $rc, no leak report"
    fi
}

run plain
run path_flags --dump-frame="$TMP/frame.ppm" --compare-golden="$TMP/golden.ppm" \
    --profile-csv="$TMP/profile.csv"

if [[ $status -eq 0 ]]; then
    echo "PASS: a TAS parse error stops voxel with no memory leak"
fi
exit $status
