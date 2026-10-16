//! Tests of the worker world and the executors (C4, C14, P4, P6).
//!
//! The root of this test is here, next to world.zig, because a module can
//! import only files under the directory of its root.
//!
//!   cache        the cache of a worker stays within its limit (C14). An
//!                evicted chunk comes back with its edits (P2).
//!   handshake    a worker stops a Hello from another build (C9).
//!   equivalence  the Inline executor and the ThreadPool executor give the
//!                same bytes, also with random edits while jobs run (P4).
//!                Both give the result of a recompute from scratch.
//!   shutdown     a pool stops with jobs in flight, and starts again for a
//!                new world, with no leaks.
const std = @import("std");
const stages = @import("pipeline/stages.zig");
const protocol = @import("pipeline/protocol.zig");
const scheduler_mod = @import("pipeline/scheduler.zig");
const exec_inline = @import("pipeline/exec_inline.zig");
const exec_threads = @import("pipeline/exec_threads.zig");
const worker_world = @import("pipeline/worker_world.zig");
const world_mod = @import("world.zig");
const chunk_mod = @import("chunk.zig");
const world_gen = @import("world_gen.zig");
const test_recompute = @import("test_recompute.zig");

const Scheduler = scheduler_mod.Scheduler;
const Region = scheduler_mod.Region;
const World = world_mod.World;
const CHUNK_W = chunk_mod.CHUNK_W;

fn hilly(seed: u64) world_gen.WorldGenConfig {
    var c = world_gen.presetConfig(.hilly);
    c.seed = seed;
    return c;
}

/// Send `msg` to `w` and decode the reply. The caller frees `reply`.
fn ask(a: std.mem.Allocator, w: *worker_world.WorkerWorld, msg: []u8) !struct { reply: []u8, d: protocol.Decoded } {
    defer a.free(msg);
    const reply = (try w.handle(msg)).?;
    return .{ .reply = reply, .d = try protocol.decode(reply) };
}

test "exec: the worker cache stays within its limit, and an evicted chunk keeps its edits" {
    const a = std.testing.allocator;
    var w: worker_world.WorkerWorld = .init(a);
    defer w.deinit();
    // About 12 hilly chunks (blocks and light) fit in 1 MB.
    const limit: u64 = 1 << 20;
    const hello = try ask(a, &w, try protocol.encodeHello(a, .{ .cache_limit = limit, .config = hilly(0) }));
    a.free(hello.reply);

    // An edit in chunk (0, 0) before the chunk is in the cache.
    const edit: protocol.Edit = .{ .cx = 0, .cz = 0, .version = 1, .x = 3, .y = 100, .z = 4, .block = .glowstone };
    const em = try protocol.encodeEdit(a, edit);
    defer a.free(em);
    try std.testing.expect(try w.handle(em) == null);

    var id: u32 = 1;
    var cz: i32 = -3;
    while (cz <= 3) : (cz += 1) {
        var cx: i32 = -3;
        while (cx <= 3) : (cx += 1) {
            var job: protocol.Job = .{ .stage = .light, .cx = cx, .cz = cz };
            for (0..stages.SLOTS) |s| {
                const dcx, const dcz = stages.offsetOf(s);
                job.blocks[s] = w.blockVersion(cx + dcx, cz + dcz);
            }
            const r = try ask(a, &w, try protocol.encodeJob(a, id, job));
            defer a.free(r.reply);
            try std.testing.expect(r.d.msg == .result);
            // C14: after each message the cache is within its limit.
            try std.testing.expect(w.bytes <= limit);
            id += 1;
        }
    }
    try std.testing.expect(w.stats.evicted > 0);
    try std.testing.expect(w.stats.peak_bytes > limit / 2);
    // (0, 0) is old: the cache evicted it. A generate makes it again from
    // the seed and the edit log.
    try std.testing.expect(!w.cache.contains(.{ .cx = 0, .cz = 0 }));
    const r = try ask(a, &w, try protocol.encodeJob(a, id, .{ .stage = .generate, .cx = 0, .cz = 0, .want_blocks = true }));
    defer a.free(r.reply);
    const res = r.d.msg.result;
    try std.testing.expectEqual(@as(stages.Version, 1), res.head.block_ver);
    var blocks = try protocol.decodeBlocks(a, res);
    defer blocks.deinit(a);
    var want = try stages.generate(a, 0, hilly(0), 0, 0);
    defer want.deinit(a);
    try want.set(a, chunk_mod.blockLinearIdx(3, 100, 4), .glowstone);
    for (0..chunk_mod.BLOCKS_PER_CHUNK) |i| try std.testing.expectEqual(want.get(i), blocks.get(i));

    // LRU: a chunk that a job reads stays, and the oldest goes first.
    const before = w.stats.evicted;
    const touch = try ask(a, &w, try protocol.encodeJob(a, id + 1, .{ .stage = .generate, .cx = 3, .cz = 3 }));
    a.free(touch.reply);
    try std.testing.expect(w.cache.contains(.{ .cx = 0, .cz = 0 }));
    try std.testing.expect(w.stats.evicted >= before);
}

test "exec: a worker stops a Hello from another build, and a stale job" {
    const a = std.testing.allocator;
    var w: worker_world.WorkerWorld = .init(a);
    defer w.deinit();
    const bad = try ask(a, &w, try protocol.encodeHello(a, .{ .build_hash = protocol.BUILD_HASH ^ 1, .cache_limit = 1 << 20, .config = hilly(0) }));
    defer a.free(bad.reply);
    try std.testing.expectEqual(protocol.ErrorCode.version_mismatch, bad.d.msg.err.code);
    // No world yet.
    const nw = try ask(a, &w, try protocol.encodeJob(a, 1, .{ .stage = .generate, .cx = 0, .cz = 0 }));
    defer a.free(nw.reply);
    try std.testing.expectEqual(protocol.ErrorCode.no_world, nw.d.msg.err.code);
    const ok = try ask(a, &w, try protocol.encodeHello(a, .{ .cache_limit = 1 << 20, .config = hilly(0) }));
    defer a.free(ok.reply);
    try std.testing.expect(ok.d.msg == .hello);
    // C3: a light job with a block version that the worker does not have.
    var job: protocol.Job = .{ .stage = .light, .cx = 0, .cz = 0 };
    job.blocks[stages.CENTER] = 1;
    const st = try ask(a, &w, try protocol.encodeJob(a, 2, job));
    defer a.free(st.reply);
    try std.testing.expectEqual(protocol.ErrorCode.stale_input, st.d.msg.err.code);
}

// ---------------------------------------------------------------------------
// Equivalence (P4, P6)
// ---------------------------------------------------------------------------

/// One step of a scenario. Both executors get the same steps.
const Step = union(enum) {
    /// Run frames. Inline: one job per frame. ThreadPool: a frame does not
    /// wait for a worker.
    frames: u32,
    /// Main gets the blocks of the simulation radius (C6), then edits.
    edit: struct { wx: i32, wy: i32, wz: i32, block: chunk_mod.BlockType },
    move: struct { cx: i32, cz: i32 },
    options: stages.AOStrategy,
};

const R: i32 = 2;

/// A scenario: frames, moves and random edits in the simulation radius.
fn makeScenario(a: std.mem.Allocator, seed: u64) ![]Step {
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    var steps: std.ArrayList(Step) = .empty;
    errdefer steps.deinit(a);
    var cx: i32 = 0;
    var cz: i32 = 0;
    for (0..60) |_| {
        switch (rand.uintLessThan(u8, 10)) {
            0...3 => try steps.append(a, .{ .frames = rand.intRangeAtMost(u32, 1, 6) }),
            4...7 => {
                // An edit in the simulation radius, often at a chunk border.
                const ecx = cx + rand.intRangeAtMost(i32, -1, 1);
                const ecz = cz + rand.intRangeAtMost(i32, -1, 1);
                const edge = [_]i32{ 0, 1, 2, 7, 13, 14, 15 };
                const lx = edge[rand.uintLessThan(usize, edge.len)];
                const lz = rand.intRangeAtMost(i32, 0, CHUNK_W - 1);
                const blocks = [_]chunk_mod.BlockType{ .air, .air, .stone, .glowstone };
                try steps.append(a, .{ .edit = .{
                    .wx = ecx * CHUNK_W + lx,
                    .wy = rand.intRangeAtMost(i32, 55, 90),
                    .wz = ecz * CHUNK_W + lz,
                    .block = blocks[rand.uintLessThan(usize, blocks.len)],
                } });
            },
            8 => {
                cx += rand.intRangeAtMost(i32, -1, 1);
                cz += rand.intRangeAtMost(i32, -1, 1);
                try steps.append(a, .{ .move = .{ .cx = cx, .cz = cz } });
            },
            else => try steps.append(a, .{ .options = if (rand.boolean()) .moore else .classic }),
        }
    }
    return steps.toOwnedSlice(a);
}

fn Run(comptime Exec: type) type {
    return struct {
        world: World,
        sched: Scheduler,
        exec: *Exec,

        const Self = @This();

        fn step(self: *Self, s: Step) !void {
            switch (s) {
                .frames => |n| for (0..n) |_| {
                    _ = try self.exec.runFrame(&self.sched, &self.world, zeroClock, 0);
                },
                .edit => |e| {
                    _ = try self.sched.ensureSimRadius(&self.world, self.sched.center_cx, self.sched.center_cz);
                    try std.testing.expect(try self.sched.editBlock(&self.world, e.wx, e.wy, e.wz, e.block));
                },
                .move => |m| self.sched.setCenter(m.cx, m.cz),
                .options => |ao| self.sched.setMeshOptions(ao, .skylight),
            }
        }

        fn zeroClock() u64 {
            return 0;
        }
    };
}

/// The two runs must have the same desired state, byte for byte.
fn expectSameState(a: std.mem.Allocator, w1: *const World, s1: *const Scheduler, w2: *const World, s2: *const Scheduler) !usize {
    _ = a;
    try std.testing.expectEqual(s1.center_cx, s2.center_cx);
    var meshes: usize = 0;
    var dz: i32 = -R - 2;
    while (dz <= R + 2) : (dz += 1) {
        var dx: i32 = -R - 2;
        while (dx <= R + 2) : (dx += 1) {
            if (!Region.blocks(dx, dz, R)) continue;
            const cx = s1.center_cx + dx;
            const cz = s1.center_cz + dz;
            const c1 = w1.get(cx, cz).?;
            const c2 = w2.get(cx, cz).?;
            try std.testing.expectEqual(c1.block_ver, c2.block_ver);
            // Main must have the blocks of the prefetch radius (C6). Out of
            // it, the blocks in the band of the hysteresis depend on the
            // path of the player, not on the executor.
            if (Region.prefetch(dx, dz, 0)) try std.testing.expect(c1.has_blocks and c2.has_blocks);
            if (c1.has_blocks and c2.has_blocks) {
                for (0..chunk_mod.BLOCKS_PER_CHUNK) |i| try std.testing.expectEqual(c1.chunk.blocks.get(i), c2.chunk.blocks.get(i));
            }
            if (Region.light(dx, dz, R)) {
                try std.testing.expect(Scheduler.lightCurrent(w1, c1) and Scheduler.lightCurrent(w2, c2));
                try std.testing.expectEqual(c1.light_hash, c2.light_hash);
            }
            if (Region.mesh(dx, dz, R)) {
                try std.testing.expect(s1.meshCurrent(w1, c1) and s2.meshCurrent(w2, c2));
                try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(c1.mesh.quads.items), std.mem.sliceAsBytes(c2.mesh.quads.items));
                try std.testing.expectEqual(c1.mesh.y_min, c2.mesh.y_min);
                try std.testing.expectEqual(c1.mesh.y_max, c2.mesh.y_max);
                meshes += 1;
            }
        }
    }
    return meshes;
}

fn equivalence(a: std.mem.Allocator, seed: u64, workers: usize) !void {
    const steps = try makeScenario(a, seed);
    defer a.free(steps);
    const config = hilly(seed % 3);

    var inl = try exec_inline.Inline.init(a, config, worker_world.DEFAULT_CACHE_LIMIT);
    defer inl.deinit();
    var r1: Run(exec_inline.Inline) = .{ .world = try World.init(a, .hilly, R), .sched = Scheduler.init(a, R, .moore, .skylight), .exec = &inl };
    defer r1.world.deinit();
    defer r1.sched.deinit();
    r1.world.gen_config = config;

    // A small cache, so that the workers evict and generate again.
    var pool: exec_threads.ThreadPool = undefined;
    try pool.init(a, std.testing.io, workers, config, 8 << 20);
    defer pool.deinit();
    var r2: Run(exec_threads.ThreadPool) = .{ .world = try World.init(a, .hilly, R), .sched = Scheduler.init(a, R, .moore, .skylight), .exec = &pool };
    defer r2.world.deinit();
    defer r2.sched.deinit();
    r2.world.gen_config = config;

    var edits: usize = 0;
    var edits_in_flight: usize = 0;
    for (steps) |s| {
        if (s == .edit) {
            edits += 1;
            if (r2.sched.in_flight > 0) edits_in_flight += 1;
        }
        try r1.step(s);
        try r2.step(s);
    }
    try inl.runUntilIdle(&r1.sched, &r1.world);
    try pool.runUntilIdle(&r2.sched, &r2.world);

    const meshes = try expectSameState(a, &r1.world, &r1.sched, &r2.world, &r2.sched);
    try std.testing.expect(meshes >= 13);
    // The edits came while jobs ran.
    try std.testing.expect(edits > 5 and edits_in_flight > 0);
    // Both are the result of a recompute from scratch (P2).
    _ = try test_recompute.expectMatchesRecompute(a, &r1.sched, &r1.world);
    _ = try test_recompute.expectMatchesRecompute(a, &r2.sched, &r2.world);
}

test "exec: Inline and ThreadPool give the same bytes, with random edits while jobs run" {
    const a = std.testing.allocator;
    const rounds: u64 = 3;
    for (0..rounds) |i| {
        const workers = [_]usize{ 3, 1, 4 };
        try equivalence(a, 0x708 + i, workers[i % workers.len]);
    }
}

test "exec: the pool stops with jobs in flight, and starts again for a new world" {
    const a = std.testing.allocator;
    var world = try World.init(a, .hilly, 1);
    defer world.deinit();
    var sched = Scheduler.init(a, 1, .moore, .skylight);
    defer sched.deinit();

    var pool: exec_threads.ThreadPool = undefined;
    try pool.init(a, std.testing.io, 3, world.gen_config, worker_world.DEFAULT_CACHE_LIMIT);
    // Send jobs, and stop before the results come back.
    _ = try pool.runFrame(&sched, &world, noClock, 0);
    try std.testing.expect(sched.in_flight > 0);
    pool.abandonAll(&sched);
    try std.testing.expectEqual(@as(usize, 0), sched.in_flight);
    pool.deinit();

    // A new world: seed 5. The old results do not matter.
    world.deinit();
    world = try World.init(a, .hilly, 1);
    world.gen_config.seed = 5;
    sched.deinit();
    sched = Scheduler.init(a, 1, .moore, .skylight);
    try pool.init(a, std.testing.io, 2, world.gen_config, worker_world.DEFAULT_CACHE_LIMIT);
    defer pool.deinit();
    try pool.runUntilIdle(&sched, &world);
    try std.testing.expect(sched.isReady(&world, 1));
    _ = try test_recompute.expectMatchesRecompute(a, &sched, &world);

    // Stop again with jobs in flight, with no abandonAll: deinit frees all.
    sched.setCenter(4, 4);
    _ = try pool.runFrame(&sched, &world, noClock, 0);
    try std.testing.expect(sched.in_flight > 0);
}

fn noClock() u64 {
    return 0;
}

test "exec: the affinity regions spread the chunks near the player over the pool" {
    for ([_]usize{ 1, 2, 3, 4 }) |n| {
        var count: [exec_threads.MAX_WORKERS]usize = @splat(0);
        var cz: i32 = -8;
        while (cz < 8) : (cz += 1) {
            var cx: i32 = -8;
            while (cx < 8) : (cx += 1) count[exec_threads.ownerOf(cx, cz, n)] += 1;
        }
        // Each worker gets a part, and no worker more than half.
        for (count[0..n]) |c| {
            try std.testing.expect(c > 0);
            if (n > 1) try std.testing.expect(c <= 128);
        }
    }
    try std.testing.expect(exec_threads.defaultWorkerCount() >= 1);
    try std.testing.expect(exec_threads.defaultWorkerCount() <= exec_threads.MAX_WORKERS);
}
