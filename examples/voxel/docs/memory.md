# Voxel memory audit

Snapshot of the voxel demo's RAM and VRAM footprint, computed from the real
code in `chunk.zig` and `mesher.zig`. Numbers here are the basis for the
optimization shortlist at the bottom.

All sizes are for the current codebase as of this document — 48×256×48 column
chunks with a `BlockType` enum backed by `u8`. If you change `CHUNK_W`,
`CHUNK_H`, or the block-ID width, redo the math.

---

## 1. Per-chunk RAM (block data)

**Source**: `chunk.zig`
```
pub const CHUNK_W = 48;
pub const CHUNK_H = 256;
pub const BlockType = enum(u8) { ... };
pub const Chunk = struct {
    allocator: std.mem.Allocator,
    blocks: PalettedBlocks,   // palette compression — see below
    skylight: [CHUNK_W][CHUNK_H][CHUNK_W]u8,
};
```

- Chunk volume: `48 × 256 × 48 = 589,824` blocks.
- Legacy layout (before palette compression):
  - Block-ID width: `u8` (1 byte). The whole palette fits in 8 bits; only
    5–6 `BlockType` values are defined.
  - Block bytes: `589,824 × 1 = 589,824` B = **576 KB per chunk** flat.

### 1a. Palette compression (current)

The block grid is now stored as a `PalettedBlocks`: a per-chunk palette of
unique `BlockType` values plus a packed `[]u64` bit-array of indices at
`bits_per_entry = minBitsFor(palette_size)` bits per cell. Aligned packing
(each u64 holds `floor(64 / bits)` entries, no entry crossing a word
boundary) keeps `get`/`set` branch-light. Palette entries are append-only;
once a type has been seen in a chunk it stays resident. The fixed
`[256]BlockType` palette array costs a flat 256 B per chunk regardless of
contents.

| palette_len | bits | entries/u64 | words/chunk | data bytes | data + 256 palette bytes |
| ----------- | ---- | ----------- | ----------- | ---------- | ------------------------ |
| 1 (uniform) | 0    | —           | 0           |        0 B |                    256 B |
| 2           | 1    | 64          | 9 216       |   73 728 B |                  73 984 B |
| 3–4         | 2    | 32          | 18 432      |  147 456 B |                 147 712 B |
| 5–8         | 3    | 21          | 28 087      |  224 696 B |                 224 952 B |
| 9–16        | 4    | 16          | 36 864      |  294 912 B |                 295 168 B |
| 17–32       | 5    | 12          | 49 152      |  393 216 B |                 393 472 B |
| 33–64       | 6    | 10          | 58 983      |  471 864 B |                 472 120 B |
| 65–128      | 7    |  9          | 65 536      |  524 288 B |                 524 544 B |
| 129–256     | 8    |  8          | 73 728      |  589 824 B |                 590 080 B |

### 1b. Measured per-chunk block data

Measured by the `[CHUNK SIZE]` log line in `world.generateChunk` (April 2026,
after landing palette compression):

| scenario                        | palette_len | bits | block_bytes | ratio vs 576 KB |
| ------------------------------- | ----------- | ---- | ----------- | --------------- |
| **Flatland** (all generated)    |           5 |    3 | **224 952** |       2.62× win |
| **Hilly default** (pregen ring) |           5 |    3 | **224 952** |       2.62× win |
| Uniform (pre-generation, `Chunk.init`) | 1 |    0 |         256 |     ~2300× win |

Every `generateTerrain` column currently touches all five defined block
types: `air`, `bedrock` (Y=0), `stone`, `dirt`, `grass`. Both flatland and
hilly therefore converge on the same palette and the same bit width — 3
bits per block. The pre-palette prediction in the task brief was
**144 KB for flatland / 216 KB for hilly**; the real numbers are a little
higher because (a) flatland still plants bedrock so it's 5 types, not 4,
and (b) the 256-byte fixed palette header is counted in both figures.

Worst case for today's enum (`air`, `grass`, `dirt`, `stone`, `bedrock`,
`debug_marker` — 6 values) is still 3 bits because 6 ≤ 8, so even a
hand-crafted chunk that uses every defined type lands at 224 952 B. A
chunk that needed ≥ 9 distinct types would widen to 4 bits (≈ 288 KB),
and the theoretical cap with all 256 `u8` slots used lands at 590 080 B —
256 B above the old flat layout (the cost of the palette header itself).

This is the dominant per-chunk cost **of the block data**. Skylight still
costs another 576 KB flat — see §1c. Everything else in `LoadedChunk` —
ChunkKey, pointers, dirty flags, the empty `Mesh` ArrayList headers — is
<300 B and negligible.

### 1c. Skylight grid (still flat)

`skylight: [CHUNK_W][CHUNK_H][CHUNK_W]u8` = 589 824 B = **576 KB** per
chunk, unchanged by this pass. Palette compression on skylight is a
separate problem: the nibble (4-bit) domain is too narrow for the
indexed-palette trick to help, and values are almost unique per air cell
after BFS propagation, so a palette table would be nearly as large as the
flat grid. Left as-is on purpose; revisit only if skylight becomes the
next bottleneck. See §3 totals below for how this shifts the balance.

---

## 2. Per-chunk peak GPU mesh size (VRAM)

**Source**: `mesher.zig`
```
pub const VoxelVertex = extern struct {
    pos: [3]f32,       // offset 0,  12 B
    normal: [3]f32,    // offset 12, 12 B
    block_type: u32,   // offset 24,  4 B
    uv: [2]f32,        // offset 28,  8 B
    ao: f32 = 1.0,     // offset 36,  4 B
    _padding: [2]f32,  // offset 40,  8 B
};
```

- `@sizeOf(VoxelVertex)` = **48 bytes** (explicit 16-byte alignment padding).
- Each quad emits 4 unique vertices + 6 indices (2 triangles, indexed).
- Per-quad VRAM: `4 × 48 + 6 × 4 = 192 + 24 =` **216 B/quad**.

### Peak case — 3D checkerboard

Worst plausible worst case: alternating solid/air blocks. Half the volume is
solid (294,912 blocks), every solid block has all 6 faces exposed.

- Quad count: `294,912 × 6 = 1,769,472` quads.
- VRAM: `1,769,472 × 216 ≈ 382 MB` **per chunk**.

This is pathological — it requires a 3D noise pattern that never occurs in the
actual `generateTerrain` implementation, which always stacks solid layers.

### Standalone all-solid chunk (second-worst, realistic upper bound)

A chunk fully packed with stone and NO neighbours generated. Only the outer
shell is exposed.

- Quads: `2 × (48×48) + 2 × (48×256) + 2 × (48×256) = 4,608 + 24,576 + 24,576 = 53,760`.
- VRAM: `53,760 × 216 ≈ 11.6 MB` per chunk.

This is the worst case that can actually arise during normal generation
(chunk loaded, neighbours not yet loaded, no-neighbour-gate in place). Part 1
of this session's change eliminates it by refusing to mesh until all four
horizontal neighbours exist.

### Typical-measured case (hilly preset, neighbours loaded)

Measured empirically from a `--headless --tas framespike.tas` run on the
hilly preset, April 2026:

- Quad count: ~5,000–5,700 per chunk (inner ring, all neighbours loaded).
- VRAM: `5,500 × 216 ≈ 1.19 MB per chunk`.

This is what really matters. The peak numbers above are book-keeping.

### Host-side mesh overhead

On top of VRAM, the `Mesh` struct keeps three parallel `ArrayList`s in host
RAM during mesh generation:

- `vertices: ArrayList(VoxelVertex)` — `4 × 48 = 192` B/quad
- `indices:  ArrayList(u32)`          — `6 × 4 = 24` B/quad
- `quad_block:     ArrayList(u32)`    — `4` B/quad
- `quad_highlight: ArrayList(u8)`     — `1` B/quad
- Plus `sort_scratch` / `sort_indices` persistent buffers at ~`(8 + 24) × quad_count` B

Total host-side per quad ≈ **~250 B**, so a realistic chunk's host mesh is
~1.38 MB and a peak checkerboard chunk's host mesh would be ~442 MB (again,
pathological).

---

## 3. Total cost for the pregen ring

Part 2 of this session pregen's a 5×5 horizontal ring around the spawn chunk
column (N = 25, `PREGEN_RADIUS = 2`). Inside that ring, the inner 3×3 is
meshed before the player is released.

**RAM (block data, all 25 generated):**

- Pre-palette: `25 × 576 KB = 14,400 KB ≈ 14 MB`
- Post-palette (hilly/flatland, 3 bits): `25 × 219.7 KB ≈ 5.37 MB`

**RAM (skylight, all 25 generated — unchanged):**
`25 × 576 KB ≈ 14 MB`

**VRAM (typical hilly, 9 meshed):**
`9 × 1.19 MB ≈ 10.7 MB`

**VRAM (pathological all-solid standalone, 9 meshed):**
`9 × 11.6 MB ≈ 104 MB`
(doesn't apply in practice thanks to the neighbour gate — kept here as an
upper bound for paranoia budgeting)

**Host-side mesh scratch (typical):**
`9 × 1.38 MB ≈ 12.4 MB`

Loading-screen total ≈ **~37 MB RAM + ~11 MB VRAM** on typical hilly terrain.

---

## 4. Total cost for a typical playing session

Assumed view distance: `RENDER_DISTANCE = 4` chunks (circular radius). Disc
area at R = 4: `π × 16 ≈ 50` chunks loaded at any one time. `world.zig`'s
`buildSpiralOffsets` yields exactly 49 cells for R = 4 (count of (dx, dz) with
dx² + dz² ≤ 16).

**RAM (block data, all 49 generated):**

- Pre-palette: `49 × 576 KB = 28,224 KB ≈ 27.6 MB`
- Post-palette (hilly/flatland, 3 bits): `49 × 219.7 KB ≈ 10.5 MB`

**RAM (skylight, all 49 generated — unchanged):**
`49 × 576 KB ≈ 27.6 MB`

**VRAM (typical hilly, all 49 meshed):**
`49 × 1.19 MB ≈ 58.3 MB`

**Host-side mesh scratch (typical):**
`49 × 1.38 MB ≈ 67.6 MB`

**Total typical session footprint** ≈ **~95 MB host RAM + ~58 MB VRAM**.

For comparison, Minecraft Java Edition's default render distance is 10 with
16×16×384 chunks (384-tall sections × 16² = 98,304 blocks), so its per-chunk
block-data footprint is actually *smaller* than ours (and it uses palette
compression on top — see below). Ours is wasteful for the complexity level.

---

## Optimization shortlist — ranked by effort vs payoff

Ranked by (expected reduction) / (engineering hours). Top of list first. None
of these should land in this PR — this is a session-end write-up to seed
follow-up work.

### Rank 1 — Mesh eviction outside view distance — **LANDED Apr 2026**

Implemented in `voxel/mesh-eviction`. Per-tick pass walks every loaded
chunk; any whose chunk-grid distance² from the player exceeds
`EVICT_RADIUS_SQ` is downgraded back to `.generated`:

- `Mesh.freeHostBuffers()` releases the four parallel `ArrayList`s + the
  `sort_scratch`/`sort_indices` slices back to the allocator (capacity
  drops to zero, not just `len`).
- The owning `chunk_gpu` entry is removed and both vertex + index
  `wgpu_native` buffers are `destroy()`ed.
- `chunk.blocks` and `chunk.skylight` are intentionally retained — they
  are deterministic from the seed but expensive to recompute, and the
  whole point of eviction is to drop *mesh* storage, not block data.

Hysteresis (`world.zig: EVICT_RADIUS_SQ` doc-block):
- `MESH_RADIUS_SQ`  = 16   — distance² inside which a chunk may be meshed
- `EVICT_RADIUS_SQ` = 25   — distance² beyond which a meshed chunk is dropped
- 17..25 dead zone — meshed chunks here are kept but no longer regenerated.
  A chunk that wobbles between 16 and 17 (the natural border-flicker case)
  stays meshed because eviction only fires above 25; a chunk that wobbles
  between 25 and 26 stays evicted because re-meshing only fires at ≤ 16.
  The minimum round-trip cost across the boundary is therefore 9 chunk
  units of travel (5² → 4²), which is huge compared to a single tick of
  player wobble at the boundary.

Re-entry path: an evicted chunk has `state = .generated` and
`mesh_dirty = true`. The existing per-tick mesh loop already handles
`.generated → .meshed` for any chunk that (a) is dirty, (b) is inside
`MESH_RADIUS_SQ`, and (c) has all four neighbours generated. No separate
re-meshing path was needed.

#### Measured savings — flatland walk + walk-back TAS

Test script: `tests/mesh_eviction_walk.tas` — capture mouse, sprint W
forward 5 chunks (~3200 sim ticks), sprint S backward 5 chunks, settle.
Run with `--headless --world=flatland`. Per-chunk flatland mesh: 4608
quads × 216 B = **0.95 MB GPU** (from `[MESH] gen ... quads=4608` log).

The `[CHUNK_STATS]` line is logged every 240 ticks; numbers below are
read directly from those lines.

| Phase                            | No eviction | With eviction |
|----------------------------------|------------:|--------------:|
| Spawn (49 disc loaded)           | 29 meshed   | 29 meshed     |
| Walking forward, peak            | 64 meshed   | 47 meshed     |
| Walking back, peak               | 64 meshed   | 54 meshed     |
| End of TAS (94 chunks ever loaded) | 64 meshed | 47 meshed     |

(`64` is not `94` because the outer ring of the loaded disc never has all
four neighbours generated, so `hasAllNeighborsGenerated` keeps it at
`.generated` regardless of whether eviction is on. That's an existing
gate, not a new one.)

End-of-TAS GPU mesh memory:
- No eviction:    64 × 0.95 MB = **60.8 MB**
- With eviction:  47 × 0.95 MB = **44.7 MB**
- **Saved: 16.1 MB GPU on a 5-chunk round trip** (~26 % reduction)

Peak savings during walk:
- No eviction:   64 × 0.95 MB = **60.8 MB**
- With eviction: 54 × 0.95 MB = **51.3 MB**
- **Saved: 9.5 MB GPU at peak**

Host-side mesh scratch goes with it: `freeHostBuffers` returns the four
parallel `ArrayList`s + sort scratch to the allocator. Per-quad host
overhead is ~250 B (vs 216 B GPU), so the host RAM saved is roughly
**`16.1 MB × (250/216) ≈ 18.6 MB`** on the same round-trip.

#### Extrapolation to hilly + longer sessions

Per-chunk **hilly** mesh (from existing measurements): ~5500 quads ×
216 B ≈ **1.19 MB GPU**. Same chunk-count delta gives:
- End-of-TAS saved: 17 × 1.19 ≈ **20.2 MB GPU** (hilly)
- Peak saved:       10 × 1.19 ≈ **11.9 MB GPU** (hilly)

The savings grow ~linearly with traversed distance: each additional chunk
the player walks past the eviction boundary frees one more chunk's worth
of mesh storage, indefinitely. The 5-chunk round trip is a deliberately
short sample — a 30-minute session that wanders ~200 chunks would save
roughly `200 × 1.19 ≈ 240 MB` GPU on hilly without eviction holding all
of those meshes hostage.

What this number does **not** include:
- Block data (`Chunk.blocks` / `Chunk.skylight`) — left in RAM by design.
  That's `94 × 576 KB ≈ 54 MB` and is the same with or without eviction.
  Trimming it is Rank 2 (palette compression), Rank 3 (uniform
  shortcuts), and Rank 4 (Y-section subdivision).
- Stats logging cost: one map walk every 240 ticks. Negligible
  (~50 chunk lookups, no allocations).

### Rank 2 — Palette compression (Minecraft's trick) ✅ LANDED

**Status**: implemented on branch `voxel/palette-compression` (April 2026).
`Chunk.blocks` is now a `PalettedBlocks` — opaque behind `getBlock` /
`setBlock` / `resolveBlockRaw`. See §1a above for the layout table and
§1b for the measured per-chunk numbers.

- **Effort actual**: medium. The refactor was ~chunk.zig rewrite plus
  `mesher.zig` (2 direct-array accesses in `shouldRenderFace`/`isSolid`
  swapped for `resolveBlockRaw`) and `world.zig` + `main.zig` (2 sites
  each) for the `setBlock` error-return plumbing. Everything else already
  went through `getBlock` and was unaffected.
- **Payoff actual**: **~2.62× reduction** on block data for typical
  terrain (flatland and hilly default both converge on 5 types / 3 bits
  / 224 952 B, down from the flat 576 KB). Uniform (never-generated)
  chunks drop to 256 B — effectively zero. See §1b for the full table.
- **Risk actual**: the `grow` re-pack path is the only allocator call on
  the hot `setBlock` route; it's hit at most 8 times over a chunk's
  lifetime (once per bit-width increase). `updateForBlockChange` was
  already routed through `chunk.getBlock`, so the incremental-mesh fast
  path needed no changes. All four TAS regressions (`framespike`,
  `ao_corners`, `cave_skylight`, `dig_relight`) produce byte-identical
  PPM dumps before and after — palette compression is a pure storage
  refactor with no visible effects.
- **Skylight stays flat** for this pass — see §1c for why palette
  compression on skylight is a separate problem.

### Rank 3 — Homogeneous chunk shortcut

- **Effort**: tiny. A `Chunk` variant: `uniform_air | uniform_stone |
  normal_dense`. `getBlock` for uniform chunks is a constant return; they
  cost ~0 bytes of block storage. Composes with Rank 2 as the `bits = 0` case.
- **Payoff**: large *only if* the world has vertical air/stone chunks, which
  ours currently doesn't (chunks are 256-tall columns with terrain always
  in the middle). Becomes compelling only after subdividing into Y sections.
- **Risk**: low in isolation. Do it alongside Y-sections or skip it.

### Rank 4 — Y-section subdivision (16-tall sub-chunks)

- **Effort**: medium-large. Retrofit `Chunk` from `[W][H][W]` to `[H/16] ×
  [W][16][W]` sections, update the mesher to work per-section, re-plumb the
  hashmap key from `(cx, cz)` to `(cx, cy, cz)` everywhere.
- **Payoff**: unlocks Rank 3. On hilly terrain most of the 256 vertical
  column is either all-air (sky) or all-stone (underground) — those sections
  compress to a single constant under Rank 2 + Rank 3. Realistic saving:
  ~80% on block-data RAM for typical worlds.
- **Risk**: high — biggest refactor on the list. Breaks the mesher, the
  raycaster, the player collision path, and serialization. Do NOT start this
  until Ranks 1/2 are done and benchmarked.

### Rank 5 — Greedy meshing *(LANDED)*

Implemented on branch `voxel/greedy-mesh`. Opt in with `--meshing=greedy`
(now the default); fall back to the per-block path with `--meshing=naive`.

**Merge rule.** Two coplanar same-material cells may merge iff both have
*uniform* AO and skylight (all four corner values equal) AND their uniform
constants match. This is strictly narrower than classic greedy — classic
allows any matching corner quadruple — but it's the only rule that
preserves bilinear interpolation across the merged quad exactly. Under
the weaker rule a merged w×h rect stretches the per-cell gradient over
multiple blocks and interior fragments drift by `0.125 × ((a+b) - (c+d))`
per channel relative to the naive output. See the block comment on
`greedyCellEq` for the worked example.

**Painter's-sort cap.** The voxel demo sorts quads in software
(centroid-distance back-to-front — no hardware depth due to the macOS/Metal
wgpu-native bug documented in the main CLAUDE.md) and a merged 48×48 grass
top has its centroid far from its nearest edge. That causes visible sort
inversions against smaller overlapping geometry (pit walls, dirt
exposures, hover outlines). Capping each merge dimension at
`MAX_GREEDY_DIM = 6` keeps every merged quad's centroid within ±3 blocks
of its farthest corner — close enough that the greedy output stays within
the RMS tolerance used by `examples/voxel/tests/greedy_vs_naive.sh`
(`< 2/255` per channel). Measured per-channel RMS for the pit test at
various caps:

    cap=4 → 0.62/255   (safe)
    cap=6 → 0.65/255   (safe, picked)
    cap=7 → 0.64/255   (borderline, passes)
    cap=8 → 9.63/255   (fails — pit-wall sort inversions)
    cap=∞ → 20.8/255   (fails badly)

The cliff between 7 and 8 is narrow, so 6 is the safest large cap. Lift
the cap once hardware depth testing comes back.

**Measured quad-count reduction** (48×256×48 chunk, cap=6, `framespike.tas`):

| Preset   | Naive quads         | Greedy quads         | Reduction   | VRAM/chunk  |
|----------|---------------------|----------------------|-------------|-------------|
| flatland | 4608 baseline       | 128–137 (~130)       | **35×**     | 1.00 MB → 28 KB |
| hilly    | ~5000–5900 (~5400)  | ~1000–2500 (~1700)   | **~3.2×**   | 1.19 MB → 370 KB |

Flatland smashes the 5–10× target because the grass top + bedrock bottom
are uniform-AO faces that merge into 35–40 rectangles of 6×6 blocks each
(plus stray chunk-boundary tiles). Hilly falls short of the target at
~3×: the uniform-AO rule rejects most bumpy surfaces before the cap even
comes into play, so the bottleneck is the merge rule, not the cap.

Measured on `examples/voxel/framespike.tas` (hilly):

    2023-04: naive=5324 quads, greedy=1700 quads — 68.1% reduction
    2023-04: naive=4995 quads, greedy=1007 quads — 79.8% reduction (best)
    2023-04: naive=5673 quads, greedy=2539 quads — 55.2% reduction (worst)

Pregen ring (9 meshed chunks) on hilly drops from ~10.7 MB VRAM → ~3.4 MB
(greedy cap=6). Typical session (49 meshed chunks) drops from ~58.3 MB →
~18 MB. On flatland the same ring drops from ~10.7 MB → ~0.27 MB.

**`quad_block` parallel array.** Greedy quads span multiple blocks, so
`updateForBlockChange`'s "find quads owned by block X" lookup loses
meaning. In greedy mode the dig/place handlers flag the whole chunk
`mesh_dirty = true` and let the next tick full-regen the mesh — this
gives up the 78% incremental-update win from the naive path. The parallel
array is still populated (with the first block of each rect) so
`swapRemoveQuad` / `decayHighlights` continue to work as-is.

**Risk/payoff summary**: was worth it on flatland and open spaces (gross
VRAM reduction). Hilly terrain is a more modest win and pays a
per-dig full-regen cost instead of the incremental path. A future session
that restores hardware depth testing can raise the cap and revisit the
merge rule.

### Rank 6 — Run-length / bitmask layers

- **Effort**: medium.
- **Payoff**: smaller than palette compression for dense terrain, because
  horizontal layers are not actually that uniform once heightmaps get hilly.
- **Risk**: low, but duplicates Rank 2's benefit with worse ergonomics.
- **Skip** in favour of palette compression.

---

## Top 2 recommendations for follow-up sessions

1. **Mesh eviction outside view distance** — trivial implementation, big win
   on sustained play, zero risk to other subsystems. Do this first.
2. **Palette compression** — 2–3× block-data RAM reduction with a clean
   integration point (hides entirely behind `getBlock`/`setBlock`). Do this
   after eviction so RAM wins compound without being masked.

Rank 3/5/6 are premature until Ranks 1 and 2 have landed and been measured.
Rank 4 is a refactor mountain that only pays off on top of Ranks 2 and 3.
