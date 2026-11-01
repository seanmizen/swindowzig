//! The mouse of the player in a window, and the pointer lock
//! (REQ-DEMO-025).
//!
//! The game reads the mouse only while the pointer is locked. The browser
//! ends the lock on Escape and when the page loses the focus. On macOS,
//! SDL keeps the relative mode on when the window loses the focus, and
//! turns it on again when the window gets the focus back. So the demo ends
//! the lock itself when the window loses the focus, and both platforms do
//! the same thing: a click in the window locks the pointer again.
//!
//! The click that locks the pointer does not fire the gun. The game reads
//! the mouse buttons again only after the player releases all of them.
//! The web lock comes some frames after the request, so the button can
//! still be down when the lock starts.
const std = @import("std");
const sw_core = @import("sw_core");

pub const Gate = struct {
    /// True after the first lock request.
    asked: bool = false,
    /// True while the game reads the mouse.
    on: bool = false,

    /// What one tick does with the pointer lock and the mouse.
    pub const Step = struct {
        /// Ask the platform for the pointer lock in this tick.
        lock: bool = false,
        /// The game reads the mouse in this tick.
        mouse: bool = false,
    };

    /// Call it one time in each tick of the player. `locked` is the real
    /// state of the pointer lock (`ctx.isCursorLocked()`).
    pub fn step(self: *Gate, locked: bool, snap: *const sw_core.InputSnapshot) Step {
        if (!locked) {
            self.on = false;
            // The first tick of the player asks for the lock (a key or a
            // click took the control). After that, only a click asks.
            const first = !self.asked;
            self.asked = true;
            return .{ .lock = first or snap.mouse.pressed.count() != 0 };
        }
        if (!self.on and snap.mouse.buttons.count() == 0 and snap.mouse.pressed.count() == 0) self.on = true;
        return .{ .mouse = self.on };
    }
};

/// A copy of `snap` with no mouse buttons and no mouse movement. The keys,
/// the wheel and the gamepads do not change.
pub fn withoutMouse(snap: *const sw_core.InputSnapshot) sw_core.InputSnapshot {
    var s = snap.*;
    s.mouse.buttons = .empty;
    s.mouse.pressed = .empty;
    s.mouse.released = .empty;
    s.mouse.delta_x = 0;
    s.mouse.delta_y = 0;
    return s;
}

/// True when the window lost the focus in this tick. Only SDL sends focus
/// events. The browser ends the pointer lock itself.
pub fn focusLost(events: []const sw_core.Event) bool {
    for (events) |e| switch (e.payload) {
        .focus => |f| if (!f.focused) return true,
        else => {},
    };
    return false;
}

fn snapWith(down: bool, pressed: bool) sw_core.InputSnapshot {
    var s: sw_core.InputSnapshot = .{};
    if (down) s.mouse.buttons.set(@backingInt(sw_core.MouseButton.left));
    if (pressed) s.mouse.pressed.set(@backingInt(sw_core.MouseButton.left));
    s.mouse.delta_x = 5;
    return s;
}

test "the first tick of the player asks for the lock" {
    var g: Gate = .{};
    const none = snapWith(false, false);
    try std.testing.expectEqual(Gate.Step{ .lock = true }, g.step(false, &none));
    // The lock did not come yet. No click: no new request.
    try std.testing.expectEqual(Gate.Step{}, g.step(false, &none));
}

test "a click locks the pointer again and does not reach the game" {
    var g: Gate = .{};
    const none = snapWith(false, false);
    const click = snapWith(true, true);
    const held = snapWith(true, false);
    _ = g.step(false, &none);
    try std.testing.expectEqual(Gate.Step{ .mouse = true }, g.step(true, &none));
    // The lock ends (Escape, or the focus goes to another window).
    try std.testing.expectEqual(Gate.Step{}, g.step(false, &held));
    // A click asks for the lock. The game does not read it.
    try std.testing.expectEqual(Gate.Step{ .lock = true }, g.step(false, &click));
    // The lock starts while the button is still down.
    try std.testing.expectEqual(Gate.Step{}, g.step(true, &held));
    // The player releases the button: the game reads the mouse.
    try std.testing.expectEqual(Gate.Step{ .mouse = true }, g.step(true, &none));
    try std.testing.expectEqual(Gate.Step{ .mouse = true }, g.step(true, &click));
}

test "withoutMouse removes the buttons and the movement" {
    var s = snapWith(true, true);
    s.keyboard.pressed.set(@backingInt(sw_core.KeyCode.W));
    const m = withoutMouse(&s);
    try std.testing.expect(!m.buttonDown(.left));
    try std.testing.expect(!m.buttonPressed(.left));
    try std.testing.expectEqual(@as(f32, 0), m.mouse.delta_x);
    try std.testing.expect(m.keyPressed(.W));
}

test "focusLost finds a focus loss" {
    const lost = [_]sw_core.Event{.init(1, 0, 0, .{ .focus = .{ .focused = false } })};
    const gained = [_]sw_core.Event{.init(1, 0, 0, .{ .focus = .{ .focused = true } })};
    try std.testing.expect(focusLost(&lost));
    try std.testing.expect(!focusLost(&gained));
    try std.testing.expect(!focusLost(&.{}));
}
