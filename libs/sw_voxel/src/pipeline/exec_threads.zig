//! The ThreadPool executor (C1, C9): chunk jobs on native threads.
//!
//! It starts min(CPU count - 1, 4) threads, and at least 1. Each thread has
//! its own WorkerWorld (worker_world.zig). A WorkerWorld holds a copy of the
//! world (the seed and the edit log) and a chunk cache with a memory limit
//! (C4 option b, C14). All messages are protocol bytes (protocol.zig), the
//! same bytes that a Web Worker gets (P6). The threads share no chunk data.
//!
//! Each region of REGION × REGION chunks goes to one worker (spatial
//! affinity, C4). The 3×3 neighbourhood of a job is then mostly in the
//! cache of its worker. When the worker of a region is full, a worker with
//! no job takes the job.
//!
//! Main, in the frame phase (C7):
//!
//!   1. sends each new edit to each worker, in order,
//!   2. installs the results that arrived, within the install budget,
//!   3. plans, and sends jobs. Each worker holds at most JOBS_PER_WORKER
//!      jobs: one runs, one waits (C8).
//!
//! A worker handles its messages in order. An edit goes to each worker
//! before each job that starts after the edit. So a worker has the blocks of
//! main when the job started (C3).
//!
//! Only this file uses std.Thread. worker_world.zig must build for
//! wasm32-freestanding (chunks.wasm, C9).
const std = @import("std");
const stages = @import("stages.zig");
const protocol = @import("protocol.zig");
const scheduler_mod = @import("scheduler.zig");
const exec_inline = @import("exec_inline.zig");
const worker_world = @import("worker_world.zig");
const world_mod = @import("../world.zig");
const content = @import("../content.zig");
const jobs = @import("sw_jobs");

const Scheduler = scheduler_mod.Scheduler;
const Started = scheduler_mod.Started;
const World = world_mod.World;
const FrameReport = exec_inline.FrameReport;
const Clock = exec_inline.Clock;

/// The most threads of a pool (C9).
pub const MAX_WORKERS = 4;
/// The jobs that a worker holds: one runs, one waits (C8).
pub const JOBS_PER_WORKER = 2;
/// The width of an affinity region, in chunks (C4).
pub const REGION: i32 = 8;

/// min(CPU count - 1, MAX_WORKERS), and at least 1 (C9).
pub fn defaultWorkerCount() usize {
    const cpus = std.Thread.getCpuCount() catch 2;
    return std.math.clamp(cpus -| 1, 1, MAX_WORKERS);
}

/// The worker of chunk (cx, cz) in a pool of `n` workers (C4). Neighbour
/// regions go to different workers, so the work near the player spreads
/// over the pool.
pub fn ownerOf(cx: i32, cz: i32, n: usize) usize {
    const rx = @divFloor(cx, REGION);
    const rz = @divFloor(cz, REGION);
    return @intCast(@mod(rx + 2 * rz, @as(i32, @intCast(n))));
}

/// The handler of one worker thread (sw_jobs): a WorkerWorld. It answers
/// each message with protocol bytes, and writes the job time into each
/// Result (C12).
const ChunkWorker = struct {
    world: worker_world.WorkerWorld,
    io: std.Io,

    pub const Snapshot = struct {
        stats: worker_world.Stats = .{},
        cached: usize = 0,
        cache_bytes: usize = 0,
    };

    pub fn handle(self: *ChunkWorker, msg: []const u8) jobs.Answer {
        const t0 = std.Io.Timestamp.now(self.io, .awake).toNanoseconds();
        const reply = self.world.handle(msg) catch null;
        const t1 = std.Io.Timestamp.now(self.io, .awake).toNanoseconds();
        if (reply) |r| {
            stampJobTime(r, t1 - t0);
            return .{ .reply = r };
        }
        // An edit has no reply. A job with no reply had no memory: main
        // abandons it.
        return if (msg[6] == @backingInt(protocol.Kind.edit)) .none else .failed;
    }

    /// A copy of the cache counters (C12).
    pub fn snapshot(self: *const ChunkWorker) Snapshot {
        return .{ .stats = self.world.stats, .cached = self.world.cachedChunks(), .cache_bytes = self.world.bytes };
    }

    pub fn deinit(self: *ChunkWorker) void {
        self.world.deinit();
    }

    /// Write the job time into a Result (C12).
    fn stampJobTime(reply: []u8, ns: i128) void {
        if (reply.len < protocol.PAYLOAD_OFFSET or reply[6] != @backingInt(protocol.Kind.result)) return;
        const us: u32 = @intCast(std.math.clamp(@divTrunc(ns, 1000), 0, std.math.maxInt(u32)));
        std.mem.writeInt(u32, reply[protocol.HEADER_LEN + 28 ..][0..4], us, .little);
    }
};

const Pool = jobs.ThreadPool(ChunkWorker);
/// A message from a worker. `bytes` is null when the worker had no memory
/// for the reply. Main then abandons the job.
const Reply = Pool.Reply;

const InFlight = struct {
    started: Started,
    worker: usize,
};

pub const ThreadPool = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// The worker threads (sw_jobs).
    pool: Pool,
    /// The jobs sent to each worker and not answered. Main thread only.
    in_flight: []usize,
    /// Replies that main took and did not install yet (the install budget).
    pending: std.ArrayList(Reply) = .empty,
    pending_head: usize = 0,
    jobs: std.AutoHashMapUnmanaged(u32, InFlight) = .empty,
    next_id: u32 = 1,
    traffic: exec_inline.Traffic = .{},

    /// Start `n` worker threads for the world `config`. Each worker gets a
    /// Hello first, and must answer with the same protocol and build (C9).
    /// The pool must not move after `init`: the threads hold pointers to it.
    pub fn init(self: *ThreadPool, allocator: std.mem.Allocator, io: std.Io, n: usize, config: content.GenConfig, cache_limit: u64) !void {
        std.debug.assert(n >= 1);
        const handlers = try allocator.alloc(ChunkWorker, n);
        defer allocator.free(handlers);
        for (handlers) |*h| h.* = .{ .world = .init(allocator), .io = io };
        const in_flight = allocator.alloc(usize, n) catch |err| {
            for (handlers) |*h| h.deinit();
            return err;
        };
        @memset(in_flight, 0);
        self.* = .{ .allocator = allocator, .io = io, .pool = undefined, .in_flight = in_flight };
        self.pool.init(allocator, io, handlers) catch |err| {
            for (handlers) |*h| h.deinit();
            allocator.free(in_flight);
            return err;
        };
        // deinit stops the threads that started, and frees the workers.
        errdefer self.deinit();

        // The handshake, before the threads start.
        const hello = try protocol.encodeHello(allocator, exec_inline.helloOf(config, cache_limit));
        defer allocator.free(hello);
        for (0..n) |i| {
            const reply = try self.pool.handler(i).world.handle(hello);
            defer if (reply) |r| allocator.free(r);
            if (!exec_inline.checkHello(reply)) return error.WorkerHandshake;
        }
        try self.pool.start();
    }

    /// Stop each thread after its current job, and wait for it, then free
    /// everything. Jobs that did not finish are lost: the caller frees the
    /// scheduler too, or calls `abandonAll` first.
    pub fn deinit(self: *ThreadPool) void {
        const a = self.allocator;
        self.pool.deinit();
        a.free(self.in_flight);
        self.in_flight = &.{};
        for (self.pending.items[self.pending_head..]) |r| if (r.bytes) |b| a.free(b);
        self.pending.deinit(a);
        self.jobs.deinit(a);
    }

    /// Give each job in flight back to the scheduler, so that the next plan
    /// queues it again. Call it before `deinit` when the scheduler stays.
    pub fn abandonAll(self: *ThreadPool, sched: *Scheduler) void {
        var it = self.jobs.valueIterator();
        while (it.next()) |j| sched.abandon(j.started);
        self.jobs.clearRetainingCapacity();
        @memset(self.in_flight, 0);
    }

    /// Send the pending edits of the scheduler to each worker, in order.
    pub fn sendEdits(self: *ThreadPool, sched: *Scheduler) !void {
        for (sched.pendingEdits()) |e| {
            const msg = try protocol.encodeEdit(self.allocator, e);
            defer self.allocator.free(msg);
            try self.pool.broadcast(0, msg);
            self.traffic.edits += self.in_flight.len;
            self.traffic.edit_bytes += msg.len * self.in_flight.len;
        }
        sched.outbox.clearRetainingCapacity();
    }

    /// Move the replies of the workers to `pending`.
    fn takeReplies(self: *ThreadPool) !void {
        if (self.pending_head == self.pending.items.len) {
            self.pending.clearRetainingCapacity();
            self.pending_head = 0;
        }
        try self.pool.takeReplies(&self.pending);
    }

    const Installed = struct {
        stage: stages.Stage,
        outcome: Scheduler.Outcome,
        job_ns: u64,
    };

    /// Install one reply. Returns null when the job failed and went back
    /// to the scheduler.
    fn installReply(self: *ThreadPool, sched: *Scheduler, world: *World, r: Reply) !?Installed {
        const kv = self.jobs.fetchRemove(r.id) orelse {
            std.log.err("[PIPE] a worker reply has an unknown job id {}", .{r.id});
            if (r.bytes) |b| self.allocator.free(b);
            return null;
        };
        const job = kv.value;
        self.in_flight[job.worker] -= 1;
        const bytes = r.bytes orelse {
            sched.abandon(job.started);
            return null;
        };
        self.traffic.addResult(job.started.job.stage, bytes.len);
        // resultOf takes the bytes. A mesh keeps them for the upload (C5).
        var result = exec_inline.resultOf(world.allocator, job.started, bytes, self.allocator) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                sched.abandon(job.started);
                return null;
            },
        };
        const outcome = try sched.install(world, &result);
        return .{ .stage = job.started.job.stage, .outcome = outcome, .job_ns = result.job_ns };
    }

    /// The frame phase. It installs results until `clock()` reaches
    /// `deadline_ns` (the install budget, C7), with at least one install
    /// when a result waits. Then it plans and sends jobs to the workers
    /// that have room. It never waits for a worker.
    pub fn runFrame(self: *ThreadPool, sched: *Scheduler, world: *World, clock: Clock, deadline_ns: u64) !FrameReport {
        var report: FrameReport = .{};
        const t_start = clock();
        try self.sendEdits(sched);
        try self.takeReplies();
        while (self.pending_head < self.pending.items.len) {
            if (report.jobs > 0 and clock() >= deadline_ns) break;
            const r = self.pending.items[self.pending_head];
            self.pending_head += 1;
            const t0 = clock();
            const done = try self.installReply(sched, world, r);
            report.install_ns += clock() - t0;
            const d = done orelse continue;
            const k = @backingInt(d.stage);
            report.count[k] += 1;
            report.job_ns[k] += d.job_ns;
            report.jobs += 1;
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

    /// The worker for `job`: the owner of its region when the owner has
    /// room. Else a worker with no job takes it, so that no thread waits
    /// while work waits. That worker generates the chunks that it does not
    /// have. Null when no worker can take the job now.
    fn workerFor(self: *const ThreadPool, job: scheduler_mod.Job) ?usize {
        const owner = ownerOf(job.cx, job.cz, self.in_flight.len);
        if (self.in_flight[owner] < JOBS_PER_WORKER) return owner;
        for (self.in_flight, 0..) |n, i| {
            if (n == 0) return i;
        }
        return null;
    }

    /// Plan, and send the jobs in priority order to the workers that have
    /// room. A job whose worker is full waits for the next plan. Returns
    /// the number of jobs that it sent.
    fn dispatch(self: *ThreadPool, sched: *Scheduler, world: *World) !usize {
        try sched.plan(world);
        var room: usize = 0;
        for (self.in_flight) |n| room += JOBS_PER_WORKER - n;
        var skipped = false;
        var sent: usize = 0;
        while (room > 0) {
            const job = sched.next(world) orelse break;
            const wi = self.workerFor(job) orelse {
                skipped = true;
                continue;
            };
            const started = try sched.start(world, job);
            errdefer sched.abandon(started);
            const id = self.next_id;
            self.next_id +%= 1;
            if (self.next_id == 0) self.next_id = 1;
            const msg = try protocol.encodeJob(self.allocator, id, started.messageFor(sched));
            errdefer self.allocator.free(msg);
            try self.jobs.put(self.allocator, id, .{ .started = started, .worker = wi });
            errdefer _ = self.jobs.remove(id);
            try self.pool.post(wi, id, msg);
            self.traffic.jobs += 1;
            self.traffic.job_bytes += msg.len;
            self.in_flight[wi] += 1;
            room -= 1;
            sent += 1;
        }
        // The next frame plans again, so a job that waited for its worker
        // goes back in the queue.
        if (skipped) sched.dirty = true;
        return sent;
    }

    /// Run frames until the scheduler is idle. It sleeps a little while the
    /// workers run. For tests and tools.
    pub fn runUntilIdle(self: *ThreadPool, sched: *Scheduler, world: *World) !void {
        while (true) {
            _ = try self.runFrame(sched, world, zeroClock, std.math.maxInt(u64));
            if (sched.isIdle()) return;
            if (sched.in_flight > 0) self.waitForReply(10_000);
        }
    }

    /// The number of worker threads.
    pub fn workerCount(self: *const ThreadPool) usize {
        return self.in_flight.len;
    }

    /// Wait until a reply arrives, or `timeout_us` passes.
    pub fn waitForReply(self: *ThreadPool, timeout_us: i64) void {
        self.pool.waitForReply(timeout_us);
    }

    /// The jobs in flight of each worker, and its cache (C12).
    pub fn workerInfo(self: *ThreadPool, i: usize) struct { in_flight: usize, cached: usize, cache_bytes: usize, stats: worker_world.Stats } {
        const snap = self.pool.snapshot(i);
        return .{ .in_flight = self.in_flight[i], .cached = snap.cached, .cache_bytes = snap.cache_bytes, .stats = snap.stats };
    }

    fn zeroClock() u64 {
        return 0;
    }
};
