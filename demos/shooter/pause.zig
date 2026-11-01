//! When the pause menu of the shooter opens and closes (REQ-DEMO-027).
//!
//! Escape or the gamepad Start button opens the menu during the fight.
//! The browser ends the pointer lock on Escape, and the page does not
//! always get the key. So the end of the lock during the fight also opens
//! the menu. Then the web build and the native build do the same thing.
//! A focus loss ends the lock too (REQ-DEMO-025), so it also opens the
//! menu.
//!
//! The Escape key that opens the menu must not also close it. The lock
//! can end some ticks before or after the key arrives, so the menu does
//! not read Escape or Start for `grace_ticks` after it opens.
const std = @import("std");

pub const Pause = struct {
    /// True while the menu is open and the fight does not run.
    open: bool = false,
    /// The pointer lock in the last tick of the fight.
    was_locked: bool = false,
    /// The ticks before the menu reads Escape and Start.
    grace: u8 = 0,

    pub const grace_ticks: u8 = 12;

    pub const Input = struct {
        /// The real state of the pointer lock. Always false for the script.
        locked: bool = false,
        escape: bool = false,
        /// The Start button of a gamepad.
        start: bool = false,
    };

    pub const Step = struct {
        /// The menu opens in this tick: end the pointer lock.
        opened: bool = false,
        /// The menu closes in this tick (Start): ask for the pointer lock.
        closed: bool = false,
        /// The menu can read Escape in this tick.
        escape: bool = false,
    };

    /// Call it one time in each tick, before the menu.
    pub fn step(self: *Pause, in: Input) Step {
        if (!self.open) {
            const lost = self.was_locked and !in.locked;
            self.was_locked = in.locked;
            if (lost or in.escape or in.start) {
                self.open = true;
                self.was_locked = false;
                self.grace = grace_ticks;
                return .{ .opened = true };
            }
            return .{};
        }
        if (self.grace > 0) {
            self.grace -= 1;
            return .{};
        }
        if (in.start) {
            self.close();
            return .{ .closed = true };
        }
        return .{ .escape = true };
    }

    /// Close the menu (Resume). The fight runs again.
    pub fn close(self: *Pause) void {
        self.open = false;
        self.was_locked = false;
        self.grace = 0;
    }
};

test "Escape and Start open the menu, and Start closes it (REQ-DEMO-027)" {
    var p: Pause = .{};
    try std.testing.expectEqual(Pause.Step{}, p.step(.{ .locked = true }));
    try std.testing.expectEqual(Pause.Step{ .opened = true }, p.step(.{ .locked = true, .escape = true }));
    // The Escape of the same key press does not close the menu.
    for (0..Pause.grace_ticks) |_| try std.testing.expectEqual(Pause.Step{}, p.step(.{ .escape = true }));
    try std.testing.expectEqual(Pause.Step{ .escape = true }, p.step(.{}));
    try std.testing.expectEqual(Pause.Step{ .closed = true }, p.step(.{ .start = true }));
    try std.testing.expect(!p.open);
    try std.testing.expectEqual(Pause.Step{ .opened = true }, p.step(.{ .start = true }));
}

test "the end of the pointer lock during the fight opens the menu (REQ-DEMO-027)" {
    var p: Pause = .{};
    // No lock yet (the lock request waits): no menu.
    try std.testing.expectEqual(Pause.Step{}, p.step(.{}));
    try std.testing.expectEqual(Pause.Step{}, p.step(.{ .locked = true }));
    // The browser ends the lock on Escape, and the key does not arrive.
    try std.testing.expectEqual(Pause.Step{ .opened = true }, p.step(.{}));
    // The key arrives in the next tick: the menu stays open.
    try std.testing.expectEqual(Pause.Step{}, p.step(.{ .escape = true }));
    try std.testing.expect(p.open);
    // Resume: the lock comes some ticks later. No menu before it.
    p.close();
    try std.testing.expectEqual(Pause.Step{}, p.step(.{}));
    try std.testing.expectEqual(Pause.Step{}, p.step(.{}));
    try std.testing.expectEqual(Pause.Step{}, p.step(.{ .locked = true }));
}
