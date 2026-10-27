// flat2d - the 2D renderer (sw_gfx2d): filled rectangles, an outline, a
// textured quad with a tint and a source rectangle, alpha blending, and text
// from a TTF font (sw_text): a paragraph with accents, wrapped to a width. It
// also loads sprite.png (next to this file) with sw_assets and draws it.
// Drawing is in logical pixels, origin at the top left.
//
// The UI (sw_ui) shows each widget. It works with the keyboard and the mouse:
// Tab and Shift+Tab move focus, the arrow keys move inside a list and change
// a slider, Enter and Space activate, and Escape closes the top screen or
// opens and closes the menu. A click focuses and activates, a drag moves a
// slider or a scroll bar or selects text, and the wheel scrolls a list.
//
// - The menu: a list, a live status text, and buttons with tooltips.
// - "Settings" opens a screen (a screen stack) with a slider and a scroll
//   list of 30 levels.
// - The text field uses the platform input method: focus it, then type. A
//   dead key works: the accent key, then "e", gives the committed "é". The
//   arrow keys, Home and End move the caret, Shift selects, and Ctrl (or Cmd)
//   with A, C, X and V selects all, copies, cuts and pastes.
// - "Keyboard" opens an on-screen keyboard that fills the text field.
//
// The focused node has a yellow ring.
const std = @import("std");
const builtin = @import("builtin");
const sw = @import("sw_app");
const gfx = @import("sw_gfx2d");
const sw_text = @import("sw_text");
const sw_ui = @import("sw_ui");
const assets = @import("sw_assets");

// The default log function does not compile for freestanding WASM.
pub const std_options: std.Options = .{
    .logFn = if (builtin.cpu.arch.isWasm()) sw.webLogFn else std.log.defaultLog,
};

// Freestanding WASM has no std.process.Init, so the web build gets a main
// with no parameters. The native build passes Io to the app (ctx.io).
pub const main = if (builtin.cpu.arch.isWasm()) mainWasm else mainNative;

// The browser does not call main. backends/wasm/loader.ts calls the
// swindowzig_init and swindowzig_frame exports that exportWeb makes.
fn mainWasm() void {}

comptime {
    if (builtin.cpu.arch.isWasm()) sw.exportWeb(config, Callbacks);
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
var volume: f32 = 0.7;
var level: usize = 0;
var keyboard: sw_ui.osk.Keyboard = .{};

const Screen = enum { settings, keyboard };
var screens: sw_ui.ScreenStack(Screen, 4) = .{};
const level_count = 30;

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
    const settings: u32 = 10;
    const keyboard_button: u32 = 11;
    const settings_screen: u32 = 20;
    const settings_panel: u32 = 21;
    const settings_title: u32 = 22;
    const volume_row: u32 = 23;
    const volume_label: u32 = 24;
    const volume_slider: u32 = 25;
    const volume_text: u32 = 26;
    const levels: u32 = 27;
    const back: u32 = 28;
    const keyboard_screen: u32 = 30;
    const keyboard_panel: u32 = 31;
    const keyboard_field: u32 = 32;
    /// The list items are accent_item + index.
    const accent_item: u32 = 100;
    /// The levels are level_item + index.
    const level_item: u32 = 200;
    /// The on-screen keyboard uses osk to osk + sw_ui.osk.id_span - 1.
    const osk: u32 = 1000;
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
    // The shortcut modifier: Ctrl, or Cmd on macOS.
    const shortcut = input.mods.ctrl or input.mods.super;
    // The web gives the wheel in pixels and SDL in lines. The UI reads lines
    // of 40 pixels (Theme.scroll_step).
    const wheel_lines = if (builtin.cpu.arch.isWasm()) input.wheel.delta_y / 40 else input.wheel.delta_y;
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
            .home = input.keyPressed(.Home),
            .end = input.keyPressed(.End),
            .delete = input.keyPressed(.Delete),
            .select_all = shortcut and input.keyPressed(.A),
            .copy = shortcut and input.keyPressed(.C),
            .cut = shortcut and input.keyPressed(.X),
            .paste = shortcut and input.keyPressed(.V),
        },
        .shift = input.mods.shift,
        .pointer_x = input.mouse.x,
        .pointer_y = input.mouse.y,
        .pointer_pressed = input.buttonPressed(.left),
        .pointer_down = input.buttonDown(.left),
        .wheel_y = wheel_lines,
        .text = input.text.text(),
        .composition = input.composition.text(),
    };
}

/// Build the UI of this frame: the menu (or a button that opens it) in the
/// middle, the text field at the bottom, then each screen of the stack over
/// them.
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
        try u.addButton(ids.close, "Close menu", .{ .tooltip = "Escape also closes the menu" });
        try u.addButton(ids.settings, "Settings", .{ .tooltip = "A slider and a long list" });
        u.endContainer();
    } else {
        try u.addButton(ids.open, "Open menu (Esc)", .{});
    }
    u.endContainer();

    try u.beginRow(ids.bottom, .{ .w = .fill, .padding = 16, .gap = 8 });
    try u.addTextField(ids.name_field, "Name", &name_value, .{ .w = .fill });
    try u.addButton(ids.keyboard_button, "Keyboard", .{ .tooltip = "Type with an on-screen keyboard" });
    u.endContainer();

    for (screens.items()) |entry| switch (entry.screen) {
        .settings => try buildSettings(u),
        .keyboard => try buildKeyboard(u),
    };

    try u.finish();
}

/// The settings screen: a slider and a scroll list.
fn buildSettings(u: *sw_ui.Ui) !void {
    try u.beginScreen(ids.settings_screen, "Settings", .{ .w = .fill, .h = .fill, .main_align = .center, .cross_align = .center });
    try u.beginColumn(ids.settings_panel, .{ .padding = 16, .gap = 8, .panel = true });
    try u.addText(ids.settings_title, "Settings: Esc goes back", .{});

    const percent = try u.print("{d:.0}%", .{volume * 100});
    try u.beginRow(ids.volume_row, .{ .gap = 8, .cross_align = .center });
    try u.addText(ids.volume_label, "Volume", .{});
    try u.addSlider(ids.volume_slider, "Volume", &volume, .{ .min = 0, .max = 1, .step = 0.05, .text = percent }, .{
        .tooltip = "Left and Right change it, or drag it",
    });
    try u.addText(ids.volume_text, percent, .{});
    u.endContainer();

    try u.beginScrollList(ids.levels, "Level", .{ .w = .fill, .h = .{ .fixed = 160 } });
    for (0..level_count) |i| {
        const name = try u.print("Level {d}", .{i + 1});
        try u.addListItem(ids.level_item + @as(u32, @intCast(i)), name, .{ .w = .fill, .selected = i == level });
    }
    u.endContainer();

    try u.addButton(ids.back, "Back", .{});
    u.endContainer();
    u.endContainer();
}

/// The on-screen keyboard screen. Its text field shows the same text as the
/// field at the bottom.
fn buildKeyboard(u: *sw_ui.Ui) !void {
    try u.beginScreen(ids.keyboard_screen, "On-screen keyboard", .{ .w = .fill, .h = .fill, .main_align = .end, .cross_align = .center, .padding = 16 });
    try u.beginColumn(ids.keyboard_panel, .{ .padding = 12, .gap = 8, .panel = true, .cross_align = .center });
    try u.addTextField(ids.keyboard_field, "Name", &name_value, .{ .w = .{ .fixed = 420 } });
    try keyboard.build(u, ids.osk, .{});
    u.endContainer();
    u.endContainer();
}

/// React to the events of the UI.
fn handleUiEvents(ctx: *sw.Context, u: *sw_ui.Ui) void {
    // The on-screen keyboard reads its own key presses.
    if (screens.top() == .keyboard) {
        const r = keyboard.apply(u, ids.osk, &name_value);
        if (r.changed) std.log.info("flat2d: name = \"{s}\"", .{name_value.slice()});
        if (r.done) _ = screens.pop(u);
    }

    for (u.frameEvents()) |e| {
        switch (e.kind) {
            .activate => {
                if (e.id >= ids.accent_item and e.id < ids.accent_item + @as(u32, accents.len)) {
                    accent = e.id - ids.accent_item;
                } else if (e.id >= ids.level_item and e.id < ids.level_item + level_count) {
                    level = e.id - ids.level_item;
                    std.log.info("flat2d: level {d}", .{level + 1});
                } else if (e.id == ids.close) {
                    menu_open = false;
                    u.setFocus(ids.open);
                } else if (e.id == ids.open) {
                    menu_open = true;
                    u.setFocus(ids.accent_item + @as(u32, @intCast(accent)));
                } else if (e.id == ids.settings) {
                    screens.push(u, .settings) catch {};
                } else if (e.id == ids.keyboard_button) {
                    screens.push(u, .keyboard) catch {};
                } else if (e.id == ids.back) {
                    _ = screens.pop(u);
                }
            },
            .cancel => {
                // Escape closes the top screen, then leaves the text field.
                // Otherwise it toggles the menu.
                const in_field = if (u.focused()) |f| f == ids.name_field else false;
                if (screens.pop(u) != null) {
                    // The screen closed.
                } else if (in_field) {
                    u.clearFocus();
                } else if (menu_open) {
                    menu_open = false;
                    u.setFocus(ids.open);
                } else {
                    menu_open = true;
                    u.setFocus(ids.accent_item + @as(u32, @intCast(accent)));
                }
            },
            .changed => {
                if (e.id == ids.volume_slider) {
                    std.log.info("flat2d: volume = {d:.2}", .{volume});
                } else {
                    std.log.info("flat2d: name = \"{s}\"", .{name_value.slice()});
                }
            },
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
