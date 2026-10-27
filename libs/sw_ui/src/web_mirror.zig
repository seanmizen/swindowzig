//! The web mirror of the semantic tree (REQ-A11Y-001). On the web build,
//! `Ui.finish` encodes the semantic tree into bytes and gives them to
//! `backends/wasm/a11y.ts`. That file keeps hidden DOM elements in sync with
//! the tree, so a screen reader can read a canvas UI.
//!
//! The encoder sends the full tree, but only when its bytes change
//! (REQ-A11Y-005). An unchanged frame costs one encode and one hash. The
//! tree of a menu is a few hundred bytes.
//!
//! The wire format. All integers are little-endian:
//!
//! ```
//! u32 node_count
//! then, for each node in tree order (node 0 is the root):
//!   u32 id
//!   u8  role         (see `roleCode`)
//!   u8  flags        (bit 0 focused, bit 1 disabled, bit 2 selected,
//!                     bit 3 live, bit 4 range)
//!   u32 name_len,  then name_len bytes of UTF-8
//!   u32 value_len, then value_len bytes of UTF-8
//!   u32 description_len, then description_len bytes of UTF-8
//!   u32 child_count, then child_count u32 indices into the node list
//!   if flag bit 4: f32 value, f32 min, f32 max
//! ```
//!
//! The bounds and the `changed` flag of a node are not sent. The DOM is
//! visually hidden, so it needs no bounds. The browser announces a change of
//! a live region itself.
//!
//! The JS side is a singleton: with two `Ui` values, the tree of the last
//! `finish` replaces the other tree. Set `WebMirror.enabled` to false on a
//! `Ui` that must not be mirrored.

const std = @import("std");
const builtin = @import("builtin");
const semantic = @import("semantic.zig");

const SemanticTree = semantic.SemanticTree;
const Role = semantic.Role;

/// True for the wasm build. Only that build sends the tree to JS.
pub const is_web = builtin.cpu.arch.isWasm();

pub const flag_focused: u8 = 1 << 0;
pub const flag_disabled: u8 = 1 << 1;
pub const flag_selected: u8 = 1 << 2;
pub const flag_live: u8 = 1 << 3;
pub const flag_range: u8 = 1 << 4;

/// The role byte of the wire format. `backends/wasm/a11y.ts` has the same
/// table. A change here needs the same change there. Each widget has its own
/// role (REQ-A11Y-006).
pub fn roleCode(role: Role) u8 {
    return switch (role) {
        .group => 0,
        .text => 1,
        .button => 2,
        .list => 3,
        .list_item => 4,
        .text_field => 5,
        .image => 6,
        .slider => 7,
        .dialog => 8,
        .tooltip => 9,
    };
}

fn appendU32(alloc: std.mem.Allocator, out: *std.ArrayList(u8), v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try out.appendSlice(alloc, &b);
}

fn appendBytes(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try appendU32(alloc, out, @intCast(s.len));
    try out.appendSlice(alloc, s);
}

/// Append the wire format of `tree` to `out`.
pub fn encode(alloc: std.mem.Allocator, out: *std.ArrayList(u8), tree: SemanticTree) std.mem.Allocator.Error!void {
    try appendU32(alloc, out, @intCast(tree.nodes.len));
    for (tree.nodes) |n| {
        try appendU32(alloc, out, n.id);
        var flags: u8 = 0;
        if (n.focused) flags |= flag_focused;
        if (n.disabled) flags |= flag_disabled;
        if (n.selected) flags |= flag_selected;
        if (n.live) flags |= flag_live;
        if (n.range != null) flags |= flag_range;
        try out.appendSlice(alloc, &.{ roleCode(n.role), flags });
        try appendBytes(alloc, out, n.name);
        try appendBytes(alloc, out, n.value);
        try appendBytes(alloc, out, n.description);
        try appendU32(alloc, out, @intCast(n.children.len));
        for (n.children) |c| try appendU32(alloc, out, c);
        if (n.range) |r| {
            for ([_]f32{ r.value, r.min, r.max }) |v| try appendU32(alloc, out, @bitCast(v));
        }
    }
}

/// The JS import. `len` 0 removes the mirror.
const js = struct {
    extern "a11y" fn jsA11yUpdate(ptr: [*]const u8, len: usize) void;
};

pub const WebMirror = struct {
    /// When false, `publish` sends nothing.
    enabled: bool = true,
    buf: std.ArrayList(u8) = .empty,
    /// The hash of the last bytes that `update` returned as changed.
    last_hash: ?u64 = null,

    pub fn deinit(self: *WebMirror, alloc: std.mem.Allocator) void {
        self.buf.deinit(alloc);
    }

    /// Encode `tree` into `bytes()`. Return true when the bytes are not the
    /// bytes of the last call that returned true.
    pub fn update(self: *WebMirror, alloc: std.mem.Allocator, tree: SemanticTree) std.mem.Allocator.Error!bool {
        self.buf.clearRetainingCapacity();
        try encode(alloc, &self.buf, tree);
        const hash = std.hash.Wyhash.hash(0, self.buf.items);
        if (self.last_hash == hash) return false;
        self.last_hash = hash;
        return true;
    }

    /// The bytes of the last `update`.
    pub fn bytes(self: *const WebMirror) []const u8 {
        return self.buf.items;
    }

    /// On the web build, send `tree` to JS when it changed. On other builds,
    /// do nothing.
    pub fn publish(self: *WebMirror, alloc: std.mem.Allocator, tree: SemanticTree) std.mem.Allocator.Error!void {
        if (comptime !is_web) return;
        if (!self.enabled) return;
        if (try self.update(alloc, tree)) js.jsA11yUpdate(self.buf.items.ptr, self.buf.items.len);
    }

    /// On the web build, remove the mirror if this value made one.
    pub fn clear(self: *WebMirror) void {
        if (comptime !is_web) return;
        if (self.last_hash == null) return;
        self.last_hash = null;
        js.jsA11yUpdate(self.buf.items.ptr, 0);
    }
};

// ---- Tests ----------------------------------------------------------------

const SemanticNode = semantic.SemanticNode;

fn testNode(id: u32, role: Role, name: []const u8, children: []const u32) SemanticNode {
    return .{
        .id = id,
        .role = role,
        .name = name,
        .value = "",
        .focused = false,
        .disabled = false,
        .selected = false,
        .live = false,
        .changed = false,
        .bounds = .{},
        .children = children,
    };
}

fn readU32(b: []const u8, at: *usize) u32 {
    const v = std.mem.readInt(u32, b[at.*..][0..4], .little);
    at.* += 4;
    return v;
}

test "web mirror: the role codes are fixed" {
    // a11y.ts reads these numbers.
    try std.testing.expectEqual(@as(u8, 0), roleCode(.group));
    try std.testing.expectEqual(@as(u8, 1), roleCode(.text));
    try std.testing.expectEqual(@as(u8, 2), roleCode(.button));
    try std.testing.expectEqual(@as(u8, 3), roleCode(.list));
    try std.testing.expectEqual(@as(u8, 4), roleCode(.list_item));
    try std.testing.expectEqual(@as(u8, 5), roleCode(.text_field));
    try std.testing.expectEqual(@as(u8, 6), roleCode(.image));
    try std.testing.expectEqual(@as(u8, 7), roleCode(.slider));
    try std.testing.expectEqual(@as(u8, 8), roleCode(.dialog));
    try std.testing.expectEqual(@as(u8, 9), roleCode(.tooltip));
}

test "web mirror: encode gives the wire format" {
    const alloc = std.testing.allocator;
    var field = testNode(9, .text_field, "Name", &.{});
    field.value = "h\u{e9}";
    field.focused = true;
    var status = testNode(5, .text, "Accent: Green", &.{});
    status.live = true;
    status.changed = true;
    const nodes = [_]SemanticNode{
        testNode(0, .group, "", &.{ 1, 2 }),
        field,
        status,
    };

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try encode(alloc, &out, .{ .nodes = &nodes });
    const b = out.items;

    var at: usize = 0;
    try std.testing.expectEqual(@as(u32, 3), readU32(b, &at));

    // The root: a group with two children.
    try std.testing.expectEqual(@as(u32, 0), readU32(b, &at));
    try std.testing.expectEqual(@as(u8, 0), b[at]);
    try std.testing.expectEqual(@as(u8, 0), b[at + 1]);
    at += 2;
    try std.testing.expectEqual(@as(u32, 0), readU32(b, &at));
    try std.testing.expectEqual(@as(u32, 0), readU32(b, &at));
    try std.testing.expectEqual(@as(u32, 0), readU32(b, &at));
    try std.testing.expectEqual(@as(u32, 2), readU32(b, &at));
    try std.testing.expectEqual(@as(u32, 1), readU32(b, &at));
    try std.testing.expectEqual(@as(u32, 2), readU32(b, &at));

    // The text field: focused, with a name and a UTF-8 value.
    try std.testing.expectEqual(@as(u32, 9), readU32(b, &at));
    try std.testing.expectEqual(@as(u8, 5), b[at]);
    try std.testing.expectEqual(flag_focused, b[at + 1]);
    at += 2;
    try std.testing.expectEqual(@as(u32, 4), readU32(b, &at));
    try std.testing.expectEqualStrings("Name", b[at..][0..4]);
    at += 4;
    try std.testing.expectEqual(@as(u32, 3), readU32(b, &at));
    try std.testing.expectEqualStrings("h\u{e9}", b[at..][0..3]);
    at += 3;
    try std.testing.expectEqual(@as(u32, 0), readU32(b, &at));
    try std.testing.expectEqual(@as(u32, 0), readU32(b, &at));

    // The live text. The changed flag is not sent.
    try std.testing.expectEqual(@as(u32, 5), readU32(b, &at));
    try std.testing.expectEqual(@as(u8, 1), b[at]);
    try std.testing.expectEqual(flag_live, b[at + 1]);
    at += 2;
    const name_len = readU32(b, &at);
    try std.testing.expectEqualStrings("Accent: Green", b[at..][0..name_len]);
    at += name_len;
    try std.testing.expectEqual(@as(u32, 0), readU32(b, &at));
    try std.testing.expectEqual(@as(u32, 0), readU32(b, &at));
    try std.testing.expectEqual(@as(u32, 0), readU32(b, &at));
    try std.testing.expectEqual(b.len, at);
}

test "web mirror: a slider sends its description and its range" {
    const alloc = std.testing.allocator;
    var slider = testNode(4, .slider, "Volume", &.{});
    slider.value = "0.5";
    slider.description = "Sound level";
    slider.range = .{ .value = 0.5, .min = 0, .max = 1 };
    const nodes = [_]SemanticNode{slider};

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try encode(alloc, &out, .{ .nodes = &nodes });
    const b = out.items;

    var at: usize = 4;
    try std.testing.expectEqual(@as(u32, 4), readU32(b, &at));
    try std.testing.expectEqual(@as(u8, 7), b[at]);
    try std.testing.expectEqual(flag_range, b[at + 1]);
    at += 2;
    const name_len = readU32(b, &at);
    try std.testing.expectEqualStrings("Volume", b[at..][0..name_len]);
    at += name_len;
    const value_len = readU32(b, &at);
    try std.testing.expectEqualStrings("0.5", b[at..][0..value_len]);
    at += value_len;
    const desc_len = readU32(b, &at);
    try std.testing.expectEqualStrings("Sound level", b[at..][0..desc_len]);
    at += desc_len;
    try std.testing.expectEqual(@as(u32, 0), readU32(b, &at));
    try std.testing.expectEqual(@as(f32, 0.5), @as(f32, @bitCast(readU32(b, &at))));
    try std.testing.expectEqual(@as(f32, 0), @as(f32, @bitCast(readU32(b, &at))));
    try std.testing.expectEqual(@as(f32, 1), @as(f32, @bitCast(readU32(b, &at))));
    try std.testing.expectEqual(b.len, at);
}

test "web mirror: update is true only when the tree changes" {
    const alloc = std.testing.allocator;
    var m: WebMirror = .{};
    defer m.deinit(alloc);

    var button = testNode(10, .button, "Play", &.{});
    var nodes = [_]SemanticNode{ testNode(0, .group, "", &.{1}), button };
    try std.testing.expect(try m.update(alloc, .{ .nodes = &nodes }));
    try std.testing.expect(!try m.update(alloc, .{ .nodes = &nodes }));

    // A change of focus is a change.
    button.focused = true;
    nodes[1] = button;
    try std.testing.expect(try m.update(alloc, .{ .nodes = &nodes }));
    try std.testing.expect(!try m.update(alloc, .{ .nodes = &nodes }));

    // The bounds and the changed flag are not sent, so they are no change.
    button.bounds = .{ .x = 4, .y = 4, .w = 10, .h = 10 };
    button.changed = true;
    nodes[1] = button;
    try std.testing.expect(!try m.update(alloc, .{ .nodes = &nodes }));
}
