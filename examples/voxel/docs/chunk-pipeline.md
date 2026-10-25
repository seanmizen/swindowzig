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
| `pipeline/mesh_bytes.zig` | The quad bytes of a mesh result, from the worker to the GPU upload, with no copy (C5). |
| `pipeline/worker_world.zig` | The world of a worker: the seed, the edit log and an LRU chunk cache (C4, C14). |
| `pipeline/exec_inline.zig` | The Inline executor: one worker on the main thread, within a frame budget (C7). |
| `pipeline/exec_threads.zig` | The ThreadPool executor: native worker threads (C9). |
| `pipeline/exec_web.zig` | The WorkerPool executor: the main side of the Web Worker pool (C9). |
| `pipeline/chunk_worker_main.zig` | The exports of `chunks.wasm`, the chunk worker of the web build. The build root is `chunks_wasm.zig`. |
| `backends/wasm/worker-pool.ts` | The JS worker pool: start, handshake, restart, the result queue (C9). |
| `backends/wasm/held-bytes.ts` | The results that JS holds for `app.wasm`, by handle, and the byte counters (C5). |
| `backends/wasm/chunk-worker.ts` | The script of each Web Worker: it runs `chunks.wasm` (C9, C12). |
| `backends/wasm/worker-pool.test.ts` | The Bun tests of the pool with real Web Workers (C11). |
| `scheduler_test.zig` | Priority order, stale results, eviction with hysteresis, runtime render distance. |
| `stages_test.zig` | The stages give the light and the quads of the reference path in `world.zig`. |
| `protocol_test.zig` | Round trip, layout and fuzz tests of the protocol. |
| `exec_test.zig` | The cache limit, and Inline, ThreadPool and WorkerPool give the same bytes, also with random edits. |

## Executors

| Executor | Where | Used by |
|----------|-------|---------|
| ThreadPool | `min(CPU count - 1, 4)` native threads, at least 1 | native, by default |
| WorkerPool | `min(navigator.hardwareConcurrency - 1, 4)` Web Workers with `chunks.wasm`, at least 1 | the web build |
| Inline | one worker on the main thread | `--chunk-workers=0`, headless tools, the fallback when no thread or worker starts |

The executors use the same worker code (`WorkerWorld.handle`) and the
same protocol bytes. So a native test also tests the web format (P6). The
test `exec: Inline and ThreadPool give the same bytes, with random edits
while jobs run` compares the two byte for byte. The `exec: web:` tests do
the same for the WorkerPool executor, with a transport of in-process
workers. Run them again to look for races: `zig build test-exec`.

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
- the quad count, the y range and the hash of each mesh. The quad bytes
  stay on main only until the GPU upload (C5),
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

Result, 48 bytes, then the payload
  0  u8    stage
  1  u8    flags: bit 0 = the payload holds blocks
  2  u16   0
  4  i32   cx
  8  i32   cz
  12 u32   block version of the chunk
  16 u64   light hash (light), or y min f32 and y max f32 (mesh)
  24 u32   quad count (mesh), or payload length (generate)
  28 u32   job time in µs
  32 u64   mesh hash (mesh), else 0
  40 u64   0
  48 ...   payload

Error, 16 bytes, then the text
  0  u16   code
  2  u8    stage
  3  u8    0
  4  i32   cx
  8  i32   cz
  12 u32   text length (at most 256)
  16 ...   text
```


The Result payload starts at byte 64 of the message, so the PackedQuad
bytes of a mesh are 16-byte aligned, ready for upload (C5). The mesh hash
is `protocol.meshHash` of the payload. The worker calculates it, so main
can compare meshes without the quads. Main reads only the first 64 bytes of
a mesh Result (`protocol.decodeResultHead`). A generate payload holds the
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
4. **Uploaded.** Main writes the quad bytes of the result to the GPU, then
   frees them (`LoadedChunk.upload`, C5).

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
| Result, light | 64 |
| Result, generate | 64, or about 25 KB with the blocks (25 chunks of the prefetch radius) |
| Result, mesh | about 8400 on average (64 + 16 for each quad) |

The measurement was with protocol version 1, when the fixed part of a
Result was 16 bytes shorter. Version 2 added the mesh hash (C5).

The old async path copied about 50,880 bytes for each job (508,800 bytes
for 10 jobs) into the worker. A job message is now 104 bytes.

## The Web Worker pool (C9)

The web build runs the chunk stages in Web Workers. Main runs only the
scheduler, the installs and the simulation-radius fallback (C6).

```
loader.ts            worker-pool.ts             chunk-worker.ts (N times)
---------            --------------             -------------------------
start pool --------> compileStreaming
                     (chunks.wasm, one time)
                     new Worker x N ----------> init: instance of the Module
load app.wasm                                   'ready': version, build hash,
instantiate app.wasm                            build id
attachPool --------> verify: same values as
                     app.wasm, else stop
swindowzig_init
  exec_web: Hello -> broadcast --------------> chunk_worker_handle
frame phase:
  Edit -------------> broadcast (kept) -------> applies the edit
  Job --------------> post to one worker -----> runs the stage
  take the heads <--- JS queue <--------------- 'reply' (ArrayBuffer, moved)
  (JS holds each result)
render:
  upload a mesh ----> queue.writeBuffer from the held ArrayBuffer (C5)
```

### Start-up (D6, D7)

The loader starts the pool first, before the download of `app.wasm` and
before the loading screen. The pool compiles `chunks.wasm` one time with
`WebAssembly.compileStreaming`, and sends the `Module` to each worker. The
pool lasts for the whole session. `chunks.wasm` is about 157 KB
(ReleaseFast, no debug info). Its only wasm imports are `env.jsGetTime`
and `env.jsLog`. It has no GPU code.

### Handshake and cache safety (C9)

`app.wasm` and `chunks.wasm` both export three values:

| Value | Source |
|-------|--------|
| Protocol version | `protocol.VERSION` |
| Build hash | `protocol.BUILD_HASH`: the protocol version and the stage sizes |
| Build id | `build.zig`: a hash of the path and the bytes of each `.zig` file under `examples/voxel` |

After the instantiation of `app.wasm`, `attachPool` compares the values of
each worker with the values of `app.wasm`. A worker with other values
stops, and the console shows the two values and "A cached old file?".
When no worker runs, the main thread runs the chunk jobs (the Inline
executor). So a cached old file cannot make wrong terrain. The worker also
checks the build hash of the Hello (`version_mismatch`), and the pool then
stops that worker for good.

Production files have content-hashed names (`bundle.sh`):

| File | Name |
|------|------|
| `chunks.wasm` | `chunks-<16 hex digits of SHA-256>.wasm` |
| The worker bundle | `chunk-worker-<16 hex digits>.js` |
| `boot.js` | the same name. It holds the two names above (`bun build --define`). |

`serve.json` gives the hashed files `Cache-Control: public,
max-age=31536000, immutable`, and each other file `no-cache`. An old
`boot.js` from a cache asks for an old name. `serve -s` then sends
`index.html`, `compileStreaming` fails on the MIME type, and the Inline
executor runs the jobs. The dev server sends each file with `no-cache`,
so the dev page uses the plain names (`/chunks.wasm`, `/chunk-worker.js`).

### Jobs, edits and results

`exec_web.zig` has the design of the ThreadPool executor:

- An edit goes to each worker (broadcast), in order. The pool keeps the
  Hello and all the edits, for a worker that starts again.
- A job goes to the worker of its 8 × 8 region (`exec_threads.ownerOf`).
  When that worker is full, a worker with no job takes it.
- A worker sends each reply as a transferable `ArrayBuffer`. The pool
  keeps the replies in a JS queue. Main takes them only in the frame
  phase, within the install budget (C7). A tick never installs.
- Main copies only the first 64 bytes of each reply into its wasm
  memory. JS holds the whole reply. A mesh goes to the GPU from the
  ArrayBuffer of the worker. See "Mesh bytes (C5)" below.

Main sends new jobs to a Web Worker only once in each frame. With 2 jobs of
about 1.3 ms in each worker, a worker waits for most of a 16.7 ms frame.
So each worker holds the jobs of one frame interval, and one more:
`exec_web.depthFor(frame, mean job time)` = ceil(frame / job) + 1, from 2
to 16. A job in a worker queue waits for at most about one frame, so a
change of priority shows in one or two frames (C8). With the fixed limit of
2, the loading screen took 2.7 s in the measurement below. With
`depthFor`, it took 1.2 s.

### A worker that stops

When a worker sends an `error` or a `messageerror` event (Bun also sends
`close`), the pool stops it and starts a new worker in the same slot. It
sends the new worker the `Module`, the Hello, all the edits, and then the jobs
in flight of the old worker, in their order. The results come back with
the same job ids, so `exec_web.zig` does not see the restart. A job that
an edit made stale gets an Error (`stale_input`), and the scheduler queues
it again (C3).

After 3 restarts (`MAX_RESTARTS`), the slot stops for good, and the pool
sends its jobs to another worker. When no worker runs, `Web.runFrame` gives
each job in flight back to the scheduler and returns `error.NoWorkers`.
`main.zig` then starts the Inline executor with the edit log of the World
(`Inline.initFromWorld`), and the frame budget limits the jobs.

### Observability (C12)

- Each worker job shows in the DevTools Performance panel as a measure
  named `chunk <stage> <cx>,<cz>`. The loader adds the measure
  `chunk worker pool start`.
- The pipeline page of the debug overlay shows "N WEB WORKERS", the jobs
  in flight of each worker, and a line when the pool stopped.
- `voxel_debug_pipeline_counts` (an `app.wasm` export) gives the counters
  that the Bun tests read: the executor, the main-thread jobs, the
  simulation-radius chunks, the worker jobs and the fallbacks.

### Tests (C11)

`bun test backends/wasm/worker-pool.test.ts` (CI) runs `app.wasm` headless
with real Bun Web Workers. It compares `voxel_debug_world_hash` (the block
versions, the light hashes, the meshes and the blocks of the desired
state) with a run of the Inline executor:

| Test | Check |
|------|-------|
| equivalence | 1, 3 and 4 workers, 40 random edits while jobs run: the same hash. 0 jobs on the main thread. |
| restart | 3 workers stop during the load: they start again, and the hash does not change. |
| fallback | the Worker constructor throws, or all workers stop: the Inline executor runs the jobs, with the same hash. |
| mismatch | another build id, build hash or protocol version: no worker starts, the console names the value, and the hash does not change. |
| Hello | a worker refuses a Hello of another build, and the slot stops. |
| serve | the pool compiles `chunks.wasm` over HTTP. An old file name (HTML from `serve -s`) gives a clear error. |
| uploads | each run above checks the mesh uploads (`checkMeshUploads`, C5). |
| memory | the main wasm memory does not grow with the meshed chunks (C5). |

`bun backends/wasm/headless.ts` (CI) uses the pool too, and fails when a
chunk job runs on the main thread. `--workers 0` runs it with the Inline
executor. `--chunks-wasm` and `--worker` run it with the production files
of `bundle.sh`.

## Measurements of the WorkerPool (2026-10-16, x86_64 Linux container, 4 CPUs)

`bun backends/wasm/headless.ts --measure`: wasm ReleaseFast in Bun 1.4,
the real clock, 60 frames per second as in a browser, stub WebGPU. 3 Web
Workers. "Main" is the time of `swindowzig_frame` on the main thread: the
ticks, the frame phase and the render with stub GPU calls. "Loading
screen" is the time from the start to "World ready". "Walk" is the flight
of 5 chunks after the loading screen.

| | Inline, main before this change | Inline | WorkerPool |
|-|---------------------------------|--------|------------|
| Loading screen | 1535 ms | 1553 ms | 1239 ms |
| Main, loading frame, p50 | 13.16 ms | 13.13 ms | 1.01 ms |
| Main, loading frame, p95 | 14.12 ms | 14.39 ms | 7.37 ms |
| Main, first 3 s after loading, p50 | 5.11 ms | 5.16 ms | 0.57 ms |
| Main, first 3 s after loading, p99 | 6.62 ms | 7.62 ms | 6.60 ms |
| Main, walk frame, p50 | 0.54 ms | 0.53 ms | 0.36 ms |
| Main, walk frame, p95 | 6.09 ms | 6.18 ms | 1.48 ms |
| Main, walk frame, p99 | 7.19 ms | 7.18 ms | 2.24 ms |
| Main, walk frame, max | 8.44 ms | 8.30 ms | 4.12 ms |

Each value is the median of 3 runs. A loading frame of the WorkerPool
installs the results of 3 workers, within the loading budget of 12 ms.
The frame that ends the loading screen takes 13 to 16 ms in 2 of 3 runs.
It installs only about 6 results: the time is the start of the game.

The main-thread time of the WorkerPool is the installs (the copy of the
quads into the main wasm memory) and the plan. The next section removes
the copy.

## Mesh bytes (C5)

Main does not copy the quads of a mesh, and keeps no CPU copy after the
GPU upload. The main wasm knows only the counts of a mesh
(`world.MeshInfo`): the quad count, the y range and the mesh hash. The
chunk record has the chunk coordinates and the versions.

The quad bytes of a new mesh go from the worker to the GPU like this
(`pipeline/mesh_bytes.zig`):

| Executor | Bytes until the upload | Upload |
|----------|------------------------|--------|
| WorkerPool | the transferred ArrayBuffer, which JS holds (`held`) | JS calls `queue.writeBuffer` with the ArrayBuffer (`gpu.writeBufferHeld`) |
| ThreadPool, Inline | the reply of the worker, in main memory (`local`) | one `writeBuffer` from the reply |

1. A worker sends the Result as a transferable ArrayBuffer.
2. In the frame phase, `exec_web.zig` takes the next result
   (`jsChunkTakeHead`). JS holds the ArrayBuffer under a handle
   (`held-bytes.ts`), and copies its first 64 bytes into the wasm memory.
3. For a mesh, the scheduler gets the counts and the handle. Any other
   result comes into the wasm memory as a whole (`jsChunkRead`): a
   generate result has the blocks of the prefetch radius (C6).
4. The render (`uploadNewMeshes` in `main.zig`) writes the 16-byte GPU
   header of the chunk from the wasm memory, then asks JS to write the
   quads from the ArrayBuffer (`webgpuWriteBufferHeld`). Then it releases
   the handle.

A mesh that a new mesh replaces before the upload, or that the scheduler
evicts, releases its bytes too. The uploads run also during the loading
screen, so the frame that ends the loading screen does not upload all the
meshes. A pure headless run (no GPU) frees the bytes in the frame phase.

### GPU buffers

The old upload made a new buffer and a new bind group for each mesh, also
for a remesh of the same chunk. Now a chunk keeps its buffer when its new
mesh fits. A buffer of an evicted chunk goes to a pool
(`QuadBufferPool` in `main.zig`). The pool has size classes of 2^k,
1.25 × 2^k, 1.5 × 2^k and 1.75 × 2^k elements of 16 bytes, from 4 KB. A
buffer has at most 1.25 times the bytes that its mesh needs, or 4 KB.

| Run | Uploads | Buffers made, old | Buffers made, pool | Taken from the pool |
|-----|---------|-------------------|--------------------|---------------------|
| `headless.ts`, a walk of 5 chunks | 540 | 540 | 530 | 10 |
| Bun memory test: R = 4, R = 12, a walk of 24 chunks | 1041 | 1041 | 641 | 400 |

Bun has no real `createBuffer`, so the time of one buffer is not known.
The on-machine session measures it in a browser. With R = 12, the quad
buffers hold 4.6 MB for 3.7 MB of quads (framespike.tas, native).

### --depth-stencil=off

The back-to-front sort of each frame needs the quads on the CPU. With the
depth test off, the upload keeps a CPU copy of the quads
(`ChunkGPU.sort_mesh`). On the web, that copy comes from JS with
`jsChunkRead`. This is the only CPU copy of a mesh on main. The flag has
no web option.

### Proof (C11)

- `exec_test.zig`: the WorkerPool executor with in-process workers reads
  no mesh payload byte (`FakePool.mesh_payload_reads`), and no handle stays
  held after the uploads. The Inline, ThreadPool and WorkerPool executors
  give the same quad bytes.
- `checkMeshUploads` (`headless-app.ts`), in `headless.ts` (CI) and in each
  run of `worker-pool.test.ts`: JS copied no mesh quad into the wasm memory,
  and at most 64 bytes for each result. Each mesh went to the GPU from the
  held bytes, with the size of its quads, at byte 16 of its buffer, after
  the GPU header of its chunk. The stub WebGPU checks the rules of
  `writeBuffer`. No chunk keeps a CPU copy, and JS holds no result at the
  end.
- The memory test of `worker-pool.test.ts`: the main wasm memory grows by
  at most 1 MB from R = 4 (49 meshes) to R = 12 (441 meshes), and by at
  most 1 MB over a walk of 24 chunks. A copy of each mesh (about 8 KB)
  adds about 3 MB from R = 4 to R = 12.
- The native log at exit has `[GPU MESH] uploads ... waiting=0
  cpu_copies=0`.

## Measurements of C5 (2026-10-17, x86_64 Linux container, 4 CPUs)

`bun backends/wasm/headless.ts --measure`, 3 Web Workers, as above. The
stub WebGPU of both builds does not record the writes. "Rise" is the
first 3 s after the loading screen, while the rest of R = 12 loads. Each
value is the median of 9 runs, one run of each build in turn.

| Main time of a frame | Before | After |
|----------------------|--------|-------|
| Loading screen | 935 ms | 971 ms |
| Loading frame, p50 | 0.81 ms | 0.77 ms |
| Loading frame, p95 | 2.96 ms | 2.77 ms |
| Loading frame, max | 6.08 ms | 4.89 ms |
| Rise, p95 | 1.86 ms | 1.10 ms |
| Rise, p99 | 4.16 ms | 1.47 ms |
| Rise, max | 9.08 ms | 2.03 ms |
| Walk, p50 | 0.19 ms | 0.18 ms |
| Walk, p95 | 0.92 ms | 0.89 ms |
| Walk, p99 | 1.41 ms | 1.22 ms |
| Walk, max | 2.27 ms | 1.80 ms |

The time of the loading screen changes by about 10% from run to run, in
both builds.

The main wasm memory, in one script for both builds (3 workers, load
R = 12, then a walk of 30 chunks):

| Main wasm memory | Before | After |
|------------------|--------|-------|
| At the start | 16.4 MB | 16.4 MB |
| R = 12 loaded (441 meshes) | 24.0 MB | 18.7 MB |
| After the walk | 24.9 MB | 18.9 MB |
