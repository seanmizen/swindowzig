//! A TrueType font, read with stb_truetype (see stb_impl.c). This file has no
//! GPU code.

const std = @import("std");

extern fn sw_ttf_set_allocator(
    alloc_fn: *const fn (usize) callconv(.c) ?*anyopaque,
    free_fn: *const fn (?*anyopaque) callconv(.c) void,
) void;
extern fn sw_ttf_open(data: [*]const u8) ?*anyopaque;
extern fn sw_ttf_close(info: *anyopaque) void;
extern fn sw_ttf_glyph_index(info: *const anyopaque, codepoint: c_int) c_int;
extern fn sw_ttf_scale(info: *const anyopaque, pixel_height: f32) f32;
extern fn sw_ttf_vmetrics(info: *const anyopaque, ascent: *c_int, descent: *c_int, line_gap: *c_int) void;
extern fn sw_ttf_advance(info: *const anyopaque, glyph: c_int) c_int;
extern fn sw_ttf_bitmap_box(info: *const anyopaque, glyph: c_int, scale: f32, x0: *c_int, y0: *c_int, x1: *c_int, y1: *c_int) void;
extern fn sw_ttf_render(info: *const anyopaque, glyph: c_int, scale: f32, out: [*]u8, width: c_int, height: c_int) void;

// stb_truetype allocates through these two functions (set with
// sw_ttf_set_allocator), because freestanding WASM has no libc. They use the
// allocator of the last `Font.init`. Each block starts with a 16 byte header that holds its size.
var stb_allocator: ?std.mem.Allocator = null;
const header = 16;

fn textMalloc(size: usize) callconv(.c) ?*anyopaque {
    const alloc = stb_allocator orelse return null;
    const block = alloc.alignedAlloc(u8, .@"16", size + header) catch return null;
    std.mem.writeInt(usize, block[0..@sizeOf(usize)], size + header, .little);
    return block.ptr + header;
}

fn textFree(ptr: ?*anyopaque) callconv(.c) void {
    const p: [*]u8 = @ptrCast(ptr orelse return);
    const alloc = stb_allocator orelse return;
    const start: [*]align(16) u8 = @alignCast(p - header);
    const total = std.mem.readInt(usize, start[0..@sizeOf(usize)], .little);
    alloc.free(start[0..total]);
}

/// The vertical metrics of a font at one size, in pixels.
pub const VMetrics = struct {
    /// Above the baseline. Positive.
    ascent: f32,
    /// Below the baseline. Negative.
    descent: f32,
    line_gap: f32,
};

/// The pixel box of a glyph, relative to the pen on the baseline. y grows
/// downward, so `y0` is usually negative.
pub const BitmapBox = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,

    pub fn width(self: BitmapBox) u32 {
        return @intCast(@max(self.x1 - self.x0, 0));
    }

    pub fn height(self: BitmapBox) u32 {
        return @intCast(@max(self.y1 - self.y0, 0));
    }
};

/// How wide a code point with no glyph is, in em (a fraction of the size).
pub const missing_advance: f32 = 0.6;

pub const Font = struct {
    info: *anyopaque,

    /// Read a font from the bytes of a .ttf file. The bytes must stay valid
    /// until `deinit`. `alloc` must stay valid until every `Font` is closed.
    pub fn init(alloc: std.mem.Allocator, bytes: []const u8) !Font {
        if (bytes.len == 0) return error.InvalidFont;
        stb_allocator = alloc;
        sw_ttf_set_allocator(&textMalloc, &textFree);
        const info = sw_ttf_open(bytes.ptr) orelse return error.InvalidFont;
        return .{ .info = info };
    }

    pub fn deinit(self: *Font) void {
        sw_ttf_close(self.info);
        self.* = undefined;
    }

    /// The glyph for a code point. 0 means the font has none.
    pub fn glyphIndex(self: Font, codepoint: u21) u32 {
        return @intCast(sw_ttf_glyph_index(self.info, codepoint));
    }

    /// Scale from font units to pixels. `size` is the pixel height from the
    /// highest ascent to the lowest descent.
    pub fn scale(self: Font, size: f32) f32 {
        return sw_ttf_scale(self.info, size);
    }

    pub fn vmetrics(self: Font, size: f32) VMetrics {
        var ascent: c_int = 0;
        var descent: c_int = 0;
        var gap: c_int = 0;
        sw_ttf_vmetrics(self.info, &ascent, &descent, &gap);
        const s = self.scale(size);
        return .{
            .ascent = @as(f32, @floatFromInt(ascent)) * s,
            .descent = @as(f32, @floatFromInt(descent)) * s,
            .line_gap = @as(f32, @floatFromInt(gap)) * s,
        };
    }

    /// Pen movement after a glyph, in pixels.
    pub fn advance(self: Font, glyph: u32, size: f32) f32 {
        const units = sw_ttf_advance(self.info, @intCast(glyph));
        return @as(f32, @floatFromInt(units)) * self.scale(size);
    }

    pub fn bitmapBox(self: Font, glyph: u32, scale_px: f32) BitmapBox {
        var x0: c_int = 0;
        var y0: c_int = 0;
        var x1: c_int = 0;
        var y1: c_int = 0;
        sw_ttf_bitmap_box(self.info, @intCast(glyph), scale_px, &x0, &y0, &x1, &y1);
        return .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 };
    }

    /// Draw a glyph as 8-bit coverage into `out`. `out` is `box.width() *
    /// box.height()` bytes, rows packed. The box comes from `bitmapBox` with
    /// the same `scale_px`.
    pub fn render(self: Font, glyph: u32, scale_px: f32, box: BitmapBox, out: []u8) void {
        const w = box.width();
        const h = box.height();
        std.debug.assert(out.len == @as(usize, w) * h);
        if (w == 0 or h == 0) return;
        sw_ttf_render(self.info, @intCast(glyph), scale_px, out.ptr, @intCast(w), @intCast(h));
    }
};

/// The metrics `layout.zig` needs, for one font at one size.
pub const Metrics = struct {
    font: *const Font,
    size: f32,

    /// Pen movement for a code point, in pixels. A tab is four spaces. Control
    /// characters have no width. A code point with no glyph has the width of
    /// the replacement box.
    pub fn advance(self: Metrics, codepoint: u21) f32 {
        if (codepoint == '\t') return 4 * self.advance(' ');
        if (codepoint < 0x20 or (codepoint >= 0x7F and codepoint < 0xA0)) return 0;
        const glyph = self.font.glyphIndex(codepoint);
        if (glyph == 0) return missing_advance * self.size;
        return self.font.advance(glyph, self.size);
    }

    /// The distance between two baselines.
    pub fn lineHeight(self: Metrics) f32 {
        const v = self.font.vmetrics(self.size);
        return v.ascent - v.descent + v.line_gap;
    }
};

const testing = std.testing;
const layout = @import("layout.zig");

// Lato, from examples/flat2d/assets (SIL Open Font License). build.zig adds
// it as the "test_font" import.
const test_font_bytes = @embedFile("test_font");

test "a font opens and has the Latin ranges" {
    var font = try Font.init(testing.allocator, test_font_bytes);
    defer font.deinit();

    // Basic Latin, Latin-1 Supplement and Latin Extended-A.
    const samples = [_]u21{ 'A', 'z', '~', 0xA0, 0xE9, 0xFC, 0xFF, 0x100, 0x142, 0x17E };
    for (samples) |cp| {
        try testing.expect(font.glyphIndex(cp) != 0);
    }
}

test "a code point the font lacks has glyph 0" {
    var font = try Font.init(testing.allocator, test_font_bytes);
    defer font.deinit();
    try testing.expectEqual(@as(u32, 0), font.glyphIndex(0x4E2D));
}

test "bad font bytes are an error" {
    try testing.expectError(error.InvalidFont, Font.init(testing.allocator, ""));
    try testing.expectError(error.InvalidFont, Font.init(testing.allocator, "this is not a font file at all"));
}

test "advances grow with the size" {
    var font = try Font.init(testing.allocator, test_font_bytes);
    defer font.deinit();
    const g = font.glyphIndex('M');
    const small = font.advance(g, 12);
    const large = font.advance(g, 24);
    try testing.expect(small > 0);
    try testing.expectApproxEqAbs(small * 2, large, 0.01);
}

test "a glyph draws some coverage" {
    var font = try Font.init(testing.allocator, test_font_bytes);
    defer font.deinit();
    const g = font.glyphIndex('I');
    const s = font.scale(32);
    const box = font.bitmapBox(g, s);
    try testing.expect(box.width() > 0 and box.height() > 0);
    // The glyph sits above the baseline.
    try testing.expect(box.y0 < 0);

    const pixels = try testing.allocator.alloc(u8, @as(usize, box.width()) * box.height());
    defer testing.allocator.free(pixels);
    @memset(pixels, 0);
    font.render(g, s, box, pixels);
    var sum: usize = 0;
    for (pixels) |p| sum += p;
    try testing.expect(sum > 0);
}

test "a space has a width and no pixels" {
    var font = try Font.init(testing.allocator, test_font_bytes);
    defer font.deinit();
    const g = font.glyphIndex(' ');
    try testing.expect(g != 0);
    try testing.expect(font.advance(g, 16) > 0);
    const box = font.bitmapBox(g, font.scale(16));
    try testing.expect(box.width() == 0 or box.height() == 0);
}

test "metrics measure a string with accents" {
    var font = try Font.init(testing.allocator, test_font_bytes);
    defer font.deinit();
    const m: Metrics = .{ .font = &font, .size = 20 };

    const plain = layout.measure(m, "creme brulee");
    const accented = layout.measure(m, "crème brûlée");
    try testing.expect(plain.w > 0);
    // An accented letter is about as wide as its base letter.
    try testing.expectApproxEqRel(plain.w, accented.w, 0.1);
    try testing.expectApproxEqAbs(m.lineHeight(), accented.h, 0.001);
    try testing.expect(m.lineHeight() >= 20);
}

test "a missing glyph has the width of the replacement box" {
    var font = try Font.init(testing.allocator, test_font_bytes);
    defer font.deinit();
    const m: Metrics = .{ .font = &font, .size = 20 };
    try testing.expectApproxEqAbs(@as(f32, 12), m.advance(0x4E2D), 0.001);
    try testing.expectEqual(@as(f32, 0), m.advance(0x07));
}

test "wrapping with a real font keeps every line inside the width" {
    var font = try Font.init(testing.allocator, test_font_bytes);
    defer font.deinit();
    const m: Metrics = .{ .font = &font, .size = 16 };
    const text = "Zażółć gęślą jaźń, crème brûlée and a naïve façade.";
    const lines = try layout.wrap(testing.allocator, m, text, 120);
    defer testing.allocator.free(lines);
    try testing.expect(lines.len > 1);
    for (lines) |line| try testing.expect(line.width <= 120);
}
