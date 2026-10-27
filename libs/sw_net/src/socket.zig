//! `Socket`: one WebSocket connection that the game polls each tick, with
//! an optional reconnect. The same code runs on the web and on native. Only
//! the transport is different (`web.zig`, `native.zig`).
const std = @import("std");
const builtin = @import("builtin");
const frame = @import("frame.zig");
const types = @import("types.zig");
pub const Backoff = @import("backoff.zig").Backoff;

const is_wasm = builtin.cpu.arch.isWasm();
const native = if (is_wasm) struct {} else @import("native.zig");
const web = if (is_wasm) @import("web.zig") else struct {};
const Transport = if (is_wasm) web.Conn else *native.Conn;

pub const Kind = types.Kind;
pub const Cause = types.Cause;

pub const Options = struct {
    /// The largest message that the socket accepts, in bytes. A larger
    /// message closes the connection with code 1009.
    max_message_size: usize = 16 * 1024 * 1024,
    /// Null: no reconnect. Otherwise, after a connection closes without a
    /// call to `close`, the socket connects again after the backoff delay.
    reconnect: ?Backoff = null,
};

pub const State = enum {
    /// The connection or the upgrade is in progress.
    connecting,
    open,
    /// The app called `close`. The close handshake is in progress.
    closing,
    /// The connection closed. The socket connects again after the delay.
    waiting,
    /// The connection closed. No reconnect follows.
    closed,
};

pub const Message = struct {
    kind: Kind,
    /// The bytes stay valid until the next call to `poll` or `deinit`.
    data: []const u8,
};

pub const Closed = struct {
    /// The close code. 1005: the close frame had no code. 1006: no close
    /// frame arrived.
    code: u16,
    cause: Cause,
    /// The delay before the next connection attempt, or null when no
    /// attempt follows.
    retry_in_ms: ?u32,
};

pub const Event = union(enum) {
    /// The connection is open. Each reconnect also gives this event.
    open,
    message: Message,
    closed: Closed,
};

pub const OpenError = error{
    /// The URL is not `ws://` or `wss://`. On the web, a path that starts
    /// with "/" is also correct.
    InvalidUrl,
    /// A native socket needs a `std.Io` (`ctx.io`).
    NoIo,
    OutOfMemory,
};

pub const SendError = error{
    /// Send only after the `open` event, and before `close`.
    NotOpen,
    OutOfMemory,
};

pub const CloseError = error{
    /// The code must be 1000, or 3000 to 4999. The browser accepts only
    /// these codes from a page.
    InvalidCloseCode,
    /// The reason must be UTF-8, 123 bytes or less.
    InvalidReason,
};

pub const Socket = struct {
    allocator: std.mem.Allocator,
    io: if (is_wasm) void else std.Io,
    url: []u8,
    options: Options,
    status: State,
    transport: ?Transport,
    /// The number of failed attempts since the last open connection.
    attempt: u32 = 0,
    retry_at_ms: i64 = 0,
    /// The data of the last message from `poll`.
    held: ?[]u8 = null,

    /// Start a connection. `io` is `ctx.io`: null on the web, required on
    /// native. The socket copies `url`.
    pub fn open(allocator: std.mem.Allocator, io: ?std.Io, url: []const u8, options: Options) OpenError!Socket {
        var self: Socket = .{
            .allocator = allocator,
            .io = if (is_wasm) {} else io orelse return error.NoIo,
            .url = try allocator.dupe(u8, url),
            .options = options,
            .status = .connecting,
            .transport = null,
        };
        errdefer allocator.free(self.url);
        self.transport = try self.startTransport();
        return self;
    }

    /// Stop the connection at once, without a close handshake, and free
    /// the socket. Use `close` first for a clean close.
    pub fn deinit(self: *Socket) void {
        self.releaseHeld();
        if (self.transport) |t| t.release();
        self.allocator.free(self.url);
        self.* = undefined;
    }

    pub fn state(self: *const Socket) State {
        return self.status;
    }

    /// Send a binary message.
    pub fn send(self: *Socket, bytes: []const u8) SendError!void {
        return self.sendKind(.binary, bytes);
    }

    /// Send a text message. `text` must be UTF-8.
    pub fn sendText(self: *Socket, text: []const u8) SendError!void {
        return self.sendKind(.text, text);
    }

    fn sendKind(self: *Socket, kind: Kind, bytes: []const u8) SendError!void {
        if (self.status != .open) return error.NotOpen;
        try self.transport.?.send(kind, bytes);
    }

    /// Start the close handshake. The `closed` event follows, and no
    /// reconnect. In the `waiting` state, the socket closes at once and
    /// `poll` gives no event.
    pub fn close(self: *Socket, code: u16, reason: []const u8) CloseError!void {
        if (!(code == 1000 or (code >= 3000 and code <= 4999))) return error.InvalidCloseCode;
        if (reason.len > frame.max_control_len - 2 or !std.unicode.utf8ValidateSlice(reason)) return error.InvalidReason;
        switch (self.status) {
            .connecting, .open => {
                self.transport.?.close(code, reason);
                self.status = .closing;
            },
            .waiting => self.status = .closed,
            .closing, .closed => {},
        }
    }

    /// The next event, or null. Call it in a loop each tick until it gives
    /// null. Events never arrive by callback (REQ-NET-001).
    pub fn poll(self: *Socket) ?Event {
        self.releaseHeld();
        if (self.transport) |t| {
            const ev = t.next() orelse return null;
            switch (ev) {
                .open => {
                    self.attempt = 0;
                    if (self.status == .connecting) self.status = .open;
                    return .open;
                },
                .message => |m| {
                    self.held = m.data;
                    return .{ .message = .{ .kind = m.kind, .data = m.data } };
                },
                .closed => |c| {
                    t.release();
                    self.transport = null;
                    return .{ .closed = .{ .code = c.code, .cause = c.cause, .retry_in_ms = self.scheduleRetry() } };
                },
            }
        }
        if (self.status == .waiting and self.nowMs() >= self.retry_at_ms) {
            self.status = .connecting;
            self.transport = self.startTransport() catch {
                // No memory for this attempt. Count it as a failed attempt.
                return .{ .closed = .{ .code = frame.abnormal, .cause = .connect_failed, .retry_in_ms = self.scheduleRetry() } };
            };
        }
        return null;
    }

    /// Set the state after a close. Returns the delay of the next attempt.
    fn scheduleRetry(self: *Socket) ?u32 {
        if (self.status != .closing) if (self.options.reconnect) |backoff| {
            if (backoff.delayMs(self.attempt)) |delay| {
                self.attempt += 1;
                self.retry_at_ms = self.nowMs() + delay;
                self.status = .waiting;
                return delay;
            }
        };
        self.status = .closed;
        return null;
    }

    fn startTransport(self: *Socket) error{ InvalidUrl, OutOfMemory }!Transport {
        if (is_wasm) return web.Conn.start(self.allocator, self.url, self.options.max_message_size);
        return native.Conn.start(self.io, self.url, self.options.max_message_size);
    }

    fn releaseHeld(self: *Socket) void {
        if (self.held) |data| {
            // `held` is set only while a transport exists: the closed event
            // comes after the last message.
            if (self.transport) |t| t.freeMessage(data);
            self.held = null;
        }
    }

    fn nowMs(self: *const Socket) i64 {
        if (is_wasm) return @intFromFloat(web.swNetNow());
        return std.Io.Clock.awake.now(self.io).toMilliseconds();
    }
};
