const std = @import("std");
const Event = @import("event.zig").Event;
const serialize = @import("serialize.zig");
const Serializer = serialize.Serializer;

/// Event recorder - writes events to a stream
pub const Recorder = struct {
    serializer: Serializer,
    enabled: bool,
    tick_hz: u32,
    event_count: usize,

    pub fn init(writer: std.io.AnyWriter, tick_hz: u32) !Recorder {
        var serializer = Serializer.init(writer);
        try serializer.writeHeader(tick_hz);

        return .{
            .serializer = serializer,
            .enabled = true,
            .tick_hz = tick_hz,
            .event_count = 0,
        };
    }

    pub fn enable(self: *Recorder) void {
        self.enabled = true;
    }

    pub fn disable(self: *Recorder) void {
        self.enabled = false;
    }

    pub fn record(self: *Recorder, e: Event) !void {
        if (!self.enabled) return;

        try self.serializer.writeEvent(e);
        self.event_count += 1;
    }

    pub fn recordBatch(self: *Recorder, events: []const Event) !void {
        if (!self.enabled) return;

        for (events) |e| {
            try self.serializer.writeEvent(e);
            self.event_count += 1;
        }
    }
};

test "Recorder basic usage" {
    var buffer: std.ArrayList(u8) = .{};
    defer buffer.deinit(std.testing.allocator);

    var recorder = try Recorder.init(buffer.writer(std.testing.allocator).any(), 120);

    const e1 = Event.init(0, 1000, 0, .{ .lifecycle = .init });
    const e2 = Event.init(0, 2000, 1, .{ .lifecycle = .paused });

    try recorder.record(e1);
    try recorder.record(e2);

    try std.testing.expectEqual(@as(usize, 2), recorder.event_count);
    try std.testing.expect(buffer.items.len > 0);
}

test "Recorder enable/disable" {
    var buffer: std.ArrayList(u8) = .{};
    defer buffer.deinit(std.testing.allocator);

    var recorder = try Recorder.init(buffer.writer(std.testing.allocator).any(), 120);

    const e1 = Event.init(0, 1000, 0, .{ .lifecycle = .init });

    try recorder.record(e1);
    try std.testing.expectEqual(@as(usize, 1), recorder.event_count);

    recorder.disable();
    try recorder.record(e1);
    try std.testing.expectEqual(@as(usize, 1), recorder.event_count);

    recorder.enable();
    try recorder.record(e1);
    try std.testing.expectEqual(@as(usize, 2), recorder.event_count);
}

test "Recorder batch" {
    var buffer: std.ArrayList(u8) = .{};
    defer buffer.deinit(std.testing.allocator);

    var recorder = try Recorder.init(buffer.writer(std.testing.allocator).any(), 120);

    const events = [_]Event{
        Event.init(0, 1000, 0, .{ .lifecycle = .init }),
        Event.init(0, 2000, 1, .{ .lifecycle = .paused }),
        Event.init(1, 3000, 0, .{ .lifecycle = .resumed }),
    };

    try recorder.recordBatch(&events);
    try std.testing.expectEqual(@as(usize, 3), recorder.event_count);
}
