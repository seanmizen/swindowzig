//! The WorkerPool executor (C1, C9): chunk jobs in Web Workers.
//!
//! The pool is JS code (backends/wasm/worker-pool.ts). Each Web Worker runs
//! chunks.wasm (pipeline/chunk_worker_main.zig), with its own WorkerWorld.
//! This file is the main side in app.wasm. It has the design of the
//! ThreadPool executor (exec_threads.zig), with a Transport in place of the
//! threads:
//!
//!   - Main sends each edit to each worker, in order (C4).
//!   - Each region of chunks goes to one worker (spatial affinity, C4).
//!   - Each worker holds the jobs of about one frame, and at least
//!     JOBS_PER_WORKER jobs (C8). See `depthFor`.
//!   - The JS pool keeps the results in a queue. Main takes them only in
//!     the frame phase, within the install budget (C7).
//!
//! The JS pool owns the lifecycle of the workers (C9). When a worker stops,
//! the pool starts a new worker, sends it the Hello and all the edits, and
//! sends the jobs of the old worker again. This file does not see it: the
//! results come back with the same job ids. A job that reads an edit that
//! came after it gets an Error (stale_input), and the scheduler queues the
//! job again (C3). When no worker can run, `runFrame` gives each job in
//! flight back to the scheduler and returns error.NoWorkers. main.zig then
//! starts the Inline executor (the fallback).
//!
//! The results go into the main wasm memory, as with the other executors.
//! C5 (main JS writes the mesh bytes to the GPU, and the main wasm never
//! copies them) is a later step.
//!
//! Native tests (exec_test.zig) run this file with a Transport of
//! in-process WorkerWorlds. The Bun tests (backends/wasm/worker-pool.test.ts)
//! run it with real Web Workers.
const std = @import("std");
const builtin = @import("builtin");
const stages = @import("stages.zig");
const protocol = @import("protocol.zig");
const scheduler_mod = @import("scheduler.zig");
const exec_inline = @import("exec_inline.zig");
const world_mod = @import("../world.zig");
const world_gen = @import("../world_gen.zig");

const Scheduler = scheduler_mod.Scheduler;
const Started = scheduler_mod.Started;
const World = world_mod.World;
const FrameReport = exec_inline.FrameReport;
const Clock = exec_inline.Clock;

// The affinity and the job limit of the ThreadPool (C4, C8). Only these
// declarations of exec_threads.zig build into app.wasm: Zig analyses a
// declaration only when the code uses it.
const exec_threads = @import("exec_threads.zig");
pub const JOBS_PER_WORKER = exec_threads.JOBS_PER_WORKER;
pub const ownerOf = exec_threads.ownerOf;
/// The most jobs that a worker holds (`depthFor`).
pub const MAX_DEPTH = 16;

/// The jobs that each worker holds (C8). A Web Worker gets new jobs only
/// in the frame phase of main, one time in each frame (60 Hz: 16.7 ms).
/// With 2 jobs of about 1.3 ms, a worker waits for most of the frame. So a
/// worker holds the jobs of one frame interval, and one more:
/// ceil(frame / job) + 1, from JOBS_PER_WORKER to MAX_DEPTH. A job in the
/// queue of a worker waits for at most about one frame, so a change of the
/// priority (the player moves) still shows in the next frame or the frame
/// after it. docs/chunk-pipeline.md has the measurements.
pub fn depthFor(frame_ns: u64, job_ns: u64) usize {
    if (frame_ns == 0 or job_ns == 0) return JOBS_PER_WORKER;
    const n = std.math.divCeil(u64, frame_ns, job_ns) catch unreachable;
    return @intCast(std.math.clamp(n + 1, JOBS_PER_WORKER, MAX_DEPTH));
}

/// The link from main to the worker pool. Each message is protocol bytes.
/// The transport copies the bytes: the caller keeps them.
pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// The number of worker slots. It does not change.
        slots: *const fn (ptr: *anyopaque) usize,
        /// True when the worker in `slot` runs and can take jobs.
        alive: *const fn (ptr: *anyopaque, slot: usize) bool,
        /// Send a Job to the worker in `slot`. False when the message did
        /// not go.
        post: *const fn (ptr: *anyopaque, slot: usize, msg: []const u8) bool,
        /// Send a Hello or an Edit to each worker. The pool keeps it, for a
        /// worker that starts again.
        broadcast: *const fn (ptr: *anyopaque, msg: []const u8) bool,
        /// The length of the next result in the queue, or 0.
        nextLen: *const fn (ptr: *anyopaque) usize,
        /// Copy the next result into `buf` (its length is `nextLen`), and
        /// remove it from the queue.
        take: *const fn (ptr: *anyopaque, buf: []u8) void,
    };

    pub fn slots(self: Transport) usize {
        return self.vtable.slots(self.ptr);
    }
    pub fn alive(self: Transport, slot: usize) bool {
        return self.vtable.alive(self.ptr, slot);
    }
    pub fn post(self: Transport, slot: usize, msg: []const u8) bool {
        return self.vtable.post(self.ptr, slot, msg);
    }
    pub fn broadcast(self: Transport, msg: []const u8) bool {
        return self.vtable.broadcast(self.ptr, msg);
    }
    pub fn nextLen(self: Transport) usize {
        return self.vtable.nextLen(self.ptr);
    }
    pub fn take(self: Transport, buf: []u8) void {
        self.vtable.take(self.ptr, buf);
    }
};

const InFlight = struct {
    started: Started,
    slot: usize,
};

pub const Error = error{
    /// No worker can run. Use the Inline executor.
    NoWorkers,
    OutOfMemory,
};

pub const Web = struct {
    allocator: std.mem.Allocator,
    transport: Transport,
    /// Jobs sent and not answered, for each slot.
    in_flight: []usize,
    jobs: std.AutoHashMapUnmanaged(u32, InFlight) = .empty,
    next_id: u32 = 1,
    traffic: exec_inline.Traffic = .{},
    /// Results that were not a Result for a job in flight (C12).
    bad_replies: u64 = 0,
    /// The jobs that each worker holds now (depthFor).
    depth: usize = JOBS_PER_WORKER,
    /// The clock at the start of the last frame phase, and the mean time of
    /// a job (an exponential mean, in ns).
    last_frame_ns: u64 = 0,
    mean_job_ns: u64 = 0,

    /// Send the Hello for the world `config` to each worker. The JS pool
    /// checks each Hello reply (C9). Returns error.NoWorkers when no worker
    /// runs.
    pub fn init(allocator: std.mem.Allocator, transport: Transport, config: world_gen.WorldGenConfig, cache_limit: u64) Error!Web {
        const n = transport.slots();
        if (n == 0 or liveCount(transport) == 0) return error.NoWorkers;
        const in_flight = try allocator.alloc(usize, n);
        @memset(in_flight, 0);
        errdefer allocator.free(in_flight);
        const hello = try protocol.encodeHello(allocator, exec_inline.helloOf(config, cache_limit));
        defer allocator.free(hello);
        if (!transport.broadcast(hello)) return error.NoWorkers;
        return .{ .allocator = allocator, .transport = transport, .in_flight = in_flight };
    }

    pub fn deinit(self: *Web) void {
        self.allocator.free(self.in_flight);
        self.jobs.deinit(self.allocator);
    }

    fn liveCount(t: Transport) usize {
        var n: usize = 0;
        for (0..t.slots()) |i| {
            if (t.alive(i)) n += 1;
        }
        return n;
    }

    /// The number of workers that run.
    pub fn workerCount(self: *const Web) usize {
        return liveCount(self.transport);
    }

    /// Give each job in flight back to the scheduler, so that the next plan
    /// queues it again.
    pub fn abandonAll(self: *Web, sched: *Scheduler) void {
        var it = self.jobs.valueIterator();
        while (it.next()) |j| sched.abandon(j.started);
        self.jobs.clearRetainingCapacity();
        @memset(self.in_flight, 0);
    }

    /// Send the pending edits of the scheduler to each worker, in order.
    fn sendEdits(self: *Web, sched: *Scheduler) Error!void {
        for (sched.pendingEdits()) |e| {
            const msg = try protocol.encodeEdit(self.allocator, e);
            defer self.allocator.free(msg);
            if (!self.transport.broadcast(msg)) return error.NoWorkers;
            const n = self.workerCount();
            self.traffic.edits += n;
            self.traffic.edit_bytes += n * msg.len;
        }
        sched.outbox.clearRetainingCapacity();
    }

    const Installed = struct {
        stage: stages.Stage,
        outcome: Scheduler.Outcome,
        job_ns: u64,
    };

    /// Install one reply. Returns null when the reply is not for a job in
    /// flight, or when the job failed and went back to the scheduler.
    fn installReply(self: *Web, sched: *Scheduler, world: *World, bytes: []const u8) !?Installed {
        if (bytes.len < protocol.HEADER_LEN) {
            self.bad_replies += 1;
            return null;
        }
        const id = std.mem.readInt(u32, bytes[12..16], .little);
        const kv = self.jobs.fetchRemove(id) orelse {
            std.log.err("[PIPE] a worker reply has an unknown job id {}", .{id});
            self.bad_replies += 1;
            return null;
        };
        const job = kv.value;
        self.in_flight[job.slot] -|= 1;
        self.traffic.addResult(job.started.job.stage, bytes.len);
        var result = exec_inline.resultOf(world.allocator, job.started, bytes) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                sched.abandon(job.started);
                return null;
            },
        };
        const outcome = try sched.install(world, &result);
        return .{ .stage = job.started.job.stage, .outcome = outcome, .job_ns = result.job_ns };
    }

    /// The frame phase (C7). It installs the results in the queue until
    /// `clock()` reaches `deadline_ns`, with at least one install when a
    /// result waits. Then it plans and sends jobs to the workers that have
    /// room. It never waits for a worker.
    pub fn runFrame(self: *Web, sched: *Scheduler, world: *World, clock: Clock, deadline_ns: u64) !FrameReport {
        var report: FrameReport = .{};
        const t_start = clock();
        if (self.last_frame_ns != 0 and t_start > self.last_frame_ns) {
            self.depth = depthFor(t_start - self.last_frame_ns, self.mean_job_ns);
        }
        self.last_frame_ns = t_start;
        if (self.workerCount() == 0) {
            self.abandonAll(sched);
            return error.NoWorkers;
        }
        try self.sendEdits(sched);
        while (true) {
            const len = self.transport.nextLen();
            if (len == 0) break;
            if (report.jobs > 0 and clock() >= deadline_ns) break;
            const bytes = try self.allocator.alloc(u8, len);
            defer self.allocator.free(bytes);
            self.transport.take(bytes);
            const t0 = clock();
            const done = try self.installReply(sched, world, bytes);
            report.install_ns += clock() - t0;
            const d = done orelse continue;
            const k = @backingInt(d.stage);
            report.count[k] += 1;
            report.job_ns[k] += d.job_ns;
            report.jobs += 1;
            self.mean_job_ns = if (self.mean_job_ns == 0) d.job_ns else (self.mean_job_ns * 7 + d.job_ns) / 8;
            if (d.outcome == .discarded) report.discarded += 1;
        }
        report.sent = try self.dispatch(sched, world);
        report.main_ns = clock() - t_start;
        if (report.jobs > 0) {
            sched.stats.install_ns.push(report.install_ns);
            sched.stats.last_frame_jobs = report.jobs;
        }
        return report;
    }

    /// The slot for `job`: the owner of its region when it runs and has
    /// room. Else a worker with no job, else a worker with room. Null when
    /// no worker can take the job now.
    fn slotFor(self: *const Web, job: scheduler_mod.Job) ?usize {
        const n = self.in_flight.len;
        const owner = ownerOf(job.cx, job.cz, n);
        if (self.transport.alive(owner) and self.in_flight[owner] < self.depth) return owner;
        var room: ?usize = null;
        for (self.in_flight, 0..) |f, i| {
            if (!self.transport.alive(i)) continue;
            if (f == 0) return i;
            if (f < self.depth and room == null and !self.transport.alive(owner)) room = i;
        }
        return room;
    }

    /// Plan, and send the jobs in priority order to the workers that have
    /// room. A job whose worker is full waits for the next plan.
    fn dispatch(self: *Web, sched: *Scheduler, world: *World) !usize {
        try sched.plan(world);
        var room: usize = 0;
        for (self.in_flight, 0..) |f, i| {
            if (self.transport.alive(i)) room += self.depth -| f;
        }
        var skipped = false;
        var sent: usize = 0;
        while (room > 0) {
            const job = sched.next(world) orelse break;
            const slot = self.slotFor(job) orelse {
                skipped = true;
                continue;
            };
            const started = try sched.start(world, job);
            errdefer sched.abandon(started);
            const id = self.next_id;
            self.next_id +%= 1;
            if (self.next_id == 0) self.next_id = 1;
            const msg = try protocol.encodeJob(self.allocator, id, started.message(sched.ao, sched.lighting));
            defer self.allocator.free(msg);
            try self.jobs.put(self.allocator, id, .{ .started = started, .slot = slot });
            if (!self.transport.post(slot, msg)) {
                _ = self.jobs.remove(id);
                sched.abandon(started);
                skipped = true;
                break;
            }
            self.traffic.jobs += 1;
            self.traffic.job_bytes += msg.len;
            self.in_flight[slot] += 1;
            room -= 1;
            sent += 1;
        }
        // The next frame plans again, so a job that waited for its worker
        // goes back in the queue.
        if (skipped) sched.dirty = true;
        return sent;
    }
};

// ---------------------------------------------------------------------------
// The transport of the web build: imports from backends/wasm/worker-pool.ts
// ---------------------------------------------------------------------------

/// The JS imports (module "chunks"). worker-pool.ts has the other side.
/// Without a pool, `jsChunkSlots` returns 0.
const js = struct {
    extern "chunks" fn jsChunkSlots() u32;
    extern "chunks" fn jsChunkAlive(slot: u32) u32;
    extern "chunks" fn jsChunkPost(slot: u32, ptr: [*]const u8, len: u32) u32;
    extern "chunks" fn jsChunkBroadcast(ptr: [*]const u8, len: u32) u32;
    extern "chunks" fn jsChunkNextLen() u32;
    extern "chunks" fn jsChunkTake(ptr: [*]u8, len: u32) void;
};

fn webSlots(_: *anyopaque) usize {
    return js.jsChunkSlots();
}
fn webAlive(_: *anyopaque, slot: usize) bool {
    return js.jsChunkAlive(@intCast(slot)) != 0;
}
fn webPost(_: *anyopaque, slot: usize, msg: []const u8) bool {
    return js.jsChunkPost(@intCast(slot), msg.ptr, @intCast(msg.len)) != 0;
}
fn webBroadcast(_: *anyopaque, msg: []const u8) bool {
    return js.jsChunkBroadcast(msg.ptr, @intCast(msg.len)) != 0;
}
fn webNextLen(_: *anyopaque) usize {
    return js.jsChunkNextLen();
}
fn webTake(_: *anyopaque, buf: []u8) void {
    js.jsChunkTake(buf.ptr, @intCast(buf.len));
}

var web_dummy: u8 = 0;
const web_vtable: Transport.VTable = .{
    .slots = webSlots,
    .alive = webAlive,
    .post = webPost,
    .broadcast = webBroadcast,
    .nextLen = webNextLen,
    .take = webTake,
};

/// The transport of the web build: the JS worker pool. Only app.wasm uses
/// it.
pub fn webTransport() Transport {
    comptime std.debug.assert(builtin.cpu.arch == .wasm32);
    return .{ .ptr = &web_dummy, .vtable = &web_vtable };
}
