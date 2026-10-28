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

## REQ-VOXEL-011 — A saved region gives the same blocks when it loads

- **Status:** active
- **Source:** agent:SWZ-52
- **Origin:** #52
- **Type:** functional
- **Priority:** P2
- **Statement:** When a game saves chunks to a region file and loads the
  file again, the `sw_voxel` region files shall give the same block in
  each cell of each saved chunk, on native and on the web.
- **Rationale:** A game must keep the edits of the player after it stops.
  The file stores the palette and the packed indices of each section as
  they are, so a load gives the sections of the save. The file has no
  light. The light stage computes the light again from the blocks, so the
  light always agrees with the blocks. The save and the load use the
  storage of `sw_assets.cache`: a folder on native and OPFS on the web.
- **Verification:**
  - Test — `libs/sw_voxel/src/region.zig` › "a generated world gives the
    same blocks after a save and a load (REQ-VOXEL-011)"
  - Test — `libs/sw_voxel/src/region.zig` › "an empty and a full section,
    and each index width (REQ-VOXEL-011)"
  - Test — `libs/sw_voxel/testing/region_store_test.zig` › "a world saves
    to a cache folder and loads with the same blocks (REQ-VOXEL-011)"
  - Test — `backends/wasm/files.test.ts` › "a save and a load give the
    same blocks"
- **Relations:** none

## REQ-VOXEL-012 — A later format reads the region files of version 1

- **Status:** active
- **Source:** agent:SWZ-52
- **Origin:** #52
- **Type:** constraint
- **Priority:** P2
- **Statement:** The `sw_voxel` region decoder shall read each region file
  of format version 1 to the current format version.
- **Rationale:** The saves of the players must stay readable after an
  engine update. Each file has a format version number, and the decoder
  reads each version that it knows. A committed version 1 file for each
  test world height stops a change that cannot read it.
- **Verification:** Test — `libs/sw_voxel/src/region.zig` › "a version 1
  file stays readable (REQ-VOXEL-012)"
- **Relations:** depends-on REQ-VOXEL-011

## REQ-VOXEL-013 — A damaged chunk in a region file fails alone

- **Status:** active
- **Source:** agent:SWZ-52
- **Origin:** #52
- **Type:** functional
- **Priority:** P2
- **Statement:** If the bytes of one chunk in a region file are damaged
  or missing, then the `sw_voxel` region files shall fail the load of that
  chunk and load the other chunks of the region.
- **Rationale:** One bad write or one bad disk sector must not lose a full
  region of a save. Each chunk is compressed on its own, with a CRC-32 and
  a zlib checksum. The game can generate a failed chunk again. A damaged
  header or offset table fails the full file, because it gives no safe
  chunk offsets.
- **Verification:** Test — `libs/sw_voxel/src/region.zig` › "a damaged
  chunk fails alone (REQ-VOXEL-013)"
- **Relations:** depends-on REQ-VOXEL-011

## REQ-VOXEL-014 — A fluid surface has a height at each corner

- **Status:** active
- **Source:** agent:SWZ-34
- **Origin:** #34
- **Type:** functional
- **Priority:** P2
- **Statement:** Where the content gives a fluid and a level for a block,
  the `sw_voxel` fluid mesher shall give the top surface of each cell of
  that block a height at each corner from the levels of the cells at the
  corner.
- **Rationale:** A fluid that flows down a slope must show the slope, and
  two cells next to each other must meet at one height with no gap. A
  corner height is the mean height of the 4 cells at the corner, so two
  cells that share an edge give it the same height. A cell under the same
  fluid is full. The greedy mesher cannot make a quad with 4 heights, so
  fluids have their own vertex stream.
- **Verification:**
  - Test — `libs/sw_voxel/src/fluid.zig` › "the corner heights go down
    from a full cell to a low cell (REQ-VOXEL-014)"
  - Test — `libs/sw_voxel/src/fluid.zig` › "one full fluid cell has 6
    faces, and its top surface is at the surface height (REQ-VOXEL-014)"
  - Test — `libs/sw_voxel/src/fluid.zig` › "the content gives a fluid
    and a level for each fluid block (REQ-VOXEL-014)"
- **Relations:** none

## REQ-VOXEL-015 — Two cells of one fluid have no face between them

- **Status:** active
- **Source:** agent:SWZ-34
- **Origin:** #34
- **Type:** functional
- **Priority:** P2
- **Statement:** When two cells next to each other hold the same fluid,
  the `sw_voxel` fluid mesher shall make no face between the two cells.
- **Rationale:** A face inside a body of fluid shows as a dark plane in a
  translucent fluid, and it costs fill rate. Two different fluids keep
  the faces between them.
- **Verification:** Test — `libs/sw_voxel/src/fluid.zig` › "two cells of
  one fluid have no face between them, two fluids do (REQ-VOXEL-015)"
- **Relations:** refines REQ-VOXEL-014

## REQ-VOXEL-016 — The texture of a fluid surface follows the flow

- **Status:** active
- **Source:** agent:SWZ-34
- **Origin:** #34
- **Type:** functional
- **Priority:** P3
- **Statement:** When a fluid cell has a lower or an open side cell, the
  `sw_voxel` fluid mesher shall turn the UVs of the top surface so that
  the texture v axis points along the flow.
- **Rationale:** A moving texture that follows the slope shows the
  direction of the flow. The flow is the sum of the drops to the side
  cells. A cell with no flow keeps the UVs of the cell and the still
  texture.
- **Verification:**
  - Test — `libs/sw_voxel/src/fluid.zig` › "the top UVs follow the flow
    direction (REQ-VOXEL-016)"
  - Test — `libs/sw_voxel/src/fluid.zig` › "a cell next to a lower cell
    has a flowing top in the direction of the drop (REQ-VOXEL-016)"
- **Relations:** refines REQ-VOXEL-014

## REQ-VOXEL-017 — The mesh uploads of one frame have a limit and a priority

- **Status:** active
- **Source:** agent:SWZ-55
- **Origin:** #55
- **Type:** quality
- **Priority:** P2
- **Statement:** During gameplay, the voxel demo shall upload at most
  `MAX_UPLOADS_PER_FRAME` chunk meshes in one frame, the chunks in view
  first and then the nearest chunks.
- **Rationale:** One install of the chunk pipeline can give many new
  meshes. Each mesh is a GPU upload, and many uploads in one frame make
  a frame spike. The meshes that wait upload in the next frames. The
  loading screen has no limit.
- **Verification:** Test — `libs/sw_voxel/src/pipeline/streaming.zig` ›
  "streaming: the upload budget keeps the chunks in view, nearest first
  (REQ-VOXEL-017)"
- **Relations:** none

## REQ-VOXEL-018 — A fast player has no long hole near the player

- **Status:** active
- **Source:** agent:SWZ-55
- **Origin:** #55
- **Type:** quality
- **Priority:** P2
- **Statement:** When the chunk pipeline runs fewer jobs in one frame
  than the render distance needs, the scheduler shall give the jobs for
  the meshes of the simulation radius the first class.
- **Rationale:** The mesh of a chunk near the player needs the light of
  the next ring and the blocks of the ring after it. When only the mesh
  has the first class, a fast player gets to the chunk before its light
  and blocks. The blocks start one ring early.
- **Verification:** Test — `examples/voxel/scheduler_test.zig` ›
  "scheduler: a fast camera leaves no long hole near the player
  (REQ-VOXEL-018)"
- **Relations:** none

## REQ-VOXEL-019 — Each mesh records which faces of its sections connect

- **Status:** active
- **Source:** agent:SWZ-40
- **Origin:** #40
- **Type:** functional
- **Priority:** P2
- **Statement:** For each 16 × 16 × 16 section of a chunk, the mesh stage
  shall record the pairs of section faces that one region of open cells
  connects.
- **Rationale:** Cave culling needs to know if the camera can see
  through a section. The mesh stage reads the blocks of the chunk, so the
  connectivity costs no more block reads. The result message carries it
  to main with the mesh (protocol version 4).
- **Verification:** Test — `libs/sw_voxel/src/visibility.zig` ›
  "visibility: a section records the face pairs that connect
  (REQ-VOXEL-019)"
- **Relations:** none

## REQ-VOXEL-020 — Cave culling removes only the sections that the camera can not see

- **Status:** active
- **Source:** agent:SWZ-40
- **Origin:** #40
- **Type:** quality
- **Priority:** P2
- **Statement:** The cave cull shall keep each section that a line of
  sight from the camera section reaches through open sections.
- **Rationale:** In a cave, most chunks in the frustum are behind rock.
  The cull walks from the camera section through connected faces, and the
  demo does not draw a chunk column that the walk does not reach. A cull
  that removes a visible section changes the image, so the cull must
  keep each section that it can not prove hidden.
- **Verification:** Test — `libs/sw_voxel/src/visibility.zig` ›
  "visibility: each section on a line of sight is visible, and the walk
  culls a closed cave (REQ-VOXEL-020)"
- **Relations:** depends-on REQ-VOXEL-019

## REQ-VOXEL-021 — Far chunks get a mesh at a lower resolution

- **Status:** active
- **Source:** agent:SWZ-39
- **Origin:** #39
- **Type:** functional
- **Priority:** P2
- **Statement:** When the far terrain distance is more than 0, the
  scheduler shall give each chunk past that distance a mesh of cells of 2,
  4 or 8 blocks, from the distance of the chunk.
- **Rationale:** A far chunk costs as much as a near chunk, but it covers
  few pixels. A mesh of larger cells has fewer quads, so the render
  distance can be larger. The mesh stays a pure stage (C2), and the quads
  keep the PackedQuad format.
- **Verification:**
  - Test — `libs/sw_voxel/src/pipeline/lod.zig` › "lod: level 0 is the
    full mesh, and each level has fewer quads (REQ-VOXEL-021)"
  - Test — `examples/voxel/scheduler_test.zig` › "scheduler: far chunks
    get a mesh at their level of detail (REQ-VOXEL-021)"
- **Relations:** none

## REQ-VOXEL-022 — No gap shows at the border between two levels of detail

- **Status:** active
- **Source:** agent:SWZ-39
- **Origin:** #39
- **Type:** quality
- **Priority:** P2
- **Statement:** At the border between two chunks at any two levels of
  detail, the meshes shall have a face at each point where one side is a
  full cube and the other side is open.
- **Rationale:** A gap at a level border shows the sky or the far
  terrain through the ground. Each coarse cell holds each full cube of
  its blocks, and each mesh reads the real blocks across the border, so
  one of the two meshes always draws the face.
- **Verification:** Test — `libs/sw_voxel/src/pipeline/lod.zig` › "lod:
  no gap at the border between two levels (REQ-VOXEL-022)"
- **Relations:** depends-on REQ-VOXEL-021

## REQ-VOXEL-023 — Each mesh has a draw range for each section

- **Status:** active
- **Source:** agent:SWZ-40
- **Origin:** #40
- **Type:** functional
- **Priority:** P2
- **Statement:** The mesher shall put the quads of a mesh in order of the
  lowest section that each quad touches, and give the end and the highest
  section of the range of each section.
- **Rationale:** With a range for each section, a game draws only the
  sections that the camera can see, not the full column. A quad can go up
  into the sections above it, and a flat quad on a section border is in
  the two sections, so each range records the highest section that its
  quads touch. The sort is stable, and with each section visible the
  game draws the full mesh in one draw, so the image does not change. The
  chunk protocol carries the ranges in the head of a mesh Result.
- **Verification:**
  - Test — `libs/sw_voxel/src/mesher.zig` › "each section has a draw
    range, and each quad is in the range of its lowest section
    (REQ-VOXEL-023)"
  - Test — `examples/voxel/protocol_test.zig` › "protocol: the fields
    are at the documented offsets, little-endian"
- **Relations:** none

## REQ-VOXEL-024 — The demo draws only the sections that the walk reaches

- **Status:** active
- **Source:** agent:SWZ-40
- **Origin:** #40
- **Type:** quality
- **Priority:** P2
- **Statement:** While the cave cull is on, the voxel demo shall draw the
  range of a section only when the walk reaches a section from that
  section to the top of its range.
- **Rationale:** The column cull draws a full column when one section of
  it is visible. The section cull also removes the hidden sections of the
  columns that it draws. The walk records each face that a path enters a
  section through, so it follows each line of sight through a section with
  partial connections. The image must not change.
- **Verification:**
  - Test — `libs/sw_voxel/src/visibility.zig` › "visibility: the walk
    leaves a section through each face that a path entered
    (REQ-VOXEL-024)"
  - Test — `examples/voxel/tests/cave_cull.sh` › each TAS gives the same
    frame with the section cull and with no cull.
- **Relations:**
  - depends-on REQ-VOXEL-020
  - depends-on REQ-VOXEL-023

## REQ-VOXEL-025 — The occlusion cull skips a chunk only while its result is correct

- **Status:** active
- **Source:** agent:SWZ-40
- **Origin:** #40
- **Type:** quality
- **Priority:** P2
- **Statement:** While `--occlusion=on`, the voxel demo shall skip a
  chunk only when its last box test found it hidden, from the same eye and
  with the same meshes on the GPU, and the test had the same view or the
  box was on the screen in full.
- **Rationale:** Occlusion results come back some frames after their
  test. If the demo used an old result after a move or a mesh change, a
  chunk that comes into view would appear late. With the same eye, a turn
  does not change a line of sight, so a box that was on the screen in full
  stays hidden. Each chunk that the other culls keep gets a box test in
  each frame, also when it is not drawn. `--occlusion=off` turns the cull
  off.
- **Verification:** Test — `examples/voxel/tests/cave_cull.sh` › each TAS
  gives the same frame with the occlusion cull and with no cull, and the
  `hills` TAS draws fewer chunks.
- **Relations:** depends-on REQ-GPU-039

## REQ-VOXEL-026 — The demo culls its entity boxes with the visible sections

- **Status:** active
- **Source:** agent:SWZ-40
- **Origin:** #40
- **Type:** functional
- **Priority:** P3
- **Statement:** The voxel demo shall test the box of each entity of its
  list with `visibility.cullBoxes`, and draw only the entities that the
  test keeps.
- **Rationale:** The demo has no game entities. The debug view draws the
  player hitbox and the spawn marker, so these are the entity list. A game
  that adds entities uses the same call.
- **Verification:**
  - Test — `libs/sw_voxel/src/visibility.zig` › "visibility: the box cull
    keeps the boxes in visible sections (REQ-VOXEL-020)"
  - Inspection — `examples/voxel/main.zig`: `cullEntities` and the debug
    draws of the player hitbox and the spawn marker.
- **Relations:** depends-on REQ-VOXEL-020

## REQ-VOXEL-027 — The mesh result carries the fluid quads after the packed quads

- **Status:** active
- **Source:** agent:SWZ-112
- **Origin:** #112
- **Type:** functional
- **Priority:** P2
- **Statement:** When a chunk holds fluid cells, the `sw_voxel` mesh stage
  shall put the quads of `fluid.generate` in the mesh result after the
  packed quads.
- **Rationale:** The fluid quads have 4 corner heights, so they cannot go
  in the greedy stream. The worker makes them with the other quads, and
  the result carries them as a second stream with its count in the head
  of the result. Main does not copy them (C5): it writes them to a GPU buffer from
  the result bytes. A chunk with no fluid gives the payload bytes of
  protocol version 6, so its mesh hash does not change.
- **Verification:**
  - Test — `examples/voxel/protocol_test.zig` › "protocol: a mesh Result
    holds the fluid quads after the quads (REQ-VOXEL-027)"
  - Test — `backends/wasm/worker-pool.test.ts` › "fluid: water gives a
    fluid stream that goes to the GPU from the held bytes
    (REQ-VOXEL-027)"
- **Relations:** depends-on REQ-VOXEL-014

## REQ-VOXEL-028 — The demo draws water in a fluid pass after the opaque chunks

- **Status:** active
- **Source:** agent:SWZ-112
- **Origin:** #112
- **Type:** functional
- **Priority:** P2
- **Statement:** When a chunk mesh has fluid quads, the voxel demo shall
  draw them after the opaque chunks with alpha blend and with the depth
  write off.
- **Rationale:** Water is translucent: the ground under it must show
  through, and a water surface must not hide the terrain behind it from
  the depth test. The chunks draw far to near. The demo generator puts
  water in the low columns only with `--water=on`, so the default terrain
  and its goldens do not change. `--place-block=water` places water.
- **Verification:**
  - Demonstration — the `water_pool` golden of
    `examples/voxel/scripts/run_headless_regressions.sh` (lavapipe, in
    CI): water in a dug hole and on the grass.
  - Test — `examples/voxel/content.zig` › "water fills the low columns to
    the sea level only with the water flag (REQ-VOXEL-028)"
- **Relations:** depends-on REQ-VOXEL-027

## REQ-VOXEL-029 — A translucent block has faces with their centres in world space

- **Status:** active
- **Source:** agent:SWZ-112
- **Origin:** #112
- **Type:** functional
- **Priority:** P2
- **Statement:** Where the content gives a colour for a translucent block,
  the `sw_voxel` translucent mesher shall make each face of a cell of that
  block that is not next to the same block or a full cube, with its
  centre, in world space.
- **Rationale:** Translucent faces must draw far to near, so the game
  needs the centre of each face for the sort. The worker calculates the
  centres, so main does not read the vertices (C5). World space lets the
  game sort the faces of a chunk with no chunk offset, and gives the
  vertices to sw_render `Translucent` as they are. A translucent block is
  not a full cube: the faces of the blocks next to it show, and it does
  not darken AO.
- **Verification:**
  - Test — `libs/sw_voxel/src/translucent.zig` › "a translucent cell has
    6 faces in world space, with a centre for each face (REQ-VOXEL-029)"
  - Test — `libs/sw_voxel/src/translucent.zig` › "two cells of one
    translucent block have no face between them, a full cube hides a face
    (REQ-VOXEL-029)"
- **Relations:** none

## REQ-VOXEL-030 — The mesh result carries the translucent quads and their centres

- **Status:** active
- **Source:** agent:SWZ-112
- **Origin:** #112
- **Type:** functional
- **Priority:** P2
- **Statement:** When a chunk holds translucent cells, the `sw_voxel` mesh
  stage shall put the translucent quads and their centres in the mesh
  result after the fluid quads.
- **Rationale:** The vertices go from the result bytes to a GPU buffer, and
  main reads only the 12 bytes of each centre for the sort (C5). On the
  web, JS counts the centre bytes apart from the quad bytes, so the test
  of C5 still proves that no quad goes into the wasm memory. A chunk with
  no translucent block gives the payload bytes of protocol version 7.
- **Verification:**
  - Test — `examples/voxel/protocol_test.zig` › "protocol: a mesh Result
    holds the translucent quads and their centres after the fluid quads
    (REQ-VOXEL-030)"
  - Test — `backends/wasm/worker-pool.test.ts` › "translucent: glass gives
    a translucent stream from the held bytes, and main reads only the
    centres (REQ-VOXEL-030)"
- **Relations:**
  - depends-on REQ-VOXEL-029
  - depends-on REQ-VOXEL-027

## REQ-VOXEL-031 — The demo draws translucent blocks with sw_render Translucent

- **Status:** active
- **Source:** agent:SWZ-112
- **Origin:** #112
- **Type:** functional
- **Priority:** P2
- **Statement:** When a chunk mesh has translucent quads, the voxel demo
  shall draw them with a sw_render `TranslucentBatch`, sorted far to near
  by the centres from the worker, after the opaque chunks.
- **Rationale:** The demo has its own scene pass, so it uses the pipeline
  and the batches of sw_render with no frame graph (REQ-GPU-040). Each
  chunk has one batch. The chunks draw far to near, and in a chunk the
  batch sorts its quads again only when the camera moves 1 block. The
  generator places no glass, so the default terrain and its goldens do
  not change. `--place-block=glass` places glass.
- **Verification:**
  - Demonstration — the `glass_blocks` golden of
    `examples/voxel/scripts/run_headless_regressions.sh` (lavapipe, in
    CI): two glass blocks on the grass.
- **Relations:**
  - depends-on REQ-VOXEL-030
  - depends-on REQ-GPU-040
  - depends-on REQ-GPU-023
