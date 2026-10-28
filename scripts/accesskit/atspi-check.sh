#!/usr/bin/env bash
# The AccessKit check on Linux with no screen reader (REQ-A11Y-007,
# REQ-A11Y-008). It runs flat2d with the AccessKit backend in a private
# D-Bus session. scripts/accesskit/fake_atspi.py takes the place of the
# AT-SPI registry: it reads the tree, moves the focus, clicks a list item,
# and checks the focus event and the live-region announcement.
#
# Needs: libaccesskit.a in ~/.local/lib (docs/accesskit.md), dbus-run-session,
# xvfb-run, lavapipe or a GPU, and python3 with the dbus and gi modules.
# Set PYTHON to choose the interpreter (default: python3).
#
# Usage: scripts/accesskit/atspi-check.sh [--no-build]
set -euo pipefail

cd "$(dirname "$0")/../.."
if [ "${1:-}" != "--no-build" ]; then
  zig build native -Dexample=flat2d -Daccesskit=true
fi

if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] || [ "${SW_ATSPI_INNER:-}" != 1 ]; then
  SW_ATSPI_INNER=1 exec dbus-run-session -- "$0" --no-build
fi

export AT_SPI_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS"
"${PYTHON:-python3}" -I scripts/accesskit/fake_atspi.py &
checker=$!
sleep 1
timeout 40 xvfb-run -a ./zig-out/bin/flat2d >/dev/null 2>&1 &
app=$!
status=0
wait "$checker" || status=$?
kill "$app" 2>/dev/null || true
wait "$app" 2>/dev/null || true
exit "$status"
