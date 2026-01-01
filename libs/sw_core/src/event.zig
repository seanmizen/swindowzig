const std = @import("std");

/// Modifier keys state
pub const Modifiers = packed struct {
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
    A, B, C, D, E, F, G, H, I, J, K, L, M,
    N, O, P, Q, R, S, T, U, V, W, X, Y, Z,

    // Numbers
    Num0, Num1, Num2, Num3, Num4,
    Num5, Num6, Num7, Num8, Num9,

    // Arrow keys
    Left, Right, Up, Down,

    // Special keys
    Space, Enter, Escape, Tab, Backspace,
    Shift, Ctrl, Alt, Super,

    // Function keys
    F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12,

    Unknown,
};

/// Mouse wheel scroll mode
pub const WheelMode = enum(u8) {
    pixel = 0,
    line = 1,
    page = 2,
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

    text: extern struct {
        utf8: [32]u8,
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
