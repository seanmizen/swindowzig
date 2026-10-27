//! Mip chain maths for sw_gpu: the level count, the size of each level, and
//! the source texels of each texel. This file has no GPU code.
//!
//! Each texel of level N is the mean of a 2x2 block of level N-1. The GPU
//! shader in `mipmap.zig` does the same box filter, and `downsample` in this
//! file is the CPU reference for the tests.
//!
//! A texture atlas holds tiles side by side. If a 2x2 block crosses a tile
//! edge, the mip level mixes the pixels of two tiles (REQ-GPU-002). With
//! power-of-two tiles on a tile grid, each block stays inside one tile while
//! the tile is 2 texels or more. `levelCount` with a tile size gives the
//! levels that obey this rule.

const std = @import("std");

/// The size of one tile of a texture atlas, in texels at mip level 0.
pub const TileSize = struct {
    width: u32,
    height: u32,

    pub fn square(size: u32) TileSize {
        return .{ .width = size, .height = size };
    }
};

pub const Error = error{
    ZeroSize,
    TileNotPowerOfTwo,
    TileNotOnTextureGrid,
};

/// The number of mip levels of a full chain, down to 1x1.
pub fn fullLevelCount(width: u32, height: u32) u32 {
    const largest = @max(width, height);
    if (largest == 0) return 0;
    return @as(u32, std.math.log2_int(u32, largest)) + 1;
}

/// The number of mip levels that a texture can have.
///
/// With no tile size, this is the full chain. With a tile size, the chain
/// stops at the level where the smaller tile edge is 1 texel, so no level
/// mixes two tiles. The tile edges must be powers of two, and the texture
/// must hold a whole number of tiles in each direction.
pub fn levelCount(width: u32, height: u32, tile: ?TileSize) Error!u32 {
    if (width == 0 or height == 0) return error.ZeroSize;
    const full = fullLevelCount(width, height);
    const t = tile orelse return full;
    if (t.width == 0 or t.height == 0 or
        !std.math.isPowerOfTwo(t.width) or !std.math.isPowerOfTwo(t.height))
    {
        return error.TileNotPowerOfTwo;
    }
    if (width % t.width != 0 or height % t.height != 0) return error.TileNotOnTextureGrid;
    const tile_levels = @as(u32, std.math.log2_int(u32, @min(t.width, t.height))) + 1;
    return @min(full, tile_levels);
}

/// The size of one edge at a mip level: the base size halved `level` times,
/// and never less than 1.
pub fn levelSize(base: u32, level: u32) u32 {
    if (level >= 32) return 1;
    return @max(1, base >> @intCast(level));
}

/// The source coordinate of one texel of the 2x2 block. `offset` is 0 or 1.
/// A source edge with an odd size drops its last texel, and a source edge
/// of 1 texel uses the same texel twice. The shader does the same with
/// `min(dst * 2 + offset, src_size - 1)`.
pub fn sourceCoord(dst: u32, offset: u1, src_size: u32) u32 {
    return @min(dst * 2 + offset, src_size - 1);
}

/// One RGBA texel, each channel 0 to 1, in linear light.
pub const Texel = [4]f32;

/// Make level N from level N-1 with the 2x2 box filter. `dst` has
/// `levelSize(src_width, 1) * levelSize(src_height, 1)` texels.
pub fn downsample(src: []const Texel, src_width: u32, src_height: u32, dst: []Texel) void {
    const dst_width = levelSize(src_width, 1);
    const dst_height = levelSize(src_height, 1);
    std.debug.assert(src.len == @as(usize, src_width) * src_height);
    std.debug.assert(dst.len == @as(usize, dst_width) * dst_height);
    for (0..dst_height) |y_usize| {
        const y: u32 = @intCast(y_usize);
        for (0..dst_width) |x_usize| {
            const x: u32 = @intCast(x_usize);
            var sum: Texel = .{ 0, 0, 0, 0 };
            for ([_]u1{ 0, 1 }) |oy| {
                for ([_]u1{ 0, 1 }) |ox| {
                    const sx = sourceCoord(x, ox, src_width);
                    const sy = sourceCoord(y, oy, src_height);
                    const t = src[@as(usize, sy) * src_width + sx];
                    for (0..4) |c| sum[c] += t[c];
                }
            }
            for (0..4) |c| sum[c] *= 0.25;
            dst[@as(usize, y) * dst_width + x] = sum;
        }
    }
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "mip chain: full level count" {
    try testing.expectEqual(@as(u32, 1), fullLevelCount(1, 1));
    try testing.expectEqual(@as(u32, 9), fullLevelCount(256, 256));
    try testing.expectEqual(@as(u32, 9), fullLevelCount(256, 4));
    try testing.expectEqual(@as(u32, 8), fullLevelCount(255, 3));
    try testing.expectEqual(@as(u32, 0), fullLevelCount(0, 0));
}

test "mip chain: level count with tiles stops at a 1-texel tile" {
    // 256x256 atlas of 16x16 tiles: levels 16, 8, 4, 2, 1 = 5.
    try testing.expectEqual(@as(u32, 5), try levelCount(256, 256, TileSize.square(16)));
    // A tile as large as the texture gives the full chain.
    try testing.expectEqual(@as(u32, 9), try levelCount(256, 256, TileSize.square(256)));
    // The smaller tile edge sets the limit.
    try testing.expectEqual(@as(u32, 3), try levelCount(64, 32, .{ .width = 16, .height = 4 }));
    // No tiles: the full chain.
    try testing.expectEqual(@as(u32, 9), try levelCount(256, 100, null));
}

test "mip chain: bad tile sizes give an error" {
    try testing.expectError(error.TileNotPowerOfTwo, levelCount(48, 48, TileSize.square(12)));
    try testing.expectError(error.TileNotPowerOfTwo, levelCount(48, 48, TileSize.square(0)));
    try testing.expectError(error.TileNotOnTextureGrid, levelCount(40, 32, TileSize.square(16)));
    try testing.expectError(error.ZeroSize, levelCount(0, 32, null));
}

test "mip chain: level size" {
    try testing.expectEqual(@as(u32, 256), levelSize(256, 0));
    try testing.expectEqual(@as(u32, 32), levelSize(256, 3));
    try testing.expectEqual(@as(u32, 1), levelSize(256, 8));
    try testing.expectEqual(@as(u32, 1), levelSize(256, 20));
    try testing.expectEqual(@as(u32, 2), levelSize(5, 1));
    try testing.expectEqual(@as(u32, 1), levelSize(7, 40));
}

/// The tile that holds texel (x, y) of a level with tiles of `tile_w` x
/// `tile_h` texels.
fn tileOf(x: u32, y: u32, tile_w: u32, tile_h: u32) [2]u32 {
    return .{ x / tile_w, y / tile_h };
}

test "mip chain: every 2x2 block of an atlas stays in one tile (REQ-GPU-002)" {
    const cases = [_]struct { w: u32, h: u32, tile: TileSize }{
        .{ .w = 64, .h = 64, .tile = TileSize.square(16) },
        .{ .w = 128, .h = 32, .tile = .{ .width = 32, .height = 8 } },
        .{ .w = 48, .h = 16, .tile = TileSize.square(16) },
        .{ .w = 8, .h = 8, .tile = TileSize.square(2) },
    };
    for (cases) |case| {
        const count = try levelCount(case.w, case.h, case.tile);
        var level: u32 = 1;
        while (level < count) : (level += 1) {
            const src_w = levelSize(case.w, level - 1);
            const src_h = levelSize(case.h, level - 1);
            const tile_w = case.tile.width >> @intCast(level - 1);
            const tile_h = case.tile.height >> @intCast(level - 1);
            const dst_w = levelSize(case.w, level);
            const dst_h = levelSize(case.h, level);
            for (0..dst_h) |y| for (0..dst_w) |x| {
                const first = tileOf(sourceCoord(@intCast(x), 0, src_w), sourceCoord(@intCast(y), 0, src_h), tile_w, tile_h);
                for ([_]u1{ 0, 1 }) |oy| for ([_]u1{ 0, 1 }) |ox| {
                    const t = tileOf(sourceCoord(@intCast(x), ox, src_w), sourceCoord(@intCast(y), oy, src_h), tile_w, tile_h);
                    try testing.expectEqual(first, t);
                };
            };
        }
    }
}

test "mip chain: the last atlas level keeps the colour of each tile (REQ-GPU-002)" {
    // A 16x8 atlas of two 8x8 tiles: red on the left, blue on the right.
    const w = 16;
    const h = 8;
    const tile = TileSize.square(8);
    const count = try levelCount(w, h, tile);
    try testing.expectEqual(@as(u32, 4), count);

    var levels: [5][w * h]Texel = undefined;
    for (0..h) |y| for (0..w) |x| {
        levels[0][y * w + x] = if (x < 8) .{ 1, 0, 0, 1 } else .{ 0, 0, 1, 1 };
    };
    var level: u32 = 1;
    // One level more than the limit, to show that the limit matters.
    while (level <= count) : (level += 1) {
        const sw = levelSize(w, level - 1);
        const sh = levelSize(h, level - 1);
        const dw = levelSize(w, level);
        const dh = levelSize(h, level);
        downsample(levels[level - 1][0 .. sw * sh], sw, sh, levels[level][0 .. dw * dh]);
    }

    // The last level in the limit is 2x1: one pure texel for each tile.
    const last = levels[count - 1];
    try testing.expectEqual(Texel{ 1, 0, 0, 1 }, last[0]);
    try testing.expectEqual(Texel{ 0, 0, 1, 1 }, last[1]);
    // The level after the limit mixes the two tiles.
    try testing.expectEqual(Texel{ 0.5, 0, 0.5, 1 }, levels[count][0]);
}

test "mip chain: downsample averages each 2x2 block" {
    const src = [_]Texel{
        .{ 0, 0, 0, 0 }, .{ 1, 1, 1, 1 }, .{ 0.5, 0, 0, 1 },
        .{ 1, 1, 1, 1 }, .{ 0, 0, 0, 0 }, .{ 0.5, 0, 0, 1 },
        .{ 1, 0, 0, 1 }, .{ 1, 0, 0, 1 }, .{ 1, 0, 0, 1 },
    };
    // 3x3 gives 1x1. The odd last row and column are not used.
    var dst: [1]Texel = undefined;
    downsample(&src, 3, 3, &dst);
    try testing.expectEqual(Texel{ 0.5, 0.5, 0.5, 0.5 }, dst[0]);

    // A 1x2 source gives 1x1, and uses each texel twice.
    const column = [_]Texel{ .{ 1, 0, 0, 1 }, .{ 0, 0, 1, 1 } };
    downsample(&column, 1, 2, &dst);
    try testing.expectEqual(Texel{ 0.5, 0, 0.5, 1 }, dst[0]);
}
