//! Atlas layout: where each image goes in the atlas texture. This file has
//! no GPU code.
//!
//! The atlas is a square texture with a grid of square cells. The cell edge
//! is a power of two. Each image starts on a cell edge and gets a whole
//! number of cells. Thus each image is a tile of `sw_gpu.mip_chain`, and no
//! mip level mixes two images while a cell is 2 texels or more
//! (REQ-GPU-004). The shelf packer of `sw_text` places the cells.

const std = @import("std");
const shelf = @import("sw_text").atlas;
const mip_chain = @import("sw_gpu").mip_chain;

/// The size of an image, in texels.
pub const Size = struct {
    width: u32,
    height: u32,
};

/// A rectangle in texels. The origin is the top left corner.
pub const Rect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,

    /// The same rectangle at a mip level: each value halved `level` times.
    /// The result is exact for a cell rectangle at a level that
    /// `Layout.mipLevelCount` allows.
    pub fn atLevel(self: Rect, level: u32) Rect {
        if (level == 0) return self;
        const s: u5 = @intCast(@min(level, 31));
        return .{
            .x = self.x >> s,
            .y = self.y >> s,
            .width = @max(1, self.width >> s),
            .height = @max(1, self.height >> s),
        };
    }
};

/// Texture coordinates of an image. (0, 0) is the top left corner of the
/// texture and (1, 1) is the bottom right corner, as in WebGPU.
pub const UvRect = struct {
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
};

/// An RGBA8 image: 4 bytes for each texel, rows top to bottom, no row
/// padding. `sw_assets.decodePng` gives this layout.
pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []const u8,

    pub fn size(self: Image) Size {
        return .{ .width = self.width, .height = self.height };
    }
};

pub const Options = struct {
    /// The edge of one grid cell, in texels. It must be a power of two. An
    /// image with a size that is a multiple of `cell` fills its cells. A
    /// smaller image repeats its edge texels to fill its cells.
    cell: u32 = 16,
    /// The largest texture edge, in texels. WebGPU guarantees 8192.
    max_size: u32 = 4096,
};

pub const Error = error{
    CellNotPowerOfTwo,
    ZeroSize,
    AtlasFull,
    OutOfMemory,
};

/// The result of `pack`: a square texture and one rectangle for each image.
pub const Layout = struct {
    /// The edge of the square texture, in texels. A power of two.
    size: u32,
    cell: u32,
    /// The texels of each image, in the order that `pack` got the sizes.
    rects: []Rect,

    pub fn deinit(self: *Layout, allocator: std.mem.Allocator) void {
        allocator.free(self.rects);
        self.* = undefined;
    }

    /// The texture coordinates of image `index`.
    pub fn uv(self: Layout, index: usize) UvRect {
        const r = self.rects[index];
        const s: f32 = @floatFromInt(self.size);
        return .{
            .u0 = @as(f32, @floatFromInt(r.x)) / s,
            .v0 = @as(f32, @floatFromInt(r.y)) / s,
            .u1 = @as(f32, @floatFromInt(r.x + r.width)) / s,
            .v1 = @as(f32, @floatFromInt(r.y + r.height)) / s,
        };
    }

    /// The cells of image `index`: its rectangle, with the width and the
    /// height made larger to a multiple of the cell.
    pub fn cellRect(self: Layout, index: usize) Rect {
        const r = self.rects[index];
        return .{
            .x = r.x,
            .y = r.y,
            .width = roundUp(r.width, self.cell),
            .height = roundUp(r.height, self.cell),
        };
    }

    /// The number of mip levels that keep each image apart (REQ-GPU-004):
    /// the levels down to 1 texel for each cell.
    pub fn mipLevelCount(self: Layout) u32 {
        return mip_chain.levelCount(self.size, self.size, mip_chain.TileSize.square(self.cell)) catch 1;
    }
};

fn roundUp(v: u32, step: u32) u32 {
    return (v + step - 1) / step * step;
}

fn cellsOf(v: u32, cell: u32) u32 {
    return (v + cell - 1) / cell;
}

/// Put each image on the cell grid of one square texture. The tallest
/// images go first. The texture is the smallest power of two that holds
/// all of the images. The order of the result is the order of `sizes`.
pub fn pack(allocator: std.mem.Allocator, sizes: []const Size, options: Options) Error!Layout {
    const cell = options.cell;
    if (cell == 0 or !std.math.isPowerOfTwo(cell)) return error.CellNotPowerOfTwo;

    var area: u64 = 0;
    var widest: u32 = 1;
    for (sizes) |s| {
        if (s.width == 0 or s.height == 0) return error.ZeroSize;
        const cw = cellsOf(s.width, cell);
        const ch = cellsOf(s.height, cell);
        area += @as(u64, cw) * ch;
        widest = @max(widest, @max(cw, ch));
    }

    const order = try allocator.alloc(u32, sizes.len);
    defer allocator.free(order);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    const Sort = struct {
        sizes: []const Size,
        cell: u32,
        fn lessThan(ctx: @This(), a: u32, b: u32) bool {
            const ah = cellsOf(ctx.sizes[a].height, ctx.cell);
            const bh = cellsOf(ctx.sizes[b].height, ctx.cell);
            if (ah != bh) return ah > bh;
            const aw = cellsOf(ctx.sizes[a].width, ctx.cell);
            const bw = cellsOf(ctx.sizes[b].width, ctx.cell);
            if (aw != bw) return aw > bw;
            return a < b;
        }
    };
    std.mem.sort(u32, order, Sort{ .sizes = sizes, .cell = cell }, Sort.lessThan);

    const rects = try allocator.alloc(Rect, sizes.len);
    errdefer allocator.free(rects);

    // The edge of the texture, in cells.
    var side: u32 = std.math.ceilPowerOfTwo(u32, widest) catch return error.AtlasFull;
    while (@as(u64, side) * side < area) side = std.math.mul(u32, side, 2) catch return error.AtlasFull;
    while (@as(u64, side) * cell <= options.max_size) {
        var packer = shelf.Packer.init(side);
        const fits = for (order) |i| {
            const s = sizes[i];
            const pos = packer.alloc(cellsOf(s.width, cell), cellsOf(s.height, cell)) orelse break false;
            rects[i] = .{ .x = pos.x * cell, .y = pos.y * cell, .width = s.width, .height = s.height };
        } else true;
        if (fits) return .{ .size = side * cell, .cell = cell, .rects = rects };
        side = std.math.mul(u32, side, 2) catch break;
    }
    return error.AtlasFull;
}

/// Copy each image to its rectangle in `out`. `out` is RGBA8 with
/// `layout.size` texels on each edge. The texels of a cell that the image
/// does not cover repeat the nearest edge texel of the image. Texels with
/// no image are zero.
pub fn compose(layout: Layout, images: []const Image, out: []u8) void {
    std.debug.assert(images.len == layout.rects.len);
    std.debug.assert(out.len == @as(usize, layout.size) * layout.size * 4);
    @memset(out, 0);
    for (images, 0..) |img, i| {
        std.debug.assert(img.pixels.len == @as(usize, img.width) * img.height * 4);
        const c = layout.cellRect(i);
        for (0..c.height) |dy| {
            const sy = @min(dy, img.height - 1);
            for (0..c.width) |dx| {
                const sx = @min(dx, img.width - 1);
                const src = img.pixels[(sy * img.width + sx) * 4 ..][0..4];
                const dst = out[((c.y + dy) * layout.size + c.x + dx) * 4 ..][0..4];
                dst.* = src.*;
            }
        }
    }
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn overlaps(a: Rect, b: Rect) bool {
    return a.x < b.x + b.width and b.x < a.x + a.width and
        a.y < b.y + b.height and b.y < a.y + a.height;
}

test "pack: each image is on the cell grid, in the texture, and apart (REQ-GPU-004)" {
    const sizes = [_]Size{
        .{ .width = 16, .height = 16 },
        .{ .width = 32, .height = 16 },
        .{ .width = 10, .height = 10 },
        .{ .width = 16, .height = 48 },
        .{ .width = 64, .height = 32 },
        .{ .width = 1, .height = 1 },
        .{ .width = 17, .height = 33 },
    };
    var l = try pack(testing.allocator, &sizes, .{ .cell = 16 });
    defer l.deinit(testing.allocator);

    try testing.expect(std.math.isPowerOfTwo(l.size));
    for (sizes, 0..) |s, i| {
        const r = l.rects[i];
        try testing.expectEqual(s.width, r.width);
        try testing.expectEqual(s.height, r.height);
        try testing.expectEqual(@as(u32, 0), r.x % 16);
        try testing.expectEqual(@as(u32, 0), r.y % 16);
        const c = l.cellRect(i);
        try testing.expect(c.x + c.width <= l.size and c.y + c.height <= l.size);
        for (0..i) |j| try testing.expect(!overlaps(c, l.cellRect(j)));
    }
}

test "pack: the texture is the smallest power of two that holds the images" {
    // Four 16x16 images fill a 32x32 texture.
    const four: [4]Size = @splat(.{ .width = 16, .height = 16 });
    var a = try pack(testing.allocator, &four, .{ .cell = 16 });
    defer a.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 32), a.size);

    // A fifth image needs a 64x64 texture.
    const five: [5]Size = @splat(.{ .width = 16, .height = 16 });
    var b = try pack(testing.allocator, &five, .{ .cell = 16 });
    defer b.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 64), b.size);

    // One wide image sets the edge.
    const wide = [_]Size{.{ .width = 100, .height = 8 }};
    var c = try pack(testing.allocator, &wide, .{ .cell = 8 });
    defer c.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 128), c.size);

    // No images: one cell.
    var d = try pack(testing.allocator, &.{}, .{ .cell = 16 });
    defer d.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 16), d.size);
}

test "pack: bad options and full atlases give an error" {
    const one = [_]Size{.{ .width = 16, .height = 16 }};
    try testing.expectError(error.CellNotPowerOfTwo, pack(testing.allocator, &one, .{ .cell = 12 }));
    try testing.expectError(error.CellNotPowerOfTwo, pack(testing.allocator, &one, .{ .cell = 0 }));
    const zero = [_]Size{.{ .width = 0, .height = 16 }};
    try testing.expectError(error.ZeroSize, pack(testing.allocator, &zero, .{}));
    const big = [_]Size{.{ .width = 64, .height = 16 }};
    try testing.expectError(error.AtlasFull, pack(testing.allocator, &big, .{ .cell = 16, .max_size = 32 }));
    const many: [5]Size = @splat(.{ .width = 16, .height = 16 });
    try testing.expectError(error.AtlasFull, pack(testing.allocator, &many, .{ .cell = 16, .max_size = 32 }));
}

test "pack: the result does not change between runs" {
    const sizes = [_]Size{
        .{ .width = 16, .height = 16 }, .{ .width = 16, .height = 32 },
        .{ .width = 32, .height = 16 }, .{ .width = 16, .height = 16 },
    };
    var a = try pack(testing.allocator, &sizes, .{});
    defer a.deinit(testing.allocator);
    var b = try pack(testing.allocator, &sizes, .{});
    defer b.deinit(testing.allocator);
    try testing.expectEqualSlices(Rect, a.rects, b.rects);
    // The tallest image goes first.
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 16, .height = 32 }, a.rects[1]);
}

test "uv: the rectangle of an image in texture coordinates" {
    const sizes = [_]Size{ .{ .width = 32, .height = 32 }, .{ .width = 8, .height = 16 } };
    var l = try pack(testing.allocator, &sizes, .{ .cell = 16 });
    defer l.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 64), l.size);
    try testing.expectEqual(UvRect{ .u0 = 0, .v0 = 0, .u1 = 0.5, .v1 = 0.5 }, l.uv(0));
    // The second image is right of the first. Its UV rectangle covers its
    // 8 texels, not the 16 texels of its cell.
    try testing.expectEqual(UvRect{ .u0 = 0.5, .v0 = 0, .u1 = 0.625, .v1 = 0.25 }, l.uv(1));
}

test "mip levels: a cell rectangle stays exact at each level (REQ-GPU-004)" {
    const sizes = [_]Size{ .{ .width = 16, .height = 16 }, .{ .width = 48, .height = 16 }, .{ .width = 16, .height = 32 } };
    var l = try pack(testing.allocator, &sizes, .{ .cell = 16 });
    defer l.deinit(testing.allocator);
    // 16-texel cells: levels 16, 8, 4, 2, 1.
    try testing.expectEqual(@as(u32, 5), l.mipLevelCount());
    for (0..sizes.len) |i| {
        const c = l.cellRect(i);
        var level: u32 = 0;
        while (level < l.mipLevelCount()) : (level += 1) {
            const r = c.atLevel(level);
            const scale = @as(u32, 1) << @intCast(level);
            try testing.expectEqual(c.x, r.x * scale);
            try testing.expectEqual(c.y, r.y * scale);
            try testing.expectEqual(c.width, r.width * scale);
            try testing.expectEqual(c.height, r.height * scale);
        }
    }
}

test "compose: images go to their rectangles, and the edge texels fill the cell" {
    const red = [_]u8{ 255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255 }; // 2x2
    const blue = [_]u8{ 0, 0, 255, 255, 0, 255, 0, 255 }; // 2x1: blue, green
    const images = [_]Image{
        .{ .width = 2, .height = 2, .pixels = &red },
        .{ .width = 2, .height = 1, .pixels = &blue },
    };
    var sizes: [2]Size = undefined;
    for (images, 0..) |img, i| sizes[i] = img.size();
    var l = try pack(testing.allocator, &sizes, .{ .cell = 4 });
    defer l.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 8), l.size);

    var out: [8 * 8 * 4]u8 = undefined;
    compose(l, &images, &out);
    const at = struct {
        fn f(o: []const u8, x: usize, y: usize) [4]u8 {
            return o[(y * 8 + x) * 4 ..][0..4].*;
        }
    }.f;
    // Image 0 at (0, 0): red in all of its 4x4 cell.
    for (0..4) |y| for (0..4) |x| try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, at(&out, x, y));
    // Image 1 at (4, 0): blue in column 0, green in columns 1 to 3, and
    // each row repeats row 0.
    for (0..4) |y| {
        try testing.expectEqual([4]u8{ 0, 0, 255, 255 }, at(&out, 4, y));
        for (5..8) |x| try testing.expectEqual([4]u8{ 0, 255, 0, 255 }, at(&out, x, y));
    }
    // No image in the bottom half.
    for (4..8) |y| for (0..8) |x| try testing.expectEqual([4]u8{ 0, 0, 0, 0 }, at(&out, x, y));
}
