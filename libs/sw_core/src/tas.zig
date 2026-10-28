//! TAS (Tool-Assisted Speedrun) Script System
//! Human-readable input scripts for deterministic game replay
//!
//! Script Format (.tas files):
//! ```
//! # Comments start with #
//! # Format: tick command args...
//!
//! 0 keydown W
//! 60 keyup W
//! 60 keydown Space
//! 120 mouse_move 100 -50
//! 180 mouse_down left
//! 181 mouse_up left
//! 200 gamepad_down south
//! 210 gamepad_up south
//! 220 gamepad_axis left_x -0.5
//! 230 gamepad_axis right_trigger 1 2
//! ```
//!
//! The gamepad commands take the name of a `GamepadButton` or a
//! `GamepadAxis`, and an optional gamepad slot at the end (default 0). The
//! axis value is raw: the game applies the dead zones (REQ-INPUT-005).

const std = @import("std");
const event_mod = @import("event.zig");
const Event = event_mod.Event;
const EventPayload = event_mod.EventPayload;
const KeyCode = event_mod.KeyCode;
const MouseButtonType = event_mod.MouseButton;
const WheelMode = event_mod.WheelMode;
const Modifiers = event_mod.Modifiers;
const CommandKind = event_mod.CommandKind;
const GamepadButton = event_mod.GamepadButton;
const GamepadAxis = event_mod.GamepadAxis;

/// TAS command types
pub const TasCommand = union(enum) {
    keydown: Key,
    keyup: Key,
    mouse_move: struct { dx: f32, dy: f32 },
    mouse_down: MouseButton,
    mouse_up: MouseButton,
    mouse_wheel: f32,
    wait: u64, // Wait N ticks (syntactic sugar, doesn't generate event)
    command: struct { kind: CommandKind, args: [4]f32 },
    gamepad_down: struct { pad: u8 = 0, button: GamepadButton },
    gamepad_up: struct { pad: u8 = 0, button: GamepadButton },
    gamepad_axis: struct { pad: u8 = 0, axis: GamepadAxis, value: f32 },

    pub fn toEvent(self: TasCommand, tick_id: u64, t_ns: u64, seq: u32) ?Event {
        const empty_mods = Modifiers{};

        return switch (self) {
            .keydown => |key| Event.init(tick_id, t_ns, seq, .{
                .key = .{
                    .keycode = @fromBackingInt(@intCast(@backingInt(key))),
                    .scancode = 0,
                    .down = true,
                    .repeat = false,
                    .mods = empty_mods,
                },
            }),
            .keyup => |key| Event.init(tick_id, t_ns, seq, .{
                .key = .{
                    .keycode = @fromBackingInt(@intCast(@backingInt(key))),
                    .scancode = 0,
                    .down = false,
                    .repeat = false,
                    .mods = empty_mods,
                },
            }),
            .mouse_move => |m| Event.init(tick_id, t_ns, seq, .{
                .pointer_move = .{
                    .x = 0,
                    .y = 0,
                    .dx = m.dx,
                    .dy = m.dy,
                    .device_id = 0,
                    .mods = empty_mods,
                },
            }),
            .mouse_down => |btn| Event.init(tick_id, t_ns, seq, .{
                .pointer_button = .{
                    .button = btn,
                    .down = true,
                    .mods = empty_mods,
                },
            }),
            .mouse_up => |btn| Event.init(tick_id, t_ns, seq, .{
                .pointer_button = .{
                    .button = btn,
                    .down = false,
                    .mods = empty_mods,
                },
            }),
            .mouse_wheel => |delta| Event.init(tick_id, t_ns, seq, .{
                .wheel = .{
                    .dx = 0,
                    .dy = delta,
                    .mode = .line,
                    .mods = empty_mods,
                },
            }),
            .wait => null, // wait doesn't generate events
            .command => |cmd| Event.init(tick_id, t_ns, seq, .{
                .command = .{
                    .kind = cmd.kind,
                    .args = cmd.args,
                },
            }),
            .gamepad_down => |g| Event.init(tick_id, t_ns, seq, .{
                .gamepad_button = .{ .pad = g.pad, .button = g.button, .down = true },
            }),
            .gamepad_up => |g| Event.init(tick_id, t_ns, seq, .{
                .gamepad_button = .{ .pad = g.pad, .button = g.button, .down = false },
            }),
            .gamepad_axis => |g| Event.init(tick_id, t_ns, seq, .{
                .gamepad_axis = .{ .pad = g.pad, .axis = g.axis, .value = g.value },
            }),
        };
    }
};

/// Key enum (alias for event.KeyCode)
pub const Key = KeyCode;

pub fn keyFromString(s: []const u8) !Key {
    // Letters
    if (std.mem.eql(u8, s, "A")) return .A;
    if (std.mem.eql(u8, s, "B")) return .B;
    if (std.mem.eql(u8, s, "C")) return .C;
    if (std.mem.eql(u8, s, "D")) return .D;
    if (std.mem.eql(u8, s, "E")) return .E;
    if (std.mem.eql(u8, s, "F")) return .F;
    if (std.mem.eql(u8, s, "G")) return .G;
    if (std.mem.eql(u8, s, "H")) return .H;
    if (std.mem.eql(u8, s, "I")) return .I;
    if (std.mem.eql(u8, s, "J")) return .J;
    if (std.mem.eql(u8, s, "K")) return .K;
    if (std.mem.eql(u8, s, "L")) return .L;
    if (std.mem.eql(u8, s, "M")) return .M;
    if (std.mem.eql(u8, s, "N")) return .N;
    if (std.mem.eql(u8, s, "O")) return .O;
    if (std.mem.eql(u8, s, "P")) return .P;
    if (std.mem.eql(u8, s, "Q")) return .Q;
    if (std.mem.eql(u8, s, "R")) return .R;
    if (std.mem.eql(u8, s, "S")) return .S;
    if (std.mem.eql(u8, s, "T")) return .T;
    if (std.mem.eql(u8, s, "U")) return .U;
    if (std.mem.eql(u8, s, "V")) return .V;
    if (std.mem.eql(u8, s, "W")) return .W;
    if (std.mem.eql(u8, s, "X")) return .X;
    if (std.mem.eql(u8, s, "Y")) return .Y;
    if (std.mem.eql(u8, s, "Z")) return .Z;
    // Numbers
    if (std.mem.eql(u8, s, "0")) return .Num0;
    if (std.mem.eql(u8, s, "1")) return .Num1;
    if (std.mem.eql(u8, s, "2")) return .Num2;
    if (std.mem.eql(u8, s, "3")) return .Num3;
    if (std.mem.eql(u8, s, "4")) return .Num4;
    if (std.mem.eql(u8, s, "5")) return .Num5;
    if (std.mem.eql(u8, s, "6")) return .Num6;
    if (std.mem.eql(u8, s, "7")) return .Num7;
    if (std.mem.eql(u8, s, "8")) return .Num8;
    if (std.mem.eql(u8, s, "9")) return .Num9;
    // Special keys
    if (std.mem.eql(u8, s, "Space")) return .Space;
    if (std.mem.eql(u8, s, "Enter")) return .Enter;
    if (std.mem.eql(u8, s, "Escape")) return .Escape;
    if (std.mem.eql(u8, s, "Tab")) return .Tab;
    if (std.mem.eql(u8, s, "Backspace")) return .Backspace;
    if (std.mem.eql(u8, s, "Shift")) return .Shift;
    if (std.mem.eql(u8, s, "Ctrl")) return .Ctrl;
    if (std.mem.eql(u8, s, "Alt")) return .Alt;
    if (std.mem.eql(u8, s, "Left")) return .Left;
    if (std.mem.eql(u8, s, "Right")) return .Right;
    if (std.mem.eql(u8, s, "Up")) return .Up;
    if (std.mem.eql(u8, s, "Down")) return .Down;
    // Punctuation and navigation keys: the KeyCode member name.
    const named = [_]Key{
        .Grave,     .Minus, .Equal,  .LeftBracket, .RightBracket, .Backslash,
        .Semicolon, .Quote, .Comma,  .Period,      .Slash,        .Delete,
        .Home,      .End,   .PageUp, .PageDown,    .Insert,
    };
    for (named) |key| {
        if (std.mem.eql(u8, s, @tagName(key))) return key;
    }
    return error.InvalidKey;
}

/// Mouse button enum (alias for event.MouseButton)
pub const MouseButton = MouseButtonType;

pub fn mouseButtonFromString(s: []const u8) !MouseButton {
    if (std.mem.eql(u8, s, "left")) return .left;
    if (std.mem.eql(u8, s, "right")) return .right;
    if (std.mem.eql(u8, s, "middle")) return .middle;
    return error.InvalidMouseButton;
}

/// TAS script entry
pub const TasEntry = struct {
    tick: u64,
    command: TasCommand,
};

/// TAS script parser
pub const TasScript = struct {
    entries: std.ArrayList(TasEntry),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TasScript {
        return .{
            .entries = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TasScript) void {
        self.entries.deinit(self.allocator);
    }

    /// Parse TAS script from string
    pub fn parse(allocator: std.mem.Allocator, source: []const u8) !TasScript {
        var script = TasScript.init(allocator);
        errdefer script.deinit();

        var lines = std.mem.splitScalar(u8, source, '\n');
        var line_num: usize = 0;

        while (lines.next()) |line| {
            line_num += 1;

            // Skip empty lines and comments
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            // Parse line: tick command args...
            var parts = std.mem.tokenizeAny(u8, trimmed, " \t");

            const tick_str = parts.next() orelse {
                std.log.err("Line {}: Missing tick number", .{line_num});
                return error.InvalidFormat;
            };
            const tick = std.fmt.parseInt(u64, tick_str, 10) catch {
                std.log.err("Line {}: Invalid tick number '{s}'", .{ line_num, tick_str });
                return error.InvalidTick;
            };

            const cmd_str = parts.next() orelse {
                std.log.err("Line {}: Missing command", .{line_num});
                return error.InvalidFormat;
            };

            const command = try parseCommand(cmd_str, &parts, line_num);

            try script.entries.append(allocator, .{
                .tick = tick,
                .command = command,
            });
        }

        return script;
    }

    /// Parse TAS script from file
    pub fn parseFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !TasScript {
        const source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(10 * 1024 * 1024)); // 10MB max
        defer allocator.free(source);

        return try parse(allocator, source);
    }

    /// Convert TAS script to event list
    pub fn toEvents(self: *const TasScript, tick_hz: u32) !std.ArrayList(Event) {
        var events: std.ArrayList(Event) = .empty;
        errdefer events.deinit(self.allocator);

        const ns_per_tick: u64 = 1_000_000_000 / tick_hz;

        for (self.entries.items, 0..) |entry, i| {
            const t_ns = entry.tick * ns_per_tick;

            if (entry.command.toEvent(entry.tick, t_ns, @intCast(i))) |event| {
                try events.append(self.allocator, event);
            }
            // wait commands don't generate events
        }

        return events;
    }

    /// Get total duration in ticks
    pub fn getDuration(self: *const TasScript) u64 {
        if (self.entries.items.len == 0) return 0;

        var max_tick: u64 = 0;
        for (self.entries.items) |entry| {
            if (entry.tick > max_tick) {
                max_tick = entry.tick;
            }
        }
        return max_tick;
    }
};

fn parseCommand(cmd: []const u8, parts: *std.mem.TokenIterator(u8, .any), line_num: usize) !TasCommand {
    if (std.mem.eql(u8, cmd, "keydown")) {
        const key_str = parts.next() orelse return error.MissingArgument;
        const key = keyFromString(key_str) catch |err| {
            std.log.err("Line {}: Invalid key '{s}'", .{ line_num, key_str });
            return err;
        };
        return .{ .keydown = key };
    } else if (std.mem.eql(u8, cmd, "keyup")) {
        const key_str = parts.next() orelse return error.MissingArgument;
        const key = keyFromString(key_str) catch |err| {
            std.log.err("Line {}: Invalid key '{s}'", .{ line_num, key_str });
            return err;
        };
        return .{ .keyup = key };
    } else if (std.mem.eql(u8, cmd, "mouse_move")) {
        const dx_str = parts.next() orelse return error.MissingArgument;
        const dy_str = parts.next() orelse return error.MissingArgument;
        const dx = try std.fmt.parseFloat(f32, dx_str);
        const dy = try std.fmt.parseFloat(f32, dy_str);
        return .{ .mouse_move = .{ .dx = dx, .dy = dy } };
    } else if (std.mem.eql(u8, cmd, "mouse_down")) {
        const btn_str = parts.next() orelse return error.MissingArgument;
        const btn = mouseButtonFromString(btn_str) catch |err| {
            std.log.err("Line {}: Invalid mouse button '{s}'", .{ line_num, btn_str });
            return err;
        };
        return .{ .mouse_down = btn };
    } else if (std.mem.eql(u8, cmd, "mouse_up")) {
        const btn_str = parts.next() orelse return error.MissingArgument;
        const btn = mouseButtonFromString(btn_str) catch |err| {
            std.log.err("Line {}: Invalid mouse button '{s}'", .{ line_num, btn_str });
            return err;
        };
        return .{ .mouse_up = btn };
    } else if (std.mem.eql(u8, cmd, "mouse_wheel")) {
        const delta_str = parts.next() orelse return error.MissingArgument;
        const delta = try std.fmt.parseFloat(f32, delta_str);
        return .{ .mouse_wheel = delta };
    } else if (std.mem.eql(u8, cmd, "gamepad_down") or std.mem.eql(u8, cmd, "gamepad_up")) {
        const name = parts.next() orelse return error.MissingArgument;
        const button = std.meta.stringToEnum(GamepadButton, name) orelse {
            std.log.err("Line {}: Invalid gamepad button '{s}'", .{ line_num, name });
            return error.InvalidGamepadButton;
        };
        const pad = try parsePad(parts, line_num);
        if (cmd[8] == 'd') return .{ .gamepad_down = .{ .pad = pad, .button = button } };
        return .{ .gamepad_up = .{ .pad = pad, .button = button } };
    } else if (std.mem.eql(u8, cmd, "gamepad_axis")) {
        const name = parts.next() orelse return error.MissingArgument;
        const axis = std.meta.stringToEnum(GamepadAxis, name) orelse {
            std.log.err("Line {}: Invalid gamepad axis '{s}'", .{ line_num, name });
            return error.InvalidGamepadAxis;
        };
        const value_str = parts.next() orelse return error.MissingArgument;
        const value = try std.fmt.parseFloat(f32, value_str);
        const pad = try parsePad(parts, line_num);
        return .{ .gamepad_axis = .{ .pad = pad, .axis = axis, .value = value } };
    } else if (std.mem.eql(u8, cmd, "wait")) {
        const ticks_str = parts.next() orelse return error.MissingArgument;
        const ticks = try std.fmt.parseInt(u64, ticks_str, 10);
        return .{ .wait = ticks };
    } else if (std.mem.eql(u8, cmd, "cmd")) {
        const name_str = parts.next() orelse {
            std.log.err("Line {}: cmd requires a command name (tp, set_spawn)", .{line_num});
            return error.MissingArgument;
        };
        const kind: CommandKind = if (std.mem.eql(u8, name_str, "tp"))
            .tp
        else if (std.mem.eql(u8, name_str, "set_spawn"))
            .set_spawn
        else {
            std.log.err("Line {}: Unknown command name '{s}'", .{ line_num, name_str });
            return error.UnknownCommand;
        };
        var args = [4]f32{ 0, 0, 0, 0 };
        var ai: usize = 0;
        while (ai < 4) : (ai += 1) {
            const arg_str = parts.next() orelse break;
            args[ai] = std.fmt.parseFloat(f32, arg_str) catch {
                std.log.err("Line {}: Invalid float arg '{s}'", .{ line_num, arg_str });
                return error.InvalidFormat;
            };
        }
        return .{ .command = .{ .kind = kind, .args = args } };
    } else {
        std.log.err("Line {}: Unknown command '{s}'", .{ line_num, cmd });
        return error.UnknownCommand;
    }
}

/// The optional gamepad slot at the end of a gamepad command. Default 0.
fn parsePad(parts: *std.mem.TokenIterator(u8, .any), line_num: usize) !u8 {
    const pad_str = parts.next() orelse return 0;
    const pad = std.fmt.parseInt(u8, pad_str, 10) catch {
        std.log.err("Line {}: Invalid gamepad slot '{s}'", .{ line_num, pad_str });
        return error.InvalidGamepadSlot;
    };
    if (pad >= event_mod.max_gamepads) {
        std.log.err("Line {}: Gamepad slot {} is not less than {}", .{ line_num, pad, event_mod.max_gamepads });
        return error.InvalidGamepadSlot;
    }
    return pad;
}

// Tests
test "TAS script parsing" {
    const script_source =
        \\# Move forward and jump
        \\0 keydown W
        \\60 keyup W
        \\60 keydown Space
        \\65 keyup Space
        \\# Look around
        \\120 mouse_move 100 -50
        \\# Click
        \\180 mouse_down left
        \\181 mouse_up left
    ;

    var script = try TasScript.parse(std.testing.allocator, script_source);
    defer script.deinit();

    try std.testing.expectEqual(@as(usize, 7), script.entries.items.len);

    try std.testing.expectEqual(@as(u64, 0), script.entries.items[0].tick);
    try std.testing.expectEqual(TasCommand.keydown, std.meta.activeTag(script.entries.items[0].command));

    try std.testing.expectEqual(@as(u64, 120), script.entries.items[4].tick);
    try std.testing.expectEqual(TasCommand.mouse_move, std.meta.activeTag(script.entries.items[4].command));

    const duration = script.getDuration();
    try std.testing.expectEqual(@as(u64, 181), duration);
}

test "TAS fields can have more than one space or a tab between them" {
    const script_source = "5  keydown A\n35\tkeyup A\n37 mouse_move  1\t-2\n";
    var script = try TasScript.parse(std.testing.allocator, script_source);
    defer script.deinit();

    try std.testing.expectEqual(@as(usize, 3), script.entries.items.len);
    try std.testing.expectEqual(@as(u64, 5), script.entries.items[0].tick);
    try std.testing.expectEqual(TasCommand.keydown, std.meta.activeTag(script.entries.items[0].command));
    try std.testing.expectEqual(TasCommand.keyup, std.meta.activeTag(script.entries.items[1].command));
    try std.testing.expectEqual(@as(f32, -2), script.entries.items[2].command.mouse_move.dy);
}

test "TAS to events conversion" {
    const script_source =
        \\0 keydown W
        \\60 keyup W
    ;

    var script = try TasScript.parse(std.testing.allocator, script_source);
    defer script.deinit();

    var events = try script.toEvents(120);
    defer events.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), events.items.len);
    try std.testing.expectEqual(@as(u64, 0), events.items[0].tick_id);
    try std.testing.expectEqual(@as(u64, 60), events.items[1].tick_id);
}

test "keyFromString knows the punctuation and navigation keys" {
    try std.testing.expectEqual(Key.Grave, try keyFromString("Grave"));
    try std.testing.expectEqual(Key.Slash, try keyFromString("Slash"));
    try std.testing.expectEqual(Key.PageDown, try keyFromString("PageDown"));
    try std.testing.expectError(error.InvalidKey, keyFromString("Unknown"));
}

test "TAS gamepad commands (REQ-INPUT-005)" {
    var script = try TasScript.parse(std.testing.allocator,
        \\10 gamepad_down south
        \\12 gamepad_up south 3
        \\14 gamepad_axis left_y -0.5
        \\16 gamepad_axis right_trigger 1 2
    );
    defer script.deinit();
    var events = try script.toEvents(120);
    defer events.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), events.items.len);
    const down = events.items[0].payload.gamepad_button;
    try std.testing.expectEqual(GamepadButton.south, down.button);
    try std.testing.expect(down.down);
    try std.testing.expectEqual(@as(u8, 0), down.pad);
    const up = events.items[1].payload.gamepad_button;
    try std.testing.expect(!up.down);
    try std.testing.expectEqual(@as(u8, 3), up.pad);
    const axis = events.items[2].payload.gamepad_axis;
    try std.testing.expectEqual(GamepadAxis.left_y, axis.axis);
    try std.testing.expectEqual(@as(f32, -0.5), axis.value);
    try std.testing.expectEqual(@as(u8, 2), events.items[3].payload.gamepad_axis.pad);
}
