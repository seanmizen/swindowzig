// flat2d - the 2D renderer (sw_gfx2d): filled rectangles, an outline, a
// textured quad with a tint and a source rectangle, and alpha blending.
// Drawing is in logical pixels, origin at the top left.
const std = @import("std");
const builtin = @import("builtin");
const sw = @import("sw_app");
const gfx = @import("sw_gfx2d");

// Freestanding WASM has no std.process.Init, so the web build gets a main
// with no parameters. The native build passes Io to the app (ctx.io).
pub const main = if (builtin.cpu.arch.isWasm()) mainWasm else mainNative;

fn mainWasm() !void {
    try sw.run(config, Callbacks);
}

fn mainNative(init: std.process.Init) !void {
    var c = config;
    c.io = init.io;
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
        std.log.info("flat2d: GPU ready", .{});
    }

    pub fn tick(ctx: *sw.Context) !void {
        _ = ctx;
        ticks +%= 1;
    }

    pub fn render(ctx: *sw.Context) !void {
        const gpu = ctx.gpu();
        if (!gpu.isReady()) return;
        const r = if (renderer) |*p| p else return;

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

        // A rectangle that moves, to show the frame is redrawn.
        const t: f32 = @floatFromInt(ticks);
        const x = 40 + 300 * (0.5 + 0.5 * @sin(t / 40.0));
        try r.fillRect(.{ .x = x, .y = 480, .w = 60, .h = 40 }, gfx.Color.rgba8(120, 230, 160, 255));

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
        if (renderer) |*r| r.deinit();
        renderer = null;
    }
};
