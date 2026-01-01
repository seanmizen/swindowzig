const std = @import("std");
const event = @import("event.zig");
const Event = event.Event;

/// Serialization format version
pub const VERSION: u32 = 1;

/// Magic bytes for file format identification
pub const MAGIC: [4]u8 = .{ 'S', 'W', 'E', 'V' }; // "SWEV" = SWindow Events

/// File header
pub const Header = extern struct {
    magic: [4]u8,
    version: u32,
    tick_hz: u32,
    reserved: [4]u8,

    pub fn init(tick_hz: u32) Header {
        return .{
            .magic = MAGIC,
            .version = VERSION,
            .tick_hz = tick_hz,
            .reserved = [_]u8{0} ** 4,
        };
    }

    pub fn validate(self: *const Header) !void {
        if (!std.mem.eql(u8, &self.magic, &MAGIC)) {
            return error.InvalidMagic;
        }
        if (self.version != VERSION) {
            return error.UnsupportedVersion;
        }
    }
};

/// Serializer with delta encoding for efficiency
pub const Serializer = struct {
    writer: std.io.AnyWriter,
    last_tick: u64,
    last_time: u64,

    pub fn init(writer: std.io.AnyWriter) Serializer {
        return .{
            .writer = writer,
            .last_tick = 0,
            .last_time = 0,
        };
    }

    pub fn writeHeader(self: *Serializer, tick_hz: u32) !void {
        const header = Header.init(tick_hz);
        try self.writer.writeStructEndian(header, .little);
    }

    pub fn writeEvent(self: *Serializer, e: Event) !void {
        // Delta encode tick and time
        const tick_delta = e.tick_id - self.last_tick;
        const time_delta = e.t_ns - self.last_time;

        try self.writer.writeInt(u64, tick_delta, .little);
        try self.writer.writeInt(u64, time_delta, .little);
        try self.writer.writeInt(u32, e.seq, .little);

        // Write payload tag
        const tag = std.meta.activeTag(e.payload);
        try self.writer.writeInt(u8, @intFromEnum(tag), .little);

        // Write payload data based on tag
        switch (e.payload) {
            .pointer_move => |p| {
                try self.writer.writeStruct(p);
            },
            .pointer_button => |p| {
                try self.writer.writeStruct(p);
            },
            .wheel => |w| {
                try self.writer.writeStruct(w);
            },
            .key => |k| {
                try self.writer.writeStruct(k);
            },
            .text => |t| {
                try self.writer.writeStruct(t);
            },
            .resize => |r| {
                try self.writer.writeStruct(r);
            },
            .focus => |f| {
                try self.writer.writeStruct(f);
            },
            .lifecycle => |l| {
                try self.writer.writeInt(u8, @intFromEnum(l), .little);
            },
            .tick => |t| {
                try self.writer.writeInt(u64, t.dt_ns, .little);
            },
        }

        self.last_tick = e.tick_id;
        self.last_time = e.t_ns;
    }
};

/// Deserializer with delta decoding
pub const Deserializer = struct {
    reader: std.io.AnyReader,
    last_tick: u64,
    last_time: u64,

    pub fn init(reader: std.io.AnyReader) Deserializer {
        return .{
            .reader = reader,
            .last_tick = 0,
            .last_time = 0,
        };
    }

    pub fn readHeader(self: *Deserializer) !Header {
        const header = try self.reader.readStructEndian(Header, .little);
        try header.validate();
        return header;
    }

    pub fn readEvent(self: *Deserializer) !Event {
        const tick_delta = try self.reader.readInt(u64, .little);
        const time_delta = try self.reader.readInt(u64, .little);
        const seq = try self.reader.readInt(u32, .little);

        const tick_id = self.last_tick + tick_delta;
        const t_ns = self.last_time + time_delta;

        const tag = try self.reader.readInt(u8, .little);

        const payload = try self.readPayload(tag);

        self.last_tick = tick_id;
        self.last_time = t_ns;

        return Event.init(tick_id, t_ns, seq, payload);
    }

    fn readPayload(self: *Deserializer, tag: u8) !event.EventPayload {
        const dummy: event.EventPayload = undefined;
        return switch (tag) {
            0 => .{ .pointer_move = try self.reader.readStruct(@TypeOf(dummy.pointer_move)) },
            1 => .{ .pointer_button = try self.reader.readStruct(@TypeOf(dummy.pointer_button)) },
            2 => .{ .wheel = try self.reader.readStruct(@TypeOf(dummy.wheel)) },
            3 => .{ .key = try self.reader.readStruct(@TypeOf(dummy.key)) },
            4 => .{ .text = try self.reader.readStruct(@TypeOf(dummy.text)) },
            5 => .{ .resize = try self.reader.readStruct(@TypeOf(dummy.resize)) },
            6 => .{ .focus = try self.reader.readStruct(@TypeOf(dummy.focus)) },
            7 => blk: {
                const val = try self.reader.readInt(u8, .little);
                break :blk .{ .lifecycle = @enumFromInt(val) };
            },
            8 => blk: {
                const dt_ns = try self.reader.readInt(u64, .little);
                break :blk .{ .tick = .{ .dt_ns = dt_ns } };
            },
            else => error.InvalidPayloadTag,
        };
    }
};

test "Serialize and deserialize header" {
    var buffer: std.ArrayList(u8) = .{};
    defer buffer.deinit(std.testing.allocator);

    var serializer = Serializer.init(buffer.writer(std.testing.allocator).any());
    try serializer.writeHeader(120);

    var fbs = std.io.fixedBufferStream(buffer.items);
    var deserializer = Deserializer.init(fbs.reader().any());
    const header = try deserializer.readHeader();

    try std.testing.expectEqual(@as(u32, 120), header.tick_hz);
}

test "Serialize and deserialize events with delta encoding" {
    var buffer: std.ArrayList(u8) = .{};
    defer buffer.deinit(std.testing.allocator);

    var serializer = Serializer.init(buffer.writer(std.testing.allocator).any());
    try serializer.writeHeader(120);

    const e1 = Event.init(0, 1000, 0, .{ .lifecycle = .init });
    const e2 = Event.init(0, 2000, 1, .{ .lifecycle = .paused });
    const e3 = Event.init(1, 3000, 0, .{ .lifecycle = .resumed });

    try serializer.writeEvent(e1);
    try serializer.writeEvent(e2);
    try serializer.writeEvent(e3);

    var fbs = std.io.fixedBufferStream(buffer.items);
    var deserializer = Deserializer.init(fbs.reader().any());
    _ = try deserializer.readHeader();

    const de1 = try deserializer.readEvent();
    const de2 = try deserializer.readEvent();
    const de3 = try deserializer.readEvent();

    try std.testing.expectEqual(e1.tick_id, de1.tick_id);
    try std.testing.expectEqual(e1.t_ns, de1.t_ns);
    try std.testing.expectEqual(e2.tick_id, de2.tick_id);
    try std.testing.expectEqual(e3.tick_id, de3.tick_id);
}
