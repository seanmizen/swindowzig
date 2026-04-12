# Voxel Project — Bug & Feature Tracker

## Bugs (P0)

### ~~FXAA texture dimension mismatch (voxel:web crashes)~~ FIXED

Fixed: `viewDimensionMap` in `webgpu.ts` was off-by-one (started keys at 1 instead of 0), causing Zig enum `.@"2d"` (value 1) to map to JS `'1d'` instead of `'2d'`. Regression test added: `yarn workspace swindowzig test:web`.

### AO broken at chunk seams

`mesher.zig` AO samples return `.air` for unloaded cross-chunk neighbors, producing too-bright corners at chunk boundaries. The `mesh_dirty` re-mesh triggered by neighbor loading is gated on `MESH_RADIUS_SQ` — chunks outside that radius keep stale AO indefinitely.

Fix: add a `neighbor_ao_dirty` flag that bypasses the distance gate; spread re-meshes across frames to avoid spikes.

### Chunk de-rendering (possible async race)

Eviction radii look correct (R=12 mesh, R=13 evict) but there may be an async race where eviction downgrades chunk state mid-frame during meshing, causing flicker.

Frustum culling (`--frustum=cone` or `--frustum=sphere`) can also over-cull chunks at view boundary angles.

To investigate: reproduce with `--frustum=none`, add state-transition logging.

---

## Features (P1)

### Glowstone placement

Block lighting is fully implemented (BFS propagation, per-vertex integration) and the glowstone block type exists, but glowstone is never placed — not in world gen, not in the player hotbar.

Fix: add glowstone to the hotbar; optionally scatter in caves during world gen.

### Stale TODO comment (`main.zig:871`)

`main.zig:871` reads "TODO: switch to .glowstone once block-light lands" — block light has landed. Remove the comment.
