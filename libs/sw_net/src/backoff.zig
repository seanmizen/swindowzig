//! The reconnect delay: it starts at `initial_ms` and doubles after each
//! failed attempt, to `max_ms` at most (REQ-NET-003).
const std = @import("std");

pub const Backoff = struct {
    /// The delay before the first reconnect attempt.
    initial_ms: u32 = 500,
    /// The largest delay.
    max_ms: u32 = 30_000,
    /// The number of attempts after a drop. Null means no limit. An open
    /// connection sets the count to zero again.
    max_attempts: ?u32 = null,

    /// The delay before attempt number `attempt` (0 is the first attempt),
    /// or null when no attempt remains.
    pub fn delayMs(self: Backoff, attempt: u32) ?u32 {
        if (self.max_attempts) |max| if (attempt >= max) return null;
        const shift: u6 = @intCast(@min(attempt, 32));
        const delay = @as(u64, self.initial_ms) << shift;
        return @intCast(@min(delay, self.max_ms));
    }
};

test "backoff: doubles to the limit (REQ-NET-003)" {
    const b: Backoff = .{ .initial_ms = 100, .max_ms = 1000 };
    try std.testing.expectEqual(@as(?u32, 100), b.delayMs(0));
    try std.testing.expectEqual(@as(?u32, 200), b.delayMs(1));
    try std.testing.expectEqual(@as(?u32, 800), b.delayMs(3));
    try std.testing.expectEqual(@as(?u32, 1000), b.delayMs(4));
    try std.testing.expectEqual(@as(?u32, 1000), b.delayMs(1_000_000));
}

test "backoff: max_attempts stops the attempts (REQ-NET-003)" {
    const b: Backoff = .{ .initial_ms = 10, .max_attempts = 2 };
    try std.testing.expect(b.delayMs(1) != null);
    try std.testing.expectEqual(@as(?u32, null), b.delayMs(2));
}
