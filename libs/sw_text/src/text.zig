//! Text drawing with sw_gfx2d. Glyphs are drawn into atlas textures the first
//! time a string uses them (at one size), and a string is a run of textured
//! quads. Coordinates are logical pixels with the origin at the top left, as in
//! sw_gfx2d.
//!
//! A renderer has a chain of faces (TrueType or bitmap fonts). Each code point
//! draws with the first face that has a glyph for it. Arabic letters take
//! their joined forms (`shape.zig`), then the Unicode bidirectional algorithm
//! (`bidi.zig`) puts each line in visual order before the renderer draws it.
//! Text with no right-to-left letters skips both steps.

const std = @import("std");
const gfx = @import("sw_gfx2d");
const atlas = @import("atlas.zig");
const bidi = @import("bidi.zig");
const caret = @import("caret.zig");
const face_mod = @import("face.zig");
const font_mod = @import("font.zig");
const layout = @import("layout.zig");
const shape = @import("shape.zig");
const utf8 = @import("utf8.zig");

pub const Size = layout.Size;

/// How to draw a string.
pub const Style = struct {
    /// Pixel height from the highest ascent to the lowest descent, in logical
    /// pixels.
    size: f32 = 16,
    color: gfx.Color = gfx.Color.white,
    /// The base direction of each paragraph. `auto` takes it from the first
    /// strong letter. The text is always drawn from `x` to the right: the
    /// direction changes the order of mixed text, not the alignment.
    direction: bidi.Direction = .auto,
};

/// Width and height of the atlas textures. A glyph larger than this is not
/// drawn.
const page_size = 512;

/// The empty border round each glyph in the atlas, so linear filtering does
/// not mix in a neighbour.
const border = 1;

/// Sizes are kept to a quarter of a pixel in the glyph cache.
const size_steps_per_pixel = 4;

const Key = struct {
    face: u32,
    glyph: u32,
    size: u32,
};

/// Where a glyph is in the atlas, and where it sits against the pen.
const Glyph = struct {
    page: u32,
    /// The glyph pixels in the page. `w` or `h` is 0 for a glyph with no pixels.
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    /// Offset of the top left of the glyph from the pen on the baseline, in
    /// device pixels.
    x_off: i32,
    y_off: i32,
};

const Page = struct {
    /// RGBA, white with the glyph coverage as alpha.
    pixels: []u8,
    texture: gfx.Texture,
    packer: atlas.Packer,
    dirty: bool = false,
};

pub const TextRenderer = struct {
    alloc: std.mem.Allocator,
    /// The font chain. The first face gives the line height and the baseline.
    faces: std.ArrayList(face_mod.Face) = .empty,
    /// Device pixels for each logical pixel. Set it each frame with
    /// `setDpiScale`, from `ctx.window().dpi_scale`.
    dpi_scale: f32 = 1,
    glyphs: std.AutoHashMapUnmanaged(Key, Glyph) = .empty,
    pages: std.ArrayList(Page) = .empty,

    /// Read the font. The bytes of the .ttf file must stay valid until
    /// `deinit`. No glyph is drawn yet: glyphs are added as strings use them.
    pub fn init(alloc: std.mem.Allocator, font_bytes: []const u8) !TextRenderer {
        return initFace(alloc, .{ .truetype = try font_mod.Font.init(alloc, font_bytes) });
    }

    /// Use a bitmap font (a glyph sheet and a width table) as the first face.
    /// Draw and measure as with a TrueType font.
    pub fn initBitmap(alloc: std.mem.Allocator, desc: face_mod.BitmapFont.Desc) !TextRenderer {
        return initFace(alloc, .{ .bitmap = try face_mod.BitmapFont.init(alloc, desc) });
    }

    /// Use `face` as the first face. The renderer owns it from now on.
    pub fn initFace(alloc: std.mem.Allocator, face: face_mod.Face) !TextRenderer {
        var self: TextRenderer = .{ .alloc = alloc };
        var f = face;
        self.faces.append(alloc, f) catch |err| {
            f.deinit();
            return err;
        };
        return self;
    }

    /// Add a TrueType font to the end of the chain: it draws the code points
    /// that the faces before it do not have. The bytes must stay valid until
    /// `deinit`.
    pub fn addFont(self: *TextRenderer, font_bytes: []const u8) !void {
        try self.addFace(.{ .truetype = try font_mod.Font.init(self.alloc, font_bytes) });
    }

    /// Add a bitmap font to the end of the chain.
    pub fn addBitmapFont(self: *TextRenderer, desc: face_mod.BitmapFont.Desc) !void {
        try self.addFace(.{ .bitmap = try face_mod.BitmapFont.init(self.alloc, desc) });
    }

    /// Add a face to the end of the chain. The renderer owns it from now on.
    pub fn addFace(self: *TextRenderer, face: face_mod.Face) !void {
        var f = face;
        self.faces.append(self.alloc, f) catch |err| {
            f.deinit();
            return err;
        };
    }

    /// Free the CPU memory. The atlas textures belong to the `gfx.Renderer`
    /// and go when it goes.
    pub fn deinit(self: *TextRenderer) void {
        for (self.pages.items) |page| self.alloc.free(page.pixels);
        self.pages.deinit(self.alloc);
        self.glyphs.deinit(self.alloc);
        for (self.faces.items) |*f| f.deinit();
        self.faces.deinit(self.alloc);
    }

    pub fn setDpiScale(self: *TextRenderer, dpi_scale: f32) void {
        self.dpi_scale = if (dpi_scale > 0) dpi_scale else 1;
    }

    /// Number of glyphs in the atlas.
    pub fn glyphCount(self: *const TextRenderer) usize {
        return self.glyphs.count();
    }

    fn metrics(self: *const TextRenderer, size: f32) face_mod.ChainMetrics {
        return .{ .faces = self.faces.items, .size = size };
    }

    /// The distance between two baselines at `size`.
    pub fn lineHeight(self: *const TextRenderer, size: f32) f32 {
        return self.metrics(size).lineHeight();
    }

    /// The size of `text` on lines split at `\n`, with no wrapping. It draws
    /// nothing and adds no glyph to the atlas.
    pub fn measure(self: *const TextRenderer, text: []const u8, size: f32) Size {
        return layout.measure(self.metrics(size), text);
    }

    /// The caret and selection geometry of `text` as one line at `size`, in
    /// the visual order that `draw` uses. The caller frees it with `deinit`.
    pub fn caretLayout(self: *const TextRenderer, text: []const u8, size: f32, direction: bidi.Direction) !caret.CaretLayout {
        return caret.caretLayout(self.alloc, self.metrics(size), text, direction);
    }

    /// The size of `text` wrapped to `max_width` at spaces.
    pub fn measureWrapped(self: *const TextRenderer, text: []const u8, size: f32, max_width: f32) !Size {
        return layout.measureWrapped(self.alloc, self.metrics(size), text, max_width);
    }

    /// Draw `text` with its top left at (`x`, `y`). A `\n` starts a new line.
    /// Returns the size of the text.
    pub fn draw(self: *TextRenderer, r: *gfx.Renderer, text: []const u8, x: f32, y: f32, style: Style) !Size {
        const m = self.metrics(style.size);
        var line_y = y;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (style.direction != .rtl and bidi.isLeftToRight(line)) {
                try self.drawLogical(r, line, x, line_y, style);
            } else {
                var visual = try bidi.visual(self.alloc, line, style.direction);
                defer visual.deinit(self.alloc);
                try self.drawCodepoints(r, visual.codepoints, x, line_y, style);
            }
            line_y += m.lineHeight();
        }
        try self.upload(r);
        return layout.measure(m, text);
    }

    /// Draw `text` wrapped to `max_width`, with its top left at (`x`, `y`).
    /// Returns the size of the wrapped text.
    pub fn drawWrapped(
        self: *TextRenderer,
        r: *gfx.Renderer,
        text: []const u8,
        x: f32,
        y: f32,
        max_width: f32,
        style: Style,
    ) !Size {
        const m = self.metrics(style.size);
        const lines = try layout.wrap(self.alloc, m, text, max_width);
        defer self.alloc.free(lines);
        // Resolve the levels of each whole paragraph, then reorder each
        // wrapped line on its own (UAX #9 section 3.4).
        var paragraphs: ?bidi.Paragraphs = null;
        if (style.direction == .rtl or !bidi.isLeftToRight(text)) {
            paragraphs = try bidi.Paragraphs.init(self.alloc, text, style.direction);
        }
        defer if (paragraphs) |*p| p.deinit();
        var line_y = y;
        var width: f32 = 0;
        for (lines) |line| {
            if (paragraphs) |*p| {
                var visual = try p.line(self.alloc, line.start, line.end);
                defer visual.deinit(self.alloc);
                try self.drawCodepoints(r, visual.codepoints, x, line_y, style);
            } else {
                try self.drawLogical(r, text[line.start..line.end], x, line_y, style);
            }
            line_y += m.lineHeight();
            width = @max(width, line.width);
        }
        try self.upload(r);
        return .{ .w = width, .h = m.lineHeight() * @as(f32, @floatFromInt(lines.len)) };
    }

    /// Draw UTF-8 text that is already in visual order.
    fn drawLogical(self: *TextRenderer, r: *gfx.Renderer, line: []const u8, x: f32, y: f32, style: Style) !void {
        var pen = Pen.init(self, x, y, style);
        var it = utf8.Iterator.init(line);
        while (it.next()) |item| try self.drawCodepoint(r, &pen, item.codepoint, style);
    }

    /// Draw code points from left to right.
    fn drawCodepoints(self: *TextRenderer, r: *gfx.Renderer, codepoints: []const u21, x: f32, y: f32, style: Style) !void {
        var pen = Pen.init(self, x, y, style);
        for (codepoints) |cp| try self.drawCodepoint(r, &pen, cp, style);
    }

    const Pen = struct {
        x: f32,
        baseline: f32,
        ascent: f32,

        fn init(self: *const TextRenderer, x: f32, y: f32, style: Style) Pen {
            const ascent = if (self.faces.items.len > 0) self.faces.items[0].vmetrics(style.size).ascent else style.size;
            return .{ .x = x, .baseline = y + ascent, .ascent = ascent };
        }
    };

    fn drawCodepoint(self: *TextRenderer, r: *gfx.Renderer, pen: *Pen, cp: u21, style: Style) !void {
        const m = self.metrics(style.size);
        const dpi = self.dpi_scale;
        if (cp <= ' ' or (cp >= 0x7F and cp < 0xA0)) {
            pen.x += m.advance(cp);
            return;
        }

        if (cp == shape.ligature_part) return;
        const hit = m.find(cp) orelse {
            if (shape.nominal(cp)) |n| {
                // No face has this Arabic presentation form: draw its letter
                // in the nominal form (REQ-TEXT-004). For a lam-alef
                // ligature, draw alef then lam, the right-to-left order of
                // the two letters.
                if (n.second != 0) try self.drawCodepoint(r, pen, n.second, style);
                try self.drawCodepoint(r, pen, n.first, style);
                return;
            }
            const advance = m.advance(cp);
            defer pen.x += advance;
            if (bidi.isFormat(cp)) return;
            // No face has a glyph: draw a box, so the gap is visible.
            const box_h = pen.ascent * 0.8;
            try r.strokeRect(.{
                .x = pen.x + advance * 0.1,
                .y = pen.baseline - box_h,
                .w = advance * 0.8,
                .h = box_h,
            }, @max(1, style.size / 16), style.color);
            return;
        };

        defer pen.x += self.faces.items[hit.face].advance(hit.glyph, style.size);
        const g = (try self.glyphFor(r, hit, style.size * dpi)) orelse return;
        if (g.w == 0 or g.h == 0) return;
        const page = self.pages.items[g.page];
        // Put the glyph on whole device pixels, so it stays sharp.
        const left = @round(pen.x * dpi) + @as(f32, @floatFromInt(g.x_off));
        const top = @round(pen.baseline * dpi) + @as(f32, @floatFromInt(g.y_off));
        const w: f32 = @floatFromInt(g.w);
        const h: f32 = @floatFromInt(g.h);
        try r.drawTexture(
            page.texture,
            .{ .x = left / dpi, .y = top / dpi, .w = w / dpi, .h = h / dpi },
            .{ .x = @floatFromInt(g.x), .y = @floatFromInt(g.y), .w = w, .h = h },
            style.color,
        );
    }

    /// The atlas entry for a glyph at a size, drawn into the atlas on first
    /// use. Null if the glyph does not fit in a page.
    fn glyphFor(self: *TextRenderer, r: *gfx.Renderer, hit: face_mod.Hit, device_size: f32) !?Glyph {
        const steps: f32 = @round(device_size * size_steps_per_pixel);
        const key: Key = .{ .face = hit.face, .glyph = hit.glyph, .size = @intFromFloat(@max(steps, 1)) };
        if (self.glyphs.get(key)) |g| return g;

        const px = @as(f32, @floatFromInt(key.size)) / size_steps_per_pixel;
        const face = &self.faces.items[hit.face];
        const box = face.bitmapBox(hit.glyph, px);
        var g: Glyph = .{
            .page = 0,
            .x = 0,
            .y = 0,
            .w = box.width(),
            .h = box.height(),
            .x_off = box.x0,
            .y_off = box.y0,
        };
        if (g.w > 0 and g.h > 0) {
            const coverage = try self.alloc.alloc(u8, @as(usize, g.w) * g.h);
            defer self.alloc.free(coverage);
            @memset(coverage, 0);
            face.render(hit.glyph, px, box, coverage);

            const spot = (try self.reserve(r, g.w + 2 * border, g.h + 2 * border)) orelse return null;
            g.page = spot.page;
            g.x = spot.pos.x + border;
            g.y = spot.pos.y + border;
            self.blit(spot.page, g, coverage);
        }
        try self.glyphs.put(self.alloc, key, g);
        return g;
    }

    const Spot = struct { page: u32, pos: atlas.Pos };

    /// Find room for a rectangle in a page, or start a new page.
    fn reserve(self: *TextRenderer, r: *gfx.Renderer, w: u32, h: u32) !?Spot {
        if (w > page_size or h > page_size) return null;
        for (self.pages.items, 0..) |*page, i| {
            if (page.packer.alloc(w, h)) |pos| return .{ .page = @intCast(i), .pos = pos };
        }

        const pixels = try self.alloc.alloc(u8, page_size * page_size * 4);
        errdefer self.alloc.free(pixels);
        @memset(pixels, 0);
        const texture = try r.createTexture(page_size, page_size, pixels, .linear);
        try self.pages.append(self.alloc, .{
            .pixels = pixels,
            .texture = texture,
            .packer = atlas.Packer.init(page_size),
        });
        const last = self.pages.items.len - 1;
        const pos = self.pages.items[last].packer.alloc(w, h) orelse return null;
        return .{ .page = @intCast(last), .pos = pos };
    }

    fn blit(self: *TextRenderer, page_index: u32, g: Glyph, coverage: []const u8) void {
        const page = &self.pages.items[page_index];
        var row: u32 = 0;
        while (row < g.h) : (row += 1) {
            var col: u32 = 0;
            while (col < g.w) : (col += 1) {
                const dst = ((@as(usize, g.y + row) * page_size) + g.x + col) * 4;
                page.pixels[dst] = 255;
                page.pixels[dst + 1] = 255;
                page.pixels[dst + 2] = 255;
                page.pixels[dst + 3] = coverage[@as(usize, row) * g.w + col];
            }
        }
        page.dirty = true;
    }

    /// Send the pages that got new glyphs to the GPU.
    fn upload(self: *TextRenderer, r: *gfx.Renderer) !void {
        for (self.pages.items) |*page| {
            if (!page.dirty) continue;
            try r.updateTexture(page.texture, page.pixels);
            page.dirty = false;
        }
    }
};

const testing = std.testing;

// Lato, from examples/flat2d/assets (SIL Open Font License). build.zig adds
// it as the "test_font" import.
const test_font_bytes = @embedFile("test_font");

/// A 2x1 sheet of 4x4 cells, all set: 'A' and U+4E2D.
fn testBitmapDesc(pixels: []const u8) face_mod.BitmapFont.Desc {
    return .{
        .sheet = .{ .pixels = pixels, .width = 8, .height = 4, .format = .alpha8 },
        .cell_width = 4,
        .cell_height = 4,
        .codepoints = &.{ 'A', 0x4E2D },
        .widths = &.{ 3, 4 },
    };
}

test "a bitmap font measures with the same API as a TrueType font" {
    const px: [32]u8 = @splat(255);
    var t = try TextRenderer.initBitmap(testing.allocator, testBitmapDesc(&px));
    defer t.deinit();
    // Size 8 is a scale of 2: 'A' is 6 wide and U+4E2D is 8 wide.
    const size = t.measure("AA\u{4E2D}", 8);
    try testing.expectEqual(@as(f32, 20), size.w);
    try testing.expectEqual(@as(f32, 8), size.h);
    try testing.expectEqual(@as(f32, 8), t.lineHeight(8));
    // The sheet has no space: it is as wide as the missing box (0.6 em).
    const wrapped = try t.measureWrapped("A A A", 8, 17);
    try testing.expectEqual(@as(f32, 16), wrapped.h);
}

test "a fallback face measures the code points the first face lacks" {
    const px: [32]u8 = @splat(255);
    var t = try TextRenderer.init(testing.allocator, test_font_bytes);
    defer t.deinit();
    const before = t.measure("\u{4E2D}", 16).w;
    try t.addBitmapFont(testBitmapDesc(&px));
    try testing.expectEqual(@as(usize, 2), t.faces.items.len);
    // Lato has no U+4E2D: the bitmap face gives its width (4 at scale 4).
    try testing.expectEqual(@as(f32, 16), t.measure("\u{4E2D}", 16).w);
    try testing.expect(before != 16);
    // Lato still draws 'A', and the line height is Lato's.
    var lato = try font_mod.Font.init(testing.allocator, test_font_bytes);
    defer lato.deinit();
    try testing.expectApproxEqAbs(lato.advance(lato.glyphIndex('A'), 16), t.measure("A", 16).w, 0.001);
    const m: font_mod.Metrics = .{ .font = &lato, .size = 16 };
    try testing.expectApproxEqAbs(m.lineHeight(), t.lineHeight(16), 0.001);
}

test "a second TrueType font can be added to the chain" {
    var t = try TextRenderer.init(testing.allocator, test_font_bytes);
    defer t.deinit();
    try t.addFont(test_font_bytes);
    try testing.expectEqual(@as(usize, 2), t.faces.items.len);
    try testing.expectError(error.InvalidFont, t.addFont(""));
    try testing.expectEqual(@as(usize, 2), t.faces.items.len);
}

/// A bitmap font of 4x4 cells with a few Arabic letters and forms. It has
/// beh in its initial and final forms, and the isolated lam-alef ligature.
/// It does not have medial beh or the final lam-alef ligature.
fn testArabicDesc(pixels: []const u8) face_mod.BitmapFont.Desc {
    return .{
        .sheet = .{ .pixels = pixels, .width = 24, .height = 4, .format = .alpha8 },
        .cell_width = 4,
        .cell_height = 4,
        .codepoints = &.{ 0x0628, 0x0644, 0x0627, 0xFE91, 0xFE90, 0xFEFB },
        .widths = &.{ 3, 3, 1, 2, 4, 2 },
    };
}

/// The pen movement of `draw` for `text` as one line: the advances of the
/// code points in the order that `draw` gives them to `drawCodepoint`.
fn drawWidth(t: *const TextRenderer, text: []const u8, size: f32) !f32 {
    const m = t.metrics(size);
    var width: f32 = 0;
    if (bidi.isLeftToRight(text)) {
        var it = utf8.Iterator.init(text);
        while (it.next()) |item| width += m.advance(item.codepoint);
        return width;
    }
    var v = try bidi.visual(t.alloc, text, .auto);
    defer v.deinit(t.alloc);
    for (v.codepoints) |cp| width += m.advance(cp);
    return width;
}

fn expectArabicWidth(t: *const TextRenderer, text: []const u8, want: f32) !void {
    try testing.expectEqual(want, t.measure(text, 4).w);
    try testing.expectEqual(want, try drawWidth(t, text, 4));
    var c = try t.caretLayout(text, 4, .auto);
    defer c.deinit();
    try testing.expectEqual(want, c.total);
}

test "measure, draw and the caret layout agree on shaped Arabic text" {
    const px: [96]u8 = @splat(255);
    var t = try TextRenderer.initBitmap(testing.allocator, testArabicDesc(&px));
    defer t.deinit();
    // Size 4 is a scale of 1. Beh beh: initial (2) and final (4), not two
    // nominal behs (3 + 3).
    try expectArabicWidth(&t, "\u{628}\u{628}", 6);
    // Lam alef: the isolated ligature (2).
    try expectArabicWidth(&t, "\u{644}\u{627}", 2);
}

test "a font that lacks a presentation form draws the letter" {
    const px: [96]u8 = @splat(255);
    var t = try TextRenderer.initBitmap(testing.allocator, testArabicDesc(&px));
    defer t.deinit();
    const m = t.metrics(4);
    // No medial beh: it is as wide as the nominal beh (3).
    try testing.expect(m.find(0xFE92) == null);
    try testing.expectEqual(@as(f32, 3), m.advance(0xFE92));
    try expectArabicWidth(&t, "\u{628}\u{628}\u{628}", 2 + 3 + 4);
    // No final lam-alef ligature: lam (3) and alef (1).
    try testing.expectEqual(@as(f32, 4), m.advance(0xFEFC));
    try expectArabicWidth(&t, "\u{628}\u{644}\u{627}", 2 + 4);
    // The part of the ligature has no width.
    try testing.expectEqual(@as(f32, 0), m.advance(shape.ligature_part));
}

test "a later face gives the presentation forms that the first face lacks" {
    const px: [96]u8 = @splat(255);
    var t = try TextRenderer.init(testing.allocator, test_font_bytes);
    defer t.deinit();
    try t.addBitmapFont(testArabicDesc(&px));
    // Lato has no Arabic. The bitmap face draws the shaped letters, and
    // Lato draws the Latin letters and the space.
    const lato = t.faces.items[0].truetype;
    const latin = lato.advance(lato.glyphIndex('a'), 4) + lato.advance(lato.glyphIndex(' '), 4);
    try testing.expectEqual(@as(u32, 1), t.metrics(4).find(0xFE91).?.face);
    const text = "a \u{628}\u{628}";
    try testing.expectApproxEqAbs(latin + 6, t.measure(text, 4).w, 0.001);
    try testing.expectApproxEqAbs(latin + 6, try drawWidth(&t, text, 4), 0.001);
}

test "Latin text is not shaped and keeps the fast path" {
    var t = try TextRenderer.init(testing.allocator, test_font_bytes);
    defer t.deinit();
    const text = "Hello, world 123";
    try testing.expect(bidi.isLeftToRight(text));
    try testing.expect(!shape.needsShaping(text));
    const m = t.metrics(16);
    var want: f32 = 0;
    var it = utf8.Iterator.init(text);
    while (it.next()) |item| want += m.advance(item.codepoint);
    try testing.expectEqual(want, t.measure(text, 16).w);
    try testing.expectEqual(want, try drawWidth(&t, text, 16));
}
