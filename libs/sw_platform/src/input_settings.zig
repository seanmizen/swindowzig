// Save and load the input settings of a game: the action bindings and the
// mouse settings of a `sw_core.ActionMap`. The text format is
// `ActionMap.encode`. Storage keeps it under one key (REQ-INPUT-004).
//
//   try input_settings.save(allocator, "controls", &map);
//   _ = try input_settings.load(allocator, "controls", &map);
const std = @import("std");
const storage = @import("storage.zig");

pub const Error = storage.Error;

/// Write the bindings and the mouse settings of `map` (a pointer to an
/// `ActionMap`) to `key`.
pub fn save(allocator: std.mem.Allocator, key: []const u8, map: anytype) Error!void {
    const text = try map.encode(allocator);
    defer allocator.free(text);
    return storage.storageSet(key, text);
}

/// Read `key` into `map` (a pointer to an `ActionMap`). Returns false when
/// the key is not set, or when the value is not input settings. Then `map`
/// does not change, and it keeps its defaults.
pub fn load(allocator: std.mem.Allocator, key: []const u8, map: anytype) Error!bool {
    const text = (try storage.storageGet(allocator, key)) orelse return false;
    defer allocator.free(text);
    map.decode(text) catch return false;
    return true;
}

test "input settings: save, then load into a new map" {
    if (@import("builtin").target.cpu.arch == .wasm32) return error.SkipZigTest;
    const core = @import("sw_core");
    const Action = enum { jump, fire };
    const defaults: core.ActionMap(Action).Defaults = .{
        .jump = &.{core.Binding.key(.Space)},
        .fire = &.{core.Binding.mouse(.left)},
    };
    const a = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    storage.useDirectory(tmp.dir, std.testing.io);

    var map = core.ActionMap(Action).init(defaults);
    try std.testing.expect(!try load(a, "controls", &map));

    map.bind(.jump, 0, core.Binding.key(.J).withMods(.{ .ctrl = true }));
    map.mouse.setSensitivity(3);
    map.mouse.invert_y = true;
    try save(a, "controls", &map);

    var loaded = core.ActionMap(Action).init(defaults);
    try std.testing.expect(try load(a, "controls", &loaded));
    try std.testing.expect(loaded.bindings(.jump)[0].eql(core.Binding.key(.J).withMods(.{ .ctrl = true })));
    try std.testing.expect(loaded.isDefault(.fire));
    try std.testing.expectEqual(@as(f32, 3), loaded.mouse.sensitivity);
    try std.testing.expect(loaded.mouse.invert_y);

    // A value that is not input settings does not change the map.
    try storage.storageSet("controls", "not settings");
    var other = core.ActionMap(Action).init(defaults);
    try std.testing.expect(!try load(a, "controls", &other));
    try std.testing.expect(other.isDefault(.jump));
}
