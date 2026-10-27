//! A wasm program for `backends/wasm/websocket.test.ts`. It drives one
//! `sw_net.Socket` through the "sw_net" imports, so the test runs the Zig
//! side and the JS bridge together. `zig build test` also builds it, so the
//! web build of sw_net must compile.
const std = @import("std");
const sw_net = @import("sw_net");

const allocator = std.heap.wasm_allocator;

var socket: ?sw_net.Socket = null;
var last: struct {
    ptr: usize = 0,
    len: usize = 0,
    text: u32 = 0,
    code: u32 = 0,
    cause: u32 = 0,
    retry_ms: i32 = -1,
} = .{};

export fn check_alloc(len: usize) [*]u8 {
    const buf = allocator.alloc(u8, @max(len, 1)) catch @panic("out of memory");
    return buf.ptr;
}

/// 0, or 1 for InvalidUrl, 2 for another error. `reconnect_ms` 0 means no
/// reconnect.
export fn check_open(ptr: [*]const u8, len: usize, reconnect_ms: u32, max_size: usize) u32 {
    const options: sw_net.Options = .{
        .max_message_size = max_size,
        .reconnect = if (reconnect_ms == 0) null else .{ .initial_ms = reconnect_ms, .max_ms = reconnect_ms * 4 },
    };
    socket = sw_net.Socket.open(allocator, null, ptr[0..len], options) catch |err| return switch (err) {
        error.InvalidUrl => 1,
        else => 2,
    };
    return 0;
}

/// 0 for no event, 1 open, 2 message, 3 closed.
export fn check_poll() u32 {
    const ev = socket.?.poll() orelse return 0;
    switch (ev) {
        .open => return 1,
        .message => |m| {
            last.ptr = @intFromPtr(m.data.ptr);
            last.len = m.data.len;
            last.text = @intFromBool(m.kind == .text);
            return 2;
        },
        .closed => |c| {
            last.code = c.code;
            last.cause = @backingInt(c.cause);
            last.retry_ms = if (c.retry_in_ms) |ms| @intCast(ms) else -1;
            return 3;
        },
    }
}

export fn check_msg_ptr() usize {
    return last.ptr;
}
export fn check_msg_len() usize {
    return last.len;
}
export fn check_msg_text() u32 {
    return last.text;
}
export fn check_closed_code() u32 {
    return last.code;
}
export fn check_closed_cause() u32 {
    return last.cause;
}
export fn check_retry_ms() i32 {
    return last.retry_ms;
}

export fn check_state() u32 {
    return @backingInt(socket.?.state());
}

/// 0, or 1 for NotOpen.
export fn check_send(ptr: [*]const u8, len: usize, text: u32) u32 {
    const data = ptr[0..len];
    const result = if (text != 0) socket.?.sendText(data) else socket.?.send(data);
    result catch return 1;
    return 0;
}

/// 0, or 1 for a code or a reason that `close` refuses.
export fn check_close(code: u32, ptr: [*]const u8, len: usize) u32 {
    socket.?.close(@intCast(code), ptr[0..len]) catch return 1;
    return 0;
}

export fn check_deinit() void {
    if (socket) |*s| s.deinit();
    socket = null;
}
