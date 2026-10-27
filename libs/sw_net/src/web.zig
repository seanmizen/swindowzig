//! The web transport: the browser WebSocket, through the wasm import module
//! "sw_net" (`backends/wasm/websocket.ts`). JS keeps the events of each
//! socket in a queue. Zig reads the queue when the game polls, so no JS
//! callback calls game code (REQ-NET-001).
const std = @import("std");
const frame = @import("frame.zig");
const types = @import("types.zig");

// Event kinds of swNetPeek. They match backends/wasm/websocket.ts.
const ev_none = 0;
const ev_open = 1;
const ev_message = 2;
const ev_closed = 3;

/// Open a socket. Returns its id (1 or more). An error comes later as a
/// closed event.
extern "sw_net" fn swNetOpen(url_ptr: [*]const u8, url_len: usize, max_size: usize) u32;
/// Send one message. `text` is 1 for a text message. Returns 0, or -1 when
/// the socket is not open.
extern "sw_net" fn swNetSend(id: u32, ptr: [*]const u8, len: usize, text: u32) i32;
/// The kind of the next event (`ev_*`). For a message, `info` gets the
/// length and 1 for text. For a close, `info` gets the code and the cause
/// (`types.Cause` value).
extern "sw_net" fn swNetPeek(id: u32, info: *[2]u32) u32;
/// Remove the next event. For a message, copy its bytes to `dst` first,
/// when `dst` is not null.
extern "sw_net" fn swNetTake(id: u32, dst: ?[*]u8) void;
extern "sw_net" fn swNetClose(id: u32, code: u32, reason_ptr: [*]const u8, reason_len: usize) void;
/// Close the socket if it is open, and forget it.
extern "sw_net" fn swNetFree(id: u32) void;
/// `performance.now()` in milliseconds.
pub extern "sw_net" fn swNetNow() f64;

pub const StartError = error{ InvalidUrl, OutOfMemory };

pub const Conn = struct {
    id: u32,
    allocator: std.mem.Allocator,

    /// The browser also accepts a path, such as "/api/ws". The bridge then
    /// connects to the host of the page.
    pub fn start(allocator: std.mem.Allocator, url_text: []const u8, max_message_size: usize) StartError!Conn {
        if (!(url_text.len > 0 and url_text[0] == '/')) {
            _ = @import("url.zig").parse(url_text) catch return error.InvalidUrl;
        }
        return .{ .id = swNetOpen(url_text.ptr, url_text.len, max_message_size), .allocator = allocator };
    }

    pub fn send(c: Conn, kind: types.Kind, bytes: []const u8) error{NotOpen}!void {
        if (swNetSend(c.id, bytes.ptr, bytes.len, @intFromBool(kind == .text)) != 0) return error.NotOpen;
    }

    pub fn close(c: Conn, code: u16, reason: []const u8) void {
        swNetClose(c.id, code, reason.ptr, reason.len);
    }

    pub fn next(c: Conn) ?types.TransportEvent {
        var info: [2]u32 = .{ 0, 0 };
        switch (swNetPeek(c.id, &info)) {
            ev_open => {
                swNetTake(c.id, null);
                return .open;
            },
            ev_message => {
                const data = c.allocator.alloc(u8, info[0]) catch {
                    // No memory: the message is lost, the connection stays.
                    swNetTake(c.id, null);
                    return null;
                };
                swNetTake(c.id, data.ptr);
                return .{ .message = .{ .kind = if (info[1] == 1) .text else .binary, .data = data } };
            },
            ev_closed => {
                swNetTake(c.id, null);
                const cause = std.enums.fromInt(types.Cause, info[1]) orelse .connection_lost;
                return .{ .closed = .{ .code = @intCast(info[0]), .cause = cause } };
            },
            else => return null,
        }
    }

    pub fn freeMessage(c: Conn, data: []u8) void {
        c.allocator.free(data);
    }

    pub fn release(c: Conn) void {
        swNetFree(c.id);
    }
};
