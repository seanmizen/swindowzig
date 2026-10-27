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

## REQ-GPU-005 — The frame graph runs the passes in a set order on targets that follow the window

- **Status:** active
- **Source:** agent:SWZ-29
- **Origin:** #29
- **Type:** functional
- **Priority:** P1
- **Statement:** When a game calls `FrameGraph.execute` of `sw_render`,
  the graph shall run the passes from the lowest `order` to the highest,
  each on targets that have the size of the surface of that frame.
- **Rationale:** Many render features (post effects, translucency, sky,
  shadows) add passes that read the targets of other passes. One set order
  and one place that changes the target sizes stop each feature from doing
  this work again, and stop a pass from drawing to a target of the old size.
- **Verification:**
  - Test — `libs/sw_render/src/plan.zig` › "plan: passes run by order, and
    equal orders keep the add sequence (REQ-GPU-005)"
  - Test — `libs/sw_render/src/plan.zig` › "plan: a surface target follows
    the surface size (REQ-GPU-005)"
- **Relations:** none

## REQ-GPU-006 — Per-frame data uses no new GPU buffer each frame

- **Status:** active
- **Source:** agent:SWZ-29
- **Origin:** #29
- **Type:** constraint
- **Priority:** P1
- **Statement:** While a frame graph runs frames, the uniform ring and the
  staged uploads of `sw_render` shall write the per-frame data into the GPU
  buffers that they made at the start, with no new GPU buffer and no new
  allocation after the first frames.
- **Rationale:** A new buffer for each frame or each draw costs a GPU
  allocation and, on the web, more calls into JavaScript. One ring with
  dynamic offsets and one write for each frame keep the cost flat.
- **Verification:**
  - Test — `libs/sw_render/src/ring.zig` › "ring: one write for each frame,
    and no new memory after init (REQ-GPU-006)"
  - Test — `libs/sw_render/src/upload.zig` › "uploads: a frame after the
    first makes no new allocation (REQ-GPU-006)"
- **Relations:** none

## REQ-GPU-007 — The WGSL prefix matches the frame uniforms

- **Status:** active
- **Source:** agent:SWZ-29
- **Origin:** #29
- **Type:** constraint
- **Priority:** P1
- **Statement:** The shared WGSL prefix of `sw_render` shall declare the
  frame uniforms at group 0 binding 0 with the same members, sizes and
  offsets as `FrameUniforms`.
- **Rationale:** Each pass reads the camera and the viewport from one
  binding. If the WGSL struct and the Zig struct differ, every shader reads
  wrong values with no error.
- **Verification:** Test — `libs/sw_render/src/wgsl.zig` › "wgsl: SwFrame
  in the prefix has the layout of FrameUniforms (REQ-GPU-007)"
- **Relations:** none
