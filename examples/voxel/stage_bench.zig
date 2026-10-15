//! stage_bench: time each chunk stage, native and wasm, and print three
//! terrain hashes to compare the two platforms.
//!
//! Where: utils/swindowzig.
//!          zig build bench-stages -Doptimize=ReleaseFast
//!          zig build bench-stages-wasm -Doptimize=ReleaseFast
//!          node examples/voxel/scripts/bench_stages.mjs zig-out/bin/stage_bench.wasm
//! When:  before and after a change to terrain generation, lighting or the
//!        mesher, to state the change in the PR.
//! Why:   the web build runs the chunk stages in wasm, and wasm costs differ
//!        from native costs. This runs the same work on the same 9×9 hilly
//!        area on both platforms.
//!
//! Stages (each the median of REPS runs, in µs per chunk):
//!   gen      World.generateChunk: terrain, skylight, block light and seams.
//!   terrain  Chunk.generateTerrain alone (no seam relight).
//!   mesh     greedy mesh, moore AO, skylight, of the inner 7×7 chunks.
//!   sky      Chunk.computeSkylight alone.
//!   relight  the work of World.relightChunk with both channels (skylight
//!            and block light, seeded from the 4 face neighbours), for the
//!            inner 7×7 chunks.
//!
//! Hashes (identical on every platform, and before and after a change that
//! must not change the terrain):
//!   block_hash  every block of every chunk, by chunk, in y, x, z order.
//!   sky_hash    the dense skylight of each chunk after computeSkylight.
//!   quad_hash   the sorted packed quads of each meshed chunk (as bench_mesher).
const std = @import("std");
const builtin = @import("builtin");
const world_mod = @import("world.zig");
const chunk_mod = @import("chunk.zig");
const mesher_mod = @import("mesher.zig");
const clock = @import("clock.zig");

const is_wasm = builtin.cpu.arch == .wasm32;
const target_name = if (is_wasm) "wasm" else "native";
const REPS = 5;
const HALF = 4; // generate -HALF..HALF, mesh -(HALF-1)..(HALF-1)

pub const std_options: std.Options = .{ .logFn = genLog, .log_level = if (is_wasm) .err else .info };
fn genLog(comptime _: std.log.Level, comptime _: @TypeOf(.enum_literal), comptime fmt: []const u8, args: anytype) void {
    if (comptime is_wasm) return;
    if (comptime std.mem.startsWith(u8, fmt, "[GEN]")) std.debug.print(fmt ++ "\n", args);
}

/// wasm imports. bench_stages.mjs supplies them.
extern fn benchNowMs() f64;
extern fn benchLog(ptr: [*]const u8, len: u32) void;

fn nowNs() u64 {
    if (comptime is_wasm) return @intFromFloat(benchNowMs() * 1_000_000.0);
    return @intCast(clock.nowNs());
}

fn out(comptime fmt: []const u8, args: anytype) void {
    if (comptime is_wasm) {
        var buf: [512]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
        benchLog(s.ptr, @intCast(s.len));
    } else {
        std.debug.print(fmt ++ "\n", args);
    }
}

fn median(xs: *[REPS]u64) u64 {
    std.mem.sort(u64, xs, {}, std.sort.asc(u64));
    return xs[REPS / 2];
}

fn us(ns: u64, n: usize) f64 {
    return @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(n)) / 1000.0;
}

fn bench(allocator: std.mem.Allocator) !void {
    const n_gen: usize = (2 * HALF + 1) * (2 * HALF + 1);

    // 1. Generation: generateChunk does terrain, skylight, block light and seams.
    var gen_ns: [REPS]u64 = undefined;
    var world: world_mod.World = undefined;
    for (&gen_ns, 0..) |*o, r| {
        if (r > 0) world.deinit();
        world = try world_mod.World.init(allocator, .hilly, HALF + 1);
        const t0 = nowNs();
        var cx: i32 = -HALF;
        while (cx <= HALF) : (cx += 1) {
            var cz: i32 = -HALF;
            while (cz <= HALF) : (cz += 1) _ = try world.generateChunk(cx, cz);
        }
        o.* = nowNs() - t0;
    }
    defer world.deinit();

    // 1b. generateTerrain alone: terrain, caves, trees, skylight and block light, with no seams.
    var terr_ns: [REPS]u64 = undefined;
    for (&terr_ns) |*o| {
        const t0 = nowNs();
        var cx: i32 = -HALF;
        while (cx <= HALF) : (cx += 1) {
            var cz: i32 = -HALF;
            while (cz <= HALF) : (cz += 1) {
                var ch = chunk_mod.Chunk.init(allocator);
                defer ch.deinit();
                try ch.generateTerrain(cx, cz, world.gen_config);
            }
        }
        o.* = nowNs() - t0;
    }

    // Terrain hash: every block of every chunk, in a fixed order.
    var block_hash: u64 = 0;
    {
        var cx: i32 = -HALF;
        while (cx <= HALF) : (cx += 1) {
            var cz: i32 = -HALF;
            while (cz <= HALF) : (cz += 1) {
                const lc = world.chunks.get(.{ .cx = cx, .cz = cz }).?;
                var h = std.hash.Wyhash.init(@bitCast(@as(i64, cx) *% 31 +% cz));
                var y: i32 = 0;
                while (y < chunk_mod.CHUNK_H) : (y += 1) {
                    var x: i32 = 0;
                    while (x < chunk_mod.CHUNK_W) : (x += 1) {
                        var z: i32 = 0;
                        while (z < chunk_mod.CHUNK_W) : (z += 1) {
                            const b: u8 = @backingInt(lc.chunk.getBlock(x, y, z));
                            h.update(&[_]u8{b});
                        }
                    }
                }
                block_hash +%= h.final();
            }
        }
    }

    // 2. Mesh the inner chunks (greedy, moore AO, skylight), as bench_mesher.
    var mesh_ns: [REPS]u64 = undefined;
    var quad_hash: u64 = 0;
    var quads: usize = 0;
    var n_mesh: usize = 0;
    for (&mesh_ns, 0..) |*o, r| {
        quads = 0;
        n_mesh = 0;
        const t0 = nowNs();
        var cx: i32 = -(HALF - 1);
        while (cx <= HALF - 1) : (cx += 1) {
            var cz: i32 = -(HALF - 1);
            while (cz <= HALF - 1) : (cz += 1) {
                const lc = world.chunks.get(.{ .cx = cx, .cz = cz }).?;
                var mesh = mesher_mod.Mesh.init(allocator);
                defer mesh.deinit();
                try mesher_mod.generateMesh(&lc.chunk, &mesh, lc.worldX(), lc.worldZ(), world.asBlockGetter(), .moore, .skylight);
                quads += mesh.quadCount();
                n_mesh += 1;
                if (r == 0) quad_hash +%= try meshHash(allocator, &mesh);
            }
        }
        o.* = nowNs() - t0;
    }

    // 3. Skylight alone, for every generated chunk.
    var sky_ns: [REPS]u64 = undefined;
    var sky_hash: u64 = 0;
    for (&sky_ns, 0..) |*o, r| {
        const t0 = nowNs();
        var it = world.chunks.valueIterator();
        while (it.next()) |lcp| {
            try lcp.*.chunk.computeSkylight();
            if (r == 0) {
                var dense: chunk_mod.DenseLight = undefined;
                lcp.*.chunk.skylight.expand(&dense);
                sky_hash +%= std.hash.Wyhash.hash(0, std.mem.asBytes(&dense));
            }
        }
        o.* = nowNs() - t0;
    }

    // 4. Relight, as World.relightChunk does it with both channels. It runs
    // last, because it changes the light that the hashes above read.
    var relight_ns: [REPS]u64 = undefined;
    for (&relight_ns) |*o| {
        const t0 = nowNs();
        var cx: i32 = -(HALF - 1);
        while (cx <= HALF - 1) : (cx += 1) {
            var cz: i32 = -(HALF - 1);
            while (cz <= HALF - 1) : (cz += 1) {
                const lc = world.chunks.get(.{ .cx = cx, .cz = cz }).?;
                const xn = world.chunkAt(cx - 1, cz);
                const xp = world.chunkAt(cx + 1, cz);
                const zn = world.chunkAt(cx, cz - 1);
                const zp = world.chunkAt(cx, cz + 1);
                try lc.chunk.computeSkylightWithNeighbors(xn, xp, zn, zp);
                try lc.chunk.computeBlockLightWithNeighbors(xn, xp, zn, zp);
            }
        }
        o.* = nowNs() - t0;
    }

    out("target={s} gen_us_per_chunk={d:.1} terrain_us_per_chunk={d:.1} sky_us_per_chunk={d:.1} relight_us_per_chunk={d:.1} mesh_us_per_chunk={d:.1} quads={d}", .{
        target_name,
        us(median(&gen_ns), n_gen),
        us(median(&terr_ns), n_gen),
        us(median(&sky_ns), n_gen),
        us(median(&relight_ns), n_mesh),
        us(median(&mesh_ns), n_mesh),
        quads,
    });
    out("target={s} block_hash={x:0>16} sky_hash={x:0>16} quad_hash={x:0>16}", .{
        target_name, block_hash, sky_hash, quad_hash,
    });
}

fn meshHash(allocator: std.mem.Allocator, mesh: *const mesher_mod.Mesh) !u64 {
    const packed_quads = try allocator.dupe(mesher_mod.PackedQuad, mesh.quads.items);
    defer allocator.free(packed_quads);
    std.mem.sort(mesher_mod.PackedQuad, packed_quads, {}, struct {
        fn lt(_: void, a: mesher_mod.PackedQuad, b: mesher_mod.PackedQuad) bool {
            for (a, b) |x, y| if (x != y) return x < y;
            return false;
        }
    }.lt);
    return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(packed_quads));
}

/// wasm entry. Returns 0 on success and 1 on an error.
export fn benchRun() u32 {
    if (comptime !is_wasm) return 0;
    bench(std.heap.wasm_allocator) catch return 1;
    return 0;
}

fn mainNative(init: std.process.Init) !void {
    clock.io = init.io;
    try bench(init.gpa);
}
fn mainWasm() void {}
pub const main = if (is_wasm) mainWasm else mainNative;
