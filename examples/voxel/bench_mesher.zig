//! bench_mesher: time the voxel mesher on a fixed world, with no GPU.
//!
//! Where: utils/swindowzig.
//!          zig build bench-mesher -Doptimize=ReleaseFast
//! When:  before and after a change to the mesher, to state the change in
//!        the PR.
//! Why:   the frame benchmark cannot see the mesher, because the async
//!        worker meshes off the main thread. This meshes the same chunks of
//!        the same world every run, so two builds give comparable numbers.
//!
//! It generates a 9×9 area of the hilly preset (seed fixed by world_gen),
//! then meshes each of the inner 7×7 chunks the way the game does: greedy,
//! moore AO, skylight, through the World getter. It repeats this REPS times
//! and prints the median and the minimum time per chunk, and the quad count
//! and a hash of every chunk's packed quads, sorted (the same hash before and
//! after a change means the same quads, in any order).
const std = @import("std");
const world_mod = @import("world.zig");
const mesher_mod = @import("mesher.zig");
const clock = @import("clock.zig");

pub const std_options: std.Options = .{ .log_level = .warn };

const REPS = 5;
const HALF = 4; // generate -HALF..HALF, mesh -(HALF-1)..(HALF-1)

pub fn main(init: std.process.Init) !void {
    clock.io = init.io;
    const allocator = init.gpa;

    var world = try world_mod.World.init(allocator, .hilly, HALF + 1);
    defer world.deinit();
    var cx: i32 = -HALF;
    while (cx <= HALF) : (cx += 1) {
        var cz: i32 = -HALF;
        while (cz <= HALF) : (cz += 1) _ = try world.generateChunk(cx, cz);
    }

    var hash: u64 = 0;
    var rep_ns: [REPS]u64 = undefined;
    var quads: usize = 0;
    var chunks: usize = 0;
    for (&rep_ns) |*out| {
        quads = 0;
        chunks = 0;
        const t0 = clock.nowNs();
        cx = -(HALF - 1);
        while (cx <= HALF - 1) : (cx += 1) {
            var cz: i32 = -(HALF - 1);
            while (cz <= HALF - 1) : (cz += 1) {
                const lc = world.chunks.get(.{ .cx = cx, .cz = cz }).?;
                var mesh = mesher_mod.Mesh.init(allocator);
                defer mesh.deinit();
                try mesher_mod.generateMeshForMode(&lc.chunk, &mesh, lc.worldX(), lc.worldZ(), world.asBlockGetter(), .moore, .skylight, .greedy);
                quads += mesh.indices.items.len / 6;
                chunks += 1;
                if (out == &rep_ns[0]) hash +%= try meshHash(allocator, &mesh, lc.worldX(), lc.worldZ());
            }
        }
        out.* = @intCast(clock.nowNs() - t0);
    }
    // Skylight: compute it again for every generated chunk, REPS times. The
    // hash of the grids shows that a change gives the same values.
    var sky_ns: [REPS]u64 = undefined;
    var sky_hash: u64 = 0;
    var sky_chunks: usize = 0;
    for (&sky_ns, 0..) |*out, r| {
        sky_chunks = 0;
        const t0 = clock.nowNs();
        var it = world.chunks.valueIterator();
        while (it.next()) |lcp| {
            lcp.*.chunk.computeSkylight();
            sky_chunks += 1;
            if (r == 0) sky_hash +%= std.hash.Wyhash.hash(0, std.mem.asBytes(&lcp.*.chunk.skylight));
        }
        out.* = @intCast(clock.nowNs() - t0);
    }
    std.mem.sort(u64, &sky_ns, {}, std.sort.asc(u64));
    std.debug.print("bench_mesher: computeSkylight {d} chunks, hash {x:0>16}, per chunk median {d:.1} us, min {d:.1} us\n", .{
        sky_chunks,
        sky_hash,
        @as(f64, @floatFromInt(sky_ns[REPS / 2])) / @as(f64, @floatFromInt(sky_chunks)) / 1000.0,
        @as(f64, @floatFromInt(sky_ns[0])) / @as(f64, @floatFromInt(sky_chunks)) / 1000.0,
    });

    std.mem.sort(u64, &rep_ns, {}, std.sort.asc(u64));
    const per = struct {
        fn us(ns: u64, n: usize) f64 {
            return @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(n)) / 1000.0;
        }
    }.us;
    std.debug.print("bench_mesher: {d} chunks, {d} quads, hash {x:0>16}, per chunk median {d:.1} us, min {d:.1} us ({d} reps)\n", .{
        chunks, quads, hash, per(rep_ns[REPS / 2], chunks), per(rep_ns[0], chunks), REPS,
    });
}

/// Order-independent hash of a mesh: its packed quads, sorted, then hashed.
fn meshHash(allocator: std.mem.Allocator, mesh: *const mesher_mod.Mesh, ox: i32, oz: i32) !u64 {
    const n = mesh.indices.items.len / 6;
    const packed_quads = try allocator.alloc(mesher_mod.PackedQuad, n);
    defer allocator.free(packed_quads);
    _ = mesher_mod.packQuads(mesh, packed_quads, ox, oz, null, false);
    std.mem.sort(mesher_mod.PackedQuad, packed_quads, {}, struct {
        fn lt(_: void, a: mesher_mod.PackedQuad, b: mesher_mod.PackedQuad) bool {
            for (a, b) |x, y| if (x != y) return x < y;
            return false;
        }
    }.lt);
    return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(packed_quads));
}
