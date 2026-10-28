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
//! flight back to the scheduler and returns error.NoWorkers. The game then
//! starts the Inline executor (the fallback).
//!
//! Main does not copy mesh bytes into its wasm memory (C5). For each result,
//! main copies only the first protocol.PAYLOAD_OFFSET bytes (`takeHead`):
//! the header and the fixed part of the Result. JS keeps the whole message
//! (the transferred ArrayBuffer) under a handle. A mesh result goes to the
//! scheduler as that handle (mesh_bytes.MeshBytes.held). The GPU upload in
//! The game tells JS to write the quads to the GPU from the ArrayBuffer
//! (gpu.writeBufferHeld), then releases the handle. Only a generate result
//! with blocks (C6) and an Error copy their payload into the wasm memory.
//!
//! Native tests (exec_test.zig) run this file with a Transport of
//! in-process WorkerWorlds. The Bun tests (backends/wasm/worker-pool.test.ts)
//! run it with real Web Workers.
const std = @import("std");
const stages = @import("stages.zig");
const protocol = @import("protocol.zig");
const scheduler_mod = @import("scheduler.zig");
const exec_inline = @import("exec_inline.zig");
const world_mod = @import("../world.zig");
const content = @import("../content.zig");
const mesh_bytes = @import("mesh_bytes.zig");
const jobs = @import("sw_jobs");

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

/// The link from main to the worker pool (sw_jobs). Each message is
/// protocol bytes. The transport copies the bytes that main sends: the
/// caller keeps them. The transport holds each result that main takes,
/// until main releases it (C5).
pub const Transport = jobs.Transport;

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
    /// The bytes of the results that came into the wasm memory: the heads,
    /// and the other payloads (blocks, Error text). A mesh payload never
    /// comes in (C5). The Bun tests check these counters.
    head_bytes: u64 = 0,
    payload_bytes: u64 = 0,
    /// Mesh results that stayed in JS.
    held_meshes: u64 = 0,
    /// The jobs that each worker holds now (depthFor).
    depth: usize = JOBS_PER_WORKER,
    /// The clock at the start of the last frame phase, and the mean time of
    /// a job (an exponential mean, in ns).
    last_frame_ns: u64 = 0,
    mean_job_ns: u64 = 0,

    /// Send the Hello for the world `config` to each worker. The JS pool
    /// checks each Hello reply (C9). Returns error.NoWorkers when no worker
    /// runs.
    pub fn init(allocator: std.mem.Allocator, transport: Transport, config: content.GenConfig, cache_limit: u64) Error!Web {
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

    /// Take the next result from the transport and install it. `len` is
    /// its length. Main copies only the head of a mesh result (C5). Returns
    /// null when the reply is not for a job in flight, or when the job
    /// failed and went back to the scheduler.
    fn installNext(self: *Web, sched: *Scheduler, world: *World, len: usize) !?Installed {
        var head: [protocol.PAYLOAD_OFFSET]u8 = undefined;
        const n = @min(len, head.len);
        const handle = self.transport.takeHead(head[0..n]);
        var held = true;
        defer if (held) self.transport.release(handle);
        self.head_bytes += n;
        if (n < protocol.HEADER_LEN) {
            self.bad_replies += 1;
            return null;
        }
        const id = std.mem.readInt(u32, head[12..16], .little);
        const kv = self.jobs.fetchRemove(id) orelse {
            std.log.err("[PIPE] a worker reply has an unknown job id {}", .{id});
            self.bad_replies += 1;
            return null;
        };
        const job = kv.value;
        self.in_flight[job.slot] -|= 1;
        self.traffic.addResult(job.started.job.stage, len);
        const result = self.resultOf(world, job.started, head[0..n], len, handle, &held) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                sched.abandon(job.started);
                return null;
            },
        };
        var r = result;
        const outcome = try sched.install(world, &r);
        return .{ .stage = job.started.job.stage, .outcome = outcome, .job_ns = r.job_ns };
    }

    /// The scheduler Result of a held reply. A mesh Result keeps the handle
    /// as its quad bytes and sets `held.*` to false: the scheduler owns the
    /// handle then. Any other reply comes into the wasm memory as a whole.
    fn resultOf(self: *Web, world: *World, st: Started, head: []const u8, len: usize, handle: u32, held: *bool) !scheduler_mod.Result {
        const maybe = protocol.decodeResultHead(head, len) catch return error.BadReply;
        if (maybe) |info| {
            if (info.head.stage == .mesh) {
                try exec_inline.checkJob(st, info.head);
                held.* = false;
                self.held_meshes += 1;
                return exec_inline.meshResult(st, info, .{ .held = .{ .handle = handle, .len = len, .store = self.transport.store() } });
            }
        }
        // Generate (with the blocks for C6), light and Error replies.
        const bytes = try self.allocator.alloc(u8, len);
        errdefer self.allocator.free(bytes);
        @memcpy(bytes[0..head.len], head);
        if (len > head.len) self.transport.read(handle, head.len, bytes[head.len..]);
        self.payload_bytes += len - head.len;
        return exec_inline.resultOf(world.allocator, st, bytes, self.allocator);
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
            const t0 = clock();
            const done = try self.installNext(sched, world, len);
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
            const msg = try protocol.encodeJob(self.allocator, id, started.messageFor(sched));
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

/// The transport of the web build: the JS worker pool (sw_jobs). Only
/// app.wasm uses it.
pub fn webTransport() Transport {
    return jobs.webTransport();
}
