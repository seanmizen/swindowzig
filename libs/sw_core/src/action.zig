//! Input actions. A game names its actions in an enum, and gives each action
//! default bindings. The player can change the bindings. Each tick,
//! `ActionMap.update` reads the `InputSnapshot` and sets the state of each
//! action. The state comes only from the snapshot and the bindings, so a
//! replay with the same bindings gives the same actions (REQ-INPUT-003).
//!
//! `encode` and `decode` change the bindings and the mouse settings to text
//! and back. `sw_platform.input_settings` keeps that text in storage
//! (REQ-INPUT-004).
//!
//! A new kind of input (for example a gamepad) is a new member of `Source`.
//! Code that defines, reads and rebinds actions does not change.

const std = @import("std");
const event = @import("event.zig");
const input = @import("input.zig");

const KeyCode = event.KeyCode;
const MouseButton = event.MouseButton;
const Modifiers = event.Modifiers;
const InputSnapshot = input.InputSnapshot;

/// The number of bindings that one action can have.
pub const max_bindings = 4;

/// An action is down when its value is at this level or more. A key or a
/// mouse button gives 0 or 1. An analog input gives a value between them.
pub const press_threshold: f32 = 0.5;

/// The first line of the text that `encode` writes.
pub const text_header = "swindowzig-input 1";

/// One input that a binding reads.
pub const Source = union(enum) {
    /// The binding slot is empty.
    none,
    key: KeyCode,
    mouse: MouseButton,

    pub fn eql(a: Source, b: Source) bool {
        return switch (a) {
            .none => b == .none,
            .key => |k| b == .key and b.key == k,
            .mouse => |m| b == .mouse and b.mouse == m,
        };
    }

    /// The value of the source in `snap`, from 0 to 1.
    pub fn value(self: Source, snap: *const InputSnapshot) f32 {
        return switch (self) {
            .none => 0,
            .key => |k| if (snap.keyDown(k)) 1 else 0,
            .mouse => |m| if (snap.buttonDown(m)) 1 else 0,
        };
    }
};

/// An input source, and the modifier keys that must be down with it. Other
/// modifier keys can also be down. Only shift, ctrl, alt and super count.
pub const Binding = struct {
    source: Source = .none,
    mods: Modifiers = .{},

    pub const none: Binding = .{};

    pub fn key(k: KeyCode) Binding {
        return .{ .source = .{ .key = k } };
    }

    pub fn mouse(b: MouseButton) Binding {
        return .{ .source = .{ .mouse = b } };
    }

    /// This binding, with `mods` as the modifier keys that must be down.
    pub fn withMods(self: Binding, mods: Modifiers) Binding {
        return .{ .source = self.source, .mods = normalMods(mods) };
    }

    pub fn isNone(self: Binding) bool {
        return self.source == .none;
    }

    pub fn eql(a: Binding, b: Binding) bool {
        return a.source.eql(b.source) and modBits(a.mods) == modBits(b.mods);
    }

    /// The value of the binding in `snap`. It is 0 when a modifier key of
    /// the binding is not down.
    pub fn value(self: Binding, snap: *const InputSnapshot) f32 {
        const need = modBits(self.mods);
        if (need & modBits(heldMods(snap)) != need) return 0;
        return self.source.value(snap);
    }

    /// Write the binding as one text token, for example `key:S+ctrl`.
    pub fn writeText(self: Binding, out: *std.ArrayList(u8), gpa: std.mem.Allocator) error{OutOfMemory}!void {
        switch (self.source) {
            .none => return out.appendSlice(gpa, "none"),
            .key => |k| try out.print(gpa, "key:{s}", .{@tagName(k)}),
            .mouse => |m| try out.print(gpa, "mouse:{s}", .{@tagName(m)}),
        }
        if (self.mods.shift) try out.appendSlice(gpa, "+shift");
        if (self.mods.ctrl) try out.appendSlice(gpa, "+ctrl");
        if (self.mods.alt) try out.appendSlice(gpa, "+alt");
        if (self.mods.super) try out.appendSlice(gpa, "+super");
    }

    /// Read one token that `writeText` wrote.
    pub fn parseText(text: []const u8) error{InvalidBinding}!Binding {
        if (std.mem.eql(u8, text, "none")) return .none;
        var parts = std.mem.splitScalar(u8, text, '+');
        const head = parts.first();
        const colon = std.mem.indexOfScalar(u8, head, ':') orelse return error.InvalidBinding;
        const kind = head[0..colon];
        const name = head[colon + 1 ..];
        var b: Binding = if (std.mem.eql(u8, kind, "key"))
            key(std.meta.stringToEnum(KeyCode, name) orelse return error.InvalidBinding)
        else if (std.mem.eql(u8, kind, "mouse"))
            mouse(std.meta.stringToEnum(MouseButton, name) orelse return error.InvalidBinding)
        else
            return error.InvalidBinding;
        while (parts.next()) |m| {
            if (std.mem.eql(u8, m, "shift")) {
                b.mods.shift = true;
            } else if (std.mem.eql(u8, m, "ctrl")) {
                b.mods.ctrl = true;
            } else if (std.mem.eql(u8, m, "alt")) {
                b.mods.alt = true;
            } else if (std.mem.eql(u8, m, "super")) {
                b.mods.super = true;
            } else return error.InvalidBinding;
        }
        return b;
    }
};

/// Keep only the modifier keys that a binding can need.
fn normalMods(m: Modifiers) Modifiers {
    return .{ .shift = m.shift, .ctrl = m.ctrl, .alt = m.alt, .super = m.super };
}

fn modBits(m: Modifiers) u4 {
    return @as(u4, @intFromBool(m.shift)) |
        @as(u4, @intFromBool(m.ctrl)) << 1 |
        @as(u4, @intFromBool(m.alt)) << 2 |
        @as(u4, @intFromBool(m.super)) << 3;
}

/// The modifier keys that are down. A modifier is down when its key is down,
/// or when the last event gave it.
pub fn heldMods(snap: *const InputSnapshot) Modifiers {
    return .{
        .shift = snap.mods.shift or snap.keyDown(.Shift),
        .ctrl = snap.mods.ctrl or snap.keyDown(.Ctrl),
        .alt = snap.mods.alt or snap.keyDown(.Alt),
        .super = snap.mods.super or snap.keyDown(.Super),
    };
}

fn isModifierKey(k: KeyCode) bool {
    return switch (k) {
        .Shift, .Ctrl, .Alt, .Super => true,
        else => false,
    };
}

/// Mouse look settings.
pub const MouseSettings = struct {
    /// Multiplies the mouse movement.
    sensitivity: f32 = 1.0,
    invert_x: bool = false,
    invert_y: bool = false,

    pub const min_sensitivity: f32 = 0.01;
    pub const max_sensitivity: f32 = 100.0;

    pub const Look = struct { dx: f32, dy: f32 };

    /// Set the sensitivity, clamped to the limits. A value that
    /// is not a number does not change the sensitivity.
    pub fn setSensitivity(self: *MouseSettings, v: f32) void {
        if (std.math.isNan(v)) return;
        self.sensitivity = std.math.clamp(v, min_sensitivity, max_sensitivity);
    }

    /// Apply the settings to a mouse movement.
    pub fn apply(self: MouseSettings, dx: f32, dy: f32) Look {
        return .{
            .dx = dx * self.sensitivity * @as(f32, if (self.invert_x) -1 else 1),
            .dy = dy * self.sensitivity * @as(f32, if (self.invert_y) -1 else 1),
        };
    }

    /// The mouse movement of this tick, with the settings applied.
    pub fn look(self: MouseSettings, snap: *const InputSnapshot) Look {
        return self.apply(snap.mouse.delta_x, snap.mouse.delta_y);
    }
};

/// The state of one action for one tick.
pub const ActionState = struct {
    /// From 0 to 1. The largest value of the bindings of the action.
    value: f32 = 0,
    down: bool = false,
    /// The action went down in this tick.
    pressed: bool = false,
    /// The action went up in this tick.
    released: bool = false,
};

pub const DecodeError = error{InvalidFormat};

/// The actions of a game. `Action` is an enum. Each member is one action.
/// The member names go into the saved text, so they must use only
/// `[A-Za-z0-9_.-]`.
pub fn ActionMap(comptime Action: type) type {
    comptime {
        if (@typeInfo(Action) != .@"enum") @compileError("ActionMap: Action must be an enum");
        for (std.meta.fieldNames(Action)) |name| {
            for (name) |c| {
                const ok = std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '-';
                if (!ok) @compileError("ActionMap: the action name '" ++ name ++ "' has a character outside [A-Za-z0-9_.-]");
            }
        }
    }

    return struct {
        const Self = @This();
        const Slots = [max_bindings]Binding;
        const actions = std.enums.values(Action);
        const all_slots = actions.len * max_bindings;

        /// The default bindings of each action. An action that the game
        /// does not name has no default binding.
        pub const Defaults = std.enums.EnumFieldStruct(Action, []const Binding, &.{});

        default_slots: std.enums.EnumArray(Action, Slots),
        slots: std.enums.EnumArray(Action, Slots),
        states: std.enums.EnumArray(Action, ActionState) = .initFill(.{}),
        mouse: MouseSettings = .{},

        /// Make a map with the default bindings. Each action can have
        /// `max_bindings` defaults at most.
        pub fn init(defaults: Defaults) Self {
            var d: std.enums.EnumArray(Action, Slots) = .initFill(@splat(Binding.none));
            inline for (comptime std.meta.fieldNames(Action)) |name| {
                const list: []const Binding = @field(defaults, name);
                std.debug.assert(list.len <= max_bindings);
                const slots = d.getPtr(@field(Action, name));
                const n = @min(list.len, max_bindings);
                for (list[0..n], 0..) |b, i| slots[i] = b.withMods(b.mods);
            }
            return .{ .default_slots = d, .slots = d };
        }

        /// Set the state of each action from the input of this tick. Call it
        /// once per tick, after the engine updates the snapshot.
        ///
        /// When one input source has two active bindings, and the modifiers
        /// of one binding include all the modifiers of the other, only the
        /// binding with more modifiers counts. Thus ctrl+S does not also
        /// fire an action bound to S.
        pub fn update(self: *Self, snap: *const InputSnapshot) void {
            var values: [all_slots]f32 = undefined;
            for (actions, 0..) |a, ai| {
                for (self.slots.get(a), 0..) |b, si| values[ai * max_bindings + si] = b.value(snap);
            }
            for (actions, 0..) |a, ai| {
                var v: f32 = 0;
                for (self.slots.get(a), 0..) |b, si| {
                    const i = ai * max_bindings + si;
                    if (values[i] <= 0) continue;
                    if (self.isShadowed(b, &values)) continue;
                    v = @max(v, values[i]);
                }
                const prev = self.states.get(a);
                const is_down = v >= press_threshold;
                self.states.set(a, .{
                    .value = v,
                    .down = is_down,
                    .pressed = is_down and !prev.down,
                    .released = !is_down and prev.down,
                });
            }
        }

        /// True when another active binding has the same source and more
        /// modifiers than `b`.
        fn isShadowed(self: *const Self, b: Binding, values: *const [all_slots]f32) bool {
            const bits = modBits(b.mods);
            for (actions, 0..) |a, ai| {
                for (self.slots.get(a), 0..) |o, si| {
                    if (values[ai * max_bindings + si] <= 0) continue;
                    if (!o.source.eql(b.source)) continue;
                    const obits = modBits(o.mods);
                    if (obits != bits and obits & bits == bits) return true;
                }
            }
            return false;
        }

        /// Set every action to up, with no edges. Use it when a menu takes
        /// the input. A key that stays down makes its action go down again
        /// at the next `update`.
        pub fn clearState(self: *Self) void {
            self.states = .initFill(.{});
        }

        pub fn state(self: *const Self, a: Action) ActionState {
            return self.states.get(a);
        }

        pub fn down(self: *const Self, a: Action) bool {
            return self.states.get(a).down;
        }

        pub fn pressed(self: *const Self, a: Action) bool {
            return self.states.get(a).pressed;
        }

        pub fn released(self: *const Self, a: Action) bool {
            return self.states.get(a).released;
        }

        pub fn value(self: *const Self, a: Action) f32 {
            return self.states.get(a).value;
        }

        /// `value(positive) - value(negative)`, from -1 to 1.
        pub fn axis(self: *const Self, negative: Action, positive: Action) f32 {
            return self.value(positive) - self.value(negative);
        }

        /// The binding slots of an action. An empty slot is `Binding.none`.
        pub fn bindings(self: *const Self, a: Action) []const Binding {
            return self.slots.getPtrConst(a);
        }

        pub fn defaultBindings(self: *const Self, a: Action) []const Binding {
            return self.default_slots.getPtrConst(a);
        }

        /// Put `b` in slot `slot` of action `a`. `slot` must be less than
        /// `max_bindings`.
        pub fn bind(self: *Self, a: Action, slot: usize, b: Binding) void {
            self.slots.getPtr(a)[slot] = b.withMods(b.mods);
        }

        pub fn unbind(self: *Self, a: Action, slot: usize) void {
            self.slots.getPtr(a)[slot] = .none;
        }

        /// Give action `a` its default bindings again.
        pub fn resetAction(self: *Self, a: Action) void {
            self.slots.set(a, self.default_slots.get(a));
        }

        /// Give every action its default bindings, and the mouse its
        /// default settings.
        pub fn resetAll(self: *Self) void {
            self.slots = self.default_slots;
            self.mouse = .{};
        }

        /// True when no binding of `a` differs from its defaults.
        pub fn isDefault(self: *const Self, a: Action) bool {
            const now = self.slots.get(a);
            const def = self.default_slots.get(a);
            for (now, def) |x, y| if (!x.eql(y)) return false;
            return true;
        }

        /// The first action, other than `except`, that has binding `b`. A
        /// rebinding menu uses it to show a conflict.
        pub fn findAction(self: *const Self, b: Binding, except: ?Action) ?Action {
            if (b.isNone()) return null;
            for (actions) |a| {
                if (except != null and except.? == a) continue;
                for (self.slots.get(a)) |o| if (o.eql(b)) return a;
            }
            return null;
        }

        /// Write the bindings and the mouse settings as text. The caller
        /// owns the returned slice.
        pub fn encode(self: *const Self, gpa: std.mem.Allocator) error{OutOfMemory}![]u8 {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(gpa);
            try out.print(gpa, "{s}\n", .{text_header});
            try out.print(gpa, "mouse sensitivity {d}\n", .{self.mouse.sensitivity});
            try out.print(gpa, "mouse invert_x {d}\n", .{@intFromBool(self.mouse.invert_x)});
            try out.print(gpa, "mouse invert_y {d}\n", .{@intFromBool(self.mouse.invert_y)});
            for (actions) |a| {
                try out.print(gpa, "action {s}", .{@tagName(a)});
                for (self.slots.get(a)) |b| {
                    try out.append(gpa, ' ');
                    try b.writeText(&out, gpa);
                }
                try out.append(gpa, '\n');
            }
            return out.toOwnedSlice(gpa);
        }

        /// Read text that `encode` wrote. Only the entries in the text
        /// change. Thus an action that the text does not name keeps its
        /// bindings. The map ignores a line or a token that it cannot read,
        /// so text from a newer version still loads (REQ-INPUT-004). If the
        /// first line is not the header, nothing changes.
        pub fn decode(self: *Self, text: []const u8) DecodeError!void {
            var lines = std.mem.splitScalar(u8, text, '\n');
            const first = std.mem.trimEnd(u8, lines.first(), "\r ");
            if (!std.mem.startsWith(u8, first, "swindowzig-input ")) return error.InvalidFormat;

            while (lines.next()) |raw| {
                const line = std.mem.trimEnd(u8, raw, "\r ");
                var tokens = std.mem.tokenizeScalar(u8, line, ' ');
                const kind = tokens.next() orelse continue;
                const name = tokens.next() orelse continue;
                if (std.mem.eql(u8, kind, "mouse")) {
                    const arg = tokens.next() orelse continue;
                    self.decodeMouse(name, arg);
                } else if (std.mem.eql(u8, kind, "action")) {
                    const a = std.meta.stringToEnum(Action, name) orelse continue;
                    const slots = self.slots.getPtr(a);
                    var i: usize = 0;
                    while (i < max_bindings) : (i += 1) {
                        const tok = tokens.next() orelse {
                            slots[i] = .none;
                            continue;
                        };
                        if (Binding.parseText(tok)) |b| slots[i] = b else |_| {}
                    }
                }
            }
        }

        fn decodeMouse(self: *Self, name: []const u8, arg: []const u8) void {
            if (std.mem.eql(u8, name, "sensitivity")) {
                const v = std.fmt.parseFloat(f32, arg) catch return;
                self.mouse.setSensitivity(v);
            } else if (std.mem.eql(u8, name, "invert_x")) {
                self.mouse.invert_x = std.mem.eql(u8, arg, "1");
            } else if (std.mem.eql(u8, name, "invert_y")) {
                self.mouse.invert_y = std.mem.eql(u8, arg, "1");
            }
        }
    };
}

/// Reads the next input of the player for a rebinding menu. Call `update`
/// once per tick while the menu waits.
///
/// - A key that is not a modifier key, or a mouse button, gives a binding
///   with the modifier keys that are down.
/// - A modifier key alone gives a binding when the player releases it.
///
/// The menu must check for its own cancel key before it calls `update`.
pub const BindingCapture = struct {
    pending_modifier: ?KeyCode = null,

    pub fn reset(self: *BindingCapture) void {
        self.pending_modifier = null;
    }

    pub fn update(self: *BindingCapture, snap: *const InputSnapshot) ?Binding {
        const mods = heldMods(snap);
        for (std.enums.values(KeyCode)) |k| {
            if (isModifierKey(k) or !snap.keyPressed(k)) continue;
            self.reset();
            return Binding.key(k).withMods(mods);
        }
        for (std.enums.values(MouseButton)) |m| {
            if (!snap.buttonPressed(m)) continue;
            self.reset();
            return Binding.mouse(m).withMods(mods);
        }
        if (self.pending_modifier) |k| {
            if (snap.keyReleased(k)) {
                self.reset();
                return Binding.key(k);
            }
        } else {
            for ([_]KeyCode{ .Shift, .Ctrl, .Alt, .Super }) |k| {
                if (snap.keyPressed(k)) {
                    self.pending_modifier = k;
                    break;
                }
            }
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Event = event.Event;

const TestAction = enum { jump, fire, forward, back, save };

const test_defaults: ActionMap(TestAction).Defaults = .{
    .jump = &.{Binding.key(.Space)},
    .fire = &.{ Binding.mouse(.left), Binding.key(.F) },
    .forward = &.{ Binding.key(.W), Binding.key(.Up) },
    .back = &.{Binding.key(.S)},
    .save = &.{Binding.key(.S).withMods(.{ .ctrl = true })},
};

fn keyEvent(k: KeyCode, is_down: bool) Event {
    return Event.init(0, 0, 0, .{ .key = .{ .keycode = k, .scancode = 0, .down = is_down, .repeat = false, .mods = .{} } });
}

fn buttonEvent(b: MouseButton, is_down: bool) Event {
    return Event.init(0, 0, 0, .{ .pointer_button = .{ .button = b, .down = is_down, .mods = .{} } });
}

test "actions: default bindings set down, pressed and released" {
    var map = ActionMap(TestAction).init(test_defaults);
    var snap = InputSnapshot.init();

    snap.updateFromEvents(&.{keyEvent(.Space, true)});
    map.update(&snap);
    try testing.expect(map.down(.jump));
    try testing.expect(map.pressed(.jump));
    try testing.expect(!map.down(.fire));

    snap.updateFromEvents(&.{buttonEvent(.left, true)});
    map.update(&snap);
    try testing.expect(map.down(.jump));
    try testing.expect(!map.pressed(.jump));
    try testing.expect(map.pressed(.fire));
    try testing.expectEqual(@as(f32, 1), map.value(.fire));

    snap.updateFromEvents(&.{ keyEvent(.Space, false), buttonEvent(.left, false) });
    map.update(&snap);
    try testing.expect(!map.down(.jump));
    try testing.expect(map.released(.jump));
    try testing.expect(map.released(.fire));

    // A second binding of the same action also works.
    snap.updateFromEvents(&.{keyEvent(.Up, true)});
    map.update(&snap);
    try testing.expect(map.down(.forward));
    try testing.expectEqual(@as(f32, 1), map.axis(.back, .forward));
}

test "actions: a binding with more modifiers shadows the same key" {
    var map = ActionMap(TestAction).init(test_defaults);
    var snap = InputSnapshot.init();

    // S alone: back, not save.
    snap.updateFromEvents(&.{keyEvent(.S, true)});
    map.update(&snap);
    try testing.expect(map.down(.back));
    try testing.expect(!map.down(.save));

    // Ctrl+S: save, and back goes up.
    snap.updateFromEvents(&.{ keyEvent(.S, false), keyEvent(.Ctrl, true), keyEvent(.S, true) });
    map.update(&snap);
    try testing.expect(map.down(.save));
    try testing.expect(!map.down(.back));

    // Shift does not stop W: a binding can have extra modifiers down.
    snap.updateFromEvents(&.{ keyEvent(.Ctrl, false), keyEvent(.Shift, true), keyEvent(.W, true) });
    map.update(&snap);
    try testing.expect(map.down(.forward));
}

test "actions: rebind, find a conflict, reset" {
    var map = ActionMap(TestAction).init(test_defaults);
    var snap = InputSnapshot.init();

    map.bind(.jump, 0, Binding.key(.J));
    try testing.expect(!map.isDefault(.jump));
    snap.updateFromEvents(&.{keyEvent(.Space, true)});
    map.update(&snap);
    try testing.expect(!map.down(.jump));
    snap.updateFromEvents(&.{keyEvent(.J, true)});
    map.update(&snap);
    try testing.expect(map.down(.jump));

    try testing.expectEqual(@as(?TestAction, .forward), map.findAction(Binding.key(.W), .jump));
    try testing.expectEqual(@as(?TestAction, null), map.findAction(Binding.key(.W), .forward));
    try testing.expectEqual(@as(?TestAction, .save), map.findAction(Binding.key(.S).withMods(.{ .ctrl = true }), null));

    map.unbind(.forward, 0);
    try testing.expect(map.bindings(.forward)[0].isNone());
    map.resetAction(.forward);
    try testing.expect(map.isDefault(.forward));

    map.mouse.invert_y = true;
    map.resetAll();
    try testing.expect(map.isDefault(.jump));
    try testing.expect(!map.mouse.invert_y);
}

test "actions: encode and decode give the same map" {
    const a = testing.allocator;
    var map = ActionMap(TestAction).init(test_defaults);
    map.bind(.jump, 1, Binding.mouse(.x1).withMods(.{ .alt = true, .shift = true, .caps_lock = true }));
    map.unbind(.fire, 0);
    map.mouse.setSensitivity(2.5);
    map.mouse.invert_y = true;

    const text = try map.encode(a);
    defer a.free(text);

    var other = ActionMap(TestAction).init(test_defaults);
    try other.decode(text);
    for (std.enums.values(TestAction)) |act| {
        for (map.bindings(act), other.bindings(act)) |x, y| try testing.expect(x.eql(y));
    }
    try testing.expectEqual(@as(f32, 2.5), other.mouse.sensitivity);
    try testing.expect(other.mouse.invert_y);
    try testing.expect(!other.mouse.invert_x);
    // Caps lock is not part of a binding.
    try testing.expect(!other.bindings(.jump)[1].mods.caps_lock);
}

test "actions: decode keeps defaults for entries it cannot read (REQ-INPUT-004)" {
    var map = ActionMap(TestAction).init(test_defaults);
    try testing.expectError(error.InvalidFormat, map.decode("something else\naction jump key:J\n"));
    try testing.expect(map.isDefault(.jump));

    try map.decode(
        \\swindowzig-input 2
        \\action jump key:J pad:a key:NoSuchKey
        \\action no_such_action key:K
        \\some_future_line 1 2 3
        \\mouse sensitivity nan
        \\mouse sensitivity 1e9
        \\
    );
    const j = map.bindings(.jump);
    try testing.expect(j[0].eql(Binding.key(.J)));
    // Tokens it cannot read keep the slot (here: empty defaults).
    try testing.expect(j[1].isNone());
    try testing.expect(j[2].isNone());
    try testing.expect(j[3].isNone());
    // Actions not in the text keep their bindings.
    try testing.expect(map.isDefault(.fire));
    try testing.expectEqual(MouseSettings.max_sensitivity, map.mouse.sensitivity);
}

test "mouse settings: sensitivity and invert" {
    var m: MouseSettings = .{};
    var r = m.apply(2, 3);
    try testing.expectEqual(@as(f32, 2), r.dx);
    try testing.expectEqual(@as(f32, 3), r.dy);

    m.setSensitivity(0.5);
    m.invert_y = true;
    r = m.apply(2, 3);
    try testing.expectEqual(@as(f32, 1), r.dx);
    try testing.expectEqual(@as(f32, -1.5), r.dy);

    m.invert_x = true;
    m.setSensitivity(std.math.nan(f32));
    try testing.expectEqual(@as(f32, 0.5), m.sensitivity);
    m.setSensitivity(0);
    try testing.expectEqual(MouseSettings.min_sensitivity, m.sensitivity);

    var snap = InputSnapshot.init();
    snap.updateFromEvents(&.{Event.init(0, 0, 0, .{ .pointer_move = .{ .x = 0, .y = 0, .dx = 100, .dy = 100, .device_id = 0, .mods = .{} } })});
    m.setSensitivity(1);
    r = m.look(&snap);
    try testing.expectEqual(@as(f32, -100), r.dx);
    try testing.expectEqual(@as(f32, -100), r.dy);
}

test "binding capture: key with modifiers, a modifier alone, a mouse button" {
    var cap: BindingCapture = .{};
    var snap = InputSnapshot.init();

    // Ctrl, then S: one binding, ctrl+S.
    snap.updateFromEvents(&.{keyEvent(.Ctrl, true)});
    try testing.expectEqual(@as(?Binding, null), cap.update(&snap));
    snap.updateFromEvents(&.{keyEvent(.S, true)});
    const b1 = cap.update(&snap).?;
    try testing.expect(b1.eql(Binding.key(.S).withMods(.{ .ctrl = true })));

    // Shift alone: a binding when the player releases it.
    snap.updateFromEvents(&.{ keyEvent(.S, false), keyEvent(.Ctrl, false) });
    try testing.expectEqual(@as(?Binding, null), cap.update(&snap));
    snap.updateFromEvents(&.{keyEvent(.Shift, true)});
    try testing.expectEqual(@as(?Binding, null), cap.update(&snap));
    snap.updateFromEvents(&.{keyEvent(.Shift, false)});
    try testing.expect(cap.update(&snap).?.eql(Binding.key(.Shift)));

    snap.updateFromEvents(&.{buttonEvent(.right, true)});
    try testing.expect(cap.update(&snap).?.eql(Binding.mouse(.right)));
}

test "actions: the same events give the same actions (REQ-INPUT-003)" {
    // Two runs over the same ticks of events, as a recording and its replay.
    const ticks = [_][]const Event{
        &.{keyEvent(.W, true)},
        &.{ keyEvent(.Ctrl, true), keyEvent(.S, true) },
        &.{buttonEvent(.left, true)},
        &.{ keyEvent(.S, false), keyEvent(.Ctrl, false), buttonEvent(.left, false) },
        &.{keyEvent(.W, false)},
    };
    var runs: [2][ticks.len]std.enums.EnumArray(TestAction, ActionState) = undefined;
    for (&runs) |*run| {
        var map = ActionMap(TestAction).init(test_defaults);
        var snap = InputSnapshot.init();
        for (ticks, 0..) |evs, t| {
            snap.updateFromEvents(evs);
            map.update(&snap);
            run[t] = map.states;
        }
    }
    for (runs[0], runs[1]) |x, y| {
        for (std.enums.values(TestAction)) |act| try testing.expectEqual(x.get(act), y.get(act));
    }
}
