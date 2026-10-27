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

## REQ-GPU-003 — An animated sprite changes with GPU copies only

- **Status:** active
- **Source:** agent:SWZ-28
- **Origin:** #28
- **Type:** functional
- **Priority:** P1
- **Statement:** When the image of an animated sprite changes,
  `Atlas.update` of `sw_render` shall copy the new image into the atlas
  with GPU texture copies only, one for each mip level, with no texel
  upload from the CPU.
- **Rationale:** An atlas can hold many animated sprites, and they change
  each tick. An upload of the atlas, or of each changed image, sends data
  from the CPU each tick. The frame images go to the GPU one time, with
  their mip levels, and a copy on the GPU is fast.
- **Verification:**
  - Test — `examples/atlas/main.zig` › `--check`: after each time step,
    each mip level of each sprite has the colour of the frame that shows.
  - Test — `libs/sw_render/src/animation.zig` › "player: advance gives an
    image only when the image changes"
- **Relations:** none

## REQ-GPU-004 — The atlas packer keeps each image on the cell grid

- **Status:** active
- **Source:** agent:SWZ-28
- **Origin:** #28
- **Type:** constraint
- **Priority:** P1
- **Statement:** The atlas packer of `sw_render` shall put each image in
  a whole number of power-of-two cells that start at a cell edge.
- **Rationale:** The mip levels of an atlas keep the tiles apart only when
  each tile is on a grid of power-of-two tiles. With the cell as the tile
  size, no mip level mixes two images.
- **Verification:**
  - Test — `libs/sw_render/src/layout.zig` › "pack: each image is on the
    cell grid, in the texture, and apart (REQ-GPU-004)"
  - Test — `examples/atlas/main.zig` › `--check`: each texel of each sprite
    cell has the sprite colour at each mip level.
- **Relations:** refines REQ-GPU-002
