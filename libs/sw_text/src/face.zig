//! A face is one font of a font chain: a TrueType font or a bitmap font. A
//! chain draws each code point with the first face that has a glyph for it.
//! This file has no GPU code.

const std = @import("std");
const font_mod = @import("font.zig");
const bitmap_mod = @import("bitmap_font.zig");
const bidi = @import("bidi.zig");
const shape = @import("shape.zig");

pub const Font = font_mod.Font;
pub const BitmapFont = bitmap_mod.BitmapFont;
pub const VMetrics = font_mod.VMetrics;
pub const BitmapBox = font_mod.BitmapBox;

pub const Face = union(enum) {
    truetype: Font,
    bitmap: BitmapFont,

    pub fn deinit(self: *Face) void {
        switch (self.*) {
            .truetype => |*f| f.deinit(),
            .bitmap => |*f| f.deinit(),
        }
        self.* = undefined;
    }

    /// The glyph for a code point. 0 means the face has none.
    pub fn glyphIndex(self: *const Face, codepoint: u21) u32 {
        return switch (self.*) {
            .truetype => |f| f.glyphIndex(codepoint),
            .bitmap => |*f| f.glyphIndex(codepoint),
        };
    }

    pub fn vmetrics(self: *const Face, size: f32) VMetrics {
        return switch (self.*) {
            .truetype => |f| f.vmetrics(size),
            .bitmap => |*f| f.vmetrics(size),
        };
    }

    /// Pen movement after a glyph, in pixels.
    pub fn advance(self: *const Face, glyph: u32, size: f32) f32 {
        return switch (self.*) {
            .truetype => |f| f.advance(glyph, size),
            .bitmap => |*f| f.advance(glyph, size),
        };
    }

    /// The pixel box of a glyph at `size` (device pixels), relative to the
    /// pen on the baseline.
    pub fn bitmapBox(self: *const Face, glyph: u32, size: f32) BitmapBox {
        return switch (self.*) {
            .truetype => |f| f.bitmapBox(glyph, f.scale(size)),
            .bitmap => |*f| f.bitmapBox(glyph, size),
        };
    }

    /// Draw a glyph as 8-bit coverage into `out`, for the box from
    /// `bitmapBox` with the same `size`.
    pub fn render(self: *const Face, glyph: u32, size: f32, box: BitmapBox, out: []u8) void {
        switch (self.*) {
            .truetype => |f| f.render(glyph, f.scale(size), box, out),
            .bitmap => |*f| f.render(glyph, box, out),
        }
    }
};

/// A glyph that a chain found: the face index and the glyph in that face.
pub const Hit = struct {
    face: u32,
    glyph: u32,
};

/// The metrics `layout.zig` needs, for a font chain at one size. The first
/// face gives the line height.
pub const ChainMetrics = struct {
    faces: []const Face,
    size: f32,

    /// The first face that has a glyph for `codepoint`, or null.
    pub fn find(self: ChainMetrics, codepoint: u21) ?Hit {
        for (self.faces, 0..) |*face, i| {
            const glyph = face.glyphIndex(codepoint);
            if (glyph != 0) return .{ .face = @intCast(i), .glyph = glyph };
        }
        return null;
    }

    /// Pen movement for a code point, in pixels. A tab is four spaces.
    /// Control characters have no width, and direction controls that no face
    /// has have no width. The part of a lam-alef ligature has no width. An
    /// Arabic presentation form that no face has is as wide as its letters
    /// (REQ-TEXT-004). Another code point that no face has has the width of
    /// the replacement box.
    pub fn advance(self: ChainMetrics, codepoint: u21) f32 {
        if (codepoint == '\t') return 4 * self.advance(' ');
        if (codepoint < 0x20 or (codepoint >= 0x7F and codepoint < 0xA0)) return 0;
        if (codepoint == shape.ligature_part) return 0;
        const hit = self.find(codepoint) orelse {
            if (shape.nominal(codepoint)) |n| {
                const second = if (n.second != 0) self.advance(n.second) else 0;
                return self.advance(n.first) + second;
            }
            return if (bidi.isFormat(codepoint)) 0 else font_mod.missing_advance * self.size;
        };
        return self.faces[hit.face].advance(hit.glyph, self.size);
    }

    /// The distance between two baselines.
    pub fn lineHeight(self: ChainMetrics) f32 {
        if (self.faces.len == 0) return self.size;
        const v = self.faces[0].vmetrics(self.size);
        return v.ascent - v.descent + v.line_gap;
    }
};

const testing = std.testing;
const layout = @import("layout.zig");

// Lato, from examples/flat2d/assets (SIL Open Font License). build.zig adds
// it as the "test_font" import.
const test_font_bytes = @embedFile("test_font");

/// A bitmap font with 'A' and U+4E2D (a code point Lato does not have).
fn testBitmap() !BitmapFont {
    const px: [8 * 4]u8 = @splat(255);
    return BitmapFont.init(testing.allocator, .{
        .sheet = .{ .pixels = &px, .width = 8, .height = 4, .format = .alpha8 },
        .cell_width = 4,
        .cell_height = 4,
        .codepoints = &.{ 'A', 0x4E2D },
        .widths = &.{ 3, 4 },
    });
}

test "a chain draws a glyph from the first face that has it" {
    var faces = [_]Face{
        .{ .bitmap = try testBitmap() },
        .{ .truetype = try Font.init(testing.allocator, test_font_bytes) },
    };
    defer for (&faces) |*f| f.deinit();
    const m: ChainMetrics = .{ .faces = &faces, .size = 16 };

    // 'A' is in both faces: the first one draws it.
    try testing.expectEqual(@as(u32, 0), m.find('A').?.face);
    // 'B' is only in the second face.
    try testing.expectEqual(@as(u32, 1), m.find('B').?.face);
    // U+4E2D is only in the first face.
    try testing.expectEqual(@as(u32, 0), m.find(0x4E2D).?.face);
    // No face has U+0E01.
    try testing.expect(m.find(0x0E01) == null);

    // The advance comes from the face that has the glyph.
    try testing.expectEqual(@as(f32, 12), m.advance('A'));
    const lato = faces[1].truetype;
    try testing.expectApproxEqAbs(lato.advance(lato.glyphIndex('B'), 16), m.advance('B'), 0.001);
    try testing.expectApproxEqAbs(font_mod.missing_advance * 16, m.advance(0x0E01), 0.001);
}

test "a chain falls back to a later face for a code point the first lacks" {
    var faces = [_]Face{
        .{ .truetype = try Font.init(testing.allocator, test_font_bytes) },
        .{ .bitmap = try testBitmap() },
    };
    defer for (&faces) |*f| f.deinit();
    const m: ChainMetrics = .{ .faces = &faces, .size = 16 };
    try testing.expectEqual(@as(u32, 0), m.find('A').?.face);
    try testing.expectEqual(@as(u32, 1), m.find(0x4E2D).?.face);
    // The first face gives the line height.
    const v = faces[0].vmetrics(16);
    try testing.expectApproxEqAbs(v.ascent - v.descent + v.line_gap, m.lineHeight(), 0.001);
    // "A" + U+4E2D: Lato's A, then a bitmap cell 4 wide at scale 4.
    const lato = faces[0].truetype;
    try testing.expectApproxEqAbs(lato.advance(lato.glyphIndex('A'), 16) + 16, layout.measure(m, "A\u{4E2D}").w, 0.001);
}

test "direction controls have no width" {
    var faces = [_]Face{.{ .truetype = try Font.init(testing.allocator, test_font_bytes) }};
    defer for (&faces) |*f| f.deinit();
    const m: ChainMetrics = .{ .faces = &faces, .size = 16 };
    for ([_]u21{ 0x200E, 0x200F, 0x202B, 0x202C, 0x2066, 0x2069 }) |cp| {
        try testing.expectEqual(@as(f32, 0), m.advance(cp));
    }
}

test "a bitmap face renders through the face API" {
    var face: Face = .{ .bitmap = try testBitmap() };
    defer face.deinit();
    const box = face.bitmapBox(1, 8);
    try testing.expectEqual(@as(u32, 8), box.width());
    try testing.expectEqual(@as(i32, -8), box.y0);
    var out: [64]u8 = undefined;
    face.render(1, 8, box, &out);
    for (out) |c| try testing.expectEqual(@as(u8, 255), c);
}
