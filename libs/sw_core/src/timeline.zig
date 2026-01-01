const std = @import("std");

/// Generic timeline interface
pub const Timeline = struct {
    tick_id: u64,
    dt_ns: u64,

    pub fn init(dt_ns: u64) Timeline {
        return .{
            .tick_id = 0,
            .dt_ns = dt_ns,
        };
    }
};

/// Fixed timestep timeline with catch-up
/// Runs 0..k ticks per frame to maintain consistent simulation speed
pub const FixedStepTimeline = struct {
    tick_id: u64,
    tick_hz: u32,
    dt_ns: u64,
    accum_ns: u64,
    max_catchup_ticks: u32,

    pub fn init(tick_hz: u32) FixedStepTimeline {
        const dt_ns = @divFloor(1_000_000_000, tick_hz);
        return .{
            .tick_id = 0,
            .tick_hz = tick_hz,
            .dt_ns = dt_ns,
            .accum_ns = 0,
            .max_catchup_ticks = 10, // Prevent spiral of death
        };
    }

    /// Advance the timeline by frame_ns nanoseconds
    /// Returns number of ticks to run this frame
    pub fn advance(self: *FixedStepTimeline, frame_ns: u64) u32 {
        self.accum_ns += frame_ns;

        var ticks: u32 = 0;
        while (self.accum_ns >= self.dt_ns and ticks < self.max_catchup_ticks) {
            self.accum_ns -= self.dt_ns;
            self.tick_id += 1;
            ticks += 1;
        }

        // If we hit max catchup, drain accumulator to prevent permanent lag
        if (ticks >= self.max_catchup_ticks) {
            self.accum_ns = 0;
        }

        return ticks;
    }

    /// Get current tick ID
    pub fn currentTick(self: *const FixedStepTimeline) u64 {
        return self.tick_id;
    }

    /// Get tick duration in nanoseconds
    pub fn tickDuration(self: *const FixedStepTimeline) u64 {
        return self.dt_ns;
    }
};

/// Variable timestep timeline
/// One tick per frame, dt varies
pub const VariableStepTimeline = struct {
    tick_id: u64,
    last_dt_ns: u64,

    pub fn init() VariableStepTimeline {
        return .{
            .tick_id = 0,
            .last_dt_ns = 0,
        };
    }

    pub fn advance(self: *VariableStepTimeline, frame_ns: u64) u32 {
        self.tick_id += 1;
        self.last_dt_ns = frame_ns;
        return 1;
    }

    pub fn currentTick(self: *const VariableStepTimeline) u64 {
        return self.tick_id;
    }

    pub fn tickDuration(self: *const VariableStepTimeline) u64 {
        return self.last_dt_ns;
    }
};

test "FixedStepTimeline at 60hz" {
    var timeline = FixedStepTimeline.init(60);

    try std.testing.expectEqual(@as(u64, 0), timeline.currentTick());
    try std.testing.expectEqual(@as(u64, 16_666_666), timeline.tickDuration());

    // One frame at 60fps (16.67ms)
    const ticks1 = timeline.advance(16_666_666);
    try std.testing.expectEqual(@as(u32, 1), ticks1);
    try std.testing.expectEqual(@as(u64, 1), timeline.currentTick());

    // Two frames worth of time (33.33ms)
    const ticks2 = timeline.advance(33_333_333);
    try std.testing.expectEqual(@as(u32, 2), ticks2);
    try std.testing.expectEqual(@as(u64, 3), timeline.currentTick());

    // Half a frame (8.33ms) - should not tick
    const ticks3 = timeline.advance(8_333_333);
    try std.testing.expectEqual(@as(u32, 0), ticks3);
    try std.testing.expectEqual(@as(u64, 3), timeline.currentTick());
}

test "FixedStepTimeline max catchup" {
    var timeline = FixedStepTimeline.init(60);

    // Simulate massive lag (1 second = 60 ticks worth)
    const ticks = timeline.advance(1_000_000_000);

    // Should only run max_catchup_ticks
    try std.testing.expectEqual(@as(u32, 10), ticks);
    try std.testing.expectEqual(@as(u64, 10), timeline.currentTick());

    // Accumulator should be drained
    try std.testing.expectEqual(@as(u64, 0), timeline.accum_ns);
}

test "VariableStepTimeline" {
    var timeline = VariableStepTimeline.init();

    try std.testing.expectEqual(@as(u64, 0), timeline.currentTick());

    const ticks1 = timeline.advance(16_666_666);
    try std.testing.expectEqual(@as(u32, 1), ticks1);
    try std.testing.expectEqual(@as(u64, 16_666_666), timeline.tickDuration());

    const ticks2 = timeline.advance(33_333_333);
    try std.testing.expectEqual(@as(u32, 1), ticks2);
    try std.testing.expectEqual(@as(u64, 33_333_333), timeline.tickDuration());
}
