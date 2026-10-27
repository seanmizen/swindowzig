# Input requirements — `REQ-INPUT-*`

Keyboard, mouse and wheel input from the platform backends, and the input
actions that a game binds to them.

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
