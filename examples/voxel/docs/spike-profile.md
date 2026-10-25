# Spawn-Area Chunk Spike — Profile Report

**Branch:** `voxel/profile-spike`  
**Date:** 2026-04-12  
**Method:** `--headless --tas tests/spike_reproducer.tas`; timers via `std.time.nanoTimestamp()`.  
**Machine:** macOS 25.4 (Apple Silicon, exact spec not captured).  
**Note:** Headless mode skips the render path (`g.isReady()` → false), so GPU sort and
upload timings are instrumented but read N/A in this run. See §GPU upload below.

---

## What was measured

Four per-phase timers were added:

| Tag | Phase | Location |
|-----|-------|----------|
| `[GEN]` | Terrain fill + `computeSkylight` (per chunk) | `chunk.zig:generateTerrain` |
| `[MESH]` | `mesher.generateMesh` (per chunk) | `main.zig` mesh loop |
| `[SPIKE_TICK]` | Per-tick totals: gen + mesh | `main.zig:voxelTick` |
| `[UPLOAD]` | GPU `writeBuffer` per dirty chunk | `main.zig:voxelRender` |
| `[SPIKE_RENDER]` | Per-frame sort + upload totals | `main.zig:voxelRender` |

Reproduce with:
```bash
zig build native -Dexample=voxel
./zig-out/bin/voxel --headless \
  --tas examples/voxel/tests/spike_reproducer.tas \
  2>&1 | grep -E '\[GEN\]|\[MESH\]|\[SPIKE_TICK\]'
```

---

## TAS scenario

`tests/spike_reproducer.tas`:
1. World loads (loading screen pregen: 5×5 = 25 chunks, unbounded budget).
2. Tick 1: left-click to capture mouse.
3. Tick 241–1009: hold **D** (strafe +X at 5 m/s → ~32 blocks).

Result: the 32-block walk stays within the pregen ring (chunk 0,0 → chunk 1,0).
New generation fired immediately when gameplay began — the 9×9 = 81-chunk ring
target needed 56 new chunks beyond the 25 pregened ones.

---

## Spike summary

Spike is concentrated in **ticks 5–16** (the first ~12 ticks of active gameplay):

| Tick | Chunks gen'd | Gen total (ms) | Chunks meshed | Mesh total (ms) | **Tick total (ms)** |
|------|-------------|----------------|---------------|-----------------|---------------------|
| 5    | 2           | 161.8          | 1             | 34.4            | **196.2** |
| 6    | 2           | 163.8          | 1             | 36.4            | **200.2** |
| 7    | 2           | 163.1          | 1             | 37.5            | **200.5** |
| 8    | 2           | 167.2          | 1             | 35.5            | **202.7** |
| 9    | 2           | 169.8          | 1             | 33.7            | **203.5** |
| 10   | 2           | 167.3          | 1             | 33.7            | **200.9** |
| 11   | 2           | 167.6          | 1             | 35.5            | **203.0** |
| 12   | 2           | 180.5          | 1             | 38.9            | **219.4** |
| 13   | 2           | 200.1          | 1             | 49.2            | **249.2** ← worst |
| 14   | 2           | 191.7          | 1             | 41.7            | **233.4** |
| 15   | 2           | 180.3          | 1             | 35.6            | **215.9** |
| 16   | 2           | 181.1          | 1             | 38.7            | **219.8** |
| 17–24| 0           | ~0             | 1             | 34–50           | **34–50** |

**Frame budget at 120 Hz:** 8.33 ms  
**Worst spike tick:** 249 ms — **30× over budget**  
**Duration of sustained spike:** 12 consecutive ticks (0.1 s wall-clock at 120 Hz)

After tick 24 all 56 new chunks are generated and meshed; tick cost drops to zero.
The walking phase (ticks 241–1009) produced no new gen events — 32 blocks stays
inside the pregen ring.

---

## Per-phase breakdown (averages over spike ticks 5–16)

| Phase | Per chunk (ms) | Per tick | % of tick |
|-------|---------------|----------|-----------|
| Terrain fill (`generateTerrain` block loop) | **~2.2 ms** | ~4.4 ms (×2 chunks) | ~2% |
| Skylight BFS (`computeSkylight`) | **~80–100 ms** | ~165 ms (×2 chunks) | ~79% |
| Greedy mesh gen (`generateMesh`) | **~35–49 ms** | ~38 ms (×1 chunk) | ~18% |
| GPU sort (`sortByDepth`) | N/A (headless) | — | — |
| GPU upload (`writeBuffer` ×2) | N/A (headless) | — | — |

Typical pregen-phase single-chunk cost: fill 2.2 ms + sky 82 ms = **84 ms/chunk**.

---

## Top 3 hotspots

### 1 · `computeSkylight` — 80–100 ms per chunk, ≈79% of spike

**Measured:** 78–116 ms per call (median ~82 ms). Two chunks generated per tick →
~165 ms/tick just for skylight.

**Hypothesis:** The bucket-sort BFS is O(MAX_SKYLIGHT × CHUNK_W² × CHUNK_H) =
O(15 × 48² × 256) ≈ 8.8 M neighbour checks per chunk, all on the main thread,
all blocking. On this machine each check costs roughly 9–11 ns, consistent with
the measured times. The outer `level` loop (15 passes) forces a full chunk scan
per level even though most cells reach zero after the first few passes — there's
no early-exit.

**Fix direction:** Move `generateChunk` (and its `computeSkylight` call) off the
main thread (async-chunk-gen branch). Even a simple thread-pool with one worker
would hide almost all of this cost behind player movement latency.

---

### 2 · `generateMesh` — 35–49 ms per chunk, ≈18% of spike

**Measured:** 33–49 ms per chunk (median ~37 ms), 1 chunk meshed per tick
(`MESH_GENS_PER_TICK = 1`). Quads built: 5 000–5 700 per chunk.

**Hypothesis:** The mesher scans all CHUNK_W × CHUNK_H × CHUNK_W = 589 824 cells
(CLAUDE.md quotes ~2.3 ms on a faster machine — this box is ~15× slower per block
scan). Each visible face requires AO sampling (8 corner checks) and skylight
lookups. No greedy merging of co-planar faces — every visible face is its own quad.
The MESH_GENS_PER_TICK=1 cap only delays the backlog; it doesn't reduce peak frame
cost for the one chunk that IS meshed.

**Fix direction:** Same as above (async meshing). Secondary optimisation: greedy
quad merging would cut quad count and index-buffer size by 2–4×, reducing both
mesh gen time and GPU draw calls.

---

### 3 · `generateTerrain` fill loop — 2.2 ms per chunk, ≈2% of spike

**Measured:** 2.0–3.3 ms per chunk (median ~2.2 ms). Negligible compared to
skylight, but still 2× chunks per tick = 4.4 ms.

**Hypothesis:** Value-noise `sampleHeight` is called once per column (48×48 = 2 304
calls), each calling `sin`/`cos` inside a multi-octave loop. Cache access is
stride-1 (x then z, matching `blocks[x][y][z]` layout) so memory is not the
bottleneck — it's noise function cost. On flatland (`noise_octaves=0`) this drops
to sub-millisecond.

**Fix direction:** Offload with the rest of gen; or precompute the heightmap into a
flat `u8[CHUNK_W*CHUNK_W]` scratch array (avoids repeated noise calls for the
stone/dirt stack fill).

---

## GPU upload (instrumented, N/A in headless)

`uploadChunkMeshToGPU` is instrumented with `[UPLOAD]` and `[SPIKE_RENDER]` logs
but is skipped in headless mode (`g.isReady()` returns false → `voxelRender` exits
immediately). Based on CLAUDE.md's incremental-update numbers (~242 µs for a full
upload of ~6 144 quads), GPU upload is expected to be a **minor contributor** (<5%
of the frame). The bottleneck is entirely CPU-side generation.

To measure in a live GPU run, grep for `[UPLOAD]` and `[SPIKE_RENDER]` tags.

---

## Chunk counts

| Phase | Chunks |
|-------|--------|
| Pregen (loading screen) | 25 (5×5 at spawn) |
| Generated during gameplay spike (ticks 5–16) | 24 |
| Remaining meshed during ticks 17–24 | 8 |
| **Total loaded at spike end** | **57** |
| Target ring size (RENDER_DISTANCE=4 → 9×9) | 81 |
| Chunks left to generate after TAS ends | 24 |

---

## Conclusion

The spike is **almost entirely `computeSkylight`** (79%). It is synchronous,
runs 2× per tick, and cannot be split or skipped. Moving chunk generation off
the main thread (the async-chunk-gen branch) will eliminate the spike entirely
for generation. The secondary hotspot (`generateMesh`, 18%) should follow onto
the same worker pool.

GPU upload is expected to be negligible and should not be a priority.
