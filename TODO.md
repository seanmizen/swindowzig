# Voxel Project — Bug & Feature Tracker

> **⚠️ DO NOT MARK ANY ITEM AS COMPLETE UNTIL HUMAN HAS VERIFIED.**

## Bugs (P0)

### Glowstone blocks do not emit light

Glowstone blocks exist and can be placed, but they do not actually emit light.
The block-light BFS is either not running for player-placed glowstone or the
light values are not being applied to the renderer.

### Distant chunk borders still shadowed

Chunk borders at distance are visually darker / shadowed. Likely an AO or
lighting artefact at chunk seams that only manifests beyond a certain range.

### Chunks do not reload after being purged

Travelling ~150 blocks away from spawn and returning: chunks that were evicted
from the render do not come back. They appear invisible. Possible cause: evicted
chunks are not being re-queued for generation/meshing when the player re-enters
their load radius.

---

## Bugs (resolved)

### ~~FXAA texture dimension mismatch (voxel:web crashes)~~ FIXED

Fixed: `viewDimensionMap` in `webgpu.ts` was off-by-one (started keys at 1 instead of 0), causing Zig enum `.@"2d"` (value 1) to map to JS `'1d'` instead of `'2d'`. Regression test added: `yarn workspace swindowzig test:web`.

### ~~AO broken at chunk seams~~ (FIXED)

Fixed: added `neighbor_ao_dirty` flag to `LoadedChunk` that bypasses the
`MESH_RADIUS_SQ` distance gate in the sync mesh loop. Chunks in the hysteresis
dead zone now get their AO corrected when a missing neighbour loads. Async drain
path also marks all 8 surrounding neighbours (including diagonals) dirty, matching
`world.zig:generateChunk`. Re-meshes capped at 2 per tick to avoid spikes.

### ~~Chunk de-rendering (possible async race)~~ (FIXED)

Fixed: eviction loop now skips chunks that are in-flight in the async pipeline,
preventing the meshed→evicted→meshed→evicted flicker cycle. Frustum culling math
reviewed and confirmed correct (bounding-sphere slack, 3×3 camera-neighbourhood
safety net, 180° short-circuit all in place).

---

## Features (P1)

### ~~Glowstone placement~~ (DONE)

Fixed: glowstone added to hotbar slot 4. World gen now scatters glowstone in the
stone layer below Y=40 with ~0.2% probability per block (deterministic hash-based
placement). Block-light BFS picks up the emitters at generation time. Stale TODO
comment at `main.zig:871` removed.
