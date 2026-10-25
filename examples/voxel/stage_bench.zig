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
//! The pure stages of pipeline/stages.zig (C2), on the same area:
//!   stage_gen    stages.generate: the blocks only, no light.
//!   light        stages.light: the 44-cell window, skylight and block
//!                light, for the inner 7×7 chunks.
//!   stage_mesh   stages.mesh (moore AO, skylight), for the inner 5×5 chunks.
//!   stage_match  yes when the stages give the blocks, the light and the
//!                quads of World for the same chunks.
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
const stages = @import("pipeline/stages.zig");

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

    // 2b. The pure stages. They run before step 3, which changes the
    // light of World, so that stage_match compares with the World light.
    const st = try benchStages(allocator, &world);

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
    out("target={s} stage_gen_us_per_chunk={d:.1} light_us_per_chunk={d:.1} stage_mesh_us_per_chunk={d:.1} stage_match={s}", .{
        target_name,
        st.gen_us,
        st.light_us,
        st.mesh_us,
        if (st.match) "yes" else "NO",
    });
}

const StageTimes = struct { gen_us: f64, light_us: f64, mesh_us: f64, match: bool };

/// Time the pure stages on the area of `world`, and compare their output
/// with the chunks of `world`.
fn benchStages(allocator: std.mem.Allocator, world: *const world_mod.World) !StageTimes {
    const SIDE = 2 * HALF + 1;
    const at = struct {
        fn f(cx: i32, cz: i32) usize {
            return @intCast((cx + HALF) * SIDE + (cz + HALF));
        }
    }.f;
    var blocks: [SIDE * SIDE]chunk_mod.PalettedBlocks = @splat(.{});
    defer for (&blocks) |*b| b.deinit(allocator);
    var light: [SIDE * SIDE]?stages.ChunkLight = @splat(null);
    defer for (&light) |*l| {
        if (l.*) |*x| x.deinit(allocator);
    };
    var match = true;

    // generate: every chunk of the area.
    var gen_ns: [REPS]u64 = undefined;
    for (&gen_ns) |*o| {
        for (&blocks) |*b| b.deinit(allocator);
        const t0 = nowNs();
        var cx: i32 = -HALF;
        while (cx <= HALF) : (cx += 1) {
            var cz: i32 = -HALF;
            while (cz <= HALF) : (cz += 1) blocks[at(cx, cz)] = try stages.generate(allocator, world.gen_config.seed, world.gen_config, cx, cz);
        }
        o.* = nowNs() - t0;
    }
    for (&blocks, 0..) |*b, i| {
        const cx: i32 = @as(i32, @intCast(i / SIDE)) - HALF;
        const cz: i32 = @as(i32, @intCast(i % SIDE)) - HALF;
        const want = &world.chunks.get(.{ .cx = cx, .cz = cz }).?.chunk.blocks;
        for (0..chunk_mod.BLOCKS_PER_CHUNK) |k| {
            if (want.get(k) != b.get(k)) match = false;
        }
    }

    // light: the inner chunks, which have their 3×3 neighbourhood.
    const L = HALF - 1;
    var light_ns: [REPS]u64 = undefined;
    for (&light_ns) |*o| {
        const t0 = nowNs();
        var cx: i32 = -L;
        while (cx <= L) : (cx += 1) {
            var cz: i32 = -L;
            while (cz <= L) : (cz += 1) {
                var w: stages.Window = undefined;
                for (0..stages.SLOTS) |s| {
                    const dcx, const dcz = stages.offsetOf(s);
                    w[s] = &blocks[at(cx + dcx, cz + dcz)];
                }
                if (light[at(cx, cz)]) |*old| old.deinit(allocator);
                light[at(cx, cz)] = try stages.light(allocator, &w);
            }
        }
        o.* = nowNs() - t0;
    }
    // World has all 3×3 neighbours of the inner chunks: the same light.
    {
        var cx: i32 = -L;
        while (cx <= L) : (cx += 1) {
            var cz: i32 = -L;
            while (cz <= L) : (cz += 1) {
                const want = &world.chunks.get(.{ .cx = cx, .cz = cz }).?.chunk;
                const got = &light[at(cx, cz)].?;
                for (0..chunk_mod.CHUNK_W) |x| for (0..chunk_mod.CHUNK_H) |y| for (0..chunk_mod.CHUNK_W) |z| {
                    if (want.skylight.get(x, y, z) != got.sky.get(x, y, z)) match = false;
                    if (want.block_light.get(x, y, z) != got.block.get(x, y, z)) match = false;
                };
            }
        }
    }

    // mesh: the chunks whose 3×3 neighbours have light.
    const M = HALF - 2;
    const n_mesh: usize = (2 * M + 1) * (2 * M + 1);
    var mesh_ns: [REPS]u64 = undefined;
    for (&mesh_ns, 0..) |*o, r| {
        var t: u64 = 0;
        var cx: i32 = -M;
        while (cx <= M) : (cx += 1) {
            var cz: i32 = -M;
            while (cz <= M) : (cz += 1) {
                var hood: stages.Neighbourhood = undefined;
                for (0..stages.SLOTS) |s| {
                    const dcx, const dcz = stages.offsetOf(s);
                    hood[s] = .{ .blocks = &blocks[at(cx + dcx, cz + dcz)], .light = &light[at(cx + dcx, cz + dcz)].? };
                }
                const t0 = nowNs();
                var m = try stages.mesh(allocator, &hood, .moore, .skylight);
                defer m.deinit(allocator);
                t += nowNs() - t0;
                if (r == 0) {
                    // The World mesh of the same chunk.
                    const lc = world.chunks.get(.{ .cx = cx, .cz = cz }).?;
                    var want = mesher_mod.Mesh.init(allocator);
                    defer want.deinit();
                    try mesher_mod.generateMesh(&lc.chunk, &want, lc.worldX(), lc.worldZ(), world.asBlockGetter(), .moore, .skylight);
                    if (!std.mem.eql(u8, std.mem.sliceAsBytes(want.quads.items), std.mem.sliceAsBytes(m.quads))) match = false;
                }
            }
        }
        o.* = t;
    }

    return .{
        .gen_us = us(median(&gen_ns), SIDE * SIDE),
        .light_us = us(median(&light_ns), (2 * L + 1) * (2 * L + 1)),
        .mesh_us = us(median(&mesh_ns), n_mesh),
        .match = match,
    };
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
