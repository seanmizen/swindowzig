//! The Inline executor (C1): it runs chunk jobs on the main thread, in the
//! frame phase, within a frame budget (C7).
//!
//! Headless runs, TAS runs, the goldens and the web build use it. Native
//! uses it too until a thread pool executor replaces it. Each job reads its
//! inputs from the World in place: the light stage reads the blocks of 9
//! chunks, and the mesh stage reads the blocks and the light of 9 chunks
//! (D8). The stages are pure, so the result is the result of a worker.
const std = @import("std");
const stages = @import("stages.zig");
const scheduler_mod = @import("scheduler.zig");
const world_mod = @import("../world.zig");

const Scheduler = scheduler_mod.Scheduler;
const Job = scheduler_mod.Job;
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
};

pub const Inline = struct {
    allocator: std.mem.Allocator,
    /// The light stage scratch (about 4 MB), kept between jobs.
    scratch: ?*stages.LightScratch = null,

    pub fn init(allocator: std.mem.Allocator) Inline {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Inline) void {
        if (self.scratch) |s| self.allocator.destroy(s);
        self.scratch = null;
    }

    /// Start `job`, read its inputs from the World, and run its stage. The
    /// caller installs the result (Scheduler.install).
    pub fn run(self: *Inline, sched: *Scheduler, world: *World, job: Job) !Result {
        const started = sched.start(world, job);
        errdefer sched.abandon();
        const a = world.allocator;
        const output: scheduler_mod.Output = switch (job.stage) {
            .generate => .{ .generate = try stages.generate(a, world.gen_config.seed, world.gen_config, job.cx, job.cz) },
            .light => blk: {
                var window: stages.Window = undefined;
                for (0..stages.SLOTS) |s| {
                    const dcx, const dcz = stages.offsetOf(s);
                    window[s] = &world.get(job.cx + dcx, job.cz + dcz).?.chunk.blocks;
                }
                if (self.scratch == null) self.scratch = try self.allocator.create(stages.LightScratch);
                break :blk .{ .light = try stages.lightScratch(a, &window, self.scratch.?) };
            },
            .mesh => blk: {
                // ChunkLight views of the light grids of the World. They
                // own nothing.
                var lights: [stages.SLOTS]stages.ChunkLight = undefined;
                var hood: stages.Neighbourhood = undefined;
                for (0..stages.SLOTS) |s| {
                    const dcx, const dcz = stages.offsetOf(s);
                    const lc = world.get(job.cx + dcx, job.cz + dcz).?;
                    lights[s] = .{ .sky = lc.chunk.skylight, .block = lc.chunk.block_light };
                    hood[s] = .{ .blocks = &lc.chunk.blocks, .light = &lights[s] };
                }
                break :blk .{ .mesh = try stages.mesh(a, &hood, sched.ao, sched.lighting) };
            },
        };
        return .{ .started = started, .output = output };
    }

    /// The frame phase: plan, then run and install jobs in priority order
    /// until no job can start, or until `clock()` reaches `deadline_ns`.
    /// When a job can start, at least one job runs, so loading always moves
    /// on. The check runs before each job, so a frame can go past the
    /// deadline by one job.
    pub fn runFrame(self: *Inline, sched: *Scheduler, world: *World, clock: Clock, deadline_ns: u64) !FrameReport {
        var report: FrameReport = .{};
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
        }
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
