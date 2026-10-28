//! The 2D layer of a demo: text, a caption and the frame-time chart, drawn
//! with sw_gfx2d and sw_text on the screen after the post chain.
//!
//! In a run with no window, the chart and the frame time use a fixed frame
//! time, so the frame hashes do not depend on the speed of the machine
//! (REQ-DEMO-001).
const std = @import("std");
const sw = @import("sw_app");
const gfx = @import("sw_gfx2d");
const sw_text = @import("sw_text");
const sw_render = @import("sw_render");
const fonts = @import("fonts.zig");

pub const DrawFn = *const fn (user: ?*anyopaque, o: *Overlay) anyerror!void;

pub const Overlay = struct {
    allocator: std.mem.Allocator,
    renderer: gfx.Renderer,
    own_text: sw_text.TextRenderer,
    /// The text renderer of the next draw. The menu demo sets another one
    /// (the bitmap font).
    text: *sw_text.TextRenderer,
    frame_times: sw_render.FrameTimes = .{},
    last_ns: ?u64 = null,
    offline: bool,
    dpi_scale: f32 = 1,
    /// The size of the screen in logical pixels, in the draw.
    width: f32 = 0,
    height: f32 = 0,
    user: ?*anyopaque,
    draw_fn: DrawFn,

    /// Make the overlay and add its pass (order 2000, on the screen) to
    /// the graph. The overlay is on the heap, so the pass can keep its
    /// address.
    pub fn create(allocator: std.mem.Allocator, graph: *sw_render.FrameGraph, offline: bool, user: ?*anyopaque, draw_fn: DrawFn) !*Overlay {
        const self = try allocator.create(Overlay);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .renderer = try gfx.Renderer.init(allocator, graph.gpu, .{}),
            .own_text = try sw_text.TextRenderer.init(allocator, fonts.latin),
            .text = undefined,
            .offline = offline,
            .user = user,
            .draw_fn = draw_fn,
        };
        self.text = &self.own_text;
        try graph.addPass(.{
            .name = "demo_overlay",
            .order = 2000,
            .attachments = .{ .colors = &.{.{ .target = .screen, .load_op = .load }} },
            .callback = .of(Overlay, self, run),
        });
        return self;
    }

    pub fn destroy(self: *Overlay) void {
        self.own_text.deinit();
        self.renderer.deinit();
        self.allocator.destroy(self);
    }

    /// Keep the time of this frame for the chart. Call it once each
    /// rendered frame.
    pub fn frameDone(self: *Overlay, ctx: *sw.Context) void {
        self.dpi_scale = if (self.offline) 1 else ctx.window().dpi_scale;
        if (self.offline) {
            self.frame_times.push(1000.0 / 60.0);
            return;
        }
        const now = ctx.timeNs();
        if (self.last_ns) |last| self.frame_times.push(@as(f32, @floatFromInt(now -| last)) / std.time.ns_per_ms);
        self.last_ns = now;
    }

    /// The mean frame time in milliseconds.
    pub fn frameMs(self: *const Overlay) f32 {
        return self.frame_times.average();
    }

    fn run(self: *Overlay, pass: *sw_render.Pass) anyerror!void {
        const r = &self.renderer;
        r.beginFrame(pass.width, pass.height, self.dpi_scale);
        const size = r.size();
        self.width = size.w;
        self.height = size.h;
        self.text.setDpiScale(self.dpi_scale);
        try self.draw_fn(self.user, self);
        try r.flush(pass.render.?);
    }

    /// Text at (x, y), top left.
    pub fn print(self: *Overlay, x: f32, y: f32, size: f32, color: gfx.Color, comptime fmt: []const u8, args: anytype) !void {
        var buf: [256]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
        _ = try self.text.draw(&self.renderer, s, x, y, .{ .size = size, .color = color });
    }

    /// A line of text in the middle of the bottom of the screen, on a dark
    /// band.
    pub fn caption(self: *Overlay, s: []const u8) !void {
        const size: f32 = 22;
        const m = self.text.measure(s, size);
        const x = (self.width - m.w) / 2;
        const y = self.height - m.h - 24;
        try self.renderer.fillRect(.{ .x = x - 14, .y = y - 8, .w = m.w + 28, .h = m.h + 16 }, gfx.Color.rgba8(0, 0, 0, 170));
        _ = try self.text.draw(&self.renderer, s, x, y, .{ .size = size, .color = gfx.Color.rgba8(255, 255, 255, 255) });
    }

    /// The frame-time chart at (x, y).
    pub fn chart(self: *Overlay, x: f32, y: f32) !void {
        try sw_render.drawFrameChart(&self.renderer, &self.frame_times, .{ .rect = .{ .x = x, .y = y, .w = 160, .h = 40 } });
    }
};
