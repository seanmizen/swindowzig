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
    /// When true, physical input events (keyboard, mouse, wheel) from the platform
    /// layer are silently dropped. Platform events have tick_id=0; TAS/replayer events
    /// have explicit tick IDs and are unaffected. Useful for deterministic TAS runs.
    block_physical_input: bool,

    pub fn init(allocator: std.mem.Allocator) Bus {
        return .{
            .events = .{},
            .allocator = allocator,
            .current_tick = 0,
            .next_seq = 0,
            .block_physical_input = false,
        };
    }

    pub fn deinit(self: *Bus) void {
        self.events.deinit(self.allocator);
    }

    /// Push an event to the bus.
    /// When block_physical_input is true, platform input events (tick_id=0,
    /// payload=pointer_move/pointer_button/key/wheel/text) are silently dropped.
    /// TAS/replayer events (tick_id != 0) are never blocked.
    pub fn push(self: *Bus, tick_id: u64, t_ns: u64, payload: event.EventPayload) !void {
        if (self.block_physical_input and tick_id == 0) {
            switch (payload) {
                .pointer_move, .pointer_button, .key, .wheel, .text => return,
                else => {},
            }
        }
        // If tick changed, reset sequence counter
        if (tick_id != self.current_tick) {
            self.current_tick = tick_id;
            self.next_seq = 0;
        }

        const e = Event.init(tick_id, t_ns, self.next_seq, payload);
        self.next_seq += 1;
        try self.events.append(self.allocator, e);
    }

    /// Assign all pending events (tick_id=0, pushed by platform before ticks are known)
    /// to a specific tick. Call this after advance() and before the tick loop so that
    /// platform events are delivered to exactly the first tick of the frame, not all of them.
    pub fn assignPendingToTick(self: *Bus, tick_id: u64) void {
        for (self.events.items) |*e| {
            if (e.tick_id == 0) e.tick_id = tick_id;
        }
    }

    /// Get all events for a specific tick (exact match only).
    pub fn eventsForTick(self: *Bus, tick_id: u64) []const Event {
        var start: usize = 0;
        var end: usize = 0;

        for (self.events.items, 0..) |e, i| {
            if (e.tick_id == tick_id) {
                if (end == 0) start = i;
                end = i + 1;
            } else if (end > 0) {
                break; // events are ordered by tick, stop once we pass it
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

    // Push two "pending" events (tick_id=0, as platform layer does)
    try bus.push(0, 1000, .{ .lifecycle = .init });
    try bus.push(0, 2000, .{ .lifecycle = .paused });
    // Push one event for tick 1
    try bus.push(1, 3000, .{ .lifecycle = .resumed });

    // Assign pending events to tick 1 (as app loop does before ticking)
    bus.assignPendingToTick(1);

    // Now tick 1 should have all three events (2 pending + 1 explicit)
    const tick1_events = bus.eventsForTick(1);
    try std.testing.expectEqual(@as(usize, 3), tick1_events.len);

    // Tick 2 should have nothing
    const tick2_events = bus.eventsForTick(2);
    try std.testing.expectEqual(@as(usize, 0), tick2_events.len);
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
