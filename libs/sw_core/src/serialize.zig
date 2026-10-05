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
            .reserved = @splat(0),
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
    writer: *std.Io.Writer,
    last_tick: u64,
    last_time: u64,

    pub fn init(writer: *std.Io.Writer) Serializer {
        return .{
            .writer = writer,
            .last_tick = 0,
            .last_time = 0,
        };
    }

    pub fn writeHeader(self: *Serializer, tick_hz: u32) !void {
        const header = Header.init(tick_hz);
        try self.writer.writeStruct(header, .little);
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
                try self.writer.writeStruct(p, .little);
            },
            .pointer_button => |p| {
                try self.writer.writeStruct(p, .little);
            },
            .wheel => |w| {
                try self.writer.writeStruct(w, .little);
            },
            .key => |k| {
                try self.writer.writeStruct(k, .little);
            },
            .text => |t| {
                try self.writer.writeStruct(t, .little);
            },
            .resize => |r| {
                try self.writer.writeStruct(r, .little);
            },
            .focus => |f| {
                try self.writer.writeStruct(f, .little);
            },
            .lifecycle => |l| {
                try self.writer.writeInt(u8, @intFromEnum(l), .little);
            },
            .tick => |t| {
                try self.writer.writeInt(u64, t.dt_ns, .little);
            },
            // command is not an extern struct, so write its fields one by one.
            .command => |c| {
                try self.writer.writeInt(u8, @intFromEnum(c.kind), .little);
                for (c.args) |arg| try self.writer.writeInt(u32, @bitCast(arg), .little);
            },
        }

        self.last_tick = e.tick_id;
        self.last_time = e.t_ns;
    }
};

/// Deserializer with delta decoding
pub const Deserializer = struct {
    reader: *std.Io.Reader,
    last_tick: u64,
    last_time: u64,

    pub fn init(reader: *std.Io.Reader) Deserializer {
        return .{
            .reader = reader,
            .last_tick = 0,
            .last_time = 0,
        };
    }

    pub fn readHeader(self: *Deserializer) !Header {
        const header = try self.reader.takeStruct(Header, .little);
        try header.validate();
        return header;
    }

    pub fn readEvent(self: *Deserializer) !Event {
        const tick_delta = try self.reader.takeInt(u64, .little);
        const time_delta = try self.reader.takeInt(u64, .little);
        const seq = try self.reader.takeInt(u32, .little);

        const tick_id = self.last_tick + tick_delta;
        const t_ns = self.last_time + time_delta;

        const tag = try self.reader.takeInt(u8, .little);

        const payload = try self.readPayload(tag);

        self.last_tick = tick_id;
        self.last_time = t_ns;

        return Event.init(tick_id, t_ns, seq, payload);
    }

    fn readPayload(self: *Deserializer, tag: u8) !event.EventPayload {
        const dummy: event.EventPayload = undefined;
        return switch (tag) {
            0 => .{ .pointer_move = try self.reader.takeStruct(@TypeOf(dummy.pointer_move), .little) },
            1 => .{ .pointer_button = try self.reader.takeStruct(@TypeOf(dummy.pointer_button), .little) },
            2 => .{ .wheel = try self.reader.takeStruct(@TypeOf(dummy.wheel), .little) },
            3 => .{ .key = try self.reader.takeStruct(@TypeOf(dummy.key), .little) },
            4 => .{ .text = try self.reader.takeStruct(@TypeOf(dummy.text), .little) },
            5 => .{ .resize = try self.reader.takeStruct(@TypeOf(dummy.resize), .little) },
            6 => .{ .focus = try self.reader.takeStruct(@TypeOf(dummy.focus), .little) },
            7 => blk: {
                const val = try self.reader.takeInt(u8, .little);
                break :blk .{ .lifecycle = @enumFromInt(val) };
            },
            8 => blk: {
                const dt_ns = try self.reader.takeInt(u64, .little);
                break :blk .{ .tick = .{ .dt_ns = dt_ns } };
            },
            9 => blk: {
                const kind = try self.reader.takeEnum(event.CommandKind, .little);
                var args: [4]f32 = undefined;
                for (&args) |*arg| arg.* = @bitCast(try self.reader.takeInt(u32, .little));
                break :blk .{ .command = .{ .kind = kind, .args = args } };
            },
            else => error.InvalidPayloadTag,
        };
    }
};

test "Serialize and deserialize header" {
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();

    var serializer = Serializer.init(&buffer.writer);
    try serializer.writeHeader(120);

    var reader: std.Io.Reader = .fixed(buffer.written());
    var deserializer = Deserializer.init(&reader);
    const header = try deserializer.readHeader();

    try std.testing.expectEqual(@as(u32, 120), header.tick_hz);
}

test "Serialize and deserialize events with delta encoding" {
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();

    var serializer = Serializer.init(&buffer.writer);
    try serializer.writeHeader(120);

    const e1 = Event.init(0, 1000, 0, .{ .lifecycle = .init });
    const e2 = Event.init(0, 2000, 1, .{ .lifecycle = .paused });
    const e3 = Event.init(1, 3000, 0, .{ .lifecycle = .resumed });

    try serializer.writeEvent(e1);
    try serializer.writeEvent(e2);
    try serializer.writeEvent(e3);

    var reader: std.Io.Reader = .fixed(buffer.written());
    var deserializer = Deserializer.init(&reader);
    _ = try deserializer.readHeader();

    const de1 = try deserializer.readEvent();
    const de2 = try deserializer.readEvent();
    const de3 = try deserializer.readEvent();

    try std.testing.expectEqual(e1.tick_id, de1.tick_id);
    try std.testing.expectEqual(e1.t_ns, de1.t_ns);
    try std.testing.expectEqual(e2.tick_id, de2.tick_id);
    try std.testing.expectEqual(e3.tick_id, de3.tick_id);
}

test "Serialize and deserialize a command event" {
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();

    var serializer = Serializer.init(&buffer.writer);
    try serializer.writeHeader(120);
    const sent = Event.init(3, 4000, 2, .{ .command = .{ .kind = .tp, .args = .{ 1.5, -64.0, 1e6, 0.0 } } });
    try serializer.writeEvent(sent);

    var reader: std.Io.Reader = .fixed(buffer.written());
    var deserializer = Deserializer.init(&reader);
    _ = try deserializer.readHeader();
    const got = try deserializer.readEvent();

    try std.testing.expectEqual(sent.tick_id, got.tick_id);
    try std.testing.expectEqual(sent.t_ns, got.t_ns);
    try std.testing.expectEqual(sent.seq, got.seq);
    try std.testing.expectEqual(event.CommandKind.tp, got.payload.command.kind);
    try std.testing.expectEqual(sent.payload.command.args, got.payload.command.args);
}
