# Voxel requirements — `REQ-VOXEL-*`

Chunk storage, meshing and the chunk pipeline of `sw_voxel`.

## REQ-VOXEL-001 — A block with a baked model gets the model mesher

- **Status:** active
- **Source:** agent:SWZ-31
- **Origin:** #31
- **Type:** functional
- **Priority:** P1
- **Statement:** Where the content module gives a baked model for a block
  ID, the `sw_voxel` mesher shall mesh each block of that ID from the quads
  of its model, in place of the full cube of the greedy mesher.
- **Rationale:** Slabs, stairs and plants are not full cubes. The game owns
  its model files, so the engine takes only baked quads (position, texture
  coordinates, face, cull face, tint index, shade flag). A world of full
  cubes must give the same packed quads as before, so the greedy output and
  its GPU format do not change: the model quads are separate 16-byte
  records in the same stream.
- **Verification:**
  - Test — `libs/sw_voxel/src/mesher.zig` › "a block with a model gets
    model records and no greedy faces (REQ-VOXEL-001)"
  - Test — `libs/sw_voxel/src/mesher.zig` › "a chunk of full cubes has no
    model records (REQ-VOXEL-001)"
  - Test — `examples/voxel/stages_test.zig` › "stages: mesh gives the
    model quads of World after edits (REQ-VOXEL-001)"
- **Relations:** none

## REQ-VOXEL-002 — A full cube hides a model quad with a cull face

- **Status:** active
- **Source:** agent:SWZ-31
- **Origin:** #31
- **Type:** functional
- **Priority:** P1
- **Statement:** If the neighbour cell in the cull face direction of a
  model quad holds a full cube, then the `sw_voxel` mesher shall not make
  a record for that quad.
- **Rationale:** A quad on the side of the cell is hidden when a full cube
  touches it. Without the cull, a wall of half blocks draws each hidden
  side. A block with a model does not hide a quad, because it does not
  fill its cell.
- **Verification:** Test — `libs/sw_voxel/src/mesher.zig` › "a quad with a
  cull face is not drawn next to a full cube (REQ-VOXEL-002)"
- **Relations:** refines REQ-VOXEL-001

## REQ-VOXEL-003 — The content gives the opacity and the emission of each block

- **Status:** active
- **Source:** agent:SWZ-32
- **Origin:** #32
- **Type:** functional
- **Priority:** P1
- **Statement:** When light goes into a cell, the `sw_voxel` light engine
  shall decrease the light by max(1, opacity) of the block in that cell,
  where the content module gives the opacity (0 to 15) and the emission
  (0 to 15) of each block ID.
- **Rationale:** A slab or a plant does not fill its cell. When each block
  with a model stopped all light, the face of a full cube next to a slab
  was dark. The game knows which blocks let light through, so the content
  gives the opacity. With no opacity in the content, air is 0 and all
  other blocks are 15, which is the light of the engine before this change.
- **Verification:**
  - Test — `libs/sw_voxel/src/light.zig` › "computeSkylight and
    computeBlockLight follow the light rules with mixed opacity
    (REQ-VOXEL-003)"
  - Test — `libs/sw_voxel/src/mesher.zig` › "the face of a full cube next
    to a half block gets the sky light (REQ-VOXEL-003)"
- **Relations:** none

## REQ-VOXEL-004 — Sky light falls straight down without loss

- **Status:** active
- **Source:** agent:SWZ-32
- **Origin:** #32
- **Type:** functional
- **Priority:** P1
- **Statement:** The `sw_voxel` light engine shall give sky light 15 to
  each cell that has no cell with opacity more than 0 above it in its
  column, and spread sky light to the sides with a loss of 1 for each
  step through a cell with opacity 0.
- **Rationale:** Open sky lights the ground under it at full level, at
  any height. Under an overhang, the light falls off with the distance
  from the open sky, so caves become dark.
- **Verification:** Test — `libs/sw_voxel/src/light.zig` › "sky light
  falls straight down without loss and spreads to the sides with a loss
  of 1 (REQ-VOXEL-004)"
- **Relations:** refines REQ-VOXEL-003

## REQ-VOXEL-005 — An edit updates the light incrementally

- **Status:** active
- **Source:** agent:SWZ-32
- **Origin:** #32
- **Type:** quality
- **Priority:** P1
- **Statement:** When an edit places or removes a block, the `sw_voxel` light
  engine shall remove the light that can come from the edited cell, then
  fill the removed cells again, to the same light as a full recompute.
- **Rationale:** A full relight of the chunk and its neighbours for each
  edit costs much more time than an update of the cells that change. The
  chunk workers keep their light current after an edit, so a light job
  after the edit does not light the 44-cell window again.
- **Verification:**
  - Test — `libs/sw_voxel/src/light.zig` › "an edit updates the light
    incrementally to the light of a full recompute (REQ-VOXEL-005)"
  - Test — `libs/sw_voxel/src/light.zig` › "a chunk worker updates its
    cached light on an edit (REQ-VOXEL-005)"
- **Relations:** depends-on REQ-VOXEL-003

## REQ-VOXEL-006 — A moving box stops at the collision boxes of the blocks

- **Status:** active
- **Source:** agent:SWZ-51
- **Origin:** #51
- **Type:** functional
- **Priority:** P2
- **Statement:** When a game moves a box by a vector through the world,
  the `sw_voxel` collision shall stop the box, one axis at a time, at the
  collision boxes that the content module gives for each block ID in all
  the cells on the path of the box.
- **Rationale:** A player or a projectile must not go into a block or
  through a wall, at any speed. The test of each cell on the path, and not
  only of the cells at the end of the move, stops a fast box at a wall of
  one block. Slabs, posts and plants are not full cubes, so the content
  gives the boxes of each block. With no declaration, air has no box and
  every other block is a full cube. The step-up lets a box climb a block
  that is lower than the step height.
- **Verification:**
  - Test — `libs/sw_voxel/src/collision.zig` › "a high speed does not go
    through a wall of one block (REQ-VOXEL-006)"
  - Test — `libs/sw_voxel/src/collision.zig` › "corners: an outer corner
    and an inner corner (REQ-VOXEL-006)"
  - Test — `libs/sw_voxel/src/collision.zig` › "step-up climbs a low block
    and not a high block (REQ-VOXEL-006)"
  - Test — `libs/sw_voxel/src/collision.zig` › "blocks smaller than a full
    cube (REQ-VOXEL-006)"
- **Relations:** none

## REQ-VOXEL-007 — A voxel ray cast gives the first block, its face and the distance

- **Status:** active
- **Source:** agent:SWZ-51
- **Origin:** #51
- **Type:** functional
- **Priority:** P2
- **Statement:** When a game casts a ray through the world, the `sw_voxel`
  ray cast shall return the cell, the block, the entry face and the
  distance of the first collision box that the ray hits within the
  maximum distance.
- **Rationale:** Block selection, hit scans and the wall stop of the
  third-person camera need the nearest block on a line. The ray cast goes
  through the cells in order (a DDA), so it reads only the cells on the
  line. It tests the boxes of each block, so the ray goes over a half
  block and through a block with no box.
- **Verification:**
  - Test — `libs/sw_voxel/src/collision.zig` › "ray cast on diagonals
    agrees with a test of each box (REQ-VOXEL-007)"
  - Test — `libs/sw_voxel/src/collision.zig` › "a ray that starts in a
    block hits it at distance 0 (REQ-VOXEL-007)"
  - Test — `libs/sw_voxel/src/collision.zig` › "the camera adapter stops
    the third-person eye at a wall of blocks (REQ-VOXEL-007)"
- **Relations:** depends-on REQ-VOXEL-006

## REQ-VOXEL-008 — Each corner gets AO and smooth light

- **Status:** active
- **Source:** agent:SWZ-33
- **Origin:** #33
- **Type:** functional
- **Priority:** P2
- **Statement:** The `sw_voxel` mesher shall give each corner of a full
  cube face, and of a model quad on the side of its cell, an ambient
  occlusion value from its 3 neighbour blocks and a smooth light value
  (the mean light of the 4 cells at the corner, from the light engine),
  unless the mesher options turn AO or smooth light off.
- **Rationale:** AO darkens the inner corners, and smooth light gives a
  gradient in place of a step at each cell. A demo must show the scene
  with each one on and off, so the options turn them off: AO 1 on each
  corner, and flat light (the light of the cell in front of the face). A
  model quad off the cell grid gets flat light and AO 1, because the
  corner samples do not touch it.
- **Verification:**
  - Test — `libs/sw_voxel/src/mesher.zig` › "a corner gets its AO from its
    3 neighbour blocks: 0 to 3 occluders (REQ-VOXEL-008)"
  - Test — `libs/sw_voxel/src/mesher.zig` › "smooth light is the mean light
    of the 4 cells at each corner (REQ-VOXEL-008)"
  - Test — `libs/sw_voxel/src/mesher.zig` › "smooth light off gives each
    face the light of the cell in front of it (REQ-VOXEL-008)"
  - Test — `libs/sw_voxel/src/mesher.zig` › "a model quad on the cell grid
    gets AO and smooth light, a quad off the grid gets flat light
    (REQ-VOXEL-008)"
- **Relations:** depends-on REQ-VOXEL-003

## REQ-VOXEL-009 — The content gives the tint colours

- **Status:** active
- **Source:** agent:SWZ-33
- **Origin:** #33
- **Type:** functional
- **Priority:** P2
- **Statement:** Where the content module gives a tint function, the
  `sw_voxel` mesher shall give each quad with a tint index the colour of
  that function for its block, tint index and world cell.
- **Rationale:** Grass and leaves change colour with the position (for
  example by biome). The game owns the colours, so the engine calls a
  content function. The colours go into tint records at the start of the
  quad stream, so the 16-byte quad format does not grow, and a mesh with
  no tint keeps its bytes.
- **Verification:**
  - Test — `libs/sw_voxel/src/mesher.zig` › "quads with a tint index get
    the tint colour of the content (REQ-VOXEL-009)"
  - Test — `examples/voxel/stages_test.zig` › "stages: mesh gives the
    quads of the greedy mesher through the World getter" (the demo tints
    grass tops and leaves, so the stage must give the tints of World)
- **Relations:** refines REQ-VOXEL-001

## REQ-VOXEL-010 — Greedy meshing merges only equal faces

- **Status:** active
- **Source:** agent:SWZ-33
- **Origin:** #33
- **Type:** functional
- **Priority:** P2
- **Statement:** The `sw_voxel` greedy mesher shall merge two faces only
  when their block, AO, light and tint are equal, and the same on the 4
  corners of each face.
- **Rationale:** A merged quad has the values of one cell on its 4
  corners. If it merged faces with other values, the AO, the light or the
  colour would be wrong, and seams would show between the quads.
- **Verification:** Test — `libs/sw_voxel/src/mesher.zig` › "greedy faces
  with different AO, light or tint do not merge (REQ-VOXEL-010)"
- **Relations:**
  - refines REQ-VOXEL-008
  - refines REQ-VOXEL-009

