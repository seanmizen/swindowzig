# Voxel Lighting

How darkness works in the voxel demo. Written when the only thing we had was
per-vertex AO, which couldn't make a cave dark, and we were trying to decide
how to fix that.

Read this before touching `mesher.zig`, `chunk.zig`, or `voxel.wgsl` if your
change affects how a face's brightness is computed.

---

## 1. The taxonomy of "dark"

There are five completely different mechanisms a voxel game can use to make a
surface look dark. They solve different problems, run in different parts of the
pipeline, and most engines combine several of them. Knowing which is which is
the entire reason this doc exists.

| Mechanism | What it knows | Where it runs | What it solves |
|---|---|---|---|
| **Ambient occlusion (AO)** | Solid blocks 1–2 cells from each face vertex | Mesh time, baked per-vertex | Sub-block contact shadows. The dark notch where two walls meet. |
| **Skylight propagation** | How far each air block is from open sky | Chunk time, stored per block | "I'm in a cave / under an overhang." Outside is bright; underground is dark. |
| **Block light** | Distance from emitters (torch, lava, glowstone) | Chunk time, stored per block | Local light sources lighting up an area. |
| **Sun shadow mapping** | Depth-from-the-sun, sampled per fragment | Render time, depth pass + sample | Sharp directional sun shadows on bright surfaces. |
| **Screen-space AO (SSAO/HBAO/GTAO)** | Depth buffer of what the camera sees | Render time, post-process | Smooth analog crevices in whatever's currently on screen. |

A few things follow from this table that are worth being explicit about because
the names overlap and it's easy to confuse them:

- **AO is not "global lighting on a small budget".** It cannot make a cave
  dark. It only knows about the blocks immediately touching a face (1 cell
  away in classic Mojang AO, 2 cells away in our Moore extension). A block in
  the middle of a 50×50×50 enclosed cavern looks identical to a block on an
  open hilltop, because both are surrounded by air for several cells.
- **Skylight is the thing Sean keeps asking for.** When he says "caves should
  be dark", he means: each block knows whether there is a path through air
  back to the sky, and if not (or if the path is long), it should be dim.
  Skylight is a property of *air blocks*; solid blocks inherit brightness
  from whichever neighbouring air block is brightest, which is exactly what
  the mesher needs to look up when it builds a face.
- **Sun shadow mapping does NOT solve the cave problem either.** Sun shadows
  give you a sharp dark line where a hill blocks the sun. A cave is *already*
  in shadow trivially (no sun line of sight), but real shadow maps don't tell
  you anything about how *far* into the cave you are. You'd have a uniformly
  shadowed cave: dark from the ceiling, dark from the entrance, dark deep
  inside — all the same. Skylight gives you the gradient.
- **SSAO doesn't help either.** It only sees fragments the camera is currently
  rendering. A cave behind the camera is just not in the depth buffer; SSAO
  produces nothing for it.

**Conclusion:** the feature that makes Sean's "stand inside a cave, it should
be pitch black" work is **skylight propagation**, full stop. AO stays. Block
light and sun shadows are nice-to-haves for later.

## 2. Minecraft's actual lighting model, briefly

Minecraft has been the load-bearing reference here for fifteen years; pretty
much every voxel engine cribs from it. The relevant pieces:

- **Two 4-bit channels per block.** `sky_light` (sunlight) and `block_light`
  (torches/lava/glowstone). Each is an integer in `[0, 15]`. Stored per block,
  so a chunk pays one extra byte per block (two 4-bit nibbles in one u8).
- **Skylight seeds at the top of the world.** Every air block above the
  topmost solid block in its (x, z) column gets `sky_light = 15`. Below that
  first solid, the column is initially dark.
- **Flood fill outward.** Once seeded, light propagates by BFS through air
  blocks. Each step decrements: a neighbour can have at most `current - 1`.
  Solid blocks block propagation (they have skylight 0 and don't pass light).
- **Heightmap optimisation.** Each chunk caches the topmost solid Y for each
  column. When a block is broken or placed, only the column from the change
  upward needs re-seeding, and the BFS only re-runs in the affected
  neighbourhood. This is what lets light updates feel instant in vanilla
  Minecraft.
- **Cross-chunk seams.** Light doesn't stop at chunk boundaries. When a chunk
  loads, the BFS pushes into already-loaded neighbours. Without this, you get
  visible brightness discontinuities at chunk edges, which look terrible
  because they're aligned to the world grid.
- **Block light** is the same algorithm with a different seed set: each
  light-emitting block is a source of `light_emission` value (torch=14,
  glowstone=15, lava=15), and the BFS runs on the second nibble independently.
- **The shader combines them.** Final brightness ≈ `max(sky_light * day_curve,
  block_light) / 15`. Sky channel scales with time-of-day; block channel does
  not.

This is well-documented if you want depth: the Minecraft Wiki article "Light"
covers all of the above with diagrams and the exact decrement rules.

## 3. Options for our first implementation, ranked

| Option | Effort | Memory | Visual payoff | Verdict |
|---|---|---|---|---|
| **A. Per-chunk skylight flood fill** | Medium | +1 byte/block (~576KB/chunk) | High — caves dark, hilltops bright | **Pick this.** |
| **B. Heuristic "downward distance to sky"** | Low | +1 byte/block | Medium, wrong in horizontal caves | Trap. Don't. |
| **C. SSAO** | High | 1 extra render target | Low for the stated goal | Wrong tool. |
| **D. Sun shadow mapping** | Very high | Shadow atlas (2k² texture) | Beautiful sun shadows, but doesn't help caves | Phase 3+ nice-to-have. |

**Option A** is the only one that produces the result Sean asked for. It is
also the foundation we'd need anyway before adding block light or anything
else, so building it first is the highest-leverage move. The Minecraft wiki
algorithm port is well-trodden and our chunk format is small enough that the
naive BFS is fast.

**Option B** is tempting because it's so simple — for each (x, z) column, the
"distance to sky" is just "how many air blocks are above me before I hit the
ceiling of the world", which is a single downward scan. It's wrong as soon as
you have a horizontal cave (a tunnel under flat ground gets the same skylight
as the surface above it because the column above is open) or any overhang.
Doing this would be visually almost-correct on the flatland preset and look
totally broken on hilly with caves. Don't ship a foundation we'll have to rip
out.

**Option C** misunderstands the problem. SSAO is a screen-space pass —
fragments not in the current depth buffer don't get any AO. That's fine for
"the inside of the doorway you're standing in is slightly darker than the
floor" but it does nothing for "this cave is dark even though you can't see
into it because you're outside". It also requires a depth target, which the
voxel example doesn't currently keep around (we use software back-to-front
sort instead — see the Metal depth crash in CLAUDE.md).

**Option D** is the right answer for a different question. Sun shadows make
the *outside* of the world look better. They don't darken caves more than a
cave is already darkened by being in shadow of the world geometry — and the
problem with our current renderer is that "in shadow of geometry" doesn't even
mean anything yet because we don't have skylight. Sun shadows on top of
working skylight would look great. Sun shadows on top of nothing would still
leave caves bright.

## 4. The skylight design for our engine

This section is the part that actually gets implemented in phase 1. Concrete,
file-by-file.

### 4.1 Storage — `chunk.zig`

```zig
pub const Chunk = struct {
    blocks: [CHUNK_W][CHUNK_H][CHUNK_W]BlockType,
    skylight: [CHUNK_W][CHUNK_H][CHUNK_W]u8, // 0..15
    ...
};
```

Why `u8` and not packed `u4`: the rest of the engine doesn't yet care about
memory at this level (block light isn't here either), so the u4 packing just
adds shift-and-mask noise everywhere it's read. We'll pack it later if we ever
add block light, by combining sky+block into one u8 (high nibble = sky, low
nibble = block).

**Memory cost.** `48 × 256 × 48 × 1 byte = 576 KB per chunk`. With render
distance 4 (the spiral covers 49 chunks), that's `49 × 576 KB ≈ 28 MB` of
skylight data resident at any time. The block array itself is also 576 KB per
chunk so this is a 100% increase per chunk. On a desktop running the demo
this is invisible noise. Worth flagging for the chunk-pregen session
(`local_0b5e6f01`) which is auditing per-chunk RAM in parallel — they should
add 576 KB per loaded chunk to their accounting once this lands.

### 4.2 Compute — `Chunk.computeSkylight()`

Two-pass algorithm:

**Pass 1 — column seed.** For each `(x, z)` column, scan downward from
`y = CHUNK_H - 1`. Every air block sets `skylight = 15` until the first
solid block. Below that solid, every air block starts at `skylight = 0`.
Solid blocks always have `skylight = 0` (they can't carry light themselves;
they only block propagation).

**Pass 2 — horizontal/upward BFS.** Build a queue of every cell with
`skylight = 15` (the seeded sky cells). Standard BFS: pop a cell, look at its
6 neighbours; for each neighbour that is air and has a current skylight
strictly less than `(my_level - 1)`, set it to `(my_level - 1)` and enqueue
it. Repeat until the queue is empty.

This terminates in at most 15 levels of BFS. Cells are visited at most twice
on average (once when they get their final value, once when a slightly
brighter path tries and fails). For our chunk size that's `~10–15 ms` cold
on a single thread on a modern desktop — fine to do at chunk-generate time
because it's a one-shot per chunk and we already gate to `CHUNKS_PER_TICK = 2`.

**Why downward propagation also "works for free".** Pass 1 gives a sky cell
`skylight = 15` directly. So for the classic Minecraft case where light
"falls" straight down through a vertical hole, the column scan in Pass 1
already places `skylight = 15` all the way to the bottom of the hole before
the BFS even runs. Light only needs the BFS to bend horizontally through
overhangs and tunnels.

**Cross-chunk seams — explicitly out of scope for phase 1.** The BFS as
described looks at neighbours via `chunk.getBlock` which returns `.air` for
out-of-bounds (good for bright outside), but we never *push light into* the
neighbour chunk's array. Result: a horizontal cave that crosses a chunk
boundary will be brightly lit on one side and dark on the other. We accept
this for phase 1 and document it as a known artifact. Phase 2 will need to
re-enqueue boundary cells in newly-loaded neighbours, similar to how
`World.update` already marks adjacent chunks as `mesh_dirty` when a new chunk
arrives.

### 4.3 Mesher integration — `mesher.zig`

A new function `computeFaceSkylight(chunk, getter, world_ox, world_oz, wx, wy, wz, face) -> [4]f32`,
shaped exactly like `computeFaceAOClassic`:

For each of the 4 vertices of the face, sample the skylight from the air
cells that share that corner. The simplest correct sample is the air cell
"outward+1" (the one immediately on the open side of the face, same as the
classic AO `c` sample) — that's the air block whose skylight value is the
authoritative answer for "how much sky light reaches this face?".

A slightly nicer choice is to average the air-side neighbours of the four
cells diagonally adjacent at the vertex, but that's a phase-2 polish; the
single-cell sample looks good and matches how we already do AO sampling.

Output is `[4]f32` in `[0, 1]` (skylight / 15.0). Stored on each vertex.

### 4.4 VoxelVertex layout

Current:
```zig
pub const VoxelVertex = extern struct {
    pos: [3]f32,       // offset 0
    normal: [3]f32,    // offset 12
    block_type: u32,   // offset 24
    uv: [2]f32,        // offset 28
    ao: f32 = 1.0,     // offset 36
    _padding: [2]f32 = .{0, 0}, // offset 40, total 48 bytes
};
```

New:
```zig
pub const VoxelVertex = extern struct {
    pos: [3]f32,         // offset 0
    normal: [3]f32,      // offset 12
    block_type: u32,     // offset 24
    uv: [2]f32,          // offset 28
    ao: f32 = 1.0,       // offset 36
    skylight: f32 = 1.0, // offset 40 — sky brightness 0..1
    _padding: [1]f32 = .{0}, // offset 44, total 48 bytes
};
```

Same 48-byte stride. We're just consuming half of the existing padding.
The vertex buffer layout in `main.zig:2032` gets one new attribute at
location 5: `.{ .format = .float32, .offset = 40, .shader_location = 5 }`.

### 4.5 Shader — `voxel.wgsl`

Add `skylight: f32` at location 5 in `VertexInput`, pass through to
`VertexOutput`, and fold into the existing brightness chain in `fs_main`.

```wgsl
let ao_brightness = 0.55 + in.ao * 0.45;
let sky_brightness = 0.05 + in.skylight * 0.95;  // 0.05 floor → caves dim, not invisible
let lit = brightness * texel_brightness * ao_brightness * sky_brightness;
let base = in.color * lit;
```

The `0.05` floor is deliberate. A truly black cave is unplayable — you literally
cannot see what you're holding. Vanilla Minecraft does the same thing
(`min_sky_light = 0` in code but the global brightness curve adds back a
constant ambient term so the night sky and pitch-dark caves are still
~15% bright). Pick `0.05` here, tune later.

### 4.6 CLI — `main.zig`

Add `--lighting=<none|skylight>` parsed alongside `--ao=`. Default `skylight`.
A new state field:

```zig
const LightingMode = enum { none, skylight };
lighting_mode: LightingMode = .skylight,
```

When `lighting_mode == .none`, the mesher writes `skylight = 1.0` for every
vertex regardless of the chunk's skylight grid. The chunk skylight grid is
still computed (the cost is small and it keeps the code paths simple), it
just isn't read by the mesher. This gives a clean A/B for the regression test.

A settings-menu entry, alongside AA Method / AO Strategy / Render Distance:
`Lighting: <skylight|none>`. Same cycle pattern as AO. Changing it requires
remeshing every loaded chunk — same constraint AO has — and the existing
"set every chunk's `mesh_dirty = true` after mutation" wiring will work
unchanged.

### 4.7 Interaction with AO

AO stays. AO and skylight are multiplicative because they describe orthogonal
phenomena:

- AO says "this corner is in a tight crevice".
- Skylight says "this region is far from the sky".

A face on a hilltop has `ao ≈ 1.0` and `sky ≈ 1.0` → fully lit.
A face deep in a cave has `ao ≈ 0.7` (typical interior corner) and `sky ≈ 0.0`
→ floor-clamped to `0.05`. The AO inside the cave is still doing its job —
once block light lands and you put a torch down, the cave wall lights up to
`0.7 × torch_brightness`, and the AO contour is still visible.

If we instead *added* them, AO would lighten dark caves (because AO is bright
on flat walls). Multiplicative composition is the only correct option here.

## 5. What ships in phase 1 vs later phases

**Phase 1 (branch `voxel/skylight-phase-1`):**
- `Chunk.skylight` storage
- `Chunk.computeSkylight` (column seed + BFS), called from `generateTerrain`
- `mesher.computeFaceSkylight` and `VoxelVertex.skylight`
- Shader formula update + new vertex attribute
- `--lighting=` CLI flag and settings-menu entry
- Cave dump-frame regression test
- Cross-chunk seams left as visible artifact
- **No relight on dig** — digging exposed the bug immediately: the new
  air cell retained its as-solid `skylight = 0`, and the floor of the
  pit read that 0 via the mesher's outward-slab sample and rendered at
  the `0.05` floor. This was fixed in the next patch, see below.

**Phase 1.1 (branch `voxel/skylight-fixes`, dig relight):**
- `World.setBlock` now calls `Chunk.computeSkylight()` and marks the chunk
  `mesh_dirty = true` after any block mutation. The next tick rebuilds the
  whole chunk mesh, picking up fresh per-vertex skylight values everywhere.
- Cost: ~30–65 ms per dig (dominated by the chunk-wide BFS), plus the
  usual ~30 ms full chunk re-mesh. Invisible against the macOS trackpad's
  80–120 ms tap-to-click latency, and acceptable versus the correctness
  payoff. A bounded local BFS would be cheaper but is easy to get wrong;
  revisit if dig latency becomes user-visible.
- Regression: `examples/voxel/tests/dig_relight.tas`. Diff vs. a local
  branch that disables the relight call shows ~22% of frame pixels change
  (the pit interior) with mean Δ ~25/255, max Δ ~52/255; buggy interior
  is ~(2,2,1), fixed interior is a (15..38)-ish gradient that matches the
  expected skylight fall-off as the camera looks into the shaft.

**Phase 2 (next session, do not attempt now):**
- Cross-chunk skylight seam fixing — re-BFS into adjacent chunks when a new
  chunk loads, mirror of the existing `mesh_dirty` wiring. Digs right at a
  chunk edge still won't push light into the neighbouring chunk.
- Heightmap-cached incremental relight — cache topmost solid Y per column
  and only re-BFS the affected neighbourhood on dig, instead of full
  chunk recompute. Needed once dig latency becomes user-visible.

**Phase 3 (branch `voxel/block-light`, glowstone only):**
- `BlockType.glowstone` — a new opaque block type that emits light from its
  own cell. Seeded at `MAX_BLOCK_LIGHT` by `computeBlockLight` pass 1.
- `Chunk.block_light: [48*256*48]u8` — a second per-block light channel
  stored alongside `skylight`. +576 KB per chunk (per-chunk memory now
  ~1.7 MB = blocks 576 KB + skylight 576 KB + block_light 576 KB).
- `Chunk.computeBlockLight()` — allocator-free bucket-sort BFS, same shape
  as `computeSkylight`, with two differences: (a) the seed pass stores
  emission level in the emissive cell itself (even though it is solid),
  (b) a `any_emitter` short-circuit skips pass 2 entirely on chunks that
  generated with no glowstones, which is every freshly-generated terrain
  chunk.
- `World.setBlock` now recomputes both skylight AND block light after any
  mutation. Placing a glowstone seeds the BFS; removing one erases the
  flood region.
- `VoxelVertex.block_light: f32` at offset 44 (replacing the padding) —
  same 48-byte stride. Vertex buffer layout gains attribute location 6
  in `main.zig:2192`, WGSL input gains `@location(6) block_light`.
- `mesher.computeFaceBlockLight` mirrors `computeFaceSkylight` but folds
  the face-owning block's `block_light` into the final value via `max`:
      block_light[v] = max(outward_mean[v], owner_block_light)
  The `max` is the bit that makes a glowstone's own face render at its
  full emission level. Without it, the face would sample the outward air
  cell (which has value 14, one BFS step from the emitter) and render as
  a noticeably dimmer glowstone.
- Shader combines sky and block as `max(sky_brightness, block_brightness)`
  — they compete, they do not add. Ambient occlusion and directional
  lighting still multiply on top. A glowstone in a cave with
  `sky_brightness = 0.05` reads `block_brightness = 1.0` and the max
  selects block; a glowstone in the open sky reads sky = 1.0 and block =
  1.0 and both yield the same peak. This matches the Minecraft wiki
  formula.
- **Distinctive pixel-art texture** for glowstone: the fragment shader
  detects glowstone via its base color and switches to a coarser 4×4
  hash grid with wider (±25%) brightness variance, producing a chunky
  molten-cluster look instead of the fine 16×16 noise used for stone
  and dirt. No per-block texture atlas is needed — the identity is
  encoded in the vertex color channel.
- **Cross-chunk propagation is deliberately out of scope.** Block light
  never crosses a chunk boundary. A glowstone placed right at a chunk
  edge lights only its own chunk; the neighbour reads 0 via
  `World.getBlockLight`. The seam is small in practice because block
  light decays to 0 within 15 cells and the player rarely straddles a
  chunk edge with an emitter, but the same cross-chunk fix planned for
  phase 2 skylight will also solve this. **TODO(phase 4):** re-BFS into
  adjacent chunks after `World.setBlock` mutates a cell near a seam.
- Regression test: `examples/voxel/tests/glowstone_cave.tas` +
  `glowstone_cave.sh`. The TAS digs a small flatland pit, places either
  `--place-block=stone` (baseline) or `--place-block=glowstone`, and the
  runner checks four bboxes in the dumped PPMs:
    core (glowstone face)   — lum ≈146 in glow, ≈34 in stone   (+112)
    wall near (1 cell away) — lum ≈120 in glow, ≈42 in stone    (+78)
    wall rim (~4 cells)     — lum  ≈44 in glow, ≈15 in stone    (+30)
    far grass               — lum ≈157, unchanged               (+0)
  The falloff 146 → 120 → 44 mirrors the BFS decay 15 → 14 → 11. The
  "far unchanged" check is the regression hook for cross-chunk leakage.

**Phase 4 (future):**
- Cross-chunk block-light seam fix (mirrors phase 2 skylight plan).
- Torch / lava block types (extend `emissionLevel` switch).
- Day/night cycle modulating the global skylight scalar.
- Real sun shadow mapping for outdoor scenes.

## 6. Memory cost summary for the chunk-pregen session

The parallel session (`local_0b5e6f01`) is auditing per-chunk RAM. After
phase 1 lands, the per-chunk number changes:

- Before: `blocks: 576 KB` (BlockType is 1 byte)
- After: `blocks: 576 KB + skylight: 576 KB = 1152 KB`

For a 4-radius render ring (49 chunks): `~28 MB` becomes `~56 MB`. This is
still trivial in absolute terms but it doubles the per-chunk count, so any
existing pregen ring sizing should be re-checked. Phase 2 (block light) would
add another 576 KB if we don't pack — i.e. `1.7 MB` per chunk if all three
channels are stored as u8. At that point the u4-packing is worth doing.

## 7. Verifying this works

Build clean and run the existing regressions first — if `framespike.tas` or
`ao_corners.tas` change pixel-for-pixel in a way that isn't explained by the
new `sky_brightness` factor on visible faces, that's a bug.

The phase-1 cave test goes in `examples/voxel/tests/cave_skylight.tas`. The
script digs a vertical shaft, looks down it, and `--dump-frame` captures the
result. Compare:

- `--lighting=none` (baseline, all faces multiply by 1.0) → bright cave
- `--lighting=skylight` (default after this lands) → dark cave

Pixel diff should be small on the rim of the hole (those faces still have
`sky ≈ 1.0`) and large on the interior walls below the surface where the
column scan never reached (`sky = 0.05`). A working implementation produces
a roughly bowl-shaped brightness gradient from the hole rim down to the
floor.
