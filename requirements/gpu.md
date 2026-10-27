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
- **Verification:**
  - Test — `libs/sw_render/src/wgsl.zig` › "wgsl: SwFrame in the prefix
    has the layout of FrameUniforms (REQ-GPU-007)"
  - Test — `libs/sw_render/src/wgsl.zig` › "wgsl: SwSky in the prefix has
    the layout of SkyUniforms (REQ-GPU-007)"
- **Relations:** none

## REQ-GPU-008 — The scene renders to an HDR target, and a tonemap writes display colour

- **Status:** active
- **Source:** agent:SWZ-30
- **Origin:** #30
- **Type:** functional
- **Priority:** P2
- **Statement:** When a game makes a `PostChain` of `sw_render`, the
  tonemap pass of the chain shall map the linear colour of the
  `rgba16float` scene target to display colour with the exposure, the curve
  and the sRGB encode of the CPU reference `post.tonemapChannel`.
- **Rationale:** Light, sky and fog give colour values over 1. An 8-bit
  target clips them. One tonemap at the end of the frame keeps the detail,
  and one CPU reference lets a test check the shader with no GPU.
- **Verification:**
  - Test — `libs/sw_render/src/post_plan.zig` › "post: the tonemap curves
    map HDR colour into 0 to 1 (REQ-GPU-008)"
  - Test — `libs/sw_render/src/post_plan.zig` › "post: the sRGB encode
    (REQ-GPU-008)"
  - Test — `libs/sw_render/src/post_plan.zig` › "post: SwTonemap in the
    tonemap shader has the layout of TonemapUniforms (REQ-GPU-008)"
  - Demonstration — `justabox --check` (native, in CI) reads the screen
    back and compares the background with the CPU reference.
- **Relations:** refines REQ-GPU-005

## REQ-GPU-009 — The post chain runs its passes in order, and FXAA is one link

- **Status:** active
- **Source:** agent:SWZ-30
- **Origin:** #30
- **Type:** functional
- **Priority:** P2
- **Statement:** While a `PostChain` runs, the chain shall run its enabled
  links (the HDR effects, the tonemap, the LDR effects, then FXAA) as frame
  graph passes in that sequence, with each link on the output of the
  enabled link before it and the last enabled link on the screen.
- **Rationale:** Sky, fog, shadows and the graphics settings add passes to
  this chain. One route that skips the disabled links stops each feature
  from wiring its own targets. FXAA uses the same shader source as
  `GPU.configureFXAA`, so the two paths cannot drift.
- **Verification:**
  - Test — `libs/sw_render/src/post_plan.zig` › "post: the links run in
    sequence, and each reads the output of the one before (REQ-GPU-009)"
  - Test — `libs/sw_render/src/post_plan.zig` › "post: a disabled link is
    skipped, and the route closes the gap (REQ-GPU-009)"
  - Test — `libs/sw_gpu/src/fxaa.zig` › "fxaa: the group token sets the
    group of the scene texture and sampler (REQ-GPU-009)"
  - Demonstration — `justabox --check` (native, in CI) turns FXAA off and
    checks that FXAA changed the box edges and nothing else.
- **Relations:** refines REQ-GPU-005

## REQ-GPU-010 — The sky pass draws the sky from a time of day

- **Status:** active
- **Source:** agent:SWZ-36
- **Origin:** #36
- **Type:** functional
- **Priority:** P2
- **Statement:** While a `Sky` of `sw_render` is in a frame graph, the sky
  pass shall draw a gradient, a sun disc, a moon disc and stars at night, or
  a cube map in place of the gradient, with the colours of the CPU reference
  `sky.passColor` at the time of day of the sky.
- **Rationale:** The sun, the moon, the sky colours and the stars must
  agree with the time of day that the game sets. One CPU reference lets a
  test check the shader, and gives the game the same colours for its own
  light.
- **Verification:**
  - Test — `libs/sw_render/src/sky_plan.zig` › "sky: the time of day moves
    the sun and the moon (REQ-GPU-010)"
  - Test — `libs/sw_render/src/sky_plan.zig` › "sky: the colours follow the
    sun, and the stars show at night only (REQ-GPU-010)"
  - Test — `libs/sw_render/src/sky_plan.zig` › "sky: the gradient goes from
    the horizon to the zenith, and the sun is a disc (REQ-GPU-010)"
  - Test — `libs/sw_render/src/sky_plan.zig` › "sky: the stars turn with
    the sun, and a part of the cells have a star (REQ-GPU-010)"
  - Demonstration — `sky --check` (native, in CI) reads the screen back at
    noon, at sunrise, at midnight and with the cube map, and compares the
    sky with the CPU reference after the tonemap.
- **Relations:** refines REQ-GPU-008

## REQ-GPU-011 — The distance fog fades into the sky colour at the horizon

- **Status:** active
- **Source:** agent:SWZ-36
- **Origin:** #36
- **Type:** functional
- **Priority:** P2
- **Statement:** When a scene shader calls `sw_fog` from the shared WGSL
  prefix, the fog shall mix the colour into the fog colour from the fog
  start to the fog end that the game sets, with the sky colour at the
  horizon as the default fog colour.
- **Rationale:** A far object in full fog must have the colour of the sky
  behind it. If the fog colour and the sky differ, the edge of the view
  distance shows as a line.
- **Verification:**
  - Test — `libs/sw_render/src/sky_plan.zig` › "sky: the fog uses the
    horizon colour, from the start to the end (REQ-GPU-011)"
  - Demonstration — `sky --check` (native, in CI) compares the fogged
    ground with the CPU reference, and the ground in full fog with the sky
    at the horizon.
- **Relations:** refines REQ-GPU-010

## REQ-GPU-012 — The web bridge keeps no surface view or command object from an earlier frame

- **Status:** active
- **Source:** agent:SWZ-68
- **Origin:** #68
- **Type:** functional
- **Priority:** P1
- **Statement:** When the web build submits a frame, the WebGPU bridge
  shall drop the handles of the canvas view, the encoders, the passes and
  the command buffers of that frame.
- **Rationale:** The canvas gives a new texture for each frame, and the
  frame graph gets the view of it in each frame. Native
  releases these objects at the same points. Before this requirement, the
  bridge kept about six handles for each frame, with the canvas texture of
  each frame. The memory of the page increased while the game ran.
- **Verification:** Test — `backends/wasm/tests/canvas.pw.ts` › "justabox
  draws the spinning box on the canvas"
- **Relations:** refines REQ-GPU-005

## REQ-GPU-013 — The web canvas has the screen format of the Zig side

- **Status:** active
- **Source:** agent:SWZ-68
- **Origin:** #68
- **Type:** functional
- **Priority:** P1
- **Statement:** When the web build configures the canvas, the WebGPU bridge
  shall use `bgra8unorm`, the screen format of the Zig pipelines.
- **Rationale:** The preferred canvas format is `rgba8unorm` on Linux and
  Android. With that format, each pipeline that writes the screen failed
  validation, and the canvas stayed black. Every WebGPU canvas supports
  `bgra8unorm`. The cost is one copy for each frame on a device that
  prefers `rgba8unorm`.
- **Verification:** Test — `backends/wasm/tests/canvas.pw.ts` › "justabox
  draws the spinning box on the canvas" (CI runs it on Linux)
- **Relations:** refines REQ-GPU-005

## REQ-GPU-014 — One draw call draws all instances of one box model

- **Status:** active
- **Source:** agent:SWZ-41
- **Origin:** #41
- **Type:** functional
- **Priority:** P2
- **Statement:** When the game adds instances of a box model to a layer of
  `BoxModels`, each with one rotation for each part, the `draw` of that
  layer shall draw all instances of the model with one draw call, each part
  turned about its pivot and moved with its parent.
- **Rationale:** A scene can have many animated figures. One draw call for
  each figure costs a call into the GPU for each figure, and on the web a
  call into JavaScript. The part matrices go into one storage buffer with
  one staged upload, so the cost of a frame grows with the parts only.
- **Verification:**
  - Test — `libs/sw_render/src/box_model_plan.zig` › "box models: a part
    turns about its pivot and follows its parent (REQ-GPU-014)"
  - Test — `libs/sw_render/src/box_model_plan.zig` › "box models: validate
    rejects a bad tree (REQ-GPU-014)"
  - Test — `libs/sw_render/src/box_model_plan.zig` › "box models: the mesh
    has 36 vertices for each box, wound counter-clockwise from outside
    (REQ-GPU-014)"
  - Test — `libs/sw_render/src/box_model_plan.zig` › "box models: the
    shader structs have the layouts of the Zig records (REQ-GPU-014)"
  - Test — `libs/sw_render/src/box_model_plan.zig` › "box models: the CPU
    shade lights the faces that turn to the light (REQ-GPU-014)"
  - Demonstration — `models --check` (native, in CI) draws 67 figures, two
    blocks and a held object, checks that the frame has 3 draw calls, and
    compares a posed hand and two bodies with the CPU reference after the
    tonemap.
- **Relations:** refines REQ-GPU-006

## REQ-GPU-015 — The first-person pass draws in front of the world

- **Status:** active
- **Source:** agent:SWZ-41
- **Origin:** #41
- **Type:** functional
- **Priority:** P2
- **Statement:** While a `BoxModels` first-person pass has a depth range
  near the near plane, the pass shall draw the instances of the
  `.first_person` layer in front of the world geometry that the scene
  passes drew on the same depth target.
- **Rationale:** A held object is near the camera, and a wall or another
  model can be nearer than the object. The object must not go into the
  wall. The pass keeps the world depth, so a later pass can still test
  against the world.
- **Verification:**
  - Test — `libs/sw_render/src/box_model_plan.zig` › "box models: the own
    depth range maps NDC depth into near to far (REQ-GPU-015)"
  - Demonstration — `models --check` (native, in CI) puts a block between
    the camera and the held object. With the depth range, the held object
    shows. With the full depth range, the block covers it.
- **Relations:** refines REQ-GPU-014

## REQ-GPU-016 — A cascaded shadow map shadows the scene from one directional light

- **Status:** active
- **Source:** agent:SWZ-38
- **Origin:** #38
- **Type:** functional
- **Priority:** P2
- **Statement:** While the shadows of a `Lighting` are on, `sw_shadow`
  shall give 0 for a surface point that a shadow caster hides from the
  light, 1 for a point in light, and a 3 x 3 PCF value at the edge. The
  cascade passes draw the casters into one depth map for each cascade.
  By default the light is the sun of `FrameUniforms.sky`, and the moon
  at night.
- **Rationale:** Shadows show where an object is in relation to the
  ground. The cascades give more texels near the camera, so near
  shadows are sharp and far shadows still show. The cascade size does
  not change when the camera turns, and the cascade moves in steps of
  one texel, so the shadow edges do not move when the camera moves.
- **Verification:**
  - Test — `libs/sw_render/src/lighting_plan.zig` › "lighting: the split
    distances grow to the shadow distance (REQ-GPU-016)"
  - Test — `libs/sw_render/src/lighting_plan.zig` › "lighting: each
    cascade holds its view slice, with depth in 0 to 1 (REQ-GPU-016)"
  - Test — `libs/sw_render/src/lighting_plan.zig` › "lighting: the
    cascade moves in whole texels when the camera moves (REQ-GPU-016)"
  - Test — `libs/sw_render/src/lighting_plan.zig` › "lighting: the
    shadow light follows the sun, and the moon at night (REQ-GPU-016)"
  - Test — `libs/sw_render/src/lighting_plan.zig` › "lighting: the CPU
    PCF gives 0 in a cast shadow, 1 in light, and a soft edge
    (REQ-GPU-016)"
  - Test — `libs/sw_render/src/lighting_plan.zig` › "lighting: a ray to
    the light finds the box that casts the shadow (REQ-GPU-016)"
  - Test — `libs/sw_render/src/lighting_plan.zig` › "lighting: SwLighting
    in the include has the layout of LightingUniforms (REQ-GPU-016)"
  - Test — `libs/sw_render/src/box_model_plan.zig` › "box models: the lit
    shader adds the shadow and the point lights (REQ-GPU-016,
    REQ-GPU-017)"
  - Demonstration — `models --check` (native) draws the figures with the
    sun 45 degrees up. It compares the ground in the shadow of a body and
    the same ground in light with the CPU reference, and checks that the
    shadow is darker by the CPU amount.
- **Relations:**
  - refines REQ-GPU-005
  - refines REQ-GPU-014

## REQ-GPU-017 — The lit passes add the point lights of the frame

- **Status:** active
- **Source:** agent:SWZ-38
- **Origin:** #38
- **Type:** functional
- **Priority:** P2
- **Statement:** When the game gives a `Lighting` up to
  `max_point_lights` point lights for a frame, `sw_point_lights` shall
  give the sum of their light on a surface point: the colour times the
  intensity, times a falloff that is 0 at the radius, times the cosine
  of the angle to the surface normal.
- **Rationale:** A game has moving lights, for example a torch that the
  player holds. The lights go into the lighting uniforms each frame, so
  a light that moves needs no new GPU object.
- **Verification:**
  - Test — `libs/sw_render/src/lighting_plan.zig` › "lighting: a point
    light is bright near, 0 at its radius, 0 behind the surface
    (REQ-GPU-017)"
  - Test — `libs/sw_render/src/box_model_plan.zig` › "box models: the lit
    shader adds the shadow and the point lights (REQ-GPU-016,
    REQ-GPU-017)"
  - Demonstration — `models --check` (native) puts a point light near
    the ground. It compares the ground under the light with the CPU
    reference, and checks that the light makes the ground brighter.
- **Relations:** refines REQ-GPU-006

## REQ-GPU-018 — A setting turns the shadows off

- **Status:** active
- **Source:** agent:SWZ-38
- **Origin:** #38
- **Type:** functional
- **Priority:** P2
- **Statement:** While the shadows of a `Lighting` are off, `sw_shadow`
  shall give 1 for each surface point, with no cascade pass in the
  frame.
- **Rationale:** Shadows cost a draw of the casters for each cascade. A
  slow device, or a settings menu, must be able to remove that cost. A
  surface in the shadow then has the colour of the same surface in
  light.
- **Verification:**
  - Test — `libs/sw_render/src/lighting_plan.zig` › "lighting: with the
    shadows off, a shadowed point gets the full light (REQ-GPU-018)"
  - Demonstration — `models --check` (native) turns the shadows off. It
    checks that no shadow draw call runs, and that the ground in the
    shadow point has the colour of the ground in light.
- **Relations:** refines REQ-GPU-016

## REQ-GPU-020 — The cloud layer moves with the wind and takes its shape from the game

- **Status:** active
- **Source:** agent:SWZ-37
- **Origin:** #37
- **Type:** functional
- **Priority:** P3
- **Statement:** While a `Clouds` of `sw_render` is in a frame graph, the
  cloud pass shall draw a box for each filled texel of the shape image of
  the game, at the cloud height, moved by the wind times the time, lit by
  the sky light and faded by the fog, with the colours of the CPU
  reference `weather.cloudSample`.
- **Rationale:** A game gives the cloud shape and the wind, and the engine
  draws the layer. One ray walk in a full-screen pass needs no mesh and no
  upload when the clouds move. The pass writes the depth of the box, so the
  scene hides the clouds behind it. The f64 wrap of the wind and the
  camera on the CPU keeps the shape stable after a long time and far from
  the origin.
- **Verification:**
  - Test — `libs/sw_render/src/weather_plan.zig` › "weather: a ray hits
    the first cloud box, and the wind moves the shape (REQ-GPU-020)"
  - Test — `libs/sw_render/src/weather_plan.zig` › "weather: a large time
    and a far camera keep the precision (REQ-GPU-020)"
  - Test — `libs/sw_render/src/weather_plan.zig` › "weather: the sun
    lights the clouds, and the fog and the fade hide far clouds
    (REQ-GPU-020)"
  - Demonstration — `sky --check` (native, in CI) compares each sky pixel
    in the right half of the screen with the CPU reference of the clouds,
    at noon, at sunrise and 40 seconds later, with the fog.
- **Relations:** refines REQ-GPU-011

## REQ-GPU-021 — Rain and snow fall around the camera and stop at the height map

- **Status:** active
- **Source:** agent:SWZ-37
- **Origin:** #37
- **Type:** functional
- **Priority:** P3
- **Statement:** While a `Precipitation` of `sw_render` is in a frame
  graph, the precipitation pass shall draw each particle of the column
  around the camera that is above the ground height of the height map of
  the game, faded by the fog, and no particle under that height.
- **Rationale:** Rain and snow must not fall through a roof or into the
  ground. The vertex shader makes each particle from its index and the
  time, so the CPU sends no particle data. A particle keeps its world
  position while the camera moves, so the weather does not move with the
  camera. A snow flake has a darker edge, so it shows on a bright sky.
- **Verification:**
  - Test — `libs/sw_render/src/weather_plan.zig` › "weather: the particles
    stay in the column and stay in place while the camera moves
    (REQ-GPU-021)"
  - Test — `libs/sw_render/src/weather_plan.zig` › "weather: particles
    fall, and the wrap of the fall time moves no particle (REQ-GPU-021)"
  - Test — `libs/sw_render/src/weather_plan.zig` › "weather: the height
    map gives the ground under a particle (REQ-GPU-021)"
  - Test — `libs/sw_render/src/weather_plan.zig` › "weather: a snow flake
    has a bright centre, a darker edge, and a soft rim (REQ-GPU-021)"
  - Demonstration — `sky --check` (native, in CI) draws snow and rain over
    a height map with a raised part. Each flake that no other particle
    covers has the CPU reference colour, and each particle under the height
    map leaves the background.
- **Relations:** refines REQ-GPU-011

## REQ-GPU-022 — Translucent quads draw after the opaque scene with no depth write

- **Status:** active
- **Source:** agent:SWZ-35
- **Origin:** #35
- **Type:** functional
- **Priority:** P2
- **Statement:** While a `Translucent` of `sw_render` is in a frame graph,
  the translucent pass shall draw its quads after the opaque pass with the
  depth test on and the depth write off.
- **Rationale:** An opaque surface in front of a translucent quad must hide
  it, so the depth test stays on. A translucent quad must not hide a
  translucent quad behind it, so the pass writes no depth. The blend puts
  each quad over the colour of the scene.
- **Verification:**
  - Test — `libs/sw_render/src/translucent_plan.zig` › "translucent: the
    depth test is on and the depth write is off (REQ-GPU-022)"
  - Demonstration — `models --check` (native, in CI) draws a translucent
    quad under the ground. The pixel through the quads has the CPU blend
    with no colour of that quad.
- **Relations:** none

## REQ-GPU-023 — The translucent pass sorts its quads from far to near

- **Status:** active
- **Source:** agent:SWZ-35
- **Origin:** #35
- **Type:** functional
- **Priority:** P2
- **Statement:** When the camera moves the resort distance or more from
  the position of the last sort, the translucent pass of `sw_render` shall
  sort its quads from far to near.
- **Rationale:** A blend gives the correct colour only when the nearer
  quad draws over the further quads. A sort for each frame costs time
  with no gain while the camera stays near the same position, so the pass
  sorts only after a set distance. The sort changes only the index list,
  so the vertices stay on the GPU.
- **Verification:**
  - Test — `libs/sw_render/src/translucent_plan.zig` › "translucent: the
    sort puts the furthest quad first, and ties keep their order
    (REQ-GPU-023)"
  - Test — `libs/sw_render/src/translucent_plan.zig` › "translucent: a
    camera on the other side reverses the order (REQ-GPU-023)"
  - Test — `libs/sw_render/src/translucent_plan.zig` › "translucent: the
    sort runs again only after the camera moves the resort distance
    (REQ-GPU-023)"
  - Demonstration — `models --check` (native, in CI) gives the quads near
    quad first. The pixel through the two quads has the CPU blend of the
    far quad, then the near quad.
- **Relations:** depends-on REQ-GPU-022

## REQ-GPU-024 — Particles draw as camera-facing quads in one draw call, far to near

- **Status:** active
- **Source:** agent:SWZ-42
- **Origin:** #42
- **Type:** functional
- **Priority:** P3
- **Statement:** While a `Particles` of `sw_render` is in a frame graph,
  the particle pass shall draw each particle of the system as one quad
  that faces the camera, in one draw call, from the furthest particle to
  the nearest.
- **Rationale:** A game can have thousands of particles, so one draw call
  draws them all. Each particle has straight alpha, so the blend is
  correct only from far to near. The step (speed, gravity, drag, life)
  is a pure function, and an emitter takes its random values from its own
  seed, so a replay gives the same particles.
- **Verification:**
  - Test — `libs/sw_render/src/particle_plan.zig` › "particles: gravity,
    drag and life move a particle (REQ-GPU-024)"
  - Test — `libs/sw_render/src/particle_plan.zig` › "particles: an emitter
    makes particles at its rate, in its ranges (REQ-GPU-024)"
  - Test — `libs/sw_render/src/particle_plan.zig` › "particles: the quads
    face the camera and go from far to near (REQ-GPU-024)"
  - Demonstration — `models --check` (native, in CI) gives two particles,
    near particle first. The pixel through them has the CPU blend of the
    far particle, then the near particle, and the pass uses one draw call.
- **Relations:** depends-on REQ-GPU-022

## REQ-GPU-025 — A full particle system drops its oldest particle

- **Status:** active
- **Source:** agent:SWZ-42
- **Origin:** #42
- **Type:** functional
- **Priority:** P3
- **Statement:** If a particle system is full when a new particle starts,
  then the `sw_render` particle system shall put the new particle in the
  place of its oldest particle.
- **Rationale:** The system has a fixed size, so it makes no allocation
  while the game runs. A new particle is more important than an old
  particle that is near the end of its life.
- **Verification:** Test — `libs/sw_render/src/particle_plan.zig` ›
  "particles: the cap drops the oldest particle (REQ-GPU-025)"
- **Relations:** none

## REQ-GPU-026 — A preset sets each graphics setting

- **Status:** active
- **Source:** agent:SWZ-44
- **Origin:** #44
- **Type:** functional
- **Priority:** P3
- **Statement:** When the game selects a quality preset, `sw_render`
  shall give a `GraphicsSettings` with the render distance, the
  anti-aliasing, the mip levels, the shadows and vsync of that preset.
- **Rationale:** A settings menu changes one struct, and a preset is a
  fast start for a slow or a fast machine. The game gives each value to
  the part that uses it, for example the anti-aliasing to
  `GPU.configureMSAA` and vsync to `GPU.setVsync`.
- **Verification:**
  - Test — `libs/sw_render/src/settings.zig` › "settings: each preset is
    better than or equal to the preset below it (REQ-GPU-026)"
  - Test — `libs/sw_render/src/settings.zig` › "settings: a preset
    matches itself, and a changed value matches no preset (REQ-GPU-026)"
  - Test — `libs/sw_render/src/settings.zig` › "settings: the
    anti-aliasing gives the sw_gpu configuration (REQ-GPU-026)"
- **Relations:** none

## REQ-GPU-027 — The frame limiter holds a target frame rate

- **Status:** active
- **Source:** agent:SWZ-44
- **Origin:** #44
- **Type:** functional
- **Priority:** P3
- **Statement:** While a frame limiter has a target frame rate, the
  `sw_render` frame limiter shall give a wait that starts each frame one
  interval after the start of the previous frame.
- **Rationale:** A frame rate limit saves power and gives an even frame
  time. The frames start at equal intervals, so a short wait after a slow
  frame keeps the mean rate at the target. After a frame that is late by
  more than one interval, the limiter starts again and does not try to
  catch up.
- **Verification:**
  - Test — `libs/sw_render/src/frame_pacing.zig` › "frame pacing: the
    limiter waits until the next frame start (REQ-GPU-027)"
  - Test — `libs/sw_render/src/frame_pacing.zig` › "frame pacing: a
    frame late by more than one interval starts again from now
    (REQ-GPU-027)"
- **Relations:** none

## REQ-GPU-028 — GPU timestamps time each render pass

- **Status:** active
- **Source:** agent:SWZ-44
- **Origin:** #44
- **Type:** functional
- **Priority:** P3
- **Statement:** Where the device has the timestamp query feature, while
  a frame graph has a `PassTimer`, the frame graph shall give the GPU
  time of each render pass of the frame.
- **Rationale:** The CPU time of a frame does not show which pass is
  slow on the GPU. The timer waits for the GPU to read the times, so it
  is for a debug overlay. The web build has no timestamps yet.
- **Verification:**
  - Test — `libs/sw_render/src/frame_pacing.zig` › "frame pacing: GPU
    timestamps to milliseconds (REQ-GPU-028)"
  - Demonstration — `models --check` (native, in CI) sets a pass timer
    when the device has timestamps. The scene, translucent, particle and
    overlay passes must each have a time.
- **Relations:** none

## REQ-GPU-029 — The overlay draws a frame-time chart with sw_gfx2d

- **Status:** active
- **Source:** agent:SWZ-44
- **Origin:** #44
- **Type:** functional
- **Priority:** P3
- **Statement:** When the game draws the frame-time chart, `sw_render`
  shall draw one bar for each frame time, with a height that is the frame
  time over the chart maximum, and a line at the target frame time.
- **Rationale:** A chart shows a frame spike that a mean value hides. A
  bar above the target has a different colour. The chart uses the
  sw_gfx2d renderer, so it draws in the same pass as the other 2D
  shapes of the game.
- **Verification:**
  - Test — `libs/sw_render/src/perf_overlay.zig` › "perf overlay: the
    chart draws the background, one bar for each frame and the line
    (REQ-GPU-029)"
  - Test — `libs/sw_render/src/perf_overlay.zig` › "perf overlay: the bar
    height is the frame time over the chart maximum (REQ-GPU-029)"
- **Relations:** none

## REQ-GPU-030 — A post effect reads the depth target and gives the fog

- **Status:** active
- **Source:** agent:SWZ-81
- **Origin:** #81
- **Type:** functional
- **Priority:** P3
- **Statement:** Where a post chain has the depth fog effect, the post
  chain shall give each pixel with a depth below 1 the colour of
  `sw_fog` at the camera distance from the depth target.
- **Rationale:** Some games cannot change each scene shader to call
  `sw_fog`. The effect gets the distance from the depth and the
  projection in `sw_frame`, so it needs no world position. The chain
  binds the depth view again at each new target generation, so a resize
  does not break the effect.
- **Verification:**
  - Test — `libs/sw_render/src/sky_plan.zig` › "sky: the depth gives the
    camera distance, and the fog post effect gives the sw_fog colour
    (REQ-GPU-030)"
  - Test — `libs/sw_render/src/post_plan.zig` › "post: the fog effect has
    the depth prefix after the input prefix (REQ-GPU-030)"
  - Demonstration — `sky --check` (native, in CI) draws the scene at noon
    and at sunrise with no shader fog and the fog effect on. Each pixel of
    the right half must match the CPU reference of the shader fog.
- **Relations:** depends-on REQ-GPU-011

## REQ-GPU-031 — A cloud puts a moving shadow on the ground under it

- **Status:** active
- **Source:** agent:SWZ-101
- **Origin:** #101
- **Type:** functional
- **Priority:** P2
- **Statement:** Where a post chain has the cloud shadow effect of a cloud
  layer, the post chain shall darken each pixel with geometry whose line
  to the sun crosses a cloud cell of that layer, with the shape, the wind
  and the height of the layer.
- **Rationale:** Moving shadows on the ground make the sky look alive. The
  effect reads the depth target, so the scene shaders do not change. The
  shadow darkens the colour under the fog and not the fog. A shadow of 0
  or the off switch of the effect turns it off.
- **Verification:**
  - Test — `libs/sw_render/src/weather_plan.zig` › "weather: a cloud puts
    a shadow on the ground under it, and the wind moves it (REQ-GPU-031)"
  - Test — `libs/sw_render/src/weather_plan.zig` › "weather: the cloud
    shadow effect has the depth prefix and the cloud uniforms at group 2
    (REQ-GPU-031)"
  - Demonstration — `sky --check` (native, in CI) compares each ground
    pixel of the right half with the CPU reference of the shadow, and
    each visible shadow pixel must be darker than the same ground in the
    sun.
- **Relations:**
  - depends-on REQ-GPU-020
  - depends-on REQ-GPU-030

## REQ-GPU-032 — Soft clouds have semi-transparent edges and a rim toward the sun

- **Status:** active
- **Source:** agent:SWZ-101
- **Origin:** #101
- **Type:** functional
- **Priority:** P2
- **Statement:** While the soft option of a cloud layer is on, the cloud
  pass shall give each cloud pixel an alpha from the length of the view
  ray in the cloud, and a colour with the forward scattering of the sun.
- **Rationale:** A short path at the edge of a cloud gives a partial
  alpha, so the edges are soft. The forward scattering makes a cloud
  between the camera and the sun glow at its thin parts. The box clouds
  stay the default.
- **Verification:**
  - Test — `libs/sw_render/src/weather_plan.zig` › "weather: a soft cloud
    has the alpha of the ray length in it, and a rim toward the sun
    (REQ-GPU-032)"
  - Demonstration — `sky --check` (native, in CI) compares each cloud
    pixel of the right half with the CPU reference of the soft clouds, at
    noon and at sunrise. Each soft edge pixel must be between the cloud
    and the sky colour.
- **Relations:** depends-on REQ-GPU-020

## REQ-GPU-033 — Light shafts go toward the sun on the screen

- **Status:** active
- **Source:** agent:SWZ-101
- **Origin:** #101
- **Type:** functional
- **Priority:** P2
- **Statement:** While the light shaft effect is on and the sun is in
  front of the camera, the post chain shall add to each pixel the bright
  sky colour on the line from the pixel to the sun on the screen.
- **Rationale:** Rays of sunlight through the gaps between clouds and
  objects make the sky look alive. The effect is a radial blur that uses
  the depth target, so the geometry makes the gaps. It has a strength, a
  sample count and an off switch. When the sun is behind the camera, the
  effect does nothing.
- **Verification:**
  - Test — `libs/sw_render/src/shafts_plan.zig` › "shafts: the sun on the
    screen, and no sun behind the camera (REQ-GPU-033)"
  - Test — `libs/sw_render/src/shafts_plan.zig` › "shafts: a pixel under
    the sun gets brighter, and the geometry makes a gap (REQ-GPU-033)"
  - Test — `libs/sw_render/src/shafts_plan.zig` › "shafts: more strength
    gives more light, and the sample count has a limit (REQ-GPU-033)"
  - Demonstration — `sky --check` (native, in CI) compares the pixels
    under the sun at sunrise with the frame with no shafts: they must be
    brighter. With the sun behind the camera, each pixel must match the
    CPU reference with no shafts.
- **Relations:** depends-on REQ-GPU-030
