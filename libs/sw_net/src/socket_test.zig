//! The native client against a local WebSocket server that the test starts.
//! The server listens on 127.0.0.1 with a port from the system, so the test
//! needs no network.
const std = @import("std");
const net = std.Io.net;
const frame = @import("frame.zig");
const handshake = @import("handshake.zig");
const sock_mod = @import("socket.zig");
const Socket = sock_mod.Socket;

const testing = std.testing;

/// A small WebSocket server. It handles `connections` connections, one at a
/// time, then stops. The request path selects the behaviour:
/// - "/echo": send each message back. Some text messages are commands:
///   "frag" (send "Hello" in two parts), "ping-me" (send a ping, then the
///   pong payload as text), "drop" (stop TCP with no close frame), "bye"
///   (send close 4001).
/// - "/reject": answer 404, with no upgrade.
const TestServer = struct {
    io: std.Io,
    server: net.Server,
    connections: usize,
    thread: std.Thread = undefined,
    joined: bool = false,
    /// The number of client frames without a mask, or with another protocol
    /// error. It must stay 0 (REQ-NET-002).
    errors: std.atomic.Value(u32) = .init(0),
    /// The number of client frames that had a mask.
    masked_frames: std.atomic.Value(u32) = .init(0),

    fn start(self: *TestServer, io: std.Io, connections: usize) !void {
        const address: net.IpAddress = .{ .ip4 = .loopback(0) };
        self.* = .{ .io = io, .server = try address.listen(io, .{}), .connections = connections };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn url(self: *TestServer, buf: []u8, path: []const u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "ws://127.0.0.1:{d}{s}", .{ self.server.socket.address.getPort(), path });
    }

    /// Wait until the server handled all its connections.
    fn join(self: *TestServer) void {
        if (self.joined) return;
        self.thread.join();
        self.joined = true;
    }

    fn stop(self: *TestServer) void {
        self.join();
        self.server.deinit(self.io);
    }

    fn run(self: *TestServer) void {
        for (0..self.connections) |_| {
            const stream = self.server.accept(self.io) catch return;
            defer stream.close(self.io);
            self.serve(stream) catch {};
        }
    }

    fn serve(self: *TestServer, stream: net.Stream) !void {
        const io = self.io;
        var rbuf: [4096]u8 = undefined;
        var wbuf: [4096]u8 = undefined;
        var sr = stream.reader(io, &rbuf);
        var sw = stream.writer(io, &wbuf);
        const r = &sr.interface;
        const w = &sw.interface;

        // The request head.
        const request_line = try r.takeDelimiterInclusive('\n');
        const reject = std.mem.indexOf(u8, request_line, "/reject") != null;
        var key_buf: [64]u8 = undefined;
        var key: []const u8 = "";
        while (true) {
            const line = std.mem.trimEnd(u8, try r.takeDelimiterInclusive('\n'), "\r\n");
            if (line.len == 0) break;
            const prefix = "Sec-WebSocket-Key: ";
            if (std.mem.startsWith(u8, line, prefix)) {
                key = key_buf[0 .. line.len - prefix.len];
                @memcpy(@constCast(key), line[prefix.len..]);
            }
        }
        if (reject) {
            try w.writeAll("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
            return w.flush();
        }
        try w.print("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{&handshake.acceptFor(key)});
        try w.flush();

        var assembler: frame.Assembler = .{ .allocator = testing.allocator, .max_size = 1 << 20, .role = .server };
        defer assembler.deinit();
        var scratch: [frame.max_control_len]u8 = undefined;
        while (true) {
            const f = assembler.read(r, &scratch) catch |err| {
                if (err != error.EndOfStream) _ = self.errors.fetchAdd(1, .monotonic);
                return;
            };
            // Assembler.read with the server role accepts only masked frames.
            _ = self.masked_frames.fetchAdd(1, .monotonic);
            switch (f) {
                .fragment => {},
                .message => |m| {
                    defer testing.allocator.free(m.data);
                    if (m.kind == .text and std.mem.eql(u8, m.data, "frag")) {
                        try frame.writeFrame(w, false, .text, "Hel", null);
                        try frame.writeFrame(w, true, .ping, "x", null);
                        try frame.writeFrame(w, true, .continuation, "lo", null);
                    } else if (m.kind == .text and std.mem.eql(u8, m.data, "ping-me")) {
                        try frame.writeFrame(w, true, .ping, "abc", null);
                    } else if (m.kind == .text and std.mem.eql(u8, m.data, "drop")) {
                        return;
                    } else if (m.kind == .text and std.mem.eql(u8, m.data, "bye")) {
                        var payload: [frame.max_control_len]u8 = undefined;
                        try frame.writeFrame(w, true, .close, frame.encodeClose(&payload, 4001, "bye"), null);
                        try w.flush();
                        // Wait for the close reply of the client.
                        _ = assembler.read(r, &scratch) catch {};
                        return;
                    } else {
                        try frame.writeFrame(w, true, if (m.kind == .text) .text else .binary, m.data, null);
                    }
                    try w.flush();
                },
                .ping => |p| {
                    try frame.writeFrame(w, true, .pong, p, null);
                    try w.flush();
                },
                .pong => |p| {
                    var buf: [frame.max_control_len + 5]u8 = undefined;
                    try frame.writeFrame(w, true, .text, try std.fmt.bufPrint(&buf, "pong:{s}", .{p}), null);
                    try w.flush();
                },
                .close => |c| {
                    var payload: [frame.max_control_len]u8 = undefined;
                    try frame.writeFrame(w, true, .close, frame.encodeClose(&payload, c.code, ""), null);
                    try w.flush();
                    return;
                },
            }
        }
    }
};

/// Poll until the socket gives an event. Fails after 10 s.
fn nextEvent(s: *Socket) !sock_mod.Event {
    const io = testing.io;
    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        if (s.poll()) |ev| return ev;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.Timeout;
}

fn expectMessage(s: *Socket, kind: sock_mod.Kind, data: []const u8) !void {
    const ev = try nextEvent(s);
    try testing.expect(ev == .message);
    try testing.expectEqual(kind, ev.message.kind);
    try testing.expectEqualSlices(u8, data, ev.message.data);
}

test "socket: binary and text echo, fragments, ping, close (REQ-NET-001, REQ-NET-002)" {
    const io = testing.io;
    var server: TestServer = undefined;
    try server.start(io, 1);
    defer server.stop();
    var url_buf: [64]u8 = undefined;

    var s = try Socket.open(testing.allocator, io, try server.url(&url_buf, "/echo"), .{});
    defer s.deinit();
    try testing.expectEqual(sock_mod.State.connecting, s.state());
    try testing.expectError(error.NotOpen, s.send("early"));
    try testing.expect(try nextEvent(&s) == .open);
    try testing.expectEqual(sock_mod.State.open, s.state());

    // Binary messages with 7-bit, 16-bit and 64-bit lengths.
    const big = try testing.allocator.alloc(u8, 70_000);
    defer testing.allocator.free(big);
    for (big, 0..) |*b, i| b.* = @truncate(i *% 31);
    for ([_]usize{ 0, 5, 125, 300, 70_000 }) |len| try s.send(big[0..len]);
    for ([_]usize{ 0, 5, 125, 300, 70_000 }) |len| try expectMessage(&s, .binary, big[0..len]);

    try s.sendText("héllo");
    try expectMessage(&s, .text, "héllo");
    // The server sends "Hello" in two frames, with a ping "x" between
    // them. The server sends the payload of each pong back as text.
    try s.sendText("frag");
    try expectMessage(&s, .text, "Hello");
    try expectMessage(&s, .text, "pong:x");
    // The client answers a ping with a pong that has the same payload.
    try s.sendText("ping-me");
    try expectMessage(&s, .text, "pong:abc");

    try testing.expectError(error.InvalidCloseCode, s.close(1001, ""));
    try s.close(1000, "done");
    try testing.expectEqual(sock_mod.State.closing, s.state());
    const ev = try nextEvent(&s);
    try testing.expectEqual(@as(u16, 1000), ev.closed.code);
    try testing.expectEqual(sock_mod.Cause.closed, ev.closed.cause);
    try testing.expectEqual(@as(?u32, null), ev.closed.retry_in_ms);
    try testing.expectEqual(sock_mod.State.closed, s.state());

    server.join();
    try testing.expectEqual(@as(u32, 0), server.errors.load(.monotonic));
    // 5 binary, 3 text, 2 pong and 1 close frame. Each had a mask.
    try testing.expectEqual(@as(u32, 11), server.masked_frames.load(.monotonic));
}

test "socket: reconnect with backoff after a drop (REQ-NET-003)" {
    const io = testing.io;
    var server: TestServer = undefined;
    try server.start(io, 2);
    defer server.stop();
    var url_buf: [64]u8 = undefined;

    var s = try Socket.open(testing.allocator, io, try server.url(&url_buf, "/echo"), .{
        .reconnect = .{ .initial_ms = 20, .max_ms = 100 },
    });
    defer s.deinit();
    try testing.expect(try nextEvent(&s) == .open);

    // The server stops the TCP connection with no close frame.
    try s.sendText("drop");
    var ev = try nextEvent(&s);
    try testing.expectEqual(@as(u16, 1006), ev.closed.code);
    try testing.expectEqual(sock_mod.Cause.connection_lost, ev.closed.cause);
    try testing.expectEqual(@as(?u32, 20), ev.closed.retry_in_ms);
    try testing.expectEqual(sock_mod.State.waiting, s.state());
    try testing.expectError(error.NotOpen, s.send("x"));

    // The socket connects again by itself.
    try testing.expect(try nextEvent(&s) == .open);
    try s.send("again");
    try expectMessage(&s, .binary, "again");

    // A close from the server is also a drop for the reconnect. An open
    // connection set the attempt count to zero, so the delay is 20 ms again.
    try s.sendText("bye");
    ev = try nextEvent(&s);
    try testing.expectEqual(@as(u16, 4001), ev.closed.code);
    try testing.expectEqual(sock_mod.Cause.closed, ev.closed.cause);
    try testing.expectEqual(@as(?u32, 20), ev.closed.retry_in_ms);
    // `close` in the waiting state stops the reconnect.
    try s.close(1000, "");
    try testing.expectEqual(sock_mod.State.closed, s.state());
    try testing.expectEqual(@as(?sock_mod.Event, null), s.poll());
}

test "socket: upgrade refused and connect failed" {
    const io = testing.io;
    var url_buf: [64]u8 = undefined;
    {
        var server: TestServer = undefined;
        try server.start(io, 1);
        defer server.stop();
        var s = try Socket.open(testing.allocator, io, try server.url(&url_buf, "/reject"), .{});
        defer s.deinit();
        const ev = try nextEvent(&s);
        try testing.expectEqual(sock_mod.Cause.handshake_failed, ev.closed.cause);
        try testing.expectEqual(@as(u16, 1006), ev.closed.code);
        try testing.expectEqual(sock_mod.State.closed, s.state());
    }
    {
        // Get a free port, then close it, so nothing listens there.
        var server: TestServer = undefined;
        try server.start(io, 0);
        const text = try server.url(&url_buf, "/");
        server.stop();
        var s = try Socket.open(testing.allocator, io, text, .{ .reconnect = .{ .initial_ms = 5, .max_attempts = 1 } });
        defer s.deinit();
        var ev = try nextEvent(&s);
        try testing.expectEqual(sock_mod.Cause.connect_failed, ev.closed.cause);
        try testing.expectEqual(@as(?u32, 5), ev.closed.retry_in_ms);
        // The one attempt fails too. No attempt remains.
        ev = try nextEvent(&s);
        try testing.expectEqual(sock_mod.Cause.connect_failed, ev.closed.cause);
        try testing.expectEqual(@as(?u32, null), ev.closed.retry_in_ms);
        try testing.expectEqual(sock_mod.State.closed, s.state());
    }
}

test "socket: open errors" {
    try testing.expectError(error.InvalidUrl, Socket.open(testing.allocator, testing.io, "http://example.com/", .{}));
    try testing.expectError(error.InvalidUrl, Socket.open(testing.allocator, testing.io, "/api/ws", .{}));
    try testing.expectError(error.NoIo, Socket.open(testing.allocator, null, "ws://127.0.0.1:1/", .{}));
}
