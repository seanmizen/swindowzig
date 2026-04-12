# Voxel Project — Bug & Feature Tracker

## Bugs (P0)

### FXAA texture dimension mismatch (voxel:web crashes)

The FXAA post-processing shader declares its texture binding as `TextureViewDimension::e1D` but the actual texture view is 2D.

```
Dimension (TextureViewDimension::e2D) of [TextureView] doesn't match the expected dimension (TextureViewDimension::e1D).
```

Crashes the entire render pipeline on web. Fix: change the dimension enum in the FXAA shader bind group layout to `e2D`. Also audit the Zig-side bind group layout creation in the FXAA pass.

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
