const std = @import("std");
const event = @import("event.zig");
const Event = event.Event;
const KeyCode = event.KeyCode;
const MouseButton = event.MouseButton;
const Modifiers = event.Modifiers;

/// Mouse state snapshot
pub const MouseState = struct {
    x: f32 = 0,
    y: f32 = 0,
    delta_x: f32 = 0,
    delta_y: f32 = 0,
    buttons: std.bit_set.IntegerBitSet(5) = .empty,
    pressed: std.bit_set.IntegerBitSet(5) = .empty,
    released: std.bit_set.IntegerBitSet(5) = .empty,

    pub fn isButtonDown(self: *const MouseState, button: MouseButton) bool {
        return self.buttons.isSet(@intFromEnum(button));
    }

    pub fn isButtonPressed(self: *const MouseState, button: MouseButton) bool {
        return self.pressed.isSet(@intFromEnum(button));
    }

    pub fn isButtonReleased(self: *const MouseState, button: MouseButton) bool {
        return self.released.isSet(@intFromEnum(button));
    }
};

/// Wheel state snapshot
pub const WheelState = struct {
    delta_x: f32 = 0,
    delta_y: f32 = 0,
};

/// Keyboard state snapshot
pub const KeyboardState = struct {
    down: std.bit_set.IntegerBitSet(256) = .empty,
    pressed: std.bit_set.IntegerBitSet(256) = .empty,
    released: std.bit_set.IntegerBitSet(256) = .empty,

    pub fn isKeyDown(self: *const KeyboardState, key: KeyCode) bool {
        const code = @intFromEnum(key);
        return code < 256 and self.down.isSet(code);
    }

    pub fn isKeyPressed(self: *const KeyboardState, key: KeyCode) bool {
        const code = @intFromEnum(key);
        return code < 256 and self.pressed.isSet(code);
    }

    pub fn isKeyReleased(self: *const KeyboardState, key: KeyCode) bool {
        const code = @intFromEnum(key);
        return code < 256 and self.released.isSet(code);
    }
};

/// Committed text of this tick (UTF-8)
pub const TextBuffer = struct {
    buffer: [256]u8 = undefined,
    len: usize = 0,

    pub fn append(self: *TextBuffer, utf8: []const u8) void {
        const available = self.buffer.len - self.len;
        const to_copy = @min(utf8.len, available);
        @memcpy(self.buffer[self.len..][0..to_copy], utf8[0..to_copy]);
        self.len += to_copy;
    }

    pub fn text(self: *const TextBuffer) []const u8 {
        return self.buffer[0..self.len];
    }

    pub fn clear(self: *TextBuffer) void {
        self.len = 0;
    }
};

/// Text that an IME or a dead key has not committed yet.
pub const Composition = struct {
    buffer: [event.text_composition_max]u8 = undefined,
    len: usize = 0,
    /// Caret position and length of the selection after it, in UTF-8 bytes.
    cursor: usize = 0,
    selection_len: usize = 0,

    pub fn text(self: *const Composition) []const u8 {
        return self.buffer[0..self.len];
    }
};

/// Ergonomic input state snapshot computed each tick from raw events.
/// Provides .keyDown(), .keyPressed(), .buttonDown(), mouse position, etc.
pub const InputSnapshot = struct {
    mouse: MouseState = .{},
    wheel: WheelState = .{},
    keyboard: KeyboardState = .{},
    mods: Modifiers = .{},
    text: TextBuffer = .{},
    /// Text in composition now, or empty. Replaced by each `text_composition`
    /// event, and not cleared per tick: it stays until the composition ends.
    composition: Composition = .{},

    pub fn init() InputSnapshot {
        return .{};
    }

    /// Update snapshot from events for a tick (called internally by swindowzig).
    pub fn updateFromEvents(self: *InputSnapshot, events: []const Event) void {
        // Clear per-frame state
        self.keyboard.pressed = .empty;
        self.keyboard.released = .empty;
        self.mouse.pressed = .empty;
        self.mouse.released = .empty;
        self.mouse.delta_x = 0;
        self.mouse.delta_y = 0;
        self.wheel.delta_x = 0;
        self.wheel.delta_y = 0;
        self.text.clear();

        for (events) |e| {
            switch (e.payload) {
                .pointer_move => |p| {
                    self.mouse.x = p.x;
                    self.mouse.y = p.y;
                    self.mouse.delta_x += p.dx;
                    self.mouse.delta_y += p.dy;
                    self.mods = p.mods;
                },

                .pointer_button => |p| {
                    const button_idx = @intFromEnum(p.button);
                    if (p.down) {
                        if (!self.mouse.buttons.isSet(button_idx)) {
                            self.mouse.pressed.set(button_idx);
                        }
                        self.mouse.buttons.set(button_idx);
                    } else {
                        self.mouse.buttons.unset(button_idx);
                        self.mouse.released.set(button_idx);
                    }
                    self.mods = p.mods;
                },

                .wheel => |w| {
                    self.wheel.delta_x += w.dx;
                    self.wheel.delta_y += w.dy;
                    self.mods = w.mods;
                },

                .key => |k| {
                    const code = @intFromEnum(k.keycode);
                    if (code < 256) {
                        if (k.down) {
                            if (!self.keyboard.down.isSet(code)) {
                                self.keyboard.pressed.set(code);
                            }
                            self.keyboard.down.set(code);
                        } else {
                            self.keyboard.down.unset(code);
                            self.keyboard.released.set(code);
                        }
                    }
                    self.mods = k.mods;
                },

                .text_input => |t| {
                    self.text.append(t.utf8[0..t.len]);
                },

                .text_composition => |c| {
                    @memcpy(self.composition.buffer[0..c.len], c.utf8[0..c.len]);
                    self.composition.len = c.len;
                    self.composition.cursor = c.cursor;
                    self.composition.selection_len = c.selection_len;
                },

                else => {},
            }
        }
    }

    /// Is this key currently held down?
    pub fn keyDown(self: *const InputSnapshot, key: KeyCode) bool {
        return self.keyboard.isKeyDown(key);
    }

    /// Was this key just pressed this tick? (goes from up to down)
    pub fn keyPressed(self: *const InputSnapshot, key: KeyCode) bool {
        return self.keyboard.isKeyPressed(key);
    }

    /// Was this key just released this tick? (goes from down to up)
    pub fn keyReleased(self: *const InputSnapshot, key: KeyCode) bool {
        return self.keyboard.isKeyReleased(key);
    }

    /// Is this mouse button currently held down?
    pub fn buttonDown(self: *const InputSnapshot, button: MouseButton) bool {
        return self.mouse.isButtonDown(button);
    }

    /// Was this mouse button just pressed this tick? (goes from up to down)
    pub fn buttonPressed(self: *const InputSnapshot, button: MouseButton) bool {
        return self.mouse.isButtonPressed(button);
    }

    /// Was this mouse button just released this tick? (goes from down to up)
    pub fn buttonReleased(self: *const InputSnapshot, button: MouseButton) bool {
        return self.mouse.isButtonReleased(button);
    }
};

test "InputSnapshot key events" {
    var snapshot = InputSnapshot.init();

    const events = [_]Event{
        Event.init(0, 0, 0, .{
            .key = .{
                .keycode = .Space,
                .scancode = 57,
                .down = true,
                .repeat = false,
                .mods = .{},
            },
        }),
    };

    snapshot.updateFromEvents(&events);

    try std.testing.expect(snapshot.keyDown(.Space));
    try std.testing.expect(snapshot.keyPressed(.Space));
    try std.testing.expect(!snapshot.keyReleased(.Space));
}

test "InputSnapshot mouse events" {
    var snapshot = InputSnapshot.init();

    const events = [_]Event{
        Event.init(0, 0, 0, .{
            .pointer_move = .{
                .x = 100,
                .y = 200,
                .dx = 10,
                .dy = 20,
                .device_id = 0,
                .mods = .{},
            },
        }),
        Event.init(0, 0, 1, .{
            .pointer_button = .{
                .button = .left,
                .down = true,
                .mods = .{},
            },
        }),
    };

    snapshot.updateFromEvents(&events);

    try std.testing.expectEqual(@as(f32, 100), snapshot.mouse.x);
    try std.testing.expectEqual(@as(f32, 200), snapshot.mouse.y);
    try std.testing.expect(snapshot.buttonDown(.left));
}

test "InputSnapshot text events" {
    var snapshot = InputSnapshot.init();

    snapshot.updateFromEvents(&[_]Event{
        Event.init(0, 0, 0, event.textCompositionPayload("e\u{301}", 1, 0)),
    });
    try std.testing.expectEqualStrings("e\u{301}", snapshot.composition.text());
    try std.testing.expectEqual(@as(usize, 1), snapshot.composition.cursor);
    try std.testing.expectEqual(@as(usize, 0), snapshot.text.text().len);

    // Commit: the composition ends and the text arrives.
    snapshot.updateFromEvents(&[_]Event{
        Event.init(1, 0, 0, event.textCompositionPayload("", 0, 0)),
        Event.init(1, 0, 1, event.textInputPayload("\u{e9}")),
    });
    try std.testing.expectEqual(@as(usize, 0), snapshot.composition.text().len);
    try std.testing.expectEqualStrings("\u{e9}", snapshot.text.text());

    // The committed text is per tick. It does not carry over.
    snapshot.updateFromEvents(&[_]Event{});
    try std.testing.expectEqual(@as(usize, 0), snapshot.text.text().len);
}
