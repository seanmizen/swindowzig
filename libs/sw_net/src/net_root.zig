//! sw_net: a WebSocket client for games, on the web and on native.
//!
//! ```zig
//! var sock = try sw_net.Socket.open(allocator, ctx.io, "wss://example.com/api/ws", .{
//!     .reconnect = .{}, // optional: connect again after a drop
//! });
//! defer sock.deinit();
//! // Each tick:
//! while (sock.poll()) |ev| switch (ev) {
//!     .open => try sock.send(hello_bytes),
//!     .message => |m| handle(m.data), // valid until the next poll
//!     .closed => |c| log(c.code, c.cause, c.retry_in_ms),
//! };
//! ```
//!
//! Web: the browser WebSocket (`backends/wasm/websocket.ts`). Native: an
//! RFC 6455 client on `std.Io`, with TLS from `std.crypto.tls` for `wss:`.
//! The game reads events with `poll`. No callback calls game code
//! (REQ-NET-001).
const socket = @import("socket.zig");

pub const Socket = socket.Socket;
pub const Options = socket.Options;
pub const Backoff = socket.Backoff;
pub const State = socket.State;
pub const Event = socket.Event;
pub const Message = socket.Message;
pub const Closed = socket.Closed;
pub const Kind = socket.Kind;
pub const Cause = socket.Cause;
pub const OpenError = socket.OpenError;
pub const SendError = socket.SendError;
pub const CloseError = socket.CloseError;

/// The frame codec and the URL parser, for a test server or a tool.
pub const frame = @import("frame.zig");
pub const url = @import("url.zig");
pub const handshake = @import("handshake.zig");

test {
    _ = @import("url.zig");
    _ = @import("frame.zig");
    _ = @import("handshake.zig");
    _ = @import("backoff.zig");
    _ = @import("socket_test.zig");
}
