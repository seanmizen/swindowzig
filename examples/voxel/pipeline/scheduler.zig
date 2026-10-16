//! The chunk scheduler: one chunk pipeline for every platform (C1).
//!
//! The scheduler compares the desired state (C8) with the chunks of the
//! World, and makes a queue of the jobs that can start now. An executor runs
//! the jobs: exec_inline.zig runs them on the main thread within a frame
//! budget. The platforms differ only in the executor (P5).
//!
//! Desired state, around the player chunk, for render distance R (C8):
//!
//!   mesh    each chunk with dx² + dz² <= R².
//!   light   each chunk next to (or at) a chunk that needs a mesh.
//!   blocks  each chunk next to (or at) a chunk that needs light, and the
//!           simulation radius: the player chunk and the ring around it (C6).
//!
//! Each region is a disc whose axes are 1 or 2 chunks longer (see `Region`).
//! A result stays until its chunk is out of the same region for R + 1. The
//! band between R and R + 1 is the hysteresis: a chunk at the edge does not
//! load and unload again when the player moves a little.
//!
//! Jobs, in priority order (C8):
//!
//!   1. the simulation radius,
//!   2. results that an edit made stale (remeshes after edits),
//!   3. chunks in the view frustum, nearest first,
//!   4. all other chunks, nearest first.
//!
//! Versions (C3): a job records the versions of its inputs when it starts.
//! `install` installs the result only when those versions are still current.
//! Otherwise it discards the result, and the next plan queues the job again.
//!
//! Install only in the frame phase, never in a tick (C7). The one exception
//! is `ensureSimRadius` (C6): a tick that needs the blocks of a missing
//! simulation-radius chunk generates them inline. Generation is a pure
//! function, so the result does not depend on timing (P4).
//!
//! Workers own the world (C4 option b). Main keeps the state of each chunk:
//! its versions, and whether it has light and a mesh. Main keeps the blocks
//! only for the prefetch radius (C6), and no light. A light result gives a
//! hash of the light, and a mesh result gives the quads. An edit goes to
//! the edit log of the World and to `outbox`. The executor sends each edit
//! to each worker before the jobs that start after it.
const std = @import("std");
const stages = @import("stages.zig");
const protocol = @import("protocol.zig");
const chunk_mod = @import("../chunk.zig");
const world_mod = @import("../world.zig");

const Version = stages.Version;
const Inputs = stages.Inputs;
pub const Stage = stages.Stage;
const World = world_mod.World;
const LoadedChunk = world_mod.LoadedChunk;
const ChunkKey = world_mod.ChunkKey;
const CHUNK_W = chunk_mod.CHUNK_W;

/// The simulation radius in chunks (C6): the player chunk and its ring.
pub const SIM_RADIUS: i32 = 1;

/// Main keeps the blocks of the chunks in this square around the player
/// chunk (C6). The workers send them with the generate results, so the
/// simulation radius has its blocks before the player gets there.
pub const PREFETCH_RADIUS: i32 = 2;

pub const STAGES = std.enums.values(Stage).len;

// ---------------------------------------------------------------------------
// Regions (C8)
// ---------------------------------------------------------------------------

/// The regions of the desired state, as pure functions of the offset
/// (dx, dz) from the player chunk and a radius.
pub const Region = struct {
    /// |d| less `slack`, not less than 0.
    fn shrink(d: i32, slack: i32) i32 {
        const a = if (d < 0) -d else d;
        return @max(a - slack, 0);
    }

    /// True when some chunk within `slack` chunks (on each axis) of (dx, dz)
    /// is in the disc of radius r.
    fn near(dx: i32, dz: i32, slack: i32, r: i32) bool {
        const x = shrink(dx, slack);
        const z = shrink(dz, slack);
        return x * x + z * z <= r * r;
    }

    pub fn sim(dx: i32, dz: i32) bool {
        return shrink(dx, SIM_RADIUS) == 0 and shrink(dz, SIM_RADIUS) == 0;
    }

    /// Main needs the blocks of the chunk (C6). `extra` makes the square
    /// larger, for the hysteresis of eviction.
    pub fn prefetch(dx: i32, dz: i32, extra: i32) bool {
        return shrink(dx, PREFETCH_RADIUS + extra) == 0 and shrink(dz, PREFETCH_RADIUS + extra) == 0;
    }

    /// The chunk needs a mesh at radius r.
    pub fn mesh(dx: i32, dz: i32, r: i32) bool {
        return near(dx, dz, 0, r);
    }

    /// The chunk needs light at radius r: a chunk next to it needs a mesh.
    pub fn light(dx: i32, dz: i32, r: i32) bool {
        return near(dx, dz, 1, r);
    }

    /// The chunk needs blocks at radius r: a chunk next to it needs light,
    /// or the simulation reads it.
    pub fn blocks(dx: i32, dz: i32, r: i32) bool {
        return near(dx, dz, 2, r) or sim(dx, dz);
    }
};

// ---------------------------------------------------------------------------
// Jobs and results
// ---------------------------------------------------------------------------

/// The priority class of a job (C8). A lower value runs first.
pub const Class = enum(u8) { sim, edit, view, other };

pub const Job = struct {
    stage: Stage,
    cx: i32,
    cz: i32,
    class: Class,
    /// Squared distance in chunks from the player chunk.
    dist_sq: i32,
    /// Generate: main needs the blocks (the prefetch radius, C6). A chunk
    /// in the World without blocks gets them from a generate job too.
    want_blocks: bool = false,

    fn lessThan(_: void, a: Job, b: Job) bool {
        if (a.class != b.class) return @backingInt(a.class) < @backingInt(b.class);
        if (a.dist_sq != b.dist_sq) return a.dist_sq < b.dist_sq;
        if (a.cz != b.cz) return a.cz < b.cz;
        if (a.cx != b.cx) return a.cx < b.cx;
        return @backingInt(a.stage) < @backingInt(b.stage);
    }
};

/// A started job: the job and the versions of its inputs at the start.
pub const Started = struct {
    job: Job,
    inputs: Inputs,
    /// The mesh options at the start (mesh jobs).
    options: u32,

    /// The protocol message of the job (protocol.zig).
    pub fn message(self: Started, ao: stages.AOStrategy, lighting: stages.LightingMode) protocol.Job {
        return .{
            .stage = self.job.stage,
            .cx = self.job.cx,
            .cz = self.job.cz,
            .ao = ao,
            .lighting = lighting,
            .want_blocks = self.job.want_blocks,
            .blocks = self.inputs.blocks,
            .light = self.inputs.light,
        };
    }
};

/// The output of a stage, from a worker. The caller of `install` gives it
/// to the scheduler.
pub const Output = union(Stage) {
    generate: struct {
        /// The block version of the chunk in the worker.
        block_ver: Version,
        /// The blocks, when the job wanted them (C6).
        blocks: ?chunk_mod.PalettedBlocks,
    },
    /// Main keeps no light (C4). The hash tells if the light changed (C3).
    light: struct { hash: u64 },
    mesh: stages.MeshResult,

    pub fn deinit(self: *Output, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .generate => |*g| if (g.blocks) |*b| b.deinit(allocator),
            .light => {},
            .mesh => |*m| m.deinit(allocator),
        }
    }
};

/// The key of a job in flight. The scheduler does not start a second job
/// for the same stage and chunk until the first result comes back.
const JobKey = struct { stage: Stage, cx: i32, cz: i32 };

pub const Result = struct {
    started: Started,
    output: Output,
    /// The time the job ran, in ns, for the counters (C12).
    job_ns: u64 = 0,
};

/// A test of the view frustum for priority class 3. Main gives one each
/// frame. With no view, no chunk is in view.
pub const View = struct {
    ctx: *const anyopaque,
    visibleFn: *const fn (ctx: *const anyopaque, cx: i32, cz: i32) bool,

    fn visible(self: View, cx: i32, cz: i32) bool {
        return self.visibleFn(self.ctx, cx, cz);
    }
};

// ---------------------------------------------------------------------------
// Counters (C12)
// ---------------------------------------------------------------------------

/// The last 64 samples of a time, in ns.
pub const Samples = struct {
    buf: [64]u64 = @splat(0),
    len: usize = 0,
    next: usize = 0,

    pub fn push(self: *Samples, v: u64) void {
        self.buf[self.next] = v;
        self.next = (self.next + 1) % self.buf.len;
        self.len = @min(self.len + 1, self.buf.len);
    }

    /// The p-th percentile (0 to 100) of the samples, or 0 with no samples.
    pub fn percentile(self: *const Samples, p: u32) u64 {
        if (self.len == 0) return 0;
        var tmp: [64]u64 = undefined;
        @memcpy(tmp[0..self.len], self.buf[0..self.len]);
        std.mem.sort(u64, tmp[0..self.len], {}, std.sort.asc(u64));
        const i = (self.len - 1) * p / 100;
        return tmp[i];
    }
};

pub const Stats = struct {
    /// Job time for each stage.
    job_ns: [STAGES]Samples = @splat(.{}),
    /// Install time of each frame with an install (C7).
    install_ns: Samples = .{},
    installed: [STAGES]u64 = @splat(0),
    discarded: [STAGES]u64 = @splat(0),
    /// Chunks that `ensureSimRadius` generated in a tick (C6).
    sim_generated: u64 = 0,
    /// Jobs in the last frame with jobs.
    last_frame_jobs: usize = 0,
    plans: u64 = 0,
};

// ---------------------------------------------------------------------------
// Scheduler
// ---------------------------------------------------------------------------

pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    render_distance: i32,
    ao: stages.AOStrategy,
    lighting: stages.LightingMode,
    /// The mesh options. It changes with `ao` or `lighting`, and a mesh with
    /// other options is stale.
    options: u32 = 1,
    /// The player chunk.
    center_cx: i32 = 0,
    center_cz: i32 = 0,
    view: ?View = null,
    /// The jobs that can start, in priority order, from the last plan.
    queue: std.ArrayList(Job) = .empty,
    /// The next job in `queue`.
    head: usize = 0,
    /// True when the desired state or the World changed after the last plan.
    dirty: bool = true,
    /// Jobs that started and are not installed or discarded.
    in_flight: usize = 0,
    /// The jobs in flight.
    started: std.AutoHashMapUnmanaged(JobKey, void) = .empty,
    /// The edits that the executor did not send yet, in order (C4).
    outbox: std.ArrayList(protocol.Edit) = .empty,
    /// Chunks whose mesh the scheduler removed. Main frees their GPU
    /// buffers and clears the list.
    evicted: std.ArrayList(ChunkKey) = .empty,
    stats: Stats = .{},
    /// Plan scratch.
    cells: std.ArrayList(Cell) = .empty,
    remove: std.ArrayList(ChunkKey) = .empty,

    pub fn init(allocator: std.mem.Allocator, render_distance: i32, ao: stages.AOStrategy, lighting: stages.LightingMode) Scheduler {
        return .{ .allocator = allocator, .render_distance = render_distance, .ao = ao, .lighting = lighting };
    }

    pub fn deinit(self: *Scheduler) void {
        self.queue.deinit(self.allocator);
        self.evicted.deinit(self.allocator);
        self.cells.deinit(self.allocator);
        self.remove.deinit(self.allocator);
        self.started.deinit(self.allocator);
        self.outbox.deinit(self.allocator);
    }

    // -- Desired state ------------------------------------------------------

    /// Set the player chunk.
    pub fn setCenter(self: *Scheduler, cx: i32, cz: i32) void {
        if (cx == self.center_cx and cz == self.center_cz) return;
        self.center_cx = cx;
        self.center_cz = cz;
        self.dirty = true;
    }

    /// Set the render distance. It works at runtime: the next plan loads
    /// and evicts chunks for the new value (C8).
    pub fn setRenderDistance(self: *Scheduler, world: *World, r: i32) void {
        std.debug.assert(r >= 1);
        world.render_distance = r;
        if (r == self.render_distance) return;
        self.render_distance = r;
        self.dirty = true;
    }

    /// Set the AO and lighting modes of the mesher. Each mesh becomes stale.
    pub fn setMeshOptions(self: *Scheduler, ao: stages.AOStrategy, lighting: stages.LightingMode) void {
        if (ao == self.ao and lighting == self.lighting) return;
        self.ao = ao;
        self.lighting = lighting;
        self.options += 1;
        self.dirty = true;
    }

    // -- State queries ------------------------------------------------------

    /// The current versions of the inputs of `stage` for chunk (cx, cz), or
    /// null when an input is missing: a block chunk for light, a lit chunk
    /// for mesh.
    pub fn inputsNow(world: *const World, stage: Stage, cx: i32, cz: i32) ?Inputs {
        var in: Inputs = .{ .stage = stage, .cx = cx, .cz = cz };
        if (stage == .generate) return in;
        for (0..stages.SLOTS) |s| {
            const dcx, const dcz = stages.offsetOf(s);
            const lc = world.get(cx + dcx, cz + dcz) orelse return null;
            in.blocks[s] = lc.block_ver;
            if (stage == .mesh) {
                if (lc.light_inputs == null) return null;
                in.light[s] = lc.light_ver;
            }
        }
        return in;
    }

    /// True when the light of `lc` is the light of its blocks now.
    pub fn lightCurrent(world: *const World, lc: *const LoadedChunk) bool {
        const have = lc.light_inputs orelse return false;
        const now = inputsNow(world, .light, lc.cx, lc.cz) orelse return false;
        return have.isCurrent(now);
    }

    /// True when the mesh of `lc` is the mesh of its blocks and light now.
    pub fn meshCurrent(self: *const Scheduler, world: *const World, lc: *const LoadedChunk) bool {
        const have = lc.mesh_inputs orelse return false;
        if (lc.mesh_options != self.options) return false;
        const now = inputsNow(world, .mesh, lc.cx, lc.cz) orelse return false;
        return have.isCurrent(now);
    }

    /// True when the job can start now: its inputs exist, and its chunk
    /// does not have a current result for the stage.
    pub fn canStart(self: *const Scheduler, world: *const World, job: Job) bool {
        const lc = world.get(job.cx, job.cz);
        return switch (job.stage) {
            .generate => lc == null or (job.want_blocks and !lc.?.has_blocks),
            .light => lc != null and inputsNow(world, .light, job.cx, job.cz) != null and !lightCurrent(world, lc.?),
            .mesh => lc != null and allLightsCurrent(world, job.cx, job.cz) and !self.meshCurrent(world, lc.?),
        };
    }

    fn allLightsCurrent(world: *const World, cx: i32, cz: i32) bool {
        for (0..stages.SLOTS) |s| {
            const dcx, const dcz = stages.offsetOf(s);
            const n = world.get(cx + dcx, cz + dcz) orelse return false;
            if (!lightCurrent(world, n)) return false;
        }
        return true;
    }

    /// True when the scheduler has no work: the World has the desired
    /// state, no job runs, and each edit went to the workers. A change of
    /// the player chunk, the render distance, the mesh options or the
    /// blocks makes it false until the next plan.
    pub fn isIdle(self: *const Scheduler) bool {
        return !self.dirty and self.head >= self.queue.items.len and self.in_flight == 0 and self.outbox.items.len == 0;
    }

    /// The "ready" check of the loading screen. True when:
    ///
    ///   - each chunk of the simulation radius has blocks (C6), and
    ///   - each chunk with dx² + dz² <= r² (r = min(radius, R)) has a
    ///     current mesh.
    ///
    /// The rest of the desired state continues to load after it.
    pub fn isReady(self: *const Scheduler, world: *const World, radius: i32) bool {
        var dz: i32 = -SIM_RADIUS;
        while (dz <= SIM_RADIUS) : (dz += 1) {
            var dx: i32 = -SIM_RADIUS;
            while (dx <= SIM_RADIUS) : (dx += 1) {
                const lc = world.get(self.center_cx + dx, self.center_cz + dz) orelse return false;
                if (!lc.has_blocks) return false;
            }
        }
        const r = @min(radius, self.render_distance);
        dz = -r;
        while (dz <= r) : (dz += 1) {
            var dx: i32 = -r;
            while (dx <= r) : (dx += 1) {
                if (!Region.mesh(dx, dz, r)) continue;
                const lc = world.get(self.center_cx + dx, self.center_cz + dz) orelse return false;
                if (!self.meshCurrent(world, lc)) return false;
            }
        }
        return true;
    }

    /// The jobs in the queue that did not start, for each stage (C12).
    pub fn queueDepth(self: *const Scheduler) [STAGES]usize {
        var out: [STAGES]usize = @splat(0);
        for (self.queue.items[@min(self.head, self.queue.items.len)..]) |j| out[@backingInt(j.stage)] += 1;
        return out;
    }

    // -- Edits and the simulation radius -------------------------------------

    /// Set a block (a dig or a place). The block version of the chunk goes
    /// up by 1, so each result that read the old block becomes stale (C3).
    /// No light or mesh runs here: the scheduler queues them as class 2.
    /// The edit goes to the edit log of the World and to `outbox` (C4).
    /// Returns false when main has no blocks for the chunk or y is out of
    /// the world.
    ///
    /// A neighbour result that cannot read the cell stays current: the
    /// light of a neighbour reads stages.MARGIN cells into this chunk, and
    /// a mesh reads stages.BORDER cells. For such a result, the recorded
    /// version moves to the new version.
    pub fn editBlock(self: *Scheduler, world: *World, wx: i32, wy: i32, wz: i32, block: chunk_mod.BlockType) !bool {
        if (wy < 0 or wy >= chunk_mod.CHUNK_H) return false;
        const lc = world.getChunkAtBlock(wx, wz) orelse return false;
        if (!lc.has_blocks) return false;
        const lx = wx - lc.worldX();
        const lz = wz - lc.worldZ();
        if (lc.chunk.getBlock(lx, wy, lz) == block) return true;
        const edit: protocol.Edit = .{
            .cx = lc.cx,
            .cz = lc.cz,
            .version = lc.block_ver + 1,
            .x = @intCast(lx),
            .y = @intCast(wy),
            .z = @intCast(lz),
            .block = block,
        };
        try self.outbox.ensureUnusedCapacity(self.allocator, 1);
        try world.logEdit(edit);
        try lc.chunk.setBlock(lx, wy, lz, block);
        self.outbox.appendAssumeCapacity(edit);
        const old = lc.block_ver;
        lc.block_ver += 1;
        for (0..stages.SLOTS) |s| {
            if (s == stages.CENTER) continue;
            const dcx, const dcz = stages.offsetOf(s);
            const n = world.get(lc.cx + dcx, lc.cz + dcz) orelse continue;
            // The slot of the edited chunk, seen from n.
            const t = stages.slot(-dcx, -dcz);
            if (n.light_inputs) |*in| {
                if (!reads(n, wx, wz, @intCast(stages.MARGIN)) and in.blocks[t] == old) in.blocks[t] = lc.block_ver;
            }
            if (n.mesh_inputs) |*in| {
                if (!reads(n, wx, wz, stages.BORDER) and in.blocks[t] == old) in.blocks[t] = lc.block_ver;
            }
        }
        self.dirty = true;
        return true;
    }

    /// True when a stage of chunk `n` that reads `margin` cells across each
    /// border reads world column (wx, wz).
    fn reads(n: *const LoadedChunk, wx: i32, wz: i32, margin: i32) bool {
        const x0 = n.worldX() - margin;
        const z0 = n.worldZ() - margin;
        const w = CHUNK_W + 2 * margin;
        return wx >= x0 and wx < x0 + w and wz >= z0 and wz < z0 + w;
    }

    /// The edits that the executor must send to each worker, in order.
    /// The executor clears `outbox` after it sends them.
    pub fn pendingEdits(self: *const Scheduler) []const protocol.Edit {
        return self.outbox.items;
    }

    /// C6: give each chunk of the simulation radius around (cx, cz) its
    /// blocks now, with an inline generate and the edits of the edit log.
    /// This is the inline fallback: a tick calls it before the simulation
    /// reads blocks, for example after a teleport. Returns the number of
    /// chunks it generated.
    pub fn ensureSimRadius(self: *Scheduler, world: *World, cx: i32, cz: i32) !usize {
        var n: usize = 0;
        var dz: i32 = -SIM_RADIUS;
        while (dz <= SIM_RADIUS) : (dz += 1) {
            var dx: i32 = -SIM_RADIUS;
            while (dx <= SIM_RADIUS) : (dx += 1) {
                const lc = world.get(cx + dx, cz + dz);
                if (lc != null and lc.?.has_blocks) continue;
                var blocks = try stages.generate(world.allocator, world.gen_config.seed, world.gen_config, cx + dx, cz + dz);
                errdefer blocks.deinit(world.allocator);
                try world.applyEditLog(cx + dx, cz + dz, &blocks);
                if (lc) |l| {
                    world.setBlocks(l, blocks);
                } else {
                    _ = try world.installBlocks(cx + dx, cz + dz, blocks);
                }
                n += 1;
            }
        }
        if (n > 0) {
            self.stats.sim_generated += n;
            self.dirty = true;
        }
        return n;
    }

    // -- Jobs -----------------------------------------------------------------

    /// The next job that can start, or null. Call `plan` first. It skips a
    /// job that is in flight.
    pub fn next(self: *Scheduler, world: *const World) ?Job {
        while (self.head < self.queue.items.len) {
            const job = self.queue.items[self.head];
            self.head += 1;
            if (self.started.contains(keyOf(job))) continue;
            if (self.canStart(world, job)) return job;
        }
        return null;
    }

    fn keyOf(job: Job) JobKey {
        return .{ .stage = job.stage, .cx = job.cx, .cz = job.cz };
    }

    /// Start `job`: record the versions of its inputs.
    pub fn start(self: *Scheduler, world: *const World, job: Job) !Started {
        std.debug.assert(self.canStart(world, job));
        try self.started.put(self.allocator, keyOf(job), {});
        self.in_flight += 1;
        return .{
            .job = job,
            .inputs = inputsNow(world, job.stage, job.cx, job.cz).?,
            .options = self.options,
        };
    }

    /// The executor did not finish a started job (an error, or a worker
    /// stopped). The next plan queues the job again.
    pub fn abandon(self: *Scheduler, st: Started) void {
        self.finish(st);
    }

    fn finish(self: *Scheduler, st: Started) void {
        const removed = self.started.remove(keyOf(st.job));
        std.debug.assert(removed);
        self.in_flight -= 1;
        self.dirty = true;
    }

    pub const Outcome = enum { installed, discarded };

    /// Install `result` when its input versions are current (C3), else
    /// discard it. The scheduler takes the output in both cases. Call it
    /// only in the frame phase (C7).
    pub fn install(self: *Scheduler, world: *World, result: *Result) !Outcome {
        const st = result.started;
        self.finish(st);
        const k = @backingInt(st.job.stage);
        self.stats.job_ns[k].push(result.job_ns);
        const ok = switch (st.job.stage) {
            .generate => blk: {
                const g = result.output.generate;
                // The chunk left the region while the job ran.
                if (!Region.blocks(st.job.cx - self.center_cx, st.job.cz - self.center_cz, self.render_distance + 1)) break :blk false;
                if (world.get(st.job.cx, st.job.cz)) |lc| {
                    // The blocks for the prefetch radius (C6).
                    break :blk !lc.has_blocks and g.blocks != null and g.block_ver == lc.block_ver;
                }
                break :blk g.block_ver == world.editVersion(st.job.cx, st.job.cz);
            },
            else => blk: {
                const now = inputsNow(world, st.job.stage, st.job.cx, st.job.cz) orelse break :blk false;
                if (st.job.stage == .mesh and st.options != self.options) break :blk false;
                break :blk st.inputs.isCurrent(now);
            },
        };
        if (!ok) {
            result.output.deinit(world.allocator);
            self.stats.discarded[k] += 1;
            return .discarded;
        }
        switch (result.output) {
            .generate => |g| {
                if (world.get(st.job.cx, st.job.cz)) |lc| {
                    world.setBlocks(lc, g.blocks.?);
                } else if (g.blocks) |blocks| {
                    const lc = try world.installBlocks(st.job.cx, st.job.cz, blocks);
                    lc.block_ver = g.block_ver;
                } else {
                    _ = try world.installRemote(st.job.cx, st.job.cz, g.block_ver);
                }
            },
            .light => |l| {
                const lc = world.get(st.job.cx, st.job.cz).?;
                // Same content: keep the version, so meshes that read the
                // old light stay current.
                const same = lc.light_inputs != null and lc.light_hash == l.hash;
                if (!same) {
                    lc.light_hash = l.hash;
                    lc.light_ver = world.next_light_version;
                    world.next_light_version += 1;
                }
                lc.light_inputs = st.inputs;
            },
            .mesh => |m| {
                const lc = world.get(st.job.cx, st.job.cz).?;
                const mesh = &lc.mesh;
                mesh.quads.deinit(mesh.allocator);
                mesh.quads = .fromOwnedSlice(m.quads);
                mesh.y_min = m.y_min;
                mesh.y_max = m.y_max;
                mesh.sort_valid = false;
                lc.mesh_inputs = st.inputs;
                lc.mesh_options = st.options;
                lc.upload_pending = true;
            },
        }
        self.stats.installed[k] += 1;
        return .installed;
    }

    // -- Plan -----------------------------------------------------------------

    const Cell = struct {
        lc: ?*LoadedChunk,
        light_ok: bool,
        /// The chunk is in the view frustum.
        visible: bool,
    };

    /// Compare the desired state with the World: evict, then make the
    /// queue of jobs that can start, in priority order. It does nothing
    /// when nothing changed after the last plan.
    pub fn plan(self: *Scheduler, world: *World) !void {
        if (!self.dirty) return;
        self.dirty = false;
        self.stats.plans += 1;
        try self.evict(world);

        self.queue.clearRetainingCapacity();
        self.head = 0;
        const r = self.render_distance;
        // The grid holds the blocks region of R (to R + 2) and two more
        // rings: the view test of a generate job looks 2 chunks out.
        const half = r + 4;
        const side: usize = @intCast(2 * half + 1);
        try self.cells.resize(self.allocator, side * side);
        const cells = self.cells.items;
        for (cells, 0..) |*c, i| {
            const dx, const dz = offsetOfCell(i, side, half);
            c.* = .{
                .lc = world.get(self.center_cx + dx, self.center_cz + dz),
                .light_ok = false,
                .visible = if (self.view) |v| v.visible(self.center_cx + dx, self.center_cz + dz) else false,
            };
        }
        for (cells, 0..) |*c, i| {
            const lc = c.lc orelse continue;
            const dx, const dz = offsetOfCell(i, side, half);
            if (@abs(dx) >= half or @abs(dz) >= half) continue;
            c.light_ok = lightCurrent(world, lc);
        }

        for (cells, 0..) |c, i| {
            const dx, const dz = offsetOfCell(i, side, half);
            if (@abs(dx) >= half or @abs(dz) >= half) continue;
            const cx = self.center_cx + dx;
            const cz = self.center_cz + dz;
            const d2 = dx * dx + dz * dz;
            const sim = Region.sim(dx, dz);
            if (c.lc) |lc| {
                if (Region.mesh(dx, dz, r) and c.light_ok and !self.meshCurrent(world, lc) and
                    self.ring(cells, i, side, .light_ok))
                {
                    const class: Class = if (sim) .sim else if (lc.mesh_inputs != null) .edit else if (inView(cells, i, side, 0)) .view else .other;
                    try self.queue.append(self.allocator, .{ .stage = .mesh, .cx = cx, .cz = cz, .class = class, .dist_sq = d2 });
                } else if (Region.light(dx, dz, r) and !c.light_ok and self.ring(cells, i, side, .blocks)) {
                    const class: Class = if (sim) .sim else if (lc.light_inputs != null) .edit else if (inView(cells, i, side, 1)) .view else .other;
                    try self.queue.append(self.allocator, .{ .stage = .light, .cx = cx, .cz = cz, .class = class, .dist_sq = d2 });
                }
            } else if (Region.blocks(dx, dz, r)) {
                const class: Class = if (sim) .sim else if (inView(cells, i, side, 2)) .view else .other;
                try self.queue.append(self.allocator, .{ .stage = .generate, .cx = cx, .cz = cz, .class = class, .dist_sq = d2, .want_blocks = Region.prefetch(dx, dz, 0) });
            }
            // C6: main gets the blocks of the prefetch radius from a worker.
            if (c.lc) |lc| if (!lc.has_blocks and Region.prefetch(dx, dz, 0)) {
                const class: Class = if (sim) .sim else .view;
                try self.queue.append(self.allocator, .{ .stage = .generate, .cx = cx, .cz = cz, .class = class, .dist_sq = d2, .want_blocks = true });
            };
        }
        std.mem.sort(Job, self.queue.items, {}, Job.lessThan);
    }

    /// True when each cell of the 3×3 around cell `i` has blocks (`.blocks`)
    /// or current light (`.light_ok`).
    fn ring(_: *const Scheduler, cells: []const Cell, i: usize, side: usize, what: enum { blocks, light_ok }) bool {
        const x = i % side;
        const z = i / side;
        for (0..stages.SLOTS) |s| {
            const dcx, const dcz = stages.offsetOf(s);
            const nx: usize = @intCast(@as(i32, @intCast(x)) + dcx);
            const nz: usize = @intCast(@as(i32, @intCast(z)) + dcz);
            const c = cells[nz * side + nx];
            const ok = switch (what) {
                .blocks => c.lc != null,
                .light_ok => c.light_ok,
            };
            if (!ok) return false;
        }
        return true;
    }

    /// True when a chunk within `reach` chunks of cell `i` is in view. A
    /// light job serves the meshes next to it (reach 1), and a generate
    /// job serves the lights next to it (reach 2). The cell is at least
    /// `reach` cells from the edge of the grid.
    fn inView(cells: []const Cell, i: usize, side: usize, reach: usize) bool {
        const x = i % side;
        const z = i / side;
        for (z - reach..z + reach + 1) |nz| for (x - reach..x + reach + 1) |nx| {
            if (cells[nz * side + nx].visible) return true;
        };
        return false;
    }

    fn offsetOfCell(i: usize, side: usize, half: i32) struct { i32, i32 } {
        return .{ @as(i32, @intCast(i % side)) - half, @as(i32, @intCast(i / side)) - half };
    }

    /// Remove the results that are out of the region for R + 1 (the
    /// hysteresis). An edited chunk keeps its place in the World, with its
    /// block version. Main drops the blocks out of the prefetch radius + 1,
    /// because the edit log and the workers have the edits (C4, C14).
    fn evict(self: *Scheduler, world: *World) !void {
        const keep_r = self.render_distance + 1;
        self.remove.clearRetainingCapacity();
        var it = world.chunks.iterator();
        while (it.next()) |e| {
            const lc = e.value_ptr.*;
            const dx = lc.cx - self.center_cx;
            const dz = lc.cz - self.center_cz;
            if (lc.hasMesh() and !Region.mesh(dx, dz, keep_r)) {
                lc.dropMesh();
                try self.evicted.append(self.allocator, e.key_ptr.*);
            }
            if (lc.hasLight() and !Region.light(dx, dz, keep_r)) lc.dropLight();
            if (lc.has_blocks and !Region.prefetch(dx, dz, 1)) lc.dropBlocks();

            if (!Region.blocks(dx, dz, keep_r) and lc.block_ver == 0) try self.remove.append(self.allocator, e.key_ptr.*);
        }
        for (self.remove.items) |k| world.removeChunk(k.cx, k.cz);
    }
};
