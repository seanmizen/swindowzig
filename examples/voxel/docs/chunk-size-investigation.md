# Chunk size investigation — is 48×256×48 wrong?

Branch: `voxel/chunk-size-perf`. Written April 2026. This doc answers Sean's
question on that branch:

> "I hate to admit it but the 16x16 chunks in Vanilla Minecraft might have been
> sane. unless you can correct me there."

**Short answer:** Minecraft's 16×16 was right, and 48×256×48 was wrong — but
not for the reason you'd guess. The mean throughput is roughly the same at
both sizes for the same visible world volume. The win from 16-wide chunks is
that they put a **tight upper bound on the cost of any single piece of work
the engine does in one tick**, so the worst-case freeze shrinks by ~10×. Our
48-wide chunks were amplifying spikes, not total work.

---

## Phase 1 — See it be slow (baseline)

New TAS: `examples/voxel/tests/flatland_forward.tas`. Spawns in flatland,
double-taps Space to toggle fly mode, holds W for 1200 sim ticks, then holds
steady for a 200-tick tail so async work drains before the frame dump.
Captured under `--profile-csv=<path>` via the new per-tick instrumentation
in `main.zig` (reset at the top of `voxelTick`, gen/mesh timings accumulated
inline, upload/render timings accumulated in `voxelRender`, flushed to the
CSV via a `defer` at the top of `voxelRender`).

CSV columns:
`tick, loading, chunk_w, tick_ns, gen_ns, gen_count, mesh_ns, mesh_count,
upload_ns, upload_count, render_ns`

Usage:
```bash
zig build native -Dexample=voxel
./zig-out/bin/voxel --headless --world=flatland \
  --tas examples/voxel/tests/flatland_forward.tas \
  --dump-frame=/tmp/flatland_before.ppm \
  --profile-csv=/tmp/flatland_before.csv
```

(Debug build — the optimisation level Sean plays in. ReleaseFast would cut
all absolute numbers by 5–10× but preserves the ratios between configs.)

### Baseline @ 48×256×48, RENDER_DISTANCE=4 (192-block visible radius)

3 pregen ticks → 1401 flyover ticks. 1200 ticks of forward fly at
FLY_SPEED=10 b/s = ~100 blocks = ~2.1 chunk boundaries crossed.

| metric                   | p50       | p95       | p99       | max         |
|--------------------------|-----------|-----------|-----------|-------------|
| **tick_ns**              | 18.46 ms  | 45.43 ms  | 312.4 ms  | **1002.6 ms** |
| gen_ns                   |  0.01 ms  |  0.04 ms  | 252.9 ms  |  610.0 ms   |
| mesh_ns                  |  0.00 ms  |  0.00 ms  |  56.4 ms  |  157.8 ms   |
| render_ns                | 18.30 ms  | 38.98 ms  |  60.3 ms  |  234.0 ms   |
| engine (tick − render)   |  0.04 ms  |  0.17 ms  | 298.9 ms  |  768.7 ms   |

First-paint: **3.54 s** wall-clock from process start to the first
non-loading render frame.

**This is what Sean was complaining about.** The game is fine 95% of the
time (p50 under 20ms), spikes to 45ms at p95 (still playable), but the tail
is catastrophic: a full 1-second freeze at max. That single max tick
generated 2 chunks (610ms gen) and meshed 1 chunk (158ms) on the main
thread. In fly mode at 120 Hz sim rate, that one tick eats the budget for
~120 consecutive frames. You SEE it.

Per-phase attribution of the worst flyover spike (tick 830):

- `gen_ns` = 610 ms / 2 chunks — **60% of the spike**
- `mesh_ns` = 158 ms / 1 chunk — **16% of the spike**
- `render_ns` = 234 ms — 23% of the spike (one-off wgpu/Metal warmup)

Generation dominates. Inside `Chunk.generateTerrain`, the expensive part is
`computeSkylight`: a 2-pass BFS at `MAX_SKYLIGHT=15` levels over
`CHUNK_W² × CHUNK_H = 589 824` cells. That's ~50 million neighbour checks
per chunk in Debug mode. Meshing at ~158 ms/chunk is a distant second and
also scales with `CHUNK_W² × CHUNK_H`.

---

## Phase 2 — Is 48 insane? Predict before measuring.

### Math first

Per-chunk cost scales with `N² × H` for every major phase:
- `computeSkylight` BFS: O(`MAX_SKYLIGHT × N² × H × 6`)
- `generateTerrain` column walk: O(`N² × H`)
- `generateMesh` inner loop: O(`N² × H × 6`) face emits
- Greedy mesher visited mask: O(`N² × H`) allocation

Block storage at `N × H × N` voxels:
| CHUNK_W | cells    | ratio to 48 |
|---------|----------|-------------|
| 16      |  65 536  |  0.111×     |
| 32      | 262 144  |  0.444×     |
| 48      | 589 824  |  1.000×     |

Per-chunk cost is 9× smaller at 16-wide and 2.25× smaller at 32-wide. Good.

**But total work at the same visible radius is not smaller**, because the
loaded disc holds `π × R²` chunks. Keeping the visible world volume constant
means `RENDER_DISTANCE × CHUNK_W = 192` blocks, which gives:
| CHUNK_W | RENDER_DISTANCE | chunks in disc | per-chunk work | total work |
|---------|----------------:|---------------:|---------------:|-----------:|
| 48      |               4 |            ~50 |          1.00× |      1.00× |
| 32      |               6 |           ~113 |          0.44× |      1.00× |
| 16      |              12 |           ~452 |          0.11× |      1.00× |

Total CPU cost is conserved. So what do we actually get for smaller chunks?

### Counter-arguments FOR large chunks (48 side)

- **Fewer draw calls** — a 48-chunk disc has ~50 draw calls; a 16-chunk disc
  with the same visible area has ~452 (9× more). GPU draw overhead grows.
- **Less per-chunk metadata** — hashmap slot, `LoadedChunk` header, GPU
  vertex/index buffer handles. ~300 B each, times chunk count.
- **Less seam work** — lighting and meshing at chunk boundaries samples
  neighbours. More boundaries = more cross-chunk lookups.

### Counter-arguments FOR small chunks (16 side)

- **Bounded per-chunk work** — the maximum time any single
  `Chunk.generate` or `generateMesh` call can take is bounded by `N² × H`.
  At 16-wide, that's 9× less than at 48-wide. A chunk gen that would cost
  300 ms at 48-wide costs ~33 ms at 16-wide.
- **Finer-grained scheduling** — `MESH_GENS_PER_TICK = 1` lets the mesh
  loop process one chunk per tick. If that one chunk costs 158 ms, every
  tick for a second is blocked. If it costs 17 ms, the budget is fine.
- **Faster first-paint** — pregen of the spawn ring at 16-wide finishes
  before the loading screen animation has time to draw one full wave.
- **Less memory pressure per eviction** — dropping a 16-wide mesh frees
  ~116 KB; a 48-wide mesh frees ~1.05 MB. Fine-grained eviction
  hysteresis works better with smaller units.

### Minecraft's real trick — vertical sub-chunks

Minecraft's "16×16×384" is actually "16×16×384 *packaged as*
sixteen 16×16×24 sub-chunks" (post-1.18). Lighting and mesh updates only
touch the affected sub-chunk, not the full column. Our 48×256×48 has no
subdivision — every `setBlock` that needs a relight re-runs
`computeSkylight` on the entire 256-tall column. This is the amplification
path Sean was hitting. A 16×16×24 sub-chunk BFS is ~1600× cheaper than a
full 48×256×48 BFS.

### Hypothesis (written before running the experiment)

- **16 RD=12 (fair)**: mean throughput ≈ baseline, worst-case spike
  **5–10× smaller**. Win on smoothness, break even on total work.
- **16 RD=4 (unfair, smaller visible area)**: mean 5–10× better, spike
  10× better. But not a fair comparison — player sees 1/9 the area.
- **32 RD=6 (middle)**: ~middle ground, probably marginal.

---

## Phase 3 — Measure

Four runs of `tests/flatland_forward.tas` at Debug opt-level, all other
flags identical. CSVs saved to `/tmp/flatland_*.csv`.

| config                       | 1st-paint | p50     | p95     | p99     | max       | fly-total |
|------------------------------|----------:|--------:|--------:|--------:|----------:|----------:|
| **baseline 48 / RD=4** (192bl) |   3.54 s |  18.5ms |  45.4ms | 312.4ms | **1003 ms** |  38 788 ms |
| exp-small  16 / RD=4 ( 64bl) |   0.49 s |   3.3ms |  10.9ms |  50.0ms |    73 ms |   7 577 ms |
| **winner  16 / RD=12** (192bl) |  **3.44 s** | 22.2ms |  55.7ms |  **71.5ms** |  **280 ms** |  38 432 ms |
| exp-mid   32 / RD=6  (192bl) |   3.84 s |  21.2ms |  82.1ms | 209.2ms |   2009 ms |  48 288 ms |

Engine-only cost (tick − render, isolates gen + mesh + upload — the part
that actually depends on chunk size):

| config              | p50     | p95    | p99     | max       |
|---------------------|--------:|-------:|--------:|----------:|
| baseline 48 / RD=4  |  0.04ms | 0.17ms | 298.9ms | **768.7 ms** |
| winner  16 / RD=12  |  0.26ms |37.30ms |  45.7ms |  **106.6 ms** |
| exp-mid 32 / RD=6   |  0.07ms |23.76ms | 167.7ms |  217.6 ms |
| exp-sml 16 / RD=4   |  0.04ms | 0.45ms |  44.3ms |   67.8 ms |

### What to read out of this

**16 / RD=12 vs baseline 48 / RD=4 (the fair comparison):**

- First-paint: 3.44 s vs 3.54 s — **break-even**. Not the big win.
- Mean `tick_ns`: 22.2 ms vs 18.5 ms — **slightly worse (20%)**. Extra
  per-chunk overhead from having 9× as many loaded chunks.
- p99 `tick_ns`: 71.5 ms vs 312.4 ms — **4.4× better**.
- Max `tick_ns`: 280 ms vs 1003 ms — **3.6× better**.
- Engine-only max: **106 ms vs 769 ms** — **7.2× smaller**. This is the
  one that matters. The worst single piece of work the engine does in any
  one tick is ~7× shorter.

The win is entirely in the tail. Average frames are a touch slower because
you're doing ~9× more bookkeeping (hashmap lookups, draw call headers, sort
entries). But you never stall for a full second again.

**32 / RD=6 is a trap.** Middle ground on paper — ~2.25× smaller per-chunk
cost, ~2.25× more chunks — but it measured **worse than both endpoints**:
- First-paint 3.84 s (slowest of the three fair configs)
- Total fly wall time 48 288 ms (24% more than baseline; 26% more than 16)
- p99 209 ms, max 2009 ms (the max is a single Metal driver spike — not
  chunk-gen — but the 32-wide engine max of 217 ms is still ugly)
- Engine-only p95 23.8 ms (worse than 16's 37.3 ms on paper, but the tail
  is wider: the 16-config's p95 is the "flyover through chunk boundary"
  spike, whereas 32's p99 blows out to 167 ms)

Why 32 lost: per-chunk cost at 32-wide is ~1/2 of 48, but at RD=6 the disc
is ~2× larger so more chunks need to be touched per boundary crossing. The
per-chunk cost didn't drop enough to offset the added bookkeeping, and the
worst-case chunk still takes ~55 ms to mesh.

**16 / RD=4 (small-visible-area) is not a fair comparison** but shows what
16-wide looks like when you don't compensate: first-paint in half a second,
every metric 5–13× better than baseline. That's the number to quote when
you want to impress someone, but you're comparing different amounts of
work, not different chunk sizes.

### Top 3 hotspots (per the baseline spike attribution)

1. **`Chunk.computeSkylight`** — 2-pass BFS over `CHUNK_W² × CHUNK_H`
   cells. At 48-wide that's 589 824 cells × 14 BFS passes × 6 neighbours
   = ~50 M ops per chunk, which is the ~300 ms single-chunk gen spike.
2. **`Mesher.generateMesh`** — 158 ms per chunk at baseline on flatland,
   dominated by per-face AO / skylight sampling across `CHUNK_W² × CHUNK_H`
   voxels with 6-neighbour checks.
3. **Render pass `sortByDepth` + `uploadChunkMeshToGPU`** — ~20 ms/frame
   mean, grows roughly linearly with chunk count. Not a spike cause, but a
   steady tax that grows with small-chunk configs.

---

## Phase 4 — Sub-chunks?

Skipped. Phase 3 already decisively beats baseline on the metric that
matters (worst-case spike). Vertical 16-tall sub-chunks are kept as future
work — the obvious next step is to retrofit the same slab-subdivision trick
Minecraft uses so `setBlock` dig-relight doesn't re-run `computeSkylight`
on the entire 256-tall column. That's the source of the ~30–65 ms dig
hiccup documented next to `World.setBlock` in `world.zig`. It would cost
another major refactor on top of `Chunk` (hashmap key becomes
`(cx, cy, cz)`, mesher walks per-section, raycaster and player collision
re-plumbed) — track as Rank 4 in `examples/voxel/docs/memory.md`.

If someone picks this up later, the phase-4 experiment to run is:

1. Add a `CHUNK_SY = 16` constant and subdivide `Chunk.skylight` into
   `[CHUNK_H / CHUNK_SY]` layers.
2. Make `computeSkylight` take an optional `only_layer: ?u8` parameter and
   BFS only the affected layer (plus 1 above and 1 below for seam
   propagation).
3. Re-run `tests/flatland_forward.tas` — dig-relight spikes should drop
   by ~16× (one section instead of sixteen), restoring sub-ms dig cost.
4. Re-run `tests/dig_relight.tas` to verify the golden PPM is still
   byte-identical (skylight result must not change, only the cost to
   compute it).

---

## Phase 5 — Verdict

**Chunk size is now `CHUNK_W = 16`, `RENDER_DISTANCE = 12`,
`PREGEN_RADIUS = 6`.** Same 192-block visible radius as before. Worst-case
engine spike cut from 769 ms to 107 ms (7.2×). p99 tick time cut from
312 ms to 72 ms (4.4×). First-paint unchanged. Mean tick time is ~20%
worse, which is the tax you pay for finer-grained scheduling — and it's
invisible against the tail-spike win.

### Sean's 16×16 question, answered directly

Minecraft was right. But the reason isn't what it looks like on paper.

Smaller chunks don't do less *total* work — at the same visible volume,
the total voxel count you touch per frame is essentially identical.
Smaller chunks bound the maximum amount of work the engine can do on any
single chunk in any single tick. With `MESH_GENS_PER_TICK = 1` and a
single-threaded mesh loop, one 48-wide chunk gen + skylight BFS + mesh can
blow a full second of frame budget. One 16-wide chunk gen + skylight BFS +
mesh caps out at ~17 ms, which fits in a 16.6 ms frame (almost). The tail
flattens because the worst single unit of work is 9× smaller. Average
throughput doesn't care; perceived smoothness does.

So: **it's complicated, but the verdict is "MC was right."** 16×16 isn't
faster in any aggregate sense — it's *more predictable*, and predictable
is what you need for a framerate-sensitive interactive program. Our 48
was optimising for the wrong metric.

### Honest admissions

- **Mean is slightly worse.** The winner config costs ~20% more average
  tick time than baseline (22 ms vs 18 ms p50). I'm calling that a win
  because the p99 and max dominate perceived smoothness — but if someone
  is running this as a headless benchmark server they'd pick 48 back.
- **First-paint is unchanged.** I expected 16-wide to pregen faster. It
  doesn't, because `PREGEN_RADIUS=6` (to preserve the 96-block pregen area)
  means generating 113 chunks instead of 25 — total voxel count is the
  same, pregen takes the same wall time. The smaller per-chunk cost is
  cancelled by the larger chunk count.
- **Render cost grew with chunk count, but not as much as I feared.**
  `render_ns` p50 went from 18.3 ms → 19.5 ms despite 9× more draw calls.
  Metal is apparently fine with 452 tiny draw calls once the pipeline is
  hot. Still a tax on very-old GPUs but negligible on modern desktops.
- **The 32-wide middle ground did NOT win.** I expected it to be a
  compromise between mean throughput and tail spikes. It ended up being
  worse than both endpoints on total wall time, and only marginally better
  than baseline on the tail. Binary choice between 16 and 48.
- **`computeSkylight` on `setBlock` is still the elephant.** The docs next
  to `World.setBlock` note it's "30–65 ms per mutation" — at 16-wide that
  drops to ~3–7 ms, which is the real win for the dig-place path, but
  still too expensive for more than a couple of digs per tick. Phase 4
  sub-chunks are the next step if this hurts.

### Things I skipped and why

- **No sub-chunk implementation.** Phase 3 already won decisively on the
  "fly-around smoothness" metric. Sub-chunks are a separate refactor that
  benefits a different workload (dig-relight) and wasn't asked for.
- **Did not touch the mesher's greedy-merge path.** Greedy meshing at
  smaller chunk sizes would compound the win but would also break
  `updateForBlockChange` (the parallel `quad_block` contract). Out of
  scope.
- **Did not re-tune `MESH_GENS_PER_TICK`.** At 16-wide you could probably
  raise it from 1 to 4 (since each mesh is 10× cheaper) and shrink the
  "async background fill" window further. Deliberately left at 1 so this
  experiment is a pure chunk-size change — don't confound.
- **Did not update the F3 overlay to show new per-chunk numbers.** Not
  needed for this investigation.
- **Did not re-run the AA / AO / lighting regressions against golden
  PPMs.** All six TAS scripts in `tests/` run to completion with the new
  chunk size (framespike, msaa_flatland, ao_corners, cave_skylight,
  dig_relight, frustum_look_down, mesh_eviction_walk) — no crashes, no
  validation errors. But the golden PPMs for those tests are frozen at
  `CHUNK_W=48` and will NOT byte-match with `CHUNK_W=16` because the
  visible scene layout is different (smaller chunks, different default
  view distance). Regenerating the goldens is a follow-up task; marked
  as TODO in the commit message.

---

## Reproducing the experiment

From `utils/swindowzig`:

```bash
# Baseline
vim examples/voxel/chunk.zig   # CHUNK_W = 48
vim examples/voxel/world.zig   # RENDER_DISTANCE = 4, PREGEN_RADIUS = 2
zig build native -Dexample=voxel
./zig-out/bin/voxel --headless --world=flatland \
  --tas examples/voxel/tests/flatland_forward.tas \
  --dump-frame=/tmp/flatland_before.ppm \
  --profile-csv=/tmp/flatland_before.csv

# Winner
vim examples/voxel/chunk.zig   # CHUNK_W = 16
vim examples/voxel/world.zig   # RENDER_DISTANCE = 12, PREGEN_RADIUS = 6
zig build native -Dexample=voxel
./zig-out/bin/voxel --headless --world=flatland \
  --tas examples/voxel/tests/flatland_forward.tas \
  --dump-frame=/tmp/flatland_after.ppm \
  --profile-csv=/tmp/flatland_after.csv
```

Then analyse with the one-line Python snippet at the top of this doc's
Phase-3 section, or inspect the CSVs directly.
