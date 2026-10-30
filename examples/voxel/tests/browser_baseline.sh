#!/usr/bin/env bash
# browser_baseline.sh: the browser baseline of the voxel web build
# (REQ-VOXEL-037).
#
# Procedure:
#   1. Build the voxel web page (ReleaseFast) with info logs
#      (-Dweb-log=info), and bundle the loaders.
#   2. Serve zig-out on port 3090 with the dev server (no build, no watch).
#   3. browser_baseline.mjs opens the page in a visible Chromium. It
#      writes trace-load.json, trace-sprint.json, console.txt and
#      result.json to the out folder, and prints result.json.
#   4. Stop the server. Build the page again with the default log level.
#
# The run needs a monitor and a GPU (a Mac with Metal). It is not a CI
# step. Look at result.json:
#   mainUs.p99 must be less than the install budget (4000 us).
#   editFrames: an edit inside a chunk shows after 2 frames. An edit on a
#   chunk border can take 3 frames (see REQ-VOXEL-037).
#
# Usage (from the repo root):
#   ./examples/voxel/tests/browser_baseline.sh [out dir]
set -euo pipefail

cd "$(dirname "$0")/../../.."  # the repo root

OUT=${1:-${TMPDIR:-/tmp}/voxel_browser_baseline}
PORT=3090
mkdir -p "$OUT"

zig build web -Dexample=voxel -Doptimize=ReleaseFast -Dweb-log=info
yarn build:js >/dev/null

bun backends/wasm/dev-server.ts --example voxel --no-build --port "$PORT" >"$OUT/server.log" 2>&1 &
SERVER=$!
trap 'kill "$SERVER" 2>/dev/null || true; zig build web -Dexample=voxel -Doptimize=ReleaseFast >/dev/null 2>&1 || true' EXIT
for _ in $(seq 1 30); do
    curl -s -o /dev/null "http://localhost:$PORT/" && break
    sleep 1
done

node examples/voxel/tests/browser_baseline.mjs "http://localhost:$PORT/" "$OUT"
echo "==> Traces and logs in $OUT"
