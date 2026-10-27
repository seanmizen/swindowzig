# Engine batch: verification log

This file is the checklist for #103. The cloud agent wrote one entry for each
ticket of #102, in the order of the batch.

## Summary

- Done: 10. Skipped: 3. Not started: 2.
- Setup:
  - ziglang.org and bun.sh are blocked in the cloud sandbox. Zig 0.17.0 came
    from the official `ziglang` wheel on PyPI, and Bun from the npm package
    `@oven/bun-linux-x64`. The other setup steps ran.
  - lavapipe works. So the native `--check` examples, the voxel GPU smoke
    test (under `xvfb-run`) and the lavapipe golden comparison
    (`run_headless_regressions.sh`) ran here. Their results are in each
    entry.
  - The browser tests (`yarn test:browser`) did not run.
  - `apps/action` and `apps/voxel.seanmizen.com` in seanorepo use the copy
    of swindowzig in `utils/swindowzig`. The batch did not build them.

## #66 the sw_voxel frustum uses the sw_math Plane and Aabb

- Status: done
- Commit: see `git log --grep SWZ-66`
- Not run here: the consumer builds in seanorepo (they use their own copy
  of swindowzig).
- Expected changes:
  - quad hash: no change (`8c11e81d4ec42623`)
  - goldens: none. The lavapipe goldens passed here (10 of 10).
- CI changes needed: none
- Requirements: none (a refactor with the same results)
- Open questions: none
- Risks: `setPlanes` now normalizes each plane (`Plane.fromCoefficients`).
  A positive scale does not change the side of a box, so the cull is the
  same. `build.zig` already gave sw_math to sw_voxel, so it did not change.

## #93 `chunk_corner_ao.tas` does not parse

- Status: done
- Commit: see `git log --grep SWZ-93`
- Not run here: nothing. All 16 scripts in `examples/voxel/tests/` now
  exit 0 headless on the flatland world.
- Expected changes:
  - quad hash: no change
  - goldens: none. `chunk_corner_ao` has no golden.
- CI changes needed: optional. A CI step that runs each
  `examples/voxel/tests/*.tas` headless would stop a script that does not
  parse.
- Requirements: none
- Open questions: none
- Risks: the cause was not the two spaces. The tokenizer already accepted
  them. The script used `key_down a`, but the commands are `keydown` and
  `keyup`, and the key names are upper case (`A`). The script now uses the
  correct names. The parser now also accepts a tab between fields, and a
  test covers more than one space and a tab. Separate bug, not fixed: when
  the TAS parse fails, the voxel demo logs a memory leak on exit.

## #76 `voxel --place-block` has no effect

- Status: done
- Commit: see `git log --grep SWZ-76`
- Not run here: nothing. `glowstone_cave.sh` passed under `xvfb-run`:
  core +104, wall near +78, wall rim +34, far grass -0.1.
- Expected changes:
  - quad hash: no change
  - goldens: none (10 of 10 passed)
- CI changes needed: optional. `glowstone_cave.sh` opens a window, so CI
  needs `xvfb-run` to run it.
- Requirements: none
- Open questions: none
- Risks: the flag now accepts each block name of `content.zig`, not only
  `stone` and `glowstone`. It puts the block in hotbar slot 1.
  `State.place_block` is gone.

## #34 fluid surface mesher

- Status: done
- Commit: see `git log --grep SWZ-34`
- Not run here: nothing that the ticket touches. The demo has no fluid
  blocks, so no frame changes.
- Expected changes:
  - quad hash: no change (`8c11e81d4ec42623`). The demo content has no
    fluid, and `fluid.isFluid` is comptime false then.
  - goldens: none (10 of 10 passed)
- CI changes needed: none
- Requirements: REQ-VOXEL-014, REQ-VOXEL-015, REQ-VOXEL-016
- Open questions:
  - The fluid mesher is a library function: `fluid.generate` gives a
    separate vertex stream (`fluid.Vertex`, 24 bytes, 4 for each quad).
    The chunk pipeline (`stages.mesh`, the protocol) and the demo do not
    call it yet. A demo with water needs a fluid block in
    `content.zig`, a fluid stream in the mesh result, and a WGSL pass.
    Decide if that is a new ticket.
  - The content contract has a new optional declaration:
    `fluid(block) ?sw_voxel.fluid.Level`. A fluid block keeps the
    default `collision` and `opacity` of a full cube unless the content
    gives them.
- Risks: `models.isCube` and the AO test (`mesher.isSolid`) are now false
  for a fluid. A section test used a pattern that missed some block
  counts (23 types gave 13 palette entries). The test content now has 25
  types, so the pattern changed to one that covers each count up to 128.

## #35 translucent pass with back-to-front sort

- Status: done, with one acceptance criterion open (see below)
- Commit: see `git log --grep SWZ-35`
- Not run here: nothing. `models --check` passed on lavapipe: the pixel
  through the two quads is `{179, 88, 210}`, difference 0 from the CPU
  blend.
- Expected changes:
  - quad hash: no change (no voxel change)
  - goldens: none. The voxel demo does not change.
- CI changes needed: none. The `models --check` step runs the new check.
- Requirements: REQ-GPU-022, REQ-GPU-023
- Open questions:
  - Not done: "The voxel demo shows correct overlap of two translucent
    blocks." The voxel demo does not use `sw_render`, and the mesher has
    no translucent blocks. A voxel version needs a translucent block in
    the content, a separate translucent quad stream in the mesh result
    (with the protocol and the upload), and a sort on main. Main keeps no
    copy of the quads (C5), so the sort needs the quad centres from the
    worker. That is a larger change than this ticket. The two-quad
    overlap is in `models --check` now. Decide if the voxel part is a new
    ticket.
  - The default order of the pass is 55: after the clouds (50) and
    before the rain and snow (60).
- Risks: `Translucent.addPass` keeps a pointer to the `Translucent`, so
  the game must keep it at one address (the same rule as `BoxModels`).

## #42 particle system with billboards

- Status: done
- Commit: see `git log --grep SWZ-42`
- Not run here: the interactive emitter of the `models` example (it runs
  only with a window). `models --check` passed on lavapipe: the pixel
  through the two check particles is `{179, 86, 210}`, difference 0, in
  one draw call.
- Expected changes:
  - quad hash: no change
  - goldens: none
- CI changes needed: none. The `models --check` step runs the new check.
- Requirements: REQ-GPU-024, REQ-GPU-025
- Open questions: the pass uses the blend and depth states of the
  translucent pass (#35). Particles and translucent quads sort apart, so
  a particle behind a translucent quad can draw over it. The default
  orders put the particles (58) after the translucent quads (55).
- Risks: `Particles.update` copies the quads of each particle each frame
  (36 bytes for each vertex, 6 vertices for each particle). That is
  216 KB for 1000 particles. A GPU-side billboard (instancing) costs less
  if a game needs many more particles.

## #44 graphics settings, frame pacing and a performance overlay

- Status: done
- Commit: see `git log --grep SWZ-44`
- Not run here:
  - `GPU.setVsync` with a real window. The sandbox has no display, so the
    surface was not configured again with the `immediate` present mode.
  - The F (frame limit) and T (pass times) keys of the `models` example.
  - GPU timestamps on the web. The web build reports no timestamp feature,
    so `PassTimer.init` gives `error.TimestampsNotSupported` there.
- What ran: `models --check` passed on lavapipe. lavapipe has the
  timestamp feature, so the check timed 10 render passes (32.8 ms) with
  the shadows on and 7 passes with the shadows off. The overlay background
  pixel is `{26, 26, 102}`, difference 0.
- Expected changes:
  - quad hash: no change
  - goldens: none
- CI changes needed: none. The `models --check` step runs the new check.
  On a CI GPU with no timestamp feature, the check logs that the pass
  timer is off and does not fail.
- Requirements: REQ-GPU-026, REQ-GPU-027, REQ-GPU-028, REQ-GPU-029
- Open questions:
  - wgpu-native does not give the timestamp period of the queue.
    `PassTimerOptions.period_ns` is 1 by default, which is correct for
    lavapipe and most desktop drivers. Some GPUs (Apple, some mobile) use
    another period.
  - The settings struct is data. The game gives each value to its part
    (`configureMSAA`, `setVsync`, `Lighting`, the atlas mip count). The
    voxel demo does not use the struct yet.
- Risks:
  - The native device now asks for the timestamp feature when the adapter
    has it. This changes the device of each native app. The voxel gate,
    smoke test and goldens ran after the change.
  - `PassTimer.collect` waits for the GPU each frame. Use the timer only
    for debug.

## #81 distance fog as a post effect that reads the depth target

- Status: done
- Commit: see `git log --grep SWZ-81`
- Not run here:
  - A resize with the effect on. The headless check has a fixed surface.
    The chain makes the bind group again at each new target generation,
    the same as the input image.
  - The effect in a browser. The web build compiles.
- What ran: `sky --check` passed on lavapipe, with 2 new steps: noon and
  sunrise with no shader fog and the fog effect on. Each step compares
  228000 pixels with the CPU reference of the shader fog, largest
  difference 1. With the effect off in those steps, 14345 pixels differ
  (largest difference 144), so the check finds a missing effect.
- Expected changes:
  - quad hash: no change
  - goldens: none
- CI changes needed: none. The `sky --check` step runs the new steps.
- Requirements: REQ-GPU-030
- Open questions: the effect fogs each pixel with geometry. Clouds and
  precipitation keep their own fog, and do not write depth. A game that
  uses the effect must not also call `sw_fog` in its scene shaders.
- Risks: `sw_view_distance` reads the projection in `sw_frame.proj`. A
  projection with a rotation or a skew gives a wrong distance.

## #101 light shafts, cloud shadows and soft clouds

- Status: done
- Commit: see `git log --grep SWZ-101`
- Not run here:
  - The H, J and O keys of the `sky` example (they need a window).
  - The effects in a browser. The web build compiles.
  - The cost on a real GPU. The numbers below are from lavapipe, which
    runs on the CPU.
- What ran: `sky --check` passed on lavapipe, with 5 new steps:
  - Soft clouds at noon and at sunrise: 219375 pixels each, 0 differ from
    the CPU reference, largest difference 1. 13131 soft edge pixels, each
    between the cloud and the sky colour.
  - Cloud shadows in the morning: 1275 ground pixels in a shadow, 0
    differ from the CPU reference. 955 of 955 visible shadow pixels are
    darker than the same ground in the sun.
  - Light shafts at sunrise: 19 of 19 pixels under the sun are brighter
    than with no shafts, largest gain 213 (sum of RGB).
  - Light shafts with the sun behind the camera: 228000 pixels, 0 differ
    from the CPU reference with no shafts.
- Cost at 1920 by 1080 (`sky --perf`, ReleaseFast, lavapipe, GPU
  timestamps, mean of 30 frames). For scale, the tonemap pass (one full
  screen pass with one texture read) costs 9.5 ms on lavapipe.
  - Box clouds: cloud pass 13.7 ms.
  - Soft clouds: cloud pass 17.5 ms (+3.8 ms).
  - Cloud shadows: effect 15.2 ms.
  - Light shafts (48 samples): effect 176.5 ms. The effect reads the
    depth and the colour 48 times for each pixel. Use fewer samples or a
    half-size target on a slow device.
- Expected changes:
  - quad hash: no change
  - goldens: none
- CI changes needed: none. The `sky --check` step runs the new steps.
  `sky --perf` is a manual tool.
- Requirements: REQ-GPU-031, REQ-GPU-032, REQ-GPU-033
- Open questions:
  - The cloud shadow is one sample of the layer middle, so its edge is
    hard. A soft edge needs more samples.
  - `Clouds.setEnabled(false)` does not turn off the shadow effect. The
    game turns it off with `post.setEffectEnabled`.
  - The light shafts start from the bright sky in screen space. When the
    sun is off the screen, the shafts become weak.
- Risks: the light shafts are the costliest effect. The default of 48
  samples is for a desktop GPU.

## #26 sw_jobs worker pool for native threads and Web Workers

- Status: skipped
- Commit: see `git log --grep SWZ-26`
- Reason: the ticket does not fit in the time limit of one ticket. It has
  three large parts:
  - a generic `sw_jobs` pool from `pipeline/exec_threads.zig` and
    `pipeline/exec_web.zig`, with tests for order, cancel and shutdown.
  - the move of `sw_voxel` to it, with `stage_match=yes`.
  - a SharedArrayBuffer mode in `backends/wasm/worker-pool.ts`.
- Open questions:
  - `backends/wasm/worker-pool.ts` says "No SharedArrayBuffer and no wasm
    threads (section 11)": each message is a transferred ArrayBuffer, so
    no copy occurs now. The acceptance criteria ask for
    SharedArrayBuffer when the page is cross-origin isolated, and copies
    when it is not. Sean must decide if that design changes, and what the
    shared mode gives (a ring buffer with no postMessage, or wasm
    threads).
  - Proposal: split the ticket. Part 1: native `sw_jobs` and the move of
    `exec_threads.zig`. Part 2: the web side and the SharedArrayBuffer
    decision.
- Risks: none. No code changed.

## #39 far terrain level of detail in sw_voxel

- Status: skipped
- Commit: see `git log --grep SWZ-39`
- Reason: the ticket does not fit in the time limit of one ticket. A
  pure stage that makes a coarse mesh is small. But "chunks past a set
  distance use" it needs changes to the chunk pipeline design:
  - the mesh Job message (`protocol.zig`) needs the level, so the
    protocol version changes, and `worker_world.zig` must handle it.
  - the scheduler must keep the mesh level of each chunk, and remesh a
    chunk when the player moves it over a level border.
  - the border between two levels needs skirts or a stitch, and a test
    that finds no gap in a rendered frame.
- Open questions:
  - Can a coarse quad use the current PackedQuad format? A quad of
    factor 2, 4 or 8 fits in the chunk-local position and size fields.
    The light and the AO of a coarse quad need a rule.
  - Proposal: split the ticket. Part 1: the pure LOD stage, with skirts
    and tests. Part 2: the scheduler and the protocol.
- Risks: none. No code changed.

## #40 occlusion culling and cave culling for chunks and entities

- Status: skipped
- Commit: see `git log --grep SWZ-40`
- Reason: the ticket does not fit in the time limit of one ticket. The
  flood fill of the faces of a section and the walk from the camera
  section are pure, but the renderer draws one mesh for each chunk
  column, not one mesh for each 16-cell section. Cave culling needs:
  - the face connections of each section in the mesh result (a
    protocol change).
  - a mesh for each section, or a draw range for each section, in the
    voxel renderer.
  - a benchmark in a cave that compares the drawn chunks and the frame
    (a golden image with culling on and off).
- Open questions:
  - The occlusion queries need the timestamp-style query support of
    `sw_gpu` (#44 added timestamp query sets). Occlusion query sets are
    not in `sw_gpu` yet.
  - Proposal: split the ticket. Part 1: the section face graph and the
    walk, pure and tested, plus the box culling call. Part 2: draw
    ranges for each section in the renderer, and the cave benchmark.
- Risks: none. No code changed.

## #55 chunk streaming with priority

- Status: done
- Commit: see `git log --grep SWZ-55`
- What changed:
  - The scheduler already had the load and unload radius with one band
    of hysteresis, and the classes sim, edit, view and other. The batch
    did not change these.
  - New: `sw_voxel.streaming.pickUploads` sorts the waiting mesh uploads
    (in view first, then nearest) and keeps a number of them. The voxel
    demo uploads at most 24 meshes in one frame during gameplay. The
    loading screen has no limit.
  - The scheduler gives the class sim to the light of the ring around
    the simulation radius and to the blocks to 4 chunks from the player.
    Before, only the jobs inside the simulation radius had the class.
- What ran: the voxel gate. Goldens 10 passed, `stage_match=yes`, the
  headless TAS and the smoke test passed.
- New test: `scheduler_test.zig` moves the camera one chunk east every 2
  frames for 60 frames, with about 12 jobs each frame. A chunk in the 3
  by 3 square around the player has no mesh for at most 2 frames.
  Measured, before the class change: holes of 40 frames at 12 jobs each
  frame. After: 0 frames at 12 jobs, and long holes again at 9 jobs or
  fewer.
- Not run here:
  - A play test with a real window. The upload limit is a constant, not
    a measured time, because the upload time on lavapipe is not the time
    on a real GPU.
- Expected changes:
  - quad hash: no change
  - goldens: none
- CI changes needed: none. `zig build test` runs the new tests.
- Requirements: REQ-VOXEL-017, REQ-VOXEL-018
- Open questions: should the upload limit be a time (for example 2 ms)
  instead of a count? A time needs a GPU timestamp of each upload.
- Risks: during gameplay, a burst of new meshes takes more frames to show.
  The meshes in view show first.
