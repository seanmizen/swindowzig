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
//!                keeps its blocks.
//!   render       a change of the render distance at runtime.
//!   ready        the loading screen check and the simulation radius.
const std = @import("std");
const stages = @import("pipeline/stages.zig");
const scheduler_mod = @import("pipeline/scheduler.zig");
const exec_inline = @import("pipeline/exec_inline.zig");
const world_mod = @import("world.zig");
const chunk_mod = @import("chunk.zig");

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
        f.* = .{
            .world = try World.init(a, .hilly, r),
            .sched = Scheduler.init(a, r, .moore, .skylight),
            .exec = exec_inline.Inline.init(a),
        };
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

/// Compute the light of each chunk next to a meshed chunk, and each mesh,
/// from the blocks of the World with the stages. The World must have the
/// same light and the same quads.
fn expectMatchesRecompute(a: std.mem.Allocator, f: *Fixture) !void {
    var checked: usize = 0;
    var it = f.world.chunks.valueIterator();
    while (it.next()) |lc_ptr| {
        const lc = lc_ptr.*;
        if (!f.sched.meshCurrent(&f.world, lc)) continue;
        var lights: [stages.SLOTS]stages.ChunkLight = undefined;
        var hood: stages.Neighbourhood = undefined;
        for (0..stages.SLOTS) |s| {
            const dcx, const dcz = stages.offsetOf(s);
            const n = f.world.get(lc.cx + dcx, lc.cz + dcz).?;
            var window: stages.Window = undefined;
            for (0..stages.SLOTS) |t| {
                const ex, const ez = stages.offsetOf(t);
                window[t] = &f.world.get(n.cx + ex, n.cz + ez).?.chunk.blocks;
            }
            lights[s] = try stages.light(a, &window);
            try std.testing.expect(lights[s].sky.eql(&n.chunk.skylight));
            try std.testing.expect(lights[s].block.eql(&n.chunk.block_light));
            hood[s] = .{ .blocks = &n.chunk.blocks, .light = &lights[s] };
        }
        defer for (&lights) |*l| l.deinit(a);
        var want = try stages.mesh(a, &hood, f.sched.ao, f.sched.lighting);
        defer want.deinit(a);
        try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(want.quads), std.mem.sliceAsBytes(lc.mesh.quads.items));
        try std.testing.expectEqual(want.y_min, lc.mesh.y_min);
        try std.testing.expectEqual(want.y_max, lc.mesh.y_max);
        checked += 1;
    }
    try std.testing.expect(checked > 0);
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
    // 3 before 4: a chunk in view comes before a nearer chunk out of view.
    const in_view = indexOf(q, .generate, 4, 0).?;
    const out_of_view = indexOf(q, .generate, -3, 0).?;
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
    // The light of the 3×3 around (2, 0) is stale. The chunks with cx = 1
    // are in the simulation radius (class 1). The others are class 2.
    var stale: usize = 0;
    for (q2, 0..) |j, i| {
        if (j.class != .sim and j.class != .edit) continue;
        try std.testing.expectEqual(scheduler_mod.Stage.light, j.stage);
        try std.testing.expect(@abs(j.cx - 2) <= 1 and @abs(j.cz) <= 1);
        try std.testing.expectEqual(if (j.cx == 1) scheduler_mod.Class.sim else scheduler_mod.Class.edit, j.class);
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
    // An edit in chunk (-4, 0), which has blocks only.
    try std.testing.expect(f.world.get(-4, 0) != null);
    try std.testing.expect(f.world.get(-4, 1) != null);
    try std.testing.expect(try f.sched.editBlock(&f.world, -4 * CHUNK_W + 5, 150, 5, .stone));

    // (-2, 0) is 3 chunks away: out of the mesh disc (R = 2), in the
    // keep disc (R + 1 = 3). The mesh stays.
    try f.move(1, 0);
    try std.testing.expect(f.world.get(-2, 0).?.hasMesh());
    try std.testing.expectEqual(@as(usize, 0), f.sched.evicted.items.len);

    // 4 chunks away: the mesh goes, and main gets the key for the GPU.
    try f.move(2, 0);
    try std.testing.expect(!f.world.get(-2, 0).?.hasMesh());
    var found = false;
    for (f.sched.evicted.items) |k| found = found or (k.cx == -2 and k.cz == 0);
    try std.testing.expect(found);
    // Unedited chunks far away go. The edited chunk keeps its blocks.
    try std.testing.expect(f.world.get(-4, 1) == null);
    const edited = f.world.get(-4, 0).?;
    try std.testing.expect(!edited.hasLight() and !edited.hasMesh());
    try std.testing.expectEqual(chunk_mod.BlockType.stone, f.world.getBlock(-4 * CHUNK_W + 5, 150, 5));

    // Back to 3 chunks away: no mesh again (no flicker at the edge).
    f.sched.evicted.clearRetainingCapacity();
    try f.move(1, 0);
    try std.testing.expect(!f.world.get(-2, 0).?.hasMesh());
    try f.expectDesiredMeshes();

    // Back to the start: the mesh comes back, with the edit.
    try f.move(0, 0);
    try std.testing.expect(f.world.get(-2, 0).?.hasMesh());
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
