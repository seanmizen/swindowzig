//! terrain_hash: the block hash of a 9×9 area of hilly terrain, for a seed.
//!
//! Where: utils/swindowzig.
//!          zig build terrain-hash -Doptimize=ReleaseFast
//!          ./zig-out/bin/terrain_hash 0 1 12345
//!          node examples/voxel/scripts/terrain_hash_wasm.mjs 0 1 12345
//!        terrain_hash_wasm.zig is the root of the wasm build.
//! Why:   terrain must be identical on every platform and in every engine.
//!        The native build and the wasm build print the same lines for the
//!        same seeds. CI compares them. The tests below pin the hash of
//!        seed 0 and check that seed 1 gives a different hash.
//!
//! The hash: for each chunk (cx, cz) in -4..4 (inclusive), start a Wyhash
//! with the key cx*31 + cz. Feed it each block as one byte, in y, x, z order.
//! Add the final value of each chunk to the total (wrapping add). The order
//! of the chunks does not change the total.
const std = @import("std");
const world_mod = @import("world.zig");
const chunk_mod = @import("chunk.zig");

/// Generation logs at info level for each chunk. This tool prints only its
/// hash lines.
pub const std_options: std.Options = .{ .log_level = .warn };

/// The area is -HALF..HALF chunks on each axis: 9×9 chunks.
pub const HALF: i32 = 4;

/// The block hash of seed 0 (the terrain before the seed existed). Measured
/// on native x86_64, V8 and JSC on 2026-10-15.
pub const SEED0_BLOCK_HASH: u64 = 0xdb5d8508a4c6cd54;

/// Generate the 9×9 hilly area for `seed` and return its block hash.
pub fn blockHash(allocator: std.mem.Allocator, seed: u64) !u64 {
    var world = try world_mod.World.init(allocator, .hilly, HALF + 1);
    defer world.deinit();
    world.gen_config.seed = seed;

    var block_hash: u64 = 0;
    var cx: i32 = -HALF;
    while (cx <= HALF) : (cx += 1) {
        var cz: i32 = -HALF;
        while (cz <= HALF) : (cz += 1) {
            _ = try world.generateChunk(cx, cz);
        }
    }
    cx = -HALF;
    while (cx <= HALF) : (cx += 1) {
        var cz: i32 = -HALF;
        while (cz <= HALF) : (cz += 1) {
            const lc = world.chunks.get(.{ .cx = cx, .cz = cz }).?;
            block_hash +%= chunkHash(&lc.chunk, cx, cz);
        }
    }
    return block_hash;
}

fn chunkHash(chunk: *const chunk_mod.Chunk, cx: i32, cz: i32) u64 {
    var h = std.hash.Wyhash.init(@bitCast(@as(i64, cx) *% 31 +% cz));
    var y: i32 = 0;
    while (y < chunk_mod.CHUNK_H) : (y += 1) {
        var x: i32 = 0;
        while (x < chunk_mod.CHUNK_W) : (x += 1) {
            var z: i32 = 0;
            while (z < chunk_mod.CHUNK_W) : (z += 1) {
                h.update(&[_]u8{@backingInt(chunk.getBlock(x, y, z))});
            }
        }
    }
    return h.final();
}

/// Native entry: print "<seed> <hash>" for each seed argument, one per line.
/// The wasm runner prints the same format, so CI compares the two with diff.
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var out_buf: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &out_buf);
    const out = &stdout.interface;

    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.skip();
    var count: usize = 0;
    while (args.next()) |arg| {
        const seed = std.fmt.parseInt(u64, arg, 10) catch {
            std.log.err("terrain_hash: '{s}' is not a u64 seed", .{arg});
            return error.InvalidSeed;
        };
        try out.print("{d} {x:0>16}\n", .{ seed, try blockHash(allocator, seed) });
        try out.flush();
        count += 1;
    }
    if (count == 0) {
        std.log.err("terrain_hash: give one or more seeds, for example: terrain_hash 0 1 12345", .{});
        return error.NoSeed;
    }
}

test "seed 0 keeps the block hash of the terrain before the seed" {
    try std.testing.expectEqual(SEED0_BLOCK_HASH, try blockHash(std.testing.allocator, 0));
}

test "seed 1 gives a different block hash" {
    try std.testing.expect(try blockHash(std.testing.allocator, 1) != SEED0_BLOCK_HASH);
}
