//! The command line of each demo (REQ-DEMO-001).
//!
//! ```
//! <demo> [--tas <file>] [--preset low|medium|high] [--capture <dir>]
//!        [--check] [--update] [--hashes <file>]
//! ```
//!
//! - `--tas <file>`: play this script. Default: the script of the demo.
//! - `--preset`: the quality preset. Default: medium.
//! - `--capture <dir>`: no window. Write each frame on the fixed timestep
//!   to `<dir>/frames.bgra`, and the size to `<dir>/info.txt`.
//! - `--check`: no window. Hash the frame at each checkpoint, and compare
//!   the hashes with the committed hash file.
//! - `--update`: with `--check`, write the hash file.
//! - `--hashes <file>`: the hash file. Default:
//!   `demos/<name>/hashes/lavapipe-<preset>.txt`.

const std = @import("std");

pub const Preset = enum { low, medium, high };

pub const Options = struct {
    tas_path: ?[]const u8 = null,
    preset: Preset = .medium,
    capture_dir: ?[]const u8 = null,
    check: bool = false,
    update: bool = false,
    hashes_path: ?[]const u8 = null,

    /// True when the frames must not depend on the wall clock: capture and
    /// check runs (REQ-DEMO-004).
    pub fn deterministic(self: Options) bool {
        return self.check or self.capture_dir != null;
    }
};

pub const Error = error{ UnknownFlag, MissingValue, BadPreset, UpdateNeedsCheck };

pub const usage =
    \\usage: <demo> [--tas <file>] [--preset low|medium|high] [--capture <dir>]
    \\              [--check] [--update] [--hashes <file>]
;

/// Parse the arguments after the program name.
pub fn parse(args: []const []const u8) Error!Options {
    var o: Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--check")) {
            o.check = true;
        } else if (std.mem.eql(u8, a, "--update")) {
            o.update = true;
        } else if (std.mem.eql(u8, a, "--tas") or std.mem.eql(u8, a, "--preset") or
            std.mem.eql(u8, a, "--capture") or std.mem.eql(u8, a, "--hashes"))
        {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            const v = args[i];
            if (std.mem.eql(u8, a, "--tas")) o.tas_path = v;
            if (std.mem.eql(u8, a, "--capture")) o.capture_dir = v;
            if (std.mem.eql(u8, a, "--hashes")) o.hashes_path = v;
            if (std.mem.eql(u8, a, "--preset")) o.preset = std.meta.stringToEnum(Preset, v) orelse return error.BadPreset;
        } else return error.UnknownFlag;
    }
    if (o.update and !o.check) return error.UpdateNeedsCheck;
    return o;
}

const testing = std.testing;

test "cli: each flag (REQ-DEMO-001)" {
    const o = try parse(&.{ "--tas", "a.tas", "--preset", "high", "--capture", "out", "--check", "--update", "--hashes", "h.txt" });
    try testing.expectEqualStrings("a.tas", o.tas_path.?);
    try testing.expectEqual(Preset.high, o.preset);
    try testing.expectEqualStrings("out", o.capture_dir.?);
    try testing.expect(o.check and o.update and o.deterministic());
    try testing.expectEqualStrings("h.txt", o.hashes_path.?);
    const d = try parse(&.{});
    try testing.expectEqual(Preset.medium, d.preset);
    try testing.expect(!d.deterministic());
    try testing.expectError(error.BadPreset, parse(&.{ "--preset", "ultra" }));
    try testing.expectError(error.MissingValue, parse(&.{"--tas"}));
    try testing.expectError(error.UnknownFlag, parse(&.{"--fast"}));
    try testing.expectError(error.UpdateNeedsCheck, parse(&.{"--update"}));
}
