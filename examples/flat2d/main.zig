// flat2d - the 2D renderer (sw_gfx2d): filled rectangles, an outline, a
// textured quad with a tint and a source rectangle, alpha blending, and text
// from a TTF font (sw_text): a paragraph with accents, wrapped to a width. It
// also loads sprite.png (next to this file) with sw_assets and draws it.
// Drawing is in logical pixels, origin at the top left.
//
// The UI (sw_ui) is a menu and a text field. It works with the keyboard only:
// Tab and Shift+Tab move focus, the arrow keys move inside the list, Enter and
// Space activate, and Escape opens or closes the menu. The text field uses the
// platform input method: focus it, then type. A dead key works: the accent key,
// then "e", gives the committed "é". The focused node has a yellow ring.
const std = @import("std");
const builtin = @import("builtin");
const sw = @import("sw_app");
const gfx = @import("sw_gfx2d");
const sw_text = @import("sw_text");
const sw_ui = @import("sw_ui");
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

// The UI. `ui_state` is made in init, after the font, because it measures text
// with it. Ids are fixed numbers, so the focus stays on a node between frames.
var ui_state: ?sw_ui.Ui = null;
var name_storage: [64]u8 = undefined;
var name_value: sw_ui.TextValue = .{ .buffer = &name_storage };
var menu_open = true;
var accent: usize = 0;

const ids = struct {
    const main_area: u32 = 1;
    const menu: u32 = 2;
    const title: u32 = 3;
    const accent_list: u32 = 4;
    const status: u32 = 5;
    const close: u32 = 6;
    const open: u32 = 7;
    const bottom: u32 = 8;
    const name_field: u32 = 9;
    /// The list items are accent_item + index.
    const accent_item: u32 = 100;
};

const Accent = struct { name: []const u8, color: gfx.Color };
const accents = [_]Accent{
    .{ .name = "Green", .color = gfx.Color.rgba8(120, 230, 160, 255) },
    .{ .name = "Orange", .color = gfx.Color.rgba8(250, 160, 70, 255) },
    .{ .name = "Pink", .color = gfx.Color.rgba8(240, 120, 200, 255) },
};

/// The engine input in the form that the UI reads.
fn uiInput(ctx: *sw.Context) sw_ui.Input {
    const input = ctx.input();
    return .{
        .keys = .{
            .tab = input.keyPressed(.Tab),
            .up = input.keyPressed(.Up),
            .down = input.keyPressed(.Down),
            .left = input.keyPressed(.Left),
            .right = input.keyPressed(.Right),
            .enter = input.keyPressed(.Enter),
            .space = input.keyPressed(.Space),
            .escape = input.keyPressed(.Escape),
            .backspace = input.keyPressed(.Backspace),
        },
        .shift = input.mods.shift,
        .pointer_x = input.mouse.x,
        .pointer_y = input.mouse.y,
        .pointer_pressed = input.buttonPressed(.left),
        .text = input.text.text(),
        .composition = input.composition.text(),
    };
}

/// Build the UI of this frame: the menu (or a button that opens it) in the
/// middle, and the text field at the bottom.
fn buildUi(u: *sw_ui.Ui, input: sw_ui.Input, width: f32, height: f32) !void {
    try u.begin(input, width, height);

    try u.beginColumn(ids.main_area, .{ .w = .fill, .h = .fill, .main_align = .center, .cross_align = .center });
    if (menu_open) {
        try u.beginColumn(ids.menu, .{ .padding = 16, .gap = 8, .panel = true, .label = "Menu" });
        try u.addText(ids.title, "Menu: Tab, arrows, Enter, Esc", .{});
        try u.beginList(ids.accent_list, "Accent colour", .{ .w = .fill });
        for (accents, 0..) |a, i| {
            try u.addListItem(ids.accent_item + @as(u32, @intCast(i)), a.name, .{ .w = .fill, .selected = i == accent });
        }
        u.endContainer();
        // A live region: assistive technology announces the change.
        try u.addText(ids.status, try u.print("Accent: {s}", .{accents[accent].name}), .{ .live = true });
        try u.addButton(ids.close, "Close menu", .{});
        u.endContainer();
    } else {
        try u.addButton(ids.open, "Open menu (Esc)", .{});
    }
    u.endContainer();

    try u.beginRow(ids.bottom, .{ .w = .fill, .padding = 16 });
    try u.addTextField(ids.name_field, "Name", &name_value, .{ .w = .fill });
    u.endContainer();

    try u.finish();
}

/// React to the events of the UI.
fn handleUiEvents(ctx: *sw.Context, u: *sw_ui.Ui) void {
    for (u.frameEvents()) |e| {
        switch (e.kind) {
            .activate => {
                if (e.id >= ids.accent_item and e.id < ids.accent_item + @as(u32, accents.len)) {
                    accent = e.id - ids.accent_item;
                } else if (e.id == ids.close) {
                    menu_open = false;
                    u.setFocus(ids.open);
                } else if (e.id == ids.open) {
                    menu_open = true;
                    u.setFocus(ids.accent_item + @as(u32, @intCast(accent)));
                }
            },
            .cancel => {
                // Escape leaves the text field first. Otherwise it toggles the menu.
                const in_field = if (u.focused()) |f| f == ids.name_field else false;
                if (in_field) {
                    u.clearFocus();
                } else if (menu_open) {
                    menu_open = false;
                    u.setFocus(ids.open);
                } else {
                    menu_open = true;
                    u.setFocus(ids.accent_item + @as(u32, @intCast(accent)));
                }
            },
            .changed => std.log.info("flat2d: name = \"{s}\"", .{name_value.slice()}),
            .submit => {
                std.log.info("flat2d: name submitted \"{s}\"", .{name_value.slice()});
                name_value.clear();
            },
        }
    }

    // The platform input method is on while a text field has focus.
    const wanted = u.wantsTextInput();
    if (wanted and !ctx.isTextInputActive()) ctx.startTextInput();
    if (!wanted and ctx.isTextInputActive()) ctx.stopTextInput();
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
        if (text_renderer) |*tr| {
            ui_state = sw_ui.Ui.init(ctx.allocator(), sw_ui.draw.measurer(tr), .{});
        }
        if (ui_state) |*u| u.setFocus(ids.accent_item);
        sprite_request = try assets.loadBytes(ctx.allocator(), "sprite.png");
        std.log.info("flat2d: GPU ready", .{});
    }

    pub fn tick(ctx: *sw.Context) !void {
        ticks +%= 1;

        const u = if (ui_state) |*p| p else return;
        const win = ctx.window();
        const logical = gfx.projection.logicalSize(win.width, win.height, win.dpi_scale);
        try buildUi(u, uiInput(ctx), logical.w, logical.h);
        handleUiEvents(ctx, u);
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
        try r.fillRect(.{ .x = x, .y = 480, .w = 60, .h = 40 }, accents[accent].color);

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

        // The UI is drawn last, over everything else.
        if (ui_state) |*u| {
            if (text_renderer) |*tr| try sw_ui.draw.draw(u, r, tr, .{});
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
        if (ui_state) |*u| u.deinit();
        ui_state = null;
        if (text_renderer) |*tr| tr.deinit();
        text_renderer = null;
        if (renderer) |*r| r.deinit();
        renderer = null;
    }
};
