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
//!   web          the WorkerPool executor (exec_web.zig) with a transport of
//!                in-process workers gives the bytes of the Inline
//!                executor: replies in any order between workers, random
//!                edits, workers that stop and start again, and a pool that
//!                stops (the Inline fallback). The Bun tests run the same
//!                executor with real Web Workers.
const std = @import("std");
const stages = @import("pipeline/stages.zig");
const protocol = @import("pipeline/protocol.zig");
const scheduler_mod = @import("pipeline/scheduler.zig");
const exec_inline = @import("pipeline/exec_inline.zig");
const exec_threads = @import("pipeline/exec_threads.zig");
const exec_web = @import("pipeline/exec_web.zig");
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

// ---------------------------------------------------------------------------
// The WorkerPool executor (exec_web.zig), with in-process workers
// ---------------------------------------------------------------------------

/// A transport with in-process WorkerWorlds, as the JS pool
/// (backends/wasm/worker-pool.ts) does it with Web Workers: a FIFO inbox
/// for each worker, replies in a shared queue, and a restart that sends the
/// Hello, all the edits and the jobs in flight again.
const FakePool = struct {
    a: std.mem.Allocator,
    rand: std.Random,
    workers: []FakeWorker,
    hello: ?[]u8 = null,
    edits: std.ArrayList([]u8) = .empty,
    replies: std.ArrayList([]u8) = .empty,
    restarts: usize = 0,

    const FakeWorker = struct {
        world: worker_world.WorkerWorld,
        alive: bool = true,
        inbox: std.ArrayList([]u8) = .empty,
        /// The job messages in flight, in order.
        pending: std.ArrayList([]u8) = .empty,
    };

    fn init(a: std.mem.Allocator, rand: std.Random, n: usize) !FakePool {
        const workers = try a.alloc(FakeWorker, n);
        for (workers) |*w| w.* = .{ .world = .init(a) };
        return .{ .a = a, .rand = rand, .workers = workers };
    }

    fn deinit(self: *FakePool) void {
        for (self.workers) |*w| {
            w.world.deinit();
            for (w.inbox.items) |m| self.a.free(m);
            w.inbox.deinit(self.a);
            for (w.pending.items) |m| self.a.free(m);
            w.pending.deinit(self.a);
        }
        self.a.free(self.workers);
        if (self.hello) |h| self.a.free(h);
        for (self.edits.items) |m| self.a.free(m);
        self.edits.deinit(self.a);
        for (self.replies.items) |m| self.a.free(m);
        self.replies.deinit(self.a);
    }

    fn transport(self: *FakePool) exec_web.Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: exec_web.Transport.VTable = .{
        .slots = slots,
        .alive = alive,
        .post = post,
        .broadcast = broadcast,
        .nextLen = nextLen,
        .take = take,
    };

    fn from(ptr: *anyopaque) *FakePool {
        return @ptrCast(@alignCast(ptr));
    }
    fn slots(ptr: *anyopaque) usize {
        return from(ptr).workers.len;
    }
    fn alive(ptr: *anyopaque, slot: usize) bool {
        return from(ptr).workers[slot].alive;
    }
    fn send(self: *FakePool, w: *FakeWorker, msg: []const u8) void {
        w.inbox.append(self.a, self.a.dupe(u8, msg) catch @panic("OOM")) catch @panic("OOM");
    }
    fn post(ptr: *anyopaque, slot: usize, msg: []const u8) bool {
        const self = from(ptr);
        const w = &self.workers[slot];
        if (!w.alive) return false;
        w.pending.append(self.a, self.a.dupe(u8, msg) catch @panic("OOM")) catch @panic("OOM");
        self.send(w, msg);
        return true;
    }
    fn broadcast(ptr: *anyopaque, msg: []const u8) bool {
        const self = from(ptr);
        const copy = self.a.dupe(u8, msg) catch @panic("OOM");
        if (msg[6] == @backingInt(protocol.Kind.hello)) {
            if (self.hello) |h| self.a.free(h);
            self.hello = copy;
        } else {
            self.edits.append(self.a, copy) catch @panic("OOM");
        }
        for (self.workers) |*w| {
            if (w.alive) self.send(w, msg);
        }
        return true;
    }
    fn nextLen(ptr: *anyopaque) usize {
        const self = from(ptr);
        return if (self.replies.items.len == 0) 0 else self.replies.items[0].len;
    }
    fn take(ptr: *anyopaque, buf: []u8) void {
        const self = from(ptr);
        const r = self.replies.orderedRemove(0);
        defer self.a.free(r);
        @memcpy(buf, r);
    }

    /// Let the workers handle up to `n` messages, from random workers. Each
    /// worker handles its own messages in order.
    fn pump(self: *FakePool, n: usize) !void {
        for (0..n) |_| {
            const i = self.rand.uintLessThan(usize, self.workers.len);
            const w = &self.workers[i];
            if (!w.alive or w.inbox.items.len == 0) continue;
            const msg = w.inbox.orderedRemove(0);
            defer self.a.free(msg);
            const reply = try w.world.handle(msg) orelse continue;
            const id = std.mem.readInt(u32, reply[12..16], .little);
            if (id == 0) {
                // A Hello reply. The JS pool checks it.
                defer self.a.free(reply);
                try std.testing.expect(reply[6] == @backingInt(protocol.Kind.hello));
                continue;
            }
            for (w.pending.items, 0..) |p, k| {
                if (std.mem.readInt(u32, p[12..16], .little) == id) {
                    self.a.free(w.pending.orderedRemove(k));
                    break;
                }
            }
            try self.replies.append(self.a, reply);
        }
    }

    /// The worker in `slot` stops. A new worker gets the Hello, all the
    /// edits and the jobs in flight of the old worker, in order.
    fn restart(self: *FakePool, slot: usize) void {
        const w = &self.workers[slot];
        if (!w.alive) return;
        w.world.deinit();
        w.world = .init(self.a);
        for (w.inbox.items) |m| self.a.free(m);
        w.inbox.clearRetainingCapacity();
        if (self.hello) |h| self.send(w, h);
        for (self.edits.items) |e| self.send(w, e);
        for (w.pending.items) |p| self.send(w, p);
        self.restarts += 1;
    }

    /// The worker in `slot` stops for good. Its jobs go to another worker.
    fn kill(self: *FakePool, slot: usize) void {
        const w = &self.workers[slot];
        w.alive = false;
        for (w.inbox.items) |m| self.a.free(m);
        w.inbox.clearRetainingCapacity();
        for (self.workers) |*o| {
            if (!o.alive) continue;
            for (w.pending.items) |p| {
                self.send(o, p);
                o.pending.append(self.a, p) catch @panic("OOM");
            }
            w.pending.clearRetainingCapacity();
            return;
        }
        for (w.pending.items) |p| self.a.free(p);
        w.pending.clearRetainingCapacity();
    }
};

/// The WorkerPool executor for Run(): each frame, the workers handle some
/// messages first, so replies arrive in any order and some jobs stay in
/// flight. When no worker runs, it changes to the Inline executor, as
/// main.zig does.
const WebRun = struct {
    pool: *FakePool,
    web: exec_web.Web,
    fallback: ?exec_inline.Inline = null,

    fn runFrame(self: *WebRun, sched: *Scheduler, world: *World, clock: exec_inline.Clock, deadline: u64) !exec_inline.FrameReport {
        if (self.fallback) |*f| return f.runFrame(sched, world, clock, deadline);
        try self.pool.pump(self.pool.rand.uintLessThan(usize, 12));
        return self.web.runFrame(sched, world, clock, deadline) catch |err| switch (err) {
            error.NoWorkers => {
                self.fallback = try exec_inline.Inline.initFromWorld(std.testing.allocator, world, sched, worker_world.DEFAULT_CACHE_LIMIT);
                return self.fallback.?.runFrame(sched, world, clock, deadline);
            },
            else => |e| return e,
        };
    }

    fn runUntilIdle(self: *WebRun, sched: *Scheduler, world: *World) !void {
        var frames: usize = 0;
        while (true) : (frames += 1) {
            try std.testing.expect(frames < 100_000);
            _ = try self.runFrame(sched, world, zeroClock, 0);
            try sched.plan(world);
            if (sched.isIdle()) return;
            if (self.fallback == null) try self.pool.pump(64);
        }
    }

    fn deinit(self: *WebRun) void {
        if (self.fallback) |*f| f.deinit();
        self.web.deinit();
    }

    fn zeroClock() u64 {
        return 0;
    }
};

const WebFault = enum { none, restart, stop_all };

fn webEquivalence(a: std.mem.Allocator, seed: u64, workers: usize, fault: WebFault) !void {
    const steps = try makeScenario(a, seed);
    defer a.free(steps);
    const config = hilly(seed % 3);
    var prng = std.Random.DefaultPrng.init(seed ^ 0x709);

    var inl = try exec_inline.Inline.init(a, config, worker_world.DEFAULT_CACHE_LIMIT);
    defer inl.deinit();
    var r1: Run(exec_inline.Inline) = .{ .world = try World.init(a, .hilly, R), .sched = Scheduler.init(a, R, .moore, .skylight), .exec = &inl };
    defer r1.world.deinit();
    defer r1.sched.deinit();
    r1.world.gen_config = config;

    var pool = try FakePool.init(a, prng.random(), workers);
    defer pool.deinit();
    var web: WebRun = .{ .pool = &pool, .web = try exec_web.Web.init(a, pool.transport(), config, 8 << 20) };
    defer web.deinit();
    var r2: Run(WebRun) = .{ .world = try World.init(a, .hilly, R), .sched = Scheduler.init(a, R, .moore, .skylight), .exec = &web };
    defer r2.world.deinit();
    defer r2.sched.deinit();
    r2.world.gen_config = config;

    var edits_in_flight: usize = 0;
    for (steps, 0..) |s, i| {
        if (s == .edit and r2.sched.in_flight > 0) edits_in_flight += 1;
        try r1.step(s);
        try r2.step(s);
        switch (fault) {
            .none => {},
            // A worker stops while it has jobs.
            .restart => if (i % 7 == 3) pool.restart(prng.random().uintLessThan(usize, workers)),
            // The workers stop one by one. Then no worker runs.
            .stop_all => if (i % 12 == 11) {
                for (pool.workers, 0..) |w, k| {
                    if (w.alive) {
                        pool.kill(k);
                        break;
                    }
                }
            },
        }
    }
    try inl.runUntilIdle(&r1.sched, &r1.world);
    try web.runUntilIdle(&r2.sched, &r2.world);

    const meshes = try expectSameState(a, &r1.world, &r1.sched, &r2.world, &r2.sched);
    try std.testing.expect(meshes >= 13);
    try std.testing.expect(edits_in_flight > 0);
    try std.testing.expectEqual(@as(u64, 0), web.web.bad_replies);
    switch (fault) {
        .none => try std.testing.expect(web.fallback == null),
        .restart => {
            try std.testing.expect(pool.restarts > 0);
            try std.testing.expect(web.fallback == null);
        },
        .stop_all => try std.testing.expect(web.fallback != null),
    }
    _ = try test_recompute.expectMatchesRecompute(a, &r2.sched, &r2.world);
}

test "exec: web: WorkerPool and Inline give the same bytes, with random edits while jobs run" {
    const a = std.testing.allocator;
    const sizes = [_]usize{ 3, 1, 4 };
    for (sizes, 0..) |n, i| try webEquivalence(a, 0x709 + i, n, .none);
}

test "exec: web: a worker that stops and starts again gives the same bytes" {
    const a = std.testing.allocator;
    const sizes = [_]usize{ 3, 2 };
    for (sizes, 0..) |n, i| try webEquivalence(a, 0x7090 + i, n, .restart);
}

test "exec: web: when no worker runs, the Inline executor takes the jobs" {
    const a = std.testing.allocator;
    try webEquivalence(a, 0x7091, 4, .stop_all);
}

test "exec: web: no live worker gives NoWorkers, and the depth follows the frame" {
    const a = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(1);
    var pool = try FakePool.init(a, prng.random(), 2);
    defer pool.deinit();
    for (pool.workers) |*w| w.alive = false;
    try std.testing.expectError(error.NoWorkers, exec_web.Web.init(a, pool.transport(), hilly(0), 1 << 20));
    // 16.7 ms frames and 1.3 ms jobs: 13 jobs and 1 more.
    try std.testing.expectEqual(@as(usize, 14), exec_web.depthFor(16_700_000, 1_300_000));
    try std.testing.expectEqual(@as(usize, exec_web.JOBS_PER_WORKER), exec_web.depthFor(0, 1_300_000));
    try std.testing.expectEqual(@as(usize, exec_web.JOBS_PER_WORKER), exec_web.depthFor(1_000_000, 4_000_000));
    try std.testing.expectEqual(@as(usize, exec_web.MAX_DEPTH), exec_web.depthFor(100_000_000, 1_000));
}
