# swindowzig - Claude Guide

> **Docs policy: CLAUDE.md and README.md only. Never create additional markdown files.**

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
| `--dump-frame=<path>` | Capture one rendered frame to a PPM file, then exit. Waits for world loading to complete; if a TAS is running, waits for TAS to finish (so MSAA comparison runs capture the same deterministic state). |

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
- `tests/msaa_flatland.tas` — MSAA regression test on flatland. Usage:
  ```bash
  ./zig-out/bin/voxel --world=flatland --msaa=none \
    --tas examples/voxel/tests/msaa_flatland.tas --dump-frame=/tmp/a.ppm
  ./zig-out/bin/voxel --world=flatland --msaa=4 \
    --tas examples/voxel/tests/msaa_flatland.tas --dump-frame=/tmp/b.ppm
  ```
  Then pixel-diff `a.ppm` vs `b.ppm`. Baseline (2026-04-11): 3.42% differing pixels,
  max channel delta = 67, 13,570 channels with diff ≥ 5 — the MSAA signature is
  unambiguous (vs hilly's max delta = 1).

New regression TAS scripts should go in `examples/voxel/tests/` with a comment
block at the top documenting the purpose, usage, and baseline numbers.

---

## Voxel Demo — Anti-Aliasing Analysis

### What MSAA can and cannot do for voxel worlds

MSAA (multi-sample anti-aliasing) works at the **rasterizer** level: it fires
multiple sub-pixel samples per pixel and averages them. It only produces
intermediate colours at **geometry silhouette edges** — pixels that straddle
two different triangles. This means:

- ✅ **Outer silhouette edges** (block geometry vs sky/fog): MSAA averages the
  block colour with the background. Visible as a 1-pixel-wide blend strip.
- ❌ **Block-on-block interior edges** (two adjacent opaque blocks touching):
  both triangle sides are solid geometry at the same/close depth. All 4× sub-
  samples hit geometry, so the coverage fraction is 0% or 100%. No blending.

For a voxel world, the vast majority of visible edges are block-on-block
interior edges (flat terrain faces, cliff faces, etc.). Only the outermost
silhouette edges get smoothed. In practice, 4× MSAA on a voxel world affects
**~3% of pixels** in a typical scene.

### Why the edge looks olive/green ("green through the gaps")

The specific effect Sean noticed (2026-04-11) is **correct MSAA behaviour**,
not a bug:

- The test scene has grass-top blocks (bright green, ~`RGB(102, 131, 36)` in
  sRGB) next to a dug hole. The hole's side faces are near-black due to
  maximum AO: `RGB(38, 4, 4)`.
- At the diagonal silhouette of the terrain edge, a pixel at the boundary row
  has 2/4 sub-samples hitting the grass-top and 2/4 hitting the dark side face.
  The blend is `(102+38)/2, (131+4)/2, (36+4)/2` ≈ `(72, 71, 21)` — olive.
- Without MSAA, the centre sample decides: one side gets solid green, the other
  solid near-black, with a hard aliased step between them.
- The olive/muddy blend looks garish because the AO floor (`0.4 + ao * 0.6`)
  combined with ambient+diffuse lighting drops occluded side faces to near-black
  while the lit grass top is fully saturated green. The extreme contrast makes
  the sub-pixel blend traverse a wide colour space.

**This is not a mesh gap.** The mesher uses `@floatFromInt(world_coord)` for
all vertex positions; IEEE 754 f32 is exact for integers ≤ 2²³, so adjacent
faces share mathematically identical coordinates. No subpixel cracks exist.

### Recommendation: FXAA for broader coverage

For voxel graphics, **FXAA** (Fast Approximate Anti-Aliasing) gives a much
more visible improvement than MSAA:

- Works as a post-process pass on the final colour image.
- Detects luminance discontinuities in screen space — catches ALL colour edges,
  including block-on-block interior edges that MSAA cannot touch.
- Cost: one extra screen-space pass (cheap; runs at 1 sample/pixel).
- Downside: blurs fine details (text, thin lines, crisp texel noise). For a
  voxel world with procedural texel noise this is acceptable — the noise is
  meant to look low-res anyway.

FXAA implementation sketch:
1. Render voxel scene to an offscreen `TextureView` (not the swapchain surface).
2. Run a FXAA fullscreen-quad pass that reads from step 1's texture and writes
   to the swapchain surface.
3. FXAA WGSL implementation: use the public-domain FXAA 3.11 GLSL → WGSL port,
   or implement the simpler but effective "FXAA lite" (4-tap neighbourhood
   luminance gradient → conditional pixel shift).

MSAA and FXAA can coexist: render to an MSAA texture (for geometry silhouette
quality), resolve to an intermediate texture, then FXAA over that. For most
voxel scenes the FXAA-only route gives a bigger visible win per GPU cost.

### FXAA Implementation Notes (2026-04-11)

**Architecture:** `--aa=fxaa` activates a two-pass pipeline. The voxel scene renders
to an offscreen `bgra8unorm` texture (`fxaa_color_texture`, usage `render_attachment |
texture_binding`). After `pass.end()`, `runFXAAPass` blits that texture to the swapchain
via a fullscreen triangle (3 vertices from `@builtin(vertex_index)`, no vertex buffer).
The FXAA shader is embedded via `@embedFile("fxaa.wgsl")` in `sw_gpu/src/gpu.zig`.

**Pixel-diff results (flatland scene, 1280×720, same camera/TAS state):**

| Comparison | Differing pixels | % of frame | Max channel Δ | Channels Δ≥5 |
|------------|-----------------|------------|---------------|--------------|
| none → fxaa | 110,990 / 921,600 | **12.04%** | 95 | 44,283 |
| none → msaa4 | 31,544 / 921,600 | **3.42%** | 67 | 13,530 |

FXAA touches **3.5× more pixels** than 4× MSAA in a typical voxel scene. In the
terrain region alone (rows 250–450, cols 100–500) FXAA covered 7.3% vs MSAA's 1.1% —
**6.6× more coverage** where it matters most.

**Visual verdict:** Block-on-block tile transitions are visibly softer under FXAA;
the horizon silhouette is cleanly smoothed; no ghosting artefacts; no interior texture
blur (the procedural texel noise is meant to look coarse, so slight softening is
acceptable). The crosshair (thin 2px white lines) is also anti-aliased — expected for
a luminance-based method. FXAA is the recommended choice for voxel scenes where
block-on-block interior edges dominate over geometry silhouettes.

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
