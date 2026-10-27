//! WebSocket frames (RFC 6455, section 5): the header, the mask, the close
//! payload, and the assembly of a fragmented message. No sockets here: the
//! functions read an `std.Io.Reader` and write an `std.Io.Writer`, so the
//! tests use fixed buffers.
const std = @import("std");
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,

    pub fn isControl(op: Opcode) bool {
        return @backingInt(op) & 0x8 != 0;
    }
};

/// The longest header: 2 bytes, an 8-byte length and a 4-byte mask.
pub const max_header_len = 14;
/// The longest payload of a control frame (RFC 6455, 5.5).
pub const max_control_len = 125;

/// The side of the connection that reads or writes a frame. A client masks
/// each frame that it sends, and a server masks none (RFC 6455, 5.1).
pub const Role = enum { client, server };

pub const Header = struct {
    fin: bool,
    opcode: Opcode,
    masked: bool,
    len: u64,
    mask: [4]u8 = .{ 0, 0, 0, 0 },
};

/// Write the header of one frame into `buf`. Returns the bytes to send.
pub fn encodeHeader(buf: *[max_header_len]u8, fin: bool, opcode: Opcode, len: u64, mask: ?[4]u8) []u8 {
    buf[0] = @as(u8, if (fin) 0x80 else 0) | @as(u8, @backingInt(opcode));
    const mask_bit: u8 = if (mask != null) 0x80 else 0;
    var n: usize = 2;
    if (len < 126) {
        buf[1] = mask_bit | @as(u8, @intCast(len));
    } else if (len <= 0xFFFF) {
        buf[1] = mask_bit | 126;
        std.mem.writeInt(u16, buf[2..4], @intCast(len), .big);
        n = 4;
    } else {
        buf[1] = mask_bit | 127;
        std.mem.writeInt(u64, buf[2..10], len, .big);
        n = 10;
    }
    if (mask) |m| {
        buf[n..][0..4].* = m;
        n += 4;
    }
    return buf[0..n];
}

/// XOR `data` with the mask key. `offset` is the position of `data[0]` in
/// the payload, so a payload can be masked in parts.
pub fn applyMask(data: []u8, key: [4]u8, offset: usize) void {
    for (data, 0..) |*b, i| b.* ^= key[(offset + i) % 4];
}

/// Write one frame. With a mask, the payload is masked in a copy:
/// `payload` does not change.
pub fn writeFrame(w: *Writer, fin: bool, opcode: Opcode, payload: []const u8, mask: ?[4]u8) Writer.Error!void {
    var hbuf: [max_header_len]u8 = undefined;
    try w.writeAll(encodeHeader(&hbuf, fin, opcode, payload.len, mask));
    const key = mask orelse return w.writeAll(payload);
    var chunk: [512]u8 = undefined;
    var done: usize = 0;
    while (done < payload.len) {
        const n = @min(chunk.len, payload.len - done);
        @memcpy(chunk[0..n], payload[done..][0..n]);
        applyMask(chunk[0..n], key, done);
        try w.writeAll(chunk[0..n]);
        done += n;
    }
}

/// A protocol error. The reader closes the connection with code 1002.
pub const ProtocolError = error{
    /// RSV1, RSV2 or RSV3 is set. This client negotiates no extension.
    ReservedBits,
    UnknownOpcode,
    /// A control frame is longer than 125 bytes, or has FIN clear.
    BadControlFrame,
    /// The mask bit is wrong for the role of the reader.
    BadMask,
    /// A 64-bit length has the top bit set, or a length is not minimal.
    BadLength,
    /// A continuation frame without a message, or a new data frame in the
    /// middle of a fragmented message.
    BadFragment,
    /// A close payload of 1 byte, or a close code that is not valid.
    BadClose,
};

/// Read one frame header.
pub fn readHeader(r: *Reader, role: Role) (Reader.Error || ProtocolError)!Header {
    const b0 = try r.takeByte();
    const b1 = try r.takeByte();
    if (b0 & 0x70 != 0) return error.ReservedBits;
    const opcode: Opcode = @fromBackingInt(@intCast(@as(u4, @truncate(b0))));
    switch (opcode) {
        .continuation, .text, .binary, .close, .ping, .pong => {},
        _ => return error.UnknownOpcode,
    }
    const fin = b0 & 0x80 != 0;
    const masked = b1 & 0x80 != 0;
    if (masked != (role == .server)) return error.BadMask;
    var len: u64 = b1 & 0x7F;
    if (len == 126) {
        len = try r.takeInt(u16, .big);
        if (len < 126) return error.BadLength;
    } else if (len == 127) {
        len = try r.takeInt(u64, .big);
        if (len >> 63 != 0 or len <= 0xFFFF) return error.BadLength;
    }
    if (opcode.isControl() and (len > max_control_len or !fin)) return error.BadControlFrame;
    var header: Header = .{ .fin = fin, .opcode = opcode, .masked = masked, .len = len };
    if (masked) header.mask = (try r.takeArray(4)).*;
    return header;
}

/// The status of a close frame.
pub const Close = struct {
    /// 1005 when the frame has no code (RFC 6455, 7.1.5).
    code: u16,
    reason: []const u8,
};

pub const no_status: u16 = 1005;
pub const abnormal: u16 = 1006;

/// True for a code that an endpoint can send in a close frame.
pub fn isValidCloseCode(code: u16) bool {
    return switch (code) {
        1000...1003, 1007...1014, 3000...4999 => true,
        else => false,
    };
}

pub fn parseClose(payload: []const u8) ProtocolError!Close {
    if (payload.len == 0) return .{ .code = no_status, .reason = "" };
    if (payload.len == 1) return error.BadClose;
    const code = std.mem.readInt(u16, payload[0..2], .big);
    if (!isValidCloseCode(code)) return error.BadClose;
    if (!std.unicode.utf8ValidateSlice(payload[2..])) return error.BadClose;
    return .{ .code = code, .reason = payload[2..] };
}

/// Write a close payload into `buf`. The reason is cut to fit 125 bytes.
pub fn encodeClose(buf: *[max_control_len]u8, code: u16, reason: []const u8) []u8 {
    std.mem.writeInt(u16, buf[0..2], code, .big);
    const n = @min(reason.len, max_control_len - 2);
    @memcpy(buf[2..][0..n], reason[0..n]);
    return buf[0 .. 2 + n];
}

pub const Kind = enum { text, binary };

/// One full message. The caller owns `data`.
pub const Message = struct {
    kind: Kind,
    data: []u8,
};

/// One frame, after `Assembler.read`.
pub const Frame = union(enum) {
    /// A full data message.
    message: Message,
    /// One part of a fragmented message. No message is complete yet.
    fragment,
    /// The payload is in the scratch buffer of the caller.
    ping: []const u8,
    pong: []const u8,
    close: Close,
};

/// Reads frames and joins the parts of a fragmented message.
pub const Assembler = struct {
    allocator: std.mem.Allocator,
    /// The largest message, in bytes, after the join.
    max_size: usize,
    role: Role = .client,
    buf: std.ArrayList(u8) = .empty,
    /// The kind of the message in progress, or null between messages.
    kind: ?Kind = null,

    pub const Error = Reader.Error || ProtocolError || error{
        /// The message is larger than `max_size`. Close code 1009.
        TooLarge,
        /// A text message is not UTF-8. Close code 1007.
        InvalidUtf8,
        OutOfMemory,
    };

    pub fn deinit(self: *Assembler) void {
        self.buf.deinit(self.allocator);
        self.* = undefined;
    }

    /// Read one frame from `r`. The payload of a control frame goes into
    /// `scratch`, and the result points into it.
    pub fn read(self: *Assembler, r: *Reader, scratch: *[max_control_len]u8) Error!Frame {
        const h = try readHeader(r, self.role);
        if (h.opcode.isControl()) {
            const payload = scratch[0..@intCast(h.len)];
            try r.readSliceAll(payload);
            if (h.masked) applyMask(payload, h.mask, 0);
            return switch (h.opcode) {
                .ping => .{ .ping = payload },
                .pong => .{ .pong = payload },
                .close => .{ .close = try parseClose(payload) },
                else => unreachable,
            };
        }
        switch (h.opcode) {
            .continuation => if (self.kind == null) return error.BadFragment,
            .text, .binary => {
                if (self.kind != null) return error.BadFragment;
                self.kind = if (h.opcode == .text) .text else .binary;
                self.buf.clearRetainingCapacity();
            },
            else => unreachable,
        }
        if (h.len > self.max_size - self.buf.items.len) return error.TooLarge;
        const dest = try self.buf.addManyAsSlice(self.allocator, @intCast(h.len));
        try r.readSliceAll(dest);
        if (h.masked) applyMask(dest, h.mask, 0);
        if (!h.fin) return .fragment;
        const kind = self.kind.?;
        self.kind = null;
        if (kind == .text and !std.unicode.utf8ValidateSlice(self.buf.items)) return error.InvalidUtf8;
        return .{ .message = .{ .kind = kind, .data = try self.buf.toOwnedSlice(self.allocator) } };
    }
};

/// The close code for an error of `Assembler.read`, or null when the error
/// is not a protocol error (the connection failed).
pub fn closeCodeFor(err: Assembler.Error) ?u16 {
    return switch (err) {
        error.ReadFailed, error.EndOfStream => null,
        error.TooLarge => 1009,
        error.InvalidUtf8 => 1007,
        error.OutOfMemory => 1011,
        else => 1002,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testAssembler(role: Role) Assembler {
    return .{ .allocator = testing.allocator, .max_size = 1 << 20, .role = role };
}

test "frame: RFC 6455 examples, unmasked and masked text" {
    var scratch: [max_control_len]u8 = undefined;
    // 5.7: a single-frame unmasked text message "Hello".
    {
        var r: Reader = .fixed(&.{ 0x81, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f });
        var a = testAssembler(.client);
        defer a.deinit();
        const f = try a.read(&r, &scratch);
        defer testing.allocator.free(f.message.data);
        try testing.expectEqual(Kind.text, f.message.kind);
        try testing.expectEqualStrings("Hello", f.message.data);
    }
    // 5.7: a single-frame masked text message "Hello" (a server reads it).
    {
        var r: Reader = .fixed(&.{ 0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58 });
        var a = testAssembler(.server);
        defer a.deinit();
        const f = try a.read(&r, &scratch);
        defer testing.allocator.free(f.message.data);
        try testing.expectEqualStrings("Hello", f.message.data);
    }
}

test "frame: the client writes the RFC 6455 masked example" {
    var out: [64]u8 = undefined;
    var w: Writer = .fixed(&out);
    try writeFrame(&w, true, .text, "Hello", .{ 0x37, 0xfa, 0x21, 0x3d });
    try testing.expectEqualSlices(u8, &.{ 0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58 }, w.buffered());
}

test "frame: fragmented text with a ping between the parts" {
    // 5.7: "Hel" then "lo", with a ping "Hello" between the two parts.
    var r: Reader = .fixed(&.{
        0x01, 0x03, 0x48, 0x65, 0x6c, // text, FIN clear
        0x89, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f, // ping
        0x80, 0x02, 0x6c, 0x6f, // continuation, FIN set
    });
    var scratch: [max_control_len]u8 = undefined;
    var a = testAssembler(.client);
    defer a.deinit();
    try testing.expectEqual(Frame.fragment, try a.read(&r, &scratch));
    try testing.expectEqualStrings("Hello", (try a.read(&r, &scratch)).ping);
    const f = try a.read(&r, &scratch);
    defer testing.allocator.free(f.message.data);
    try testing.expectEqualStrings("Hello", f.message.data);
}

test "frame: 16-bit and 64-bit lengths, binary, round trip" {
    inline for (.{ 125, 126, 300, 65535, 65536, 70000 }) |len| {
        const payload = try testing.allocator.alloc(u8, len);
        defer testing.allocator.free(payload);
        for (payload, 0..) |*b, i| b.* = @truncate(i *% 7);
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try writeFrame(&out.writer, true, .binary, payload, .{ 1, 2, 3, 4 });
        var hbuf: [max_header_len]u8 = undefined;
        const expected_header = if (len < 126) 6 else if (len <= 0xFFFF) 8 else 14;
        try testing.expectEqual(expected_header, encodeHeader(&hbuf, true, .binary, len, .{ 1, 2, 3, 4 }).len);

        var r: Reader = .fixed(out.written());
        var scratch: [max_control_len]u8 = undefined;
        var a = testAssembler(.server);
        defer a.deinit();
        const f = try a.read(&r, &scratch);
        defer testing.allocator.free(f.message.data);
        try testing.expectEqual(Kind.binary, f.message.kind);
        try testing.expectEqualSlices(u8, payload, f.message.data);
    }
}

test "frame: protocol errors" {
    var scratch: [max_control_len]u8 = undefined;
    const cases = [_]struct { bytes: []const u8, role: Role, err: Assembler.Error }{
        .{ .bytes = &.{ 0xC1, 0x00 }, .role = .client, .err = error.ReservedBits },
        .{ .bytes = &.{ 0x83, 0x00 }, .role = .client, .err = error.UnknownOpcode },
        .{ .bytes = &.{ 0x81, 0x80, 0, 0, 0, 0 }, .role = .client, .err = error.BadMask },
        .{ .bytes = &.{ 0x81, 0x00 }, .role = .server, .err = error.BadMask },
        .{ .bytes = &.{ 0x09, 0x00 }, .role = .client, .err = error.BadControlFrame },
        .{ .bytes = &.{ 0x89, 0x7E, 0x00, 0x7E }, .role = .client, .err = error.BadControlFrame },
        .{ .bytes = &.{ 0x82, 0x7E, 0x00, 0x05 }, .role = .client, .err = error.BadLength },
        .{ .bytes = &.{ 0x80, 0x00 }, .role = .client, .err = error.BadFragment },
        .{ .bytes = &.{ 0x01, 0x00, 0x01, 0x00 }, .role = .client, .err = error.BadFragment },
        .{ .bytes = &.{ 0x88, 0x01, 0x03 }, .role = .client, .err = error.BadClose },
        .{ .bytes = &.{ 0x88, 0x02, 0x03, 0xED }, .role = .client, .err = error.BadClose }, // 1005
        .{ .bytes = &.{ 0x81, 0x01, 0xFF }, .role = .client, .err = error.InvalidUtf8 },
    };
    for (cases) |case| {
        var r: Reader = .fixed(case.bytes);
        var a = testAssembler(case.role);
        defer a.deinit();
        // Read until the error. A fragment comes before some errors.
        while (true) {
            const f = a.read(&r, &scratch) catch |err| {
                try testing.expectEqual(case.err, err);
                break;
            };
            if (f == .message) testing.allocator.free(f.message.data);
        }
    }
}

test "frame: a message larger than max_size fails before the read" {
    var r: Reader = .fixed(&.{ 0x82, 0x7F, 0, 0, 0, 0, 0, 0x10, 0, 0 });
    var scratch: [max_control_len]u8 = undefined;
    var a: Assembler = .{ .allocator = testing.allocator, .max_size = 1000 };
    defer a.deinit();
    try testing.expectError(error.TooLarge, a.read(&r, &scratch));
    try testing.expectEqual(@as(?u16, 1009), closeCodeFor(error.TooLarge));
}

test "frame: close payload" {
    var buf: [max_control_len]u8 = undefined;
    const payload = encodeClose(&buf, 1000, "bye");
    const c = try parseClose(payload);
    try testing.expectEqual(@as(u16, 1000), c.code);
    try testing.expectEqualStrings("bye", c.reason);
    try testing.expectEqual(no_status, (try parseClose("")).code);
    try testing.expect(isValidCloseCode(4000));
    try testing.expect(!isValidCloseCode(1006));
    try testing.expect(!isValidCloseCode(999));
}
