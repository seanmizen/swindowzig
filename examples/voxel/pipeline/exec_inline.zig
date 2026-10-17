//! The Inline executor (C1): it runs chunk jobs on the main thread, in the
//! frame phase, within a frame budget (C7).
//!
//! Headless tools, the tests, the web build and the fallback use it. It has
//! one WorkerWorld (worker_world.zig) on the main thread. Each edit and
//! each job goes to it as protocol bytes, and each result comes back as
//! protocol bytes (P6). So the Inline executor runs the code and the bytes
//! of the ThreadPool executor and the Web Workers, with no threads.
//!
//! The ThreadPool executor uses two parts of this file too: the conversion
//! of a reply to a scheduler Result, and the counters of the message bytes.

const std = @import("std");
const stages = @import("stages.zig");
const protocol = @import("protocol.zig");
const scheduler_mod = @import("scheduler.zig");
const worker_world = @import("worker_world.zig");
const world_mod = @import("../world.zig");
const world_gen = @import("../world_gen.zig");

const Scheduler = scheduler_mod.Scheduler;
const Job = scheduler_mod.Job;
const Started = scheduler_mod.Started;
const Result = scheduler_mod.Result;
const World = world_mod.World;

/// A clock in ns. Main gives the wall clock of the platform (clock.zig).
pub const Clock = *const fn () u64;

/// What one frame did, for the debug overlay and the profile CSV (C12).
pub const FrameReport = struct {
    jobs: usize = 0,
    /// Jobs and job time for each stage.
    count: [scheduler_mod.STAGES]usize = @splat(0),
    job_ns: [scheduler_mod.STAGES]u64 = @splat(0),
    discarded: usize = 0,
    install_ns: u64 = 0,
    /// The time of the frame phase on the main thread: the plan, the
    /// messages and the installs. With the Inline executor it includes the
    /// job time too.
    main_ns: u64 = 0,
    /// The jobs that the frame sent to a worker.
    sent: usize = 0,
};

/// The bytes of the messages (C12).
pub const Traffic = struct {
    jobs: u64 = 0,
    job_bytes: u64 = 0,
    results: u64 = 0,
    result_bytes: u64 = 0,
    /// Edit messages, one for each edit and each worker.
    edits: u64 = 0,
    edit_bytes: u64 = 0,
    /// Result bytes for each stage.
    stage_results: [scheduler_mod.STAGES]u64 = @splat(0),
    stage_bytes: [scheduler_mod.STAGES]u64 = @splat(0),

    pub fn addResult(self: *Traffic, stage: stages.Stage, len: usize) void {
        self.results += 1;
        self.result_bytes += len;
        self.stage_results[@backingInt(stage)] += 1;
        self.stage_bytes[@backingInt(stage)] += len;
    }
};

pub const ReplyError = error{
    /// The worker sent an Error message.
    WorkerError,
    /// The reply is not a Result for the job.
    BadReply,
    OutOfMemory,
};

/// The scheduler Result of the worker reply `reply` to the job `st`. The
/// blocks and the quads are copies, from `allocator`. The caller still owns
/// `reply`.
pub fn resultOf(allocator: std.mem.Allocator, st: Started, reply: []const u8) ReplyError!Result {
    const d = protocol.decode(reply) catch return error.BadReply;
    const r = switch (d.msg) {
        .result => |r| r,
        .err => |e| {
            std.log.err("[PIPE] worker error {s} for {s} ({}, {})", .{ @tagName(e.code), @tagName(e.stage), e.cx, e.cz });
            return error.WorkerError;
        },
        else => return error.BadReply,
    };
    if (r.head.stage != st.job.stage or r.head.cx != st.job.cx or r.head.cz != st.job.cz) return error.BadReply;
    const output: scheduler_mod.Output = switch (r.head.stage) {
        .generate => .{ .generate = .{
            .block_ver = r.head.block_ver,
            .blocks = if (r.has_blocks) try protocol.decodeBlocks(allocator, r) else null,
        } },
        .light => .{ .light = .{ .hash = r.head.light_hash } },
        .mesh => blk: {
            const quads = try allocator.alloc(stages.PackedQuad, r.quadCount());
            r.copyQuads(quads);
            break :blk .{ .mesh = .{ .quads = quads, .y_min = r.head.y_min, .y_max = r.head.y_max } };
        },
    };
    return .{ .started = st, .output = output, .job_ns = @as(u64, r.head.job_us) * 1000 };
}

/// The Hello that starts a worker for `config` (C9).
pub fn helloOf(config: world_gen.WorldGenConfig, cache_limit: u64) protocol.Hello {
    return .{ .cache_limit = cache_limit, .config = config };
}

/// Check the Hello reply of a worker: the same protocol and build (C9).
pub fn checkHello(reply: ?[]const u8) bool {
    const bytes = reply orelse return false;
    const d = protocol.decode(bytes) catch return false;
    return switch (d.msg) {
        .hello => |h| h.build_hash == protocol.BUILD_HASH,
        else => false,
    };
}

pub const Inline = struct {
    allocator: std.mem.Allocator,
    worker: worker_world.WorkerWorld,
    next_id: u32 = 1,
    traffic: Traffic = .{},

    /// Start the worker for the world `config`, through a Hello message.
    pub fn init(allocator: std.mem.Allocator, config: world_gen.WorldGenConfig, cache_limit: u64) !Inline {
        var self: Inline = .{ .allocator = allocator, .worker = .init(allocator) };
        errdefer self.worker.deinit();
        const hello = try protocol.encodeHello(allocator, helloOf(config, cache_limit));
        defer allocator.free(hello);
        const reply = try self.worker.handle(hello);
        defer if (reply) |r| allocator.free(r);
        if (!checkHello(reply)) return error.WorkerHandshake;
        return self;
    }

    /// Start the worker for a world that has edits: the fallback when the
    /// WorkerPool stops (C9). The worker gets each edit of the edit log of
    /// `world`. The edits in the outbox of the scheduler are in the edit
    /// log too, so the outbox is then empty.
    pub fn initFromWorld(allocator: std.mem.Allocator, world: *const World, sched: *Scheduler, cache_limit: u64) !Inline {
        var self = try init(allocator, world.gen_config, cache_limit);
        errdefer self.deinit();
        var it = world.edits.valueIterator();
        while (it.next()) |list| {
            for (list.items) |e| try self.worker.applyEdit(e);
        }
        sched.outbox.clearRetainingCapacity();
        return self;
    }

    pub fn deinit(self: *Inline) void {
        self.worker.deinit();
    }

    /// Send the pending edits of the scheduler to the worker, in order.
    pub fn sendEdits(self: *Inline, sched: *Scheduler) !void {
        for (sched.pendingEdits()) |e| {
            const msg = try protocol.encodeEdit(self.allocator, e);
            defer self.allocator.free(msg);
            self.traffic.edits += 1;
            self.traffic.edit_bytes += msg.len;
            const reply = try self.worker.handle(msg);
            if (reply) |r| {
                defer self.allocator.free(r);
                std.log.err("[PIPE] the worker did not apply an edit", .{});
                return error.WorkerError;
            }
        }
        sched.outbox.clearRetainingCapacity();
    }

    /// Start `job` and run it in the worker. The caller installs the
    /// result (Scheduler.install).
    pub fn run(self: *Inline, sched: *Scheduler, world: *World, job: Job) !Result {
        try self.sendEdits(sched);
        const started = try sched.start(world, job);
        errdefer sched.abandon(started);
        const id = self.next_id;
        self.next_id +%= 1;
        const msg = try protocol.encodeJob(self.allocator, id, started.message(sched.ao, sched.lighting));
        defer self.allocator.free(msg);
        self.traffic.jobs += 1;
        self.traffic.job_bytes += msg.len;
        const reply = (try self.worker.handle(msg)) orelse return error.BadReply;
        defer self.allocator.free(reply);
        self.traffic.addResult(job.stage, reply.len);
        return resultOf(world.allocator, started, reply);
    }

    /// The frame phase: plan, then run and install jobs in priority order
    /// until no job can start, or until `clock()` reaches `deadline_ns`.
    /// When a job can start, at least one job runs, so loading always moves
    /// on. The check runs before each job, so a frame can go past the
    /// deadline by one job.
    pub fn runFrame(self: *Inline, sched: *Scheduler, world: *World, clock: Clock, deadline_ns: u64) !FrameReport {
        var report: FrameReport = .{};
        const t_start = clock();
        try self.sendEdits(sched);
        try sched.plan(world);
        while (true) {
            if (report.jobs > 0 and clock() >= deadline_ns) break;
            const job = sched.next(world) orelse {
                // The installs of this frame can make new jobs ready.
                if (!sched.dirty) break;
                try sched.plan(world);
                continue;
            };
            const t0 = clock();
            var result = try self.run(sched, world, job);
            const t1 = clock();
            result.job_ns = t1 - t0;
            const k = @backingInt(job.stage);
            report.count[k] += 1;
            report.job_ns[k] += result.job_ns;
            if (try sched.install(world, &result) == .discarded) report.discarded += 1;
            report.install_ns += clock() - t1;
            report.jobs += 1;
            report.sent += 1;
        }
        report.main_ns = clock() - t_start;
        if (report.jobs > 0) {
            sched.stats.install_ns.push(report.install_ns);
            sched.stats.last_frame_jobs = report.jobs;
        }
        return report;
    }

    /// Run frames with no deadline until the scheduler is idle. For tests
    /// and tools.
    pub fn runUntilIdle(self: *Inline, sched: *Scheduler, world: *World) !void {
        while (true) {
            _ = try self.runFrame(sched, world, zeroClock, std.math.maxInt(u64));
            try sched.plan(world);
            if (sched.isIdle()) return;
        }
    }

    fn zeroClock() u64 {
        return 0;
    }
};
