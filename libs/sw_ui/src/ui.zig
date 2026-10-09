//! The UI tree: immediate mode, with keyboard focus and a semantic tree. This
//! file has no GPU code and no font code, so the unit tests run without them.
//!
//! The app builds the tree every frame:
//!
//! ```zig
//! try u.begin(input, width, height);
//! try u.beginColumn(1, .{ .padding = 8, .gap = 4 });
//! try u.addButton(10, "Play", .{});
//! try u.addButton(11, "Quit", .{});
//! u.endContainer();
//! try u.finish();
//! for (u.frameEvents()) |e| switch (e.kind) { ... };
//! ```
//!
//! `finish` lays out the tree, applies the input to it (focus, activation,
//! text) and builds the semantic tree. The result of the input is a list of
//! events, not a return value of `addButton`, so a click is seen in the frame
//! that it happens in.
//!
//! IDs: each node has a non-zero `u32` ID from the app. An ID must be unique in
//! a frame and must stay the same between frames, because the focus is an ID.
//!
//! Memory: a string that the app gives to a node must stay valid until the next
//! `begin` (and until the semantic tree is no longer read). `print` makes a
//! string in a per-frame buffer.

const std = @import("std");
const semantic = @import("semantic.zig");

pub const Rect = semantic.Rect;
pub const Role = semantic.Role;
pub const SemanticNode = semantic.SemanticNode;
pub const SemanticTree = semantic.SemanticTree;

/// The ID of the root node. An ID from the app is never 0.
pub const root_id: u32 = 0;

/// The deepest nesting of containers, root included.
pub const max_depth = 32;

/// The size of the per-frame text buffer of `print`.
pub const scratch_len = 4096;

pub const Size = struct {
    w: f32 = 0,
    h: f32 = 0,
};

pub const Kind = enum {
    row,
    column,
    text,
    button,
    list,
    list_item,
    text_field,
    image,
};

/// How a node takes its width or height.
pub const Dim = union(enum) {
    /// The size of the content, and the padding.
    fit,
    /// A size in logical pixels.
    fixed: f32,
    /// A share of what the parent has left on its main axis, or all of its
    /// room on its cross axis.
    fill,
};

/// Where a container puts its children, on the main axis or the cross axis.
pub const Align = enum { start, center, end };

/// Options of a node. Every field has a default.
pub const Opts = struct {
    w: Dim = .fit,
    h: Dim = .fit,
    /// Space between the edge of the node and its content, on all four sides.
    /// Null is 0 for a container, text and image, and `Theme.control_pad` for
    /// a button, list item and text field.
    padding: ?f32 = null,
    /// Space between the children of a container.
    gap: f32 = 0,
    /// A container: where the children sit on its main axis.
    main_align: Align = .start,
    /// A container: where the children sit on its cross axis. A child with
    /// `.fill` on that axis takes all of it.
    cross_align: Align = .start,
    /// A node that is disabled never takes focus or activation.
    disabled: bool = false,
    /// A list item that is selected. It is the tab stop of its list when
    /// nothing else decides.
    selected: bool = false,
    /// Text: a live region. The semantic tree marks it as changed when its
    /// text changes.
    live: bool = false,
    /// A container: draw a panel behind it.
    panel: bool = false,
    /// A row or column: its accessible name.
    label: []const u8 = "",
};

/// Sizes of the UI, in logical pixels.
pub const Theme = struct {
    text_size: f32 = 16,
    control_pad: f32 = 8,
    field_width: f32 = 240,
    /// The width of the focus ring. At least 2.
    focus_ring: f32 = 3,
};

/// Measures text. The UI has no font: the app gives it a measurer.
pub const Measurer = struct {
    context: ?*const anyopaque = null,
    measureFn: *const fn (context: ?*const anyopaque, text: []const u8, size: f32) Size,

    /// The size of `s` at `size`. An empty string must have the height of one
    /// line.
    pub fn measureText(self: Measurer, s: []const u8, size: f32) Size {
        return self.measureFn(self.context, s, size);
    }
};

/// The keys that the UI reads. Each is true for the frame in which it went
/// down (a key press, not a held key).
pub const Keys = struct {
    tab: bool = false,
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,
    enter: bool = false,
    space: bool = false,
    escape: bool = false,
    backspace: bool = false,
};

/// The input of one frame. The app fills it from the engine input.
pub const Input = struct {
    keys: Keys = .{},
    /// Shift is held. Shift and Tab move focus backwards.
    shift: bool = false,
    pointer_x: f32 = 0,
    pointer_y: f32 = 0,
    /// The left mouse button went down in this frame.
    pointer_pressed: bool = false,
    /// UTF-8 text that the platform committed in this frame.
    text: []const u8 = "",
    /// UTF-8 text in composition (IME or dead key), or empty.
    composition: []const u8 = "",
};

pub const EventKind = enum {
    /// A button or list item was activated, by Enter, Space or a click.
    activate,
    /// Escape was pressed. `id` is the focused node, or 0.
    cancel,
    /// The text of a text field changed.
    changed,
    /// Enter was pressed in a text field.
    submit,
};

pub const Event = struct {
    kind: EventKind,
    id: u32,
};

/// The text of a text field. The app owns it, so the text lives across
/// frames. Editing adds text at the end and removes the last code point.
pub const TextValue = struct {
    buffer: []u8,
    len: usize = 0,

    pub fn slice(self: *const TextValue) []const u8 {
        return self.buffer[0..self.len];
    }

    pub fn clear(self: *TextValue) void {
        self.len = 0;
    }

    /// Add `s` at the end. It is all or nothing: false if `s` is not valid
    /// UTF-8 or does not fit.
    pub fn append(self: *TextValue, s: []const u8) bool {
        if (s.len == 0) return false;
        if (!std.unicode.utf8ValidateSlice(s)) return false;
        if (self.len + s.len > self.buffer.len) return false;
        @memcpy(self.buffer[self.len..][0..s.len], s);
        self.len += s.len;
        return true;
    }

    /// Remove the last code point. False if the text is empty.
    pub fn backspace(self: *TextValue) bool {
        if (self.len == 0) return false;
        self.len -= 1;
        while (self.len > 0 and (self.buffer[self.len] & 0xC0) == 0x80) self.len -= 1;
        return true;
    }
};

pub const Error = std.mem.Allocator.Error || error{
    /// The ID is 0.
    InvalidId,
    /// Two nodes have the same ID.
    DuplicateId,
    /// More than `max_depth` containers are open.
    TooDeep,
    /// `endContainer` was called too often, or a container is still open.
    UnbalancedTree,
    /// A node was added outside `begin` and `finish`.
    NotInFrame,
};

const no_parent = std.math.maxInt(usize);

const Node = struct {
    kind: Kind,
    id: u32,
    /// The text of text, a button and a list item. The label of a list, a text
    /// field and a container. The description of an image.
    text: []const u8,
    opts: Opts,
    parent: usize,
    /// The index after the last descendant. For a leaf: its own index plus 1.
    subtree_end: usize,
    value: ?*TextValue = null,
    texture: u32 = 0,
    /// The size that the node wants, from `measureNode`.
    pref: Size = .{},
    rect: Rect = .{},
};

const ListActive = struct {
    list: u32,
    item: u32,
};

const LiveState = struct {
    id: u32,
    hash: u64,
};

fn isContainer(kind: Kind) bool {
    return kind == .row or kind == .column or kind == .list;
}

fn isFocusableKind(kind: Kind) bool {
    return kind == .button or kind == .list_item or kind == .text_field;
}

pub const Ui = struct {
    alloc: std.mem.Allocator,
    theme: Theme,
    measurer: Measurer,

    nodes: std.ArrayList(Node) = .empty,
    stack: [max_depth]usize = undefined,
    depth: usize = 0,
    unbalanced: bool = false,
    in_frame: bool = false,
    input: Input = .{},
    viewport: Size = .{},
    scratch: [scratch_len]u8 = undefined,
    scratch_used: usize = 0,

    events: std.ArrayList(Event) = .empty,
    /// The ID that has focus, or 0.
    focus_id: u32 = 0,
    pending_focus: ?u32 = null,
    /// The list item that is the tab stop of each list.
    list_active: std.ArrayList(ListActive) = .empty,
    text_input_wanted: bool = false,

    live_prev: std.ArrayList(LiveState) = .empty,
    live_next: std.ArrayList(LiveState) = .empty,
    sem_nodes: std.ArrayList(SemanticNode) = .empty,
    sem_children: std.ArrayList(u32) = .empty,

    pub fn init(alloc: std.mem.Allocator, measurer: Measurer, theme: Theme) Ui {
        return .{ .alloc = alloc, .theme = theme, .measurer = measurer };
    }

    pub fn deinit(self: *Ui) void {
        self.nodes.deinit(self.alloc);
        self.events.deinit(self.alloc);
        self.list_active.deinit(self.alloc);
        self.live_prev.deinit(self.alloc);
        self.live_next.deinit(self.alloc);
        self.sem_nodes.deinit(self.alloc);
        self.sem_children.deinit(self.alloc);
    }

    // ---- Building the tree --------------------------------------------

    /// Start a frame. `width` and `height` are the size of the window in
    /// logical pixels. The events and the semantic tree of the last frame stay
    /// valid until this call.
    pub fn begin(self: *Ui, input: Input, width: f32, height: f32) Error!void {
        self.nodes.clearRetainingCapacity();
        self.events.clearRetainingCapacity();
        self.scratch_used = 0;
        self.unbalanced = false;
        self.input = input;
        self.viewport = .{ .w = width, .h = height };
        self.in_frame = true;
        self.depth = 0;
        try self.nodes.append(self.alloc, .{
            .kind = .column,
            .id = root_id,
            .text = "",
            .opts = .{ .w = .fill, .h = .fill },
            .parent = no_parent,
            .subtree_end = 1,
        });
        self.stack[0] = 0;
        self.depth = 1;
    }

    /// Open a row. Children sit side by side. Close it with `endContainer`.
    pub fn beginRow(self: *Ui, id: u32, opts: Opts) Error!void {
        try self.open(.row, id, opts.label, opts);
    }

    /// Open a column. Children sit one above the other. Close it with
    /// `endContainer`.
    pub fn beginColumn(self: *Ui, id: u32, opts: Opts) Error!void {
        try self.open(.column, id, opts.label, opts);
    }

    /// Open a list. Its children are list items. A list is a column, and it is
    /// one tab stop: the arrow keys move focus inside it. `name` is the
    /// accessible name. Close it with `endContainer`.
    pub fn beginList(self: *Ui, id: u32, name: []const u8, opts: Opts) Error!void {
        try self.open(.list, id, name, opts);
    }

    /// Close the container that `beginRow`, `beginColumn` or `beginList`
    /// opened last.
    pub fn endContainer(self: *Ui) void {
        if (self.depth <= 1) {
            self.unbalanced = true;
            return;
        }
        const index = self.stack[self.depth - 1];
        self.nodes.items[index].subtree_end = self.nodes.items.len;
        self.depth -= 1;
    }

    pub fn addText(self: *Ui, id: u32, content: []const u8, opts: Opts) Error!void {
        _ = try self.addNode(.text, id, content, opts);
    }

    pub fn addButton(self: *Ui, id: u32, name: []const u8, opts: Opts) Error!void {
        _ = try self.addNode(.button, id, name, opts);
    }

    /// An item of the list that is open.
    pub fn addListItem(self: *Ui, id: u32, name: []const u8, opts: Opts) Error!void {
        _ = try self.addNode(.list_item, id, name, opts);
    }

    /// A text field. `name` is the accessible name (the label). The text is in
    /// `value`, which the app owns.
    pub fn addTextField(self: *Ui, id: u32, name: []const u8, value: *TextValue, opts: Opts) Error!void {
        const index = try self.addNode(.text_field, id, name, opts);
        self.nodes.items[index].value = value;
    }

    /// An image. `texture` is the texture ID for the renderer. `alt` describes
    /// the image for assistive technology. Give it a fixed size in `opts`
    /// (the default is 32 by 32).
    pub fn addImage(self: *Ui, id: u32, texture: u32, alt: []const u8, opts: Opts) Error!void {
        const index = try self.addNode(.image, id, alt, opts);
        self.nodes.items[index].texture = texture;
    }

    /// Make a string in the per-frame buffer. It is valid until the next
    /// `begin`. Fails if the buffer is full.
    pub fn print(self: *Ui, comptime fmt: []const u8, args: anytype) ![]const u8 {
        const out = try std.fmt.bufPrint(self.scratch[self.scratch_used..], fmt, args);
        self.scratch_used += out.len;
        return out;
    }

    fn open(self: *Ui, kind: Kind, id: u32, name: []const u8, opts: Opts) Error!void {
        if (self.depth >= max_depth) return error.TooDeep;
        const index = try self.addNode(kind, id, name, opts);
        self.stack[self.depth] = index;
        self.depth += 1;
    }

    fn addNode(self: *Ui, kind: Kind, id: u32, name: []const u8, opts: Opts) Error!usize {
        if (!self.in_frame or self.depth == 0) return error.NotInFrame;
        if (id == root_id) return error.InvalidId;
        const index = self.nodes.items.len;
        try self.nodes.append(self.alloc, .{
            .kind = kind,
            .id = id,
            .text = name,
            .opts = opts,
            .parent = self.stack[self.depth - 1],
            .subtree_end = index + 1,
        });
        return index;
    }

    // ---- Focus ----------------------------------------------------------

    /// Move focus to the node with this ID. It takes effect in `finish`. A
    /// node that is missing or disabled does not take focus.
    pub fn setFocus(self: *Ui, id: u32) void {
        self.pending_focus = id;
    }

    /// Remove focus.
    pub fn clearFocus(self: *Ui) void {
        self.focus_id = 0;
        self.pending_focus = null;
    }

    /// The ID that has focus, as of the last `finish`.
    pub fn focused(self: *const Ui) ?u32 {
        return if (self.focus_id == 0) null else self.focus_id;
    }

    /// True when a text field has focus. The app calls
    /// `ctx.startTextInput()` when this becomes true and `ctx.stopTextInput()`
    /// when it becomes false.
    pub fn wantsTextInput(self: *const Ui) bool {
        return self.text_input_wanted;
    }

    // ---- Results ----------------------------------------------------------

    /// The events of the last `finish`: activations, cancel, and text changes.
    pub fn frameEvents(self: *const Ui) []const Event {
        return self.events.items;
    }

    /// The semantic tree of the last `finish`.
    pub fn semanticTree(self: *const Ui) SemanticTree {
        return .{ .nodes = self.sem_nodes.items };
    }

    /// The rectangle of a node in the last `finish`, or null.
    pub fn bounds(self: *const Ui, id: u32) ?Rect {
        const index = self.indexOf(id) orelse return null;
        return self.nodes.items[index].rect;
    }

    // ---- The end of the frame -------------------------------------------

    /// End the frame: lay out the tree, apply the input, build the semantic
    /// tree. The tree is then ready to draw.
    pub fn finish(self: *Ui) Error!void {
        if (!self.in_frame) return error.NotInFrame;
        self.in_frame = false;
        if (self.depth != 1 or self.unbalanced) return error.UnbalancedTree;
        self.nodes.items[0].subtree_end = self.nodes.items.len;
        try self.checkIds();

        self.measureNode(0);
        self.arrange(0, .{ .x = 0, .y = 0, .w = self.viewport.w, .h = self.viewport.h });

        try self.applyInput();
        try self.buildSemantic();
    }

    fn checkIds(self: *const Ui) Error!void {
        const items = self.nodes.items;
        for (items, 0..) |a, i| {
            for (items[i + 1 ..]) |b| {
                if (a.id == b.id) return error.DuplicateId;
            }
        }
    }

    pub fn indexOf(self: *const Ui, id: u32) ?usize {
        if (id == root_id) return null;
        for (self.nodes.items, 0..) |n, i| {
            if (n.id == id) return i;
        }
        return null;
    }

    // ---- Layout -----------------------------------------------------------

    fn leafPadding(self: *const Ui, n: *const Node) f32 {
        if (n.opts.padding) |p| return p;
        return switch (n.kind) {
            .button, .list_item, .text_field => self.theme.control_pad,
            else => 0,
        };
    }

    /// The natural size of a node, bottom up. It goes in `pref`.
    fn measureNode(self: *Ui, index: usize) void {
        const n = &self.nodes.items[index];
        var natural: Size = .{};
        if (isContainer(n.kind)) {
            const horizontal = n.kind == .row;
            var count: f32 = 0;
            var main: f32 = 0;
            var cross: f32 = 0;
            var c = index + 1;
            while (c < n.subtree_end) : (c = self.nodes.items[c].subtree_end) {
                self.measureNode(c);
                const child = &self.nodes.items[c];
                const child_main = if (horizontal) child.pref.w else child.pref.h;
                const child_cross = if (horizontal) child.pref.h else child.pref.w;
                main += child_main;
                cross = @max(cross, child_cross);
                count += 1;
            }
            if (count > 1) main += n.opts.gap * (count - 1);
            const pad = n.opts.padding orelse 0;
            natural = if (horizontal)
                .{ .w = main + 2 * pad, .h = cross + 2 * pad }
            else
                .{ .w = cross + 2 * pad, .h = main + 2 * pad };
        } else {
            const pad = self.leafPadding(n);
            const size = self.theme.text_size;
            switch (n.kind) {
                .text, .button, .list_item => {
                    const m = self.measurer.measureText(n.text, size);
                    natural = .{ .w = m.w + 2 * pad, .h = m.h + 2 * pad };
                },
                .text_field => {
                    const m = self.measurer.measureText("", size);
                    natural = .{ .w = self.theme.field_width, .h = m.h + 2 * pad };
                },
                .image => natural = .{ .w = 32 + 2 * pad, .h = 32 + 2 * pad },
                else => {},
            }
        }
        n.pref = .{
            .w = switch (n.opts.w) {
                .fixed => |v| v,
                else => natural.w,
            },
            .h = switch (n.opts.h) {
                .fixed => |v| v,
                else => natural.h,
            },
        };
    }

    /// Give a node its rectangle, then its children theirs, top down.
    fn arrange(self: *Ui, index: usize, rect: Rect) void {
        const n = &self.nodes.items[index];
        n.rect = rect;
        if (!isContainer(n.kind)) return;

        const pad = n.opts.padding orelse 0;
        const inner: Rect = .{
            .x = rect.x + pad,
            .y = rect.y + pad,
            .w = @max(0, rect.w - 2 * pad),
            .h = @max(0, rect.h - 2 * pad),
        };
        const horizontal = n.kind == .row;
        const inner_main = if (horizontal) inner.w else inner.h;
        const inner_cross = if (horizontal) inner.h else inner.w;
        const gap = n.opts.gap;

        // The space that fixed and fit children use, and the number of fills.
        var used: f32 = 0;
        var fills: f32 = 0;
        var count: f32 = 0;
        var c = index + 1;
        while (c < n.subtree_end) : (c = self.nodes.items[c].subtree_end) {
            const child = &self.nodes.items[c];
            count += 1;
            const dim = if (horizontal) child.opts.w else child.opts.h;
            switch (dim) {
                .fill => fills += 1,
                else => used += if (horizontal) child.pref.w else child.pref.h,
            }
        }
        const gaps = if (count > 1) gap * (count - 1) else 0;
        const left = @max(0, inner_main - used - gaps);
        const share = if (fills > 0) left / fills else 0;

        // Where the first child starts, for the main alignment. Fills take all
        // the room that is left, so the alignment has an effect only without.
        const free = if (fills > 0) 0 else left;
        var cursor: f32 = switch (n.opts.main_align) {
            .start => 0,
            .center => free / 2,
            .end => free,
        };
        cursor += if (horizontal) inner.x else inner.y;

        c = index + 1;
        while (c < n.subtree_end) : (c = self.nodes.items[c].subtree_end) {
            const child = &self.nodes.items[c];
            const main_dim = if (horizontal) child.opts.w else child.opts.h;
            const cross_dim = if (horizontal) child.opts.h else child.opts.w;
            const child_main = switch (main_dim) {
                .fill => share,
                else => if (horizontal) child.pref.w else child.pref.h,
            };
            const child_cross = switch (cross_dim) {
                .fill => inner_cross,
                else => if (horizontal) child.pref.h else child.pref.w,
            };
            const free_cross = @max(0, inner_cross - child_cross);
            var offset: f32 = switch (n.opts.cross_align) {
                .start => 0,
                .center => free_cross / 2,
                .end => free_cross,
            };
            offset += if (horizontal) inner.y else inner.x;

            const child_rect: Rect = if (horizontal)
                .{ .x = cursor, .y = offset, .w = child_main, .h = child_cross }
            else
                .{ .x = offset, .y = cursor, .w = child_cross, .h = child_main };
            self.arrange(c, child_rect);
            cursor += child_main + gap;
        }
    }

    // ---- Input ------------------------------------------------------------

    fn isFocusableNode(self: *const Ui, index: usize) bool {
        const n = &self.nodes.items[index];
        return isFocusableKind(n.kind) and !n.opts.disabled;
    }

    fn activeFor(self: *const Ui, list_id: u32) ?u32 {
        for (self.list_active.items) |entry| {
            if (entry.list == list_id) return entry.item;
        }
        return null;
    }

    fn setActive(self: *Ui, list_id: u32, item_id: u32) Error!void {
        for (self.list_active.items) |*entry| {
            if (entry.list == list_id) {
                entry.item = item_id;
                return;
            }
        }
        try self.list_active.append(self.alloc, .{ .list = list_id, .item = item_id });
    }

    /// The list item that Tab reaches in a list: the one with focus, else the
    /// last one that had focus, else a selected one, else the first. Disabled
    /// items never count.
    fn listTabItem(self: *const Ui, list_index: usize) ?usize {
        const list = &self.nodes.items[list_index];
        const stored = self.activeFor(list.id);
        var with_focus: ?usize = null;
        var remembered: ?usize = null;
        var chosen: ?usize = null;
        var first: ?usize = null;
        var c = list_index + 1;
        while (c < list.subtree_end) : (c = self.nodes.items[c].subtree_end) {
            const child = &self.nodes.items[c];
            if (child.kind != .list_item or child.opts.disabled) continue;
            if (child.id == self.focus_id) with_focus = c;
            if (stored != null and stored.? == child.id) remembered = c;
            if (child.opts.selected and chosen == null) chosen = c;
            if (first == null) first = c;
        }
        return with_focus orelse remembered orelse chosen orelse first;
    }

    fn isTabStop(self: *const Ui, index: usize) bool {
        const n = &self.nodes.items[index];
        if (n.opts.disabled) return false;
        switch (n.kind) {
            .button, .text_field => return true,
            .list_item => {
                if (n.parent == no_parent or self.nodes.items[n.parent].kind != .list) return true;
                const stop = self.listTabItem(n.parent) orelse return false;
                return stop == index;
            },
            else => return false,
        }
    }

    /// The next tab stop after (or before) `current`, in tree order, wrapping
    /// round. With no current node it is the first (or last) stop.
    fn nextStop(self: *const Ui, current: ?usize, forward: bool) ?usize {
        const len = self.nodes.items.len;
        var k: usize = 0;
        while (k < len) : (k += 1) {
            const candidate = if (forward)
                (if (current) |cur| (cur + 1 + k) % len else k)
            else
                (if (current) |cur| (cur + len - 1 - k) % len else len - 1 - k);
            if (self.isTabStop(candidate)) return candidate;
        }
        return null;
    }

    /// The enabled list item before or after `index` in the same list, or null.
    fn neighbourItem(self: *const Ui, index: usize, forward: bool) ?usize {
        const parent = self.nodes.items[index].parent;
        if (parent == no_parent) return null;
        const list = &self.nodes.items[parent];
        if (list.kind != .list) return null;
        var before: ?usize = null;
        var after: ?usize = null;
        var passed = false;
        var c = parent + 1;
        while (c < list.subtree_end) : (c = self.nodes.items[c].subtree_end) {
            if (c == index) {
                passed = true;
                continue;
            }
            const child = &self.nodes.items[c];
            if (child.kind != .list_item or child.opts.disabled) continue;
            if (!passed) {
                before = c;
            } else if (after == null) {
                after = c;
            }
        }
        return if (forward) after else before;
    }

    fn emit(self: *Ui, kind: EventKind, id: u32) Error!void {
        try self.events.append(self.alloc, .{ .kind = kind, .id = id });
    }

    fn applyInput(self: *Ui) Error!void {
        const input = self.input;
        const keys = input.keys;

        // A focus request from the app, then a focus that points at nothing.
        if (self.pending_focus) |id| {
            self.pending_focus = null;
            if (self.indexOf(id)) |index| {
                if (self.isFocusableNode(index)) self.focus_id = id;
            }
        }
        var current: ?usize = null;
        if (self.focus_id != 0) {
            current = self.indexOf(self.focus_id);
            if (current) |index| {
                if (!self.isFocusableNode(index)) current = null;
            }
            if (current == null) self.focus_id = 0;
        }

        // A click: the topmost node under the pointer that takes focus.
        if (input.pointer_pressed) {
            var i = self.nodes.items.len;
            while (i > 0) {
                i -= 1;
                if (!self.isFocusableNode(i)) continue;
                const n = &self.nodes.items[i];
                if (!n.rect.contains(input.pointer_x, input.pointer_y)) continue;
                self.focus_id = n.id;
                current = i;
                if (n.kind == .button or n.kind == .list_item) try self.emit(.activate, n.id);
                break;
            }
        }

        // Text: committed text and Backspace edit the field that has focus.
        if (current) |index| {
            const n = &self.nodes.items[index];
            if (n.kind == .text_field) {
                if (n.value) |value| {
                    var edited = value.append(input.text);
                    if (keys.backspace and value.backspace()) edited = true;
                    if (edited) try self.emit(.changed, n.id);
                }
            }
        }

        // Tab and Shift+Tab.
        if (keys.tab) {
            if (self.nextStop(current, !input.shift)) |next| {
                current = next;
                self.focus_id = self.nodes.items[next].id;
            }
        }

        // The arrow keys move inside a list.
        if (current) |index| {
            if (self.nodes.items[index].kind == .list_item and (keys.up or keys.down)) {
                if (self.neighbourItem(index, keys.down)) |next| {
                    current = next;
                    self.focus_id = self.nodes.items[next].id;
                }
            }
        }

        // Enter and Space.
        if (current) |index| {
            const n = &self.nodes.items[index];
            switch (n.kind) {
                .button, .list_item => {
                    if (keys.enter or keys.space) try self.emit(.activate, n.id);
                },
                .text_field => {
                    if (keys.enter) try self.emit(.submit, n.id);
                },
                else => {},
            }
        }

        if (keys.escape) try self.emit(.cancel, self.focus_id);

        // The list that holds the focus remembers it, for the next Tab.
        if (current) |index| {
            const n = &self.nodes.items[index];
            if (n.kind == .list_item and n.parent != no_parent) {
                const list = &self.nodes.items[n.parent];
                if (list.kind == .list) try self.setActive(list.id, n.id);
            }
        }

        self.text_input_wanted = if (current) |index| self.nodes.items[index].kind == .text_field else false;
    }

    // ---- The semantic tree --------------------------------------------

    fn roleOf(kind: Kind) Role {
        return switch (kind) {
            .row, .column => .group,
            .text => .text,
            .button => .button,
            .list => .list,
            .list_item => .list_item,
            .text_field => .text_field,
            .image => .image,
        };
    }

    fn lastHash(self: *const Ui, id: u32) ?u64 {
        for (self.live_prev.items) |entry| {
            if (entry.id == id) return entry.hash;
        }
        return null;
    }

    fn buildSemantic(self: *Ui) Error!void {
        const items = self.nodes.items;
        self.sem_nodes.clearRetainingCapacity();
        self.sem_children.clearRetainingCapacity();
        self.live_next.clearRetainingCapacity();

        // The children of each node, one run after another, in node order.
        for (items, 0..) |n, i| {
            var c = i + 1;
            while (c < n.subtree_end) : (c = items[c].subtree_end) {
                try self.sem_children.append(self.alloc, @intCast(c));
            }
        }

        var offset: usize = 0;
        for (items, 0..) |n, i| {
            var count: usize = 0;
            var c = i + 1;
            while (c < n.subtree_end) : (c = items[c].subtree_end) count += 1;

            const live = n.kind == .text and n.opts.live;
            var changed = false;
            if (live) {
                const hash = std.hash.Wyhash.hash(0, n.text);
                if (self.lastHash(n.id)) |old| changed = old != hash;
                try self.live_next.append(self.alloc, .{ .id = n.id, .hash = hash });
            }

            try self.sem_nodes.append(self.alloc, .{
                .id = n.id,
                .role = roleOf(n.kind),
                .name = n.text,
                .value = if (n.value) |v| v.slice() else "",
                .focused = n.id == self.focus_id and n.id != root_id,
                .disabled = n.opts.disabled,
                .selected = n.opts.selected,
                .live = live,
                .changed = changed,
                .bounds = n.rect,
                .children = self.sem_children.items[offset .. offset + count],
            });
            offset += count;
        }

        std.mem.swap(std.ArrayList(LiveState), &self.live_prev, &self.live_next);
    }
};

// ---- Tests ----------------------------------------------------------------

fn fakeMeasure(context: ?*const anyopaque, s: []const u8, size: f32) Size {
    _ = context;
    _ = size;
    // 8 pixels for each byte, 16 pixels high.
    return .{ .w = @floatFromInt(s.len * 8), .h = 16 };
}

fn testUi() Ui {
    return Ui.init(std.testing.allocator, .{ .measureFn = fakeMeasure }, .{});
}

const tab_key: Input = .{ .keys = .{ .tab = true } };

fn buildMenu(u: *Ui) anyerror!void {
    try u.beginColumn(1, .{ .padding = 8, .gap = 4 });
    try u.addButton(10, "Play", .{});
    try u.addButton(11, "Options", .{});
    try u.addButton(12, "Quit", .{ .disabled = true });
    u.endContainer();
}

fn buildMenuWithList(u: *Ui) anyerror!void {
    try u.beginColumn(1, .{});
    try u.addButton(10, "Top", .{});
    try u.beginList(20, "Levels", .{});
    try u.addListItem(21, "One", .{});
    try u.addListItem(22, "Two", .{ .disabled = true });
    try u.addListItem(23, "Three", .{});
    u.endContainer();
    try u.addButton(11, "Bottom", .{});
    u.endContainer();
}

fn runFrame(u: *Ui, input: Input, build: *const fn (*Ui) anyerror!void) !void {
    try u.begin(input, 400, 300);
    try build(u);
    try u.finish();
}

test "layout: column with padding and gap" {
    var u = testUi();
    defer u.deinit();
    try runFrame(&u, .{}, buildMenu);

    // "Play": 4 bytes of 8 px and 8 px of padding each side: 48 x 32.
    const play = u.bounds(10).?;
    try std.testing.expectEqual(@as(f32, 8), play.x);
    try std.testing.expectEqual(@as(f32, 8), play.y);
    try std.testing.expectEqual(@as(f32, 48), play.w);
    try std.testing.expectEqual(@as(f32, 32), play.h);

    const options = u.bounds(11).?;
    try std.testing.expectEqual(@as(f32, 44), options.y);
    try std.testing.expectEqual(@as(f32, 72), options.w);

    // The column is as wide as its widest child ("Quit" is 48, "Options" 72).
    const column = u.bounds(1).?;
    try std.testing.expectEqual(@as(f32, 88), column.w);
    try std.testing.expectEqual(@as(f32, 8 + 32 + 4 + 32 + 4 + 32 + 8), column.h);
}

fn buildFill(u: *Ui) anyerror!void {
    try u.beginRow(1, .{ .w = .{ .fixed = 200 }, .h = .{ .fixed = 40 }, .gap = 10 });
    try u.addButton(2, "ab", .{ .w = .{ .fixed = 50 } });
    try u.addText(3, "x", .{ .w = .fill });
    try u.addText(4, "y", .{ .w = .fill });
    u.endContainer();
}

test "layout: fill shares what fixed children leave" {
    var u = testUi();
    defer u.deinit();
    try runFrame(&u, .{}, buildFill);

    // 200 - 50 - two gaps of 10 = 130, shared by two fills.
    try std.testing.expectEqual(@as(f32, 50), u.bounds(2).?.w);
    try std.testing.expectEqual(@as(f32, 65), u.bounds(3).?.w);
    try std.testing.expectEqual(@as(f32, 65), u.bounds(4).?.w);
    try std.testing.expectEqual(@as(f32, 60), u.bounds(3).?.x);
    try std.testing.expectEqual(@as(f32, 135), u.bounds(4).?.x);
}

fn buildCentered(u: *Ui) anyerror!void {
    try u.beginColumn(1, .{ .w = .fill, .h = .fill, .main_align = .center, .cross_align = .center });
    try u.addButton(2, "ab", .{});
    u.endContainer();
}

test "layout: center alignment" {
    var u = testUi();
    defer u.deinit();
    try runFrame(&u, .{}, buildCentered);

    // The button is 32 x 32 in a 400 x 300 window.
    const b = u.bounds(2).?;
    try std.testing.expectEqual(@as(f32, 184), b.x);
    try std.testing.expectEqual(@as(f32, 134), b.y);
}

test "focus order: Tab moves in tree order and skips disabled nodes" {
    var u = testUi();
    defer u.deinit();
    try runFrame(&u, .{}, buildMenu);
    try std.testing.expectEqual(@as(?u32, null), u.focused());

    try runFrame(&u, tab_key, buildMenu);
    try std.testing.expectEqual(@as(?u32, 10), u.focused());
    try runFrame(&u, tab_key, buildMenu);
    try std.testing.expectEqual(@as(?u32, 11), u.focused());
    // 12 is disabled: the focus wraps round to 10.
    try runFrame(&u, tab_key, buildMenu);
    try std.testing.expectEqual(@as(?u32, 10), u.focused());
}

test "focus order: Shift+Tab moves backwards" {
    var u = testUi();
    defer u.deinit();
    const back: Input = .{ .keys = .{ .tab = true }, .shift = true };

    // From nothing it goes to the last stop that is enabled.
    try runFrame(&u, back, buildMenu);
    try std.testing.expectEqual(@as(?u32, 11), u.focused());
    try runFrame(&u, back, buildMenu);
    try std.testing.expectEqual(@as(?u32, 10), u.focused());
    try runFrame(&u, back, buildMenu);
    try std.testing.expectEqual(@as(?u32, 11), u.focused());
}

test "focus: a node that goes away loses focus" {
    var u = testUi();
    defer u.deinit();
    u.setFocus(11);
    try runFrame(&u, .{}, buildMenu);
    try std.testing.expectEqual(@as(?u32, 11), u.focused());

    try u.begin(.{}, 400, 300);
    try u.addButton(10, "Play", .{});
    try u.finish();
    try std.testing.expectEqual(@as(?u32, null), u.focused());
}

test "focus: setFocus ignores a disabled node" {
    var u = testUi();
    defer u.deinit();
    u.setFocus(12);
    try runFrame(&u, .{}, buildMenu);
    try std.testing.expectEqual(@as(?u32, null), u.focused());
}

test "activation: Enter and Space activate a button" {
    var u = testUi();
    defer u.deinit();
    u.setFocus(10);
    try runFrame(&u, .{ .keys = .{ .enter = true } }, buildMenu);
    try std.testing.expectEqual(@as(usize, 1), u.frameEvents().len);
    try std.testing.expectEqual(EventKind.activate, u.frameEvents()[0].kind);
    try std.testing.expectEqual(@as(u32, 10), u.frameEvents()[0].id);

    try runFrame(&u, .{ .keys = .{ .space = true } }, buildMenu);
    try std.testing.expectEqual(@as(usize, 1), u.frameEvents().len);
    try std.testing.expectEqual(@as(u32, 10), u.frameEvents()[0].id);

    // No key, no event.
    try runFrame(&u, .{}, buildMenu);
    try std.testing.expectEqual(@as(usize, 0), u.frameEvents().len);
}

test "activation: Escape sends cancel" {
    var u = testUi();
    defer u.deinit();
    try runFrame(&u, .{ .keys = .{ .escape = true } }, buildMenu);
    try std.testing.expectEqual(@as(usize, 1), u.frameEvents().len);
    try std.testing.expectEqual(EventKind.cancel, u.frameEvents()[0].kind);
    try std.testing.expectEqual(@as(u32, 0), u.frameEvents()[0].id);

    u.setFocus(11);
    try runFrame(&u, .{ .keys = .{ .escape = true } }, buildMenu);
    try std.testing.expectEqual(@as(u32, 11), u.frameEvents()[0].id);
}

test "mouse: a click focuses and activates a button" {
    var u = testUi();
    defer u.deinit();
    try runFrame(&u, .{}, buildMenu);
    const target = u.bounds(11).?;

    const click: Input = .{
        .pointer_x = target.x + target.w / 2,
        .pointer_y = target.y + target.h / 2,
        .pointer_pressed = true,
    };
    try runFrame(&u, click, buildMenu);
    try std.testing.expectEqual(@as(?u32, 11), u.focused());
    try std.testing.expectEqual(@as(usize, 1), u.frameEvents().len);
    try std.testing.expectEqual(EventKind.activate, u.frameEvents()[0].kind);
    try std.testing.expectEqual(@as(u32, 11), u.frameEvents()[0].id);
}

test "mouse: a click on a disabled button or on nothing does nothing" {
    var u = testUi();
    defer u.deinit();
    try runFrame(&u, .{}, buildMenu);
    const disabled = u.bounds(12).?;
    try runFrame(&u, .{
        .pointer_x = disabled.x + 1,
        .pointer_y = disabled.y + 1,
        .pointer_pressed = true,
    }, buildMenu);
    try std.testing.expectEqual(@as(?u32, null), u.focused());
    try std.testing.expectEqual(@as(usize, 0), u.frameEvents().len);

    try runFrame(&u, .{ .pointer_x = 390, .pointer_y = 290, .pointer_pressed = true }, buildMenu);
    try std.testing.expectEqual(@as(?u32, null), u.focused());
}

test "list: arrow keys move inside a list and skip disabled items" {
    var u = testUi();
    defer u.deinit();
    const down: Input = .{ .keys = .{ .down = true } };
    const up: Input = .{ .keys = .{ .up = true } };

    u.setFocus(21);
    try runFrame(&u, .{}, buildMenuWithList);
    try std.testing.expectEqual(@as(?u32, 21), u.focused());

    try runFrame(&u, down, buildMenuWithList);
    try std.testing.expectEqual(@as(?u32, 23), u.focused());
    // The end of the list: the focus stays.
    try runFrame(&u, down, buildMenuWithList);
    try std.testing.expectEqual(@as(?u32, 23), u.focused());
    try runFrame(&u, up, buildMenuWithList);
    try std.testing.expectEqual(@as(?u32, 21), u.focused());
    try runFrame(&u, up, buildMenuWithList);
    try std.testing.expectEqual(@as(?u32, 21), u.focused());
}

test "list: the arrow keys do nothing outside a list" {
    var u = testUi();
    defer u.deinit();
    u.setFocus(10);
    try runFrame(&u, .{ .keys = .{ .down = true } }, buildMenuWithList);
    try std.testing.expectEqual(@as(?u32, 10), u.focused());
}

test "list: Tab treats a list as one stop and remembers the item" {
    var u = testUi();
    defer u.deinit();
    // Top, then the first item of the list, then Bottom.
    try runFrame(&u, tab_key, buildMenuWithList);
    try std.testing.expectEqual(@as(?u32, 10), u.focused());
    try runFrame(&u, tab_key, buildMenuWithList);
    try std.testing.expectEqual(@as(?u32, 21), u.focused());

    try runFrame(&u, .{ .keys = .{ .down = true } }, buildMenuWithList);
    try std.testing.expectEqual(@as(?u32, 23), u.focused());

    try runFrame(&u, tab_key, buildMenuWithList);
    try std.testing.expectEqual(@as(?u32, 11), u.focused());
    // Shift+Tab comes back to the item that had focus, not to the first one.
    try runFrame(&u, .{ .keys = .{ .tab = true }, .shift = true }, buildMenuWithList);
    try std.testing.expectEqual(@as(?u32, 23), u.focused());
}

test "list: Enter activates the focused item" {
    var u = testUi();
    defer u.deinit();
    u.setFocus(23);
    try runFrame(&u, .{ .keys = .{ .enter = true } }, buildMenuWithList);
    try std.testing.expectEqual(@as(usize, 1), u.frameEvents().len);
    try std.testing.expectEqual(@as(u32, 23), u.frameEvents()[0].id);
}

fn expectNode(tree: SemanticTree, id: u32, role: Role, name: []const u8) !*const SemanticNode {
    const n = tree.find(id) orelse return error.TestNodeMissing;
    try std.testing.expectEqual(role, n.role);
    try std.testing.expectEqualStrings(name, n.name);
    return n;
}

test "semantic tree: roles, names, flags and children" {
    var u = testUi();
    defer u.deinit();
    u.setFocus(10);
    try runFrame(&u, .{}, buildMenuWithList);
    const tree = u.semanticTree();

    // The root, the column, the two buttons, the list, three items.
    try std.testing.expectEqual(@as(usize, 8), tree.nodes.len);
    const root = tree.nodes[0];
    try std.testing.expectEqual(root_id, root.id);
    try std.testing.expectEqual(Role.group, root.role);
    try std.testing.expectEqual(@as(usize, 1), root.children.len);
    try std.testing.expectEqual(@as(u32, 1), tree.nodes[root.children[0]].id);

    const column = tree.find(1).?;
    try std.testing.expectEqual(@as(usize, 3), column.children.len);
    try std.testing.expectEqual(@as(u32, 10), tree.nodes[column.children[0]].id);
    try std.testing.expectEqual(@as(u32, 20), tree.nodes[column.children[1]].id);
    try std.testing.expectEqual(@as(u32, 11), tree.nodes[column.children[2]].id);

    const top = try expectNode(tree, 10, .button, "Top");
    try std.testing.expect(top.focused);
    try std.testing.expect(!top.disabled);
    try std.testing.expectEqual(@as(usize, 0), top.children.len);
    try std.testing.expectEqual(top, tree.focusedNode().?);

    const list = try expectNode(tree, 20, .list, "Levels");
    try std.testing.expectEqual(@as(usize, 3), list.children.len);
    try std.testing.expect(!list.focused);

    const two = try expectNode(tree, 22, .list_item, "Two");
    try std.testing.expect(two.disabled);
    _ = try expectNode(tree, 23, .list_item, "Three");

    // The bounds are the layout rectangles.
    try std.testing.expectEqual(u.bounds(10).?, top.bounds);
}

test "semantic tree: text, image and text field" {
    var u = testUi();
    defer u.deinit();
    var storage: [16]u8 = undefined;
    var value: TextValue = .{ .buffer = &storage };
    try std.testing.expect(value.append("Sean"));

    try u.begin(.{}, 400, 300);
    try u.beginRow(1, .{ .label = "Profile" });
    try u.addText(2, "Name", .{});
    try u.addTextField(3, "Your name", &value, .{});
    try u.addImage(4, 7, "A red box", .{ .w = .{ .fixed = 16 }, .h = .{ .fixed = 16 } });
    u.endContainer();
    try u.finish();
    const tree = u.semanticTree();

    _ = try expectNode(tree, 1, .group, "Profile");
    _ = try expectNode(tree, 2, .text, "Name");
    const field = try expectNode(tree, 3, .text_field, "Your name");
    try std.testing.expectEqualStrings("Sean", field.value);
    const image = try expectNode(tree, 4, .image, "A red box");
    try std.testing.expectEqual(@as(f32, 16), image.bounds.w);
    try std.testing.expect(!field.live and !field.changed);
}

var live_text: []const u8 = "";

fn buildLive(u: *Ui) anyerror!void {
    try u.beginColumn(1, .{});
    try u.addText(2, live_text, .{ .live = true });
    try u.addText(3, live_text, .{});
    u.endContainer();
}

test "live region: the tree marks a change of text" {
    var u = testUi();
    defer u.deinit();

    live_text = "Score 1";
    try runFrame(&u, .{}, buildLive);
    // A new node is not a change.
    try std.testing.expect(u.semanticTree().find(2).?.live);
    try std.testing.expect(!u.semanticTree().find(2).?.changed);

    try runFrame(&u, .{}, buildLive);
    try std.testing.expect(!u.semanticTree().find(2).?.changed);

    live_text = "Score 2";
    try runFrame(&u, .{}, buildLive);
    try std.testing.expect(u.semanticTree().find(2).?.changed);
    // Text that is not live is never marked.
    try std.testing.expect(!u.semanticTree().find(3).?.live);
    try std.testing.expect(!u.semanticTree().find(3).?.changed);

    try runFrame(&u, .{}, buildLive);
    try std.testing.expect(!u.semanticTree().find(2).?.changed);
}

test "text field: typing, Backspace, submit and the text input request" {
    var u = testUi();
    defer u.deinit();
    var storage: [8]u8 = undefined;
    var value: TextValue = .{ .buffer = &storage };

    u.setFocus(3);
    const frame = struct {
        fn run(ui: *Ui, input: Input, v: *TextValue) !void {
            try ui.begin(input, 400, 300);
            try ui.addButton(2, "Before", .{});
            try ui.addTextField(3, "Name", v, .{});
            try ui.finish();
        }
    }.run;

    try frame(&u, .{ .text = "h\u{e9}" }, &value);
    try std.testing.expectEqualStrings("h\u{e9}", value.slice());
    try std.testing.expect(u.wantsTextInput());
    try std.testing.expectEqual(@as(usize, 1), u.frameEvents().len);
    try std.testing.expectEqual(EventKind.changed, u.frameEvents()[0].kind);
    try std.testing.expectEqualStrings("h\u{e9}", u.semanticTree().find(3).?.value);

    // Backspace removes one code point, not one byte.
    try frame(&u, .{ .keys = .{ .backspace = true } }, &value);
    try std.testing.expectEqualStrings("h", value.slice());

    // Text that does not fit is dropped whole.
    try frame(&u, .{ .text = "123456789" }, &value);
    try std.testing.expectEqualStrings("h", value.slice());
    try std.testing.expectEqual(@as(usize, 0), u.frameEvents().len);

    try frame(&u, .{ .keys = .{ .enter = true } }, &value);
    try std.testing.expectEqual(@as(usize, 1), u.frameEvents().len);
    try std.testing.expectEqual(EventKind.submit, u.frameEvents()[0].kind);

    // Tab leaves the field, and the platform input method is not wanted.
    try frame(&u, tab_key, &value);
    try std.testing.expectEqual(@as(?u32, 2), u.focused());
    try std.testing.expect(!u.wantsTextInput());
}

test "text field: typing with no focus changes nothing" {
    var u = testUi();
    defer u.deinit();
    var storage: [8]u8 = undefined;
    var value: TextValue = .{ .buffer = &storage };
    try u.begin(.{ .text = "abc" }, 400, 300);
    try u.addTextField(3, "Name", &value, .{});
    try u.finish();
    try std.testing.expectEqual(@as(usize, 0), value.len);
    try std.testing.expect(!u.wantsTextInput());
}

test "TextValue: rejects bad UTF-8" {
    var storage: [8]u8 = undefined;
    var value: TextValue = .{ .buffer = &storage };
    try std.testing.expect(!value.append("\xff"));
    try std.testing.expect(!value.append(""));
    try std.testing.expect(!value.backspace());
    try std.testing.expect(value.append("ab"));
    try std.testing.expect(value.backspace());
    try std.testing.expectEqualStrings("a", value.slice());
}

test "errors: unbalanced tree, duplicate ID, ID 0 and a node outside a frame" {
    var u = testUi();
    defer u.deinit();

    try std.testing.expectError(error.NotInFrame, u.finish());

    try u.begin(.{}, 100, 100);
    try u.beginColumn(1, .{});
    try std.testing.expectError(error.UnbalancedTree, u.finish());

    try u.begin(.{}, 100, 100);
    u.endContainer();
    try std.testing.expectError(error.UnbalancedTree, u.finish());

    try u.begin(.{}, 100, 100);
    try u.addButton(5, "a", .{});
    try u.addButton(5, "b", .{});
    try std.testing.expectError(error.DuplicateId, u.finish());

    try u.begin(.{}, 100, 100);
    try std.testing.expectError(error.InvalidId, u.addButton(0, "a", .{}));
}

test "print: makes a string that lives until the next frame" {
    var u = testUi();
    defer u.deinit();
    try u.begin(.{}, 100, 100);
    const a = try u.print("Score {d}", .{12});
    const b = try u.print("{s}!", .{"Hi"});
    try std.testing.expectEqualStrings("Score 12", a);
    try std.testing.expectEqualStrings("Hi!", b);
    try u.addText(1, a, .{});
    try u.finish();
}
