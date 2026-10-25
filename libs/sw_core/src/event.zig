const std = @import("std");

/// Modifier keys state
pub const Modifiers = packed struct(u8) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
    _padding: u2 = 0,
};

/// Mouse button identifiers
pub const MouseButton = enum(u8) {
    left = 0,
    right = 1,
    middle = 2,
    x1 = 3,
    x2 = 4,
};

/// Keyboard key codes (subset for v0.1)
pub const KeyCode = enum(u16) {
    // Letters
    A,
    B,
    C,
    D,
    E,
    F,
    G,
    H,
    I,
    J,
    K,
    L,
    M,
    N,
    O,
    P,
    Q,
    R,
    S,
    T,
    U,
    V,
    W,
    X,
    Y,
    Z,

    // Numbers
    Num0,
    Num1,
    Num2,
    Num3,
    Num4,
    Num5,
    Num6,
    Num7,
    Num8,
    Num9,

    // Arrow keys
    Left,
    Right,
    Up,
    Down,

    // Special keys
    Space,
    Enter,
    Escape,
    Tab,
    Backspace,
    Shift,
    Ctrl,
    Alt,
    Super,

    // Function keys
    F1,
    F2,
    F3,
    F4,
    F5,
    F6,
    F7,
    F8,
    F9,
    F10,
    F11,
    F12,

    Unknown,
};

/// Mouse wheel scroll mode
pub const WheelMode = enum(u8) {
    pixel = 0,
    line = 1,
    page = 2,
};

/// Game command types dispatched via TAS scripts or a future in-game console.
/// Payload is a fixed-size [4]f32 arg array — meaning depends on the kind:
///   .tp        — args[0..2] = world-space x, y, z
///   .set_spawn — no args (uses current player position)
pub const CommandKind = enum(u8) {
    tp = 0,
    set_spawn = 1,
};

/// Largest text in one `text_input` event, in bytes.
pub const text_input_max = 32;
/// Largest text in one `text_composition` event, in bytes.
pub const text_composition_max = 64;

/// Length of the longest prefix of `utf8` that is at most `max` bytes and ends
/// on a code point boundary. A cut never splits a multi-byte character.
pub fn utf8PrefixLen(utf8: []const u8, max: usize) usize {
    if (utf8.len <= max) return utf8.len;
    var n = max;
    // 0b10xxxxxx is a continuation byte. Step back to the lead byte.
    while (n > 0 and (utf8[n] & 0xC0) == 0x80) n -= 1;
    return n;
}

/// Make a `text_input` payload from `utf8`. Text longer than
/// `text_input_max` is cut on a code point boundary; use `utf8PrefixLen` to
/// send the rest in more events.
pub fn textInputPayload(utf8: []const u8) EventPayload {
    const len = utf8PrefixLen(utf8, text_input_max);
    var buf: [text_input_max]u8 = @splat(0);
    @memcpy(buf[0..len], utf8[0..len]);
    return .{ .text_input = .{ .utf8 = buf, .len = @intCast(len) } };
}

/// Make a `text_composition` payload from `utf8`. The text is cut on a code
/// point boundary at `text_composition_max`. `cursor` and `selection_len` are
/// byte counts and are clamped to the text that stays.
pub fn textCompositionPayload(utf8: []const u8, cursor: usize, selection_len: usize) EventPayload {
    const len = utf8PrefixLen(utf8, text_composition_max);
    var buf: [text_composition_max]u8 = @splat(0);
    @memcpy(buf[0..len], utf8[0..len]);
    const c = @min(cursor, len);
    return .{ .text_composition = .{
        .utf8 = buf,
        .len = @intCast(len),
        .cursor = @intCast(c),
        .selection_len = @intCast(@min(selection_len, len - c)),
    } };
}

/// Byte offset in `utf8` of the code point at index `index`. An index past
/// the end gives `utf8.len`. SDL reports the composition cursor in code points.
pub fn utf8OffsetOfCodePoint(utf8: []const u8, index: usize) usize {
    var offset: usize = 0;
    var seen: usize = 0;
    while (offset < utf8.len and seen < index) {
        offset += std.unicode.utf8ByteSequenceLength(utf8[offset]) catch 1;
        seen += 1;
    }
    return @min(offset, utf8.len);
}

/// Event payloads
pub const EventPayload = union(enum) {
    pointer_move: extern struct {
        x: f32,
        y: f32,
        dx: f32,
        dy: f32,
        device_id: u32,
        mods: Modifiers,
    },

    pointer_button: extern struct {
        button: MouseButton,
        down: bool,
        mods: Modifiers,
    },

    wheel: extern struct {
        dx: f32,
        dy: f32,
        mode: WheelMode,
        mods: Modifiers,
    },

    key: extern struct {
        keycode: KeyCode,
        scancode: u32,
        down: bool,
        repeat: bool,
        mods: Modifiers,
    },

    /// Text the user committed (typed, or accepted from an IME). UTF-8.
    /// Longer text arrives as several events, each split on a code point
    /// boundary. Sent only while text input is on (Context.startTextInput).
    text_input: extern struct {
        utf8: [text_input_max]u8,
        len: u8,
    },

    resize: extern struct {
        width: u32,
        height: u32,
        dpi_scale: f32,
    },

    focus: extern struct {
        focused: bool,
    },

    lifecycle: enum(u8) {
        init,
        paused,
        resumed,
        shutdown,
    },

    tick: extern struct {
        dt_ns: u64,
    },

    command: struct {
        kind: CommandKind,
        args: [4]f32,
    },

    // Keep this last: serialize.zig stores the union tag, and tags 0-9 are
    // fixed in files that exist.
    /// Text that is in composition (an IME or a dead key has not committed
    /// it yet). Each event replaces the one before. `len == 0` means the
    /// composition ended or was cancelled: the committed part arrives as
    /// `text_input`. `cursor` is the caret position, and `selection_len` the
    /// length of the selected part after it. Both count UTF-8 bytes in `utf8`.
    /// Sent only while text input is on.
    text_composition: extern struct {
        utf8: [text_composition_max]u8,
        len: u8,
        cursor: u8,
        selection_len: u8,
    },
};

/// Core event structure
pub const Event = struct {
    tick_id: u64,
    t_ns: u64,
    seq: u32,
    payload: EventPayload,

    pub fn init(tick_id: u64, t_ns: u64, seq: u32, payload: EventPayload) Event {
        return .{
            .tick_id = tick_id,
            .t_ns = t_ns,
            .seq = seq,
            .payload = payload,
        };
    }
};

test "Event creation" {
    const e = Event.init(0, 0, 0, .{
        .lifecycle = .init,
    });
    try std.testing.expectEqual(@as(u64, 0), e.tick_id);
    try std.testing.expectEqual(EventPayload.lifecycle, std.meta.activeTag(e.payload));
}

test "Modifiers packing" {
    const mods = Modifiers{
        .shift = true,
        .ctrl = true,
    };
    try std.testing.expect(mods.shift);
    try std.testing.expect(mods.ctrl);
    try std.testing.expect(!mods.alt);
}

test "textInputPayload encodes UTF-8" {
    const p = textInputPayload("\u{e9}"); // é, 2 bytes
    try std.testing.expectEqual(@as(u8, 2), p.text_input.len);
    try std.testing.expectEqualSlices(u8, "\u{e9}", p.text_input.utf8[0..p.text_input.len]);
}

test "textInputPayload never splits a code point" {
    // 11 x U+20AC (3 bytes) = 33 bytes. The limit is 32, so 10 characters stay.
    var euro: [33]u8 = undefined;
    for (0..11) |i| @memcpy(euro[i * 3 ..][0..3], "\u{20ac}");
    const p = textInputPayload(&euro);
    try std.testing.expectEqual(@as(u8, 30), p.text_input.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(p.text_input.utf8[0..p.text_input.len]));
}

test "utf8PrefixLen returns the whole text when it fits" {
    try std.testing.expectEqual(@as(usize, 5), utf8PrefixLen("hello", 32));
    try std.testing.expectEqual(@as(usize, 3), utf8PrefixLen("hello", 3));
    try std.testing.expectEqual(@as(usize, 0), utf8PrefixLen("\u{1f600}", 3));
    try std.testing.expectEqual(@as(usize, 4), utf8PrefixLen("\u{1f600}x", 4));
}

test "textCompositionPayload keeps cursor and selection" {
    const p = textCompositionPayload("\u{3053}\u{3093}", 3, 3); // こん
    try std.testing.expectEqual(@as(u8, 6), p.text_composition.len);
    try std.testing.expectEqual(@as(u8, 3), p.text_composition.cursor);
    try std.testing.expectEqual(@as(u8, 3), p.text_composition.selection_len);
}

test "textCompositionPayload clamps cursor and selection to the text" {
    const p = textCompositionPayload("ab", 9, 9);
    try std.testing.expectEqual(@as(u8, 2), p.text_composition.cursor);
    try std.testing.expectEqual(@as(u8, 0), p.text_composition.selection_len);
}

test "empty composition marks the end of composition" {
    const p = textCompositionPayload("", 0, 0);
    try std.testing.expectEqual(@as(u8, 0), p.text_composition.len);
}

test "utf8OffsetOfCodePoint converts a code point index to bytes" {
    const text = "a\u{e9}\u{3053}b"; // 1 + 2 + 3 + 1 bytes
    try std.testing.expectEqual(@as(usize, 0), utf8OffsetOfCodePoint(text, 0));
    try std.testing.expectEqual(@as(usize, 1), utf8OffsetOfCodePoint(text, 1));
    try std.testing.expectEqual(@as(usize, 3), utf8OffsetOfCodePoint(text, 2));
    try std.testing.expectEqual(@as(usize, 6), utf8OffsetOfCodePoint(text, 3));
    try std.testing.expectEqual(@as(usize, 7), utf8OffsetOfCodePoint(text, 99));
}
