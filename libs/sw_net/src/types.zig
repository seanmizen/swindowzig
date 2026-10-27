//! Types that the socket and both transports share.
const frame = @import("frame.zig");

pub const Kind = frame.Kind;

/// Why a connection closed.
pub const Cause = enum {
    /// A close handshake: the server sent a close frame, or the app called
    /// `close`.
    closed,
    /// No connection: the DNS lookup, the TCP connect or the TLS handshake
    /// failed.
    connect_failed,
    /// The server answered, but did not accept the WebSocket upgrade.
    handshake_failed,
    /// The connection stopped without a close frame.
    connection_lost,
    /// The server broke the protocol, or sent a message larger than
    /// `Options.max_message_size`. The client sent close code 1002, 1007
    /// or 1009.
    protocol_error,
};

pub const Closed = struct {
    /// The close code. 1005 means that the close frame had no code. 1006
    /// means that no close frame arrived.
    code: u16,
    cause: Cause,
};

/// An event from a transport to the socket.
pub const TransportEvent = union(enum) {
    open,
    /// The data belongs to the transport. Give it back with `freeMessage`.
    message: frame.Message,
    closed: Closed,
};
