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
