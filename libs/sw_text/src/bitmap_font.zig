//! A bitmap font: glyphs in a grid of equal cells on one sheet image, and a
//! table of glyph widths. This file has no GPU code.

const std = @import("std");
const font_mod = @import("font.zig");

pub const VMetrics = font_mod.VMetrics;
pub const BitmapBox = font_mod.BitmapBox;

pub const BitmapFont = struct {
    /// The pixels of a glyph sheet.
    pub const Sheet = struct {
        pub const Format = enum {
            /// One byte for each pixel: the coverage.
            alpha8,
            /// Four bytes for each pixel (red, green, blue, alpha). The alpha
            /// is the coverage. Text is drawn in the style colour.
            rgba8,
        };
        pixels: []const u8,
        width: u32,
        height: u32,
        format: Format = .rgba8,
    };

    /// How to read a sheet.
    pub const Desc = struct {
        sheet: Sheet,
        /// The size of one cell, in sheet pixels. The cells are in rows from
        /// the top left of the sheet.
        cell_width: u32,
        cell_height: u32,
        /// The code point of each cell, row by row. 0 is an empty cell. When
        /// two cells have the same code point, the font uses the first one.
        codepoints: []const u21,
        /// The advance of each cell, in sheet pixels: the pen movement after
        /// the glyph. It has the same length as `codepoints`.
        widths: []const u8,
        /// The rows from the top of a cell to the baseline. Null puts the
        /// baseline at the bottom of the cell.
        baseline: ?u32 = null,
    };

    alloc: std.mem.Allocator,
    /// The coverage of each sheet pixel (a copy).
    coverage: []u8,
    sheet_width: u32,
    cell_width: u32,
    cell_height: u32,
    columns: u32,
    baseline: u32,
    widths: []u8,
    /// Code point to glyph index. A glyph index is the cell index plus 1.
    glyphs: std.AutoHashMapUnmanaged(u21, u32) = .empty,

    /// Read a sheet. The font keeps a copy of the coverage and the widths, so
    /// `desc` does not need to stay valid.
    pub fn init(alloc: std.mem.Allocator, desc: Desc) !BitmapFont {
        const s = desc.sheet;
        if (desc.cell_width == 0 or desc.cell_height == 0) return error.InvalidBitmapFont;
        if (desc.cell_width > s.width or desc.cell_height > s.height) return error.InvalidBitmapFont;
        if (desc.codepoints.len != desc.widths.len) return error.InvalidBitmapFont;
        const pixel_count = @as(usize, s.width) * s.height;
        const bytes_per_pixel: usize = switch (s.format) {
            .alpha8 => 1,
            .rgba8 => 4,
        };
        if (s.pixels.len < pixel_count * bytes_per_pixel) return error.InvalidBitmapFont;
        const columns = s.width / desc.cell_width;
        const rows = s.height / desc.cell_height;
        if (desc.codepoints.len > @as(usize, columns) * rows) return error.InvalidBitmapFont;
        const baseline = desc.baseline orelse desc.cell_height;
        if (baseline > desc.cell_height) return error.InvalidBitmapFont;

        const coverage = try alloc.alloc(u8, pixel_count);
        errdefer alloc.free(coverage);
        switch (s.format) {
            .alpha8 => @memcpy(coverage, s.pixels[0..pixel_count]),
            .rgba8 => for (coverage, 0..) |*c, i| {
                c.* = s.pixels[i * 4 + 3];
            },
        }
        const widths = try alloc.dupe(u8, desc.widths);
        errdefer alloc.free(widths);

        var font: BitmapFont = .{
            .alloc = alloc,
            .coverage = coverage,
            .sheet_width = s.width,
            .cell_width = desc.cell_width,
            .cell_height = desc.cell_height,
            .columns = columns,
            .baseline = baseline,
            .widths = widths,
        };
        errdefer font.glyphs.deinit(alloc);
        for (desc.codepoints, 0..) |cp, i| {
            if (cp == 0) continue;
            const entry = try font.glyphs.getOrPut(alloc, cp);
            if (!entry.found_existing) entry.value_ptr.* = @intCast(i + 1);
        }
        return font;
    }

    pub fn deinit(self: *BitmapFont) void {
        self.glyphs.deinit(self.alloc);
        self.alloc.free(self.widths);
        self.alloc.free(self.coverage);
        self.* = undefined;
    }

    /// The glyph for a code point. 0 means the font has none.
    pub fn glyphIndex(self: *const BitmapFont, codepoint: u21) u32 {
        return self.glyphs.get(codepoint) orelse 0;
    }

    /// Pixels for each sheet pixel when a cell is `size` pixels high.
    pub fn scale(self: *const BitmapFont, size: f32) f32 {
        return size / @as(f32, @floatFromInt(self.cell_height));
    }

    /// The vertical metrics at `size`. A cell is `size` pixels high, from
    /// the ascent to the descent, with no line gap.
    pub fn vmetrics(self: *const BitmapFont, size: f32) VMetrics {
        const s = self.scale(size);
        return .{
            .ascent = @as(f32, @floatFromInt(self.baseline)) * s,
            .descent = -@as(f32, @floatFromInt(self.cell_height - self.baseline)) * s,
            .line_gap = 0,
        };
    }

    /// Pen movement after a glyph, in pixels.
    pub fn advance(self: *const BitmapFont, glyph: u32, size: f32) f32 {
        if (glyph == 0 or glyph > self.widths.len) return 0;
        return @as(f32, @floatFromInt(self.widths[glyph - 1])) * self.scale(size);
    }

    /// The pixel box of a glyph at `size`, relative to the pen on the
    /// baseline. It is the whole cell, scaled.
    pub fn bitmapBox(self: *const BitmapFont, glyph: u32, size: f32) BitmapBox {
        if (glyph == 0) return .{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };
        const s = self.scale(size);
        const top: i32 = @intFromFloat(@round(-@as(f32, @floatFromInt(self.baseline)) * s));
        const w: i32 = @intFromFloat(@max(@round(@as(f32, @floatFromInt(self.cell_width)) * s), 1));
        const h: i32 = @intFromFloat(@max(@round(@as(f32, @floatFromInt(self.cell_height)) * s), 1));
        return .{ .x0 = 0, .y0 = top, .x1 = w, .y1 = top + h };
    }

    /// Draw a glyph as 8-bit coverage into `out`, with the nearest sheet
    /// pixel for each output pixel, so the edges stay sharp. `out` is
    /// `box.width() * box.height()` bytes, rows packed. The box comes from
    /// `bitmapBox` with the same `size`.
    pub fn render(self: *const BitmapFont, glyph: u32, box: BitmapBox, out: []u8) void {
        const w = box.width();
        const h = box.height();
        std.debug.assert(out.len == @as(usize, w) * h);
        if (glyph == 0 or w == 0 or h == 0) return;
        const cell = glyph - 1;
        const cell_x = (cell % self.columns) * self.cell_width;
        const cell_y = (cell / self.columns) * self.cell_height;
        for (0..h) |y| {
            const sy = @min(y * self.cell_height / h, self.cell_height - 1);
            const row = (cell_y + sy) * @as(usize, self.sheet_width);
            for (0..w) |x| {
                const sx = @min(x * self.cell_width / w, self.cell_width - 1);
                out[y * w + x] = self.coverage[row + cell_x + sx];
            }
        }
    }
};

const testing = std.testing;

/// A 2x1 grid of 3x4 cells. Cell 0 is 'A': a 2 pixel wide bar on rows 0-2.
/// Cell 1 is 'B': one pixel at the top left.
fn testSheet() [24]u8 {
    var px: [6 * 4]u8 = @splat(0);
    for (0..3) |y| {
        px[y * 6 + 0] = 255;
        px[y * 6 + 1] = 255;
    }
    px[3] = 200;
    return px;
}

fn testFont(px: []const u8) !BitmapFont {
    return BitmapFont.init(testing.allocator, .{
        .sheet = .{ .pixels = px, .width = 6, .height = 4, .format = .alpha8 },
        .cell_width = 3,
        .cell_height = 4,
        .codepoints = &.{ 'A', 'B' },
        .widths = &.{ 3, 2 },
        .baseline = 3,
    });
}

test "a bitmap font maps code points to cells" {
    const px = testSheet();
    var font = try testFont(&px);
    defer font.deinit();
    try testing.expectEqual(@as(u32, 1), font.glyphIndex('A'));
    try testing.expectEqual(@as(u32, 2), font.glyphIndex('B'));
    try testing.expectEqual(@as(u32, 0), font.glyphIndex('C'));
}

test "a bitmap font scales the width table and the metrics with the size" {
    const px = testSheet();
    var font = try testFont(&px);
    defer font.deinit();
    // The cell is 4 high, so size 8 is a scale of 2.
    try testing.expectEqual(@as(f32, 6), font.advance(1, 8));
    try testing.expectEqual(@as(f32, 4), font.advance(2, 8));
    const v = font.vmetrics(8);
    try testing.expectEqual(@as(f32, 6), v.ascent);
    try testing.expectEqual(@as(f32, -2), v.descent);
}

test "a bitmap glyph renders with the nearest sheet pixel" {
    const px = testSheet();
    var font = try testFont(&px);
    defer font.deinit();

    const box = font.bitmapBox(1, 8);
    try testing.expectEqual(@as(i32, -6), box.y0);
    try testing.expectEqual(@as(u32, 6), box.width());
    try testing.expectEqual(@as(u32, 8), box.height());
    var out: [48]u8 = undefined;
    font.render(1, box, &out);
    // Each sheet pixel is 2x2: columns 0-3 of rows 0-5 are set.
    for (0..8) |y| {
        for (0..6) |x| {
            const want: u8 = if (x < 4 and y < 6) 255 else 0;
            try testing.expectEqual(want, out[y * 6 + x]);
        }
    }

    const box_b = font.bitmapBox(2, 4);
    var out_b: [12]u8 = undefined;
    font.render(2, box_b, &out_b);
    try testing.expectEqual(@as(u8, 200), out_b[0]);
    try testing.expectEqual(@as(u8, 0), out_b[1]);
}

test "an rgba8 sheet uses the alpha as coverage" {
    var px: [2 * 1 * 4]u8 = .{ 255, 255, 255, 10, 0, 0, 0, 250 };
    var font = try BitmapFont.init(testing.allocator, .{
        .sheet = .{ .pixels = &px, .width = 2, .height = 1 },
        .cell_width = 1,
        .cell_height = 1,
        .codepoints = &.{ 'x', 'y' },
        .widths = &.{ 1, 1 },
    });
    defer font.deinit();
    var out: [1]u8 = undefined;
    font.render(font.glyphIndex('y'), font.bitmapBox(2, 1), &out);
    try testing.expectEqual(@as(u8, 250), out[0]);
}

test "a bad bitmap font description is an error" {
    const px = testSheet();
    try testing.expectError(error.InvalidBitmapFont, BitmapFont.init(testing.allocator, .{
        .sheet = .{ .pixels = &px, .width = 6, .height = 4, .format = .alpha8 },
        .cell_width = 3,
        .cell_height = 4,
        .codepoints = &.{ 'A', 'B' },
        .widths = &.{3},
    }));
    try testing.expectError(error.InvalidBitmapFont, BitmapFont.init(testing.allocator, .{
        .sheet = .{ .pixels = px[0..10], .width = 6, .height = 4, .format = .alpha8 },
        .cell_width = 3,
        .cell_height = 4,
        .codepoints = &.{'A'},
        .widths = &.{3},
    }));
}
