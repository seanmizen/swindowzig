//! Frame pacing with no GPU code (REQ-GPU-027): a frame limiter that holds
//! a target frame rate, a ring of frame times with statistics, and the
//! conversion of GPU timestamps to milliseconds (REQ-GPU-028).
//!
//! ```zig
//! var limiter: render.FrameLimiter = .{};
//! limiter.setTarget(60);
//! // At the end of each frame:
//! const wait_ns = limiter.wait(now_ns);
//! if (wait_ns > 0) try io.sleep(.fromNanoseconds(wait_ns), .awake);
//! ```
//!
//! The technique follows the frame timing of horizon (MIT). No code of
//! horizon is in this file.
const std = @import("std");

const ns_per_s: u64 = std.time.ns_per_s;

/// Holds a target frame rate. Call `wait` one time at the end of each
/// frame with the time now. It gives the time to wait before the next
/// frame starts. The frames start at equal intervals, so a short wait
/// after a slow frame keeps the mean rate at the target. When a frame is
/// late by more than one interval, the limiter starts again from now and
/// does not try to catch up.
pub const FrameLimiter = struct {
    /// The target frame rate. Null or 0: no limit.
    target_fps: ?u32 = null,
    /// The time at which the current frame started, in ns.
    last_ns: ?u64 = null,

    /// Set the target frame rate. Null: no limit.
    pub fn setTarget(self: *FrameLimiter, fps: ?u32) void {
        self.target_fps = fps;
        self.last_ns = null;
    }

    /// The time between two frame starts, in ns. Null: no limit.
    pub fn interval(self: FrameLimiter) ?u64 {
        const fps = self.target_fps orelse return null;
        if (fps == 0) return null;
        return ns_per_s / fps;
    }

    /// The time to wait, in ns, at the end of a frame at `now_ns`.
    pub fn wait(self: *FrameLimiter, now_ns: u64) u64 {
        const iv = self.interval() orelse return 0;
        const last = self.last_ns orelse {
            self.last_ns = now_ns;
            return 0;
        };
        const next = last + iv;
        if (now_ns < next) {
            self.last_ns = next;
            return next - now_ns;
        }
        // Late: keep the step when the frame is late by less than one
        // interval, otherwise start again from now.
        self.last_ns = if (now_ns - next < iv) next else now_ns;
        return 0;
    }
};

/// The last `capacity` frame times, in milliseconds.
pub const FrameTimes = struct {
    pub const capacity = 240;

    samples: [capacity]f32 = @splat(0),
    head: usize = 0,
    len: usize = 0,

    pub fn push(self: *FrameTimes, ms: f32) void {
        self.samples[(self.head + self.len) % capacity] = ms;
        if (self.len < capacity) {
            self.len += 1;
        } else {
            self.head = (self.head + 1) % capacity;
        }
    }

    /// Sample `i`, from the oldest (0) to the newest (`len - 1`).
    pub fn get(self: *const FrameTimes, i: usize) f32 {
        std.debug.assert(i < self.len);
        return self.samples[(self.head + i) % capacity];
    }

    pub fn latest(self: *const FrameTimes) ?f32 {
        if (self.len == 0) return null;
        return self.get(self.len - 1);
    }

    pub fn average(self: *const FrameTimes) f32 {
        if (self.len == 0) return 0;
        var sum: f32 = 0;
        for (0..self.len) |i| sum += self.get(i);
        return sum / @as(f32, @floatFromInt(self.len));
    }

    pub fn max(self: *const FrameTimes) f32 {
        var m: f32 = 0;
        for (0..self.len) |i| m = @max(m, self.get(i));
        return m;
    }

    /// The frame time that `p` (0 to 1) of the samples are not more than,
    /// for example 0.99 for the 99th percentile.
    pub fn percentile(self: *const FrameTimes, p: f32) f32 {
        if (self.len == 0) return 0;
        var sorted: [capacity]f32 = undefined;
        for (0..self.len) |i| sorted[i] = self.get(i);
        std.sort.pdq(f32, sorted[0..self.len], {}, std.sort.asc(f32));
        const last: f32 = @floatFromInt(self.len - 1);
        const at: usize = @intFromFloat(@round(std.math.clamp(p, 0, 1) * last));
        return sorted[at];
    }
};

/// The time between two GPU timestamps, in ms. `period_ns` is the length
/// of one timestamp tick in ns. A pair in the wrong order gives 0: some
/// GPUs reset the counter.
pub fn timestampMs(begin: u64, end: u64, period_ns: f32) f32 {
    if (end <= begin) return 0;
    const ticks: f64 = @floatFromInt(end - begin);
    return @floatCast(ticks * period_ns / std.time.ns_per_ms);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "frame pacing: the limiter waits until the next frame start (REQ-GPU-027)" {
    var l: FrameLimiter = .{};
    try testing.expectEqual(@as(u64, 0), l.wait(5));
    l.setTarget(100); // 10 ms
    try testing.expectEqual(@as(u64, 0), l.wait(0));
    // A 4 ms frame waits 6 ms.
    try testing.expectEqual(@as(u64, 6_000_000), l.wait(4_000_000));
    // The next frame starts at 10 ms. A 13 ms frame ends at 23 ms: no
    // wait, and the step stays at 20 ms.
    try testing.expectEqual(@as(u64, 0), l.wait(23_000_000));
    try testing.expectEqual(@as(u64, 20_000_000), l.last_ns.?);
    // The next frame is fast: the wait goes to 30 ms, so the mean stays
    // at 100 frames each second.
    try testing.expectEqual(@as(u64, 5_000_000), l.wait(25_000_000));
}

test "frame pacing: a frame late by more than one interval starts again from now (REQ-GPU-027)" {
    var l: FrameLimiter = .{};
    l.setTarget(100);
    _ = l.wait(0);
    try testing.expectEqual(@as(u64, 0), l.wait(50_000_000));
    try testing.expectEqual(@as(u64, 50_000_000), l.last_ns.?);
    try testing.expectEqual(@as(u64, 8_000_000), l.wait(52_000_000));
    l.setTarget(0);
    try testing.expectEqual(@as(?u64, null), l.interval());
    try testing.expectEqual(@as(u64, 0), l.wait(53_000_000));
}

test "frame pacing: the frame times keep the newest samples (REQ-GPU-027)" {
    var t: FrameTimes = .{};
    try testing.expectEqual(@as(f32, 0), t.average());
    try testing.expectEqual(@as(?f32, null), t.latest());
    for (0..FrameTimes.capacity + 10) |i| t.push(@floatFromInt(i));
    try testing.expectEqual(@as(usize, FrameTimes.capacity), t.len);
    try testing.expectEqual(@as(f32, 10), t.get(0));
    try testing.expectEqual(@as(f32, FrameTimes.capacity + 9), t.latest().?);
    try testing.expectEqual(@as(f32, FrameTimes.capacity + 9), t.max());
}

test "frame pacing: the average and the percentile (REQ-GPU-027)" {
    var t: FrameTimes = .{};
    for ([_]f32{ 16, 16, 16, 32, 20 }) |ms| t.push(ms);
    try testing.expectApproxEqAbs(@as(f32, 20), t.average(), 1e-5);
    try testing.expectEqual(@as(f32, 16), t.percentile(0));
    try testing.expectEqual(@as(f32, 16), t.percentile(0.5));
    try testing.expectEqual(@as(f32, 32), t.percentile(1));
    try testing.expectEqual(@as(f32, 32), t.percentile(0.99));
}

test "frame pacing: GPU timestamps to milliseconds (REQ-GPU-028)" {
    try testing.expectApproxEqAbs(@as(f32, 2.5), timestampMs(1_000, 2_501_000, 1), 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 5), timestampMs(0, 2_500_000, 2), 1e-5);
    try testing.expectEqual(@as(f32, 0), timestampMs(10, 5, 1));
}
