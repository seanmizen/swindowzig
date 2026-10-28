#!/usr/bin/env bash
# demos-check.sh: replay the script of each demo in demos/ with each preset,
# and compare the frame hashes at the checkpoints with the committed file
# demos/<demo>/hashes/lavapipe-<preset>.txt (REQ-DEMO-003).
#
# The hashes are lavapipe frames (Mesa software Vulkan): the CI runner has
# the same driver. A GPU gives other pixels, so run this on Linux with
# lavapipe (VK_LOADER_DRIVERS_SELECT='*lvp*').
#
# Usage (from the repo root):
#   scripts/demos-check.sh                # compare
#   scripts/demos-check.sh --update       # write the hash files
#   scripts/demos-check.sh --demo cow     # one demo
#   scripts/demos-check.sh --twice        # also run each check two times (same hashes)
#
# A failed compare writes the new hashes to zig-out/demo-hashes/ and prints
# the command that accepts them.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

UPDATE=0
TWICE=0
ONLY_DEMO=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --update) UPDATE=1; shift ;;
        --twice) TWICE=1; shift ;;
        --demo) ONLY_DEMO="$2"; shift 2 ;;
        *) echo "demos-check.sh: unknown option: $1" >&2; exit 2 ;;
    esac
done

export VK_LOADER_DRIVERS_SELECT="${VK_LOADER_DRIVERS_SELECT:-*lvp*}"
RUN_TIMEOUT="${RUN_TIMEOUT:-1200}"
FAIL=0

for d in demos/*/; do
    demo="$(basename "$d")"
    [[ -f "demos/$demo/main.zig" ]] || continue
    [[ -z "$ONLY_DEMO" || "$ONLY_DEMO" == "$demo" ]] || continue
    echo "== $demo: build"
    zig build native -Ddemo="$demo" -Doptimize=ReleaseFast
    for preset in low medium high; do
        runs=1
        [[ $TWICE -eq 1 && $UPDATE -eq 0 ]] && runs=2
        for run in $(seq 1 "$runs"); do
            args=(--check --preset "$preset")
            [[ $UPDATE -eq 1 ]] && args+=(--update)
            echo "== $demo $preset (run $run)"
            log="$(mktemp)"
            set +e
            timeout "$RUN_TIMEOUT" "./zig-out/bin/$demo" "${args[@]}" > "$log" 2>&1
            rc=$?
            set -e
            # The log lists each checkpoint hash. Show the rest.
            grep -v "checkpoint .* [0-9a-f]\{16\}$" "$log" || true
            rm -f "$log"
            if [[ $rc -ne 0 ]]; then
                echo "FAIL: $demo $preset (exit $rc)"
                FAIL=1
            fi
        done
    done
done

if [[ $FAIL -ne 0 ]]; then
    echo
    echo "One or more demo checks failed. If the change is deliberate, accept the new hashes:"
    echo "  scripts/demos-check.sh --update"
    echo "or copy them from zig-out/demo-hashes/ (CI uploads that folder)."
    exit 1
fi
echo "All demo checks passed."
