# Input requirements — `REQ-INPUT-*`

Keyboard, mouse and wheel input from the platform backends.

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
