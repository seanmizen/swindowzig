//! The demo script: a text file that drives a demo on the fixed timestep
//! (REQ-DEMO-002).
//!
//! Each line is `<tick> <command> [arguments]`. The tick is an absolute
//! tick number, or `+N`: N ticks after the tick of the line before. A `#`
//! starts a comment line. The commands:
//!
//! ```
//! 0    caption Anti-aliasing: off      # the caption text (rest of the line)
//! 0    set aa off                      # change one named setting
//! +90  checkpoint aa_off               # hash this frame (check mode)
//! +30  end                             # the script stops here
//! ```
//!
//! A demo that takes input also reads the input commands. Each one gives
//! the demo an input event on its tick, as if a player pressed a key
//! (`demos/common/input_script.zig` makes the events):
//!
//! ```
//! 0   key Down              # press and release a key in this tick
//! 0   key Shift down        # hold a key: down, then later up
//! 0   text Daisy            # type text (UTF-8)
//! 0   pad south             # a gamepad button: press, down or up
//! 0   axis right_x 0.4      # a gamepad axis value
//! 0   mouse move 400 300    # the pointer, in layout units of the demo
//! 0   mouse left down       # a mouse button: press, down or up
//! 0   wheel -2              # the wheel, in lines
//! ```
//!
//! The script has no clock. A demo gives the tick, and the script gives
//! the commands of that tick, so two runs of one script are equal.
//! The parser keeps slices into the source text: the source must stay
//! valid while the script exists.

const std = @import("std");

pub const Command = union(enum) {
    /// Show this text as the caption. An empty text removes the caption.
    caption: []const u8,
    /// Change the setting `name` to `value`.
    set: struct { name: []const u8, value: []const u8 },
    /// Hash the frame of this tick under this name.
    checkpoint: []const u8,
    /// An input event for a demo that takes input. The parser checks the
    /// device word only. `input_script.zig` reads the arguments.
    input: Input,
    /// The end of the script.
    end,
};

/// The input devices of an `input` command.
pub const Device = enum { key, text, pad, axis, mouse, wheel };

pub const Input = struct {
    device: Device,
    /// The rest of the line: the key name and the action, the text, ...
    args: []const u8,
};

pub const Entry = struct {
    tick: u64,
    command: Command,
    /// The line number in the source, from 1, for error messages.
    line: u32,
};

pub const ParseError = error{
    MissingTick,
    BadTick,
    TickGoesBack,
    UnknownCommand,
    MissingArgument,
    CommandAfterEnd,
    OutOfMemory,
};

/// Where a parse failed: the line number (from 1) and the error.
pub const Diagnostic = struct {
    line: u32 = 0,
};

pub const Script = struct {
    entries: []Entry,
    /// The tick of the `end` command. Null: the script has no `end`, and
    /// it stops after the last entry.
    end_tick: ?u64,

    pub fn deinit(self: *Script, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        self.* = undefined;
    }

    /// The last tick of the script: the `end` tick, or the tick of the last
    /// entry.
    pub fn lastTick(self: Script) u64 {
        if (self.end_tick) |t| return t;
        if (self.entries.len == 0) return 0;
        return self.entries[self.entries.len - 1].tick;
    }

    /// The number of `checkpoint` commands.
    pub fn checkpointCount(self: Script) usize {
        var n: usize = 0;
        for (self.entries) |e| {
            if (e.command == .checkpoint) n += 1;
        }
        return n;
    }
};

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}

/// Split off the first word of `s`. Give the word and the rest.
fn word(s: []const u8) struct { []const u8, []const u8 } {
    const t = trim(s);
    const end = std.mem.indexOfAny(u8, t, " \t") orelse t.len;
    return .{ t[0..end], trim(t[end..]) };
}

/// Parse a script. On an error, `diag.line` names the line.
pub fn parse(allocator: std.mem.Allocator, source: []const u8, diag: *Diagnostic) ParseError!Script {
    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(allocator);
    var last_tick: u64 = 0;
    var end_tick: ?u64 = null;
    var line_no: u32 = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        line_no += 1;
        diag.line = line_no;
        const line = trim(raw);
        if (line.len == 0 or line[0] == '#') continue;
        if (end_tick != null) return error.CommandAfterEnd;
        const tick_word, const rest = word(line);
        if (tick_word.len == 0) return error.MissingTick;
        const tick: u64 = if (tick_word[0] == '+')
            last_tick + (std.fmt.parseInt(u64, tick_word[1..], 10) catch return error.BadTick)
        else
            std.fmt.parseInt(u64, tick_word, 10) catch return error.BadTick;
        if (tick < last_tick) return error.TickGoesBack;
        last_tick = tick;
        const name, const args = word(rest);
        const command: Command = if (std.mem.eql(u8, name, "caption"))
            .{ .caption = args }
        else if (std.mem.eql(u8, name, "set")) blk: {
            const setting, const value = word(args);
            if (setting.len == 0 or value.len == 0) return error.MissingArgument;
            break :blk .{ .set = .{ .name = setting, .value = value } };
        } else if (std.mem.eql(u8, name, "checkpoint")) blk: {
            if (args.len == 0) return error.MissingArgument;
            break :blk .{ .checkpoint = args };
        } else if (std.meta.stringToEnum(Device, name)) |device| blk: {
            if (args.len == 0) return error.MissingArgument;
            break :blk .{ .input = .{ .device = device, .args = args } };
        } else if (std.mem.eql(u8, name, "end")) blk: {
            end_tick = tick;
            break :blk .end;
        } else return error.UnknownCommand;
        try entries.append(allocator, .{ .tick = tick, .command = command, .line = line_no });
    }
    diag.line = 0;
    return .{ .entries = try entries.toOwnedSlice(allocator), .end_tick = end_tick };
}

/// Plays a script tick by tick.
pub const Player = struct {
    script: *const Script,
    next_index: usize = 0,

    /// The next command at `tick` or before it, or null. Call it in a loop
    /// for each tick, from tick 0 up.
    pub fn next(self: *Player, tick: u64) ?Entry {
        if (self.next_index >= self.script.entries.len) return null;
        const e = self.script.entries[self.next_index];
        if (e.tick > tick) return null;
        self.next_index += 1;
        return e;
    }

    /// True after the last entry (or the `end`) has run.
    pub fn finished(self: Player) bool {
        return self.next_index >= self.script.entries.len;
    }

    /// Play the script again from tick 0.
    pub fn restart(self: *Player) void {
        self.next_index = 0;
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "script: absolute and relative ticks, each command (REQ-DEMO-002)" {
    const src =
        \\# a comment
        \\0 caption Anti-aliasing: off
        \\0 set aa off
        \\+90 checkpoint aa_off
        \\
        \\200 set exposure 1.5
        \\+10 caption
        \\+5 end
    ;
    var diag: Diagnostic = .{};
    var s = try parse(testing.allocator, src, &diag);
    defer s.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 6), s.entries.len);
    try testing.expectEqualStrings("Anti-aliasing: off", s.entries[0].command.caption);
    try testing.expectEqualStrings("aa", s.entries[1].command.set.name);
    try testing.expectEqualStrings("off", s.entries[1].command.set.value);
    try testing.expectEqual(@as(u64, 90), s.entries[2].tick);
    try testing.expectEqualStrings("aa_off", s.entries[2].command.checkpoint);
    try testing.expectEqual(@as(u64, 200), s.entries[3].tick);
    try testing.expectEqualStrings("", s.entries[4].command.caption);
    try testing.expectEqual(@as(u64, 210), s.entries[4].tick);
    try testing.expectEqual(@as(?u64, 215), s.end_tick);
    try testing.expectEqual(@as(u64, 215), s.lastTick());
    try testing.expectEqual(@as(usize, 1), s.checkpointCount());
}

test "script: input commands keep the device and the arguments (REQ-DEMO-008)" {
    var diag: Diagnostic = .{};
    var s = try parse(testing.allocator, "0 key Down\n+5 text Daisy May\n+5 mouse move 10 20\n", &diag);
    defer s.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), s.entries.len);
    try testing.expectEqual(Device.key, s.entries[0].command.input.device);
    try testing.expectEqualStrings("Down", s.entries[0].command.input.args);
    try testing.expectEqualStrings("Daisy May", s.entries[1].command.input.args);
    try testing.expectEqual(@as(u64, 10), s.entries[2].tick);
    try testing.expectEqualStrings("move 10 20", s.entries[2].command.input.args);
    try testing.expectError(error.MissingArgument, parse(testing.allocator, "0 key\n", &diag));
}

test "script: errors name the line (REQ-DEMO-002)" {
    var diag: Diagnostic = .{};
    try testing.expectError(error.TickGoesBack, parse(testing.allocator, "10 caption a\n5 caption b\n", &diag));
    try testing.expectEqual(@as(u32, 2), diag.line);
    try testing.expectError(error.UnknownCommand, parse(testing.allocator, "0 jump\n", &diag));
    try testing.expectError(error.MissingArgument, parse(testing.allocator, "0 set aa\n", &diag));
    try testing.expectError(error.BadTick, parse(testing.allocator, "x caption a\n", &diag));
    try testing.expectError(error.CommandAfterEnd, parse(testing.allocator, "0 end\n1 caption a\n", &diag));
}

test "script: the player gives each command at its tick, one time (REQ-DEMO-002)" {
    var diag: Diagnostic = .{};
    var s = try parse(testing.allocator, "0 caption a\n2 caption b\n2 checkpoint c\n4 end\n", &diag);
    defer s.deinit(testing.allocator);
    var p: Player = .{ .script = &s };
    var seen: [5]u32 = @splat(0);
    for (0..5) |t| {
        while (p.next(t)) |_| seen[t] += 1;
    }
    try testing.expectEqualSlices(u32, &.{ 1, 0, 2, 0, 1 }, &seen);
    try testing.expect(p.finished());
    p.restart();
    try testing.expectEqualStrings("a", p.next(0).?.command.caption);
}
