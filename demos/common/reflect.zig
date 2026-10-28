//! Set a field of a settings struct by its name and a text value. A demo
//! script uses it for `set <name> <value>` (REQ-DEMO-002).
//!
//! A bool takes `on`, `off`, `true`, `false`, `1` or `0`. An enum takes the
//! name of a tag. A float and an integer take a number.

const std = @import("std");

pub const Error = error{ UnknownSetting, BadValue };

/// Set the field `name` of `settings` to `value`.
pub fn setField(comptime T: type, settings: *T, name: []const u8, value: []const u8) Error!void {
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |fname, ftype| {
        if (std.mem.eql(u8, fname, name)) {
            @field(settings, fname) = try parseValue(ftype, value);
            return;
        }
    }
    return error.UnknownSetting;
}

/// Parse `value` as a value of type `V`.
pub fn parseValue(comptime V: type, value: []const u8) Error!V {
    switch (@typeInfo(V)) {
        .bool => {
            for ([_][]const u8{ "on", "true", "1" }) |s| if (std.mem.eql(u8, value, s)) return true;
            for ([_][]const u8{ "off", "false", "0" }) |s| if (std.mem.eql(u8, value, s)) return false;
            return error.BadValue;
        },
        .@"enum" => return std.meta.stringToEnum(V, value) orelse error.BadValue,
        .float => return std.fmt.parseFloat(V, value) catch error.BadValue,
        .int => return std.fmt.parseInt(V, value, 10) catch error.BadValue,
        else => @compileError("reflect: no text form for " ++ @typeName(V)),
    }
}

/// Write the value of the field `name` as text. Give null for an unknown name.
pub fn fieldText(comptime T: type, settings: T, name: []const u8, buf: []u8) ?[]const u8 {
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |fname, ftype| {
        if (std.mem.eql(u8, fname, name)) {
            const v = @field(settings, fname);
            return switch (@typeInfo(ftype)) {
                .bool => if (v) "on" else "off",
                .@"enum" => @tagName(v),
                .float => std.fmt.bufPrint(buf, "{d:.2}", .{v}) catch null,
                .int => std.fmt.bufPrint(buf, "{d}", .{v}) catch null,
                else => null,
            };
        }
    }
    return null;
}

const testing = std.testing;

test "reflect: set a bool, an enum, a float and an int by name (REQ-DEMO-002)" {
    const S = struct {
        on: bool = false,
        mode: enum { a, b } = .a,
        level: f32 = 1,
        count: u32 = 0,
    };
    var s: S = .{};
    try setField(S, &s, "on", "on");
    try setField(S, &s, "mode", "b");
    try setField(S, &s, "level", "0.5");
    try setField(S, &s, "count", "3");
    try testing.expect(s.on);
    try testing.expectEqual(.b, s.mode);
    try testing.expectEqual(@as(f32, 0.5), s.level);
    try testing.expectEqual(@as(u32, 3), s.count);
    try testing.expectError(error.UnknownSetting, setField(S, &s, "nope", "1"));
    try testing.expectError(error.BadValue, setField(S, &s, "mode", "c"));
    try testing.expectError(error.BadValue, setField(S, &s, "on", "maybe"));
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("b", fieldText(S, s, "mode", &buf).?);
    try testing.expectEqualStrings("0.50", fieldText(S, s, "level", &buf).?);
}
