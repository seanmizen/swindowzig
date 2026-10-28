# Input requirements — `REQ-INPUT-*`

Keyboard, mouse, wheel and gamepad input from the platform backends, and the
input actions that a game binds to them.

## REQ-INPUT-001 — Key code values do not change

- **Status:** active
- **Source:** agent:SWZ-3
- **Origin:** #3
- **Type:** constraint
- **Priority:** P2
- **Statement:** The `sw_core` `KeyCode` enum shall keep the integer value of
  each member that exists, and get each new member after the last member.
- **Rationale:** A binary recording stores the integer value of each key
  code. If a value changes, an old recording replays different keys. TAS
  files and the bind names of games also refer to these keys.
- **Verification:** Test — `libs/sw_core/src/event.zig` › "KeyCode values do
  not change"
- **Relations:** none

## REQ-INPUT-002 — Punctuation keys follow the physical key

- **Status:** active
- **Source:** agent:SWZ-3
- **Origin:** #3
- **Type:** functional
- **Priority:** P2
- **Statement:** When the user presses a punctuation or navigation key, the
  platform backend shall send the `KeyCode` of the key at that physical
  position on a US keyboard.
- **Rationale:** The punctuation keys type different characters on each
  layout, and the browsers give them different `keyCode` values. A game that
  binds the console to the backtick key must find that key on every layout.
  The web backend reads `KeyboardEvent.code`, and the SDL backend reads the
  scancode. Letters and digits still follow the layout.
- **Verification:** Test — `backends/wasm/events.test.ts` › "the backtick key
  is 192 on every layout"
- **Relations:** none

## REQ-INPUT-003 — Actions come only from the input and the bindings

- **Status:** active
- **Source:** agent:SWZ-49
- **Origin:** #49
- **Type:** constraint
- **Priority:** P1
- **Statement:** The `sw_core` `ActionMap` shall set the state of each
  action only from the `InputSnapshot` of the tick, the bindings and the
  state of the previous tick.
- **Rationale:** A recording stores the raw input events, not the actions. A
  replay with the same bindings must give the same actions as the
  recording. A clock, a random value or a platform call in the action layer
  makes the replay differ.
- **Verification:** Test — `libs/sw_core/src/action.zig` › "actions: the same
  events give the same actions (REQ-INPUT-003)"
- **Relations:** none

## REQ-INPUT-004 — Saved input settings load in a newer version

- **Status:** active
- **Source:** agent:SWZ-49
- **Origin:** #49
- **Type:** functional
- **Priority:** P2
- **Statement:** If the saved input settings have a line or a binding that
  `ActionMap.decode` cannot read, then `decode` shall keep the value that
  the map had for that entry, and read the other entries.
- **Rationale:** A game adds actions, and the engine adds input sources (for
  example gamepads). The settings that a player saved with an older or a
  newer version must still load, and must not reset all bindings.
- **Verification:** Test — `libs/sw_core/src/action.zig` › "actions: decode
  keeps defaults for entries it cannot read (REQ-INPUT-004)"
- **Relations:** none

## REQ-INPUT-005 — Gamepads are recorded input that binds to actions

- **Status:** active
- **Source:** agent:SWZ-50
- **Origin:** #50
- **Type:** functional
- **Priority:** P2
- **Statement:** The `sw_core` `InputSnapshot` and `ActionMap` shall get
  the gamepad state only from the gamepad events and the dead zone
  settings.
- **Rationale:** A platform backend sends a gamepad event when a gamepad
  connects, disconnects, or changes a button or an axis. A recording and a TAS replay store the raw input events. If
  the gamepad state comes from the events, a replay gives the same gamepad
  input. SDL sends events, but the web Gamepad API must be read each frame:
  the web backend reads it once per frame and sends the changes as events.
  The snapshot keeps the raw axis values, and the game applies its dead
  zones when it reads them, so a change of a setting does not change the
  recording.
- **Verification:** Test — `libs/sw_core/src/replay.zig` › "Replayer plays
  gamepad input into the snapshot (REQ-INPUT-005)"
- **Relations:** none

## REQ-INPUT-006 — Old recordings still play

- **Status:** active
- **Source:** agent:SWZ-50
- **Origin:** #50
- **Type:** constraint
- **Priority:** P1
- **Statement:** The `sw_core` `Deserializer` shall read each recording
  format version from `MIN_VERSION` to `VERSION`.
- **Rationale:** Projects keep recordings and TAS replays for regression
  tests and for bug reports. A new event type must not make an old file stop
  playing. Each change to the format increases `VERSION`, and the version
  tells the reader which event tags the file can have.
- **Verification:** Test — `libs/sw_core/src/replay.zig` › "Replayer plays a
  version 1 recording (REQ-INPUT-006)"
- **Relations:** none

## REQ-INPUT-007 — A key press shorter than one tick is not lost

- **Status:** active
- **Source:** agent:SWZ-92
- **Origin:** #92
- **Type:** functional
- **Priority:** P2
- **Statement:** When a key goes down and up in the same tick, the `sw_core`
  `InputSnapshot` shall give the key as down and pressed in that tick, with
  the modifiers of the key press.
- **Rationale:** A slow frame puts all the events of the frame in one tick.
  A short Shift+Tab then has the Shift up after the Tab, and a game that
  reads the modifiers at the end of the tick sees no Shift. The browser
  tests on SwiftShader draw a few frames each second, and lost key presses
  in this way. Two presses of one key in one tick are still one press for
  `keyPressed`. `keyPressCount` gives the number of presses (REQ-INPUT-009).
- **Verification:**
  - Test — `libs/sw_core/src/input.zig` › "InputSnapshot keeps a key press
    shorter than one tick (REQ-INPUT-007)"
  - Test — `backends/wasm/tests/platform.pw.ts` › "a game goes to full
    screen and back"
- **Relations:** none

## REQ-INPUT-008 — The wheel snapshot is in lines

- **Status:** active
- **Source:** agent:SWZ-77
- **Origin:** #77
- **Type:** functional
- **Priority:** P2
- **Statement:** The `sw_core` `InputSnapshot` shall give `wheel.delta_x`
  and `wheel.delta_y` in lines, from the `dx`, `dy` and `mode` of each wheel
  event.
- **Rationale:** SDL gives one line for one notch of the wheel. The browser
  gives a `WheelEvent.deltaMode`, and most browsers give pixels. Before this
  requirement, the snapshot added the deltas and dropped the mode, so a
  game got pixels on the web and lines on the desktop. Then each game
  needed a different factor for each backend. The snapshot divides pixels
  by 40 (`wheel_pixels_per_line`, the same value as the `sw_ui` scroll
  step) and multiplies pages by 10 (`wheel_lines_per_page`). The wheel
  event keeps its raw deltas and its mode, so a recording does not change.
  A browser notch is often more than one line, because the browser sets
  the size of a notch.
- The snapshot does not make one notch the same number of lines on each
  backend. Chrome gives about 2.5 lines for one notch (100 pixels), Firefox
  gives 3 lines, and SDL gives 1 line. The size of a browser notch also
  changes with the operating system scroll setting, and a trackpad gives
  pixels with no notch. So a constant for each backend is not correct on
  all computers, and a notch detector breaks the trackpad. A change of the
  scale also changes the wheel for each game that reads lines now. A game
  that wants one step for each notch uses the sign of `delta_y`, or adds
  the lines and steps at each full line.
- **Verification:** Test — `libs/sw_core/src/input.zig` › "InputSnapshot
  wheel is in lines on all backends (REQ-INPUT-008)"
- **Relations:** none

## REQ-INPUT-009 — The snapshot counts the presses of one key in one tick

- **Status:** active
- **Source:** agent:SWZ-112
- **Origin:** #112
- **Type:** functional
- **Priority:** P3
- **Statement:** The `sw_core` `InputSnapshot` shall give, with
  `keyPressCount`, the number of up-to-down changes of a key in the tick,
  up to 255.
- **Rationale:** A slow tick can hold two presses of one key, for example
  two fast presses of Space at a few frames each second. `keyPressed` gives
  a bool, and it stays a bool so that the games that read it do not change.
  A game that must not lose a press reads the count. A key repeat is not a
  press. The count is 256 bytes in the snapshot, and the tick clears it.
- **Verification:** Test — `libs/sw_core/src/input.zig` › "InputSnapshot
  counts the presses of one key in one tick (REQ-INPUT-009)"
- **Relations:** refines REQ-INPUT-007

## REQ-INPUT-010 — A recording with a bad wheel mode gives an error

- **Status:** active
- **Source:** agent:SWZ-112
- **Origin:** #112
- **Type:** functional
- **Priority:** P2
- **Statement:** If a wheel event in a recording has a `mode` byte that is
  not a `WheelMode`, then the `sw_core` `Deserializer` shall give
  `error.InvalidWheelMode`.
- **Rationale:** A recording is a file from the disk or from a bug report,
  so its bytes can be bad. Before this requirement, the reader put the byte
  into the `WheelMode` enum with no check. A value above 2 gave an enum
  value that is not valid. A switch on that value has undefined behaviour.
- **Verification:** Test — `libs/sw_core/src/serialize.zig` › "a wheel event
  with a bad mode byte gives an error (REQ-INPUT-010)"
- **Relations:** none
