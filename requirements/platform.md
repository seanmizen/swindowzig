# Platform requirements — `REQ-PLATFORM-*`

The window, the cursor and the clipboard that the platform backends
(`libs/sw_platform`, `backends/wasm`) give to a game.

## REQ-PLATFORM-001 — A refused pointer lock does not stop the game

- **Status:** active
- **Source:** agent:SWZ-45
- **Origin:** #45
- **Type:** functional
- **Priority:** P2
- **Statement:** If the browser refuses a pointer lock, has no pointer lock,
  or ends a pointer lock, then the web backend shall continue the frame loop
  of the game.
- **Rationale:** `requestPointerLock` throws at once in some browsers, and
  rejects a promise in others. iOS Safari does not have it. A throw inside a
  wasm import stops `swindowzig_frame`, and the loader then stops the frame
  loop. A rejected promise with no handler is an error in the console. The
  game reads the real state with `isCursorLocked`.
- **Verification:** Test — `backends/wasm/tests/platform.pw.ts` › "a browser
  with no pointer lock does not stop the game"
- **Relations:** none

## REQ-PLATFORM-002 — Clipboard results arrive as events

- **Status:** active
- **Source:** agent:SWZ-45
- **Origin:** #45
- **Type:** functional
- **Priority:** P2
- **Statement:** When a clipboard read, write or paste completes, the
  platform backend shall send a `clipboard` event with the kind and the
  status of the operation.
- **Rationale:** On the web, the Clipboard API is asynchronous, needs a
  secure context, and can need a user gesture or a permission. A blocking
  call cannot work there. The same event on native keeps the game code the
  same on each platform. The status tells the game when the browser refused,
  and the console tells the developer why.
- **Verification:**
  - Test — `backends/wasm/tests/platform.pw.ts` › "the text field copies to
    the system clipboard and pastes from it"
  - Test — `libs/sw_platform/src/clipboard.zig` › "a result arrives as a
    clipboard event on the next flush (REQ-PLATFORM-002)"
- **Relations:** none

## REQ-PLATFORM-003 — The canvas and the surface follow the device pixel ratio

- **Status:** active
- **Source:** agent:SWZ-45
- **Origin:** #45
- **Type:** functional
- **Priority:** P2
- **Statement:** When the device pixel ratio of the window changes, the
  platform backend shall send a `resize` event with the new pixel size and
  DPI scale.
- **Rationale:** A move to a monitor with another ratio changes the pixel
  size, but the window size in points or CSS pixels can stay the same. Then
  the browser and SDL do not always send a resize. Without the event, the
  canvas and the GPU surface keep the old pixel size, and the image is soft
  or too large.
- **Verification:**
  - Test — `backends/wasm/tests/platform.pw.ts` › "the canvas follows the
    device pixel ratio"
  - Test — `libs/sw_platform/src/platform.zig` › "a move to a monitor with
    another DPI scale is a change (REQ-PLATFORM-003)"
- **Relations:** none

## REQ-PLATFORM-004 — The native window shows after the init callback

- **Status:** active
- **Source:** sean
- **Origin:** #14
- **Type:** functional
- **Priority:** P3
- **Statement:** On Windows, the native window shall become visible only
  after the init callback of the game returns.
- **Rationale:** The AccessKit Windows adapter subclasses the window. It
  stops the program if the window was visible before the adapter starts.
  The game starts the adapter in its init callback.
- **Verification:** Inspection — `flat2d.exe` with `-Daccesskit=true` on
  Windows starts, and Narrator reads the focused widget.
- **Relations:** none
