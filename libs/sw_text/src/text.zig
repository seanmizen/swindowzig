//! Text drawing with sw_gfx2d. Glyphs are drawn into atlas textures the first
//! time a string uses them (at one size), and a string is a run of textured
//! quads. Coordinates are logical pixels with the origin at the top left, as in
//! sw_gfx2d.

const std = @import("std");
const gfx = @import("sw_gfx2d");
const atlas = @import("atlas.zig");
const font_mod = @import("font.zig");
const layout = @import("layout.zig");
const utf8 = @import("utf8.zig");

pub const Size = layout.Size;

/// How to draw a string.
pub const Style = struct {
    /// Pixel height from the highest ascent to the lowest descent, in logical
    /// pixels.
    size: f32 = 16,
    color: gfx.Color = gfx.Color.white,
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
    font: font_mod.Font,
    /// Device pixels for each logical pixel. Set it each frame with
    /// `setDpiScale`, from `ctx.window().dpi_scale`.
    dpi_scale: f32 = 1,
    glyphs: std.AutoHashMapUnmanaged(Key, Glyph) = .empty,
    pages: std.ArrayList(Page) = .empty,

    /// Read the font. The bytes of the .ttf file must stay valid until
    /// `deinit`. No glyph is drawn yet: glyphs are added as strings use them.
    pub fn init(alloc: std.mem.Allocator, font_bytes: []const u8) !TextRenderer {
        return .{ .alloc = alloc, .font = try font_mod.Font.init(alloc, font_bytes) };
    }

    /// Free the CPU memory. The atlas textures belong to the `gfx.Renderer`
    /// and go when it goes.
    pub fn deinit(self: *TextRenderer) void {
        for (self.pages.items) |page| self.alloc.free(page.pixels);
        self.pages.deinit(self.alloc);
        self.glyphs.deinit(self.alloc);
        self.font.deinit();
    }

    pub fn setDpiScale(self: *TextRenderer, dpi_scale: f32) void {
        self.dpi_scale = if (dpi_scale > 0) dpi_scale else 1;
    }

    /// Number of glyphs in the atlas.
    pub fn glyphCount(self: *const TextRenderer) usize {
        return self.glyphs.count();
    }

    fn metrics(self: *const TextRenderer, size: f32) font_mod.Metrics {
        return .{ .font = &self.font, .size = size };
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
            try self.drawLine(r, line, x, line_y, style);
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
        var line_y = y;
        var width: f32 = 0;
        for (lines) |line| {
            try self.drawLine(r, text[line.start..line.end], x, line_y, style);
            line_y += m.lineHeight();
            width = @max(width, line.width);
        }
        try self.upload(r);
        return .{ .w = width, .h = m.lineHeight() * @as(f32, @floatFromInt(lines.len)) };
    }

    fn drawLine(self: *TextRenderer, r: *gfx.Renderer, line: []const u8, x: f32, y: f32, style: Style) !void {
        const m = self.metrics(style.size);
        const v = self.font.vmetrics(style.size);
        const dpi = self.dpi_scale;
        const baseline = y + v.ascent;
        const device_size = style.size * dpi;
        var pen = x;

        var it = utf8.Iterator.init(line);
        while (it.next()) |item| {
            const cp = item.codepoint;
            const advance = m.advance(cp);
            defer pen += advance;
            if (cp <= ' ' or (cp >= 0x7F and cp < 0xA0)) continue;

            const glyph_index = self.font.glyphIndex(cp);
            if (glyph_index == 0) {
                // The font has no glyph: draw a box, so the gap is visible.
                const box_h = v.ascent * 0.8;
                try r.strokeRect(.{
                    .x = pen + advance * 0.1,
                    .y = baseline - box_h,
                    .w = advance * 0.8,
                    .h = box_h,
                }, @max(1, style.size / 16), style.color);
                continue;
            }

            const g = (try self.glyphFor(r, glyph_index, device_size)) orelse continue;
            if (g.w == 0 or g.h == 0) continue;
            const page = self.pages.items[g.page];
            // Put the glyph on whole device pixels, so it stays sharp.
            const left = @round(pen * dpi) + @as(f32, @floatFromInt(g.x_off));
            const top = @round(baseline * dpi) + @as(f32, @floatFromInt(g.y_off));
            const w: f32 = @floatFromInt(g.w);
            const h: f32 = @floatFromInt(g.h);
            try r.drawTexture(
                page.texture,
                .{ .x = left / dpi, .y = top / dpi, .w = w / dpi, .h = h / dpi },
                .{ .x = @floatFromInt(g.x), .y = @floatFromInt(g.y), .w = w, .h = h },
                style.color,
            );
        }
    }

    /// The atlas entry for a glyph at a size, drawn into the atlas on first
    /// use. Null if the glyph does not fit in a page.
    fn glyphFor(self: *TextRenderer, r: *gfx.Renderer, glyph_index: u32, device_size: f32) !?Glyph {
        const steps: f32 = @round(device_size * size_steps_per_pixel);
        const key: Key = .{ .glyph = glyph_index, .size = @intFromFloat(@max(steps, 1)) };
        if (self.glyphs.get(key)) |g| return g;

        const px = @as(f32, @floatFromInt(key.size)) / size_steps_per_pixel;
        const scale = self.font.scale(px);
        const box = self.font.bitmapBox(glyph_index, scale);
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
            self.font.render(glyph_index, scale, box, coverage);

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
