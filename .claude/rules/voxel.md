---
paths:
  - "examples/voxel/**"
  - "libs/sw_voxel/**"
---

# swindowzig voxel demo and sw_voxel

Read with `CLAUDE.md`. The mandatory tests are there.

The engine code is in `libs/sw_voxel/src/`: the chunk storage, the mesher,
World, the frustum, and the chunk pipeline in `pipeline/`. The demo in
`examples/voxel/` keeps the game code: the block types and the generator
(`content.zig`, `world_gen.zig`), the renderer, the player and the menus.
In this file, a `pipeline/...` path is in `libs/sw_voxel/src/`.

### The content contract (libs/sw_voxel/src/content.zig)

- sw_voxel has no block names and no terrain. It imports the game content
  as the module `sw_voxel_content`: `Block` (an `enum(u8)` with `air = 0`),
  `emission`, `GenConfig` (with `seed: u64`), `generate`, and the
  `GenConfig` bytes of the Hello message.
- The content can give the opacity of a block ID, 0 to 15: `opacity(block)`
  (REQ-VOXEL-003). With no declaration, air is 0 and all other blocks are
  15. `light.zig` has the light rules and makes tables of `opacity` and
  `emission` at comptime.
- The content can declare the world height: `min_y` and `height`
  (multiples of 16, default 0 and 256). Chunk, PalettedBlocks, LightGrid
  and the mesh cells use local y (0 to `CHUNK_H - 1`). World, BlockGetter,
  the scheduler edits and the mesh y range use world y (`local + MIN_Y`).
  The unit tests of the library run two times: y 0 to 255, and y -64 to
  319.
- The content can give a baked model for a block ID: `model(block)`
  returns a `*const sw_voxel.model.BakedModel` or null (REQ-VOXEL-001).
  `models.zig` makes the tables at comptime. A block with no model is a
  full cube. For AO, a block with a model is the same as a full cube.
  For light, it has the opacity of its block ID.
- The content can give the collision boxes of a block ID:
  `collision(block)` returns a slice of `sw_voxel.collision.CellBox` or
  null (REQ-VOXEL-006). With null, air has no box and all other blocks are
  full cubes. `collision.zig` has `moveBox` (one axis at a time, with a
  step-up), `raycast` (a DDA, REQ-VOXEL-007) and `CameraRayTest` (the
  wall stop of the `sw_math` camera). The demo player and its ray cast do
  not use them yet.
- The content can give tint colours (REQ-VOXEL-009): `tint(block,
  tint_index, x, y, z) [3]u8` (a pure function), and `tintIndex(block,
  face) i8` for the faces of full cubes (comptime). A model quad takes
  its tint index from its `BakedQuad`. The demo tints grass tops and
  leaves, and voxel.wgsl draws them white times the tint.
- `build.zig` wires it with `addVoxel`. The demo gives
  `examples/voxel/content.zig`. The unit tests of the library give
  `libs/sw_voxel/testing/content.zig`, with numbered blocks.
- Do not put a block name, a biome or a generator in `libs/sw_voxel`. Put
  it in the content.

## Voxel lessons

### Voxel face winding (fixed in sw_voxel mesher.zig)
+Y, -Y, +Z, -Z faces had CW winding (inside-out). Fixed by reversing vertex
order so geometric normal matches the intended outward face normal. +X and -X
were already correct.

### Mesher output and block edits (libs/sw_voxel/src/mesher.zig)

- `generateMesh` runs the greedy mesher for the full cubes, then the
  model mesher for the blocks with a baked model. It writes one 16-byte
  `PackedQuad` per quad to `Mesh.quads`, and the y range to `Mesh.y_min`
  and `Mesh.y_max`. This is the GPU format. A model quad record has bit
  31 of word 3 set, and an index into `models.gpu_table` in place of the
  face and the size. The game uploads the table one time (the demo binds
  it at group 2). A quad with a cull face is not drawn next to a full
  cube (REQ-VOXEL-002). When a quad has a tint, the stream starts with
  tint records (word 3 bits 24-30 = 127) that hold the colours of the
  tint slots, and each quad holds its slot in the same bits. The shader
  draws no triangle for a tint record. `mesher.zig` has the layout. The upload writes the bytes of
  the worker result to the GPU as they are, and main keeps no copy (C5).
  Main keeps only `world.MeshInfo`: the quad count, the y range and the
  mesh hash.
- A greedy quad spans many blocks. A dig or a place meshes the whole chunk
  again, on the main thread, in the same tick. If the block is at a chunk
  edge, `updateBoundaryNeighbors` also meshes the neighbour chunk.
- The hardware depth test is always on. Main draws the chunks front to
  back and does not sort the quads.
- Each corner gets AO from its 3 neighbour blocks and smooth light: the
  mean `lightAt` of the 4 cells at the corner (REQ-VOXEL-008). A model
  quad on the side of its cell gets the values of the full face at its
  corners. A model quad off the grid gets flat light and AO 1.
  `MeshOptions` (`generateMeshWith`) turns AO (`.ao = .none`) and smooth
  light (`.smooth_light = false`) off. The greedy mesher merges only
  faces with equal AO, light and tint (REQ-VOXEL-010).
- `bench_mesher` (`zig build bench-mesher -Doptimize=ReleaseFast`) hashes
  the packed quads of a fixed world. The quad hash is `8c11e81d4ec42623`
  (the demo tints changed it from `4b4f00654f783b36`). A mesher change
  that must not change the output must keep this hash.

### Chunk stages (libs/sw_voxel/src/pipeline/stages.zig)

- `generate`, `light` and `mesh` are pure functions of a bounded
  neighbourhood (C2, P3). They read no World and no globals. The chunk
  workers (`pipeline/worker_world.zig`) run them.
- `light` lights a window 44 cells wide (16 + 2 × 14) from the blocks of
  the 3×3 chunks. It gives the same light as World after all 3×3
  neighbours load. With `light.ordered` (each opacity 0 or 15, one
  emission level), the queue is in order of level. Else a ring queue takes
  a cell again when it gets brighter.
- An edit changes the light incrementally (`light.update`, REQ-VOXEL-005):
  World.setBlock, and a chunk worker when its cache has the current light
  of the 3×3 chunks around the edit. The light stays within 14 cells of
  the edit, so the 3×3 chunks are sufficient (`light.Region`).
- `LightGrid` holds 4 bits per cell, per 16-high section. A uniform section
  has no array. After `set`, call `compact`, so that `eql` and
  `protocol.lightHash` see one form for each light.
- The mesher reads the light of a cell with `Chunk.lightAt` or
  `BlockGetter.lightAt` (`light.CellLight`). `mesh` reads at most `BORDER` (3) cells of each
  neighbour. A read further than that stops debug builds.
- `Inputs` records the versions that a job reads (C3). Install a result
  only when `Inputs.isCurrent` is true.
- `stages_test.zig` holds the equivalence, install-order and edit tests.
  `zig build bench-stages` prints the time of each stage and
  `stage_match=yes` when the stages give the output of World.

### Region files (libs/sw_voxel/src/region.zig)

- A region holds 16 × 16 chunks. `Region.put` compresses the blocks of a
  chunk, `get` gives them back, and `encode` and `decode` give the file
  bytes. The file stores the palette and the packed indices of each
  section as they are. It does not store the light: the light stage
  computes it again after a load.
- `decode` reads each format version that it knows. The test files
  `libs/sw_voxel/testing/region_v1_*.bin` must stay readable. Do not make
  them again (REQ-VOXEL-012).
- A damaged chunk fails alone with `error.CorruptChunk` (REQ-VOXEL-013).
- `Store(sw_assets.cache)` saves and loads through a folder (native) or
  OPFS (web). A save writes the full region again.

---

## Voxel Demo — CLI Flags

**Default changes (April 2026):** `--ao=moore` and `--aa=fxaa`
(quality=medium) are the startup defaults when no CLI flags are given. The
default render distance is 12 (`libs/sw_voxel/src/world.zig: DEFAULT_RENDER_DISTANCE`). Existing regression tests that captured frames under the old defaults
(classic AO, no AA) continue to pass the previous flags explicitly — see the
comment blocks at the top of `examples/voxel/tests/ao_corners.tas`,
`cave_skylight.tas`, and `tests/aa_regression.sh`.

| Flag | Description |
|------|-------------|
| `--tas <path>` | Load and play a TAS script. Physical input blocked during playback. |
| `--headless` | No window, no GPU. Ticks unlimited speed. Exits when TAS finishes. |
| `--tas-step` | Frame-by-frame TAS stepping. Right arrow = advance one TAS tick. Implies `--gpu-debug`. |
| `--gpu-debug` | Tint each chunk orange after its mesh is rebuilt. The tint fades in about 0.5 s. Cmd+G / Ctrl+G toggles it at runtime. |
| `--aa=<mode>` | Anti-aliasing method. Accepted: `none`, `msaa` (hardware multisample), `fxaa` (FXAA 3.11 post-process, **default at `medium` quality**). `--aa=fxaa` renders the scene to an offscreen bgra8unorm texture then runs a fullscreen FXAA pass to the swapchain. Can be combined with `--msaa=N` / `--fxaa-quality=<tier>` to control the per-method quality knob. |
| `--msaa=N` | MSAA sample count. Accepted: `none`/`0` (no AA), `1`, `2`, `4`, `8`. Implies `--aa=msaa` when given. The `bgra8unorm` surface format supports [1, 2, 4] on native and [1, 4] on WebGPU. Values outside that range are clamped (e.g. `--msaa=8` → 4×). |
| `--fxaa-quality=<tier>` | FXAA 3.11 quality tier. Accepted: `low` (4-step edge search, 0.5 subpix cap, 0.166 edge threshold), `medium` (12-step, 0.75, 0.125 — **default**. Matches the pre-quality-tier baseline so old FXAA diffs stay valid), `high` (32-step, 0.85, 0.063). Tiers map to roughly FXAA 3.11 presets 12/25/39. A change in the Settings menu at runtime rebuilds the FXAA shader and pipeline. WGSL has no specialisation constants, so `configureFXAA` substitutes the tier into `fxaa.wgsl` by text replacement. |
| `--render-distance=N` | Chunk-radius circular render distance. Accepted: integer in [1, 32]. **Default: 12.** The Settings picker changes it at runtime: the chunk scheduler loads and evicts for the new value. See `examples/voxel/docs/chunk-pipeline.md`. |
| `--world=<preset>` | Worldgen preset. Accepted: `flatland` (flat Y=63), `hilly` (default — procedural noise terrain). |
| `--seed=<u64>` | World seed. **Default: 0.** Generation mixes the seed into each random source: the height and biome noise, the caves, the trees and the glowstone. Seed 0 gives the terrain from before the seed existed. Native only. The web build uses seed 0. `zig build terrain-hash` builds a tool that prints the block hash of a 9×9 hilly area for each seed, from native and from wasm. CI compares the two. |
| `--ao=<mode>` | Ambient-occlusion sampler. Accepted: `none` (no AO, full brightness), `classic` (per-vertex Mojang face-plane AO), `moore` (**default** — extended sampler that adds the outward+2 slab at half weight to darken indoor corners). `propagated` and `ssao` are reserved enum values that fall back to `classic` with a one-shot warning. Read at startup only — runtime changes (future settings menu) require remeshing all loaded chunks. |
| `--lighting=<mode>` | World-lighting mode for the mesher. Accepted: `none` (every face fully lit by sky — A baseline for the cave-darkness regression) and `skylight` (default — per-chunk skylight propagation. Caves and overhangs go dark). Skylight is baked per-vertex at mesh time, so the in-game settings menu picker remeshes every loaded chunk on toggle. Digging or placing a block updates the light incrementally (`light.update`), then meshes the chunk again. See `examples/voxel/docs/lighting.md` for the algorithm and phase 3 (block light / glowstone) design. |
| `--smooth-light=<on\|off>` | Smooth light of the mesher. `on` (default): each corner gets the mean light of the 4 cells at the corner. `off`: flat light, each face gets the light of the cell in front of it (REQ-VOXEL-008). Goes through `Scheduler.setSmoothLight`. |
| `--place-block=<name>` | Puts the named block in hotbar slot 1, the slot that is selected at the start. Right-click then places it. Accepted: a block name of `content.zig`, for example `stone` or `glowstone`. With no flag, slot 1 is stone. `tests/glowstone_cave.sh` uses it to place an emitter from a TAS with no key presses. The script opens a window: run it under `xvfb-run` on Linux with no display. |
| `--dump-frame=<path>` | Capture one rendered frame to a PPM file, then exit. Waits for world loading to complete. If a TAS is running, waits for the TAS to finish. Then waits for the chunk scheduler to be idle (`Scheduler.isIdle`), so the captured state does not depend on timing. |
| `--debug-page=<general\|pipeline>` | The first page of the debug overlay. `pipeline` shows the chunk pipeline counters (C12). Cmd+P (Ctrl+P) changes the page at runtime. |
| `--chunk-workers=N` | Native only. The chunk worker threads of the ThreadPool executor, 0 to 4. **Default: min(CPU count - 1, 4).** 0 runs the chunk jobs on the main thread (the Inline executor). Each worker has its own world copy and a 64 MB cache (C4, C14). The web build uses min(`navigator.hardwareConcurrency` - 1, 4) Web Workers. See `examples/voxel/docs/chunk-pipeline.md`. |
| `--frustum=<mode>` | Per-chunk cull strategy. Accepted: `none`, `sphere`, `cone` and `frustum`. `frustum` is the default: it tests each chunk's box (the y range of its mesh) against the planes of the view-projection matrix. `none` draws every loaded chunk. `sphere` is a cheap radial cutoff at render_distance plus slack. `cone` tests each sphere against a cone along the camera's forward vector, with the FOV set by `--frustum-fov-deg`. No strategy ever culls the camera's own chunk or its 8 horizontal neighbours. `libs/sw_voxel/src/frustum.zig` has the math notes and edge-case tests. Cmd+F (Ctrl+F on Win/Linux) freezes the live frustum at its current transform so you can fly around and see what got culled. Settings menu has a live picker for the strategy. |
| `--frustum-fov-deg=<degrees>` | Total fov of the cone strategy in degrees. With no flag, each frame uses the screen-diagonal fov of the camera (about 100° at 60° vertical and 16:9). The test uses each chunk's full-height bounding sphere, so this cone keeps every chunk on screen. Range [0, 360]. Half-angle ≥ 90° always returns true. |

---

## Voxel Demo — World Loading & Spawn

**Loading screen** (`main.zig:renderLoadingScreen`): on first launch, the render
loop shows a dark purple background with animated wavy strips and a centred
"WORLD LOADING!!!" title. The screen remains until the chunk scheduler is
"ready" (`Scheduler.isReady`, radius 5): the simulation radius has blocks
and the chunks near spawn have current meshes. Then `state.world_loading`
is false. While loading, `voxelTick`
skips all gameplay input, and the TAS replayer stays `.stopped`.

**First spawn**: when loading completes, `resolveSpawnPos()` scans upward from the
default spawn_point (24, 64, 20) until it finds a 1×2 air column and places the
player there. The resolved (x, y, z) is stored as the permanent `state.spawn_point`.

**Respawn mechanics**:
- **R key** — manual respawn at current `spawn_point` via `resolveSpawnPos` (scans
  upward, so griefer blocks can't trap future respawns).
- **Void death** — automatic respawn when `player.feet_pos[1] < -10`.
- **Cmd+S / Ctrl+S** — debug override: set spawn_point to current player position.

**TAS + loading integration**: the replayer starts in `.stopped` state. When loading
completes, every event's `tick_id` is remapped by `+ctx.tickId() + 1` and the
replayer is `play()`ed. Result: TAS tick 1 is always the first post-loading sim
tick, regardless of how long loading took.

---

## Voxel Demo — Regression Tests

CI renders the regression scenes with lavapipe and compares them with
`examples/voxel/assets/goldens/lavapipe/` (workflow `swindowzig-check`). A
deliberate visual change needs new goldens: the failed job prints the command.
See `examples/voxel/docs/headless-regressions.md`.

TAS scripts for regression live under `examples/voxel/`:
- `framespike.tas` — block-removal during camera pan (hilly world). Mandatory
  headless test (see "Voxel Demo — Mandatory Testing" in `CLAUDE.md`).
- `tests/msaa_flatland.tas` — deterministic flatland scene used by the AA
  regression. Runner: `./examples/voxel/tests/aa_regression.sh` (captures
  none/fxaa/msaa4, writes both normalized and amplified diffs, prints coverage).
- `tests/ao_corners.tas` — flatland 1×4×1 shaft, used to verify
  `--ao=none|classic|moore` strategies darken the indoor wall faces of the
  shaft progressively. The Moore-vs-classic diff is small in this scene
  (~0.7% of frame, max delta ~8) because the shaft is small. On the hilly
  default world Moore differs from classic across ~70% of pixels with a
  mean channel delta of ~5/255 — that's the "more grounded" look.
- `tests/cave_skylight.tas` — flatland 1×6×1 shaft, used to verify
  `--lighting=none|skylight` darkens the dug interior. Baselines:
  flatland → 10.65% pixels differ, mean Δ 3.91/255, max Δ 105/255 (the
  affected pixels are exactly the cave interior, and the sky region is unchanged).
  Hilly → 97.5% pixels differ, mean Δ 19.78/255, max Δ 105/255 (almost
  every face shifts because hilly terrain has overhangs everywhere).
- `tests/frustum_look_down.tas` — flatland, pitches the camera into the
  -π/2 + 0.01 clamp, used to verify the frustum cull never blanks the
  ground when looking straight down. Pass criterion is that
  `--frustum=cone --frustum-fov-deg=30` and `--frustum=none` produce
  byte-identical PPMs (the camera-inside-bounding-sphere shortcut and the
  3×3 camera-neighbourhood safety net both fire). Mean brightness ≈ 103/255
  on the default flatland scene. "black" would be < 5/255.
- `tests/dig_relight.tas` — flatland small pit (4 dig clicks from a
  steep pitch-clamped look-down), used to verify `World.setBlock` now
  recomputes chunk skylight on dig. Diff vs. a local branch that
  disables the relight call: ~22% pixels differ, mean Δ ~25/255, max
  Δ ~52/255 — the affected pixels are exactly the pit interior, which
  goes from RGB ~(2,2,1) to a ~(15..38) gradient matching the skylight
  fall-off as the camera looks into the shaft.
- `tests/glowstone_cave.tas` + `tests/glowstone_cave.sh` — phase-3 block
  light regression. TAS digs a small flatland pit and right-clicks once.
  runner captures two frames (`--place-block=stone` baseline vs
  `--place-block=glowstone`) and asserts four brightness bboxes: core
  (glowstone face, glow lum ≈146 vs stone 34), wall near (lum ≈120 vs
  42), wall rim at ~distance-4 (lum ≈44 vs 15), and far grass (unchanged
  — verifies block light did NOT leak beyond the BFS radius or across
  chunk boundaries). Run with `./examples/voxel/tests/glowstone_cave.sh`
  (or `--skip-build` to reuse an existing binary).

New regression TAS scripts should go in `examples/voxel/tests/` with a comment
block at the top documenting the purpose, usage, and baseline numbers.

---

## Voxel Demo — Anti-Aliasing

Theory (MSAA vs FXAA for voxels, olive-edge explanation, FXAA impl architecture,
pixel-diff baselines): [`docs/antialiasing.md`](docs/antialiasing.md).
Regenerating the diffs / refreshing the doc's embedded PNGs:
`./examples/voxel/tests/aa_regression.sh [--output-dir docs/assets]`.

---

## Voxel Demo — Chunk Pipeline

One chunk scheduler (`libs/sw_voxel/src/pipeline/scheduler.zig`) loads chunks
on every platform. It runs in the frame phase (`voxelFrame`), never in a
tick. Workers own the world (C4): native runs the ThreadPool executor
(`pipeline/exec_threads.zig`, `--chunk-workers=N`), and the web build runs
the WorkerPool executor (`pipeline/exec_web.zig`): Web Workers that run
`chunks.wasm`. The Inline executor (`pipeline/exec_inline.zig`) is the
fallback when no worker runs. All messages are the bytes of
`pipeline/protocol.zig` (P6). Main keeps blocks only for the prefetch
radius (2 chunks) and no light. Design, protocol layout, "ready", budgets
and numbers:
[`examples/voxel/docs/chunk-pipeline.md`](examples/voxel/docs/chunk-pipeline.md).

Web Worker pool rules (C9):

- `zig build web -Dexample=voxel` writes `app.wasm` and `chunks.wasm`. The
  only wasm imports of `chunks.wasm` are `env.jsGetTime` and `env.jsLog`.
  Do not import a WebGPU function into it.
- Both files export the protocol version, the build hash and the build id
  (a hash of the `.zig` files under `examples/voxel` and `libs/sw_voxel`,
  from `build.zig`).
  The pool starts only when the three values are equal.
- `apps/minecraft.seanmizen.com/bundle.sh` in seanorepo gives the chunk files
  content-hashed names. Each deploy file must be in `bundle.sh`, the
  dockerfile and `serve.json`.
- `bun test backends/wasm/worker-pool.test.ts` runs the pool with real
  Bun Web Workers. Run it 10 times after a change to the pool, to look
  for races.

Mesh bytes (C5):

- Main never copies the quads of a mesh. JS holds each worker result
  (`backends/wasm/held-bytes.ts`), and `app.wasm` copies only its first 64
  bytes. The render writes a mesh to the GPU from the held ArrayBuffer
  (`gpu.writeBufferHeld`), then releases it. Native executors upload from
  the reply bytes (`pipeline/mesh_bytes.zig`).
- Do not read the quads of a mesh on main. Use `LoadedChunk.mesh`
  (`MeshInfo`). The tests compare meshes by the mesh hash of the worker.
- A chunk keeps its GPU quad buffer for a new mesh that fits. Evicted
  buffers go to `QuadBufferPool` (`main.zig`).
- `checkMeshUploads` (`headless-app.ts`) and the memory test of
  `worker-pool.test.ts` prove it in CI.

---

## Voxel Demo — Lighting

Why caves are dark: per-chunk skylight propagation, baked per-vertex at mesh
time, multiplied with AO and direct light in the shader. Design + algorithm +
phase-1 limitations (no cross-chunk seams, no relight on dig):
[`examples/voxel/docs/lighting.md`](examples/voxel/docs/lighting.md).

---

## Voxel Demo — GPU Debug System

Shows which chunks got a new mesh: the shader tints the chunk orange, and the tint
fades in about 0.5 s.

**Data path:**
- `State.debug_tick` (main.zig) is the debug clock. It advances one step per
  tick. In TAS step mode it advances only on executing ticks, so the tint
  stays between steps.
- `uploadChunkMesh` writes the clock value into `ChunkGPU.rebuilt_tick`
  when the mesh is new. The 16-byte header of the quad buffer holds it:
  (origin x, rebuilt tick, origin z, 0).
- The uniforms hold `debug_tick`: the clock when GPU debug is on, 0 when off.
- `rebuildTint` in `voxel.wgsl` gives `(255 - 4 × age) / 255` for an age of
  0 to 63 ticks, else 0. `fs_main` mixes orange `vec3(1.0, 0.5, 0.1)` with
  the base colour.

**Key design choices:**
- One value for each chunk, not one value for each quad. The mesher output
  has no debug data.
- No upload for the fade: the shader calculates it from the two ticks.
- With GPU debug off, the tint is 0 and the frame does not change.

---

## macOS Trackpad Click Latency

**Summary: our code already does the right thing. The remaining lag is macOS, not us.**

Symptom: trackpad clicks in the voxel demo feel sluggish. Clicking to break a
block has a perceptible delay. It looks like a frame drop but it isn't.

### What's actually happening

macOS adds a system-level delay (typically **80–120 ms**) between your finger
hitting the trackpad and the OS dispatching `NSEventTypeLeftMouseDown` to the
application. The OS uses that window to disambiguate the press from:

- a **double-tap** (synthesised double-click)
- a **two-finger tap** (right-click / secondary click)
- a **drag start** (tap-and-hold-then-move)
- a **Force Touch** pressure threshold (on Force Touch trackpads, the click is
  pressure-driven and has its own hardware-side delay)

SDL2 receives the `mouseDown` from Cocoa and immediately surfaces it as
`SDL_MOUSEBUTTONDOWN`. We forward that into the event bus on the same poll
tick. There is no extra latency added by swindowzig — verified by reading
`libs/sw_platform/src/native_sdl.zig:158` (the SDL→bus pump) and
`libs/sw_app/src/app.zig:130` (the main loop polls events at the start of every
iteration, before the tick).

### Why our code is already optimal

Every mouse interaction in the voxel demo uses `input.buttonPressed(.left)` —
the **down edge** — not `buttonReleased`:

- `examples/voxel/main.zig:648` — pause-menu Resume button
- `examples/voxel/main.zig:659` — pause-menu Quit button
- `examples/voxel/main.zig:677` — click-to-recapture-mouse after Esc
- `examples/voxel/main.zig:754` — break block
- `examples/voxel/main.zig:783` — place block

Switching any of these to release-edge would add another full click-duration of
perceived latency. We already act the moment SDL hands us a `mouseDown`.

### Things that DO NOT help

Investigated and ruled out (web search + SDL2 wiki + reading the SDL Cocoa
backend):

- `SDL_HINT_MOUSE_DOUBLE_CLICK_TIME` — only affects how SDL flags `clicks=2`
  on the *second* click. It does not delay the first click.
- `SDL_HINT_TRACKPAD_IS_TOUCH_ONLY=1` — would route trackpad input as
  multitouch events instead of mouse events. We could synthesise our own
  "click" from `SDL_FINGERDOWN`, which arrives ~30–50 ms earlier than the
  synthesised mouseDown. **But it disables mouse-cursor synthesis from the
  trackpad entirely**, breaking the FPS mouse-look path. Non-starter for the
  voxel demo. Worth revisiting only if we ever build a touch-first UI.
- Polling SDL events more than once per main-loop iteration — our poll-tick-
  render order is already minimal. The bottleneck is the OS dispatch, not the
  poll cadence.

### Things that DO help (a little)

- `SDL_HINT_MOUSE_FOCUS_CLICKTHROUGH=1` — set in `native_sdl.zig:23` before
  `SDL_Init`. Lets a click that focuses an unfocused window also fire a normal
  `mouseDown`, instead of being swallowed as a focus-only click. Saves one
  click after alt-tabbing back into the game.
- **Disable tap-to-click in macOS System Settings → Trackpad** (or specifically
  turn off "Smart Zoom" and "Look up & data detectors"). This removes most of
  the disambiguation window. If the user wants the snappiest possible feel, a
  physical click (or a real mouse) is unavoidably faster than tap-to-click.
- Run on a 120 Hz display if possible — our tick rate is 120 Hz already, so
  the internal pipeline latency is ~8 ms. The visible portion is dominated by
  vsync.

### TAS replay determinism

Press-vs-release semantics are recorded as separate events
(`event.payload.pointer_button.down = true | false`) in `sw_core/src/tas.zig`.
Both edges are persisted in `.tas` scripts, so swapping our gameplay logic
between press and release does not affect what gets *recorded*, only when our
game-state code reacts to a recorded event. Since we have always acted on the
press edge, no existing `.tas` script needs updating.

---

## Game state and layers

- `game_state.zig` holds pure state logic with no GPU dependencies, and a fixed
  `[8]Layer` array.
- `overlay.zig` is a 2D alpha-blended pipeline. `ensurePipeline` creates it on
  first use. Each frame calls `begin`, then `rect`, then `draw`.
- Alpha blending on the native path in `gpu.zig`: allocate `[8]WGPUBlendState`
  on the stack, and set the pointer before you create the pipeline.
- Input gating: `gameplayReceivesInput()` blocks WASD and mouse look while the
  pause menu is open.
- Take the `was_captured` snapshot before the global key handling. This stops
  the camera jumping on the tick the game resumes.

---

## File Map

### Voxel example (`examples/voxel/`)

Chunk dimensions: **CHUNK_W = 16** (X/Z), **CHUNK_H = content.height**
(Y, 256 in the demo). A column is CHUNK_H / 16 paletted sections of
16 × 16 × 16 cells (`section.zig`). CHUNK_W was 48 on
main prior to April 2026. Flipped on `voxel/chunk-size-perf` — see
[`docs/chunk-size-investigation.md`](examples/voxel/docs/chunk-size-investigation.md)
for the experiment and "why MC's 16×16 is the right default" writeup.

| File | Purpose |
|------|---------|
| `main.zig` | Entry point, TAS wiring, render loop, pause menu, debug overlay, loading screen, `resolveSpawnPos`/`doRespawn` |
| `content.zig` | The demo content for sw_voxel: `Block` enum, `emission`, `GenConfig` bytes, `generate` (the terrain fill, glowstone, caves and trees) |
| `world_gen.zig` | Procedural terrain, `Preset` enum (flatland / hilly), `presetConfig()`, value-noise `sampleHeight` |
| `chunks_wasm.zig` | The root of `chunks.wasm`. It calls `sw_voxel.chunk_worker.exportFunctions` with the build id (C9) |
| `stages_test.zig`, `scheduler_test.zig`, `protocol_test.zig`, `exec_test.zig`, `world_test.zig` | sw_voxel tests on the demo world (`test_recompute.zig` is their helper) |
| `shader_test.zig` | The corner constants of `voxel.wgsl` match `sw_voxel.mesher.cornerBits` |
| `camera.zig` | FPS camera, view/projection matrices |
| `player.zig` | Movement, gravity, collision |
| `raycast.zig` | Block-face hit test for place/destroy |
| `overlay.zig` | `OverlayRenderer` — 2D alpha-blended quad pipeline for HUD |
| `bitmap_font.zig` | 5×7 glyph table + `drawText`/`drawStepHud` helpers |
| `game_state.zig` | Pure-state struct (no GPU deps), shared across files |
| `keyboard_hud.zig` | On-screen keyboard layout diagram |
| `voxel.wgsl` | Voxel vertex+fragment shader, `PackedQuad` decode, GPU debug tint |
| `libs/sw_gpu/src/fxaa.wgsl` | FXAA 3.11 post-process shader, fullscreen triangle VS + luminance-based edge search FS |
| `terrain_hash.zig` | Block hash of a 9×9 hilly area for a seed. Native CLI and tests. `terrain_hash_wasm.zig` is the wasm root, and `scripts/terrain_hash_wasm.mjs` runs it in Node or Bun |
| `framespike.tas` | TAS script used by the mandatory headless regression test |
| `tests/msaa_flatland.tas` | MSAA regression test — flatland, block-remove, camera pan |

### sw_voxel (`libs/sw_voxel/src/`)

| File | Purpose |
|------|---------|
| `sw_voxel.zig` | The module root. It names each file below |
| `content.zig` | The content contract: what the game module `sw_voxel_content` must declare |
| `section.zig` | `Section`: 16 × 16 × 16 cells, a palette and indices of 0, 1, 2, 4 or 8 bits. One block type has no index array |
| `chunk.zig` | `Chunk`: `PalettedBlocks` (a column of sections), skylight, block light (`LightGrid`), `setBlock`/`getBlock`, `lightAt`, `generateTerrain` (calls `content.generate`). `CHUNK_H` and `MIN_Y` come from the content |
| `light.zig` | The light rules: opacity and emission tables, `CellLight`, the incremental update (`update`, `Region`) |
| `world.zig` | Multi-chunk world, chunk map, chunk versions, `World.init(allocator, gen_config, render_distance)` |
| `mesher.zig` | Greedy quad mesher and model mesher (writes `PackedQuad` and model quad records), `cornerBits` for a shader |
| `model.zig` | `BakedQuad`, `BakedModel`, the `box` and `rotateY` helpers, `GpuQuad` (the GPU format of a baked quad) |
| `models.zig` | The models of the content as comptime tables: `isCube`, `hasModel`, `quads`, `gpu_table` |
| `region.zig` | Region files: 16 × 16 chunks, each compressed (zlib), with an offset table and a format version. `Store(sw_assets.cache)` saves and loads them. The file has no light (REQ-VOXEL-011 to 013) |
| `frustum.zig` | Chunk cull strategies: none, sphere, cone, frustum |
| `clock.zig` | Monotonic clock for the perf logs. main sets `clock.io` |
| `pipeline/stages.zig` | The pure chunk stages: generate, light, mesh (C2), and versions (C3) |
| `pipeline/scheduler.zig` | The chunk scheduler: desired state, priority, version checks, eviction, edits (C8) |
| `pipeline/exec_inline.zig` | The Inline executor: one in-process worker on the main thread, within a frame budget (C7) |
| `pipeline/exec_threads.zig` | The ThreadPool executor: native worker threads, spatial affinity, install budget (C4, C9) |
| `pipeline/exec_web.zig` | The WorkerPool executor: the main side of the Web Worker pool, through the "chunks" imports (C9) |
| `pipeline/chunk_worker_main.zig` | The exports of `chunks.wasm` (`exportFunctions`), the chunk worker of the web build (C9) |
| `pipeline/worker_world.zig` | The world of a chunk worker: seed, edit log, LRU cache with a memory limit (C4, C14). Builds for wasm32 |
| `pipeline/protocol.zig` | The chunk protocol: Hello, Edit, Job, Result, Error bytes (P6) |
| `pipeline/mesh_bytes.zig` | The quad bytes of a mesh result until the GPU upload: in main memory, or held by JS (C5) |
