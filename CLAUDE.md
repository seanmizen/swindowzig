# swindowzig - Claude Guide

> **Docs policy.** Operational command sequences (>5 steps) → executable script under
> `examples/voxel/tests/*.sh`. Deep reference material (>20 lines on one topic) →
> `docs/<topic>.md`. Both cases: leave a ≤3-line breadcrumb in CLAUDE.md pointing
> at the real artifact. Do NOT inline heavy reference or long command runs directly
> into CLAUDE.md — it is loaded into every agent's context and the budget is finite.

---

## Build Commands

```bash
# Default example (justabox spinning box)
zig build run

# Specific example
zig build run -Dexample=voxel
zig build run -Dexample=windows

# Compile only (default example is justabox)
zig build native -Dexample=voxel

# Clean build (fixes mysterious segfaults from stale cache)
rm -rf zig-out zig-cache .zig-cache && zig build native -Dexample=voxel

# Web (WASM)
zig build web
bun backends/wasm/dev-server.ts
```

---

## Project Structure

```
swindowzig/
├── libs/
│   ├── sw_core/        # Timeline, events, input, record/replay
│   ├── sw_platform/    # SDL2 (native) + canvas (web)
│   ├── sw_app/         # Entry point — run() function + Context
│   ├── sw_gpu/         # WebGPU wrapper (active development)
│   │   ├── gpu.zig              # Main API — GPU struct, all create* methods
│   │   ├── native_webgpu.zig    # C bindings for wgpu-native
│   │   ├── types.zig            # Shared descriptor types
│   │   └── web_bridge.zig       # WASM JS bindings
│   └── sw_math/        # Vec3, Mat4, perspective(), lookAt()
├── examples/
│   ├── justabox/       # Default: single spinning colored box
│   ├── windows/        # Triangle with mouse drag
│   └── voxel/          # Voxel chunk demo (48×256×48)
└── backends/
    └── wasm/           # Web platform boot + dev server
```

---

## Critical Lessons

### extern struct initialization (CRITICAL)
Always `std.mem.zeroes()` for extern structs passed to C APIs — aggregate init
does NOT apply default field values:
```zig
// WRONG — padding and optional fields are undefined
const desc = WGPUFooDescriptor{ .field = value };

// CORRECT
var desc = std.mem.zeroes(WGPUFooDescriptor);
desc.field = value;
```

### IndexFormat enum mismatch (fixed in gpu.zig)
`types.IndexFormat` starts at 0, but native `WGPUIndexFormat` has `undefined=0`,
`uint16=1`, `uint32=2`. The `setIndexBuffer` wrapper now uses an explicit switch
to map correctly. Do not use raw `@intFromEnum` for this conversion.

### TextureViewDimension enum mismatch (fixed in gpu.zig — createBindGroupLayout)
`types.TextureViewDimension` starts at 0 (`@"1d"=0, @"2d"=1`), but native
`WGPUTextureViewDimension` has `undefined=0, 1d=1, 2d=2`. Raw `@intFromEnum`
would map `.@"2d"→1` which is `WGPUTextureViewDimension.1d` — wrong, crashes
with "Texture binding N expects dimension = D1, but given a view with dimension = D2".
`createBindGroupLayout` now uses explicit switch maps for both `.texture.view_dimension`
and `.storage_texture.view_dimension`. Do not use raw `@intFromEnum` for these.

### Hardware depth testing (macOS/Metal)
`wgpuDeviceCreateRenderPipeline` crashes (bus error at 0x29) when depth stencil
is enabled — wgpu-native v0.19.4.1 bug on Metal. **Workaround: painter's
algorithm** (sort quads back-to-front in software before uploading index buffer).
See `examples/voxel/mesher.zig` `sortByDepth()`.

### Voxel face winding (fixed in mesher.zig)
+Y, -Y, +Z, -Z faces had CW winding (inside-out). Fixed by reversing vertex
order so geometric normal matches the intended outward face normal. +X and -X
were already correct.

### Zig 0.15.2 ArrayList API
```zig
var list = std.ArrayList(T){};           // init (no allocator arg)
try list.append(allocator, item);        // pass allocator per-op
list.deinit(allocator);
```

### Incremental mesh update (voxel/mesher.zig)
Full `generateMesh` scans 27,648 blocks — O(chunk_volume). For block add/remove,
only 7 blocks are affected (changed block + 6 neighbours). Use `updateForBlockChange`:

```zig
// After chunk.setBlock(bx, by, bz, .air):
mesh.updateForBlockChange(&chunk, bx, by, bz, camera_pos) catch {
    mesh_dirty = true; // fallback to full regen
};
mesh_incremental_dirty = true; // GPU buffers need recreation
```

**How it works:**
- `quad_block: ArrayList(u32)` — parallel array tracking which block owns each quad
- `swapRemoveQuad(qi)` — O(1) removal: moves last quad into slot `qi`, rewrites its 6 indices
- Collects affected quads via linear scan of `quad_block` (~6k entries), removes them, re-meshes 7 blocks
- Maintains `sort_scratch` through the update so `sortByDepth` uses insertion sort (O(n)) instead of pdqsort (O(n log n)) on the next frame. Scratch is compacted by filtering entries with `.idx >= new_quad_count`, then new entries are appended with computed distances. Scratch is grown with +64 headroom when quad count increases.

**Measured improvement (48×256×48 chunk, ~6144 quads):**
- Before: 3891µs (mesh 2308 + sort 1341 + upload 242)
- After: ~840µs (tick update 210 + sort 565 + upload 280) — **78% reduction**

**`sortByDepth` latent bug fixed:** after scratch reallocation, must set `sort_valid = false`
(previously, growing scratch left it with garbage values but sort_valid could still be true).

---

## Common Crashes

**Bus error / segfault in render pass or pipeline creation**
→ `extern struct` has uninitialized fields. Use `std.mem.zeroes()`.

**`invalid index format: 0`**
→ Passing `IndexFormat.uint16` (value 0) raw to native; use the named switch
in `gpu.zig:setIndexBuffer`.

**`CommandBuffer cannot be destroyed because still in use`**
→ Missing `wgpuDevicePoll()` after submit, or missing `release()` calls.

---

## Voxel Demo — Development Principles

**No function keys.** Do not use F1–F12 for any gameplay or debug feature in the voxel demo.
Function keys are excluded from the keyboard HUD and are not a reliable cross-platform input.
Use letter/modifier combos (e.g. Cmd+D, Cmd+G, Cmd+T) instead.

---

## Voxel Demo — CLI Flags

| Flag | Description |
|------|-------------|
| `--tas <path>` | Load and play a TAS script. Physical input blocked during playback. |
| `--headless` | No window, no GPU. Ticks unlimited speed. Exits when TAS finishes. |
| `--tas-step` | Frame-by-frame TAS stepping. Right arrow = advance one TAS tick. Implies `--gpu-debug`. |
| `--gpu-debug` | Highlight freshly rebuilt mesh faces (orange tint, fades ~0.5s). Also toggled with Cmd+G / Ctrl+G at runtime. |
| `--aa=<mode>` | Anti-aliasing method. Accepted: `none`, `msaa` (default, 4× MSAA), `fxaa` (FXAA 3.11 post-process). `--aa=fxaa` renders the scene to an offscreen bgra8unorm texture then runs a fullscreen FXAA pass to the swapchain. Can be combined with `--msaa=N` to control the MSAA sample count when `--aa=msaa` is active. |
| `--msaa=N` | MSAA sample count. Accepted: `none`/`0` (no AA), `1`, `2`, `4` (default), `8`. The `bgra8unorm` surface format supports [1, 2, 4] on native and [1, 4] on WebGPU; values outside that range are clamped (e.g. `--msaa=8` → 4×). |
| `--world=<preset>` | Worldgen preset. Accepted: `flatland` (flat Y=63), `hilly` (default — procedural noise terrain). |
| `--ao=<mode>` | Ambient-occlusion sampler. Accepted: `none` (no AO, full brightness), `classic` (default — per-vertex Mojang face-plane AO), `moore` (extended sampler that adds the outward+2 slab at half weight to darken indoor corners). `propagated` and `ssao` are reserved enum values that fall back to `classic` with a one-shot warning. Read at startup only — runtime changes (future settings menu) require remeshing all loaded chunks. |
| `--lighting=<mode>` | World-lighting mode for the mesher. Accepted: `none` (every face fully lit by sky — A baseline for the cave-darkness regression) and `skylight` (default — per-chunk skylight propagation; caves and overhangs go dark). Skylight is baked per-vertex at mesh time, so the in-game settings menu picker remeshes every loaded chunk on toggle. Digging or placing a block triggers a full-chunk `computeSkylight()` + `computeBlockLight()` + mesh regen. See `examples/voxel/docs/lighting.md` for the algorithm and phase 3 (block light / glowstone) design. |
| `--meshing=<mode>` | Mesher strategy. Accepted: `naive` (one quad per visible block face — preserves the `quad_block` parallel-array invariant used by `updateForBlockChange`) and `greedy` (default — coplanar same-material + uniform-AO/skylight faces merged into larger rectangles, ~35× reduction on flatland, ~3× on hilly). Greedy quads span multiple blocks so `updateForBlockChange` can't patch them; dig/place events flag the chunk `mesh_dirty = true` for next-tick full regen. Merge dimension capped at 6 blocks to stay within the painter's-algorithm sort tolerance (see `examples/voxel/docs/memory.md` §Rank 5). |
| `--place-block=<type>` | Block type emitted by right-click placement. Accepted: `stone` (default) and `glowstone`. Added with phase-3 block light so `tests/glowstone_cave.tas` can place an emitter from a TAS without needing an in-game block picker UI. |
| `--dump-frame=<path>` | Capture one rendered frame to a PPM file, then exit. Waits for world loading to complete; if a TAS is running, waits for TAS to finish (so MSAA comparison runs capture the same deterministic state). |
| `--frustum=<mode>` | Per-chunk cull strategy. Accepted: `none` (default — opt-in feature, draw every loaded chunk), `sphere` (radial cutoff at render_distance + slack; cheap sanity backstop), `cone` (sphere-vs-cone test against the camera forward, fov controlled by `--frustum-fov-deg`). The chunk the camera sits in plus its 8 horizontal neighbours are NEVER culled regardless of strategy — see `examples/voxel/frustum.zig` for the math notes and edge-case tests. Cmd+F (Ctrl+F on Win/Linux) freezes the live frustum at its current transform so you can fly around and see what got culled. Settings menu has a live picker for the strategy. |
| `--frustum-fov-deg=<degrees>` | Total fov of the cone strategy in degrees. Default 180° (a deliberate no-op short-circuit so an accidental `--frustum=cone` cannot drop chunks before the user tightens the fov). Range [0, 360]. Half-angle ≥ 90° always returns true. |

---

## Voxel Demo — World Loading & Spawn

**Loading screen** (`main.zig:renderLoadingScreen`): on first launch, the render
loop shows a dark purple background with animated wavy strips and a centred
"WORLD LOADING!!!" title. The screen remains until the spawn chunk is generated
*and* its mesh is built (`state.world_loading = false`). While loading, `voxelTick`
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

TAS scripts for regression live under `examples/voxel/`:
- `framespike.tas` — block-removal during camera pan (hilly world). Mandatory
  headless test (see below).
- `tests/msaa_flatland.tas` — deterministic flatland scene used by the AA
  regression. Runner: `./examples/voxel/tests/aa_regression.sh` (captures
  none/fxaa/msaa4, writes both normalized and amplified diffs, prints coverage).
- `tests/ao_corners.tas` — flatland 1×4×1 shaft, used to verify
  `--ao=none|classic|moore` strategies darken the indoor wall faces of the
  shaft progressively. The Moore-vs-classic diff is small in this scene
  (~0.7% of frame, max delta ~8) because the shaft is small; on the hilly
  default world Moore differs from classic across ~70% of pixels with a
  mean channel delta of ~5/255 — that's the "more grounded" look.
- `tests/cave_skylight.tas` — flatland 1×6×1 shaft, used to verify
  `--lighting=none|skylight` darkens the dug interior. Baselines:
  flatland → 10.65% pixels differ, mean Δ 3.91/255, max Δ 105/255 (the
  affected pixels are exactly the cave interior; sky region unchanged).
  Hilly → 97.5% pixels differ, mean Δ 19.78/255, max Δ 105/255 (almost
  every face shifts because hilly terrain has overhangs everywhere).
- `tests/frustum_look_down.tas` — flatland, pitches the camera into the
  -π/2 + 0.01 clamp, used to verify the frustum cull never blanks the
  ground when looking straight down. Pass criterion is that
  `--frustum=cone --frustum-fov-deg=30` and `--frustum=none` produce
  byte-identical PPMs (the camera-inside-bounding-sphere shortcut and the
  3×3 camera-neighbourhood safety net both fire). Mean brightness ≈ 103/255
  on the default flatland scene; "black" would be < 5/255.
- `tests/greedy_vs_naive.tas` + `tests/greedy_vs_naive.sh` — captures the
  same flatland pit scene under `--meshing=naive` and `--meshing=greedy`
  and runs an RMS diff; asserts `< 2/255` per channel (greedy is within
  0.65/255 at the current cap=6 setting). Used to guard the painter's-sort
  cap in `examples/voxel/mesher.zig` — bumping the cap too high causes
  visible sort inversions against pit walls and this test catches them.
- `tests/dig_relight.tas` — flatland small pit (4 dig clicks from a
  steep pitch-clamped look-down), used to verify `World.setBlock` now
  recomputes chunk skylight on dig. Diff vs. a local branch that
  disables the relight call: ~22% pixels differ, mean Δ ~25/255, max
  Δ ~52/255 — the affected pixels are exactly the pit interior, which
  goes from RGB ~(2,2,1) to a ~(15..38) gradient matching the skylight
  fall-off as the camera looks into the shaft.
- `tests/glowstone_cave.tas` + `tests/glowstone_cave.sh` — phase-3 block
  light regression. TAS digs a small flatland pit and right-clicks once;
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

## Voxel Demo — Lighting

Why caves are dark: per-chunk skylight propagation, baked per-vertex at mesh
time, multiplied with AO and direct light in the shader. Design + algorithm +
phase-1 limitations (no cross-chunk seams, no relight on dig):
[`examples/voxel/docs/lighting.md`](examples/voxel/docs/lighting.md).

---

## Voxel Demo — GPU Debug System

Tracks which mesh quads were rebuilt and visualises them with an orange tint.

**Data path:**
- `mesher.zig: quad_highlight: ArrayList(u8)` — parallel to `quad_block`, intensity 0–255 per quad
- `addQuad(..., highlight)` — new quads start at 255 (incremental rebuild and full rebuild)
- `swapRemoveQuad` — keeps `quad_highlight` in sync with other parallel arrays
- `decayHighlights(amount)` — saturating subtract each tick (amount=4 → ~60 ticks / 0.5s fade)
- `uploadMeshToGPU` — encodes highlight into upper 8 bits of `block_type` u32 at GPU upload time, restores after
- `voxel.wgsl` — shader extracts `(block_type >> 16) & 0xFF`, mixes orange `vec3(1.0, 0.5, 0.1)` with base colour

**Key design choices:**
- Piggybacks on existing `block_type: u32` (only uses lower 8 bits) — no vertex layout changes
- Zero overhead when off: highlights are 0, shader multiplies by 0, vertex re-upload skipped
- In TAS step mode, highlights only decay on executing ticks (persists between steps)

---

## macOS Trackpad Click Latency

**TL;DR — our code already does the right thing. The remaining lag is macOS, not us.**

Symptom: trackpad clicks in the voxel demo feel sluggish; clicking to break a
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
  on the *second* click; it does not delay the first click.
- `SDL_HINT_TRACKPAD_IS_TOUCH_ONLY=1` — would route trackpad input as
  multitouch events instead of mouse events. We could synthesise our own
  "click" from `SDL_FINGERDOWN`, which arrives ~30–50 ms earlier than the
  synthesised mouseDown. **But it disables mouse-cursor synthesis from the
  trackpad entirely**, breaking the FPS mouse-look path. Non-starter for the
  voxel demo. Worth revisiting only if we ever build a touch-first UI.
- Polling SDL events more than once per main-loop iteration — our poll-tick-
  render order is already minimal; the bottleneck is the OS dispatch, not the
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
  the internal pipeline latency is ~8 ms; the visible portion is dominated by
  vsync.

### TAS replay determinism

Press-vs-release semantics are recorded as separate events
(`event.payload.pointer_button.down = true | false`) in `sw_core/src/tas.zig`.
Both edges are persisted in `.tas` scripts, so swapping our gameplay logic
between press and release does not affect what gets *recorded*, only when our
game-state code reacts to a recorded event. Since we have always acted on the
press edge, no existing `.tas` script needs updating.

---

## Voxel Demo — Mandatory Testing

**Before handing any voxel changes back to the user, ALL three checks must pass:**

```bash
# 1. Clean compile
zig build native -Dexample=voxel

# 2. Headless TAS run — must exit 0
./zig-out/bin/voxel --headless --tas examples/voxel/framespike.tas

# 3. GPU smoke test — must not crash within 5 seconds
timeout 5 ./zig-out/bin/voxel 2>&1 | grep -v "^\[" | head -20
```

Do **NOT** hand changes back until all three pass. The GPU smoke test catches wgpu validation
errors (buffer overruns, bad descriptors) that only appear when the renderer actually runs.

---

## Adding New WebGPU Features

1. Check wgpu-native headers: `~/.local/include/webgpu/webgpu.h`
2. Add C binding to `native_webgpu.zig`
3. Add Zig wrapper in `gpu.zig`
4. Add corresponding web path in `web_bridge.zig`
5. Release anything you create (wgpu uses reference counting)

---

## File Map

Key files and what they do — read this before opening anything.

### Core libraries (`libs/`)

| File | Purpose |
|------|---------|
| `libs/sw_app/src/app.zig` | `sw.run()` entry point; owns the main loop |
| `libs/sw_app/src/context.zig` | `Context` passed to every callback; holds allocator, bus, tick info |
| `libs/sw_core/src/event.zig` | `Event` union — all input/system event variants |
| `libs/sw_core/src/bus.zig` | Event bus: push/subscribe per tick |
| `libs/sw_core/src/input.zig` | Keyboard/mouse snapshot, edge detection |
| `libs/sw_core/src/record.zig` | Record events to a TAS file |
| `libs/sw_core/src/replay.zig` | Replay events from a TAS file |
| `libs/sw_core/src/tas.zig` | TAS file format (parse/write) |
| `libs/sw_gpu/src/gpu.zig` | Main GPU API — `GPU` struct, all `create*` / `begin*` / `submit` methods |
| `libs/sw_gpu/src/native_webgpu.zig` | Raw C bindings for wgpu-native (`WGPUFoo` types) |
| `libs/sw_gpu/src/types.zig` | Shared descriptor types used by both native and WASM paths |
| `libs/sw_gpu/src/web_bridge.zig` | WASM/JS extern bindings |
| `libs/sw_platform/src/native_sdl.zig` | SDL2 window + event pump (native path) |
| `libs/sw_math/src/mat4.zig` | 4×4 matrix: `perspective()`, `lookAt()`, multiply |
| `libs/sw_math/src/vec3.zig` | Vec3 ops |

### Voxel example (`examples/voxel/`)

Chunk dimensions: **CHUNK_W = 48** (X/Z), **CHUNK_H = 256** (Y).

| File | Purpose |
|------|---------|
| `main.zig` | Entry point, TAS wiring, render loop, pause menu, debug overlay, loading screen, `resolveSpawnPos`/`doRespawn` |
| `chunk.zig` | `Chunk` struct; `BlockType` enum; `setBlock`/`getBlock`; world-gen call |
| `world.zig` | Multi-chunk world; chunk map; load/unload; `World.init(allocator, preset)` |
| `world_gen.zig` | Procedural terrain; `Preset` enum (flatland / hilly); `presetConfig()`; value-noise `sampleHeight` |
| `mesher.zig` | Greedy quad mesher; incremental `updateForBlockChange`; `sortByDepth` |
| `camera.zig` | FPS camera; view/projection matrices |
| `player.zig` | Movement, gravity, collision |
| `raycast.zig` | Block-face hit test for place/destroy |
| `overlay.zig` | `OverlayRenderer` — 2D alpha-blended quad pipeline for HUD |
| `bitmap_font.zig` | 5×7 glyph table + `drawText`/`drawStepHud` helpers |
| `game_state.zig` | Pure-state struct (no GPU deps); shared across files |
| `keyboard_hud.zig` | On-screen keyboard layout diagram |
| `voxel.wgsl` | Voxel vertex+fragment shader; GPU debug highlight decode |
| `libs/sw_gpu/src/fxaa.wgsl` | FXAA 3.11 post-process shader; fullscreen triangle VS + luminance-based edge search FS |
| `framespike.tas` | TAS script used by the mandatory headless regression test |
| `tests/msaa_flatland.tas` | MSAA regression test — flatland, block-remove, camera pan |
