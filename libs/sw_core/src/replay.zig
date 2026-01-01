const std = @import("std");
const Event = @import("event.zig").Event;
const Bus = @import("bus.zig").Bus;
const serialize = @import("serialize.zig");
const Deserializer = serialize.Deserializer;
const Header = serialize.Header;

/// Replay state
pub const ReplayState = enum {
    stopped,
    playing,
    paused,
    finished,
};

/// Event replayer - reads events from a stream and feeds them to a bus
pub const Replayer = struct {
    deserializer: Deserializer,
    header: Header,
    events: std.ArrayList(Event),
    current_index: usize,
    state: ReplayState,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, reader: std.io.AnyReader) !Replayer {
        var deserializer = Deserializer.init(reader);
        const header = try deserializer.readHeader();

        return .{
            .deserializer = deserializer,
            .header = header,
            .events = .{},
            .current_index = 0,
            .state = .stopped,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Replayer) void {
        self.events.deinit(self.allocator);
    }

    /// Load all events into memory
    pub fn loadAll(self: *Replayer) !void {
        while (true) {
            const e = self.deserializer.readEvent() catch |err| {
                if (err == error.EndOfStream) break;
                return err;
            };
            try self.events.append(self.allocator, e);
        }
    }

    /// Play from the beginning
    pub fn play(self: *Replayer) void {
        self.state = .playing;
        self.current_index = 0;
    }

    /// Pause playback
    pub fn pause(self: *Replayer) void {
        if (self.state == .playing) {
            self.state = .paused;
        }
    }

    /// Resume playback (renamed from 'resume' which is a Zig keyword)
    pub fn unpause(self: *Replayer) void {
        if (self.state == .paused) {
            self.state = .playing;
        }
    }

    /// Stop playback
    pub fn stop(self: *Replayer) void {
        self.state = .stopped;
        self.current_index = 0;
    }

    /// Feed events for a specific tick to the bus
    pub fn feedTick(self: *Replayer, tick_id: u64, bus: *Bus) !void {
        if (self.state != .playing) return;

        while (self.current_index < self.events.items.len) {
            const e = self.events.items[self.current_index];

            if (e.tick_id > tick_id) break;
            if (e.tick_id == tick_id) {
                try bus.push(e.tick_id, e.t_ns, e.payload);
            }

            self.current_index += 1;
        }

        if (self.current_index >= self.events.items.len) {
            self.state = .finished;
        }
    }

    /// Step through one tick
    pub fn stepTick(self: *Replayer, bus: *Bus) !void {
        if (self.current_index >= self.events.items.len) {
            self.state = .finished;
            return;
        }

        const target_tick = self.events.items[self.current_index].tick_id;
        try self.feedTick(target_tick, bus);
    }
};

test "Replayer load and playback" {
    // Create a recording
    var write_buffer: std.ArrayList(u8) = .{};
    defer write_buffer.deinit(std.testing.allocator);

    const events = [_]Event{
        Event.init(0, 1000, 0, .{ .lifecycle = .init }),
        Event.init(0, 2000, 1, .{ .lifecycle = .paused }),
        Event.init(1, 3000, 0, .{ .lifecycle = .resumed }),
    };

    var recorder_serializer = serialize.Serializer.init(write_buffer.writer(std.testing.allocator).any());
    try recorder_serializer.writeHeader(120);
    for (events) |e| {
        try recorder_serializer.writeEvent(e);
    }

    // Replay
    var fbs = std.io.fixedBufferStream(write_buffer.items);
    var replayer = try Replayer.init(std.testing.allocator, fbs.reader().any());
    defer replayer.deinit();

    try replayer.loadAll();
    try std.testing.expectEqual(@as(usize, 3), replayer.events.items.len);

    var bus = Bus.init(std.testing.allocator);
    defer bus.deinit();

    replayer.play();
    try replayer.feedTick(0, &bus);

    const tick0_events = bus.eventsForTick(0);
    try std.testing.expectEqual(@as(usize, 2), tick0_events.len);

    try replayer.feedTick(1, &bus);
    const tick1_events = bus.eventsForTick(1);
    try std.testing.expectEqual(@as(usize, 1), tick1_events.len);

    try std.testing.expectEqual(ReplayState.finished, replayer.state);
}

test "Replayer pause and resume" {
    var write_buffer: std.ArrayList(u8) = .{};
    defer write_buffer.deinit(std.testing.allocator);

    var recorder_serializer = serialize.Serializer.init(write_buffer.writer(std.testing.allocator).any());
    try recorder_serializer.writeHeader(120);

    const e = Event.init(0, 1000, 0, .{ .lifecycle = .init });
    try recorder_serializer.writeEvent(e);

    var fbs = std.io.fixedBufferStream(write_buffer.items);
    var replayer = try Replayer.init(std.testing.allocator, fbs.reader().any());
    defer replayer.deinit();

    try replayer.loadAll();

    replayer.play();
    try std.testing.expectEqual(ReplayState.playing, replayer.state);

    replayer.pause();
    try std.testing.expectEqual(ReplayState.paused, replayer.state);

    replayer.unpause();
    try std.testing.expectEqual(ReplayState.playing, replayer.state);
}
