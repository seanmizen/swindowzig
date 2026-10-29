#!/usr/bin/env bash
# save_reload.sh: the edits of the voxel demo stay after a restart
# (REQ-VOXEL-035).
#
# Procedure, all runs headless on the flatland world, with a temp save
# folder (--save-dir):
#   1. --save=on, the TAS tests/dig_relight.tas (4 digs). At the end of
#      the TAS, the demo writes the edit log. The log must say "wrote 4".
#   2. --save=on --print-world-hash: the demo loads the 4 edits ("4 saved
#      edits") and prints the world hash.
#   3. --save=off --print-world-hash: no edits. The hash must not be the
#      hash of run 2, because the dug blocks are in the hash.
#   4. --save=on --print-world-hash again: the hash of run 2.
#   5. A TAS with no --save flag: save is off, and the folder does not
#      change.
#   6. Corrupt saved data: --save=on gives one warning, no edits, and the
#      hash of run 3.
#   7. The TAS tests/new_world.tas digs, then selects Settings > New World.
#      The save file goes. The next run has the hash of run 3.
#   Each debug run must log no leak.
#
# Usage (from the repo root):
#   zig build native -Dexample=voxel
#   ./examples/voxel/tests/save_reload.sh
set -euo pipefail

cd "$(dirname "$0")/../../.."  # the repo root

VOXEL=./zig-out/bin/voxel
if [[ ! -x "$VOXEL" ]]; then
    echo "voxel binary missing. Run: zig build native -Dexample=voxel"
    exit 1
fi

TMP="$(mktemp -d -t voxel-save.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
SAVE="$TMP/save"
KEYFILE="$SAVE/voxel-edits-flatland-0.sav"
TAS=examples/voxel/tests/dig_relight.tas

status=0
fail() {
    echo "FAIL $1"
    status=1
}

run() {
    local name="$1"; shift
    timeout 300 "$VOXEL" --headless --world=flatland --save-dir="$SAVE" "$@" >"$TMP/$name.log" 2>&1 || {
        echo "run $name exited with an error" >&2
        tail -n 20 "$TMP/$name.log" >&2
        exit 1
    }
}

hash_of() {
    grep -o 'world_hash=[0-9a-f]*' "$TMP/$1.log" | head -n 1 | cut -d= -f2
}

run dig --save=on --tas "$TAS"
if grep -q "\[SAVE\] wrote 4 edits" "$TMP/dig.log" && [[ -s "$KEYFILE" ]]; then
    echo "PASS the TAS run wrote 4 edits"
else
    fail "the TAS run did not write 4 edits"
fi

run load --save=on --print-world-hash
grep -q "\[SAVE\] on: 4 saved edits" "$TMP/load.log" && echo "PASS the second run read 4 edits" || fail "the second run did not read 4 edits"
h_load="$(hash_of load)"

run fresh --save=off --print-world-hash
h_fresh="$(hash_of fresh)"
if [[ -n "$h_load" && -n "$h_fresh" && "$h_load" != "$h_fresh" ]]; then
    echo "PASS the saved edits change the world ($h_load, fresh $h_fresh)"
else
    fail "the world with the saved edits has hash '$h_load', fresh '$h_fresh'"
fi

run again --save=on --print-world-hash
[[ "$(hash_of again)" == "$h_load" ]] && echo "PASS a third run gives the same world" || fail "a third run gives another world"

before="$(sha256sum "$KEYFILE")"
run tas_default --tas "$TAS"
grep -q "\[SAVE\] off" "$TMP/tas_default.log" && [[ "$(sha256sum "$KEYFILE")" == "$before" ]] \
    && echo "PASS a TAS run with no --save flag does not save" || fail "a TAS run with no --save flag saved"

printf 'SWZE\001garbage' >"$KEYFILE"
run corrupt --save=on --print-world-hash
warnings="$(grep -c "\[SAVE\].*cannot be read" "$TMP/corrupt.log" || true)"
if [[ "$warnings" == "1" && "$(hash_of corrupt)" == "$h_fresh" ]]; then
    echo "PASS corrupt data gives one warning and no edits"
else
    fail "corrupt data: $warnings warnings, hash $(hash_of corrupt)"
fi

run dig2 --save=on --tas "$TAS"
run new_world --save=on --tas examples/voxel/tests/new_world.tas
run after_new --save=on --print-world-hash
if grep -q "\[SAVE\] new world" "$TMP/new_world.log" && [[ ! -e "$KEYFILE" ]] && [[ "$(hash_of after_new)" == "$h_fresh" ]]; then
    echo "PASS New World deletes the saved edits"
else
    fail "New World: the save file or the world did not reset"
fi

if grep -l "leaked" "$TMP"/*.log; then
    fail "a run leaked memory"
fi
exit $status
