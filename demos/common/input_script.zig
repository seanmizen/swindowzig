//! The input commands of a demo script as engine input (REQ-DEMO-008).
//!
//! A script line such as `+10 key Down` gives an `input` command
//! (`script.zig`). `ScriptInput.add` makes the engine events of the command,
//! and `ScriptInput.step` gives them to an `InputSnapshot` once per tick.
//! A demo reads that snapshot as it reads the snapshot of a real player, so
//! the action map, the binding capture and the UI see the same input on
//! each run of the script.
//!
//! The argument forms:
//!
//! - `key <KeyCode> [press|down|up]`: a key of `sw_core` (`Down`, `Enter`,
//!   `A`, `Shift`). `press` (the default) is down and up in one tick. A
//!   held modifier key (Shift, Ctrl, Alt, Super) is in the modifiers of each
//!   later event, until it goes up.
//! - `text <UTF-8>`: committed text, at most 32 bytes.
//! - `pad <GamepadButton> [press|down|up]`: a button of gamepad 0. A
//!   gamepad or mouse `press` is down in this tick and up in the next tick:
//!   the snapshot counts the presses of keys only.
//! - `axis <GamepadAxis> <value>`: an axis of gamepad 0, -1 to 1.
//! - `mouse move <x> <y>`: the pointer position, in the layout units of the
//!   demo. `mouse <left|right|middle> [press|down|up]`: a button.
//! - `wheel <lines>`: the wheel. A positive value scrolls up.

const std = @import("std");
const core = @import("sw_core");
const script = @import("script.zig");

const Event = core.Event;
const EventPayload = core.EventPayload;
const Modifiers = core.Modifiers;

pub const Error = error{ BadInput, TooManyEvents };

/// The most events of one tick.
pub const max_events = 32;

const Action = enum { press, down, up };

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}

fn split(s: []const u8) struct { []const u8, []const u8 } {
    const t = trim(s);
    const end = std.mem.indexOfAny(u8, t, " \t") orelse t.len;
    return .{ t[0..end], trim(t[end..]) };
}

fn parseAction(word: []const u8) Error!Action {
    if (word.len == 0) return .press;
    return std.meta.stringToEnum(Action, word) orelse error.BadInput;
}

fn parseFloat(word: []const u8) Error!f32 {
    return std.fmt.parseFloat(f32, word) catch error.BadInput;
}

pub const ScriptInput = struct {
    snapshot: core.InputSnapshot = .init(),
    pending: [max_events]Event = undefined,
    len: usize = 0,
    /// The button releases of a `press`, for the next tick.
    later: [max_events]Event = undefined,
    later_len: usize = 0,
    /// The modifier keys that the script holds down.
    mods: Modifiers = .{},
    pointer_x: f32 = 0,
    pointer_y: f32 = 0,

    /// Make the events of one input command. They go to the snapshot in the
    /// next `step`.
    pub fn add(self: *ScriptInput, in: script.Input) Error!void {
        switch (in.device) {
            .key => {
                const name, const rest = split(in.args);
                const k = std.meta.stringToEnum(core.KeyCode, name) orelse return error.BadInput;
                const action = try parseAction(rest);
                if (action != .up) {
                    self.setMod(k, true);
                    try self.push(.{ .key = .{ .keycode = k, .scancode = 0, .down = true, .repeat = false, .mods = self.mods } });
                }
                if (action != .down) {
                    self.setMod(k, false);
                    try self.push(.{ .key = .{ .keycode = k, .scancode = 0, .down = false, .repeat = false, .mods = self.mods } });
                }
            },
            .text => {
                if (in.args.len > core.event.text_input_max) return error.BadInput;
                try self.push(core.event.textInputPayload(in.args));
            },
            .pad => {
                const name, const rest = split(in.args);
                const b = std.meta.stringToEnum(core.GamepadButton, name) orelse return error.BadInput;
                const action = try parseAction(rest);
                if (action != .up) try self.push(.{ .gamepad_button = .{ .pad = 0, .button = b, .down = true } });
                const up: EventPayload = .{ .gamepad_button = .{ .pad = 0, .button = b, .down = false } };
                if (action == .press) try self.pushLater(up) else if (action == .up) try self.push(up);
            },
            .axis => {
                const name, const rest = split(in.args);
                const a = std.meta.stringToEnum(core.GamepadAxis, name) orelse return error.BadInput;
                const v = std.math.clamp(try parseFloat(rest), -1, 1);
                try self.push(.{ .gamepad_axis = .{ .pad = 0, .axis = a, .value = v } });
            },
            .mouse => {
                const name, const rest = split(in.args);
                if (std.mem.eql(u8, name, "move")) {
                    const xs, const ys = split(rest);
                    const x = try parseFloat(xs);
                    const y = try parseFloat(ys);
                    try self.push(.{ .pointer_move = .{ .x = x, .y = y, .dx = x - self.pointer_x, .dy = y - self.pointer_y, .device_id = 0, .mods = self.mods } });
                    self.pointer_x = x;
                    self.pointer_y = y;
                } else {
                    const b = std.meta.stringToEnum(core.MouseButton, name) orelse return error.BadInput;
                    const action = try parseAction(rest);
                    if (action != .up) try self.push(.{ .pointer_button = .{ .button = b, .down = true, .mods = self.mods } });
                    const up: EventPayload = .{ .pointer_button = .{ .button = b, .down = false, .mods = self.mods } };
                    if (action == .press) try self.pushLater(up) else if (action == .up) try self.push(up);
                }
            },
            .wheel => {
                const dy = try parseFloat(in.args);
                try self.push(.{ .wheel = .{ .dx = 0, .dy = dy, .mode = .line, .mods = self.mods } });
            },
        }
    }

    /// Give the events of this tick to the snapshot. Call it once per tick,
    /// also with no events, so the presses of the last tick end.
    pub fn step(self: *ScriptInput, tick: u64) void {
        for (self.pending[0..self.len], 0..) |*e, i| {
            e.tick_id = tick;
            e.seq = @intCast(i);
        }
        self.snapshot.updateFromEvents(self.pending[0..self.len]);
        self.len = 0;
        for (self.later[0..self.later_len]) |e| try_push: {
            self.push(e.payload) catch break :try_push;
        }
        self.later_len = 0;
    }

    /// Release each key and button, and forget the pointer.
    pub fn reset(self: *ScriptInput) void {
        self.* = .{};
    }

    fn push(self: *ScriptInput, payload: EventPayload) Error!void {
        if (self.len >= max_events) return error.TooManyEvents;
        self.pending[self.len] = Event.init(0, 0, 0, payload);
        self.len += 1;
    }

    fn pushLater(self: *ScriptInput, payload: EventPayload) Error!void {
        if (self.later_len >= max_events) return error.TooManyEvents;
        self.later[self.later_len] = Event.init(0, 0, 0, payload);
        self.later_len += 1;
    }

    fn setMod(self: *ScriptInput, k: core.KeyCode, down: bool) void {
        switch (k) {
            .Shift => self.mods.shift = down,
            .Ctrl => self.mods.ctrl = down,
            .Alt => self.mods.alt = down,
            .Super => self.mods.super = down,
            else => {},
        }
    }
};
