const std = @import("std");
const event = @import("event.zig");
const Event = event.Event;

/// The format version that `Serializer` writes.
///
/// - 1: event tags 0 to 11.
/// - 2: adds the gamepad events, tags 12 to 14 (REQ-INPUT-005).
///
/// `Deserializer` reads each version from `MIN_VERSION` to `VERSION`, so an
/// old recording still plays (REQ-INPUT-006).
pub const VERSION: u32 = 2;

/// The oldest format version that `Deserializer` reads.
pub const MIN_VERSION: u32 = 1;

/// The largest event tag in each format version, from version 1.
const max_tag_of_version = [_]u8{ 11, 14 };

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
        if (self.version < MIN_VERSION or self.version > VERSION) {
            return error.UnsupportedVersion;
        }
    }

    /// The largest event tag that a file of this version can have.
    pub fn maxTag(self: *const Header) u8 {
        const v = std.math.clamp(self.version, MIN_VERSION, VERSION);
        return max_tag_of_version[v - MIN_VERSION];
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
        try self.writer.writeInt(u8, @backingInt(tag), .little);

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
            .text_input => |t| {
                try self.writer.writeStruct(t, .little);
            },
            .resize => |r| {
                try self.writer.writeStruct(r, .little);
            },
            .focus => |f| {
                try self.writer.writeStruct(f, .little);
            },
            .lifecycle => |l| {
                try self.writer.writeInt(u8, @backingInt(l), .little);
            },
            .tick => |t| {
                try self.writer.writeInt(u64, t.dt_ns, .little);
            },
            // command is not an extern struct, so write its fields one by one.
            .command => |c| {
                try self.writer.writeInt(u8, @backingInt(c.kind), .little);
                for (c.args) |arg| try self.writer.writeInt(u32, @bitCast(arg), .little);
            },
            .text_composition => |c| {
                try self.writer.writeStruct(c, .little);
            },
            .clipboard => |c| {
                try self.writer.writeStruct(c, .little);
            },
            // Write the gamepad events field by field, so the file has
            // no padding bytes.
            .gamepad_connection => |g| {
                try self.writer.writeInt(u8, g.pad, .little);
                try self.writer.writeInt(u8, @intFromBool(g.connected), .little);
            },
            .gamepad_button => |g| {
                try self.writer.writeInt(u8, g.pad, .little);
                try self.writer.writeInt(u8, @backingInt(g.button), .little);
                try self.writer.writeInt(u8, @intFromBool(g.down), .little);
            },
            .gamepad_axis => |g| {
                try self.writer.writeInt(u8, g.pad, .little);
                try self.writer.writeInt(u8, @backingInt(g.axis), .little);
                try self.writer.writeInt(u32, @bitCast(g.value), .little);
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
    /// The largest event tag of the file version. `readHeader` sets it.
    max_tag: u8 = max_tag_of_version[max_tag_of_version.len - 1],

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
        self.max_tag = header.maxTag();
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
        // A tag that the file version does not have is an error.
        if (tag > self.max_tag) return error.InvalidPayloadTag;
        const dummy: event.EventPayload = undefined;
        return switch (tag) {
            0 => .{ .pointer_move = try self.reader.takeStruct(@TypeOf(dummy.pointer_move), .little) },
            1 => .{ .pointer_button = try self.reader.takeStruct(@TypeOf(dummy.pointer_button), .little) },
            2 => .{ .wheel = try self.readWheel() },
            3 => .{ .key = try self.reader.takeStruct(@TypeOf(dummy.key), .little) },
            4 => .{ .text_input = try self.reader.takeStruct(@TypeOf(dummy.text_input), .little) },
            5 => .{ .resize = try self.reader.takeStruct(@TypeOf(dummy.resize), .little) },
            6 => .{ .focus = try self.reader.takeStruct(@TypeOf(dummy.focus), .little) },
            7 => blk: {
                const val = try self.reader.takeInt(u8, .little);
                break :blk .{ .lifecycle = @fromBackingInt(@intCast(val)) };
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
            10 => .{ .text_composition = try self.reader.takeStruct(@TypeOf(dummy.text_composition), .little) },
            11 => .{ .clipboard = try self.reader.takeStruct(event.ClipboardEvent, .little) },
            12 => .{ .gamepad_connection = .{
                .pad = try self.readPad(),
                .connected = try self.readBool(),
            } },
            13 => .{ .gamepad_button = .{
                .pad = try self.readPad(),
                .button = try self.reader.takeEnum(event.GamepadButton, .little),
                .down = try self.readBool(),
            } },
            14 => .{ .gamepad_axis = .{
                .pad = try self.readPad(),
                .axis = try self.reader.takeEnum(event.GamepadAxis, .little),
                .value = @bitCast(try self.reader.takeInt(u32, .little)),
            } },
            else => error.InvalidPayloadTag,
        };
    }

    const Wheel = @FieldType(event.EventPayload, "wheel");

    /// Reads a wheel event. A `mode` byte that is not a `WheelMode` gives
    /// `error.InvalidWheelMode`, not an invalid enum value (REQ-INPUT-010).
    fn readWheel(self: *Deserializer) !Wheel {
        const raw = try self.reader.peek(@sizeOf(Wheel));
        const mode = raw[@offsetOf(Wheel, "mode")];
        if (std.enums.fromInt(event.WheelMode, mode) == null) return error.InvalidWheelMode;
        return self.reader.takeStruct(Wheel, .little);
    }

    fn readPad(self: *Deserializer) !u8 {
        const pad = try self.reader.takeInt(u8, .little);
        if (pad >= event.max_gamepads) return error.InvalidGamepad;
        return pad;
    }

    fn readBool(self: *Deserializer) !bool {
        return switch (try self.reader.takeInt(u8, .little)) {
            0 => false,
            1 => true,
            else => error.InvalidBool,
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

test "Serialize and deserialize text events" {
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();

    var serializer = Serializer.init(&buffer.writer);
    try serializer.writeHeader(120);
    const committed = Event.init(1, 1000, 0, event.textInputPayload("\u{e9}"));
    const composing = Event.init(2, 2000, 0, event.textCompositionPayload("\u{3053}\u{3093}", 6, 0));
    try serializer.writeEvent(committed);
    try serializer.writeEvent(composing);

    var reader: std.Io.Reader = .fixed(buffer.written());
    var deserializer = Deserializer.init(&reader);
    _ = try deserializer.readHeader();
    const got_committed = try deserializer.readEvent();
    const got_composing = try deserializer.readEvent();

    const ti = got_committed.payload.text_input;
    try std.testing.expectEqualStrings("\u{e9}", ti.utf8[0..ti.len]);
    const tc = got_composing.payload.text_composition;
    try std.testing.expectEqualStrings("\u{3053}\u{3093}", tc.utf8[0..tc.len]);
    try std.testing.expectEqual(@as(u8, 6), tc.cursor);
}

test "Serialize and deserialize a clipboard event" {
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();

    var serializer = Serializer.init(&buffer.writer);
    try serializer.writeHeader(120);
    const sent = Event.init(4, 5000, 0, .{ .clipboard = .{ .kind = .read, .status = .denied, .len = 7 } });
    try serializer.writeEvent(sent);

    var reader: std.Io.Reader = .fixed(buffer.written());
    var deserializer = Deserializer.init(&reader);
    _ = try deserializer.readHeader();
    const got = try deserializer.readEvent();
    try std.testing.expectEqual(event.ClipboardEventKind.read, got.payload.clipboard.kind);
    try std.testing.expectEqual(event.ClipboardStatus.denied, got.payload.clipboard.status);
    try std.testing.expectEqual(@as(u32, 7), got.payload.clipboard.len);
}

test "Serialize and deserialize gamepad events (REQ-INPUT-005)" {
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();

    var serializer = Serializer.init(&buffer.writer);
    try serializer.writeHeader(120);
    try serializer.writeEvent(Event.init(1, 10, 0, .{ .gamepad_connection = .{ .pad = 2, .connected = true } }));
    try serializer.writeEvent(Event.init(1, 10, 1, .{ .gamepad_button = .{ .pad = 2, .button = .dpad_left, .down = true } }));
    try serializer.writeEvent(Event.init(2, 20, 0, .{ .gamepad_axis = .{ .pad = 2, .axis = .left_y, .value = -0.75 } }));

    var reader: std.Io.Reader = .fixed(buffer.written());
    var deserializer = Deserializer.init(&reader);
    const header = try deserializer.readHeader();
    try std.testing.expectEqual(VERSION, header.version);

    const c = (try deserializer.readEvent()).payload.gamepad_connection;
    try std.testing.expectEqual(@as(u8, 2), c.pad);
    try std.testing.expect(c.connected);
    const b = (try deserializer.readEvent()).payload.gamepad_button;
    try std.testing.expectEqual(event.GamepadButton.dpad_left, b.button);
    try std.testing.expect(b.down);
    const a = try deserializer.readEvent();
    try std.testing.expectEqual(@as(u64, 2), a.tick_id);
    try std.testing.expectEqual(event.GamepadAxis.left_y, a.payload.gamepad_axis.axis);
    try std.testing.expectEqual(@as(f32, -0.75), a.payload.gamepad_axis.value);
    try std.testing.expectError(error.EndOfStream, deserializer.readEvent());
}

test "a version 1 file reads, and cannot have the gamepad tags (REQ-INPUT-006)" {
    // Version 1 has the same bytes as version 2 for tags 0 to 11.
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    var serializer = Serializer.init(&buffer.writer);
    var old = Header.init(120);
    old.version = 1;
    try buffer.writer.writeStruct(old, .little);
    try serializer.writeEvent(Event.init(1, 10, 0, .{ .focus = .{ .focused = true } }));
    try serializer.writeEvent(Event.init(1, 10, 1, .{ .gamepad_connection = .{ .pad = 0, .connected = true } }));

    var reader: std.Io.Reader = .fixed(buffer.written());
    var deserializer = Deserializer.init(&reader);
    try std.testing.expectEqual(@as(u32, 1), (try deserializer.readHeader()).version);
    try std.testing.expect((try deserializer.readEvent()).payload.focus.focused);
    try std.testing.expectError(error.InvalidPayloadTag, deserializer.readEvent());

    // A version from the future does not read.
    var future = Header.init(120);
    future.version = VERSION + 1;
    try std.testing.expectError(error.UnsupportedVersion, future.validate());
    future.version = 0;
    try std.testing.expectError(error.UnsupportedVersion, future.validate());
}

test "a wheel event with a bad mode byte gives an error (REQ-INPUT-010)" {
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    var serializer = Serializer.init(&buffer.writer);
    try serializer.writeHeader(120);
    try serializer.writeEvent(Event.init(1, 10, 0, .{ .wheel = .{ .dx = 0, .dy = 1, .mode = .page, .mods = .{} } }));
    const bad_at = buffer.written().len;
    try serializer.writeEvent(Event.init(1, 10, 1, .{ .wheel = .{ .dx = 0, .dy = 1, .mode = .line, .mods = .{} } }));

    // The event head is 21 bytes: two u64 deltas, a u32 seq and the tag.
    const head = 8 + 8 + 4 + 1;
    const bytes = buffer.written();
    bytes[bad_at + head + @offsetOf(Deserializer.Wheel, "mode")] = 3;

    var reader: std.Io.Reader = .fixed(bytes);
    var deserializer = Deserializer.init(&reader);
    _ = try deserializer.readHeader();
    const good = (try deserializer.readEvent()).payload.wheel;
    try std.testing.expectEqual(event.WheelMode.page, good.mode);
    try std.testing.expectEqual(@as(f32, 1), good.dy);
    try std.testing.expectError(error.InvalidWheelMode, deserializer.readEvent());
}
