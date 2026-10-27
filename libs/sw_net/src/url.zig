//! WebSocket URL parsing: `ws://host[:port][/path][?query]` and `wss://`.
//! The native client reads the URL with this file. The web client gives the
//! URL to the browser, which also accepts a path such as "/api/ws".
const std = @import("std");

pub const ParseError = error{InvalidUrl};

pub const Url = struct {
    /// True for `wss:` (TLS).
    secure: bool,
    /// The host name or IP address, without the brackets of an IPv6 address.
    host: []const u8,
    port: u16,
    /// The path and the query, for the request line. It starts with "/".
    resource: []const u8,
    /// The value of the HTTP Host header: the host as written in the URL,
    /// and the port when the URL gives one.
    host_header: []const u8,
};

/// Parse a `ws:` or `wss:` URL. The slices in the result point into `text`.
/// A fragment (`#`), user information (`@`) or an empty host is an error.
pub fn parse(text: []const u8) ParseError!Url {
    var secure = false;
    var rest: []const u8 = undefined;
    if (std.ascii.startsWithIgnoreCase(text, "ws://")) {
        rest = text["ws://".len..];
    } else if (std.ascii.startsWithIgnoreCase(text, "wss://")) {
        secure = true;
        rest = text["wss://".len..];
    } else return error.InvalidUrl;
    if (std.mem.indexOfScalar(u8, rest, '#') != null) return error.InvalidUrl;

    const authority_end = std.mem.indexOfAny(u8, rest, "/?") orelse rest.len;
    const authority = rest[0..authority_end];
    const resource: []const u8 = if (authority_end == rest.len)
        "/"
    else if (rest[authority_end] == '?')
        // "ws://host?x" has an empty path. The request line needs "/?x", but
        // the result must point into `text`, so this case is not supported.
        return error.InvalidUrl
    else
        rest[authority_end..];
    if (authority.len == 0) return error.InvalidUrl;
    if (std.mem.indexOfScalar(u8, authority, '@') != null) return error.InvalidUrl;
    for (resource) |c| if (c <= ' ' or c == 0x7f) return error.InvalidUrl;

    var host: []const u8 = undefined;
    var port_text: ?[]const u8 = null;
    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return error.InvalidUrl;
        host = authority[1..close];
        const after = authority[close + 1 ..];
        if (after.len > 0) {
            if (after[0] != ':') return error.InvalidUrl;
            port_text = after[1..];
        }
    } else if (std.mem.indexOfScalar(u8, authority, ':')) |colon| {
        host = authority[0..colon];
        port_text = authority[colon + 1 ..];
    } else {
        host = authority;
    }
    if (host.len == 0) return error.InvalidUrl;
    for (host) |c| if (c <= ' ' or c == 0x7f) return error.InvalidUrl;

    const port: u16 = if (port_text) |p|
        std.fmt.parseInt(u16, p, 10) catch return error.InvalidUrl
    else if (secure) 443 else 80;
    if (port == 0) return error.InvalidUrl;

    return .{
        .secure = secure,
        .host = host,
        .port = port,
        .resource = resource,
        .host_header = authority,
    };
}

test "url: ws with defaults" {
    const u = try parse("ws://example.com");
    try std.testing.expect(!u.secure);
    try std.testing.expectEqualStrings("example.com", u.host);
    try std.testing.expectEqual(@as(u16, 80), u.port);
    try std.testing.expectEqualStrings("/", u.resource);
    try std.testing.expectEqualStrings("example.com", u.host_header);
}

test "url: wss with port, path and query" {
    const u = try parse("wss://example.com:8443/api/ws?room=2");
    try std.testing.expect(u.secure);
    try std.testing.expectEqualStrings("example.com", u.host);
    try std.testing.expectEqual(@as(u16, 8443), u.port);
    try std.testing.expectEqualStrings("/api/ws?room=2", u.resource);
    try std.testing.expectEqualStrings("example.com:8443", u.host_header);
    try std.testing.expectEqual(@as(u16, 443), (try parse("WSS://a")).port);
}

test "url: IPv6 literal" {
    const u = try parse("ws://[::1]:9000/x");
    try std.testing.expectEqualStrings("::1", u.host);
    try std.testing.expectEqual(@as(u16, 9000), u.port);
    try std.testing.expectEqualStrings("[::1]:9000", u.host_header);
}

test "url: bad URLs" {
    const bad = [_][]const u8{
        "http://example.com",
        "/api/ws",
        "ws://",
        "ws://:80/",
        "ws://host:0/",
        "ws://host:99999/",
        "ws://host:x/",
        "ws://user@host/",
        "ws://host/#frag",
        "ws://host/a b",
        "ws://[::1/",
        "ws://host?x",
    };
    for (bad) |text| try std.testing.expectError(error.InvalidUrl, parse(text));
}
