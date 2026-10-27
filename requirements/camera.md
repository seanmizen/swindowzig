# Camera requirements — `REQ-CAMERA-*`

The camera controller of `sw_math` (`libs/sw_math/src/camera.zig`).

## REQ-CAMERA-001 — The camera result does not depend on the frame rate

- **Status:** active
- **Source:** agent:SWZ-43
- **Origin:** #43
- **Type:** quality
- **Priority:** P2
- **Statement:** When the game gives the same input over the same time, the
  camera controller shall give the same rotation, field of view and
  third-person distance for one update of dt and for two updates of dt / 2.
- **Rationale:** A smoothing that moves a fixed part of the distance in each
  frame turns faster at a high frame rate. Then the camera feels different
  on each computer, and a replay at a different rate shows a different view.
  The controller uses exponential smoothing, `1 - exp(-dt / time_constant)`.
- **Verification:** Test — `libs/sw_math/src/camera.zig` › "smoothing does
  not depend on the frame rate"
- **Relations:** none

## REQ-CAMERA-002 — The camera controller reads no platform input

- **Status:** active
- **Source:** agent:SWZ-43
- **Origin:** #43
- **Type:** constraint
- **Priority:** P2
- **Statement:** The camera controller shall get its look, move and
  field-of-view input, its dt and its ray test only from the arguments of
  `update`.
- **Rationale:** A pure controller runs in unit tests, in a headless replay
  and on each platform with the same result. The game decides which actions
  and bindings feed it, and which ray test stops the third-person eye.
- **Verification:** Inspection — `libs/sw_math/src/camera.zig` imports only
  `std` and the `sw_math` files.
- **Relations:** none
