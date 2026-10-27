//! The WebSocket opening handshake (RFC 6455, section 4): the HTTP Upgrade
//! request of the client, and the check of the server response.
const std = @import("std");
const Url = @import("url.zig").Url;

/// The GUID that RFC 6455 adds to the key before the SHA-1 hash.
const accept_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const key_len = 24;
pub const accept_len = 28;

/// The Sec-WebSocket-Key: 16 random bytes in base64.
pub fn makeKey(random: [16]u8) [key_len]u8 {
    var out: [key_len]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&out, &random);
    return out;
}

/// The Sec-WebSocket-Accept value that the server must send for `key`.
pub fn acceptFor(key: []const u8) [accept_len]u8 {
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(key);
    sha.update(accept_guid);
    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    sha.final(&digest);
    var out: [accept_len]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&out, &digest);
    return out;
}

pub fn writeRequest(w: *std.Io.Writer, url: Url, key: []const u8) std.Io.Writer.Error!void {
    try w.print("GET {s} HTTP/1.1\r\n", .{url.resource});
    try w.print("Host: {s}\r\n", .{url.host_header});
    try w.writeAll("Upgrade: websocket\r\nConnection: Upgrade\r\n");
    try w.print("Sec-WebSocket-Key: {s}\r\n", .{key});
    try w.writeAll("Sec-WebSocket-Version: 13\r\n\r\n");
}

pub const ResponseError = error{
    /// The status is not 101 Switching Protocols.
    NotUpgraded,
    /// Upgrade, Connection or Sec-WebSocket-Accept is missing or wrong.
    BadHeaders,
    /// The response head is longer than the read buffer, or is not HTTP.
    BadResponse,
    ReadFailed,
    EndOfStream,
};

/// Read the response head and check it. On success, the reader is at the
/// first byte after the head (the first frame).
pub fn readResponse(r: *std.Io.Reader, key: []const u8) ResponseError!void {
    const status = try readLine(r);
    // "HTTP/1.1 101 Switching Protocols"
    var parts = std.mem.tokenizeScalar(u8, status, ' ');
    const version = parts.next() orelse return error.BadResponse;
    if (!std.mem.startsWith(u8, version, "HTTP/")) return error.BadResponse;
    const code = parts.next() orelse return error.BadResponse;
    if (!std.mem.eql(u8, code, "101")) return error.NotUpgraded;

    const expected = acceptFor(key);
    var upgrade = false;
    var connection = false;
    var accept = false;
    while (true) {
        const line = try readLine(r);
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadResponse;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "upgrade")) {
            upgrade = std.ascii.eqlIgnoreCase(value, "websocket");
        } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
            connection = hasToken(value, "upgrade");
        } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-accept")) {
            accept = std.mem.eql(u8, value, &expected);
        } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-extensions")) {
            // The request asks for no extension.
            return error.BadHeaders;
        }
    }
    if (!(upgrade and connection and accept)) return error.BadHeaders;
}

/// Read one line without the CR LF.
fn readLine(r: *std.Io.Reader) ResponseError![]const u8 {
    const line = r.takeDelimiterInclusive('\n') catch |err| return switch (err) {
        error.StreamTooLong => error.BadResponse,
        error.ReadFailed => error.ReadFailed,
        error.EndOfStream => error.EndOfStream,
    };
    return std.mem.trimEnd(u8, line, "\r\n");
}

/// True when the comma-separated list `value` holds `token` (any case).
pub fn hasToken(value: []const u8, token: []const u8) bool {
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |part| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, part, " \t"), token)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "handshake: RFC 6455 accept example" {
    // RFC 6455, 1.3.
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &acceptFor("dGhlIHNhbXBsZSBub25jZQ=="));
    // RFC 6455, 4.1: the key is 16 bytes in base64. The RFC example nonce
    // is "the sample nonce".
    try testing.expectEqualStrings("dGhlIHNhbXBsZSBub25jZQ==", &makeKey("the sample nonce".*));
}

test "handshake: request" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const url = try @import("url.zig").parse("ws://example.com:9000/chat?x=1");
    try writeRequest(&w, url, "dGhlIHNhbXBsZSBub25jZQ==");
    try testing.expectEqualStrings(
        "GET /chat?x=1 HTTP/1.1\r\n" ++
            "Host: example.com:9000\r\n" ++
            "Upgrade: websocket\r\nConnection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
            "Sec-WebSocket-Version: 13\r\n\r\n",
        w.buffered(),
    );
}

test "handshake: response checks" {
    const key = "dGhlIHNhbXBsZSBub25jZQ==";
    const good = "HTTP/1.1 101 Switching Protocols\r\n" ++
        "upgrade: WebSocket\r\nConnection: keep-alive, Upgrade\r\n" ++
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n\x81\x00";
    {
        var r: std.Io.Reader = .fixed(good);
        try readResponse(&r, key);
        // The reader stops at the first frame.
        try testing.expectEqual(@as(u8, 0x81), try r.takeByte());
    }
    const cases = [_]struct { text: []const u8, err: ResponseError }{
        .{ .text = "HTTP/1.1 200 OK\r\n\r\n", .err = error.NotUpgraded },
        .{ .text = "SSH-2.0\r\n\r\n", .err = error.BadResponse },
        .{ .text = "HTTP/1.1 101 x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n", .err = error.BadHeaders },
        .{ .text = "HTTP/1.1 101 x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: AAAA\r\n\r\n", .err = error.BadHeaders },
        .{ .text = "HTTP/1.1 101 x\r\nUpgrade: websocket\r\n", .err = error.EndOfStream },
    };
    for (cases) |case| {
        var r: std.Io.Reader = .fixed(case.text);
        try testing.expectError(case.err, readResponse(&r, key));
    }
}
