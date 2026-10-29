#!/usr/bin/env bash
# seed_web_native.sh: the seed of the page URL gives the terrain of the
# native --seed flag (REQ-VOXEL-034).
#
# Procedure: native voxel runs headless with --print-world-hash. When the
# scheduler is idle after the loading screen, it prints the hash of the
# desired state around the player (the blocks, the light hashes and the mesh
# hashes). The Bun runner (backends/wasm/headless.ts --world-hash) prints
# the same hash for app.wasm. It reads the seed of a URL query with the
# function of the loader (backends/wasm/seed.ts). The chunk workers make
# the light and the meshes, so a worker with another seed gives another
# hash. The script compares:
#   1. native --seed=12345 and ?seed=12345 (the worker pool)
#   2. native --seed=12345 and ?seed=12345 with no pool (--workers 0)
#   3. native with no flag and no query (seed 0)
#   4. native with no flag and ?seed=abc. The run must log one warning.
#
# Baseline (2026-10-28): seed 12345 gives 07a06bf5509eedac on native and
# in app.wasm. Each run takes about 30 s with the debug build.
#
# Usage (from the repo root):
#   zig build native -Dexample=voxel
#   zig build web -Dexample=voxel
#   ./examples/voxel/tests/seed_web_native.sh
set -euo pipefail

cd "$(dirname "$0")/../../.."  # the repo root

VOXEL=./zig-out/bin/voxel
APP=zig-out/bin/app.wasm
for f in "$VOXEL" "$APP" zig-out/bin/chunks.wasm; do
    if [[ ! -e "$f" ]]; then
        echo "$f missing. Run: zig build native -Dexample=voxel && zig build web -Dexample=voxel"
        exit 1
    fi
done

TMP="$(mktemp -d -t voxel-seed.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

hash_of() {
    grep -o 'world_hash=[0-9a-f]*' "$1" | head -n 1 | cut -d= -f2
}

native() {
    local name="$1"; shift
    timeout 300 "$VOXEL" --headless --print-world-hash "$@" >"$TMP/$name.log" 2>&1 || true
    local h
    h="$(hash_of "$TMP/$name.log")"
    if [[ -z "$h" ]]; then
        echo "FAIL native $name: no world_hash line" >&2
        tail -n 20 "$TMP/$name.log" >&2
        exit 1
    fi
    echo "$h"
}

web() {
    local name="$1"; shift
    timeout 300 bun backends/wasm/headless.ts --wasm "$APP" --world-hash "$@" >"$TMP/$name.log" 2>&1 || true
    local h
    h="$(hash_of "$TMP/$name.log")"
    if [[ -z "$h" ]]; then
        echo "FAIL web $name: no world_hash line" >&2
        tail -n 20 "$TMP/$name.log" >&2
        exit 1
    fi
    echo "$h"
}

status=0
same() {
    if [[ "$2" == "$3" ]]; then
        echo "PASS $1: $2"
    else
        echo "FAIL $1: native $2, web $3"
        status=1
    fi
}

n12345="$(native seed12345 --seed=12345)"
n0="$(native seed0)"
same "seed 12345, worker pool" "$n12345" "$(web pool12345 --query '?seed=12345')"
same "seed 12345, no pool" "$n12345" "$(web inline12345 --query '?seed=12345' --workers 0)"
same "no seed" "$n0" "$(web none)"
same "invalid seed" "$n0" "$(web invalid --query '?seed=abc')"

warnings="$(grep -c "is not a u64" "$TMP/invalid.log" || true)"
if [[ "$warnings" == "1" ]]; then
    echo "PASS invalid seed: one warning"
else
    echo "FAIL invalid seed: $warnings warnings, expected 1"
    status=1
fi
if [[ "$n12345" == "$n0" ]]; then
    echo "FAIL seed 12345 and seed 0 give the same hash"
    status=1
fi
exit $status
