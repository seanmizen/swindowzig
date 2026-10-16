# Chunk pipeline

The voxel demo has one chunk pipeline for every platform (C1). A scheduler
compares the desired state with the World and makes a queue of jobs. An
executor runs the jobs. The platforms differ only in the executor (P5).
The C and P numbers are the design items of the voxel chunk pipeline
rework.

| File | Purpose |
|------|---------|
| `pipeline/stages.zig` | The pure stages: `generate`, `light`, `mesh` (C2), and the versions (C3). |
| `pipeline/scheduler.zig` | The desired state, the priority order, version checks, eviction, edits (C3, C6, C8). |
| `pipeline/exec_inline.zig` | The Inline executor: jobs on the main thread within a frame budget (C7). |
| `scheduler_test.zig` | Priority order, stale results, eviction with hysteresis, runtime render distance. |
| `stages_test.zig` | The stages give the light and the quads of the reference path in `world.zig`. |

## Stages

A chunk goes through these stages (C2):

1. **Generated.** `generate(seed, config, cx, cz)` gives the blocks.
2. **Lit.** `light` reads the blocks of the 3×3 chunks around the chunk and
   gives the light of the middle chunk.
3. **Meshed.** `mesh` reads the blocks and the light of the 3×3 chunks and
   gives the `PackedQuad` list. It reads the 8 neighbours in place (D8).
4. **Uploaded.** Main copies the quads to the GPU (`upload_pending`).

A light job can start when the 3×3 chunks have blocks. A mesh job can start
when the 3×3 chunks have current light. So the result does not depend on
the order of the installs (P3).

## Versions (C3)

Each chunk has a block version. Generation gives 0, and each edit adds 1.
Each light install gets a new light version, from a counter that never
gives a value two times. When a new light has the same values as the old
light, the chunk keeps the old version, so the meshes that read it stay
current.

A job records the versions of its inputs when it starts (`Inputs`). The
scheduler installs the result only when those versions are still current.
Otherwise it discards the result, and the next plan queues the job again.
A mesh also records the mesh options (AO and lighting mode). The Settings
picker for AO or lighting changes the options, so each mesh becomes stale.

An edit (`Scheduler.editBlock`) changes only the blocks and the version.
It does not relight or mesh. A neighbour result that cannot read the
edited cell stays current: a light reads 14 cells into a neighbour, and a
mesh reads 3 cells. For such a result, the recorded version moves to the
new version.

## Desired state (C8)

Around the player chunk, for render distance R:

| Result | Region |
|--------|--------|
| Mesh | each chunk with dx² + dz² <= R² |
| Light | each chunk next to a chunk that needs a mesh |
| Blocks | each chunk next to a chunk that needs light, and the simulation radius |

`Region` in `scheduler.zig` has the exact functions. A result stays until
its chunk is out of the same region for R + 1 (hysteresis). Thus a chunk at
the edge does not load and unload again when the player moves a little.
An edited chunk keeps its blocks, because the World has no other copy of
the edit.

A change of R in the Settings menu works at runtime. The next plan loads
the new chunks and evicts the chunks past the new R + 1. The test
`scheduler: the render distance changes at runtime` and the TAS
`tests/render_distance_change.tas` check it.

## Priority order (C8)

Each plan sorts the jobs that can start:

1. The simulation radius: the player chunk and the ring around it.
2. Results that an edit made stale (remeshes after edits).
3. Chunks in the view frustum, nearest first. A light job counts as in view
   when a chunk next to it is in view, and a generate job when a chunk
   within 2 chunks is in view.
4. All other chunks, nearest first.

The plan runs only when something changed: the player chunk, R, the mesh
options, the blocks, or an install.

## Frame phase and ticks (C7)

The scheduler and the executor run in the frame phase (`voxelFrame`). The
native loop calls it once per frame, after the ticks and before render,
also in a headless run with no GPU. The web build calls it from
`swindowzig_frame`. A tick never installs a result.

The one exception is the simulation radius (C6). The simulation reads the
blocks of the player chunk and its ring. Each frame loads them first. After
a teleport or a respawn in a tick, a chunk can be missing. Then the tick
generates its blocks inline (`ensureSimRadius`) before the simulation reads
them. Generation is a pure function, so the simulation does not depend on
timing (P4). The simulation reads less than one chunk from the player:
the raycast reach is 5 blocks.

## Frame budget

The Inline executor runs jobs until no job can start or the frame budget is
spent. It checks the clock before each job, so a frame can go past the
budget by one job. A frame with a job that can start always runs one job.

| Phase | Budget |
|-------|--------|
| Loading screen | 12 ms (`LOADING_BUDGET_NS`) |
| Gameplay | 4 ms (`PLAY_BUDGET_NS`) |

The clock is `clock.frameNowNs`: the monotonic clock on native and
`performance.now()` on the web. Native runs all chunk jobs on the main
thread until a ThreadPool executor replaces the Inline executor (C1).

## What "ready" means

There are two checks.

- **Loading screen: `Scheduler.isReady(world, LOADING_READY_RADIUS)`.**
  It is true when each chunk of the simulation radius has blocks, and each
  chunk with dx² + dz² <= r² has a current mesh, with
  r = min(`LOADING_READY_RADIUS`, R). `LOADING_READY_RADIUS` is 5. Then the
  player and the TAS start. The rest of the desired state continues to
  load.
- **`--dump-frame` and `--compare-golden`: `Scheduler.isIdle()`.** It is
  true when the World has the whole desired state for the player chunk, no
  job runs, and nothing changed after the last plan. The capture also
  waits for the TAS to finish. Thus the captured frame does not depend on
  timing.

## Counters (C12)

`Cmd+D` (`Ctrl+D`) shows the debug overlay, and `Cmd+P` (`Ctrl+P`) changes
the page. `--debug-page=pipeline` opens the pipeline page first. The page
shows:

- the jobs in the queue for each stage,
- the job time for each stage (p50 and p95 of the last 64 jobs),
- the install time for each frame (p50 and p95),
- the jobs of the last frame, the installs and the discarded results,
- the chunks that the simulation radius generated inline.

The native log has one `[PIPE]` line for each frame with jobs, and one
summary line at shutdown.

## Measurements (2026-10-15, x86_64 Linux container)

Loading screen time, from start to "World ready", framespike.tas:

| Build | Old chunk paths | Scheduler and Inline executor |
|-------|-----------------|-------------------------------|
| Native Debug, headless | 7.4 s | 5.6 s |
| Native ReleaseFast, headless | 0.66 s | 0.62 s |
| wasm ReleaseFast in Bun, real clock | 1.01 s (121 meshes) | 1.13 s (194 meshes) |

In Bun, the full render distance (441 meshes) took about 2.1 s of frames
after start. The old paths took about 4.3 s for 349 meshes. The worst
gameplay frame went from 14.5 ms to 6.6 ms.

Stage times per chunk, from `zig build bench-stages -Doptimize=ReleaseFast`:
generate 1.2 ms, light 1.3 ms, mesh 0.63 ms.
