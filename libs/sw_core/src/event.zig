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

/// Keyboard key codes. A recording stores the integer value of a key code, so
/// a value never changes. Add a new member after the last member only
/// (REQ-INPUT-001).
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

    // Punctuation keys. Each name is the key at that position on a US
    // keyboard. The backends find these keys by position, so each name is
    // correct on every layout (REQ-INPUT-002).
    Grave,
    Minus,
    Equal,
    LeftBracket,
    RightBracket,
    Backslash,
    Semicolon,
    Quote,
    Comma,
    Period,
    Slash,

    // Navigation keys
    Delete,
    Home,
    End,
    PageUp,
    PageDown,
    Insert,
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

/// What a `clipboard` event reports (REQ-PLATFORM-002).
pub const ClipboardEventKind = enum(u8) {
    /// The user pasted: Ctrl+V or Cmd+V while text input is on, or the
    /// Paste command of the browser. Only the web backend sends it. The
    /// text is in `Context.clipboardText()`.
    paste = 0,
    /// A read that `Context.requestClipboardText` started is complete. When
    /// the status is `ok`, the text is in `Context.clipboardText()`.
    read = 1,
    /// A write that `Context.setClipboardText` started is complete.
    write = 2,
};

/// The result of a clipboard operation.
pub const ClipboardStatus = enum(u8) {
    ok = 0,
    /// The platform has no clipboard. On the web: the browser has no
    /// Clipboard API, or the page is not a secure context (https or
    /// localhost).
    unavailable = 1,
    /// The browser refused. The page did not have the focus or a user
    /// gesture, or the user did not give the permission.
    denied = 2,
    /// The clipboard has no text, or the text is larger than the limit.
    no_text = 3,
    /// The operation failed for a different reason.
    failed = 4,
};

/// The payload of a `clipboard` event. The text is not in the event: a
/// paste can be large. `len` is the byte count of the text.
pub const ClipboardEvent = extern struct {
    kind: ClipboardEventKind,
    status: ClipboardStatus,
    len: u32,
};

/// The most gamepads that the engine reads at one time. A gamepad has a slot
/// from 0 to `max_gamepads - 1` while it is connected (REQ-INPUT-005).
pub const max_gamepads = 4;

/// A gamepad button, by its position on the gamepad. `south` is the bottom
/// face button, `east` the right one, and so on. A recording stores the
/// integer value, so a value never changes. Add a new member after the last
/// member only (REQ-INPUT-005).
pub const GamepadButton = enum(u8) {
    south = 0,
    east = 1,
    west = 2,
    north = 3,
    left_shoulder = 4,
    right_shoulder = 5,
    back = 6,
    start = 7,
    guide = 8,
    left_stick = 9,
    right_stick = 10,
    dpad_up = 11,
    dpad_down = 12,
    dpad_left = 13,
    dpad_right = 14,
};

/// A gamepad axis. A stick axis goes from -1 to 1: `x` is positive to the
/// right, and `y` is positive down (as SDL and the web Gamepad API give it).
/// A trigger goes from 0 (released) to 1. The values are raw: no dead zone
/// (REQ-INPUT-005). Add a new member after the last member only.
pub const GamepadAxis = enum(u8) {
    left_x = 0,
    left_y = 1,
    right_x = 2,
    right_y = 3,
    left_trigger = 4,
    right_trigger = 5,
};

/// A gamepad was connected to slot `pad`, or disconnected from it.
pub const GamepadConnectionEvent = extern struct {
    pad: u8,
    connected: bool,
};

/// A gamepad button went down or up.
pub const GamepadButtonEvent = extern struct {
    pad: u8,
    button: GamepadButton,
    down: bool,
};

/// A gamepad axis has a new raw value.
pub const GamepadAxisEvent = extern struct {
    pad: u8,
    axis: GamepadAxis,
    value: f32,
};

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

    /// `dy > 0` scrolls up (away from the user). `dx > 0` scrolls right.
    /// `mode` gives the unit: pixels, lines or pages.
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

    // serialize.zig stores the union tag, and tags 0-10 are fixed in files
    // that exist. Add a new member after the last member only.
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

    /// A clipboard operation is complete (serialize tag 11).
    clipboard: ClipboardEvent,

    /// Gamepad events (serialize tags 12, 13 and 14, REQ-INPUT-005). New
    /// members go after `gamepad_axis`.
    gamepad_connection: GamepadConnectionEvent,
    gamepad_button: GamepadButtonEvent,
    gamepad_axis: GamepadAxisEvent,
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

test "KeyCode values do not change" {
    // A recording stores these values (REQ-INPUT-001).
    try std.testing.expectEqual(@as(u16, 0), @backingInt(KeyCode.A));
    try std.testing.expectEqual(@as(u16, 26), @backingInt(KeyCode.Num0));
    try std.testing.expectEqual(@as(u16, 36), @backingInt(KeyCode.Left));
    try std.testing.expectEqual(@as(u16, 40), @backingInt(KeyCode.Space));
    try std.testing.expectEqual(@as(u16, 48), @backingInt(KeyCode.Super));
    try std.testing.expectEqual(@as(u16, 49), @backingInt(KeyCode.F1));
    try std.testing.expectEqual(@as(u16, 60), @backingInt(KeyCode.F12));
    try std.testing.expectEqual(@as(u16, 61), @backingInt(KeyCode.Unknown));
    try std.testing.expectEqual(@as(u16, 62), @backingInt(KeyCode.Grave));
    try std.testing.expectEqual(@as(u16, 72), @backingInt(KeyCode.Slash));
    try std.testing.expectEqual(@as(u16, 73), @backingInt(KeyCode.Delete));
    try std.testing.expectEqual(@as(u16, 78), @backingInt(KeyCode.Insert));
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

test "the clipboard event has tag 11" {
    // serialize.zig stores the union tag (REQ-PLATFORM-002).
    try std.testing.expectEqual(@as(usize, 11), @backingInt(std.meta.Tag(EventPayload).clipboard));
    try std.testing.expectEqual(@as(usize, 10), @backingInt(std.meta.Tag(EventPayload).text_composition));
}

test "the gamepad events have tags 12, 13 and 14 (REQ-INPUT-005)" {
    const Tag = std.meta.Tag(EventPayload);
    try std.testing.expectEqual(@as(usize, 12), @backingInt(Tag.gamepad_connection));
    try std.testing.expectEqual(@as(usize, 13), @backingInt(Tag.gamepad_button));
    try std.testing.expectEqual(@as(usize, 14), @backingInt(Tag.gamepad_axis));
    // A recording stores these values.
    try std.testing.expectEqual(@as(u8, 0), @backingInt(GamepadButton.south));
    try std.testing.expectEqual(@as(u8, 14), @backingInt(GamepadButton.dpad_right));
    try std.testing.expectEqual(@as(u8, 5), @backingInt(GamepadAxis.right_trigger));
}
