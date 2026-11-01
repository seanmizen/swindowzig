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

## REQ-DEMO-020 — The shooter demo is a fight in a snowy arena, offline

- **Status:** active
- **Source:** agent:SWZ-79
- **Origin:** #79
- **Type:** functional
- **Priority:** P2
- **Statement:** The shooter demo shall show a first-person fight against
  bots in a snowy arena that code builds, with no network code.
- **Rationale:** The demo shows the engine features in a game: falling
  snow, a cloud layer, the fog, the sky, the shadows, the particles, 3D
  sound, box models, collision, the camera and the input actions. The
  fight code comes from the offline part of the action game, so the demo
  has no server.
- **Verification:**
  - Test — `demos/shooter/arena.zig` › "arena: the spawns are free, and
    each cover point is beside a tall box (REQ-DEMO-020)"
  - Test — `scripts/demos-check.sh` › the checkpoints of
    `demos/shooter/shooter.tas` (for example `snow_clouds`, `fog_sky`,
    `shadows`, `first_kill`).
- **Relations:** depends-on REQ-DEMO-001

## REQ-DEMO-021 — The bots of the shooter give the same fight on each run

- **Status:** active
- **Source:** agent:SWZ-79
- **Origin:** #79
- **Type:** functional
- **Priority:** P2
- **Statement:** The bots of the shooter demo shall take each random choice
  from a seeded random number generator on the fixed timestep, so one
  script of input gives the same fight on each run.
- **Rationale:** The bots move, take cover and fire back. A clock or an
  unseeded choice gives another fight on each run, and then the frame
  hashes of the script change.
- **Verification:**
  - Test — `demos/shooter/game.zig` › "game: the same seed and input give
    the same fight (REQ-DEMO-021)"
  - Test — `demos/shooter/game.zig` › "game: the bots take cover and fire
    back (REQ-DEMO-021)"
  - Test — `scripts/demos-check.sh` › `--twice` gives the same hashes for
    the shooter.
- **Relations:** depends-on REQ-DEMO-004

## REQ-DEMO-022 — One box model draws the bodies of all the bots

- **Status:** active
- **Source:** agent:SWZ-79
- **Origin:** #79
- **Type:** functional
- **Priority:** P3
- **Statement:** The shooter demo shall draw the bodies of the bots as
  instances of one `sw_render` box model, in the pose of the skeleton of
  each bot.
- **Rationale:** The body model of the action game gives a world frame for
  each part. The box model gives one draw call for all bodies, and the
  bodies cast shadows. The posed parts must stay on the skeleton, or the
  gun leaves the hand and the hit boxes leave the body.
- **Verification:** Test — `demos/shooter/body_model.zig` › "body model:
  the posed boxes follow the skeleton of npc.zig (REQ-DEMO-022)"
- **Relations:** none

## REQ-DEMO-023 — Each hit throws the particles of its material

- **Status:** active
- **Source:** agent:SWZ-79
- **Origin:** #79
- **Type:** functional
- **Priority:** P3
- **Statement:** When a round of the shooter demo hits a surface, the demo
  shall throw the particles of the material of the surface, or of snow.
- **Rationale:** Sparks for steel, splinters for wood and a white burst
  for snow show the particle system of `sw_render`. The random numbers
  come from a seeded generator, so a replay gives the same particles.
- **Verification:** Test — `demos/shooter/impact_fx.zig` › "impact fx:
  one seed gives the same particles, and snow has its own recipe
  (REQ-DEMO-023)"
- **Relations:** depends-on REQ-DEMO-021

## REQ-DEMO-024 — The shots of the shooter play as 3D sound

- **Status:** active
- **Source:** agent:SWZ-79
- **Origin:** #79
- **Type:** functional
- **Priority:** P3
- **Statement:** When a gun of the shooter demo fires in a window, the demo
  shall play the muzzle report at the gun, the crack of a near miss and
  the impact as `sw_audio` voices at their places in the world.
- **Rationale:** The mixer of `sw_audio` gives each voice its pan and its
  distance loss. A delay of distance divided by the speed of sound puts
  the report of a far gun after its flash. The sounds are procedural
  (the bullet sound models of the action game), so the demo has no audio
  file.
- **Verification:** Inspection — `demos/shooter/sfx.zig` › `Sfx.shots`.
  Demonstration — Sean listens to the native and the web build.
- **Relations:** none

## REQ-DEMO-025 — A click in the shooter locks the pointer again

- **Status:** active
- **Source:** agent:SWZ-120
- **Origin:** #120
- **Type:** functional
- **Priority:** P2
- **Statement:** While the player controls the shooter demo and the
  pointer is not locked, when the player clicks in the window, the demo
  shall ask for the pointer lock, and keep that click and the mouse
  movement from the game.
- **Rationale:** The browser ends the lock on Escape and on a focus loss.
  SDL on macOS keeps the relative mode during a focus loss, so the demo
  ends the lock itself on a focus loss. Before this requirement, the demo
  asked for the lock one time only, so the player lost the mouse after the
  first focus loss. The click that locks the pointer must not fire the gun.
- **Verification:**
  - Test — `demos/shooter/mouse_gate.zig` › "a click locks the pointer
    again and does not reach the game"
  - Demonstration — Sean clicks in another window, then in the shooter, in
    the native build on macOS and in the web build in Chromium.
- **Relations:** depends-on REQ-DEMO-010

## REQ-DEMO-026 — The menu and shooter demos share one game menu

- **Status:** active
- **Source:** agent:SWZ-121
- **Origin:** #121
- **Type:** constraint
- **Priority:** P2
- **Statement:** The menu demo and the shooter demo shall build their menu
  screens with the shared game menu of `demos/common/game_menu.zig`.
- **Rationale:** The two demos show one sw_ui game menu: the panel, the
  cycle buttons, the sliders, the mouse rows, the audio screen, the text
  of each language, the fonts and the gamepad navigation. One copy keeps
  the look and the input the same. The menu demo did not change when its
  screens moved: its frame hashes stay the same.
- **Verification:**
  - Inspection — `demos/common/game_menu.zig` › `Menu`.
  - Test — `scripts/demos-check.sh` › the checkpoints of
    `demos/menu/menu.tas` keep their hashes.
- **Relations:** depends-on REQ-DEMO-009

## REQ-DEMO-027 — Escape or Start pauses the shooter and opens its menu

- **Status:** active
- **Source:** agent:SWZ-121
- **Origin:** #121
- **Type:** functional
- **Priority:** P2
- **Statement:** When the player presses Escape or the gamepad Start
  button during the fight, or the pointer lock ends during the fight, the
  shooter demo shall stop the fight, end the pointer lock and show the
  pause menu.
- **Rationale:** The browser ends the pointer lock on Escape, and the page
  does not always get the key. So the end of the lock also opens the menu,
  and the web build and the native build do the same thing. The menu has
  Resume, the graphics, the mouse and the volume, and Quit in the native
  build. Each change applies at once. Resume asks for the pointer lock
  again. The menu does not read Escape for some ticks after it opens, so
  the key that opens it does not also close it.
- **Verification:**
  - Test — `demos/shooter/pause.zig` › "Escape and Start open the menu,
    and Start closes it (REQ-DEMO-027)"
  - Test — `demos/shooter/pause.zig` › "the end of the pointer lock
    during the fight opens the menu (REQ-DEMO-027)"
  - Test — `backends/wasm/tests/shooter.pw.ts` › "Escape pauses the
    shooter, and the mirror shows the pause menu"
  - Test — `scripts/demos-check.sh` › the checkpoint `pause_menu` of
    `demos/shooter/shooter.tas`.
  - Demonstration — Sean presses Escape and Start in the native build on
    macOS and in the web build in Chromium.
- **Relations:**
  - depends-on REQ-DEMO-025
  - depends-on REQ-DEMO-026

## REQ-DEMO-028 — The shooter keeps the settings of its menu

- **Status:** active
- **Source:** agent:SWZ-121
- **Origin:** #121
- **Type:** functional
- **Priority:** P3
- **Statement:** When the player changes a setting in the pause menu of
  the shooter demo, the demo shall write the settings to `sw_platform`
  storage, and read them when it starts again.
- **Rationale:** The player sets the graphics, the mouse and the volume
  one time. A capture or check run does not read the save, so the frames
  do not depend on the machine (REQ-DEMO-004). The script of a window
  run does not write the save. A line that the demo cannot read keeps
  the value before it.
- **Verification:**
  - Test — `demos/shooter/prefs.zig` › "prefs: the text form gives the
    same settings back (REQ-DEMO-028)"
  - Test — `demos/shooter/prefs.zig` › "prefs: a bad line keeps the
    value before it (REQ-DEMO-028)"
  - Test — `backends/wasm/tests/shooter.pw.ts` › "Escape pauses the
    shooter, and the mirror shows the pause menu": the page writes
    localStorage, and a new page reads it.
- **Relations:** depends-on REQ-DEMO-027

## REQ-DEMO-029 — A demo can have more than one map, each with its own script and hashes

- **Status:** active
- **Source:** agent:SWZ-127
- **Origin:** #127
- **Type:** functional
- **Priority:** P2
- **Statement:** When a demo gives more than one map, `scripts/demos-check.sh`
  shall play the script of each map and compare its frame hashes with the
  hash files of that map.
- **Rationale:** The shooter has a second map with its own script. The
  script of the first map is tuned to exact bot places, so its script and
  its hash files must not change when a map is added. `--map <name>` picks
  the map. The first map keeps the file names of a demo with one map.
  Each other map uses `hashes/<map>-lavapipe-<preset>.txt`.
  `--list-maps` gives the names to the check and record scripts.
- **Verification:**
  - Test — `demos/common/cli.zig` › "cli: the map flags (REQ-DEMO-029)"
  - Test — `.github/workflows/demos-check.yml` › the job checks
    `demos/shooter/indoor.tas` with
    `demos/shooter/hashes/indoor-lavapipe-<preset>.txt`.
- **Relations:** depends-on REQ-DEMO-003

## REQ-DEMO-030 — The shooter has a closed room lit by two shadowed lamps

- **Status:** active
- **Source:** agent:SWZ-127
- **Origin:** #127
- **Type:** functional
- **Priority:** P2
- **Statement:** When the shooter demo shows the `indoor` map, the demo
  shall light the room with two point lights that cast shadows from cube
  shadow maps, and with no sun light.
- **Rationale:** Sean wants to see two lights that compete: two shadows of
  each crate, and the light of one lamp where the other is blocked. The
  room is closed: a floor, four walls and a ceiling, with no sky, snow,
  clouds or fog inside. The ambient light is low (`indoor_ambient`,
  default 0.04), so the shadows are easy to see. Light 1 hangs still at
  the centre. Its lamp is a box model that casts no shadow, and the player
  casts none, so nothing that moves casts into its cube map: the lighting
  draws that cube map one time. The room has no bots. The pause menu
  changes the map with no restart. The Map button shows only when the
  player has control, because a script plays one map.
- **Verification:**
  - Test — `demos/shooter/arena.zig` › "arena: the room is closed, has no
    bots and no snow, and the lamps are inside (REQ-DEMO-030)"
  - Test — `demos/shooter/game.zig` › "game: the room has no bots and no
    waves, and L moves light 2 (REQ-DEMO-030, REQ-DEMO-031)"
  - Test — `scripts/demos-check.sh` › the checkpoints of
    `demos/shooter/indoor.tas`.
  - Demonstration — Sean opens the pause menu in the native build and
    changes the map.
- **Relations:**
  - depends-on REQ-GPU-044
  - depends-on REQ-DEMO-027
  - depends-on REQ-DEMO-029

## REQ-DEMO-031 — L moves the rail lamp of the shooter room

- **Status:** active
- **Source:** agent:SWZ-127
- **Origin:** #127
- **Type:** functional
- **Priority:** P2
- **Statement:** When the player presses L or the gamepad north button in
  the room of the shooter, the demo shall move light 2 at a constant speed
  to the other end of its rail, or turn it round during a move.
- **Rationale:** The moving lamp shows the shadows move, and the shadows of
  the still lamp stay. A moving lamp draws its cube map again in each
  frame of the move only. The HUD names the key.
- **Verification:**
  - Test — `demos/shooter/game.zig` › "game: a press moves light 2 to the
    other end, and a press during a move turns it round (REQ-DEMO-031)"
  - Test — `scripts/demos-check.sh` › the checkpoints `light2_west`,
    `light2_middle`, `light2_east` and `turned` of
    `demos/shooter/indoor.tas`.
- **Relations:** depends-on REQ-DEMO-030

## REQ-DEMO-032 — A shot on the button of the shooter room moves the rail lamp

- **Status:** active
- **Source:** sean
- **Origin:** #127
- **Type:** functional
- **Priority:** P2
- **Statement:** When a shot of the player hits the button on the wall of
  the shooter room, the demo shall move light 2 as one press of the L key
  does.
- **Rationale:** Sean asked for a button in the world: the mouse and the
  gamepad fire the gun, so the button needs no new binding. The button
  is a box model. A hit moves it into the wall and out again, and it
  makes a procedural click. The button ignores a hit while it moves, so a
  burst does not move the lamp to and fro. The button casts no shadow, so
  its move does not make the lighting draw the cube map of light 1 again.
- **Verification:**
  - Test — `demos/shooter/game.zig` › "game: a shot on the button of the
    room moves light 2, as L does (REQ-DEMO-032)"
  - Test — `scripts/demos-check.sh` › the checkpoint `button` of
    `demos/shooter/indoor.tas`.
  - Demonstration — Sean hears the click in the native build.
- **Relations:** depends-on REQ-DEMO-031

## REQ-DEMO-033 — The pause menu sets the ambient light of the shooter room

- **Status:** active
- **Source:** sean
- **Origin:** #127
- **Type:** functional
- **Priority:** P3
- **Statement:** When the player moves the Room light slider in the pause
  menu of the shooter, the demo shall change the ambient light of the
  indoor room at once and save the value with the other settings.
- **Rationale:** Sean wants to try the ambient level that shows the two
  shadows best. The slider is on the Graphics screen, and only in the
  room: it changes nothing in the arena, and the frames of the arena
  script stay the same. The screen reader reads the new value after a
  key press (REQ-A11Y-009).
- **Verification:**
  - Test — `demos/shooter/prefs.zig` › "prefs: the text form gives the
    same settings back (REQ-DEMO-028)"
  - Test — `backends/wasm/tests/shooter.pw.ts` › "Escape pauses the
    shooter, and the mirror shows the pause menu": the slider gives its
    value, and the page saves it.
- **Relations:**
  - depends-on REQ-DEMO-028
  - depends-on REQ-DEMO-030
