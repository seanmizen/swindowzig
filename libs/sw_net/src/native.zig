//! The native transport: a WebSocket client (RFC 6455) on `std.Io`.
//!
//! Each connection has one network thread. The thread connects, does the
//! TLS handshake for `wss:`, does the HTTP upgrade, then reads frames and
//! writes the frames that the app queued. Only this thread reads or writes
//! the connection, so the TLS state has one owner. The game thread and the
//! network thread share a mutex-guarded queue in each direction
//! (REQ-NET-001).
//!
//! The thread waits for socket data with a timeout of `wait_ms`, then
//! writes the queued frames. So a queued frame waits `wait_ms` at most.
const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const tls = std.crypto.tls;
const frame = @import("frame.zig");
const handshake = @import("handshake.zig");
const url_mod = @import("url.zig");
const types = @import("types.zig");

/// The game thread and the network thread share these allocations, so they
/// come from a thread-safe allocator, not from the app.
const gpa = std.heap.smp_allocator;

/// The longest wait for socket data before the thread writes queued frames.
const wait_ms = 2;
/// After the client sends a close frame, the longest wait for the reply.
const close_timeout_ms = 3000;
/// The buffer of a plain socket reader. The HTTP response head must fit.
const plain_buffer_len = 16 * 1024;

pub const StartError = error{ InvalidUrl, OutOfMemory };

const Outgoing = struct {
    opcode: frame.Opcode,
    data: []u8,
};

pub const Conn = struct {
    io: Io,
    /// One for the game thread, one for the network thread.
    refs: std.atomic.Value(u32) = .init(2),
    url: []u8,
    max_message_size: usize,

    mutex: Io.Mutex = .init,
    // `mutex` guards the fields below.
    inbox: std.ArrayList(types.TransportEvent) = .empty,
    inbox_head: usize = 0,
    outbox: std.ArrayList(Outgoing) = .empty,
    close_code: ?u16 = null,
    close_reason: [frame.max_control_len - 2]u8 = undefined,
    close_reason_len: usize = 0,
    /// The game thread released the connection. The thread stops.
    abort: bool = false,
    /// Set while the socket is open, so that `release` can shut it down.
    stream: ?net.Stream = null,

    /// Parse the URL and start the network thread. A connection error comes
    /// later, as a `closed` event.
    pub fn start(io: Io, url_text: []const u8, max_message_size: usize) StartError!*Conn {
        _ = url_mod.parse(url_text) catch return error.InvalidUrl;
        const c = try gpa.create(Conn);
        errdefer gpa.destroy(c);
        c.* = .{
            .io = io,
            .url = try gpa.dupe(u8, url_text),
            .max_message_size = max_message_size,
        };
        const thread = std.Thread.spawn(.{}, run, .{c}) catch {
            c.refs.store(1, .monotonic);
            c.push(.{ .closed = .{ .code = frame.abnormal, .cause = .connect_failed } });
            return c;
        };
        thread.detach();
        return c;
    }

    /// Queue one data frame. The connection copies `bytes`.
    pub fn send(c: *Conn, kind: types.Kind, bytes: []const u8) error{OutOfMemory}!void {
        const data = try gpa.dupe(u8, bytes);
        errdefer gpa.free(data);
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        try c.outbox.append(gpa, .{ .opcode = if (kind == .text) .text else .binary, .data = data });
    }

    /// Start the close handshake. A second call does nothing.
    pub fn close(c: *Conn, code: u16, reason: []const u8) void {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        if (c.close_code != null) return;
        c.close_code = code;
        const n = @min(reason.len, c.close_reason.len);
        @memcpy(c.close_reason[0..n], reason[0..n]);
        c.close_reason_len = n;
    }

    /// The next event, or null.
    pub fn next(c: *Conn) ?types.TransportEvent {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        if (c.inbox_head == c.inbox.items.len) return null;
        const ev = c.inbox.items[c.inbox_head];
        c.inbox_head += 1;
        if (c.inbox_head == c.inbox.items.len) {
            c.inbox.clearRetainingCapacity();
            c.inbox_head = 0;
        }
        return ev;
    }

    pub fn freeMessage(_: *Conn, data: []u8) void {
        gpa.free(data);
    }

    /// Stop the connection without a close handshake, and give up the game
    /// thread's reference. Do not use `c` after this call.
    pub fn release(c: *Conn) void {
        {
            c.mutex.lockUncancelable(c.io);
            defer c.mutex.unlock(c.io);
            c.abort = true;
            // A blocking read or write in the thread stops with an error.
            if (c.stream) |s| s.shutdown(c.io, .both) catch {};
        }
        c.unref();
    }

    fn unref(c: *Conn) void {
        if (c.refs.fetchSub(1, .acq_rel) != 1) return;
        for (c.inbox.items[c.inbox_head..]) |ev| if (ev == .message) gpa.free(ev.message.data);
        c.inbox.deinit(gpa);
        for (c.outbox.items) |o| gpa.free(o.data);
        c.outbox.deinit(gpa);
        gpa.free(c.url);
        gpa.destroy(c);
    }

    fn push(c: *Conn, ev: types.TransportEvent) void {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        c.inbox.append(gpa, ev) catch {
            // No memory for the event. A message is lost. A closed event
            // must arrive, so the thread drops the oldest event for it.
            if (ev == .message) {
                gpa.free(ev.message.data);
                return;
            }
            if (c.inbox.items.len > c.inbox_head) {
                const old = &c.inbox.items[c.inbox.items.len - 1];
                if (old.* == .message) gpa.free(old.message.data);
                old.* = ev;
            }
        };
    }

    fn aborted(c: *Conn) bool {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        return c.abort;
    }

    fn run(c: *Conn) void {
        defer c.unref();
        const closed = c.session();
        if (!c.aborted()) c.push(.{ .closed = closed });
    }

    /// Connect, upgrade and run the frame loop. Returns the close status.
    fn session(c: *Conn) types.Closed {
        const io = c.io;
        const url = url_mod.parse(c.url) catch unreachable; // `start` checked it.
        const lost: types.Closed = .{ .code = frame.abnormal, .cause = .connection_lost };
        const no_connect: types.Closed = .{ .code = frame.abnormal, .cause = .connect_failed };

        const stream = connect(io, url) catch return no_connect;
        {
            c.mutex.lockUncancelable(io);
            defer c.mutex.unlock(io);
            if (c.abort) {
                stream.close(io);
                return lost;
            }
            c.stream = stream;
        }
        defer {
            c.mutex.lockUncancelable(io);
            c.stream = null;
            c.mutex.unlock(io);
            stream.close(io);
        }

        // One allocation for every buffer. TLS needs a full record in each
        // socket buffer.
        const sock_len: usize = if (url.secure) tls.Client.min_buffer_len else plain_buffer_len;
        const tls_read_len: usize = if (url.secure) tls.Client.min_buffer_len + plain_buffer_len else 0;
        const tls_write_len: usize = if (url.secure) 1024 else 0;
        const buffers = gpa.alloc(u8, 2 * sock_len + tls_read_len + tls_write_len) catch return no_connect;
        defer gpa.free(buffers);
        var stream_reader = stream.reader(io, buffers[0..sock_len]);
        var stream_writer = stream.writer(io, buffers[sock_len..][0..sock_len]);

        var ca_lock: Io.RwLock = .init;
        var ca_bundle: std.crypto.Certificate.Bundle = .empty;
        defer ca_bundle.deinit(gpa);
        var tls_client: tls.Client = undefined;
        if (url.secure) {
            const now = Io.Clock.real.now(io);
            ca_bundle.rescan(gpa, io, now) catch return no_connect;
            var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
            io.random(&entropy);
            const tls_read = buffers[2 * sock_len ..][0..tls_read_len];
            tls_client = tls.Client.init(&stream_reader.interface, &stream_writer.interface, .{
                .host = .{ .explicit = url.host },
                .ca = .{ .bundle = .{ .gpa = gpa, .io = io, .lock = &ca_lock, .bundle = &ca_bundle } },
                .read_buffer = tls_read,
                .write_buffer = buffers[2 * sock_len + tls_read_len ..][0..tls_write_len],
                .entropy = &entropy,
                .realtime_now = now,
            }) catch return no_connect;
        }

        var link: Link = .{
            .io = io,
            .stream = stream,
            .stream_reader = &stream_reader,
            .stream_writer = &stream_writer,
            .tls_client = if (url.secure) &tls_client else null,
        };

        // The HTTP upgrade.
        var nonce: [16]u8 = undefined;
        io.random(&nonce);
        const key = handshake.makeKey(nonce);
        handshake.writeRequest(link.writer(), url, &key) catch return lost;
        link.flush() catch return lost;
        handshake.readResponse(link.reader(), &key) catch |err| return switch (err) {
            error.ReadFailed, error.EndOfStream => lost,
            else => .{ .code = frame.abnormal, .cause = .handshake_failed },
        };
        c.push(.open);

        return c.frameLoop(&link);
    }

    fn frameLoop(c: *Conn, link: *Link) types.Closed {
        const io = c.io;
        const lost: types.Closed = .{ .code = frame.abnormal, .cause = .connection_lost };
        var assembler: frame.Assembler = .{ .allocator = gpa, .max_size = c.max_message_size };
        defer assembler.deinit();
        var scratch: [frame.max_control_len]u8 = undefined;
        var sent_close = false;
        var close_deadline: ?Io.Clock.Timestamp = null;
        var wait: Wait = .{ .link = link };
        defer wait.cancel();

        while (true) {
            // 1. Write the queued frames.
            var outgoing: std.ArrayList(Outgoing) = .empty;
            defer {
                for (outgoing.items) |o| gpa.free(o.data);
                outgoing.deinit(gpa);
            }
            var close_code: ?u16 = null;
            var reason_buf: [frame.max_control_len - 2]u8 = undefined;
            var reason_len: usize = 0;
            {
                c.mutex.lockUncancelable(io);
                defer c.mutex.unlock(io);
                if (c.abort) return lost;
                std.mem.swap(std.ArrayList(Outgoing), &outgoing, &c.outbox);
                if (!sent_close) if (c.close_code) |code| {
                    close_code = code;
                    reason_len = c.close_reason_len;
                    @memcpy(reason_buf[0..reason_len], c.close_reason[0..reason_len]);
                };
            }
            if (!sent_close) for (outgoing.items) |o| {
                link.writeFrame(o.opcode, o.data) catch return lost;
            };
            if (close_code) |code| {
                var payload: [frame.max_control_len]u8 = undefined;
                link.writeFrame(.close, frame.encodeClose(&payload, code, reason_buf[0..reason_len])) catch return lost;
                sent_close = true;
                close_deadline = Io.Clock.Timestamp.fromNow(io, .{ .raw = .fromMilliseconds(close_timeout_ms), .clock = .awake });
            }
            if (outgoing.items.len > 0 or close_code != null) link.flush() catch return lost;

            // 2. Wait for data.
            if (!link.hasBuffered()) {
                switch (wait.poll()) {
                    .data => {},
                    .timeout => {
                        if (close_deadline) |d| if (Io.Clock.Timestamp.now(io, .awake).compare(.gte, d))
                            return .{ .code = frame.abnormal, .cause = .closed };
                        continue;
                    },
                    .failed => return lost,
                }
            }

            // 3. Read one frame.
            const f = assembler.read(link.reader(), &scratch) catch |err| {
                const code = frame.closeCodeFor(err) orelse return lost;
                if (!sent_close) {
                    var payload: [frame.max_control_len]u8 = undefined;
                    link.writeFrame(.close, frame.encodeClose(&payload, code, "")) catch {};
                    link.flush() catch {};
                }
                return .{ .code = code, .cause = .protocol_error };
            };
            switch (f) {
                .message => |m| c.push(.{ .message = m }),
                .fragment, .pong => {},
                .ping => |payload| {
                    if (!sent_close) {
                        link.writeFrame(.pong, payload) catch return lost;
                        link.flush() catch return lost;
                    }
                },
                .close => |status| {
                    if (!sent_close) {
                        // Send the code back (RFC 6455, 5.5.1).
                        var payload: [frame.max_control_len]u8 = undefined;
                        const body = if (status.code == frame.no_status) "" else frame.encodeClose(&payload, status.code, "");
                        link.writeFrame(.close, body) catch {};
                        link.flush() catch {};
                    }
                    return .{ .code = status.code, .cause = .closed };
                },
            }
        }
    }
};

/// The byte stream of one connection: plain TCP or TLS over TCP.
const Link = struct {
    io: Io,
    stream: net.Stream,
    stream_reader: *net.Stream.Reader,
    stream_writer: *net.Stream.Writer,
    tls_client: ?*tls.Client,

    fn reader(l: *Link) *Io.Reader {
        return if (l.tls_client) |t| &t.reader else &l.stream_reader.interface;
    }

    fn writer(l: *Link) *Io.Writer {
        return if (l.tls_client) |t| &t.writer else &l.stream_writer.interface;
    }

    fn flush(l: *Link) Io.Writer.Error!void {
        if (l.tls_client) |t| try t.writer.flush();
        try l.stream_writer.interface.flush();
    }

    /// True when a read can use bytes that already arrived.
    fn hasBuffered(l: *Link) bool {
        if (l.stream_reader.interface.bufferedLen() > 0) return true;
        if (l.tls_client) |t| return t.reader.bufferedLen() > 0;
        return false;
    }

    /// A client masks each frame with a new random key (RFC 6455, 5.3).
    fn writeFrame(l: *Link, opcode: frame.Opcode, payload: []const u8) Io.Writer.Error!void {
        var key: [4]u8 = undefined;
        l.io.random(&key);
        try frame.writeFrame(l.writer(), true, opcode, payload, key);
    }
};

/// Waits for socket data with a timeout. The read goes into the buffer of
/// the socket reader, so the frame reader and the TLS client see the bytes.
const Wait = struct {
    link: *Link,
    storage: [1]Io.Operation.Storage = undefined,
    batch: ?Io.Batch = null,
    vec: [1][]u8 = undefined,

    const Result = enum { data, timeout, failed };

    fn poll(w: *Wait) Result {
        const io = w.link.io;
        const r = &w.link.stream_reader.interface;
        if (w.batch == null) {
            // The buffer is empty (hasBuffered is false), so the read can
            // start at the front.
            r.seek = 0;
            r.end = 0;
            w.vec = .{r.buffer};
            w.batch = .init(&w.storage);
            w.batch.?.addAt(0, .{ .net_read = .{ .socket_handle = w.link.stream.socket.handle, .data = &w.vec } });
        }
        const b = &w.batch.?;
        b.awaitConcurrent(io, .{ .duration = .{ .raw = .fromMilliseconds(wait_ms), .clock = .awake } }) catch |err| switch (err) {
            error.Timeout => return .timeout,
            error.Canceled => return .failed,
            // No concurrent wait in this Io. Wait without a timeout.
            error.ConcurrencyUnavailable => b.awaitAsync(io) catch return .failed,
        };
        const completion = b.next() orelse return .timeout;
        w.batch = null;
        const result = completion.result.net_read catch return .failed;
        // Zero bytes is the end of the stream. The frame reader reads it
        // again and gets EndOfStream.
        r.end = result.data_len;
        return .data;
    }

    fn cancel(w: *Wait) void {
        if (w.batch) |*b| {
            b.cancel(w.link.io);
            while (b.next()) |_| {}
            w.batch = null;
        }
    }
};

fn connect(io: Io, url: url_mod.Url) !net.Stream {
    if (net.IpAddress.parse(url.host, url.port)) |address| {
        return address.connect(io, .{ .mode = .stream });
    } else |_| {
        const host = try net.HostName.init(url.host);
        return host.connect(io, url.port, .{ .mode = .stream });
    }
}
