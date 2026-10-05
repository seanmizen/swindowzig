//! Native async chunk gen+mesh pipeline.
//!
//! One worker thread, two mutex-guarded FIFOs. Job = (cx, cz, a copy of the
//! center if it exists, and the borders of its neighbours). Worker generates
//! the center chunk (if not provided), meshes it through the borders as a
//! BlockGetter, ships owned CPU buffers back. Main
//! thread drains results per tick, sorts by (cx, cz) for determinism, copies
//! buffers into the real LoadedChunk's mesh, uploads to GPU.
//!
//! The worker entry point touches only this module, `chunk.zig`, `mesher.zig`,
//! `world_gen.zig`, and `std.heap.c_allocator`. No `sw_gpu` import. No
//! main-thread state. This is the property that keeps the Web Worker port
//! cheap (see `examples/voxel/docs/async-chunks.md`).

const std = @import("std");
const clock = @import("clock.zig");
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

/// Cap on simultaneously in-flight jobs. Bounds the memory that jobs hold:
/// a deep copy of the center (about 150 KB) and up to 8 borders (about
/// 170 KB) per job. Past this the main thread stops enqueueing and lets the
/// worker drain.
pub const ASYNC_MAX_IN_FLIGHT: usize = 8;

/// Index into the 3×3 snapshots grid. Row-major (dcz+1)*3 + (dcx+1).
fn snapIndex(dcx: i32, dcz: i32) usize {
    return @intCast((dcz + 1) * 3 + (dcx + 1));
}

/// Center slot of the 3×3 snapshots grid — index 4.
const CENTER_SLOT: usize = 4;

/// A single gen+mesh or mesh-only job.
///
/// `center`:
///   - null → this is a gen-and-mesh job. Worker allocates a fresh Chunk,
///            runs `generateTerrain` + `computeSkylight`, then meshes it.
///   - non-null → this is a mesh-only job (re-mesh because a neighbour
///            arrived). A deep copy of the chunk (cloneChunk): the worker
///            meshes it and does not regenerate.
///
/// `borders` (slot = snapIndex(dcx, dcz), CENTER_SLOT unused): the cells of
/// up to 8 surrounding chunks that the mesher reads (see Border). null
/// neighbours are treated as air (skylight = 0 in the -Y direction,
/// MAX_SKYLIGHT above chunk top). The 4 diagonal neighbours (slots 0, 2,
/// 6, 8) are required for deterministic AO sampling at chunk corners —
/// see `examples/voxel/docs/async-chunks.md`.
///
/// The Job owns its center and borders (allocated with c_allocator), and
/// the worker frees them. Nothing in a Job points into a live chunk, so the
/// main thread can edit or evict chunks while the job runs.
pub const Job = struct {
    cx: i32,
    cz: i32,
    gen_config: world_gen.WorldGenConfig,
    ao: gpu_mod.AOStrategy,
    lighting: gpu_mod.LightingMode,
    center: ?*Chunk = null,
    borders: [9]?*Border = @splat(null),
};

/// How far into a neighbour chunk the mesher reads: propagated AO samples
/// 3 blocks outward from a face. The border test meshes through borders and
/// through full chunks and checks that the meshes are the same.
pub const BORDER: i32 = 3;

/// A copy of the cells of one neighbour chunk that are within BORDER blocks
/// of the target chunk: all y, and the x and z range next to the target.
/// Blocks are decoded (one BlockType per cell), so a read is an array index.
pub const Border = struct {
    /// Local cells of the neighbour held: x in [x0, x0 + w), z in [z0, z0 + d).
    x0: i32,
    z0: i32,
    w: i32,
    d: i32,
    blocks: []BlockType,
    sky: []u8,
    block_light: []u8,

    /// Copy the cells of `src` (the neighbour at offset (dcx, dcz) from the
    /// target) that the mesher can read.
    pub fn fromChunk(src: *const Chunk, dcx: i32, dcz: i32) !*Border {
        const a = std.heap.c_allocator;
        // dcx = -1: the target is east of src, so src's east cells.
        const x0: i32 = if (dcx < 0) CHUNK_W - BORDER else 0;
        const w: i32 = if (dcx == 0) CHUNK_W else BORDER;
        const z0: i32 = if (dcz < 0) CHUNK_W - BORDER else 0;
        const d: i32 = if (dcz == 0) CHUNK_W else BORDER;
        const n: usize = @intCast(w * d * CHUNK_H);
        const b = try a.create(Border);
        errdefer a.destroy(b);
        b.* = .{ .x0 = x0, .z0 = z0, .w = w, .d = d, .blocks = try a.alloc(BlockType, n), .sky = &.{}, .block_light = &.{} };
        errdefer a.free(b.blocks);
        b.sky = try a.alloc(u8, n);
        errdefer a.free(b.sky);
        b.block_light = try a.alloc(u8, n);
        var i: usize = 0;
        var x: i32 = x0;
        while (x < x0 + w) : (x += 1) {
            var y: i32 = 0;
            while (y < CHUNK_H) : (y += 1) {
                var z: i32 = z0;
                while (z < z0 + d) : (z += 1) {
                    b.blocks[i] = src.resolveBlockRaw(x, y, z);
                    b.sky[i] = src.skylight[@intCast(x)][@intCast(y)][@intCast(z)];
                    b.block_light[i] = src.block_light[@intCast(x)][@intCast(y)][@intCast(z)];
                    i += 1;
                }
            }
        }
        return b;
    }

    pub fn free(self: *Border) void {
        const a = std.heap.c_allocator;
        a.free(self.blocks);
        a.free(self.sky);
        a.free(self.block_light);
        a.destroy(self);
    }

    pub fn bytes(self: *const Border) usize {
        return self.blocks.len * 3 + @sizeOf(Border);
    }

    /// Index of local cell (lx, y, lz), or null outside the held cells.
    fn index(self: *const Border, lx: i32, y: i32, lz: i32) ?usize {
        const x = lx - self.x0;
        const z = lz - self.z0;
        if (x < 0 or x >= self.w or z < 0 or z >= self.d) return null;
        return @intCast((x * CHUNK_H + y) * self.d + z);
    }
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
    center: *const Chunk,
    borders: *const [9]?*Border,

    /// The chunk slot of world (wx, wz) and its local coordinates, or null
    /// when it is not in the 3×3 grid.
    fn locate(self: *const SnapshotGetter, wx: i32, wz: i32) ?struct { slot: usize, lx: i32, lz: i32 } {
        const target_cx = @divFloor(wx, CHUNK_W);
        const target_cz = @divFloor(wz, CHUNK_W);
        const dcx = target_cx - self.cx;
        const dcz = target_cz - self.cz;
        if (dcx < -1 or dcx > 1 or dcz < -1 or dcz > 1) return null;
        return .{ .slot = snapIndex(dcx, dcz), .lx = wx - target_cx * CHUNK_W, .lz = wz - target_cz * CHUNK_W };
    }

    /// A read outside a border means BORDER is too small for the mesher.
    /// Debug builds stop. Release builds read the cell as missing.
    fn outsideBorder() void {
        std.debug.assert(false);
    }

    fn getBlock(ctx: *const anyopaque, x: i32, y: i32, z: i32) BlockType {
        const self: *const SnapshotGetter = @ptrCast(@alignCast(ctx));
        if (y < 0 or y >= CHUNK_H) return .air;
        const at = self.locate(x, z) orelse return .air;
        if (at.slot == CENTER_SLOT) return self.center.getBlock(at.lx, y, at.lz);
        const b = self.borders[at.slot] orelse return .air;
        const i = b.index(at.lx, y, at.lz) orelse {
            outsideBorder();
            return .air;
        };
        return b.blocks[i];
    }

    fn getSkylight(ctx: *const anyopaque, x: i32, y: i32, z: i32) u8 {
        const self: *const SnapshotGetter = @ptrCast(@alignCast(ctx));
        if (y >= CHUNK_H) return MAX_SKYLIGHT;
        if (y < 0) return 0;
        const at = self.locate(x, z) orelse return 0;
        if (at.slot == CENTER_SLOT) return self.center.getSkylight(at.lx, y, at.lz);
        const b = self.borders[at.slot] orelse return 0;
        const i = b.index(at.lx, y, at.lz) orelse {
            outsideBorder();
            return 0;
        };
        return b.sky[i];
    }

    fn getBlockLightFn(ctx: *const anyopaque, x: i32, y: i32, z: i32) u8 {
        const self: *const SnapshotGetter = @ptrCast(@alignCast(ctx));
        if (y < 0 or y >= CHUNK_H) return 0;
        const at = self.locate(x, z) orelse return 0;
        if (at.slot == CENTER_SLOT) return self.center.getBlockLight(at.lx, y, at.lz);
        const b = self.borders[at.slot] orelse return 0;
        const i = b.index(at.lx, y, at.lz) orelse {
            outsideBorder();
            return 0;
        };
        return b.block_light[i];
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
    /// Io for the locks below, from main() (std.process.Init.io).
    io: std.Io,
    job_mtx: std.Io.Mutex,
    result_mtx: std.Io.Mutex,
    job_cv: std.Io.Condition,
    shutdown: std.atomic.Value(bool),
    thread: ?std.Thread,

    const ChunkKey = struct { cx: i32, cz: i32 };

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !*Pipeline {
        const self = try allocator.create(Pipeline);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .jobs = .empty,
            .results = .empty,
            .in_flight = std.AutoHashMap(ChunkKey, void).init(allocator),
            .job_mtx = .init,
            .result_mtx = .init,
            .job_cv = .init,
            .shutdown = std.atomic.Value(bool).init(false),
            .thread = null,
        };
        self.thread = try std.Thread.spawn(.{}, workerMain, .{self});
        return self;
    }

    pub fn deinit(self: *Pipeline) void {
        // Signal shutdown and wake the worker.
        self.job_mtx.lockUncancelable(self.io);
        self.shutdown.store(true, .release);
        self.job_cv.signal(self.io);
        self.job_mtx.unlock(self.io);

        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }

        // Drop any unprocessed jobs: free their owned Chunk snapshots.
        for (self.jobs.items) |*job| freeJob(job);
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
        self.job_mtx.lockUncancelable(self.io);
        defer self.job_mtx.unlock(self.io);

        const key = ChunkKey{ .cx = job.cx, .cz = job.cz };
        if (self.in_flight.contains(key)) return false;
        if (self.in_flight.count() >= ASYNC_MAX_IN_FLIGHT) return false;

        try self.jobs.append(self.allocator, job);
        try self.in_flight.put(key, {});
        self.job_cv.signal(self.io);
        return true;
    }

    pub fn isInFlight(self: *Pipeline, cx: i32, cz: i32) bool {
        self.job_mtx.lockUncancelable(self.io);
        defer self.job_mtx.unlock(self.io);
        return self.in_flight.contains(.{ .cx = cx, .cz = cz });
    }

    pub fn inFlightCount(self: *Pipeline) usize {
        self.job_mtx.lockUncancelable(self.io);
        defer self.job_mtx.unlock(self.io);
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
        self.result_mtx.lockUncancelable(self.io);
        const taken = self.results;
        self.results = .empty;
        self.result_mtx.unlock(self.io);
        defer {
            var mut = taken;
            mut.deinit(self.allocator);
        }

        // Drop from in_flight (requires job lock).
        {
            self.job_mtx.lockUncancelable(self.io);
            defer self.job_mtx.unlock(self.io);
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
/// A deep copy of `src`: the packed block data too, so the copy shares no
/// memory with the live chunk. (A struct copy shares `blocks.data`, which
/// the main thread frees when the palette grows or the chunk is evicted.)
pub fn cloneChunk(src: *const Chunk) !*Chunk {
    const a = std.heap.c_allocator;
    const ch = try a.create(Chunk);
    errdefer a.destroy(ch);
    ch.* = src.*;
    ch.allocator = a;
    ch.blocks.data = if (src.blocks.data.len > 0) try a.dupe(u64, src.blocks.data) else &.{};
    return ch;
}

/// Free a Chunk previously returned by `cloneChunk`.
pub fn freeChunk(ch: *Chunk) void {
    ch.deinit();
    std.heap.c_allocator.destroy(ch);
}

/// Free the struct of a c_allocator Chunk whose value was copied out
/// (`dst = ch.*`): the copy owns the block data now, so it is not freed.
pub fn freeMovedChunk(ch: *Chunk) void {
    std.heap.c_allocator.destroy(ch);
}

/// Free the job's borders. The center is freed by its owner (see processJob).
fn freeJobBorders(job: *Job) void {
    for (&job.borders) |*slot| {
        if (slot.*) |b| {
            b.free();
            slot.* = null;
        }
    }
}

/// Free everything a job owns: its center and its borders.
pub fn freeJob(job: *Job) void {
    if (job.center) |c| freeChunk(c);
    job.center = null;
    freeJobBorders(job);
}

/// Bytes a job copied from the world: the center copy and the borders.
pub fn jobBytes(job: *const Job) usize {
    var n: usize = 0;
    if (job.center) |c| n += @sizeOf(Chunk) + c.blocks.data.len * @sizeOf(u64);
    for (job.borders) |slot| {
        if (slot) |b| n += b.bytes();
    }
    return n;
}

fn freeResult(r: *Result) void {
    if (r.chunk) |ch| freeChunk(ch);
    std.heap.c_allocator.free(r.vertices);
    std.heap.c_allocator.free(r.indices);
    std.heap.c_allocator.free(r.quad_block);
    std.heap.c_allocator.free(r.quad_highlight);
}

// ─── Worker thread ──────────────────────────────────────────────────────────

fn workerMain(pipeline: *Pipeline) void {
    while (true) {
        // Pop a job under the job lock.
        pipeline.job_mtx.lockUncancelable(pipeline.io);
        while (pipeline.jobs.items.len == 0 and !pipeline.shutdown.load(.acquire)) {
            pipeline.job_cv.waitUncancelable(pipeline.io, &pipeline.job_mtx);
        }
        if (pipeline.shutdown.load(.acquire) and pipeline.jobs.items.len == 0) {
            pipeline.job_mtx.unlock(pipeline.io);
            return;
        }
        var job = pipeline.jobs.orderedRemove(0);
        pipeline.job_mtx.unlock(pipeline.io);

        processJob(pipeline, &job) catch |err| {
            std.log.err("[ASYNC-WORKER] job ({},{}) failed: {}", .{ job.cx, job.cz, err });
            freeJob(&job);
            // Even on failure we must release the in_flight slot so the
            // main thread can retry or move on. Easiest path: push a
            // fake empty result that main will install as an empty mesh.
            // Rare and non-fatal.
            pushEmptyResult(pipeline, job.cx, job.cz) catch {};
        };
    }
}

fn processJob(pipeline: *Pipeline, job: *Job) !void {
    const t0 = clock.nowNs();

    // Resolve the target chunk. For gen+mesh jobs (center slot == null),
    // allocate a fresh Chunk and run the worldgen + skylight pipeline.
    // For mesh-only jobs, take ownership of the caller-provided snapshot.
    //
    // After this block, the worker exclusively owns `target_ptr` and must
    // free it on any error path. On the success path, ownership is either
    // transferred to `result.chunk` (gen+mesh) or released inline (mesh-only).
    var target_owned_gen: bool = false;
    var target_ptr: *Chunk = undefined;
    if (job.center) |existing| {
        target_ptr = existing;
        // The worker now owns the center: clear it so freeJob does not
        // free it a second time.
        job.center = null;
    } else {
        target_ptr = try std.heap.c_allocator.create(Chunk);
        target_ptr.* = Chunk.init(std.heap.c_allocator);
        try target_ptr.generateTerrain(job.cx, job.cz, job.gen_config);
        target_owned_gen = true;
    }
    var target_consumed: bool = false;
    errdefer if (!target_consumed) freeChunk(target_ptr);

    const getter_impl = SnapshotGetter{
        .cx = job.cx,
        .cz = job.cz,
        .center = target_ptr,
        .borders = &job.borders,
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
    freeJobBorders(job);

    const t_ns = clock.nowNs() - t0;
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
            freeChunk(target_ptr);
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

    pipeline.result_mtx.lockUncancelable(pipeline.io);
    defer pipeline.result_mtx.unlock(pipeline.io);
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
    pipeline.result_mtx.lockUncancelable(pipeline.io);
    defer pipeline.result_mtx.unlock(pipeline.io);
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

/// Test getter over a full 3×3 grid of chunks (no borders): the reference
/// for the border test. Same missing-chunk values as SnapshotGetter.
const FullGridGetter = struct {
    cx: i32,
    cz: i32,
    chunks: *const [9]*Chunk,

    fn at(self: *const FullGridGetter, x: i32, z: i32) ?struct { ch: *const Chunk, lx: i32, lz: i32 } {
        const tcx = @divFloor(x, CHUNK_W);
        const tcz = @divFloor(z, CHUNK_W);
        const dcx = tcx - self.cx;
        const dcz = tcz - self.cz;
        if (dcx < -1 or dcx > 1 or dcz < -1 or dcz > 1) return null;
        return .{ .ch = self.chunks[snapIndex(dcx, dcz)], .lx = x - tcx * CHUNK_W, .lz = z - tcz * CHUNK_W };
    }
    fn block(ctx: *const anyopaque, x: i32, y: i32, z: i32) BlockType {
        const self: *const FullGridGetter = @ptrCast(@alignCast(ctx));
        if (y < 0 or y >= CHUNK_H) return .air;
        const a = self.at(x, z) orelse return .air;
        return a.ch.getBlock(a.lx, y, a.lz);
    }
    fn sky(ctx: *const anyopaque, x: i32, y: i32, z: i32) u8 {
        const self: *const FullGridGetter = @ptrCast(@alignCast(ctx));
        if (y >= CHUNK_H) return MAX_SKYLIGHT;
        if (y < 0) return 0;
        const a = self.at(x, z) orelse return 0;
        return a.ch.getSkylight(a.lx, y, a.lz);
    }
    fn blockLight(ctx: *const anyopaque, x: i32, y: i32, z: i32) u8 {
        const self: *const FullGridGetter = @ptrCast(@alignCast(ctx));
        if (y < 0 or y >= CHUNK_H) return 0;
        const a = self.at(x, z) orelse return 0;
        return a.ch.getBlockLight(a.lx, y, a.lz);
    }
    fn getter(self: *const FullGridGetter) BlockGetter {
        return .{ .ctx = self, .getFn = block, .getSkylightFn = sky, .getBlockLightFn = blockLight };
    }
};

test "meshing through borders gives the same mesh as through full chunks" {
    const a = std.heap.c_allocator;
    const cx: i32 = 3;
    const cz: i32 = -2;
    const config = world_gen.presetConfig(.hilly);
    var grid: [9]*Chunk = undefined;
    for (0..9) |slot| {
        const dcx: i32 = @as(i32, @intCast(slot % 3)) - 1;
        const dcz: i32 = @as(i32, @intCast(slot / 3)) - 1;
        grid[slot] = try a.create(Chunk);
        grid[slot].* = Chunk.init(a);
        try grid[slot].generateTerrain(cx + dcx, cz + dcz, config);
    }
    defer for (grid) |ch| freeChunk(ch);
    // An overhang and a glowstone in the +X neighbour, next to the shared
    // edge, so AO and both light channels cross the border.
    const east = grid[snapIndex(1, 0)];
    var y: i32 = 90;
    while (y < 93) : (y += 1) {
        var z: i32 = 4;
        while (z < 9) : (z += 1) try east.setBlock(0, y, z, .stone);
    }
    try east.setBlock(1, 85, 6, .glowstone);
    for (grid) |ch| {
        ch.computeSkylight();
        ch.computeBlockLight();
    }

    var borders: [9]?*Border = @splat(null);
    defer for (borders) |b| if (b) |bb| bb.free();
    for (0..9) |slot| {
        if (slot == CENTER_SLOT) continue;
        borders[slot] = try Border.fromChunk(grid[slot], @as(i32, @intCast(slot % 3)) - 1, @as(i32, @intCast(slot / 3)) - 1);
    }
    const center = grid[CENTER_SLOT];
    const via_borders = SnapshotGetter{ .cx = cx, .cz = cz, .center = center, .borders = &borders };
    const via_chunks = FullGridGetter{ .cx = cx, .cz = cz, .chunks = &grid };

    for ([_]mesher_mod.MeshingMode{ .naive, .greedy }) |mode| {
        for ([_]gpu_mod.AOStrategy{ .classic, .moore, .propagated }) |ao| {
            var want = mesher_mod.Mesh.init(a);
            defer want.deinit();
            var got = mesher_mod.Mesh.init(a);
            defer got.deinit();
            try mesher_mod.generateMeshForMode(center, &want, cx * CHUNK_W, cz * CHUNK_W, via_chunks.getter(), ao, .skylight, mode);
            try mesher_mod.generateMeshForMode(center, &got, cx * CHUNK_W, cz * CHUNK_W, via_borders.asBlockGetter(), ao, .skylight, mode);
            try std.testing.expect(want.vertices.items.len > 0);
            try std.testing.expectEqualSlices(VoxelVertex, want.vertices.items, got.vertices.items);
            try std.testing.expectEqualSlices(u32, want.indices.items, got.indices.items);
        }
    }
}

test "cloneChunk shares no block data with the source" {
    const a = std.heap.c_allocator;
    var src = Chunk.init(a);
    defer src.deinit();
    try src.setBlock(1, 2, 3, .stone);
    const copy = try cloneChunk(&src);
    defer freeChunk(copy);
    try std.testing.expect(copy.blocks.data.ptr != src.blocks.data.ptr);
    try src.setBlock(1, 2, 3, .dirt);
    try std.testing.expectEqual(BlockType.stone, copy.getBlock(1, 2, 3));
}
