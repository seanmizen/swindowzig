# Demo requirements — `REQ-DEMO-*`

The showcase demos in `demos/`: the shared frame in `demos/common`, the
scripts, the frame hashes and the recordings.

## REQ-DEMO-001 — Each demo takes one command line

- **Status:** active
- **Source:** agent:SWZ-79
- **Origin:** #79
- **Type:** functional
- **Priority:** P2
- **Statement:** Each demo in `demos/` shall accept the flags `--tas
  <file>`, `--preset low|medium|high`, `--capture <dir>` and `--check`.
- **Rationale:** The record script and CI run every demo with the same
  command. A new demo then joins the recordings and the checks with no
  change to the scripts. `demos/common/demo.zig` parses the flags for
  each demo.
- **Verification:** Test — `demos/common/cli.zig` › "cli: each flag
  (REQ-DEMO-001)"
- **Relations:** none

## REQ-DEMO-002 — A script changes the demo on the fixed timestep

- **Status:** active
- **Source:** agent:SWZ-79
- **Origin:** #79
- **Type:** functional
- **Priority:** P2
- **Statement:** When a demo script names a command at a tick, the demo
  shall run that command at that tick of the fixed timestep.
- **Rationale:** The script is the film of the demo: it sets the captions
  and changes one setting at a time. A command on a tick, and not on a
  wall-clock time, gives the same film on a slow machine and on a fast
  machine.
- **Verification:**
  - Test — `demos/common/script.zig` › "script: the player gives each
    command at its tick, one time (REQ-DEMO-002)"
  - Test — `demos/common/script.zig` › "script: absolute and relative
    ticks, each command (REQ-DEMO-002)"
  - Test — `demos/common/reflect.zig` › "reflect: set a bool, an enum, a
    float and an int by name (REQ-DEMO-002)"
- **Relations:** none

## REQ-DEMO-003 — CI compares the frame hashes of each demo script

- **Status:** active
- **Source:** agent:SWZ-79
- **Origin:** #79
- **Type:** quality
- **Priority:** P2
- **Statement:** If a frame hash at a checkpoint of a demo script differs
  from the committed hash file of that demo and preset, then the `--check`
  run shall exit with a failure code.
- **Rationale:** A demo uses many library parts. Without a check, a
  change to a library can break a demo with nobody aware of it. The run
  writes the new hashes to `zig-out/demo-hashes/` and prints the command
  that accepts a deliberate change.
- **Verification:**
  - Test — `demos/common/hashes.zig` › "hashes: compare finds a changed, a
    new and a lost checkpoint (REQ-DEMO-003)"
  - Test — `.github/workflows/demos-check.yml` › the job runs
    `scripts/demos-check.sh` on lavapipe.
- **Relations:** depends-on REQ-DEMO-004

## REQ-DEMO-004 — Capture and check runs do not read the wall clock

- **Status:** active
- **Source:** agent:SWZ-79
- **Origin:** #79
- **Type:** constraint
- **Priority:** P2
- **Statement:** While a demo runs with `--capture` or `--check`, the demo
  shall make each frame from the tick count and the script only.
- **Rationale:** Two runs of one script and one preset must give the same
  frame hashes, and a video must not skip frames. So the run draws one
  frame for each tick, and the overlay shows the fixed tick time in place
  of the measured frame time.
- **Verification:** Test — `scripts/demos-check.sh` › `--twice`: each
  check runs two times and each run must match the committed hashes.
- **Relations:** none

## REQ-DEMO-005 — The cow is an original voxel model

- **Status:** active
- **Source:** agent:SWZ-79
- **Origin:** #79
- **Type:** constraint
- **Priority:** P2
- **Statement:** The cow demo shall show a voxel cow that the code in
  `demos/common/cow_model.zig` makes, with no model or texture from a game.
- **Rationale:** The demo is for a public page. A copy of the cow of a
  game is not ours to show. The code makes the model, so the model needs
  no asset and no licence notice.
- **Verification:** Test — `demos/common/cow_model.zig` › "cow model: the
  same voxels on each build, with each colour (REQ-DEMO-005)"
- **Relations:** none

## REQ-DEMO-006 — Greedy meshing merges only faces that shade the same

- **Status:** active
- **Source:** agent:SWZ-79
- **Origin:** #79
- **Type:** functional
- **Priority:** P3
- **Statement:** Where the demo mesher runs in greedy mode, it shall merge
  two faces only when the faces have the same colour and the same ambient
  occlusion at each corner.
- **Rationale:** The cow demo shows naive and greedy meshing side by side
  with the quad count. The two meshes must give the same image, so a
  merged quad must not spread the occlusion of one corner over a larger
  area.
- **Verification:**
  - Test — `demos/common/voxel_mesh.zig` › "voxel mesh: greedy merges a
    cube of one colour into six quads (REQ-DEMO-006)"
  - Test — `demos/common/voxel_mesh.zig` › "voxel mesh: a voxel on a floor
    darkens the floor corners next to it (REQ-DEMO-006)"
- **Relations:** none

## REQ-DEMO-007 — The record script makes a video and a loop for each run

- **Status:** active
- **Source:** agent:SWZ-79
- **Origin:** #79
- **Type:** functional
- **Priority:** P3
- **Statement:** When `yarn demos:record` runs, the record script shall
  make an MP4 file and an animated WebP file of at most 4 MB for each demo
  and each preset.
- **Rationale:** The MP4 files go to a GitHub Release. GitHub shows a WebP
  loop of at most 4 MB in a README page, so a reader sees each demo with
  no download.
- **Verification:** Inspection — `scripts/demos-record.sh`: the loop over
  `demos/*/main.zig` and the presets, and the WebP size limit.
- **Relations:** depends-on REQ-DEMO-004

## REQ-DEMO-008 — A demo script can press keys as a player does

- **Status:** active
- **Source:** agent:SWZ-79
- **Origin:** #79
- **Type:** functional
- **Priority:** P2
- **Statement:** When a demo script names an input command (`key`, `text`,
  `pad`, `axis`, `mouse` or `wheel`) at a tick, the demo shall give the
  engine input event of that command to the demo at that tick.
- **Rationale:** A menu demo needs key presses, text and a gamepad to go
  through its screens. The events go into an input snapshot, so the action
  map, the binding capture and the UI read them as they read a player. The
  same script then gives the same frames on each run.
- **Verification:**
  - Test — `demos/common/script.zig` › "script: input commands keep the
    device and the arguments (REQ-DEMO-008)"
  - Test — `scripts/demos-check.sh` › the menu demo drives its menu only
    with input commands, and `--twice` gives the same hashes.
- **Relations:** depends-on REQ-DEMO-002

## REQ-DEMO-009 — The menu demo applies each setting at once

- **Status:** active
- **Source:** agent:SWZ-79
- **Origin:** #79
- **Type:** functional
- **Priority:** P3
- **Statement:** When the player changes a setting in the menu demo, the
  demo shall apply the setting to the live background in the same tick.
- **Rationale:** The demo shows that a game menu built on sw_ui needs no
  Apply button: the graphics settings change the cow scene, the volumes
  change the sound groups, and the control settings change the camera.
  Each checkpoint of the menu script shows a setting after its change.
- **Verification:** Test — `scripts/demos-check.sh` › the checkpoints of
  `demos/menu/menu.tas` (for example `preset_low`, `sky_off`,
  `turn_j`, `dead_zone`).
- **Relations:** depends-on REQ-DEMO-008

## REQ-DEMO-010 — The player can take control of an interactive demo

- **Status:** active
- **Source:** agent:SWZ-79
- **Origin:** #79
- **Type:** functional
- **Priority:** P3
- **Statement:** While an interactive demo plays its script in a window,
  when the player presses a key, a mouse button or a gamepad button, the
  demo shall stop the script and read the input of the player.
- **Rationale:** The web page of the menu demo plays the script as a
  film. A visitor who presses a key wants to use the menu, and the script
  must not fight the visitor.
- **Verification:** Inspection — `demos/common/demo.zig` › `playerActed`
  and `Host.input`.
- **Relations:** depends-on REQ-DEMO-008
