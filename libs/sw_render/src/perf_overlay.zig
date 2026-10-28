//! A frame-time chart for a performance overlay (REQ-GPU-029). It draws
//! with the sw_gfx2d renderer: a background, one bar for each frame time,
//! the newest at the right, and a line at the target frame time. A bar
//! above the target has the slow colour.
//!
//! ```zig
//! times.push(frame_ms);
//! r2d.beginFrame(w, h, dpi);
//! try render.drawFrameChart(&r2d, &times, .{ .rect = .{ .x = 8, .y = 8, .w = 240, .h = 60 } });
//! try r2d.flush(pass.render.?);
//! ```
//!
//! The technique follows the debug chart of horizon (MIT). No code of
//! horizon is in this file.
const std = @import("std");
const gfx2d = @import("sw_gfx2d");
const pacing = @import("frame_pacing.zig");

const Rect = gfx2d.Rect;
const Color = gfx2d.Color;

pub const ChartOptions = struct {
    /// The chart area, in logical pixels.
    rect: Rect,
    /// The frame time at the top of the chart. A longer frame time draws
    /// a bar of the full height.
    max_ms: f32 = 1000.0 / 30.0,
    /// The frame time of the line, for example the time of one frame at
    /// 60 frames each second.
    target_ms: f32 = 1000.0 / 60.0,
    /// The space between the edge of the chart and the bars.
    padding: f32 = 2,
    background: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0.6 },
    bar: Color = .{ .r = 0.2, .g = 0.8, .b = 0.3 },
    slow_bar: Color = .{ .r = 0.9, .g = 0.2, .b = 0.2 },
    line: Color = .{ .r = 1, .g = 1, .b = 1, .a = 0.8 },
};

/// The area inside the padding.
pub fn innerRect(o: ChartOptions) Rect {
    const p = @min(o.padding, @min(o.rect.w, o.rect.h) / 2);
    return .{ .x = o.rect.x + p, .y = o.rect.y + p, .w = o.rect.w - 2 * p, .h = o.rect.h - 2 * p };
}

/// The bar of sample `i` (0: the oldest) of `times`. Its bottom is on the
/// bottom of the inner area.
pub fn barRect(times: *const pacing.FrameTimes, i: usize, o: ChartOptions) Rect {
    const inner = innerRect(o);
    const bw = inner.w / @as(f32, @floatFromInt(pacing.FrameTimes.capacity));
    const from_right: f32 = @floatFromInt(times.len - i);
    const ms = times.get(i);
    const fraction = if (o.max_ms > 0) std.math.clamp(ms / o.max_ms, 0, 1) else 0;
    const h = fraction * inner.h;
    return .{ .x = inner.x + inner.w - from_right * bw, .y = inner.y + inner.h - h, .w = bw, .h = h };
}

/// The line at the target frame time, 1 logical pixel high.
pub fn targetLineRect(o: ChartOptions) Rect {
    const inner = innerRect(o);
    const fraction = if (o.max_ms > 0) std.math.clamp(o.target_ms / o.max_ms, 0, 1) else 0;
    return .{ .x = inner.x, .y = inner.y + inner.h - fraction * inner.h, .w = inner.w, .h = 1 };
}

/// Draw the chart with `renderer`, a `*sw_gfx2d.Renderer` or another
/// type with `fillRect(Rect, Color) !void`.
pub fn drawFrameChart(renderer: anytype, times: *const pacing.FrameTimes, o: ChartOptions) !void {
    try renderer.fillRect(o.rect, o.background);
    for (0..times.len) |i| {
        const r = barRect(times, i, o);
        if (r.h <= 0) continue;
        try renderer.fillRect(r, if (times.get(i) > o.target_ms) o.slow_bar else o.bar);
    }
    try renderer.fillRect(targetLineRect(o), o.line);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

const Recorder = struct {
    rects: [pacing.FrameTimes.capacity + 2]Rect = undefined,
    colors: [pacing.FrameTimes.capacity + 2]Color = undefined,
    n: usize = 0,

    pub fn fillRect(self: *Recorder, r: Rect, c: Color) !void {
        self.rects[self.n] = r;
        self.colors[self.n] = c;
        self.n += 1;
    }
};

const test_options: ChartOptions = .{ .rect = .{ .x = 10, .y = 20, .w = 244, .h = 44 }, .max_ms = 40, .target_ms = 20 };

test "perf overlay: the chart draws the background, one bar for each frame and the line (REQ-GPU-029)" {
    var times: pacing.FrameTimes = .{};
    times.push(10);
    times.push(30);
    times.push(80);
    var rec: Recorder = .{};
    try drawFrameChart(&rec, &times, test_options);
    try testing.expectEqual(@as(usize, 5), rec.n);
    try testing.expectEqual(test_options.rect, rec.rects[0]);
    try testing.expectEqual(test_options.bar, rec.colors[1]);
    try testing.expectEqual(test_options.slow_bar, rec.colors[2]);
    try testing.expectEqual(test_options.slow_bar, rec.colors[3]);
    try testing.expectEqual(test_options.line, rec.colors[4]);
}

test "perf overlay: the bar height is the frame time over the chart maximum (REQ-GPU-029)" {
    var times: pacing.FrameTimes = .{};
    times.push(10);
    times.push(80);
    const inner = innerRect(test_options);
    try testing.expectEqual(Rect{ .x = 12, .y = 22, .w = 240, .h = 40 }, inner);
    // 10 ms of 40 ms: a quarter of the height. Each bar is 1 pixel wide,
    // and the newest bar touches the right edge.
    const a = barRect(&times, 0, test_options);
    try testing.expectEqual(Rect{ .x = 250, .y = 52, .w = 1, .h = 10 }, a);
    // 80 ms is more than the maximum: the full height.
    const b = barRect(&times, 1, test_options);
    try testing.expectEqual(Rect{ .x = 251, .y = 22, .w = 1, .h = 40 }, b);
    // The line at 20 ms is at half the height.
    try testing.expectEqual(Rect{ .x = 12, .y = 42, .w = 240, .h = 1 }, targetLineRect(test_options));
}

test "perf overlay: a full ring fills the inner width (REQ-GPU-029)" {
    var times: pacing.FrameTimes = .{};
    for (0..pacing.FrameTimes.capacity + 5) |_| times.push(5);
    const inner = innerRect(test_options);
    try testing.expectApproxEqAbs(inner.x, barRect(&times, 0, test_options).x, 1e-4);
    const last = barRect(&times, times.len - 1, test_options);
    try testing.expectApproxEqAbs(inner.x + inner.w, last.x + last.w, 1e-4);
}
