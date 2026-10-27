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
