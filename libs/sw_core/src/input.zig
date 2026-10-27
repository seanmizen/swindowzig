const std = @import("std");
const event = @import("event.zig");
const Event = event.Event;
const KeyCode = event.KeyCode;
const MouseButton = event.MouseButton;
const Modifiers = event.Modifiers;
const GamepadButton = event.GamepadButton;
const GamepadAxis = event.GamepadAxis;

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
        return self.buttons.isSet(@backingInt(button));
    }

    pub fn isButtonPressed(self: *const MouseState, button: MouseButton) bool {
        return self.pressed.isSet(@backingInt(button));
    }

    pub fn isButtonReleased(self: *const MouseState, button: MouseButton) bool {
        return self.released.isSet(@backingInt(button));
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
        const code = @backingInt(key);
        return code < 256 and self.down.isSet(code);
    }

    pub fn isKeyPressed(self: *const KeyboardState, key: KeyCode) bool {
        const code = @backingInt(key);
        return code < 256 and self.pressed.isSet(code);
    }

    pub fn isKeyReleased(self: *const KeyboardState, key: KeyCode) bool {
        const code = @backingInt(key);
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

/// The number of members of `GamepadButton` and `GamepadAxis`.
pub const gamepad_button_count = std.enums.values(GamepadButton).len;
pub const gamepad_axis_count = std.enums.values(GamepadAxis).len;

/// The dead zones of the gamepad sticks and triggers (REQ-INPUT-005). The
/// snapshot keeps the raw values. The game applies the settings when it
/// reads them, so a replay with the same settings gives the same values.
pub const GamepadSettings = struct {
    /// A stick is at the centre while its distance from the centre is at
    /// this value or less. The engine scales the rest of the travel to 0 to 1.
    stick_dead_zone: f32 = 0.15,
    /// A trigger is released while its value is at this value or less.
    trigger_dead_zone: f32 = 0.05,

    pub const max_dead_zone: f32 = 0.95;

    /// Set the stick dead zone, clamped to 0 to `max_dead_zone`. A value
    /// that is not a number does not change the setting.
    pub fn setStickDeadZone(self: *GamepadSettings, v: f32) void {
        if (std.math.isNan(v)) return;
        self.stick_dead_zone = std.math.clamp(v, 0, max_dead_zone);
    }

    /// Set the trigger dead zone, clamped to 0 to `max_dead_zone`. A value
    /// that is not a number does not change the setting.
    pub fn setTriggerDeadZone(self: *GamepadSettings, v: f32) void {
        if (std.math.isNan(v)) return;
        self.trigger_dead_zone = std.math.clamp(v, 0, max_dead_zone);
    }
};

/// A stick position after the dead zone.
pub const Stick = struct {
    x: f32 = 0,
    y: f32 = 0,
};

pub const StickSide = enum { left, right };

/// A radial dead zone. Inside `dead_zone`, the stick is at the centre.
/// Outside it, this function scales the distance from the dead zone to the
/// edge to 0 to 1, and keeps the direction. Thus a diagonal keeps its full
/// length, and the first movement after the dead zone is small. A distance
/// of more than 1 (a worn stick) gives 1.
pub fn radialDeadZone(x: f32, y: f32, dead_zone: f32) Stick {
    const len = @sqrt(x * x + y * y);
    if (!std.math.isFinite(len) or len <= dead_zone or len == 0) return .{};
    const scaled = @min((len - dead_zone) / (1 - dead_zone), 1);
    return .{ .x = x / len * scaled, .y = y / len * scaled };
}

/// A trigger value after the dead zone: 0 to 1.
pub fn triggerDeadZone(v: f32, dead_zone: f32) f32 {
    if (!std.math.isFinite(v) or v <= dead_zone) return 0;
    return @min((v - dead_zone) / (1 - dead_zone), 1);
}

/// The slot that `InputSnapshot.gamepad` gives for a slot number that is
/// too large.
const no_gamepad: GamepadState = .{};

/// The state of one gamepad slot in a tick (REQ-INPUT-005).
pub const GamepadState = struct {
    connected: bool = false,
    buttons: std.bit_set.IntegerBitSet(gamepad_button_count) = .empty,
    pressed: std.bit_set.IntegerBitSet(gamepad_button_count) = .empty,
    released: std.bit_set.IntegerBitSet(gamepad_button_count) = .empty,
    /// The raw axis values, by `GamepadAxis`: no dead zone.
    axes: [gamepad_axis_count]f32 = @splat(0),
    /// The raw axis values at the end of the previous tick.
    prev_axes: [gamepad_axis_count]f32 = @splat(0),

    pub fn buttonDown(self: *const GamepadState, b: GamepadButton) bool {
        return self.buttons.isSet(@backingInt(b));
    }

    pub fn buttonPressed(self: *const GamepadState, b: GamepadButton) bool {
        return self.pressed.isSet(@backingInt(b));
    }

    pub fn buttonReleased(self: *const GamepadState, b: GamepadButton) bool {
        return self.released.isSet(@backingInt(b));
    }

    /// The raw value of an axis: no dead zone.
    pub fn rawAxis(self: *const GamepadState, a: GamepadAxis) f32 {
        return self.axes[@backingInt(a)];
    }

    /// A stick, with the radial stick dead zone of `settings`.
    pub fn stick(self: *const GamepadState, side: StickSide, settings: GamepadSettings) Stick {
        return stickOf(&self.axes, side, settings);
    }

    /// A trigger, from 0 to 1, with the trigger dead zone of `settings`.
    pub fn trigger(self: *const GamepadState, side: StickSide, settings: GamepadSettings) f32 {
        const a: GamepadAxis = if (side == .left) .left_trigger else .right_trigger;
        return triggerDeadZone(self.axes[@backingInt(a)], settings.trigger_dead_zone);
    }

    /// The value of an axis in one direction, from 0 to 1, after the dead
    /// zone. A trigger has only the positive direction.
    pub fn axisValue(self: *const GamepadState, a: GamepadAxis, positive: bool, settings: GamepadSettings) f32 {
        return directionValue(&self.axes, a, positive, settings);
    }

    /// `axisValue` at the end of the previous tick.
    pub fn prevAxisValue(self: *const GamepadState, a: GamepadAxis, positive: bool, settings: GamepadSettings) f32 {
        return directionValue(&self.prev_axes, a, positive, settings);
    }

    fn stickOf(axes: *const [gamepad_axis_count]f32, side: StickSide, settings: GamepadSettings) Stick {
        const xa: GamepadAxis, const ya: GamepadAxis = if (side == .left) .{ .left_x, .left_y } else .{ .right_x, .right_y };
        return radialDeadZone(axes[@backingInt(xa)], axes[@backingInt(ya)], settings.stick_dead_zone);
    }

    fn directionValue(axes: *const [gamepad_axis_count]f32, a: GamepadAxis, positive: bool, settings: GamepadSettings) f32 {
        const v: f32 = switch (a) {
            .left_x => stickOf(axes, .left, settings).x,
            .left_y => stickOf(axes, .left, settings).y,
            .right_x => stickOf(axes, .right, settings).x,
            .right_y => stickOf(axes, .right, settings).y,
            .left_trigger, .right_trigger => triggerDeadZone(axes[@backingInt(a)], settings.trigger_dead_zone),
        };
        return @max(0, if (positive) v else -v);
    }
};

/// Ergonomic input state snapshot computed each tick from raw events.
/// Provides .keyDown(), .keyPressed(), .buttonDown(), mouse position, etc.
pub const InputSnapshot = struct {
    mouse: MouseState = .{},
    wheel: WheelState = .{},
    keyboard: KeyboardState = .{},
    /// The modifiers of this tick. When a key goes down in this tick, they
    /// are the modifiers of that key press (the last one). So a short
    /// Shift+Tab, with each key up in the same tick, keeps its Shift
    /// (REQ-INPUT-007).
    mods: Modifiers = .{},
    /// The modifiers after the last event. The next tick starts from them.
    live_mods: Modifiers = .{},
    text: TextBuffer = .{},
    /// Text in composition now, or empty. Replaced by each `text_composition`
    /// event, and not cleared per tick: it stays until the composition ends.
    composition: Composition = .{},
    /// The last `clipboard` event of this tick, or null. The text of a paste
    /// or a read is in `Context.clipboardText()` (REQ-PLATFORM-002).
    clipboard: ?event.ClipboardEvent = null,
    /// The gamepads, by slot (REQ-INPUT-005). A button or axis event also
    /// marks its slot as connected, so a replay that starts after the
    /// connection event still works.
    gamepads: [event.max_gamepads]GamepadState = @splat(.{}),

    pub fn init() InputSnapshot {
        return .{};
    }

    /// Update snapshot from events for a tick (called internally by swindowzig).
    pub fn updateFromEvents(self: *InputSnapshot, events: []const Event) void {
        // Clear per-frame state
        self.mods = self.live_mods;
        var press_mods: ?Modifiers = null;
        self.keyboard.pressed = .empty;
        self.keyboard.released = .empty;
        self.mouse.pressed = .empty;
        self.mouse.released = .empty;
        self.mouse.delta_x = 0;
        self.mouse.delta_y = 0;
        self.wheel.delta_x = 0;
        self.wheel.delta_y = 0;
        self.text.clear();
        self.clipboard = null;
        for (&self.gamepads) |*g| {
            g.pressed = .empty;
            g.released = .empty;
            g.prev_axes = g.axes;
        }

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
                    const button_idx = @backingInt(p.button);
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
                    const code = @backingInt(k.keycode);
                    if (code < 256) {
                        if (k.down) {
                            if (!self.keyboard.down.isSet(code)) {
                                self.keyboard.pressed.set(code);
                                press_mods = k.mods;
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

                .clipboard => |c| self.clipboard = c,

                .gamepad_connection => |c| {
                    if (c.pad >= event.max_gamepads) continue;
                    const g = &self.gamepads[c.pad];
                    if (c.connected) {
                        g.connected = true;
                    } else {
                        // Each button that was down goes up, and the axes go
                        // to the centre.
                        g.released.setUnion(g.buttons);
                        g.buttons = .empty;
                        g.axes = @splat(0);
                        g.connected = false;
                    }
                },

                .gamepad_button => |b| {
                    if (b.pad >= event.max_gamepads) continue;
                    const g = &self.gamepads[b.pad];
                    g.connected = true;
                    const i = @backingInt(b.button);
                    if (b.down) {
                        if (!g.buttons.isSet(i)) g.pressed.set(i);
                        g.buttons.set(i);
                    } else {
                        if (g.buttons.isSet(i)) g.released.set(i);
                        g.buttons.unset(i);
                    }
                },

                .gamepad_axis => |a| {
                    if (a.pad >= event.max_gamepads) continue;
                    const g = &self.gamepads[a.pad];
                    g.connected = true;
                    const v = if (std.math.isFinite(a.value)) a.value else 0;
                    const lo: f32 = switch (a.axis) {
                        .left_trigger, .right_trigger => 0,
                        else => -1,
                    };
                    g.axes[@backingInt(a.axis)] = std.math.clamp(v, lo, 1);
                },

                else => {},
            }
        }
        self.live_mods = self.mods;
        if (press_mods) |m| self.mods = m;
    }

    /// Is this key held down in this tick? A key that goes down and up in
    /// the same tick is down for that tick, so a short press is not lost
    /// (REQ-INPUT-007).
    pub fn keyDown(self: *const InputSnapshot, key: KeyCode) bool {
        return self.keyboard.isKeyDown(key) or self.keyboard.isKeyPressed(key);
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

    /// The gamepad in slot `pad`. A slot past `max_gamepads` gives a gamepad
    /// that is not connected.
    pub fn gamepad(self: *const InputSnapshot, pad: usize) *const GamepadState {
        return if (pad < self.gamepads.len) &self.gamepads[pad] else &no_gamepad;
    }

    /// True when a gamepad is connected.
    pub fn anyGamepad(self: *const InputSnapshot) bool {
        for (&self.gamepads) |*g| if (g.connected) return true;
        return false;
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

fn keyEvent(key: KeyCode, down: bool, mods: Modifiers) Event {
    return Event.init(0, 0, 0, .{ .key = .{ .keycode = key, .scancode = 0, .down = down, .repeat = false, .mods = mods } });
}

test "InputSnapshot keeps a key press shorter than one tick (REQ-INPUT-007)" {
    var snapshot = InputSnapshot.init();
    // Shift+Tab: all four events arrive in one tick.
    snapshot.updateFromEvents(&.{
        keyEvent(.Shift, true, .{ .shift = true }),
        keyEvent(.Tab, true, .{ .shift = true }),
        keyEvent(.Tab, false, .{ .shift = true }),
        keyEvent(.Shift, false, .{}),
    });
    try std.testing.expect(snapshot.keyPressed(.Tab));
    try std.testing.expect(snapshot.keyDown(.Tab));
    try std.testing.expect(snapshot.keyReleased(.Tab));
    try std.testing.expect(snapshot.mods.shift);
    // The next tick has no event: the key is up, and Shift is up.
    snapshot.updateFromEvents(&.{});
    try std.testing.expect(!snapshot.keyDown(.Tab));
    try std.testing.expect(!snapshot.keyPressed(.Tab));
    try std.testing.expect(!snapshot.mods.shift);
    // A tick with no key press has the modifiers of its last event.
    snapshot.updateFromEvents(&.{keyEvent(.Alt, true, .{ .alt = true })});
    snapshot.updateFromEvents(&.{keyEvent(.Alt, false, .{})});
    try std.testing.expect(!snapshot.mods.alt);
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

test "InputSnapshot keeps the clipboard event of the tick" {
    var snapshot = InputSnapshot.init();
    snapshot.updateFromEvents(&[_]Event{
        Event.init(0, 0, 0, .{ .clipboard = .{ .kind = .paste, .status = .ok, .len = 3 } }),
    });
    try std.testing.expectEqual(event.ClipboardEventKind.paste, snapshot.clipboard.?.kind);
    try std.testing.expectEqual(@as(u32, 3), snapshot.clipboard.?.len);
    // The next tick has no clipboard event.
    snapshot.updateFromEvents(&[_]Event{});
    try std.testing.expect(snapshot.clipboard == null);
}

fn padButton(pad: u8, b: GamepadButton, down: bool) Event {
    return Event.init(0, 0, 0, .{ .gamepad_button = .{ .pad = pad, .button = b, .down = down } });
}

fn padAxis(pad: u8, a: GamepadAxis, v: f32) Event {
    return Event.init(0, 0, 0, .{ .gamepad_axis = .{ .pad = pad, .axis = a, .value = v } });
}

test "InputSnapshot gamepad buttons, axes and disconnect (REQ-INPUT-005)" {
    var snapshot = InputSnapshot.init();
    try std.testing.expect(!snapshot.anyGamepad());

    snapshot.updateFromEvents(&[_]Event{
        Event.init(0, 0, 0, .{ .gamepad_connection = .{ .pad = 1, .connected = true } }),
        padButton(1, .south, true),
        padAxis(1, .left_x, 0.5),
        padAxis(1, .right_trigger, 2),
    });
    const g = snapshot.gamepad(1);
    try std.testing.expect(g.connected);
    try std.testing.expect(snapshot.anyGamepad());
    try std.testing.expect(g.buttonDown(.south));
    try std.testing.expect(g.buttonPressed(.south));
    try std.testing.expectEqual(@as(f32, 0.5), g.rawAxis(.left_x));
    // The snapshot clamps a value past the range.
    try std.testing.expectEqual(@as(f32, 1), g.rawAxis(.right_trigger));
    try std.testing.expect(!snapshot.gamepad(0).connected);
    try std.testing.expect(!snapshot.gamepad(99).connected);

    // The next tick: the button stays down, with no edge.
    snapshot.updateFromEvents(&[_]Event{});
    try std.testing.expect(g.buttonDown(.south));
    try std.testing.expect(!g.buttonPressed(.south));
    try std.testing.expectEqual(@as(f32, 0.5), g.prev_axes[@backingInt(GamepadAxis.left_x)]);

    // A disconnect releases each button and centres the axes.
    snapshot.updateFromEvents(&[_]Event{
        Event.init(0, 0, 0, .{ .gamepad_connection = .{ .pad = 1, .connected = false } }),
    });
    try std.testing.expect(!g.connected);
    try std.testing.expect(!g.buttonDown(.south));
    try std.testing.expect(g.buttonReleased(.south));
    try std.testing.expectEqual(@as(f32, 0), g.rawAxis(.left_x));
}

test "gamepad dead zones (REQ-INPUT-005)" {
    // Inside the dead zone: the centre.
    try std.testing.expectEqual(Stick{}, radialDeadZone(0.1, 0.05, 0.15));
    // The edge stays at 1.
    try std.testing.expectApproxEqAbs(@as(f32, 1), radialDeadZone(1, 0, 0.15).x, 1e-6);
    // Half of the travel after the dead zone gives 0.5.
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), radialDeadZone(0, 0.575, 0.15).y, 1e-6);
    // A worn stick past 1 gives a length of 1, in the same direction.
    const over = radialDeadZone(1, 1, 0.15);
    try std.testing.expectApproxEqAbs(@as(f32, 1), @sqrt(over.x * over.x + over.y * over.y), 1e-6);
    try std.testing.expectApproxEqAbs(over.x, over.y, 1e-6);
    try std.testing.expectEqual(@as(f32, 0), triggerDeadZone(0.04, 0.05));
    try std.testing.expectApproxEqAbs(@as(f32, 1), triggerDeadZone(1, 0.05), 1e-6);

    var snapshot = InputSnapshot.init();
    snapshot.updateFromEvents(&[_]Event{ padAxis(0, .left_x, -0.575), padAxis(0, .left_trigger, 0.525) });
    const settings: GamepadSettings = .{};
    const g = snapshot.gamepad(0);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), g.stick(.left, settings).x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), g.axisValue(.left_x, false, settings), 1e-6);
    try std.testing.expectEqual(@as(f32, 0), g.axisValue(.left_x, true, settings));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), g.trigger(.left, settings), 1e-6);
    // A trigger has no negative direction.
    try std.testing.expectEqual(@as(f32, 0), g.axisValue(.left_trigger, false, settings));

    // A larger dead zone puts the same stick at the centre.
    var big: GamepadSettings = .{};
    big.setStickDeadZone(0.6);
    try std.testing.expectEqual(@as(f32, 0), g.axisValue(.left_x, false, big));
    big.setStickDeadZone(std.math.nan(f32));
    try std.testing.expectEqual(@as(f32, 0.6), big.stick_dead_zone);
    big.setTriggerDeadZone(5);
    try std.testing.expectEqual(GamepadSettings.max_dead_zone, big.trigger_dead_zone);
}
