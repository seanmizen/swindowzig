//! Native async chunk gen+mesh pipeline.
//!
//! One worker thread, two mutex-guarded FIFOs. Job = (cx, cz, 3×3 chunk
//! snapshots). Worker generates the center chunk (if not provided), meshes it
//! using the snapshots as a BlockGetter, ships owned CPU buffers back. Main
//! thread drains results per tick, sorts by (cx, cz) for determinism, copies
//! buffers into the real LoadedChunk's mesh, uploads to GPU.
//!
//! The worker entry point touches only this module, `chunk.zig`, `mesher.zig`,
//! `world_gen.zig`, and `std.heap.c_allocator`. No `sw_gpu` import. No
//! main-thread state. This is the property that keeps the Web Worker port
//! cheap (see `examples/voxel/docs/async-chunks.md`).

const std = @import("std");
const chunk_mod = @import("chunk.zig");
const mesher_mod = @import("mesher.zig");
const world_gen = @import("world_gen.zig");
const gpu_mod = @import("sw_gpu");

const Chunk = chunk_mod.Chunk;
const BlockType = chunk_mod.BlockType;
const BlockGetter = chunk_mod.BlockGetter;
const MAX_SKYLIGHT = chunk_mod.MAX_SKYLIGHT;
const CHUNK_W = chunk_mod.CHUNK_W;
const CHUNK_H = chunk_mod.CHUNK_H;
const VoxelVertex = mesher_mod.VoxelVertex;

/// Cap on simultaneously in-flight jobs. Bounds worst-case memory at
/// ASYNC_MAX_IN_FLIGHT × 9 × sizeof(Chunk) ≈ ~80 MB. Past this the main thread
/// stops enqueueing and lets the worker drain.
pub const ASYNC_MAX_IN_FLIGHT: usize = 8;

/// Index into the 3×3 snapshots grid. Row-major (dcz+1)*3 + (dcx+1).
fn snapIndex(dcx: i32, dcz: i32) usize {
    return @intCast((dcz + 1) * 3 + (dcx + 1));
}

/// Center slot of the 3×3 snapshots grid — index 4.
const CENTER_SLOT: usize = 4;

/// A single gen+mesh or mesh-only job.
///
/// `snapshots[CENTER_SLOT]` is interpreted as follows:
///   - null → this is a gen-and-mesh job. Worker allocates a fresh Chunk,
///            runs `generateTerrain` + `computeSkylight`, then meshes it.
///   - non-null → this is a mesh-only job (re-mesh because a neighbour
///            arrived). Worker uses the pointed-to Chunk directly as the
///            mesh target, does not regenerate.
///
/// Non-center slots are optional snapshots of up to 8 surrounding chunks.
/// null neighbours are treated as air (skylight = 0 in the -Y direction,
/// MAX_SKYLIGHT above chunk top). The 4 diagonal neighbours (slots 0, 2,
/// 6, 8) are required for deterministic AO sampling at chunk corners —
/// see `examples/voxel/docs/async-chunks.md`.
///
/// The Job owns all non-null Chunk pointers (allocated with c_allocator by
/// the enqueueing code) and the worker is responsible for freeing them all
/// via the same allocator after the result is pushed.
pub const Job = struct {
    cx: i32,
    cz: i32,
    gen_config: world_gen.WorldGenConfig,
    ao: gpu_mod.AOStrategy,
    lighting: gpu_mod.LightingMode,
    snapshots: [9]?*Chunk,
};

/// CPU-side mesh buffers produced by the worker. Main thread takes ownership
/// on drain and frees them via `c_allocator` after installing into the
/// LoadedChunk's mesh.
pub const Result = struct {
    cx: i32,
    cz: i32,
    /// For gen+mesh jobs: the newly-generated Chunk, heap-allocated from
    /// `c_allocator`. Main thread copies it by value into the LoadedChunk
    /// slot and frees the worker's allocation.
    /// For mesh-only jobs: null — main thread leaves the existing Chunk
    /// in place.
    chunk: ?*Chunk,
    /// Wall-clock time spent gen+mesh-ing this chunk, in microseconds.
    /// Purely informational; dumped to `std.log.info` on drain.
    worker_us: u64,
    vertices: []VoxelVertex,
    indices: []u32,
    quad_block: []u32,
    quad_highlight: []u8,
};

/// BlockGetter implementation that routes queries through a 3×3 grid of
/// Chunk snapshots owned by the current Job. The mesher never writes through
/// the getter — this is a read-only view for the worker thread only.
const SnapshotGetter = struct {
    cx: i32,
    cz: i32,
    snapshots: *const [9]?*Chunk,

    fn lookupChunk(self: *const SnapshotGetter, wx: i32, wz: i32) struct { ch: ?*const Chunk, lx: i32, lz: i32 } {
        const target_cx = @divFloor(wx, CHUNK_W);
        const target_cz = @divFloor(wz, CHUNK_W);
        const dcx = target_cx - self.cx;
        const dcz = target_cz - self.cz;
        if (dcx < -1 or dcx > 1 or dcz < -1 or dcz > 1) {
            return .{ .ch = null, .lx = 0, .lz = 0 };
        }
        const slot = snapIndex(dcx, dcz);
        const ch_opt = self.snapshots[slot];
        const lx = wx - target_cx * CHUNK_W;
        const lz = wz - target_cz * CHUNK_W;
        return .{ .ch = ch_opt, .lx = lx, .lz = lz };
    }

    fn getBlock(ctx: *const anyopaque, x: i32, y: i32, z: i32) BlockType {
        const self: *const SnapshotGetter = @ptrCast(@alignCast(ctx));
        if (y < 0 or y >= CHUNK_H) return .air;
        const look = self.lookupChunk(x, z);
        const ch = look.ch orelse return .air;
        return ch.getBlock(look.lx, @intCast(y), look.lz);
    }

    fn getSkylight(ctx: *const anyopaque, x: i32, y: i32, z: i32) u8 {
        const self: *const SnapshotGetter = @ptrCast(@alignCast(ctx));
        if (y >= CHUNK_H) return MAX_SKYLIGHT;
        if (y < 0) return 0;
        const look = self.lookupChunk(x, z);
        const ch = look.ch orelse return 0;
        return ch.getSkylight(look.lx, @intCast(y), look.lz);
    }

    fn getBlockLightFn(ctx: *const anyopaque, x: i32, y: i32, z: i32) u8 {
        const self: *const SnapshotGetter = @ptrCast(@alignCast(ctx));
        if (y < 0 or y >= CHUNK_H) return 0;
        const look = self.lookupChunk(x, z);
        const ch = look.ch orelse return 0;
        return ch.getBlockLight(look.lx, @intCast(y), look.lz);
    }

    fn asBlockGetter(self: *const SnapshotGetter) BlockGetter {
        return .{
            .ctx = self,
            .getFn = getBlock,
            .getSkylightFn = getSkylight,
            .getBlockLightFn = getBlockLightFn,
        };
    }
};

pub const Pipeline = struct {
    /// Allocator used for persistent pipeline state (queue storage, the
    /// in-flight set). Worker result buffers and Chunk snapshots use
    /// `std.heap.c_allocator` directly so the worker is decoupled from
    /// whatever the main thread hands us.
    allocator: std.mem.Allocator,
    jobs: std.ArrayList(Job),
    results: std.ArrayList(Result),
    in_flight: std.AutoHashMap(ChunkKey, void),
    job_mtx: std.Thread.Mutex,
    result_mtx: std.Thread.Mutex,
    job_cv: std.Thread.Condition,
    shutdown: std.atomic.Value(bool),
    thread: ?std.Thread,

    const ChunkKey = struct { cx: i32, cz: i32 };

    pub fn init(allocator: std.mem.Allocator) !*Pipeline {
        const self = try allocator.create(Pipeline);
        self.* = .{
            .allocator = allocator,
            .jobs = .{},
            .results = .{},
            .in_flight = std.AutoHashMap(ChunkKey, void).init(allocator),
            .job_mtx = .{},
            .result_mtx = .{},
            .job_cv = .{},
            .shutdown = std.atomic.Value(bool).init(false),
            .thread = null,
        };
        self.thread = try std.Thread.spawn(.{}, workerMain, .{self});
        return self;
    }

    pub fn deinit(self: *Pipeline) void {
        // Signal shutdown and wake the worker.
        self.job_mtx.lock();
        self.shutdown.store(true, .release);
        self.job_cv.signal();
        self.job_mtx.unlock();

        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }

        // Drop any unprocessed jobs: free their owned Chunk snapshots.
        for (self.jobs.items) |*job| freeJobSnapshots(job);
        self.jobs.deinit(self.allocator);

        // Drop any un-drained results: free their owned buffers.
        for (self.results.items) |*r| freeResult(r);
        self.results.deinit(self.allocator);

        self.in_flight.deinit();

        const alloc = self.allocator;
        alloc.destroy(self);
    }

    /// Try to enqueue a job. Returns true on success, false if at cap.
    /// Caller retains ownership of the job's snapshot pointers until this
    /// returns true — once enqueued, the pipeline owns them.
    pub fn tryEnqueue(self: *Pipeline, job: Job) !bool {
        self.job_mtx.lock();
        defer self.job_mtx.unlock();

        const key = ChunkKey{ .cx = job.cx, .cz = job.cz };
        if (self.in_flight.contains(key)) return false;
        if (self.in_flight.count() >= ASYNC_MAX_IN_FLIGHT) return false;

        try self.jobs.append(self.allocator, job);
        try self.in_flight.put(key, {});
        self.job_cv.signal();
        return true;
    }

    pub fn isInFlight(self: *Pipeline, cx: i32, cz: i32) bool {
        self.job_mtx.lock();
        defer self.job_mtx.unlock();
        return self.in_flight.contains(.{ .cx = cx, .cz = cz });
    }

    pub fn inFlightCount(self: *Pipeline) usize {
        self.job_mtx.lock();
        defer self.job_mtx.unlock();
        return self.in_flight.count();
    }

    /// Drain all pending results into `out`, clear the internal queue, and
    /// sort the drained results by (cx, cz) lexicographic — the determinism
    /// fix described in `docs/async-chunks.md`.
    ///
    /// Also removes drained chunks from the in_flight set so new jobs for
    /// the same coord can be enqueued if needed.
    pub fn drainSorted(self: *Pipeline, out: *std.ArrayList(Result), alloc: std.mem.Allocator) !void {
        // Swap the results queue out under the result lock so the worker
        // can keep pushing while main processes.
        self.result_mtx.lock();
        const taken = self.results;
        self.results = .{};
        self.result_mtx.unlock();
        defer {
            var mut = taken;
            mut.deinit(self.allocator);
        }

        // Drop from in_flight (requires job lock).
        {
            self.job_mtx.lock();
            defer self.job_mtx.unlock();
            for (taken.items) |r| {
                _ = self.in_flight.remove(.{ .cx = r.cx, .cz = r.cz });
            }
        }

        try out.ensureTotalCapacity(alloc, out.items.len + taken.items.len);
        for (taken.items) |r| out.appendAssumeCapacity(r);

        // Sort by (cx, cz) so downstream processing is order-independent
        // of worker scheduling.
        const Less = struct {
            fn lt(_: void, a: Result, b: Result) bool {
                if (a.cx != b.cx) return a.cx < b.cx;
                return a.cz < b.cz;
            }
        };
        std.mem.sort(Result, out.items, {}, Less.lt);
    }
};

/// Allocate a heap Chunk copy from c_allocator. Caller owns the returned ptr.
pub fn cloneChunk(src: *const Chunk) !*Chunk {
    const ch = try std.heap.c_allocator.create(Chunk);
    ch.* = src.*;
    return ch;
}

/// Free a Chunk previously returned by `cloneChunk`.
pub fn freeChunk(ch: *Chunk) void {
    std.heap.c_allocator.destroy(ch);
}

fn freeJobSnapshots(job: *Job) void {
    for (&job.snapshots) |*slot| {
        if (slot.*) |p| {
            std.heap.c_allocator.destroy(p);
            slot.* = null;
        }
    }
}

fn freeResult(r: *Result) void {
    if (r.chunk) |ch| std.heap.c_allocator.destroy(ch);
    std.heap.c_allocator.free(r.vertices);
    std.heap.c_allocator.free(r.indices);
    std.heap.c_allocator.free(r.quad_block);
    std.heap.c_allocator.free(r.quad_highlight);
}

// ─── Worker thread ──────────────────────────────────────────────────────────

fn workerMain(pipeline: *Pipeline) void {
    while (true) {
        // Pop a job under the job lock.
        pipeline.job_mtx.lock();
        while (pipeline.jobs.items.len == 0 and !pipeline.shutdown.load(.acquire)) {
            pipeline.job_cv.wait(&pipeline.job_mtx);
        }
        if (pipeline.shutdown.load(.acquire) and pipeline.jobs.items.len == 0) {
            pipeline.job_mtx.unlock();
            return;
        }
        var job = pipeline.jobs.orderedRemove(0);
        pipeline.job_mtx.unlock();

        processJob(pipeline, &job) catch |err| {
            std.log.err("[ASYNC-WORKER] job ({},{}) failed: {}", .{ job.cx, job.cz, err });
            freeJobSnapshots(&job);
            // Even on failure we must release the in_flight slot so the
            // main thread can retry or move on. Easiest path: push a
            // fake empty result that main will install as an empty mesh.
            // Rare and non-fatal.
            pushEmptyResult(pipeline, job.cx, job.cz) catch {};
        };
    }
}

fn processJob(pipeline: *Pipeline, job: *Job) !void {
    const t0 = std.time.nanoTimestamp();

    // Resolve the target chunk. For gen+mesh jobs (center slot == null),
    // allocate a fresh Chunk and run the worldgen + skylight pipeline.
    // For mesh-only jobs, take ownership of the caller-provided snapshot.
    //
    // After this block, the worker exclusively owns `target_ptr` and must
    // free it on any error path. On the success path, ownership is either
    // transferred to `result.chunk` (gen+mesh) or released inline (mesh-only).
    var target_owned_gen: bool = false;
    var target_ptr: *Chunk = undefined;
    if (job.snapshots[CENTER_SLOT]) |existing| {
        target_ptr = existing;
        // The center slot is consumed by the worker as the target; we
        // must NOT double-free it as a neighbour snapshot.
        job.snapshots[CENTER_SLOT] = null;
    } else {
        target_ptr = try std.heap.c_allocator.create(Chunk);
        target_ptr.* = Chunk.init(std.heap.c_allocator);
        try target_ptr.generateTerrain(job.cx, job.cz, job.gen_config);
        target_owned_gen = true;
    }
    var target_consumed: bool = false;
    errdefer if (!target_consumed) std.heap.c_allocator.destroy(target_ptr);

    // Build a snapshot view over a 3×3 grid where the center is the target.
    var snaps: [9]?*Chunk = undefined;
    var i: usize = 0;
    while (i < 9) : (i += 1) {
        snaps[i] = if (i == CENTER_SLOT) target_ptr else job.snapshots[i];
    }

    const getter_impl = SnapshotGetter{
        .cx = job.cx,
        .cz = job.cz,
        .snapshots = &snaps,
    };
    const getter = getter_impl.asBlockGetter();

    // Mesh into a scratch Mesh backed by c_allocator so we can hand off
    // the buffer ownership without touching the main thread's allocator.
    // Defer deinit so it runs on both the success (no-op on empty
    // ArrayLists after toOwnedSlice) and error paths.
    var scratch_mesh = mesher_mod.Mesh.init(std.heap.c_allocator);
    defer scratch_mesh.deinit();

    try mesher_mod.generateMesh(
        target_ptr,
        &scratch_mesh,
        job.cx * CHUNK_W,
        job.cz * CHUNK_W,
        getter,
        job.ao,
        job.lighting,
    );

    // Extract owned slices. After `toOwnedSlice` the ArrayLists are empty,
    // so the subsequent `deinit` only frees any zero-length sort scratches.
    const verts = try scratch_mesh.vertices.toOwnedSlice(std.heap.c_allocator);
    errdefer std.heap.c_allocator.free(verts);
    const inds = try scratch_mesh.indices.toOwnedSlice(std.heap.c_allocator);
    errdefer std.heap.c_allocator.free(inds);
    const qb = try scratch_mesh.quad_block.toOwnedSlice(std.heap.c_allocator);
    errdefer std.heap.c_allocator.free(qb);
    const qh = try scratch_mesh.quad_highlight.toOwnedSlice(std.heap.c_allocator);
    errdefer std.heap.c_allocator.free(qh);

    // Neighbour snapshots have served their purpose. Free them before we
    // publish the result so the worker's working set shrinks immediately.
    freeJobSnapshots(job);

    const t_ns = std.time.nanoTimestamp() - t0;
    const worker_us: u64 = @intCast(@divTrunc(t_ns, 1000));

    // For mesh-only jobs we're done with `target_ptr` — free the snapshot
    // here and mark the ownership-tracking flag so the errdefer doesn't
    // double-free it. For gen+mesh jobs, `target_ptr` will be moved into
    // the result struct below and the errdefer remains armed until the
    // result successfully reaches the results queue.
    const result_chunk: ?*Chunk = blk: {
        if (target_owned_gen) {
            break :blk target_ptr;
        } else {
            std.heap.c_allocator.destroy(target_ptr);
            target_consumed = true;
            break :blk null;
        }
    };

    const result = Result{
        .cx = job.cx,
        .cz = job.cz,
        .chunk = result_chunk,
        .worker_us = worker_us,
        .vertices = verts,
        .indices = inds,
        .quad_block = qb,
        .quad_highlight = qh,
    };

    pipeline.result_mtx.lock();
    defer pipeline.result_mtx.unlock();
    try pipeline.results.append(pipeline.allocator, result);

    // Ownership of `target_ptr` (if any) has now transferred to the result
    // queue. Disarm the errdefer so we don't free it at function return.
    if (target_owned_gen) target_consumed = true;
}

fn pushEmptyResult(pipeline: *Pipeline, cx: i32, cz: i32) !void {
    const empty = Result{
        .cx = cx,
        .cz = cz,
        .chunk = null,
        .worker_us = 0,
        .vertices = &.{},
        .indices = &.{},
        .quad_block = &.{},
        .quad_highlight = &.{},
    };
    pipeline.result_mtx.lock();
    defer pipeline.result_mtx.unlock();
    try pipeline.results.append(pipeline.allocator, empty);
}

// ─── Public install helper used by main.zig on the drain side ──────────────

/// Install a drained result's mesh buffers into an existing `Mesh`, freeing
/// the worker's owned slices. Does NOT touch the chunk data — that's the
/// caller's responsibility (differs between gen+mesh and mesh-only paths).
pub fn installMeshFromResult(mesh: *mesher_mod.Mesh, result: *const Result) !void {
    mesh.clear();
    try mesh.vertices.appendSlice(mesh.allocator, result.vertices);
    try mesh.indices.appendSlice(mesh.allocator, result.indices);
    try mesh.quad_block.appendSlice(mesh.allocator, result.quad_block);
    try mesh.quad_highlight.appendSlice(mesh.allocator, result.quad_highlight);
    mesh.sort_valid = false; // force painter's-algorithm re-sort next render
}

/// Free a result's owned heap buffers. Call after `installMeshFromResult`.
pub fn releaseResult(r: *Result) void {
    freeResult(r);
}
