// flat2d - the 2D renderer (sw_gfx2d): filled rectangles, an outline, a
// textured quad with a tint and a source rectangle, alpha blending, and text
// from a TTF font (sw_text): a paragraph with accents, wrapped to a width. It
// also loads sprite.png (next to this file) with sw_assets and draws it.
// Drawing is in logical pixels, origin at the top left.
//
// The text box at the bottom uses the platform input method. Click it, then
// type. A dead key works: the accent key, then "e", gives the committed
// "é". An IME shows its composition text in a second colour until you
// accept it. Each code point is a colour block and the string goes to the
// log.
const std = @import("std");
const builtin = @import("builtin");
const sw = @import("sw_app");
const gfx = @import("sw_gfx2d");
const sw_text = @import("sw_text");
const assets = @import("sw_assets");

// Freestanding WASM has no std.process.Init, so the web build gets a main
// with no parameters. The native build passes Io to the app (ctx.io).
pub const main = if (builtin.cpu.arch.isWasm()) mainWasm else mainNative;

fn mainWasm() !void {
    try sw.run(config, Callbacks);
}

fn mainNative(init: std.process.Init) !void {
    var c = config;
    c.io = init.io;
    // A relative path reads a file in this directory. `zig build run` runs
    // from the package root.
    assets.useDirectoryPath(init.io, "examples/flat2d") catch |err| {
        std.log.warn("flat2d: no asset directory: {s}", .{@errorName(err)});
    };
    try sw.run(c, Callbacks);
}

const config: sw.Config = .{
    .title = "flat2d",
    .size = .{ .w = 800, .h = 600 },
    .tick_hz = 60,
};

const checker_size = 16;
const checker_cell = 4;

var renderer: ?gfx.Renderer = null;
var checker: gfx.Texture = .{ .id = 0, .width = 1, .height = 1 };
var ticks: u32 = 0;
var text_renderer: ?sw_text.TextRenderer = null;

// Lato, under the SIL Open Font License (assets/Lato-OFL.txt).
const font_bytes = @embedFile("assets/Lato-Regular.ttf");

const paragraph_x = 620;
const paragraph_width = 160;
const paragraph =
    "Zażółć gęślą jaźń. Crème brûlée, façade, Ångström, piñata, " ++
    "Müller, größer, naïve café, Čeština, Ğ, Ő, Ž. " ++
    "No glyph for 中, so a box.";

// The text box: the committed text (UTF-8), the text in composition, and focus.
const box = struct {
    const x: f32 = 40;
    const y: f32 = 540;
    const w: f32 = 720;
    const h: f32 = 44;
};
const glyph_w = 12;
const glyph_step = 16;
var typed: [256]u8 = undefined;
var typed_len: usize = 0;
var composing: [64]u8 = undefined;
var composing_len: usize = 0;
var box_focused = false;

fn insideBox(x: f32, y: f32) bool {
    return x >= box.x and x < box.x + box.w and y >= box.y and y < box.y + box.h;
}

/// Remove the last code point from the committed text.
fn eraseLast() void {
    if (typed_len == 0) return;
    typed_len -= 1;
    while (typed_len > 0 and (typed[typed_len] & 0xC0) == 0x80) typed_len -= 1;
}

/// A colour that depends on the code point, so each character looks different.
fn glyphColor(cp: u21, alpha: u8) gfx.Color {
    const h: u32 = @as(u32, cp) *% 2654435761;
    const r: u8 = 96 + @as(u8, @intCast(h & 0x7f));
    const g: u8 = 96 + @as(u8, @intCast((h >> 7) & 0x7f));
    const b: u8 = 96 + @as(u8, @intCast((h >> 14) & 0x7f));
    return gfx.Color.rgba8(r, g, b, alpha);
}

/// Draw one block per code point of `text`, from `index`. Returns the next index.
fn drawGlyphs(r: *gfx.Renderer, text: []const u8, first_index: usize, alpha: u8) !usize {
    var index = first_index;
    var it = (std.unicode.Utf8View.init(text) catch return index).iterator();
    while (it.nextCodepoint()) |cp| : (index += 1) {
        const gx = box.x + 12 + @as(f32, @floatFromInt(index)) * glyph_step;
        if (gx + glyph_w > box.x + box.w - 12) break;
        try r.fillRect(.{ .x = gx, .y = box.y + 10, .w = glyph_w, .h = box.h - 20 }, glyphColor(cp, alpha));
    }
    return index;
}

// sprite.png: `sprite_request` is set while the load runs, `sprite` when the
// texture is ready.
var sprite_request: ?assets.Request = null;
var sprite: ?gfx.Texture = null;

/// Check the load of sprite.png. The frame does not wait for it.
fn pollSprite(ctx: *sw.Context, r: *gfx.Renderer) void {
    const request = if (sprite_request) |*p| p else return;
    switch (request.poll()) {
        .pending => {},
        .bytes => |data| {
            defer ctx.allocator().free(data);
            sprite_request = null;
            sprite = r.createTextureFromPng(data, .nearest) catch |err| {
                std.log.warn("flat2d: sprite.png: {s}", .{@errorName(err)});
                return;
            };
        },
        .failed => |err| {
            sprite_request = null;
            std.log.warn("flat2d: sprite.png: {s}", .{assets.errorMessage(err)});
        },
    }
}

/// A 16x16 checkerboard in four colours, so a source rectangle shows.
fn makeChecker() [checker_size * checker_size * 4]u8 {
    var pixels: [checker_size * checker_size * 4]u8 = undefined;
    for (0..checker_size) |y| {
        for (0..checker_size) |x| {
            const odd = ((x / checker_cell) + (y / checker_cell)) % 2 == 1;
            const left = x < checker_size / 2;
            const top = y < checker_size / 2;
            const rgb: [3]u8 = if (odd)
                .{ 30, 30, 40 }
            else if (left and top)
                .{ 240, 90, 70 }
            else if (top)
                .{ 250, 210, 80 }
            else if (left)
                .{ 90, 200, 120 }
            else
                .{ 90, 150, 240 };
            const i = (y * checker_size + x) * 4;
            pixels[i] = rgb[0];
            pixels[i + 1] = rgb[1];
            pixels[i + 2] = rgb[2];
            pixels[i + 3] = 255;
        }
    }
    return pixels;
}

const Callbacks = struct {
    pub fn init(ctx: *sw.Context) !void {
        const gpu = ctx.gpu();
        if (!gpu.isReady()) return;
        var r = try gfx.Renderer.init(ctx.allocator(), gpu, .{});
        const pixels = makeChecker();
        checker = try r.createTexture(checker_size, checker_size, &pixels, .nearest);
        renderer = r;
        text_renderer = try sw_text.TextRenderer.init(ctx.allocator(), font_bytes);
        sprite_request = try assets.loadBytes(ctx.allocator(), "sprite.png");
        std.log.info("flat2d: GPU ready", .{});
    }

    pub fn tick(ctx: *sw.Context) !void {
        ticks +%= 1;

        const input = ctx.input();

        // A click in the box starts text input. A click outside, or Escape, stops it.
        if (input.buttonPressed(.left)) {
            const inside = insideBox(input.mouse.x, input.mouse.y);
            if (inside and !box_focused) ctx.startTextInput();
            if (!inside and box_focused) ctx.stopTextInput();
            box_focused = inside;
        }
        if (box_focused and input.keyPressed(.Escape)) {
            ctx.stopTextInput();
            box_focused = false;
        }
        if (!box_focused) {
            composing_len = 0;
            return;
        }

        const before = typed_len;
        const committed = input.text.text();
        if (std.unicode.utf8ValidateSlice(committed) and typed_len + committed.len <= typed.len) {
            @memcpy(typed[typed_len..][0..committed.len], committed);
            typed_len += committed.len;
        }
        if (input.keyPressed(.Backspace)) eraseLast();
        if (input.keyPressed(.Enter)) {
            std.log.info("flat2d: text box submitted \"{s}\"", .{typed[0..typed_len]});
            typed_len = 0;
        }

        const comp = input.composition.text();
        @memcpy(composing[0..comp.len], comp);
        composing_len = comp.len;

        if (typed_len != before or committed.len > 0) {
            std.log.info("flat2d: text box = \"{s}\"", .{typed[0..typed_len]});
        }
    }

    pub fn render(ctx: *sw.Context) !void {
        const gpu = ctx.gpu();
        if (!gpu.isReady()) return;
        const r = if (renderer) |*p| p else return;

        pollSprite(ctx, r);

        const win = ctx.window();
        r.beginFrame(win.width, win.height, win.dpi_scale);

        // Solid rectangles.
        try r.fillRect(.{ .x = 40, .y = 40, .w = 200, .h = 120 }, gfx.Color.rgba8(230, 80, 70, 255));
        try r.fillRect(.{ .x = 140, .y = 100, .w = 200, .h = 120 }, gfx.Color.rgba8(70, 140, 230, 255));
        // Alpha blending: this one lets both rectangles show through.
        try r.fillRect(.{ .x = 90, .y = 70, .w = 200, .h = 120 }, gfx.Color.rgba8(250, 230, 80, 128));

        // An outline, 6 logical pixels wide.
        try r.strokeRect(.{ .x = 380, .y = 40, .w = 220, .h = 140 }, 6, gfx.Color.rgba8(240, 240, 240, 255));

        // The whole texture, then one quarter of it, then a tinted copy.
        try r.drawTexture(checker, .{ .x = 40, .y = 280, .w = 160, .h = 160 }, null, gfx.Color.white);
        try r.drawTexture(
            checker,
            .{ .x = 230, .y = 280, .w = 160, .h = 160 },
            .{ .x = 0, .y = 0, .w = checker_size / 2, .h = checker_size / 2 },
            gfx.Color.white,
        );
        try r.drawTexture(
            checker,
            .{ .x = 420, .y = 280, .w = 160, .h = 160 },
            null,
            gfx.Color.rgba8(120, 200, 255, 200),
        );

        // The PNG from a file, 8x8 texels drawn at 16 times the size. It
        // appears after the load finishes.
        if (sprite) |tex| {
            try r.drawTexture(tex, .{ .x = 620, .y = 280, .w = 128, .h = 128 }, null, gfx.Color.white);
        }

        // A rectangle that moves, to show the frame is redrawn.
        const t: f32 = @floatFromInt(ticks);
        const x = 40 + 300 * (0.5 + 0.5 * @sin(t / 40.0));
        try r.fillRect(.{ .x = x, .y = 480, .w = 60, .h = 40 }, gfx.Color.rgba8(120, 230, 160, 255));

        // Text: a heading, then a paragraph wrapped to a width. The outline
        // shows the width.
        if (text_renderer) |*tr| {
            tr.setDpiScale(win.dpi_scale);
            const white = gfx.Color.rgba8(240, 240, 240, 255);
            _ = try tr.draw(r, "Text (TTF)", paragraph_x, 40, .{ .size = 20, .color = white });
            const size = try tr.drawWrapped(r, paragraph, paragraph_x, 76, paragraph_width, .{
                .size = 14,
                .color = gfx.Color.rgba8(250, 210, 80, 255),
            });
            try r.strokeRect(.{ .x = paragraph_x - 4, .y = 72, .w = paragraph_width + 8, .h = size.h + 8 }, 1, gfx.Color.rgba8(90, 90, 110, 255));
        }

        // The text box. Committed text is opaque. Text in composition is faint.
        const edge = if (box_focused)
            gfx.Color.rgba8(120, 200, 255, 255)
        else
            gfx.Color.rgba8(120, 120, 140, 255);
        try r.fillRect(.{ .x = box.x, .y = box.y, .w = box.w, .h = box.h }, gfx.Color.rgba8(20, 20, 30, 255));
        try r.strokeRect(.{ .x = box.x, .y = box.y, .w = box.w, .h = box.h }, 2, edge);
        const after_typed = try drawGlyphs(r, typed[0..typed_len], 0, 255);
        const after_comp = try drawGlyphs(r, composing[0..composing_len], after_typed, 140);
        if (box_focused and (ticks / 30) % 2 == 0) {
            const cx = box.x + 12 + @as(f32, @floatFromInt(after_comp)) * glyph_step;
            try r.fillRect(.{ .x = cx, .y = box.y + 8, .w = 2, .h = box.h - 16 }, gfx.Color.white);
        }

        var view_tex = try gpu.getCurrentTextureView();
        const encoder = try gpu.createCommandEncoder();
        const pass = try encoder.beginRenderPass(.{
            .color_attachments = &[_]sw.gpu_types.RenderPassColorAttachment{.{
                .view = &view_tex,
                .load_op = .clear,
                .store_op = .store,
                .clear_value = .{ .r = 0.08, .g = 0.08, .b = 0.12, .a = 1.0 },
            }},
        });
        try r.flush(pass);
        pass.end();

        const cmd = try encoder.finish();
        gpu.submit(&[_]sw.gpu_types.CommandBuffer{cmd});
        view_tex.release();
        gpu.present();
    }

    pub fn shutdown(ctx: *sw.Context) !void {
        _ = ctx;
        if (text_renderer) |*tr| tr.deinit();
        text_renderer = null;
        if (renderer) |*r| r.deinit();
        renderer = null;
    }
};
