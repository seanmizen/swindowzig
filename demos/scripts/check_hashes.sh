#!/usr/bin/env bash
# check_hashes.sh: replay the TAS script of each demo and compare the frame
# hashes (REQ-DEMO-001).
#
# Each demo plays its TAS script two times for each preset, with no window.
# The two runs must give the same hash at each checkpoint. On Linux with
# lavapipe (the CI runner), the hashes must also equal the golden file
# demos/<demo>/hashes/lavapipe-<preset>.txt. A GPU gives other pixels for
# each adapter, so there are no goldens for other GPUs.
#
# Usage (from the repo root):
#   demos/scripts/check_hashes.sh                # compare
#   demos/scripts/check_hashes.sh --update       # write the lavapipe goldens
#   demos/scripts/check_hashes.sh --out DIR      # keep the hash files in DIR
#
# Exit codes: 0 pass, 1 a difference, 2 a missing golden or a bad option.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

UPDATE=0
OUT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --update) UPDATE=1; shift ;;
        --out) OUT="$2"; shift 2 ;;
        *) echo "check_hashes.sh: unknown option: $1" >&2; exit 2 ;;
    esac
done
if [[ -z "$OUT" ]]; then
    OUT="$(mktemp -d -t demo-hashes.XXXXXX)"
    trap 'rm -rf "$OUT"' EXIT
fi
mkdir -p "$OUT"

GOLDEN=0
if [[ "$(uname -s)" == Linux && "${VK_LOADER_DRIVERS_SELECT:-}" == *lvp* ]]; then
    GOLDEN=1
fi

status=0
for demo in cow shooter menu; do
    echo "[build] $demo"
    zig build native -Ddemo="$demo"
    for preset in low medium high; do
        a="$OUT/$demo-$preset-a.txt"
        b="$OUT/$demo-$preset-b.txt"
        ./zig-out/bin/"$demo" --tas "demos/$demo/$demo.tas" --preset "$preset" --hashes "$a" > "$OUT/$demo-$preset-a.log" 2>&1
        ./zig-out/bin/"$demo" --tas "demos/$demo/$demo.tas" --preset "$preset" --hashes "$b" > "$OUT/$demo-$preset-b.log" 2>&1
        if ! cmp -s "$a" "$b"; then
            echo "FAIL $demo $preset: two runs gave different hashes"
            diff "$a" "$b" | head -10 || true
            status=1
            continue
        fi
        echo "ok   $demo $preset: two runs, $(wc -l < "$a" | tr -d ' ') equal checkpoints"
        [[ $GOLDEN -eq 1 ]] || continue
        golden="demos/$demo/hashes/lavapipe-$preset.txt"
        if [[ $UPDATE -eq 1 ]]; then
            mkdir -p "demos/$demo/hashes"
            cp "$a" "$golden"
            echo "     wrote $golden"
        elif [[ ! -f "$golden" ]]; then
            echo "FAIL $demo $preset: no golden $golden (run with --update)"
            [[ $status -ne 0 ]] || status=2
        elif ! cmp -s "$a" "$golden"; then
            echo "FAIL $demo $preset: the hashes are not the golden $golden"
            diff "$golden" "$a" | head -10 || true
            status=1
        else
            echo "     equal to $golden"
        fi
    done
done
exit $status
