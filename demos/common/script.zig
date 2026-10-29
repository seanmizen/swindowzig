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
//! Input commands drive a demo as a player would (REQ-DEMO-025). The
//! input stays as the script left it until the next command:
//!
//! ```
//! 0    key W down                      # a key of sw_core KeyCode
//! +60  key W up
//! +1   mouse 40 -5                     # a mouse move of dx, dy pixels
//! +1   button left down                # a mouse button: left or right
//! +10  button left up
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
    /// The end of the script.
    end,
    /// A key goes down or up. `name` is a tag of sw_core `KeyCode`. The
    /// demo frame checks the name.
    key: struct { name: []const u8, down: bool },
    /// The mouse moves by dx, dy pixels in this tick.
    mouse: struct { dx: f32, dy: f32 },
    /// A mouse button goes down or up.
    button: struct { button: MouseButton, down: bool },
};

pub const MouseButton = enum { left, right };

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
    BadArgument,
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

fn downUp(s: []const u8) ParseError!bool {
    if (std.mem.eql(u8, s, "down")) return true;
    if (std.mem.eql(u8, s, "up")) return false;
    return error.BadArgument;
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
        } else if (std.mem.eql(u8, name, "key")) blk: {
            const key, const state = word(args);
            if (key.len == 0 or state.len == 0) return error.MissingArgument;
            break :blk .{ .key = .{ .name = key, .down = try downUp(state) } };
        } else if (std.mem.eql(u8, name, "mouse")) blk: {
            const dx, const dy = word(args);
            if (dx.len == 0 or dy.len == 0) return error.MissingArgument;
            break :blk .{ .mouse = .{
                .dx = std.fmt.parseFloat(f32, dx) catch return error.BadArgument,
                .dy = std.fmt.parseFloat(f32, dy) catch return error.BadArgument,
            } };
        } else if (std.mem.eql(u8, name, "button")) blk: {
            const b, const state = word(args);
            if (b.len == 0 or state.len == 0) return error.MissingArgument;
            const button = std.meta.stringToEnum(MouseButton, b) orelse return error.BadArgument;
            break :blk .{ .button = .{ .button = button, .down = try downUp(state) } };
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

test "script: errors name the line (REQ-DEMO-002)" {
    var diag: Diagnostic = .{};
    try testing.expectError(error.TickGoesBack, parse(testing.allocator, "10 caption a\n5 caption b\n", &diag));
    try testing.expectEqual(@as(u32, 2), diag.line);
    try testing.expectError(error.UnknownCommand, parse(testing.allocator, "0 jump\n", &diag));
    try testing.expectError(error.MissingArgument, parse(testing.allocator, "0 set aa\n", &diag));
    try testing.expectError(error.BadTick, parse(testing.allocator, "x caption a\n", &diag));
    try testing.expectError(error.CommandAfterEnd, parse(testing.allocator, "0 end\n1 caption a\n", &diag));
}

test "script: the input commands (REQ-DEMO-025)" {
    var diag: Diagnostic = .{};
    var s = try parse(testing.allocator, "0 key W down\n+5 mouse 12.5 -3\n+1 button left down\n+1 button right up\n+1 key LeftShift up\n", &diag);
    defer s.deinit(testing.allocator);
    try testing.expectEqualStrings("W", s.entries[0].command.key.name);
    try testing.expect(s.entries[0].command.key.down);
    try testing.expectEqual(@as(f32, 12.5), s.entries[1].command.mouse.dx);
    try testing.expectEqual(@as(f32, -3), s.entries[1].command.mouse.dy);
    try testing.expectEqual(MouseButton.left, s.entries[2].command.button.button);
    try testing.expect(!s.entries[3].command.button.down);
    try testing.expect(!s.entries[4].command.key.down);
    try testing.expectError(error.BadArgument, parse(testing.allocator, "0 key W sideways\n", &diag));
    try testing.expectError(error.BadArgument, parse(testing.allocator, "0 button middle down\n", &diag));
    try testing.expectError(error.MissingArgument, parse(testing.allocator, "0 mouse 4\n", &diag));
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
