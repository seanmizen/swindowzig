//! Tests of the chunk scheduler (pipeline/scheduler.zig) and the Inline
//! executor (pipeline/exec_inline.zig): C3, C6, C8.
//!
//! The root of this test is here, next to world.zig, because a module can
//! import only files under the directory of its root.
//!
//!   priority     the queue order of C8.
//!   stale        a result with old input versions is discarded and queued
//!                again, and the final state equals a recompute.
//!   hysteresis   a mesh stays to R + 1 and goes past it. An edited chunk
//!                keeps its version, and its blocks come back with the edit.
//!   render       a change of the render distance at runtime.
//!   ready        the loading screen check and the simulation radius.
const std = @import("std");
/// The demo world of the tests and the tools: the hilly preset.
const hilly_config = @import("voxel_content").world_gen.presetConfig(.hilly);
const stages = @import("sw_voxel").stages;
const scheduler_mod = @import("sw_voxel").scheduler;
const exec_inline = @import("sw_voxel").exec_inline;
const worker_world = @import("sw_voxel").worker_world;
const world_mod = @import("sw_voxel").world;
const chunk_mod = @import("sw_voxel").chunk;
const test_recompute = @import("test_recompute.zig");

const Scheduler = scheduler_mod.Scheduler;
const Region = scheduler_mod.Region;
const Job = scheduler_mod.Job;
const World = world_mod.World;
const CHUNK_W = chunk_mod.CHUNK_W;

const Fixture = struct {
    world: World,
    sched: Scheduler,
    exec: exec_inline.Inline,

    fn init(a: std.mem.Allocator, r: i32) !*Fixture {
        const f = try a.create(Fixture);
        errdefer a.destroy(f);
        f.world = try World.init(a, hilly_config, r);
        errdefer f.world.deinit();
        f.sched = Scheduler.init(a, r, .moore, .skylight);
        f.exec = try exec_inline.Inline.init(a, f.world.gen_config, worker_world.DEFAULT_CACHE_LIMIT);
        return f;
    }

    fn deinit(f: *Fixture, a: std.mem.Allocator) void {
        f.exec.deinit();
        f.sched.deinit();
        f.world.deinit();
        a.destroy(f);
    }

    fn idle(f: *Fixture) !void {
        try f.exec.runUntilIdle(&f.sched, &f.world);
    }

    fn move(f: *Fixture, cx: i32, cz: i32) !void {
        f.sched.setCenter(cx, cz);
        try f.idle();
    }

    fn meshCount(f: *const Fixture) usize {
        var n: usize = 0;
        var it = f.world.chunks.valueIterator();
        while (it.next()) |lc| {
            if (lc.*.hasMesh()) n += 1;
        }
        return n;
    }

    /// Each chunk that needs a mesh at the center has a current mesh.
    fn expectDesiredMeshes(f: *const Fixture) !void {
        const r = f.sched.render_distance;
        var dz: i32 = -r;
        while (dz <= r) : (dz += 1) {
            var dx: i32 = -r;
            while (dx <= r) : (dx += 1) {
                if (!Region.mesh(dx, dz, r)) continue;
                const lc = f.world.get(f.sched.center_cx + dx, f.sched.center_cz + dz).?;
                try std.testing.expect(f.sched.meshCurrent(&f.world, lc));
            }
        }
    }
};

/// The index of the job (stage, cx, cz) in the queue, or null.
fn indexOf(queue: []const Job, stage: scheduler_mod.Stage, cx: i32, cz: i32) ?usize {
    for (queue, 0..) |j, i| {
        if (j.stage == stage and j.cx == cx and j.cz == cz) return i;
    }
    return null;
}

/// A view that sees the chunks with cx > 0.
fn eastVisible(_: *const anyopaque, cx: i32, _: i32) bool {
    return cx > 0;
}

/// Each current light and mesh of the World must be the result of a
/// recompute from scratch: generate, the edit log, light and mesh.
fn expectMatchesRecompute(a: std.mem.Allocator, f: *Fixture) !void {
    _ = try test_recompute.expectMatchesRecompute(a, &f.sched, &f.world);
}

test "scheduler: the regions have one band of hysteresis" {
    // R = 2: mesh to d² <= 4, light one chunk more, blocks two more.
    try std.testing.expect(Region.mesh(2, 0, 2));
    try std.testing.expect(!Region.mesh(2, 1, 2));
    try std.testing.expect(Region.light(3, 0, 2));
    try std.testing.expect(Region.light(3, 1, 2));
    try std.testing.expect(!Region.light(4, 0, 2));
    try std.testing.expect(Region.blocks(4, 0, 2));
    try std.testing.expect(!Region.blocks(5, 0, 2));
    // The simulation radius always has blocks.
    try std.testing.expect(Region.blocks(1, 1, 0));
    try std.testing.expect(Region.sim(-1, 1));
    try std.testing.expect(!Region.sim(2, 0));
}

test "scheduler: jobs run in priority order" {
    const a = std.testing.allocator;
    const f = try Fixture.init(a, 3);
    defer f.deinit(a);
    const dummy: u8 = 0;
    f.sched.view = .{ .ctx = &dummy, .visibleFn = eastVisible };

    // An empty World: each job is a generate.
    try f.sched.plan(&f.world);
    const q = f.sched.queue.items;
    // 1. The simulation radius comes first, nearest first.
    for (q[0..9]) |j| {
        try std.testing.expectEqual(scheduler_mod.Class.sim, j.class);
        try std.testing.expect(Region.sim(j.cx, j.cz));
    }
    try std.testing.expectEqual(@as(i32, 0), q[0].dist_sq);
    // The classes do not go back, and in a class the distance does not go down.
    for (q[1..], q[0 .. q.len - 1]) |j, prev| {
        try std.testing.expect(@backingInt(j.class) >= @backingInt(prev.class));
        if (j.class == prev.class) try std.testing.expect(j.dist_sq >= prev.dist_sq);
    }
    // 3 before 4: a chunk in view comes before a chunk out of view at the
    // same distance. The blocks to 4 chunks from the player feed the
    // simulation radius, so these chunks are 5 chunks away.
    const in_view = indexOf(q, .generate, 5, 0).?;
    const out_of_view = indexOf(q, .generate, -5, 0).?;
    try std.testing.expectEqual(scheduler_mod.Class.view, q[in_view].class);
    try std.testing.expectEqual(scheduler_mod.Class.other, q[out_of_view].class);
    try std.testing.expect(in_view < out_of_view);

    // 2. After an edit, the remesh work comes before new chunks. Edit the
    // middle of chunk (2, 0), and make the render distance larger.
    try f.idle();
    try std.testing.expect(try f.sched.editBlock(&f.world, 2 * CHUNK_W + 8, 200, 8, .stone));
    f.sched.setRenderDistance(&f.world, 4);
    try f.sched.plan(&f.world);
    const q2 = f.sched.queue.items;
    // The light of the 3×3 around (2, 0) is stale. The chunks with cx <= 2
    // give light to the meshes of the simulation radius (class 1). The
    // others are class 2.
    var stale: usize = 0;
    for (q2, 0..) |j, i| {
        if (j.class != .sim and j.class != .edit) continue;
        try std.testing.expectEqual(scheduler_mod.Stage.light, j.stage);
        try std.testing.expect(@abs(j.cx - 2) <= 1 and @abs(j.cz) <= 1);
        try std.testing.expectEqual(if (j.cx <= 2) scheduler_mod.Class.sim else scheduler_mod.Class.edit, j.class);
        try std.testing.expectEqual(stale, i);
        stale += 1;
    }
    try std.testing.expectEqual(@as(usize, 9), stale);
    const edits = stale;
    // New chunks for R = 4 are in the queue, after the edit work.
    try std.testing.expect(indexOf(q2, .generate, 6, 0).? >= edits);
    try f.idle();
    try expectMatchesRecompute(a, f);
}

test "scheduler: a stale result is discarded and queued again" {
    const a = std.testing.allocator;
    const f = try Fixture.init(a, 2);
    defer f.deinit(a);
    try f.idle();
    try expectMatchesRecompute(a, f);

    // An edit in the middle of chunk (1, 0). The neighbour meshes read 3
    // cells into (1, 0) only, so they stay current. The neighbour lights
    // read 14 cells, so they become stale.
    const wx = CHUNK_W + 8;
    try std.testing.expect(try f.sched.editBlock(&f.world, wx, 120, 8, .glowstone));
    try std.testing.expect(f.sched.meshCurrent(&f.world, f.world.get(0, 0).?));
    try std.testing.expect(!scheduler_mod.Scheduler.lightCurrent(&f.world, f.world.get(0, 0).?));

    // Start the light job of (1, 0), then edit (1, 0) again before the
    // result installs.
    try f.sched.plan(&f.world);
    var job: ?Job = null;
    while (f.sched.next(&f.world)) |j| {
        if (j.stage == .light and j.cx == 1 and j.cz == 0) {
            job = j;
            break;
        }
    }
    var result = try f.exec.run(&f.sched, &f.world, job.?);
    try std.testing.expect(try f.sched.editBlock(&f.world, wx, 121, 8, .glowstone));
    try std.testing.expectEqual(Scheduler.Outcome.discarded, try f.sched.install(&f.world, &result));
    try std.testing.expectEqual(@as(u64, 1), f.sched.stats.discarded[@backingInt(scheduler_mod.Stage.light)]);
    try std.testing.expectEqual(@as(usize, 0), f.sched.in_flight);

    // The next plan queues the job again.
    try f.sched.plan(&f.world);
    try std.testing.expect(indexOf(f.sched.queue.items, .light, 1, 0) != null);
    try f.idle();
    try std.testing.expectEqual(chunk_mod.BlockType.glowstone, f.world.getBlock(wx, 121, 8));
    try expectMatchesRecompute(a, f);
    try f.expectDesiredMeshes();
}

test "scheduler: eviction has hysteresis" {
    const a = std.testing.allocator;
    const f = try Fixture.init(a, 2);
    defer f.deinit(a);
    try f.idle();
    try std.testing.expect(f.world.get(-2, 0).?.hasMesh());
    // Main has no blocks out of the prefetch radius (C6).
    try std.testing.expect(f.world.get(-4, 0) != null);
    try std.testing.expect(!f.world.get(-4, 0).?.has_blocks);
    try std.testing.expect(!try f.sched.editBlock(&f.world, -4 * CHUNK_W + 5, 150, 5, .stone));
    // An edit in chunk (-4, 0), from a player near it.
    try f.move(-2, 0);
    try std.testing.expect(f.world.get(-4, 0).?.has_blocks);
    try std.testing.expect(try f.sched.editBlock(&f.world, -4 * CHUNK_W + 5, 150, 5, .stone));
    try f.move(0, 0);
    // Back at the start, (-4, 0) has no mesh, and main dropped its blocks.
    try std.testing.expect(!f.world.get(-4, 0).?.hasMesh());
    try std.testing.expect(!f.world.get(-4, 0).?.has_blocks);
    try std.testing.expect(f.world.get(-4, 1) != null);
    f.sched.evicted.clearRetainingCapacity();

    // (-2, 0) is 3 chunks away: out of the mesh disc (R = 2), in the
    // keep disc (R + 1 = 3). The mesh stays.
    try f.move(1, 0);
    try std.testing.expect(f.world.get(-2, 0).?.hasMesh());
    for (f.sched.evicted.items) |k| try std.testing.expect(!(k.cx == -2 and k.cz == 0));

    // 4 chunks away: the mesh goes, and main gets the key for the GPU.
    try f.move(2, 0);
    try std.testing.expect(!f.world.get(-2, 0).?.hasMesh());
    var found = false;
    for (f.sched.evicted.items) |k| found = found or (k.cx == -2 and k.cz == 0);
    try std.testing.expect(found);
    // Unedited chunks far away go. The edited chunk keeps its version.
    // Its blocks are in the edit log and in the worker (C4).
    try std.testing.expect(f.world.get(-4, 1) == null);
    const edited = f.world.get(-4, 0).?;
    try std.testing.expect(!edited.hasLight() and !edited.hasMesh() and !edited.has_blocks);
    try std.testing.expectEqual(@as(stages.Version, 1), edited.block_ver);
    try std.testing.expectEqual(@as(stages.Version, 1), f.world.editVersion(-4, 0));

    // Back to 3 chunks away: no mesh again (no flicker at the edge).
    f.sched.evicted.clearRetainingCapacity();
    try f.move(1, 0);
    try std.testing.expect(!f.world.get(-2, 0).?.hasMesh());
    try f.expectDesiredMeshes();

    // Back to the start: the mesh comes back, with the edit.
    try f.move(0, 0);
    try std.testing.expect(f.world.get(-2, 0).?.hasMesh());
    try expectMatchesRecompute(a, f);
    // Near the edited chunk, main gets its blocks from the worker, with
    // the edit (C6).
    try f.move(-3, 0);
    try std.testing.expect(f.world.get(-4, 0).?.has_blocks);
    try std.testing.expectEqual(chunk_mod.BlockType.stone, f.world.getBlock(-4 * CHUNK_W + 5, 150, 5));
    try expectMatchesRecompute(a, f);
}

test "scheduler: the render distance changes at runtime" {
    const a = std.testing.allocator;
    const f = try Fixture.init(a, 1);
    defer f.deinit(a);
    try f.idle();
    // The disc of radius 1 has 5 chunks.
    try std.testing.expectEqual(@as(usize, 5), f.meshCount());
    f.sched.setRenderDistance(&f.world, 3);
    try std.testing.expectEqual(@as(i32, 3), f.world.render_distance);
    try f.idle();
    try std.testing.expectEqual(@as(usize, 29), f.meshCount());
    try f.expectDesiredMeshes();
    // Smaller: the meshes out of the disc of R + 1 = 2 go (13 stay).
    f.sched.setRenderDistance(&f.world, 1);
    try f.idle();
    try std.testing.expectEqual(@as(usize, 13), f.meshCount());
    try f.expectDesiredMeshes();
    // A change of the mesh options makes each mesh stale.
    f.sched.setMeshOptions(.classic, .skylight);
    try std.testing.expect(!f.sched.meshCurrent(&f.world, f.world.get(0, 0).?));
    try f.idle();
    try f.expectDesiredMeshes();
    try expectMatchesRecompute(a, f);
}

test "scheduler: the ready check and the simulation radius" {
    const a = std.testing.allocator;
    const f = try Fixture.init(a, 2);
    defer f.deinit(a);
    f.sched.setCenter(5, -3);
    try std.testing.expect(!f.sched.isReady(&f.world, 1));
    // C6: the simulation radius gets its blocks inline.
    try std.testing.expectEqual(@as(usize, 9), try f.sched.ensureSimRadius(&f.world, 5, -3));
    try std.testing.expectEqual(@as(usize, 0), try f.sched.ensureSimRadius(&f.world, 5, -3));
    try std.testing.expect(!f.sched.isReady(&f.world, 1));
    try f.idle();
    try std.testing.expect(f.sched.isReady(&f.world, 1));
    try std.testing.expect(f.sched.isReady(&f.world, 99));
    try std.testing.expect(f.sched.isIdle());
    // The inline blocks are the blocks of the generate stage.
    var want = try stages.generate(a, 0, f.world.gen_config, 5, -3);
    defer want.deinit(a);
    const have = &f.world.get(5, -3).?.chunk.blocks;
    for (0..chunk_mod.BLOCKS_PER_CHUNK) |i| try std.testing.expectEqual(want.get(i), have.get(i));
}

/// A clock that moves one tick at each read. The Inline executor reads it
/// four times for each job, so a budget of 4 * n ticks runs about n jobs.
var ticks: u64 = 0;
fn countingClock() u64 {
    ticks += 1;
    return ticks;
}

test "scheduler: a fast camera leaves no long hole near the player (REQ-VOXEL-018)" {
    const a = std.testing.allocator;
    const r = 4;
    const f = try Fixture.init(a, r);
    defer f.deinit(a);
    try f.idle();
    // The camera moves one chunk east every 2 frames, and each frame runs
    // about 12 jobs: less than all the work of the render distance, so the
    // far chunks fall behind. A hole is a chunk in the 3 by 3 square around
    // the player with no current mesh. The light and the blocks ahead of
    // the square have the class of the simulation, so a hole stays short.
    // With fewer than 10 jobs each frame, the holes get longer.
    const jobs_per_frame = 12;
    const max_hole_frames = 2;
    var hole: [3][3]u32 = @splat(@splat(0));
    var worst: u32 = 0;
    var frame: i32 = 0;
    while (frame < 60) : (frame += 1) {
        const cx = @divTrunc(frame, 2);
        f.sched.setCenter(cx, 0);
        _ = try f.exec.runFrame(&f.sched, &f.world, countingClock, ticks + 4 * jobs_per_frame);
        for (0..3) |i| for (0..3) |j| {
            const x = cx + @as(i32, @intCast(i)) - 1;
            const z = @as(i32, @intCast(j)) - 1;
            const meshed = if (f.world.get(x, z)) |lc| f.sched.meshCurrent(&f.world, lc) else false;
            hole[i][j] = if (meshed) 0 else hole[i][j] + 1;
            worst = @max(worst, hole[i][j]);
        };
    }
    try std.testing.expect(worst <= max_hole_frames);
    try f.idle();
    try f.expectDesiredMeshes();
}

test "scheduler: far chunks get a mesh at their level of detail (REQ-VOXEL-021)" {
    const a = std.testing.allocator;
    const r = 9;
    const f = try Fixture.init(a, r);
    defer f.deinit(a);
    try f.idle();
    // The quads of the full mesh of each chunk.
    var full: std.AutoHashMapUnmanaged([2]i32, u32) = .empty;
    defer full.deinit(a);
    var it = f.world.chunks.valueIterator();
    while (it.next()) |lc| {
        if (lc.*.hasMesh()) try full.put(a, .{ lc.*.cx, lc.*.cz }, lc.*.mesh.quad_count);
    }

    // Level 1 past 2 chunks, level 2 past 4, level 3 past 8.
    f.sched.setLodDistance(2);
    try std.testing.expectEqual(@as(u8, 0), f.sched.lodLevel(2, 0));
    try std.testing.expectEqual(@as(u8, 1), f.sched.lodLevel(3, 0));
    try std.testing.expectEqual(@as(u8, 2), f.sched.lodLevel(3, 3));
    try std.testing.expectEqual(@as(u8, 3), f.sched.lodLevel(9, 0));
    try f.idle();
    try f.expectDesiredMeshes();
    // The quads of each level, and the quads of the full meshes of the
    // same chunks.
    var levels: [4]usize = @splat(0);
    var lod_quads: [4]u64 = @splat(0);
    var full_quads: [4]u64 = @splat(0);
    it = f.world.chunks.valueIterator();
    while (it.next()) |lc| {
        if (!lc.*.hasMesh()) continue;
        const l = lc.*.mesh_lod;
        levels[l] += 1;
        lod_quads[l] += lc.*.mesh.quad_count;
        full_quads[l] += full.get(.{ lc.*.cx, lc.*.cz }).?;
        // A full mesh near a level border can stay (the hysteresis).
        const want = f.sched.lodLevel(lc.*.cx, lc.*.cz);
        try std.testing.expect(lc.*.mesh_lod <= want and lc.*.mesh_lod + 1 >= want);
    }
    for (levels) |n| try std.testing.expect(n > 0);
    try std.testing.expectEqual(full_quads[0], lod_quads[0]);
    // Measured on the hilly preset: 2.2, 4.4 and 8.7 times fewer quads.
    for (1..4) |l| try std.testing.expect(lod_quads[l] * (l + 1) < full_quads[l]);
    // Each mesh is the mesh of a recompute at its level.
    try expectMatchesRecompute(a, f);

    // One chunk of movement: the hysteresis keeps the levels, so no mesh
    // job runs.
    const meshed = f.sched.stats.installed[@backingInt(scheduler_mod.Stage.mesh)];
    try f.move(1, 0);
    try f.move(0, 0);
    try f.move(1, 0);
    const after_small = f.sched.stats.installed[@backingInt(scheduler_mod.Stage.mesh)];
    // The chunks that come into the render distance get meshes, and no
    // other chunk remeshes.
    try std.testing.expect(after_small - meshed < 2 * (2 * r + 1));

    // A long move: the levels follow the player.
    try f.move(6, 0);
    try f.expectDesiredMeshes();
    try std.testing.expectEqual(@as(u8, 0), f.world.get(6, 0).?.mesh_lod);
    try expectMatchesRecompute(a, f);

    // Off: each chunk in the render distance gets the full mesh again.
    // The meshes in the band of the hysteresis stay until they go.
    f.sched.setLodDistance(0);
    try f.idle();
    try f.expectDesiredMeshes();
    it = f.world.chunks.valueIterator();
    while (it.next()) |lc| {
        if (lc.*.hasMesh() and Region.mesh(lc.*.cx - 6, lc.*.cz, r)) try std.testing.expectEqual(@as(u8, 0), lc.*.mesh_lod);
    }
    try expectMatchesRecompute(a, f);
}
