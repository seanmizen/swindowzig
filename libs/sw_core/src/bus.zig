const std = @import("std");
const event = @import("event.zig");
const Event = event.Event;

/// Buffered event bus with deterministic ordering
/// Single producer, multi-consumer pattern
pub const Bus = struct {
    events: std.ArrayList(Event),
    allocator: std.mem.Allocator,
    current_tick: u64,
    next_seq: u32,

    pub fn init(allocator: std.mem.Allocator) Bus {
        return .{
            .events = .{},
            .allocator = allocator,
            .current_tick = 0,
            .next_seq = 0,
        };
    }

    pub fn deinit(self: *Bus) void {
        self.events.deinit(self.allocator);
    }

    /// Push an event to the bus
    pub fn push(self: *Bus, tick_id: u64, t_ns: u64, payload: event.EventPayload) !void {
        // If tick changed, reset sequence counter
        if (tick_id != self.current_tick) {
            self.current_tick = tick_id;
            self.next_seq = 0;
        }

        const e = Event.init(tick_id, t_ns, self.next_seq, payload);
        self.next_seq += 1;
        try self.events.append(self.allocator, e);
    }

    /// Get all events for a specific tick
    /// Events with tick_id=0 are treated as "current tick" and always included
    pub fn eventsForTick(self: *Bus, tick_id: u64) []const Event {
        var start: usize = 0;
        var end: usize = 0;

        for (self.events.items, 0..) |e, i| {
            // Include events for this tick OR events with tick_id=0 (current tick wildcard)
            if (e.tick_id == tick_id or e.tick_id == 0) {
                if (end == 0) start = i;
                end = i + 1;
            } else if (end > 0 and e.tick_id != 0) {
                break;
            }
        }

        if (end == 0) return &.{};
        return self.events.items[start..end];
    }

    /// Clear all events
    pub fn clear(self: *Bus) void {
        self.events.clearRetainingCapacity();
        self.next_seq = 0;
    }

    /// Clear events older than a specific tick
    pub fn clearBefore(self: *Bus, tick_id: u64) void {
        var i: usize = 0;
        while (i < self.events.items.len) {
            if (self.events.items[i].tick_id < tick_id) {
                _ = self.events.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }
};

test "Bus push and retrieve" {
    var bus = Bus.init(std.testing.allocator);
    defer bus.deinit();

    try bus.push(0, 1000, .{ .lifecycle = .init });
    try bus.push(0, 2000, .{ .lifecycle = .paused });
    try bus.push(1, 3000, .{ .lifecycle = .resumed });

    const tick0_events = bus.eventsForTick(0);
    try std.testing.expectEqual(@as(usize, 2), tick0_events.len);
    try std.testing.expectEqual(@as(u32, 0), tick0_events[0].seq);
    try std.testing.expectEqual(@as(u32, 1), tick0_events[1].seq);

    const tick1_events = bus.eventsForTick(1);
    try std.testing.expectEqual(@as(usize, 1), tick1_events.len);
    try std.testing.expectEqual(@as(u32, 0), tick1_events[0].seq);
}

test "Bus clear" {
    var bus = Bus.init(std.testing.allocator);
    defer bus.deinit();

    try bus.push(0, 1000, .{ .lifecycle = .init });
    try bus.push(1, 2000, .{ .lifecycle = .paused });

    bus.clear();
    try std.testing.expectEqual(@as(usize, 0), bus.events.items.len);
}

test "Bus clearBefore" {
    var bus = Bus.init(std.testing.allocator);
    defer bus.deinit();

    try bus.push(0, 1000, .{ .lifecycle = .init });
    try bus.push(1, 2000, .{ .lifecycle = .paused });
    try bus.push(2, 3000, .{ .lifecycle = .resumed });

    bus.clearBefore(2);
    try std.testing.expectEqual(@as(usize, 1), bus.events.items.len);
    try std.testing.expectEqual(@as(u64, 2), bus.events.items[0].tick_id);
}
