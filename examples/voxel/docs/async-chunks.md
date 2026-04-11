# Async Chunk Generation & Meshing — Research + Phase-1 Implementation Plan

> Research doc + phase-1 implementation notes. Explains *why* the voxel demo
> moves chunk gen+mesh off the render thread, the constraint that shapes every
> decision (Zig + WebGPU + "must translate to Web Workers later"), and how the
> native-side prototype lands today.

## TL;DR

- Leaving the pregen 5×5 ring spikes the main thread by **32–44 ms per new
  chunk** (measured: see "Baseline numbers" below). At 120 Hz that's 4–5
  missed ticks per chunk. The existing `MESH_GENS_PER_TICK = 1` cap is a
  throttle, not a fix — it just spreads the stall over consecutive frames.
- All of the expensive work — terrain gen, skylight flood-fill, AO sampling,
  `VoxelVertex` construction — is **pure math on plain bytes**. No GPU
  handles, no shared mutable state. It moves to a background thread cleanly.
- The GPU upload (`wgpuQueueWriteBuffer`) is cheap (tens of µs) and MUST
  stay on the render thread: wgpu-native does not guarantee device/queue
  thread-safety, and in-browser only the main thread owns the WebGPU device.
- **Phase 1 implementation** (this branch): one `std.Thread` worker, two
  mutex-guarded FIFOs (`job_queue`, `result_queue`), one job type that does
  **gen + mesh in a single worker call**. Main thread drains ≤N results per
  tick, sorts by `(cx, cz)` before applying, uploads to GPU. Flag
  `--async-chunks=on|off` (default on); off restores the synchronous
  time-budgeted loop as an escape hatch.
- **Web Worker port** is left as a documented follow-up. The worker entry
  point takes a `*WorkerContext` and nothing else — no globals, no
  `@import("sw_gpu")`. Porting is a recompile + a handful of JS glue.
- **Determinism is preserved** by (a) enqueueing chunks in the existing
  spiral/pregen order, (b) draining results per tick and **sorting by
  `(cx, cz)` before applying**, (c) leaving the single-threaded pregen path
  unchanged when `--async-chunks=off`. Success criterion: all three
  regression TAS scripts produce byte-identical PPM dumps across the flag.

## The problem we're solving

### The render-thread spike

Walking off the pregen ring triggers the `voxelTick` gen+mesh loop:

```
utils/swindowzig/examples/voxel/main.zig (voxelTick, post-loading):
  world.update(anchors)                 // K=2 gen/tick during gameplay
  mesh_gens = 0
  for each chunk in state.world.chunks:
    if mesh_dirty && hasAllNeighborsGenerated:
      generateMesh(...)                 // 32–44 ms each
      mesh_gens += 1
      if mesh_gens >= MESH_GENS_PER_TICK: break
```

At `MESH_GENS_PER_TICK = 1`, each new chunk eats 32–44 ms of the 8.3 ms
tick budget — a 4–5× overrun. Framespike-style. The band-aid spreads the
damage across consecutive frames but never hides it.

### Baseline numbers (sync path, main-thread meshing)

Captured this session, same machine that runs the regression tests.
`[MESH] chunk (cx,cz) gen=Nus` lines from the three standard TAS scripts:

| Scene (TAS)                | Mesh gen per chunk (µs) | Quads per chunk |
|---------------------------|-------------------------|-----------------|
| ao_corners (flatland)     | 31 000 – 42 000         | 4608            |
| cave_skylight (flatland)  | 32 000 – 34 000         | 4608            |
| framespike (hilly)        | 32 000 – 44 000         | 5226 – 5673     |

No noise-height dependence — flatland and hilly mesh at the same cost
within jitter. The ~10× over the "2.3 ms/chunk" estimate in
`main.zig:124` is the AO+skylight bake multiplying per-vertex work. The
old number predates `--ao=classic` and `--lighting=skylight`.

Generation itself (`generateTerrain` + `computeSkylight`) is ~1 ms/chunk
on the same machine. **Mesh is 30×+ more expensive than gen.** Moving
only gen off-thread would not move the spike.

## Native threading in Zig

Zig ships a full cross-platform `std.Thread` in the standard library.
Minimal API:

```zig
const std = @import("std");

// Spawn a thread that runs workerMain(arg). Returns a handle.
const handle = try std.Thread.spawn(.{}, workerMain, .{&ctx});

// Block until the thread exits.
handle.join();

// Synchronisation primitives
var mtx: std.Thread.Mutex = .{};
var cond: std.Thread.Condition = .{};

mtx.lock();
defer mtx.unlock();
while (queue.items.len == 0 and !ctx.shutdown) cond.wait(&mtx);
```

`std.Thread.Mutex` is a futex on Linux, `pthread_mutex_t` wrapper on
macOS. `std.Thread.Condition` is a `pthread_cond_t` wrapper. Both are
POSIX-level — overhead is tens of nanoseconds for uncontended lock
cycles, well below the cost of anything we do on either side of them.

**Allocators and thread safety.** The main concern is that `std.ArrayList`
operations need an allocator, and not every Zig allocator is thread-safe.
Rules of thumb:

- `std.heap.c_allocator` → thread-safe (delegates to `malloc`/`free`).
- `std.heap.page_allocator` → thread-safe (delegates to `mmap`/`munmap`).
- `std.heap.GeneralPurposeAllocator(.{})` → thread-safe by default
  (`thread_safe = true`).
- Arena allocators → **NOT** thread-safe. Don't share an arena between
  threads without external locking.

The voxel demo uses whatever `ctx.allocator()` returns — today that's the
app's root GPA, which is thread-safe. For the worker's ephemeral buffers
(the CPU vertex/index slices destined for GPU upload) we use
`std.heap.c_allocator` directly so the choice is independent of the
context allocator and can't regress if the context allocator changes.

## Web-worker analog (for the future port)

In the WebGPU-in-browser backend (`backends/wasm/`, `libs/sw_gpu/src/web_bridge.zig`):

- The main JS thread owns the `GPUDevice`, the render loop, and DOM
  input. JS calls into the Zig/WASM `run()` each RAF tick.
- Background work goes in a **Web Worker** — a separate JS thread with
  its own JS heap, no shared globals with main. Communication is either:
  - `postMessage(obj)` — structured-cloned deep copy. Fast for small
    payloads (input events), slow for 1 MB chunks (tens of ms).
  - `postMessage(ab, [ab])` where `ab` is an `ArrayBuffer` and the second
    argument transfers ownership — zero-copy, but the sender loses the
    buffer.
  - `SharedArrayBuffer` — a genuinely shared region of memory, both
    threads read/write concurrently. Zero-copy. **Requires COOP/COEP
    headers** (`Cross-Origin-Opener-Policy: same-origin`,
    `Cross-Origin-Embedder-Policy: require-corp`). Our dev server doesn't
    set these today; the Fly.io gateway doesn't either. That's
    fixable in one commit on the server side when we need it.
- WASM threads are a thing (`wasm-threads` proposal, stable in Firefox/
  Chrome) but Zig's `std.Thread.spawn` in the WASI/freestanding target is
  a stub — it returns `error.ThreadingUnavailable`. So "native Zig thread
  in the browser" is **not** on the table. The worker body must be a
  separate compilation that runs as a Web Worker on its own WASM
  instance.

### What this means for the worker entry point

The worker function takes a `*WorkerContext` (see `async_chunks.zig`),
which is a plain struct of:

- The two queues (job + result).
- The world generation config (a POD `WorldGenConfig`).
- A shutdown flag (`std.atomic.Value(bool)`).
- The allocator used for result buffers.

No globals. No `@import("sw_gpu")`. No main-thread references. This is
the property that keeps the Web Worker port cheap: on WASM the
`WorkerContext` fields become `SharedArrayBuffer` views, the mutex
becomes `Atomics.wait/notify`, and the worker JS file calls
`zig_worker_main(ctx_ptr)`. The Zig source code is unchanged.

## The data-structures-matter decision

### Chunks must remain plain-old-data

`Chunk` today is exactly:

```zig
pub const Chunk = struct {
    blocks:   [CHUNK_W][CHUNK_H][CHUNK_W]BlockType,  // ~589 KB
    skylight: [CHUNK_W][CHUNK_H][CHUNK_W]u8,         // ~589 KB
};
```

~1.15 MB of POD. No allocations, no pointers, no hashmaps. This is
*exactly* the shape `SharedArrayBuffer` wants: the worker could treat
the chunk as a flat byte view and write directly into it with no
serialization.

**Rule going forward:** `Chunk` must stay POD. Any feature that wants to
hang something off a chunk (a per-chunk lightmap cache, a palette
compressor, a biome struct) either embeds it as a fixed-size field or
lives in a parallel structure owned by the main thread. A compile-time
assertion helps:

```zig
comptime {
    if (@typeInfo(Chunk).Struct.layout == .auto) {
        @compileError("Chunk must be POD — keep layout explicit and pointer-free");
    }
}
```

*(Not landed in phase 1 — it would force `extern struct` which changes
the field layout semantics slightly. Noted as a follow-up.)*

Incremental mesh state (`quad_block`, `quad_highlight`, `sort_scratch`,
`sort_indices`) lives on `Mesh`, not `Chunk`, so it does not violate
this rule — `Mesh` stays on the main thread and is never transferred
across the worker boundary.

### Why we don't transfer the whole Mesh

The worker could build a whole `Mesh` struct and hand it to main. We
don't, because:

- `Mesh` contains `std.ArrayList` fields backed by an allocator. Moving
  a Mesh across threads means either sharing an allocator (footgun) or
  deep-copying on the main side (cost).
- The main thread already has a `Mesh` living inside each `LoadedChunk`.
  Overwriting it with a worker-built one means `deinit`ing the old one
  and copying pointer guts — workable but fiddly.
- The worker produces **raw CPU buffers** (`[]VoxelVertex`, `[]u32`,
  `[]u32`, `[]u8`) allocated from `std.heap.c_allocator`. Main thread
  takes the four slices, clears the existing `Mesh`, `appendSlice`s them
  into the Mesh (one `memcpy` each), then `c_allocator.free`s the
  worker's slices. Total copy cost per chunk: ~300 KB of vertices + ~60
  KB of indices + ~30 KB of bookkeeping ≈ **<100 µs on the render
  thread**, compared to the 32–44 ms we save from not meshing there.

## The boundary — what can and cannot move to the worker

### Can (confirmed pure-CPU, no GPU handles, no shared mutation)

- `Chunk.generateTerrain(cx, cz, config)` — noise sweep, deterministic
  from `(cx, cz, config)` alone.
- `Chunk.computeSkylight()` — two-pass BFS on `chunk.blocks` and
  `chunk.skylight` only. Read+write on the worker's own Chunk.
- `mesher.generateMesh(...)` — scans `chunk.blocks`, calls
  `BlockGetter.getBlock` / `getSkylight` for neighbour cross-faces,
  produces vertices+indices. The BlockGetter is a function-pointer
  vtable and its backing `ctx` can be anything — on the main thread it
  points at `*const World`, on the worker it points at a **snapshot
  struct** that holds the 5 chunk pointers (self + 4 neighbours).

### Cannot (must stay main-thread)

- Any `sw_gpu` API call — `createBuffer`, `queueWriteBuffer`,
  `createRenderPipeline`, etc. On native, wgpu-native's thread safety is
  not guaranteed for device/queue objects. In-browser, only the main JS
  thread owns the WebGPU device.
- `Mesh.sortByDepth` — reads the current camera position and mutates
  `Mesh.indices` to the painter's-algorithm order. This is
  render-adjacent and runs every frame; easier to keep on main.
- `updateForBlockChange` (incremental dig path) — affects only 7 blocks,
  runs in hundreds of µs, is triggered by user input, and requires
  immediate feedback. Staying synchronous on main is fine.

### The grey zone

- Marking neighbour chunks `mesh_dirty` when a new chunk lands. Has to
  happen on the main thread because the chunk map is main-owned, but
  the main thread is the one draining results, so it's naturally in the
  right place.
- The `quad_block` / `quad_highlight` bookkeeping for incremental mesh
  updates. When a worker produces a full mesh, the main thread clears
  the existing Mesh (which wipes these) and repopulates. The bookkeeping
  survives — it's just regenerated from the worker's output. No worker
  access needed.

## The architecture sketch

```
                ┌───────── main thread ─────────┐       ┌──── worker thread ────┐
                │                                │       │                        │
  player walks  │ enqueue(cx,cz)                 │       │  loop:                 │
   off pregen → │    ↓                           │       │    lock(job_mtx)       │
                │  job_queue ───────────────────────────▶│    wait for !empty     │
                │   (gen+mesh)                   │       │    pop(job)            │
                │                                │       │    unlock              │
                │                                │       │                        │
                │                                │       │    run job:            │
                │                                │       │      gen terrain       │
                │                                │       │      compute skylight  │
                │                                │       │      mesh (with        │
                │                                │       │       snapshot of self │
                │                                │       │       + 4 neighbours)  │
                │                                │       │                        │
                │                                │       │    lock(result_mtx)    │
                │  result_queue ◀────────────────────────│    push(result)        │
                │   (chunk ptr + CPU buffers)    │       │    unlock              │
                │                                │       │                        │
                │  drain ≤N/tick, sort by (cx,cz)│       │                        │
                │    install .generated          │       │                        │
                │    install .meshed + upload    │       │                        │
                │    mark neighbours mesh_dirty  │       │                        │
                │    enqueue newly-mesheable     │       │                        │
                └────────────────────────────────┘       └────────────────────────┘
```

Single queue of *combined* gen+mesh jobs in phase 1. Future splits (see
"Open follow-ups") can promote this to a 3-stage pipeline
(gen_queue → mesh_queue → upload_queue) without disturbing the call
sites — only the `JobReq` union gains a variant.

### Why one combined job and not two pipeline stages

For a first landing, "gen the chunk, then immediately mesh it, ship
both results back" is much simpler than a two-stage pipeline, because:

- **No inter-stage scheduling on the main thread.** A pipeline would
  need main to track "K is generated, all its neighbours are generated,
  now push a mesh job". That bookkeeping exists today for the sync
  path; making it async means a second "in-flight mesh" set that shares
  ownership rules with the chunk map. Worth doing, but not on a
  first-landing budget.
- **The expensive part (mesh: 32–44 ms) is 30× the cheap part (gen:
  ~1 ms).** Splitting them wouldn't meaningfully change thread
  utilisation on one worker.
- **The neighbour-readiness constraint is captured inline.** When the
  main thread enqueues a combined gen+mesh job, it passes snapshot
  pointers to the 4 neighbours. If any neighbour is missing, we pass
  `null` and the mesher treats it as air — which produces seam holes
  on the outer edge of the loaded region. That matches the current
  behaviour (the outer ring is always unmeshed until its neighbours
  load). The inner ring has all neighbours by construction, so no
  holes.

### Sync points and ordering rules

Enqueue side (main thread):

1. Walk `world.spiral_offsets` innermost-first.
2. For each (dx, dz): if chunk (anchor_cx+dx, anchor_cz+dz) is not
   already in `chunks` or `in_flight` — enqueue it. Record it in
   `in_flight` so we don't enqueue it twice.
3. Cap **in-flight** to `ASYNC_MAX_IN_FLIGHT = 8`. Prevents a sprinting
   player from filling the queue with 200 chunks.

Drain side (main thread, top of voxelTick):

1. Lock `result_mtx`, move everything into a local `scratch` list,
   unlock.
2. **Sort `scratch` by `(cx, cz)` lexicographic.** This is the
   determinism fix — the worker may finish jobs in any order (though
   our phase-1 single worker is FIFO in practice; the sort is a safety
   net against future changes), and HashMap iteration order on the main
   thread depends on insertion order, so we must always install in a
   canonical order.
3. For each result in sorted order:
   - Allocate a `LoadedChunk`, copy the worker's `Chunk` into it,
     `put` into `world.chunks`, mark the 4 horizontal neighbours
     `mesh_dirty = true`. (Same behaviour as `World.generateChunk`.)
   - Take the worker's CPU vertex/index slices, `mesh.clear()` +
     `appendSlice` into the chunk's own `Mesh`, free the worker slices,
     set `state = .meshed`, `mesh_dirty = false`,
     `mesh_incremental_dirty = true` (upload happens next render pass).
   - Remove from `in_flight`.

### The snapshot problem

A mesh job needs `getSkylight` for all 4 horizontal neighbours. On the
worker side, the `BlockGetter.ctx` has to point at something that can
answer `getSkylight(wx, wy, wz)` without touching the main thread's
chunk map.

**Phase 1 approach:** each mesh job captures **5 Chunk value-copies**
(self + up to 4 neighbours), owned by the job. The worker's
`BlockGetter` routes lookups through a stack struct that holds the
5 copies. Value-copies are cheap-ish: ~1.15 MB × 5 ≈ 5.75 MB of
`memcpy` per mesh job. At `memcpy` ~10 GB/s that's ~600 µs per job of
pure copy cost — acceptable given the 34 ms saved. Total allocator
pressure is bounded by `ASYNC_MAX_IN_FLIGHT × 5 × 1.15 MB ≈ 46 MB`.

**Why value-copy and not pointer-share:** it eliminates the entire
"main thread must not mutate these 5 chunks while the worker holds
them" coordination problem. Digging or future relight only touches
the main-thread Mesh for already-loaded chunks; those are never
passed to the worker. The 5 copies are immutable snapshots for the
worker's exclusive use.

**Future optimisation** (not in phase 1): use a read-locked
pointer-share for the common case and fall back to copy only when a
write is observed. Not worth the complexity today.

### Thread count

**Phase 1: one worker thread.** The justification:

- Single worker churns meshes at ~30 ms each = ~33 meshes/second.
- A walking player crosses a chunk boundary every ~1.5 seconds at the
  current movement speed, loading ~3–5 chunks at a time.
- So 33/sec is already an order of magnitude more throughput than the
  player can demand on the walking case.
- The only case that exercises more is a teleport (e.g. respawn in an
  unloaded region), which is already mediated by the
  `state.world_loading` screen and the pregen ring.

**Two workers** would help only if (a) a single thread is bottlenecked
on CPU **and** (b) there's contention we can't fix with a smarter
single-worker loop. Neither is true yet. Defer until we have numbers
that argue for it.

## Native-first, web-later implementation path

The worker entry point:

```zig
fn workerMain(ctx: *WorkerContext) void {
    while (true) {
        ctx.job_mtx.lock();
        while (ctx.jobs.items.len == 0 and !ctx.shutdown.load(.acquire)) {
            ctx.job_cv.wait(&ctx.job_mtx);
        }
        if (ctx.shutdown.load(.acquire) and ctx.jobs.items.len == 0) {
            ctx.job_mtx.unlock();
            return;
        }
        const job = ctx.jobs.orderedRemove(0);
        ctx.job_mtx.unlock();

        processJob(ctx, job);
    }
}
```

`processJob` is pure: it reads from `job`, writes to `ctx.results`
(guarded by `result_mtx`), and calls only:

- `world_gen.sampleHeight` (noise, pure function)
- `chunk.generateTerrain` / `computeSkylight` (read+write on job-owned
  Chunk)
- `mesher.generateMesh` (read-only on snapshot, write on
  worker-allocated buffers)
- `std.heap.c_allocator` (thread-safe by delegation to `malloc`)

No `sw_gpu` import. No `state.*` access. No `std.log` inside the hot
path (logging from worker threads on macOS has historically been racy;
keep it main-thread).

### Web Worker port checklist (follow-up)

When the web port lands, the changes are:

1. Compile `async_chunks.zig` as a second WASM target (`-Dtarget=web_worker`).
2. Write ~40 lines of JS glue that spawns a Worker, loads the second
   WASM, calls `init_worker_context(sab)` and `worker_main(sab)`.
3. Replace `job_mtx`/`job_cv` with `Atomics.wait/notify` on a shared
   `Int32Array`. Replace `std.ArrayList` queues with fixed-size
   ring buffers backed by `SharedArrayBuffer`.
4. Set the COOP/COEP headers on the dev server and Fly.io gateway.
5. Main-thread JS wraps the Zig `drainResults` in a pre-render
   pass and the `enqueue` in a post-tick pass, same as native.

Zig voxel source changes: **zero**, except possibly the queue types
hiding behind a backend trait.

## Risks and gotchas

### wgpu-native handle thread safety

wgpu-native documentation is silent on thread safety of `WGPUDevice` /
`WGPUQueue` / buffer handles. Empirically, `wgpuQueueWriteBuffer` from
multiple threads causes sporadic crashes on macOS/Metal. Rule: **GPU
handles stay on the render thread**. The worker only produces raw
bytes; main thread owns all `createBuffer` + `queueWriteBuffer` calls.

### TAS determinism

The three regression TAS scripts produce captured PPMs that must be
byte-identical across the sync and async implementations. The
determinism argument:

- Pregen order: identical. Pregen uses the same inside-out square scan,
  just enqueues instead of running sync. The worker processes FIFO;
  main drains sorted. Inner ring meshes land in `(cx, cz)` order in
  both paths — sync used `chunks.iterator()` which is not order-stable
  across insertions, **but** pregen happens before any deletions so
  the iterator is effectively insertion-order. The async path's
  sort-on-drain is a stricter invariant.
- Mesh output is a pure function of `(chunk_blocks, 4 neighbours'
  blocks+skylight, ao_strategy, lighting_mode)`. None of these change
  as a function of *when* the mesh runs, so a given chunk produces the
  same bytes regardless of which thread built it.
- The `dump-frame` captures the frame **after** the TAS finishes and
  **after** world loading is complete, so it sees the fully-converged
  state. Async and sync both converge to the same state; only the
  wall-clock duration differs.

### Queue bloat / memory pressure

Each queued gen+mesh job owns 5 × ~1.15 MB = ~5.75 MB of Chunk copies.
`ASYNC_MAX_IN_FLIGHT = 8` caps total job memory at ~46 MB. The result
queue additionally owns raw vertex/index slices until drained; those
are tens of KB each, bounded by the same cap. At ≤50 MB worst case,
comfortable on both native and a 2 GB WASM heap.

### Shutdown

`deinit` on the pipeline sets the shutdown atomic, signals the
condvar, and `join()`s the worker. Any in-flight job finishes; any
queued-but-unstarted jobs are discarded. Result buffers on the result
queue are freed during drain, and anything still in-flight on shutdown
is freed inside the worker's result-push path.

### Logging

`std.log.info` is safe on all platforms (it goes through `std.debug.print`
which locks stderr). But high-frequency logging from the worker is
visually noisy. Phase 1: one summary log per mesh
(`[ASYNC-MESH] chunk ({},{}) gen+mesh={}us quads={}`) in the worker,
and one `[ASYNC] drain N chunks` in the main thread.

## Phase 1 implementation surface

### New file: `examples/voxel/async_chunks.zig`

```zig
// Job types
const JobKind = enum { gen_and_mesh };

pub const Job = struct {
    cx: i32, cz: i32,
    ao: gpu_mod.AOStrategy,
    lighting: gpu_mod.LightingMode,
    gen_config: world_gen.WorldGenConfig,
    // 4 optional neighbour snapshots. null = treated as air/bright sky.
    neighbours: [4]?*const chunk_mod.Chunk, // -X, +X, -Z, +Z
};

pub const Result = struct {
    cx: i32, cz: i32,
    chunk: *chunk_mod.Chunk,          // heap-alloc from c_allocator
    vertices: []mesher_mod.VoxelVertex, // c_allocator
    indices: []u32,                   // c_allocator
    quad_block: []u32,                // c_allocator
    quad_highlight: []u8,             // c_allocator
};

pub const Pipeline = struct {
    allocator: std.mem.Allocator, // persistent state; uses caller allocator
    jobs: std.ArrayList(Job),
    results: std.ArrayList(Result),
    job_mtx: std.Thread.Mutex,
    result_mtx: std.Thread.Mutex,
    job_cv: std.Thread.Condition,
    shutdown: std.atomic.Value(bool),
    thread: ?std.Thread,
    in_flight: std.AutoHashMap(ChunkKey, void),

    pub fn init(allocator: std.mem.Allocator) !Pipeline { ... }
    pub fn deinit(self: *Pipeline) void { ... }
    pub fn enqueue(self: *Pipeline, job: Job) !bool { ... }
    pub fn drainSorted(self: *Pipeline, out: *std.ArrayList(Result)) !void { ... }
    pub fn inFlightCount(self: *Pipeline) usize { ... }
    pub fn isInFlight(self: *Pipeline, cx: i32, cz: i32) bool { ... }
};

fn workerMain(self: *Pipeline) void { ... }
fn processJob(self: *Pipeline, job: Job) void { ... }
```

Result buffers are allocated from `std.heap.c_allocator` directly inside
`processJob`, not from the pipeline's own allocator, so the worker's
allocations are independent of the main thread.

### Wiring into `main.zig`

1. Parse `--async-chunks=on|off` flag. Default: on. Store in `state.async_chunks_enabled: bool`.
2. In `voxelInit`, after `state.world = ...`: if enabled, init
   `state.async_pipeline = try async_chunks.Pipeline.init(allocator)`.
3. In `voxelShutdown`: if enabled, `state.async_pipeline.deinit()`.
4. In `voxelTick`, replace the sync gen+mesh block with a branch:
   - If `!async_chunks_enabled`: existing code path, unchanged.
   - If enabled: (a) drain results → install; (b) enqueue gen+mesh
     jobs for spiral offsets that are missing and not already in-flight.
5. In `pregenStep`: if enabled, uses the same enqueue+drain flow. The
   "ring_ready" check becomes "all inner-ring chunks are in the chunk
   map and meshed", same as today.

The time-budgeted sync path stays in place behind `!async_chunks_enabled`
so we can A/B test determinism (`--async-chunks=off` vs `on`) and toggle
it off if something breaks in production.

## Open follow-ups (explicitly out of phase 1)

1. **Web Worker port.** Documented in "Native-first, web-later" above.
   ~40 lines of JS glue + 1 WASM target + COOP/COEP headers.
2. **Two-stage pipeline** (gen → mesh as separate jobs). Only justified
   if we find a case where gen is idle-waiting for mesh or vice versa.
3. **Multi-worker.** Two mesh workers if profiling shows CPU headroom.
4. **Lock-free MPSC queue.** `std.Thread.Mutex + ArrayList` is fine at
   the current job rate (dozens per second). Only matters at 10K+/s.
5. **`Chunk`-is-POD compile-time assertion.** Forces `extern struct` or
   similar. Belongs in `chunk.zig`, not this file.
6. **Cross-chunk skylight propagation** (phase-2 lighting). Unrelated —
   it's about what the mesher reads, not where it runs.
7. **Relight-on-dig.** Same — unrelated to async.

## Phase 1 success criteria

- `zig build native -Dexample=voxel` clean.
- `./zig-out/bin/voxel --headless --tas examples/voxel/framespike.tas`
  exits 0 on both `--async-chunks=on` and `--async-chunks=off`.
- `--dump-frame` output for `ao_corners.tas`, `cave_skylight.tas`, and
  `framespike.tas` is **byte-identical** to the pre-async baseline with
  `--async-chunks=on`. (Baseline hashes recorded during development are
  at the bottom of this doc.)
- Walking off the pregen ring: the main-thread mesh log line
  (`[ASYNC] drained N chunks upload=...us`) costs ≤ a few hundred µs per
  drained chunk, vs 32–44 ms on the sync path. Ideally no mesh log shows
  the old `gen=34000us` spike anymore while async is on.

## Baseline PPM hashes (sync path, recorded 2026-04-12)

```
279d735e75d1cd7298ce694bb559a669893b00c7  ao_corners.ppm
1eb4d04fca80c71df862c51732f458f73c9b1e00  cave_skylight.ppm
5d78d3f809701ce331df613993eaaeda6a11cf69  framespike.ppm
```

Commands used to produce them:

```
./zig-out/bin/voxel --world=flatland --ao=classic --lighting=skylight --aa=none \
  --tas examples/voxel/tests/ao_corners.tas \
  --dump-frame=/tmp/voxel-async-baseline/ao_corners.ppm

./zig-out/bin/voxel --world=flatland --ao=classic --lighting=skylight --aa=none \
  --tas examples/voxel/tests/cave_skylight.tas \
  --dump-frame=/tmp/voxel-async-baseline/cave_skylight.ppm

./zig-out/bin/voxel --world=hilly --ao=classic --lighting=skylight --aa=none \
  --tas examples/voxel/framespike.tas \
  --dump-frame=/tmp/voxel-async-baseline/framespike.ppm
```
