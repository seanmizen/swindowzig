//! The map from the sw_ui semantic tree to AccessKit nodes (REQ-A11Y-007).
//! This file is plain Zig with no C code, so `zig build test` tests it on
//! each platform. `accesskit.zig` gives the result to accesskit-c.
//!
//! `Snapshot.init` copies a semantic tree into a list of `Node` values. Each
//! value holds the data of one AccessKit node: the role, the label, the value,
//! the bounds in physical pixels, the actions, the live-region setting and the
//! child IDs. The strings end with a zero byte, so C can read them.
//!
//! `diff` compares two snapshots. It gives the nodes that are new or that
//! changed, and tells if the focus moved (REQ-A11Y-008). An AccessKit tree
//! update holds only these nodes. AccessKit removes a node when no parent
//! holds its ID. A removal changes the children of the parent, so the parent
//! is in the diff.
//!
//! The roles (see `roleOf`):
//!
//! - the root node: `window`, with the title of the window as its label
//! - group: `group` when it has a name, `generic_container` when not
//! - text: `label`, with the text in `value` (the AccessKit rule for a label)
//! - button: `button`
//! - list: `list`
//! - list item: `list_item`, with its selected state
//! - text field: `text_input`, with the name as label and the text as value
//! - image: `image`
//! - slider: `slider`, with its numbers
//! - tooltip: `tooltip`
//! - screen: `dialog`, modal
//!
//! A live text is `polite`, as in the web mirror (REQ-A11Y-003). AccessKit
//! tells the screen reader to speak a live node when its text changes in an
//! update.

const std = @import("std");
const semantic = @import("semantic.zig");

const SemanticTree = semantic.SemanticTree;
const SemanticNode = semantic.SemanticNode;

/// The AccessKit role numbers (`accesskit_role` in `accesskit.h`, version
/// 0.23). The C enum has no explicit numbers. `docs/accesskit.md` gives the
/// command that prints them from the header.
pub const Role = enum(u8) {
    unknown = 0,
    label = 3,
    image = 4,
    list_item = 7,
    generic_container = 14,
    text_input = 17,
    button = 18,
    list = 24,
    dialog = 66,
    group = 78,
    slider = 113,
    tooltip = 128,
    window = 133,
};

/// `accesskit_live`.
pub const Live = enum(u8) {
    off = 0,
    polite = 1,
    assertive = 2,
};

/// The AccessKit actions that a node supports. The numbers are
/// `accesskit_action` values.
pub const Action = enum(u8) {
    click = 0,
    focus = 1,
    decrement = 6,
    increment = 7,
};

pub const Actions = packed struct(u8) {
    click: bool = false,
    focus: bool = false,
    decrement: bool = false,
    increment: bool = false,
    _pad: u4 = 0,

    /// The actions in a fixed order.
    pub fn list(self: Actions, out: *[4]Action) []const Action {
        var n: usize = 0;
        if (self.click) {
            out[n] = .click;
            n += 1;
        }
        if (self.focus) {
            out[n] = .focus;
            n += 1;
        }
        if (self.decrement) {
            out[n] = .decrement;
            n += 1;
        }
        if (self.increment) {
            out[n] = .increment;
            n += 1;
        }
        return out[0..n];
    }
};

/// `accesskit_rect`: the left, top, right and bottom edges.
pub const Bounds = struct {
    x0: f64 = 0,
    y0: f64 = 0,
    x1: f64 = 0,
    y1: f64 = 0,
};

pub const Range = struct {
    value: f64,
    min: f64,
    max: f64,
};

/// The data of one AccessKit node.
pub const Node = struct {
    id: u64,
    role: Role,
    label: [:0]const u8 = "",
    value: [:0]const u8 = "",
    description: [:0]const u8 = "",
    bounds: Bounds = .{},
    live: Live = .off,
    disabled: bool = false,
    /// Set for a list item only. Null: the node has no selected state.
    selected: ?bool = null,
    modal: bool = false,
    range: ?Range = null,
    actions: Actions = .{},
    children: []const u64 = &.{},

    /// True when the two nodes give the same AccessKit node.
    pub fn eql(a: *const Node, b: *const Node) bool {
        return a.id == b.id and
            a.role == b.role and
            std.mem.eql(u8, a.label, b.label) and
            std.mem.eql(u8, a.value, b.value) and
            std.mem.eql(u8, a.description, b.description) and
            std.meta.eql(a.bounds, b.bounds) and
            a.live == b.live and
            a.disabled == b.disabled and
            std.meta.eql(a.selected, b.selected) and
            a.modal == b.modal and
            std.meta.eql(a.range, b.range) and
            @as(u8, @bitCast(a.actions)) == @as(u8, @bitCast(b.actions)) and
            std.mem.eql(u64, a.children, b.children);
    }
};

pub const Options = struct {
    /// The label of the root node: the title of the window.
    title: []const u8 = "",
    /// Physical pixels for each logical pixel (the DPI scale). AccessKit
    /// bounds are in physical pixels of the window.
    scale: f32 = 1,
};

/// The AccessKit role of a semantic node.
pub fn roleOf(n: *const SemanticNode) Role {
    return switch (n.role) {
        .group => if (n.name.len > 0) .group else .generic_container,
        .text => .label,
        .button => .button,
        .list => .list,
        .list_item => .list_item,
        .text_field => .text_input,
        .image => .image,
        .slider => .slider,
        .dialog => .dialog,
        .tooltip => .tooltip,
    };
}

/// The actions that a semantic node supports. A disabled node has none.
pub fn actionsOf(n: *const SemanticNode) Actions {
    if (n.disabled) return .{};
    return switch (n.role) {
        .button, .list_item => .{ .click = true, .focus = true },
        .text_field => .{ .focus = true },
        .slider => .{ .focus = true, .increment = true, .decrement = true },
        else => .{},
    };
}

/// A copy of a semantic tree as AccessKit node data. It owns its memory.
pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    nodes: []const Node,
    /// The ID of the root node.
    root: u64,
    /// The ID of the focused node. AccessKit needs a focus at all times, so
    /// with no focused node it is the root: the window has focus.
    focus: u64,

    pub fn init(gpa: std.mem.Allocator, tree: SemanticTree, opts: Options) std.mem.Allocator.Error!Snapshot {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        if (tree.nodes.len == 0) {
            const nodes = try a.alloc(Node, 1);
            nodes[0] = .{ .id = 0, .role = .window, .label = try a.dupeSentinel(u8, opts.title, 0) };
            return .{ .arena = arena, .nodes = nodes, .root = 0, .focus = 0 };
        }

        const nodes = try a.alloc(Node, tree.nodes.len);
        const root = tree.nodes[0].id;
        var focus = root;
        const s: f64 = opts.scale;
        for (tree.nodes, nodes, 0..) |*src, *dst, i| {
            const children = try a.alloc(u64, src.children.len);
            for (src.children, children) |c, *out| out.* = tree.nodes[c].id;
            const b = src.bounds;
            dst.* = .{
                .id = src.id,
                .role = if (i == 0) .window else roleOf(src),
                .description = try a.dupeSentinel(u8, src.description, 0),
                .bounds = .{
                    .x0 = b.x * s,
                    .y0 = b.y * s,
                    .x1 = (b.x + b.w) * s,
                    .y1 = (b.y + b.h) * s,
                },
                .live = if (src.live) .polite else .off,
                .disabled = src.disabled,
                .selected = if (src.role == .list_item) src.selected else null,
                .modal = src.role == .dialog,
                .range = if (src.range) |r| .{ .value = r.value, .min = r.min, .max = r.max } else null,
                .actions = if (i == 0) .{} else actionsOf(src),
                .children = children,
            };
            if (i == 0) {
                dst.label = try a.dupeSentinel(u8, opts.title, 0);
            } else if (src.role == .text) {
                // AccessKit reads the text of a label from its value.
                dst.value = try a.dupeSentinel(u8, src.name, 0);
            } else {
                dst.label = try a.dupeSentinel(u8, src.name, 0);
                dst.value = try a.dupeSentinel(u8, src.value, 0);
            }
            if (src.focused and i != 0) focus = src.id;
        }
        return .{ .arena = arena, .nodes = nodes, .root = root, .focus = focus };
    }

    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// The node with this ID, or null.
    pub fn find(self: *const Snapshot, id: u64) ?*const Node {
        for (self.nodes) |*n| {
            if (n.id == id) return n;
        }
        return null;
    }
};

/// The result of `diff`.
pub const Diff = struct {
    /// Indices into `next.nodes`: the nodes that are new or that changed.
    changed: []const u32,
    /// The focus is not the focus of `prev`.
    focus_changed: bool,

    /// True when AccessKit needs no update.
    pub fn isEmpty(self: Diff) bool {
        return self.changed.len == 0 and !self.focus_changed;
    }
};

/// Compare `next` with `prev` (null: no tree was sent). `out` gets the
/// indices of the nodes to send, and the result points into it.
pub fn diff(
    gpa: std.mem.Allocator,
    prev: ?*const Snapshot,
    next: *const Snapshot,
    out: *std.ArrayList(u32),
) std.mem.Allocator.Error!Diff {
    out.clearRetainingCapacity();
    const old = prev orelse {
        for (0..next.nodes.len) |i| try out.append(gpa, @intCast(i));
        return .{ .changed = out.items, .focus_changed = true };
    };

    var index: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer index.deinit(gpa);
    try index.ensureTotalCapacity(gpa, @intCast(old.nodes.len));
    for (old.nodes, 0..) |n, i| index.putAssumeCapacity(n.id, @intCast(i));

    for (next.nodes, 0..) |*n, i| {
        const same = if (index.get(n.id)) |j| n.eql(&old.nodes[j]) else false;
        if (!same) try out.append(gpa, @intCast(i));
    }
    return .{
        .changed = out.items,
        .focus_changed = next.focus != old.focus or next.root != old.root,
    };
}

// ---- Tests ----------------------------------------------------------------

fn testNode(id: u32, role: semantic.Role, name: []const u8, children: []const u32) SemanticNode {
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

test "accesskit map: each semantic role has its AccessKit role and actions" {
    const t = std.testing;
    var group = testNode(1, .group, "", &.{});
    try t.expectEqual(Role.generic_container, roleOf(&group));
    group.name = "Menu";
    try t.expectEqual(Role.group, roleOf(&group));

    const cases = [_]struct { semantic.Role, Role, Actions }{
        .{ .text, .label, .{} },
        .{ .button, .button, .{ .click = true, .focus = true } },
        .{ .list, .list, .{} },
        .{ .list_item, .list_item, .{ .click = true, .focus = true } },
        .{ .text_field, .text_input, .{ .focus = true } },
        .{ .image, .image, .{} },
        .{ .slider, .slider, .{ .focus = true, .increment = true, .decrement = true } },
        .{ .dialog, .dialog, .{} },
        .{ .tooltip, .tooltip, .{} },
    };
    for (cases) |case| {
        var n = testNode(2, case[0], "x", &.{});
        try t.expectEqual(case[1], roleOf(&n));
        try t.expectEqual(@as(u8, @bitCast(case[2])), @as(u8, @bitCast(actionsOf(&n))));
        n.disabled = true;
        try t.expectEqual(@as(u8, 0), @as(u8, @bitCast(actionsOf(&n))));
    }
}

test "accesskit map: the role and action numbers are the accesskit.h numbers" {
    // accesskit-c 0.23.1. docs/accesskit.md gives the command that prints them.
    const t = std.testing;
    try t.expectEqual(@as(u8, 3), @backingInt(Role.label));
    try t.expectEqual(@as(u8, 18), @backingInt(Role.button));
    try t.expectEqual(@as(u8, 133), @backingInt(Role.window));
    try t.expectEqual(@as(u8, 113), @backingInt(Role.slider));
    try t.expectEqual(@as(u8, 1), @backingInt(Live.polite));
    try t.expectEqual(@as(u8, 1), @backingInt(Action.focus));
    try t.expectEqual(@as(u8, 7), @backingInt(Action.increment));
}

test "accesskit map: a snapshot copies the tree with ids, text, bounds and focus" {
    const t = std.testing;
    var field = testNode(9, .text_field, "Name", &.{});
    field.value = "Ann";
    field.focused = true;
    field.bounds = .{ .x = 10, .y = 20, .w = 100, .h = 30 };
    var status = testNode(5, .text, "Accent: Green", &.{});
    status.live = true;
    var item = testNode(100, .list_item, "Green", &.{});
    item.selected = true;
    var slider = testNode(25, .slider, "Volume", &.{});
    slider.value = "70%";
    slider.range = .{ .value = 0.7, .min = 0, .max = 1 };
    slider.description = "Left and Right change it";
    const nodes = [_]SemanticNode{
        testNode(0, .group, "", &.{ 1, 2, 3, 4, 5 }),
        field,
        status,
        item,
        slider,
        testNode(20, .dialog, "Settings", &.{}),
    };

    var snap = try Snapshot.init(t.allocator, .{ .nodes = &nodes }, .{ .title = "flat2d", .scale = 2 });
    defer snap.deinit();

    try t.expectEqual(@as(usize, 6), snap.nodes.len);
    try t.expectEqual(@as(u64, 0), snap.root);
    try t.expectEqual(@as(u64, 9), snap.focus);

    const root = &snap.nodes[0];
    try t.expectEqual(Role.window, root.role);
    try t.expectEqualStrings("flat2d", root.label);
    try t.expectEqualSlices(u64, &.{ 9, 5, 100, 25, 20 }, root.children);

    const f = snap.find(9).?;
    try t.expectEqual(Role.text_input, f.role);
    try t.expectEqualStrings("Name", f.label);
    try t.expectEqualStrings("Ann", f.value);
    try t.expectEqual(@as(u8, 0), f.value.ptr[f.value.len]);
    try t.expectEqual(Bounds{ .x0 = 20, .y0 = 40, .x1 = 220, .y1 = 100 }, f.bounds);
    try t.expectEqual(@as(?bool, null), f.selected);

    const s = snap.find(5).?;
    try t.expectEqual(Role.label, s.role);
    try t.expectEqualStrings("", s.label);
    try t.expectEqualStrings("Accent: Green", s.value);
    try t.expectEqual(Live.polite, s.live);

    try t.expectEqual(@as(?bool, true), snap.find(100).?.selected);

    const v = snap.find(25).?;
    try t.expectEqual(Range{ .value = @as(f32, 0.7), .min = 0, .max = 1 }, v.range.?);
    try t.expectEqualStrings("70%", v.value);
    try t.expectEqualStrings("Left and Right change it", v.description);

    try t.expect(snap.find(20).?.modal);
}

test "accesskit map: with no focused node, the root has the focus" {
    const t = std.testing;
    const nodes = [_]SemanticNode{ testNode(0, .group, "", &.{1}), testNode(6, .button, "Close", &.{}) };
    var snap = try Snapshot.init(t.allocator, .{ .nodes = &nodes }, .{});
    defer snap.deinit();
    try t.expectEqual(@as(u64, 0), snap.focus);

    var empty = try Snapshot.init(t.allocator, .{ .nodes = &.{} }, .{ .title = "app" });
    defer empty.deinit();
    try t.expectEqual(@as(usize, 1), empty.nodes.len);
    try t.expectEqual(Role.window, empty.nodes[0].role);
}

test "accesskit map: diff gives the new and changed nodes and the focus change" {
    const t = std.testing;
    const alloc = t.allocator;
    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(alloc);

    var status = testNode(5, .text, "Accent: Green", &.{});
    status.live = true;
    var button = testNode(6, .button, "Close", &.{});
    var nodes = [_]SemanticNode{ testNode(0, .group, "", &.{ 1, 2 }), status, button };

    var a = try Snapshot.init(alloc, .{ .nodes = &nodes }, .{});
    defer a.deinit();

    // The first tree: each node, and the focus.
    const first = try diff(alloc, null, &a, &out);
    try t.expectEqualSlices(u32, &.{ 0, 1, 2 }, first.changed);
    try t.expect(first.focus_changed);

    // The same tree: nothing to send.
    var same = try Snapshot.init(alloc, .{ .nodes = &nodes }, .{});
    defer same.deinit();
    try t.expect((try diff(alloc, &a, &same, &out)).isEmpty());

    // The focus moves: no node changes, but the focus does.
    button.focused = true;
    nodes[2] = button;
    var b = try Snapshot.init(alloc, .{ .nodes = &nodes }, .{});
    defer b.deinit();
    const moved = try diff(alloc, &a, &b, &out);
    try t.expectEqual(@as(usize, 0), moved.changed.len);
    try t.expect(moved.focus_changed);
    try t.expectEqual(@as(u64, 6), b.focus);

    // The live text changes: only that node goes to AccessKit, and the
    // screen reader speaks it.
    status.name = "Accent: Orange";
    nodes[1] = status;
    var c = try Snapshot.init(alloc, .{ .nodes = &nodes }, .{});
    defer c.deinit();
    const spoken = try diff(alloc, &b, &c, &out);
    try t.expectEqualSlices(u32, &.{1}, spoken.changed);
    try t.expect(!spoken.focus_changed);
}

test "accesskit map: a removed node changes its parent" {
    const t = std.testing;
    const alloc = t.allocator;
    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(alloc);

    const before = [_]SemanticNode{ testNode(0, .group, "", &.{ 1, 2 }), testNode(6, .button, "Close", &.{}), testNode(10, .button, "Settings", &.{}) };
    const after = [_]SemanticNode{ testNode(0, .group, "", &.{1}), testNode(10, .button, "Settings", &.{}) };
    var a = try Snapshot.init(alloc, .{ .nodes = &before }, .{});
    defer a.deinit();
    var b = try Snapshot.init(alloc, .{ .nodes = &after }, .{});
    defer b.deinit();

    const d = try diff(alloc, &a, &b, &out);
    // The root lost a child. The node that stays is unchanged.
    try t.expectEqualSlices(u32, &.{0}, d.changed);
    try t.expectEqualSlices(u64, &.{10}, b.nodes[0].children);
}
