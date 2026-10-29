//! The text over each demo: a caption at the bottom, and the stats at the
//! top left (REQ-DEMO-002, REQ-DEMO-004).
//!
//! The sizes follow the surface height, so each preset gives the same
//! layout. A demo gives the lines; the overlay draws them with sw_gfx2d and
//! sw_text in a pass on `.screen`.

const std = @import("std");
const sw_gfx2d = @import("sw_gfx2d");
const sw_gpu = @import("sw_gpu");
const sw_text = @import("sw_text");
const sw_render = @import("sw_render");

/// Lato, under the SIL Open Font License (examples/flat2d/assets/Lato-OFL.txt).
const font_bytes = @embedFile("demo_font");

pub const max_stat_lines = 4;

pub const Overlay = struct {
    renderer: sw_gfx2d.Renderer,
    text: sw_text.TextRenderer,
    caption: []const u8 = "",
    stats: [max_stat_lines][]const u8 = @splat(""),
    stat_count: usize = 0,
    /// Draw this frame-time chart under the stats. Null: no chart.
    chart: ?*const sw_render.FrameTimes = null,

    pub fn init(allocator: std.mem.Allocator, gpu: *sw_gpu.GPU) !Overlay {
        var r = try sw_gfx2d.Renderer.init(allocator, gpu, .{});
        errdefer r.deinit();
        return .{ .renderer = r, .text = try sw_text.TextRenderer.init(allocator, font_bytes) };
    }

    pub fn deinit(self: *Overlay) void {
        self.text.deinit();
        self.renderer.deinit();
        self.* = undefined;
    }

    /// The scale of the layout: 1 at a height of 540 pixels.
    fn scale(height: u32) f32 {
        return @as(f32, @floatFromInt(height)) / 540.0;
    }

    /// Start the 2D frame and draw the caption and the stats. The caller can
    /// add more 2D shapes and text, then call `flush`.
    pub fn draw(self: *Overlay, width: u32, height: u32) !void {
        const r = &self.renderer;
        r.beginFrame(width, height, 1);
        const k = scale(height);
        const w: f32 = @floatFromInt(width);
        const h: f32 = @floatFromInt(height);

        // The stats: a dark box with small lines.
        if (self.stat_count > 0) {
            const size = 13 * k;
            const line_h = size * 1.3;
            var box_w: f32 = 0;
            for (self.stats[0..self.stat_count]) |line| box_w = @max(box_w, self.text.measure(line, size).w);
            const chart_h: f32 = if (self.chart != null) 34 * k else 0;
            const box_h = line_h * @as(f32, @floatFromInt(self.stat_count)) + chart_h + 10 * k;
            box_w = @max(box_w, if (self.chart != null) 140 * k else 0);
            try r.fillRect(.{ .x = 8 * k, .y = 8 * k, .w = box_w + 12 * k, .h = box_h }, sw_gfx2d.Color.rgba8(0, 0, 0, 150));
            for (self.stats[0..self.stat_count], 0..) |line, i| {
                const y = 13 * k + line_h * @as(f32, @floatFromInt(i));
                _ = try self.text.draw(r, line, 14 * k, y, .{ .size = size, .color = sw_gfx2d.Color.rgba8(235, 235, 235, 255) });
            }
            if (self.chart) |times| {
                const y = 13 * k + line_h * @as(f32, @floatFromInt(self.stat_count));
                try sw_render.drawFrameChart(r, times, .{ .rect = .{ .x = 14 * k, .y = y, .w = 140 * k, .h = 28 * k } });
            }
        }

        // The caption: centred text on a bar at the bottom.
        if (self.caption.len > 0) {
            const size = 26 * k;
            const m = self.text.measure(self.caption, size);
            const pad = 10 * k;
            const bar_w = m.w + 4 * pad;
            const bar_h = m.h + 2 * pad;
            const x = (w - bar_w) / 2;
            const y = h - bar_h - 18 * k;
            try r.fillRect(.{ .x = x, .y = y, .w = bar_w, .h = bar_h }, sw_gfx2d.Color.rgba8(0, 0, 0, 170));
            _ = try self.text.draw(r, self.caption, x + 2 * pad, y + pad, .{ .size = size, .color = sw_gfx2d.Color.rgba8(255, 244, 214, 255) });
        }
    }

    /// Set the stat lines. The strings must stay valid until `draw`.
    pub fn setStats(self: *Overlay, lines: []const []const u8) void {
        self.stat_count = @min(lines.len, max_stat_lines);
        for (lines[0..self.stat_count], 0..) |l, i| self.stats[i] = l;
    }
};
