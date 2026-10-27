# GPU requirements — `REQ-GPU-*`

Textures, samplers and other resources of `sw_gpu`.

## REQ-GPU-001 — The GPU makes the mip levels on native and on the web

- **Status:** active
- **Source:** agent:SWZ-27
- **Origin:** #27
- **Type:** functional
- **Priority:** P1
- **Statement:** When a game calls `MipmapGenerator.generate` for a 2D
  texture or a 2D texture array, `sw_gpu` shall record GPU commands that
  make each mip level from the level above it, with the same calls on
  native and on the web.
- **Rationale:** With no mip levels, a texture far away shimmers. The game
  must not make the levels on the CPU and upload each one. The GPU does the
  work in a few passes, and the web build has the same result as the native
  build.
- **Verification:** Test — `examples/mipmaps/main.zig` › `--check`: the GPU
  levels of each layer match the CPU reference of `sw_gpu.mip_chain`.
- **Relations:** none

## REQ-GPU-002 — The mip levels of an atlas do not mix tiles

- **Status:** active
- **Source:** agent:SWZ-27
- **Origin:** #27
- **Type:** constraint
- **Priority:** P1
- **Statement:** Where a game gives a tile size for a texture atlas, each
  mip level that `sw_gpu` makes shall get each texel from the texels of one
  tile only.
- **Rationale:** An atlas holds many small images side by side. If a mip
  level mixes two tiles, the colour of one image shows at the edge of the
  next, far away. The tile size sets the last level: the level where a tile
  is 1 texel.
- **Verification:** Test — `libs/sw_gpu/src/mip_chain.zig` › "mip chain:
  every 2x2 block of an atlas stays in one tile (REQ-GPU-002)"
- **Relations:** refines REQ-GPU-001
