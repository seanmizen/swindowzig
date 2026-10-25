#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

PORT=3020
TIMEOUT=15

cleanup() {
  if [ -n "${SERVER_PID:-}" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  # Free the port if something else grabbed it
  lsof -ti :"$PORT" 2>/dev/null | xargs kill -9 2>/dev/null || true
}
trap cleanup EXIT

echo "=== Building wasm target ==="
zig build web -Dexample=voxel -Doptimize=ReleaseFast

echo "=== Starting dev server on port $PORT ==="
# Kill anything already on the port
lsof -ti :"$PORT" 2>/dev/null | xargs kill -9 2>/dev/null || true
sleep 1

bun backends/wasm/dev-server.ts --example voxel &
SERVER_PID=$!

echo "=== Waiting for server ==="
elapsed=0
while ! curl -sf http://localhost:$PORT/ > /dev/null 2>&1; do
  sleep 1
  elapsed=$((elapsed + 1))
  if [ "$elapsed" -ge "$TIMEOUT" ]; then
    echo "FAIL: server did not start within ${TIMEOUT}s"
    exit 1
  fi
done

echo "=== Checking index.html ==="
INDEX_CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/")
if [ "$INDEX_CODE" != "200" ]; then
  echo "FAIL: index.html returned $INDEX_CODE"
  exit 1
fi

echo "=== Checking app.wasm ==="
WASM_CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/app.wasm")
if [ "$WASM_CODE" != "200" ]; then
  echo "FAIL: app.wasm returned $WASM_CODE"
  exit 1
fi

echo "=== All checks passed ==="
