//! The clipboard state that each platform backend keeps (REQ-PLATFORM-002).
//!
//! A game reads and writes the clipboard through the Context:
//! `setClipboardText`, `requestClipboardText` and `clipboardText`. Each
//! operation completes later, as a `clipboard` event. Native completes it on
//! the next poll. The web completes it when the browser promise settles. So
//! the game code is the same on each platform, and no call waits.
//!
//! On the web, a paste by the user (Ctrl+V or Cmd+V while text input is on)
//! arrives as a `clipboard` event of kind `paste`. The browser gives the text
//! of a paste with no permission prompt.

const std = @import("std");
const core = @import("sw_core");

/// The largest clipboard text that the platform keeps, in bytes. Longer text
/// is cut on a code point boundary.
pub const max_text_len: usize = 1 << 20;

/// The most results that wait for the next poll. A full queue drops the
/// oldest result.
pub const max_pending = 8;

pub const ClipboardState = struct {
    /// The last clipboard text that the platform knows: from a paste, a
    /// read, or a write by the game.
    text: std.ArrayList(u8) = .empty,
    pending: [max_pending]core.ClipboardEvent = undefined,
    pending_len: usize = 0,

    pub fn deinit(self: *ClipboardState, alloc: std.mem.Allocator) void {
        self.text.deinit(alloc);
    }

    /// The clipboard text, or empty. It stays valid until the next `store`
    /// or `reserve`.
    pub fn slice(self: *const ClipboardState) []const u8 {
        return self.text.items;
    }

    /// Keep `utf8` as the clipboard text. Text longer than `max_text_len` is
    /// cut on a code point boundary.
    pub fn store(self: *ClipboardState, alloc: std.mem.Allocator, utf8: []const u8) error{OutOfMemory}!void {
        const n = core.event.utf8PrefixLen(utf8, max_text_len);
        self.text.clearRetainingCapacity();
        try self.text.appendSlice(alloc, utf8[0..n]);
    }

    /// Make the text `len` bytes long, for a platform that writes the bytes
    /// in place (the web). Returns null when `len` is larger than
    /// `max_text_len`, or when there is no memory. Then the text is empty.
    pub fn reserve(self: *ClipboardState, alloc: std.mem.Allocator, len: usize) ?[]u8 {
        self.text.clearRetainingCapacity();
        if (len > max_text_len) return null;
        self.text.resize(alloc, len) catch return null;
        return self.text.items;
    }

    /// Cut the text to `len` bytes, on a code point boundary. The web uses
    /// it after it writes fewer bytes than it reserved.
    pub fn truncate(self: *ClipboardState, len: usize) void {
        if (len >= self.text.items.len) return;
        self.text.items.len = core.event.utf8PrefixLen(self.text.items, len);
    }

    /// Keep a result for the next `flush`.
    pub fn queue(self: *ClipboardState, ev: core.ClipboardEvent) void {
        if (self.pending_len == max_pending) {
            std.mem.copyForwards(core.ClipboardEvent, self.pending[0 .. max_pending - 1], self.pending[1..max_pending]);
            self.pending_len -= 1;
        }
        self.pending[self.pending_len] = ev;
        self.pending_len += 1;
    }

    /// Push each waiting result to the bus as a `clipboard` event, in order.
    pub fn flush(self: *ClipboardState, bus: *core.Bus, t_ns: u64) !void {
        defer self.pending_len = 0;
        for (self.pending[0..self.pending_len]) |ev| {
            try bus.push(0, t_ns, .{ .clipboard = ev });
        }
    }
};

/// The event of a completed write.
pub fn writeResult(status: core.ClipboardStatus) core.ClipboardEvent {
    return .{ .kind = .write, .status = status, .len = 0 };
}

/// The event of a completed read of `len` bytes.
pub fn readResult(status: core.ClipboardStatus, len: usize) core.ClipboardEvent {
    return .{ .kind = .read, .status = status, .len = @intCast(len) };
}

test "store keeps the text and cuts it on a code point boundary" {
    const alloc = std.testing.allocator;
    var state: ClipboardState = .{};
    defer state.deinit(alloc);
    try state.store(alloc, "hello");
    try std.testing.expectEqualStrings("hello", state.slice());
    try state.store(alloc, "\u{e9}");
    try std.testing.expectEqualStrings("\u{e9}", state.slice());

    // max_text_len - 1 ASCII bytes, then a 2-byte character: the character
    // does not fit, so it goes.
    const big = try alloc.alloc(u8, max_text_len + 1);
    defer alloc.free(big);
    @memset(big, 'a');
    big[max_text_len - 1] = 0xC3;
    big[max_text_len] = 0xA9;
    try state.store(alloc, big);
    try std.testing.expectEqual(max_text_len - 1, state.slice().len);
}

test "reserve refuses text over the limit" {
    const alloc = std.testing.allocator;
    var state: ClipboardState = .{};
    defer state.deinit(alloc);
    const buf = state.reserve(alloc, 4).?;
    @memcpy(buf, "abcd");
    try std.testing.expectEqualStrings("abcd", state.slice());
    try std.testing.expect(state.reserve(alloc, max_text_len + 1) == null);
    try std.testing.expectEqualStrings("", state.slice());
}

test "truncate does not split a code point" {
    const alloc = std.testing.allocator;
    var state: ClipboardState = .{};
    defer state.deinit(alloc);
    try state.store(alloc, "a\u{e9}b");
    state.truncate(2);
    try std.testing.expectEqualStrings("a", state.slice());
}

test "a result arrives as a clipboard event on the next flush (REQ-PLATFORM-002)" {
    const alloc = std.testing.allocator;
    var bus = core.Bus.init(alloc);
    defer bus.deinit();
    var state: ClipboardState = .{};
    defer state.deinit(alloc);

    state.queue(writeResult(.ok));
    state.queue(readResult(.denied, 0));
    try std.testing.expectEqual(@as(usize, 0), bus.events.items.len);
    try state.flush(&bus, 0);
    try std.testing.expectEqual(@as(usize, 2), bus.events.items.len);
    const first = bus.events.items[0].payload.clipboard;
    try std.testing.expectEqual(core.ClipboardEventKind.write, first.kind);
    const second = bus.events.items[1].payload.clipboard;
    try std.testing.expectEqual(core.ClipboardEventKind.read, second.kind);
    try std.testing.expectEqual(core.ClipboardStatus.denied, second.status);

    // The queue is empty after a flush.
    try state.flush(&bus, 0);
    try std.testing.expectEqual(@as(usize, 2), bus.events.items.len);
}

test "a full queue drops the oldest result" {
    var state: ClipboardState = .{};
    for (0..max_pending + 1) |i| state.queue(readResult(.ok, i));
    try std.testing.expectEqual(@as(usize, max_pending), state.pending_len);
    try std.testing.expectEqual(@as(u32, 1), state.pending[0].len);
    try std.testing.expectEqual(@as(u32, max_pending), state.pending[max_pending - 1].len);
}
