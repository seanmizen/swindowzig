# Chunk pipeline

The voxel demo has one chunk pipeline for every platform (C1). A scheduler
compares the desired state with the World and makes a queue of jobs. An
executor sends the jobs to the chunk workers, and installs the results.
The platforms differ only in the executor (P5). The C and P numbers are
the design items of the voxel chunk pipeline rework.

| File | Purpose |
|------|---------|
| `pipeline/stages.zig` | The pure stages: `generate`, `light`, `mesh` (C2), and the versions (C3). |
| `pipeline/scheduler.zig` | The desired state, the priority order, version checks, eviction, edits (C3, C6, C8). |
| `pipeline/protocol.zig` | The bytes between main and a worker: Hello, Edit, Job, Result, Error (P6). |
| `pipeline/worker_world.zig` | The world of a worker: the seed, the edit log and an LRU chunk cache (C4, C14). |
| `pipeline/exec_inline.zig` | The Inline executor: one worker on the main thread, within a frame budget (C7). |
| `pipeline/exec_threads.zig` | The ThreadPool executor: native worker threads (C9). |
| `worker_wasm.zig` | The worker side, built for wasm32-freestanding (`zig build worker-wasm`). |
| `scheduler_test.zig` | Priority order, stale results, eviction with hysteresis, runtime render distance. |
| `stages_test.zig` | The stages give the light and the quads of the reference path in `world.zig`. |
| `protocol_test.zig` | Round trip, layout and fuzz tests of the protocol. |
| `exec_test.zig` | The cache limit, and Inline and ThreadPool give the same bytes, also with random edits. |

## Executors

| Executor | Where | Used by |
|----------|-------|---------|
| ThreadPool | `min(CPU count - 1, 4)` native threads, at least 1 | native, by default |
| Inline | one worker on the main thread | the web build, `--chunk-workers=0`, the fallback when no thread starts |
| WorkerPool | Web Workers with `chunks.wasm` | a later step |

Both executors use the same worker code (`WorkerWorld.handle`) and the
same protocol bytes. So a native test also tests the web format (P6). The
test `exec: Inline and ThreadPool give the same bytes, with random edits
while jobs run` compares the two byte for byte. Run it again to look for
races: `zig build test-exec`.

The ThreadPool starts before the loading screen, and the loading screen
uses it (D6, D7). At exit, main stops each thread and waits for it. A job
in flight is lost, and main frees its result. `ThreadPool.abandonAll` gives
the jobs in flight back to the scheduler, for a new world.

## Workers own the world (C4)

A worker has a copy of the world: the generation config with the seed,
and the edit log (P2). It makes each chunk from them. It keeps the chunks
that it made, and their light, in an LRU cache with a limit of 64 MB
(C14). The cache removes the oldest chunk when it is past the limit, at
the end of each message. A job can go past the limit while it runs, by
the 5 × 5 chunks that it reads. The light stage scratch (about 4 MB) is
not in the limit. A chunk that the cache removed comes back from the seed
and the edit log, with the same bytes.

Main keeps:

- the state of each chunk: its block version, its light version and
  light hash, and the input versions of its light and mesh (C3),
- the blocks of the chunks in the prefetch radius: the square of 2 chunks
  around the player chunk (C6). Main drops them past 3 chunks,
- the meshes, for the upload to the GPU,
- the edit log.

Main keeps no light. A light result holds a hash of the light. When the
hash does not change, the light version does not change, so the meshes
that read the light stay current (C3).

An edit goes to the edit log of main and to each worker, in order. A
worker handles its messages in order, so it applies the edit before each
job that started after the edit. Thus the block versions of a job are
the block versions of the worker. A job with other versions gets an
Error (`stale_input`).

The simulation reads only the blocks of the simulation radius (C6). A
generate job in the prefetch radius asks for the blocks (`want_blocks`),
so the blocks are on main before the player gets there. When a chunk of
the simulation radius has no blocks, a tick generates it inline and
applies the edit log (`Scheduler.ensureSimRadius`). Generation is pure,
so the result is the result of a worker (P4).

## Spatial affinity (C4)

Each region of 8 × 8 chunks goes to one worker (`exec_threads.ownerOf`).
The regions next to a region go to other workers. A light job reads the
blocks of 3 × 3 chunks, and a mesh job reads 5 × 5. So a job near the edge
of a region makes some chunks of the next region again. When the worker
of a region is full and another worker has no job, that worker takes the
job, so that no thread waits while work waits.

Each worker holds at most 2 jobs: one runs and one waits (C8). A job
whose worker is full waits for the next plan.

| Region width | Chunks generated (full load, R = 12) | Full load |
|--------------|--------------------------------------|-----------|
| 4 | 1743 (2.7 × 657) | 0.98 s |
| 8 | 1209 (1.8 × 657) | 0.79 s |
| 16 | 877 (1.3 × 657), one worker gets most of the work | 0.79 s |
| 8, with a free worker that takes a job | 1346 | 0.74 s |

The numbers in this table are from runs before the worker threads used
their own allocator. See the measurements below for the current numbers.

## Protocol (P6)

The protocol has no pointers. Each field has a fixed offset, each integer
is little-endian, and an f32 is its IEEE 754 bits. `VERSION` changes with
each change of the layout. The Hello handshake checks the protocol
version and the build hash (C9).

Header, 16 bytes:

| Offset | Type | Field |
|--------|------|-------|
| 0 | u32 | magic `VXCP` |
| 4 | u16 | protocol version |
| 6 | u8 | kind: 1 Hello, 2 Edit, 3 Job, 4 Result, 5 Error |
| 7 | u8 | 0 |
| 8 | u32 | body length |
| 12 | u32 | job id (Job, Result, Error), else 0 |

Bodies (offset, type, field). `protocol.zig` has the same layout in its
doc comments.

```
Hello, 56 bytes
  0  u64   build hash
  8  u64   seed
  16 u64   cache limit in bytes
  24 u8    preset, then 3 bytes of 0
  28 i32   sea level
  32 i32   terrain height min
  36 i32   terrain height max
  40 f32   noise scale
  44 u32   noise octaves
  48 f32   noise persistence
  52 f32   noise lacunarity

Edit, 16 bytes
  0  i32   cx
  4  i32   cz
  8  u32   block version after the edit
  12 u8    x, 13 u8 y, 14 u8 z (local cell)
  15 u8    block type

Job, 88 bytes
  0  u8    stage (0 generate, 1 light, 2 mesh)
  1  u8    AO strategy
  2  u8    lighting mode
  3  u8    flags: bit 0 = send the blocks back
  4  i32   cx
  8  i32   cz
  12 u32   0
  16 u32×9 block versions of the 3×3 chunks
  52 u32×9 light versions of the 3×3 chunks

Result, 32 bytes, then the payload
  0  u8    stage
  1  u8    flags: bit 0 = the payload holds blocks
  2  u16   0
  4  i32   cx
  8  i32   cz
  12 u32   block version of the chunk
  16 u64   light hash (light), or y min f32 and y max f32 (mesh)
  24 u32   quad count (mesh), or payload length (generate)
  28 u32   job time in µs
  32 ...   payload

Error, 16 bytes, then the text
  0  u16   code
  2  u8    stage
  3  u8    0
  4  i32   cx
  8  i32   cz
  12 u32   text length (at most 256)
  16 ...   text
```


The Result payload starts at byte 48, so the PackedQuad bytes of a mesh are
16-byte aligned, ready for upload (C5). A generate payload holds the
blocks: palette length u16, bits u8, 0 u8, word count u32, the palette
(padded to 8 bytes), then the packed u64 words.

The decoder checks each field, and never reads past the message. A
message that decodes encodes to the same bytes. The fuzz tests check both.

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

The ThreadPool executor installs results until no result waits or the
frame budget is spent. Then it plans and sends jobs. It never waits for a
worker. The Inline executor runs jobs until no job can start or the frame
budget is spent. Each checks the clock before each job, so a frame can go
past the budget by one job. A frame with a job that can start always runs
one job.

| Phase | Budget |
|-------|--------|
| Loading screen | 12 ms (`LOADING_BUDGET_NS`) |
| Gameplay | 4 ms (`PLAY_BUDGET_NS`) |

The clock is `clock.frameNowNs`: the monotonic clock on native and
`performance.now()` on the web.

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

With the ThreadPool, the page also shows each worker: its jobs in flight,
its cache (chunks and MB) and its cache hit rate. It shows the mean bytes
of a job message and of a result message.

The native log has one `[PIPE]` line for each frame with jobs. `main_us`
is the time of the frame phase on the main thread. At shutdown, the log
has the installs, the message bytes for each stage, and the cache
counters of each worker.

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

## Measurements of the ThreadPool (2026-10-16, x86_64 Linux container, 4 CPUs)

Native ReleaseFast, headless, hilly, R = 12, 3 worker threads. "Ready" is
the time from start to "World ready". "Full load" is the time to the last
chunk job of the full render distance (657 generate, 545 light and 441
mesh results). "Main" is the frame phase on the main thread. Median of 5
runs.

| | Inline (before) | ThreadPool |
|-|-----------------|------------|
| Ready | 0.53 s | 0.40 s |
| Full load | 1.08 s | 0.71 s |
| Main, loading frame, p50 | 12.3 ms | 0.14 ms |
| Main, gameplay frame, p50 | 4.25 ms | 0.30 ms |
| Main, gameplay frame, p95 | 4.76 ms | 0.38 ms |
| Main, gameplay frame, p99 | 4.95 ms | 0.44 ms |

With `--chunk-workers=0` (the Inline executor through the protocol
bytes), "ready" is 0.54 s and the full load is 1.11 s, about 2% slower
than before. The cost is the copies of the messages and the light hash.

The 3 workers generate about 1310 chunks for the 657 chunks of the World.
A worker makes again the chunks next to its regions, because a mesh job
reads 5 × 5 chunks of blocks. So the full load is 1.5 times faster, not 3
times.


Bytes for each message, full load:

| Message | Bytes |
|---------|-------|
| Job | 104 |
| Edit | 32 for each worker |
| Result, light | 48 |
| Result, generate | 48, or about 25 KB with the blocks (25 chunks of the prefetch radius) |
| Result, mesh | 8383 on average (48 + 16 for each quad) |

The old async path copied about 50,880 bytes for each job (508,800 bytes
for 10 jobs) into the worker. A job message is now 104 bytes.

