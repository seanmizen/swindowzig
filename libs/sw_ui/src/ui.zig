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
//! `tooltip_id` is also not an app ID.
//!
//! Memory: a string that the app gives to a node must stay valid until the next
//! `begin` (and until the semantic tree is no longer read). `print` makes a
//! string in a per-frame buffer.
//!
//! The widgets: text, button, list and list item, text field (caret,
//! selection, clipboard), image, slider, scroll list, tooltip (`Opts.tooltip`)
//! and screen. A screen is a modal layer over its parent: when the tree has a
//! screen, only the last screen in tree order takes input, and the semantic tree holds only
//! that screen and its ancestors. `screen.zig` keeps a stack of screens, and
//! `osk.zig` is an on-screen keyboard made of buttons.

const std = @import("std");
const semantic = @import("semantic.zig");
const web_mirror = @import("web_mirror.zig");

pub const Rect = semantic.Rect;
pub const Role = semantic.Role;
pub const SemanticNode = semantic.SemanticNode;
pub const SemanticTree = semantic.SemanticTree;

/// The ID of the root node. An ID from the app is never 0.
pub const root_id: u32 = 0;

/// The ID of the tooltip node in the semantic tree. An app node must not use
/// it.
pub const tooltip_id: u32 = std.math.maxInt(u32);

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
    slider,
    scroll_list,
    screen,
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
    /// a button, list item, text field and slider.
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
    /// nothing else decides. A button that is selected is drawn as pressed.
    selected: bool = false,
    /// Text: a live region. The semantic tree marks it as changed when its
    /// text changes.
    live: bool = false,
    /// A container: draw a panel behind it.
    panel: bool = false,
    /// A row or column: its accessible name.
    label: []const u8 = "",
    /// The text of a tooltip. It shows when the pointer or the focus stays
    /// on the node for `Theme.tooltip_delay` frames. The semantic tree gives
    /// it as the description of the node.
    tooltip: []const u8 = "",
    /// A container: the arrow keys move the focus to the nearest node in the
    /// direction of the key, among the nodes inside the container that take
    /// focus. The container is one tab stop. Use it for a grid of buttons.
    arrows: bool = false,
};

/// The options of a slider.
pub const SliderOpts = struct {
    min: f32 = 0,
    max: f32 = 1,
    /// The change for one arrow key. The value is always a whole number of
    /// steps from `min`. 0 gives a hundredth of the range and no snapping.
    step: f32 = 0.1,
    /// The value as text for assistive technology, for example "50%". Empty
    /// gives the number. The app makes this text before `finish` applies the
    /// input, so after a key press it gives the old value. Use `format` for a
    /// text that follows the value.
    text: []const u8 = "",
    /// Writes the value as text into `buf` and returns the text. sw_ui calls
    /// it after it applies the input, so the text has the new value
    /// (REQ-A11Y-009). It replaces `text`.
    format: ?*const fn (value: f32, buf: []u8) []const u8 = null,
};

/// Sizes of the UI, in logical pixels.
pub const Theme = struct {
    text_size: f32 = 16,
    control_pad: f32 = 8,
    field_width: f32 = 240,
    /// The width of the focus ring. At least 2.
    focus_ring: f32 = 3,
    /// The width of the scroll bar of a scroll list.
    scrollbar: f32 = 10,
    /// The distance that one line of the mouse wheel scrolls.
    scroll_step: f32 = 40,
    /// The width of the thumb of a slider.
    slider_thumb: f32 = 12,
    /// The number of frames that the pointer or the focus stays on a node
    /// before its tooltip shows.
    tooltip_delay: u32 = 30,
};

/// Measures text. The UI has no font: the app gives it a measurer.
pub const Measurer = struct {
    context: ?*const anyopaque = null,
    measureFn: *const fn (context: ?*const anyopaque, text: []const u8, size: f32) Size,
    /// Optional. The x of the caret at byte `offset` of `text` drawn as one
    /// line, from the left edge of the text. Null measures the bytes before
    /// `offset`, which is correct only for left-to-right text. `draw.measurer`
    /// gives a function that uses the bidi caret layout of sw_text.
    caretFn: ?*const fn (context: ?*const anyopaque, text: []const u8, size: f32, offset: usize) f32 = null,

    /// The size of `s` at `size`. An empty string must have the height of one
    /// line.
    pub fn measureText(self: Measurer, s: []const u8, size: f32) Size {
        return self.measureFn(self.context, s, size);
    }

    /// The x of the caret at byte `offset` of `s`.
    pub fn caretX(self: Measurer, s: []const u8, size: f32, offset: usize) f32 {
        if (self.caretFn) |f| return f(self.context, s, size, offset);
        return self.measureFn(self.context, s[0..@min(offset, s.len)], size).w;
    }

    /// The byte offset of the caret position in `s` nearest to `x`.
    pub fn offsetAt(self: Measurer, s: []const u8, size: f32, x: f32) usize {
        var best: usize = 0;
        var best_d = std.math.inf(f32);
        var offset: usize = 0;
        while (true) {
            const d = @abs(self.caretX(s, size, offset) - x);
            if (d < best_d) {
                best_d = d;
                best = offset;
            }
            if (offset >= s.len) break;
            offset += 1;
            while (offset < s.len and (s[offset] & 0xC0) == 0x80) offset += 1;
        }
        return best;
    }
};

/// The keys that the UI reads. Each is true for the frame in which it went
/// down (a key press, not a held key). The app maps the platform keys to
/// them, for example Ctrl+C (or Cmd+C) to `copy`.
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
    home: bool = false,
    end: bool = false,
    /// Remove the code point after the caret.
    delete: bool = false,
    select_all: bool = false,
    copy: bool = false,
    cut: bool = false,
    paste: bool = false,
};

/// The input of one frame. The app fills it from the engine input.
pub const Input = struct {
    keys: Keys = .{},
    /// Shift is held. Shift and Tab move focus backwards. Shift and an arrow
    /// key, Home, End or a click extend the selection of a text field.
    shift: bool = false,
    pointer_x: f32 = 0,
    pointer_y: f32 = 0,
    /// The left mouse button went down in this frame.
    pointer_pressed: bool = false,
    /// The left mouse button is down. While it is down after a press on a
    /// slider, a scroll bar or a text field, the pointer drags it.
    pointer_down: bool = false,
    /// Mouse wheel lines in this frame. A positive value scrolls up.
    wheel_y: f32 = 0,
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
    /// The text of a text field or the value of a slider changed.
    changed,
    /// Enter was pressed in a text field.
    submit,
};

pub const Event = struct {
    kind: EventKind,
    id: u32,
};

fn isContinuation(byte: u8) bool {
    return (byte & 0xC0) == 0x80;
}

/// The text of a text field. The app owns it, so the text lives across
/// frames. It has a caret and a selection, as byte offsets at code point
/// boundaries. `append` and `backspace` edit the end of the text. The other
/// edits use the caret.
pub const TextValue = struct {
    buffer: []u8,
    len: usize = 0,
    /// The caret. Null is the end of the text, so text that the app appends
    /// keeps the caret at the end.
    caret: ?usize = null,
    /// The other end of the selection. Null, or the caret position, is no
    /// selection.
    anchor: ?usize = null,

    /// The bytes `start..end` of the text.
    pub const Selection = struct { start: usize, end: usize };

    pub fn slice(self: *const TextValue) []const u8 {
        return self.buffer[0..self.len];
    }

    pub fn clear(self: *TextValue) void {
        self.len = 0;
        self.caret = null;
        self.anchor = null;
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
        while (self.len > 0 and isContinuation(self.buffer[self.len])) self.len -= 1;
        return true;
    }

    /// `offset` moved back to a code point boundary, and into the text.
    fn boundary(self: *const TextValue, offset: usize) usize {
        var o = @min(offset, self.len);
        while (o > 0 and o < self.len and isContinuation(self.buffer[o])) o -= 1;
        return o;
    }

    fn prevBoundary(self: *const TextValue, offset: usize) usize {
        if (offset == 0) return 0;
        var o = offset - 1;
        while (o > 0 and isContinuation(self.buffer[o])) o -= 1;
        return o;
    }

    fn nextBoundary(self: *const TextValue, offset: usize) usize {
        if (offset >= self.len) return self.len;
        var o = offset + 1;
        while (o < self.len and isContinuation(self.buffer[o])) o += 1;
        return o;
    }

    /// The byte offset of the caret.
    pub fn caretPos(self: *const TextValue) usize {
        return if (self.caret) |c| self.boundary(c) else self.len;
    }

    /// The selection. `start == end` is no selection.
    pub fn selection(self: *const TextValue) Selection {
        const c = self.caretPos();
        const a = if (self.anchor) |x| self.boundary(x) else c;
        return .{ .start = @min(a, c), .end = @max(a, c) };
    }

    pub fn hasSelection(self: *const TextValue) bool {
        const s = self.selection();
        return s.end > s.start;
    }

    /// The selected text. It is valid until the next edit.
    pub fn selectedText(self: *const TextValue) []const u8 {
        const s = self.selection();
        return self.buffer[s.start..s.end];
    }

    /// Put the caret at `offset`. With `extend`, the selection goes from the
    /// old anchor (or the old caret) to the new caret.
    pub fn setCaret(self: *TextValue, offset: usize, extend: bool) void {
        const old = self.caretPos();
        const target = self.boundary(offset);
        if (extend) {
            if (self.anchor == null) self.anchor = old;
        } else {
            self.anchor = null;
        }
        self.caret = if (target == self.len) null else target;
    }

    pub fn selectAll(self: *TextValue) void {
        self.anchor = 0;
        self.caret = null;
    }

    /// Move the caret one code point back (in the order of the bytes). With
    /// no `extend`, a selection collapses to its start.
    pub fn moveLeft(self: *TextValue, extend: bool) void {
        const s = self.selection();
        if (!extend and s.end > s.start) return self.setCaret(s.start, false);
        self.setCaret(self.prevBoundary(self.caretPos()), extend);
    }

    /// Move the caret one code point forward. With no `extend`, a selection
    /// collapses to its end.
    pub fn moveRight(self: *TextValue, extend: bool) void {
        const s = self.selection();
        if (!extend and s.end > s.start) return self.setCaret(s.end, false);
        self.setCaret(self.nextBoundary(self.caretPos()), extend);
    }

    fn remove(self: *TextValue, start: usize, end: usize) void {
        std.mem.copyForwards(u8, self.buffer[start..], self.buffer[end..self.len]);
        self.len -= end - start;
    }

    /// Remove the selected text. False if nothing is selected.
    pub fn deleteSelection(self: *TextValue) bool {
        const s = self.selection();
        if (s.end == s.start) return false;
        self.remove(s.start, s.end);
        self.setCaret(s.start, false);
        return true;
    }

    /// Put `s` at the caret, in place of the selection. It is all or nothing:
    /// false if `s` is empty, is not valid UTF-8 or does not fit.
    pub fn insert(self: *TextValue, s: []const u8) bool {
        if (s.len == 0) return false;
        if (!std.unicode.utf8ValidateSlice(s)) return false;
        const sel = self.selection();
        if (self.len - (sel.end - sel.start) + s.len > self.buffer.len) return false;
        self.remove(sel.start, sel.end);
        std.mem.copyBackwards(u8, self.buffer[sel.start + s.len .. self.len + s.len], self.buffer[sel.start..self.len]);
        @memcpy(self.buffer[sel.start..][0..s.len], s);
        self.len += s.len;
        self.setCaret(sel.start + s.len, false);
        return true;
    }

    /// Remove the selection, or else the code point before the caret. False
    /// if nothing changed.
    pub fn deleteBackward(self: *TextValue) bool {
        if (self.deleteSelection()) return true;
        const c = self.caretPos();
        if (c == 0) return false;
        const p = self.prevBoundary(c);
        self.remove(p, c);
        self.setCaret(p, false);
        return true;
    }

    /// Remove the selection, or else the code point after the caret. False
    /// if nothing changed.
    pub fn deleteForward(self: *TextValue) bool {
        if (self.deleteSelection()) return true;
        const c = self.caretPos();
        if (c >= self.len) return false;
        self.remove(c, self.nextBoundary(c));
        self.setCaret(c, false);
        return true;
    }
};

/// The clipboard of the text fields. The platform gives one. Until it does,
/// `Ui.clipboard` is null and the text fields of one `Ui` share a clipboard
/// inside it.
pub const Clipboard = struct {
    context: ?*anyopaque = null,
    /// Keep `text` as the clipboard text. Called for copy and cut.
    writeFn: *const fn (context: ?*anyopaque, text: []const u8) void,
    /// The clipboard text, or empty. It must stay valid until `finish`
    /// returns. A platform that gets the text in a paste event gives the text
    /// of that event.
    readFn: *const fn (context: ?*anyopaque) []const u8,

    /// The platform clipboard of a `sw_app` Context: copy and cut write
    /// the system clipboard, and paste reads it. `ctx` is a pointer that
    /// stays valid while the `Ui` uses the clipboard. The call also turns
    /// off the paste as typed text of the web (`setPasteAsText(false)`), so
    /// a paste does not insert the text two times. On the web, the browser
    /// gives the text of a paste (Ctrl+V or Cmd+V) to the platform before
    /// the frame that has `Keys.paste`.
    pub fn platform(ctx: anytype) Clipboard {
        const Ctx = @typeInfo(@TypeOf(ctx)).pointer.child;
        ctx.setPasteAsText(false);
        const fns = struct {
            fn write(context: ?*anyopaque, text: []const u8) void {
                const c: *Ctx = @ptrCast(@alignCast(context.?));
                c.setClipboardText(text);
            }
            fn read(context: ?*anyopaque) []const u8 {
                const c: *Ctx = @ptrCast(@alignCast(context.?));
                return c.clipboardText();
            }
        };
        return .{ .context = ctx, .writeFn = fns.write, .readFn = fns.read };
    }
};

pub const Error = std.mem.Allocator.Error || error{
    /// The ID is 0 or `tooltip_id`.
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
const not_in_tree = std.math.maxInt(u32);

pub const Node = struct {
    kind: Kind,
    id: u32,
    /// The text of text, a button and a list item. The label of a list, a text
    /// field, a slider, a screen and a container. The description of an image.
    text: []const u8,
    opts: Opts,
    parent: usize,
    /// The index after the last descendant. For a leaf: its own index plus 1.
    subtree_end: usize,
    value: ?*TextValue = null,
    texture: u32 = 0,
    /// The value and the options of a slider.
    number: ?*f32 = null,
    slider: SliderOpts = .{},
    /// The size that the node wants, from `measureNode`.
    pref: Size = .{},
    rect: Rect = .{},
    /// The part of the window where the node shows: the window, cut by the
    /// scroll lists round the node.
    clip: Rect = .{},
    /// A scroll list: the height of its children and their gaps.
    content_h: f32 = 0,

    /// The part of the node that shows.
    pub fn visible(self: *const Node) Rect {
        return intersect(self.rect, self.clip);
    }
};

/// The part of `a` that is also in `b`.
pub fn intersect(a: Rect, b: Rect) Rect {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.w, b.x + b.w);
    const y1 = @min(a.y + a.h, b.y + b.h);
    return .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) };
}

const ListActive = struct {
    list: u32,
    item: u32,
};

const LiveState = struct {
    id: u32,
    hash: u64,
};

const ScrollState = struct {
    id: u32,
    offset: f32,
};

const DragKind = enum { none, slider, text, scrollbar };

const Drag = struct {
    kind: DragKind = .none,
    id: u32 = 0,
    /// A scroll bar: the distance from the top of the thumb to the pointer.
    grab: f32 = 0,
};

const TipState = struct {
    /// The node whose tooltip can show, or 0.
    target: u32 = 0,
    /// Frames since `target` changed.
    frames: u32 = 0,
    /// A click or Escape hid the tooltip until the target changes.
    hidden: bool = false,
    shown: bool = false,
    text: []const u8 = "",
    rect: Rect = .{},
};

/// The tooltip that shows.
pub const Tooltip = struct {
    target: u32,
    text: []const u8,
    rect: Rect,
};

/// The parts of a slider, for drawing.
pub const SliderParts = struct {
    /// The line that the thumb moves on.
    track: Rect,
    /// The part of the track from `min` to the value.
    fill: Rect,
    thumb: Rect,
};

/// The parts of the scroll bar of a scroll list.
pub const ScrollBar = struct {
    track: Rect,
    thumb: Rect,
    /// The largest scroll offset.
    max: f32,
};

const Dir = enum { left, right, up, down };

fn isContainer(kind: Kind) bool {
    return switch (kind) {
        .row, .column, .list, .scroll_list, .screen => true,
        else => false,
    };
}

fn isListKind(kind: Kind) bool {
    return kind == .list or kind == .scroll_list;
}

fn isFocusableKind(kind: Kind) bool {
    return switch (kind) {
        .button, .list_item, .text_field, .slider => true,
        else => false,
    };
}

pub const Ui = struct {
    alloc: std.mem.Allocator,
    theme: Theme,
    measurer: Measurer,
    /// The clipboard of the text fields. Null uses a clipboard inside this
    /// `Ui`.
    clipboard: ?Clipboard = null,

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
    pending_first: bool = false,
    /// The list item that is the tab stop of each list, and the node that is
    /// the tab stop of each container with `arrows`.
    list_active: std.ArrayList(ListActive) = .empty,
    text_input_wanted: bool = false,
    /// The scroll offset of each scroll list (down) and text field (right).
    scroll_state: std.ArrayList(ScrollState) = .empty,
    local_clipboard: std.ArrayList(u8) = .empty,
    drag: Drag = .{},
    /// The index of the screen that takes input, or null.
    top_screen: ?usize = null,
    tip: TipState = .{},
    relayout: bool = false,

    live_prev: std.ArrayList(LiveState) = .empty,
    live_next: std.ArrayList(LiveState) = .empty,
    sem_nodes: std.ArrayList(SemanticNode) = .empty,
    sem_children: std.ArrayList(u32) = .empty,
    sem_map: std.ArrayList(u32) = .empty,
    sem_spans: std.ArrayList([2]u32) = .empty,
    /// The web build sends the semantic tree to the screen-reader mirror in
    /// `finish` (REQ-A11Y-001). Set `web_mirror.enabled` to false to stop it.
    web_mirror: web_mirror.WebMirror = .{},

    pub fn init(alloc: std.mem.Allocator, measurer: Measurer, theme: Theme) Ui {
        return .{ .alloc = alloc, .theme = theme, .measurer = measurer };
    }

    pub fn deinit(self: *Ui) void {
        self.nodes.deinit(self.alloc);
        self.events.deinit(self.alloc);
        self.list_active.deinit(self.alloc);
        self.scroll_state.deinit(self.alloc);
        self.local_clipboard.deinit(self.alloc);
        self.live_prev.deinit(self.alloc);
        self.live_next.deinit(self.alloc);
        self.sem_nodes.deinit(self.alloc);
        self.sem_children.deinit(self.alloc);
        self.sem_map.deinit(self.alloc);
        self.sem_spans.deinit(self.alloc);
        self.web_mirror.clear();
        self.web_mirror.deinit(self.alloc);
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
        self.top_screen = null;
        self.tip.shown = false;
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

    /// Open a scroll list: a list that shows a part of its children and
    /// scrolls. Give it a fixed or fill height. The mouse wheel and the
    /// scroll bar scroll it, and a child that gets focus scrolls into view.
    /// The children can be list items or any other nodes. Close it with
    /// `endContainer`.
    pub fn beginScrollList(self: *Ui, id: u32, name: []const u8, opts: Opts) Error!void {
        try self.open(.scroll_list, id, name, opts);
    }

    /// Open a screen: a column that is a modal layer. It covers the inside
    /// of its parent (the window, for a child of the root), and takes no
    /// room in the layout of the parent. When the tree has a screen, the last
    /// screen in tree order is the top screen. Only the
    /// nodes in it take focus and input, and the semantic tree leaves out the
    /// other nodes. `title` is the accessible name. Close it with
    /// `endContainer`. `ScreenStack` (screen.zig) keeps the order of screens.
    pub fn beginScreen(self: *Ui, id: u32, title: []const u8, opts: Opts) Error!void {
        try self.open(.screen, id, title, opts);
    }

    /// Close the container that a `begin` function opened last.
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

    /// A slider. `name` is the accessible name. The value is in `value`,
    /// which the app owns. The arrow keys, Home, End, a click and a drag
    /// change it, and each change sends a `changed` event.
    pub fn addSlider(self: *Ui, id: u32, name: []const u8, value: *f32, slider: SliderOpts, opts: Opts) Error!void {
        const index = try self.addNode(.slider, id, name, opts);
        self.nodes.items[index].number = value;
        self.nodes.items[index].slider = slider;
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
        if (id == root_id or id == tooltip_id) return error.InvalidId;
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
        self.pending_first = false;
    }

    /// Move focus to the first tab stop (of the top screen, if there is a
    /// screen). It takes effect in `finish`.
    pub fn focusFirst(self: *Ui) void {
        self.pending_first = true;
        self.pending_focus = null;
    }

    /// Remove focus.
    pub fn clearFocus(self: *Ui) void {
        self.focus_id = 0;
        self.pending_focus = null;
        self.pending_first = false;
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

    /// The events of the last `finish`: activations, cancel, and changes.
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

    /// The scroll offset of a scroll list (down) or a text field (right).
    pub fn scrollOf(self: *const Ui, id: u32) f32 {
        for (self.scroll_state.items) |s| {
            if (s.id == id) return s.offset;
        }
        return 0;
    }

    /// The tooltip that shows after the last `finish`, or null.
    pub fn tooltip(self: *const Ui) ?Tooltip {
        if (!self.tip.shown) return null;
        return .{ .target = self.tip.target, .text = self.tip.text, .rect = self.tip.rect };
    }

    /// True when the node at `index` takes input: there is no screen, or the
    /// node is in the top screen.
    pub fn isActive(self: *const Ui, index: usize) bool {
        const top = self.top_screen orelse return true;
        return index >= top and index < self.nodes.items[top].subtree_end;
    }

    // ---- The end of the frame -------------------------------------------

    /// End the frame: lay out the tree, apply the input, build the semantic
    /// tree. The tree is then ready to draw. On the web build, also send the
    /// semantic tree to the screen-reader mirror when it changed.
    pub fn finish(self: *Ui) Error!void {
        if (!self.in_frame) return error.NotInFrame;
        self.in_frame = false;
        if (self.depth != 1 or self.unbalanced) return error.UnbalancedTree;
        self.nodes.items[0].subtree_end = self.nodes.items.len;
        try self.checkIds();

        self.top_screen = null;
        for (self.nodes.items, 0..) |n, i| {
            if (n.kind == .screen) self.top_screen = i;
        }

        self.measureNode(0);
        self.layout();

        self.relayout = false;
        try self.applyInput();
        if (self.relayout) self.layout();
        self.updateTooltip();
        try self.buildSemantic();
        try self.web_mirror.publish(self.alloc, self.semanticTree());
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
            .button, .list_item, .text_field, .slider => self.theme.control_pad,
            else => 0,
        };
    }

    /// The rectangle of a node less its padding.
    pub fn innerRect(self: *const Ui, n: *const Node) Rect {
        const pad = if (isContainer(n.kind)) n.opts.padding orelse 0 else self.leafPadding(n);
        return .{
            .x = n.rect.x + pad,
            .y = n.rect.y + pad,
            .w = @max(0, n.rect.w - 2 * pad),
            .h = @max(0, n.rect.h - 2 * pad),
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
                // A screen covers its parent and takes no room in it.
                if (child.kind == .screen) continue;
                const child_main = if (horizontal) child.pref.w else child.pref.h;
                const child_cross = if (horizontal) child.pref.h else child.pref.w;
                main += child_main;
                cross = @max(cross, child_cross);
                count += 1;
            }
            if (count > 1) main += n.opts.gap * (count - 1);
            if (n.kind == .scroll_list) cross += self.theme.scrollbar;
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
                .text_field, .slider => {
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

    fn layout(self: *Ui) void {
        const window: Rect = .{ .x = 0, .y = 0, .w = self.viewport.w, .h = self.viewport.h };
        self.arrange(0, window, window);
    }

    fn scrollPtr(self: *Ui, id: u32) ?*f32 {
        for (self.scroll_state.items) |*s| {
            if (s.id == id) return &s.offset;
        }
        return null;
    }

    fn setScroll(self: *Ui, id: u32, offset: f32) Error!void {
        if (self.scrollPtr(id)) |p| {
            p.* = offset;
            return;
        }
        try self.scroll_state.append(self.alloc, .{ .id = id, .offset = offset });
    }

    /// Give a node its rectangle, then its children theirs, top down.
    fn arrange(self: *Ui, index: usize, rect: Rect, clip: Rect) void {
        const n = &self.nodes.items[index];
        n.rect = rect;
        n.clip = clip;
        if (!isContainer(n.kind)) return;

        const scrolls = n.kind == .scroll_list;
        var inner = self.innerRect(n);
        var child_clip = clip;
        if (scrolls) {
            inner.w = @max(0, inner.w - self.theme.scrollbar);
            child_clip = intersect(clip, inner);
        }
        const horizontal = n.kind == .row;
        const inner_main = if (horizontal) inner.w else inner.h;
        const inner_cross = if (horizontal) inner.h else inner.w;
        const gap = n.opts.gap;

        // The space that fixed and fit children use, and the number of fills.
        // In a scroll list, a fill on the main axis is a fit.
        var used: f32 = 0;
        var fills: f32 = 0;
        var count: f32 = 0;
        var c = index + 1;
        while (c < n.subtree_end) : (c = self.nodes.items[c].subtree_end) {
            const child = &self.nodes.items[c];
            if (child.kind == .screen) continue;
            count += 1;
            const dim = if (horizontal) child.opts.w else child.opts.h;
            if (dim == .fill and !scrolls) {
                fills += 1;
            } else {
                used += if (horizontal) child.pref.w else child.pref.h;
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

        if (scrolls) {
            n.content_h = used + gaps;
            const max = @max(0, n.content_h - inner.h);
            if (self.scrollPtr(n.id)) |p| {
                p.* = std.math.clamp(p.*, 0, max);
                cursor -= p.*;
            }
        }

        c = index + 1;
        while (c < n.subtree_end) : (c = self.nodes.items[c].subtree_end) {
            const child = &self.nodes.items[c];
            if (child.kind == .screen) {
                self.arrange(c, inner, child_clip);
                continue;
            }
            const main_dim = if (horizontal) child.opts.w else child.opts.h;
            const cross_dim = if (horizontal) child.opts.h else child.opts.w;
            const child_main = if (main_dim == .fill and !scrolls)
                share
            else if (horizontal) child.pref.w else child.pref.h;
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
            self.arrange(c, child_rect, child_clip);
            cursor += child_main + gap;
        }
    }

    // ---- Widget geometry ------------------------------------------------

    /// The parts of the slider at `index`.
    pub fn sliderParts(self: *const Ui, index: usize) SliderParts {
        const n = &self.nodes.items[index];
        const inner = self.innerRect(n);
        const thumb_w = self.theme.slider_thumb;
        const track_h = @max(2, inner.h / 6);
        const track: Rect = .{
            .x = inner.x + thumb_w / 2,
            .y = inner.y + (inner.h - track_h) / 2,
            .w = @max(0, inner.w - thumb_w),
            .h = track_h,
        };
        const range = n.slider.max - n.slider.min;
        const v = if (n.number) |p| p.* else n.slider.min;
        const t = if (range != 0) std.math.clamp((v - n.slider.min) / range, 0, 1) else 0;
        const x = track.x + track.w * t;
        return .{
            .track = track,
            .fill = .{ .x = track.x, .y = track.y, .w = x - track.x, .h = track.h },
            .thumb = .{ .x = x - thumb_w / 2, .y = inner.y, .w = thumb_w, .h = inner.h },
        };
    }

    /// The scroll bar of the scroll list at `index`, or null when all of its
    /// children show.
    pub fn scrollBar(self: *const Ui, index: usize) ?ScrollBar {
        const n = &self.nodes.items[index];
        if (n.kind != .scroll_list) return null;
        const inner = self.innerRect(n);
        const max = n.content_h - inner.h;
        if (max <= 0 or inner.h <= 0) return null;
        const w = self.theme.scrollbar;
        const track: Rect = .{ .x = inner.x + inner.w - w, .y = inner.y, .w = w, .h = inner.h };
        const thumb_h = std.math.clamp(inner.h * inner.h / n.content_h, @min(2 * w, track.h), track.h);
        const offset = std.math.clamp(self.scrollOf(n.id), 0, max);
        const thumb_y = track.y + (track.h - thumb_h) * offset / max;
        return .{ .track = track, .thumb = .{ .x = track.x, .y = thumb_y, .w = w, .h = thumb_h }, .max = max };
    }

    // ---- Input ------------------------------------------------------------

    fn isFocusableNode(self: *const Ui, index: usize) bool {
        const n = &self.nodes.items[index];
        return isFocusableKind(n.kind) and !n.opts.disabled and self.isActive(index);
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
            if (child.kind != .list_item or !self.isFocusableNode(c)) continue;
            if (child.id == self.focus_id) with_focus = c;
            if (stored != null and stored.? == child.id) remembered = c;
            if (child.opts.selected and chosen == null) chosen = c;
            if (first == null) first = c;
        }
        return with_focus orelse remembered orelse chosen orelse first;
    }

    /// The innermost container with `arrows` round the node at `index`.
    fn arrowsContainer(self: *const Ui, index: usize) ?usize {
        var p = self.nodes.items[index].parent;
        while (p != no_parent) : (p = self.nodes.items[p].parent) {
            if (self.nodes.items[p].opts.arrows) return p;
        }
        return null;
    }

    /// The node that Tab reaches in a container with `arrows`: the one with
    /// focus, else the last one that had focus, else the first.
    fn arrowsTabItem(self: *const Ui, container: usize) ?usize {
        const stored = self.activeFor(self.nodes.items[container].id);
        var with_focus: ?usize = null;
        var remembered: ?usize = null;
        var first: ?usize = null;
        for (container + 1..self.nodes.items[container].subtree_end) |c| {
            if (!self.isFocusableNode(c)) continue;
            const id = self.nodes.items[c].id;
            if (id == self.focus_id) with_focus = c;
            if (stored != null and stored.? == id) remembered = c;
            if (first == null) first = c;
        }
        return with_focus orelse remembered orelse first;
    }

    fn isTabStop(self: *const Ui, index: usize) bool {
        if (!self.isFocusableNode(index)) return false;
        const n = &self.nodes.items[index];
        if (n.kind == .list_item and n.parent != no_parent and isListKind(self.nodes.items[n.parent].kind)) {
            const stop = self.listTabItem(n.parent) orelse return false;
            return stop == index;
        }
        if (self.arrowsContainer(index)) |container| {
            const stop = self.arrowsTabItem(container) orelse return false;
            return stop == index;
        }
        return true;
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
        if (!isListKind(list.kind)) return null;
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
            if (child.kind != .list_item or !self.isFocusableNode(c)) continue;
            if (!passed) {
                before = c;
            } else if (after == null) {
                after = c;
            }
        }
        return if (forward) after else before;
    }

    /// The first or last enabled list item of the list round `index`.
    fn endItem(self: *const Ui, index: usize, last: bool) ?usize {
        const parent = self.nodes.items[index].parent;
        const list = &self.nodes.items[parent];
        var found: ?usize = null;
        var c = parent + 1;
        while (c < list.subtree_end) : (c = self.nodes.items[c].subtree_end) {
            if (self.nodes.items[c].kind != .list_item or !self.isFocusableNode(c)) continue;
            if (!last) return c;
            found = c;
        }
        return found;
    }

    /// The node that takes focus nearest to `index` in direction `dir`, in
    /// the same container with `arrows`. A node is nearer when it is less far
    /// on the axis of the key and less far to the side, with the side
    /// distance counted two times.
    fn spatialNext(self: *const Ui, index: usize, dir: Dir) ?usize {
        const container = self.arrowsContainer(index) orelse return null;
        const from = self.nodes.items[index].rect;
        const fx = from.x + from.w / 2;
        const fy = from.y + from.h / 2;
        var best: ?usize = null;
        var best_score = std.math.inf(f32);
        for (container + 1..self.nodes.items[container].subtree_end) |c| {
            if (c == index or !self.isFocusableNode(c)) continue;
            const r = self.nodes.items[c].rect;
            const dx = r.x + r.w / 2 - fx;
            const dy = r.y + r.h / 2 - fy;
            const along: f32, const side: f32 = switch (dir) {
                .right => .{ dx, dy },
                .left => .{ -dx, dy },
                .down => .{ dy, dx },
                .up => .{ -dy, dx },
            };
            if (along < 0.5) continue;
            const score = along + 2 * @abs(side);
            if (score < best_score) {
                best_score = score;
                best = c;
            }
        }
        return best;
    }

    fn emit(self: *Ui, kind: EventKind, id: u32) Error!void {
        try self.events.append(self.alloc, .{ .kind = kind, .id = id });
    }

    /// The topmost node under the pointer that takes focus, or null.
    fn hitTest(self: *const Ui, x: f32, y: f32) ?usize {
        var i = self.nodes.items.len;
        while (i > 0) {
            i -= 1;
            if (!self.isFocusableNode(i)) continue;
            if (self.nodes.items[i].visible().contains(x, y)) return i;
        }
        return null;
    }

    /// The innermost scroll list under the pointer that takes input.
    fn scrollListAt(self: *const Ui, x: f32, y: f32) ?usize {
        var i = self.nodes.items.len;
        while (i > 0) {
            i -= 1;
            const n = &self.nodes.items[i];
            if (n.kind != .scroll_list or !self.isActive(i)) continue;
            if (n.visible().contains(x, y)) return i;
        }
        return null;
    }

    /// Set the scroll offset of the scroll list at `index`, in its limits.
    fn scrollTo(self: *Ui, index: usize, offset: f32) Error!void {
        const n = &self.nodes.items[index];
        const max = @max(0, n.content_h - self.innerRect(n).h);
        const clamped = std.math.clamp(offset, 0, max);
        if (clamped == self.scrollOf(n.id)) return;
        try self.setScroll(n.id, clamped);
        self.relayout = true;
    }

    fn dragScrollBar(self: *Ui, index: usize, y: f32) Error!void {
        const bar = self.scrollBar(index) orelse return;
        const room = bar.track.h - bar.thumb.h;
        if (room <= 0) return;
        const top = y - self.drag.grab - bar.track.y;
        try self.scrollTo(index, top / room * bar.max);
    }

    fn sliderStep(n: *const Node) f32 {
        return if (n.slider.step > 0) n.slider.step else (n.slider.max - n.slider.min) / 100;
    }

    /// Set the value of a slider, snapped to a step and in its limits. True
    /// when the value changed.
    fn setSlider(n: *const Node, value: f32) bool {
        const p = n.number orelse return false;
        const lo = @min(n.slider.min, n.slider.max);
        const hi = @max(n.slider.min, n.slider.max);
        var v = std.math.clamp(value, lo, hi);
        if (n.slider.step > 0) {
            v = n.slider.min + @round((v - n.slider.min) / n.slider.step) * n.slider.step;
            v = std.math.clamp(v, lo, hi);
        }
        if (v == p.*) return false;
        p.* = v;
        return true;
    }

    fn sliderFromPointer(self: *const Ui, index: usize) bool {
        const n = &self.nodes.items[index];
        const track = self.sliderParts(index).track;
        const t = if (track.w > 0) std.math.clamp((self.input.pointer_x - track.x) / track.w, 0, 1) else 0;
        return setSlider(n, n.slider.min + t * (n.slider.max - n.slider.min));
    }

    /// The arrow keys, Home and End on a slider. True when the value changed.
    fn sliderKeys(n: *const Node, keys: Keys) bool {
        const p = n.number orelse return false;
        var v = p.*;
        const step = sliderStep(n);
        if (keys.right or keys.up) v += step;
        if (keys.left or keys.down) v -= step;
        if (keys.home) v = n.slider.min;
        if (keys.end) v = n.slider.max;
        return setSlider(n, v);
    }

    /// Put the caret of the text field at `index` under the pointer.
    fn caretFromPointer(self: *Ui, index: usize, extend: bool) void {
        const n = &self.nodes.items[index];
        const value = n.value orelse return;
        const x0 = self.innerRect(n).x - self.scrollOf(n.id);
        const offset = self.measurer.offsetAt(value.slice(), self.theme.text_size, self.input.pointer_x - x0);
        value.setCaret(offset, extend);
    }

    fn writeClipboard(self: *Ui, text: []const u8) Error!void {
        if (self.clipboard) |c| return c.writeFn(c.context, text);
        self.local_clipboard.clearRetainingCapacity();
        try self.local_clipboard.appendSlice(self.alloc, text);
    }

    fn readClipboard(self: *const Ui) []const u8 {
        if (self.clipboard) |c| return c.readFn(c.context);
        return self.local_clipboard.items;
    }

    /// The keys and the text of a frame on a text field. True when the text
    /// changed.
    fn editText(self: *Ui, value: *TextValue) Error!bool {
        const input = self.input;
        const keys = input.keys;
        var edited = false;
        if (keys.select_all) value.selectAll();
        if ((keys.copy or keys.cut) and value.hasSelection()) {
            try self.writeClipboard(value.selectedText());
            if (keys.cut and value.deleteSelection()) edited = true;
        }
        if (keys.paste) {
            // One line only, cut to the room that is left.
            var paste = self.readClipboard();
            if (std.mem.indexOfAny(u8, paste, "\r\n")) |nl| paste = paste[0..nl];
            const sel = value.selection();
            const room = value.buffer.len - (value.len - (sel.end - sel.start));
            if (paste.len > room) {
                var cut = room;
                while (cut > 0 and isContinuation(paste[cut])) cut -= 1;
                paste = paste[0..cut];
            }
            if (value.insert(paste)) edited = true;
        }
        if (value.insert(input.text)) edited = true;
        if (keys.backspace and value.deleteBackward()) edited = true;
        if (keys.delete and value.deleteForward()) edited = true;
        if (keys.left) value.moveLeft(input.shift);
        if (keys.right) value.moveRight(input.shift);
        if (keys.home) value.setCaret(0, input.shift);
        if (keys.end) value.setCaret(value.len, input.shift);
        return edited;
    }

    /// Scroll the text field at `index` so that its caret shows.
    fn followCaret(self: *Ui, index: usize) Error!void {
        const n = &self.nodes.items[index];
        const value = n.value orelse return;
        const size = self.theme.text_size;
        const text = value.slice();
        // The caret is 2 pixels wide.
        const room = @max(0, self.innerRect(n).w - 2);
        const caret = self.measurer.caretX(text, size, value.caretPos());
        const total = self.measurer.measureText(text, size).w;
        const old = self.scrollOf(n.id);
        var offset = old;
        if (caret - offset > room) offset = caret - room;
        if (caret < offset) offset = caret;
        offset = std.math.clamp(offset, 0, @max(0, total - room));
        if (offset != old) try self.setScroll(n.id, offset);
    }

    /// Scroll the scroll list round the node at `index` so that the node
    /// shows.
    fn scrollIntoView(self: *Ui, index: usize) Error!void {
        var p = self.nodes.items[index].parent;
        while (p != no_parent) : (p = self.nodes.items[p].parent) {
            if (self.nodes.items[p].kind == .scroll_list) break;
        } else return;
        const list = &self.nodes.items[p];
        const view = self.innerRect(list);
        const r = self.nodes.items[index].rect;
        var offset = self.scrollOf(list.id);
        if (r.y < view.y) offset -= view.y - r.y;
        if (r.y + r.h > view.y + view.h) offset += r.y + r.h - (view.y + view.h);
        try self.scrollTo(p, offset);
    }

    fn moveFocus(self: *Ui, current: *?usize, to: usize) void {
        current.* = to;
        self.focus_id = self.nodes.items[to].id;
    }

    fn applyInput(self: *Ui) Error!void {
        const input = self.input;
        const keys = input.keys;
        const start_focus = self.focus_id;

        // A focus request from the app, then a focus that points at nothing.
        if (self.pending_first) {
            self.pending_first = false;
            self.focus_id = 0;
            if (self.nextStop(null, true)) |first| self.focus_id = self.nodes.items[first].id;
        }
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

        // The pointer: a click on a scroll bar, else on the topmost node
        // under the pointer that takes focus. Then a drag while it is down.
        const px = input.pointer_x;
        const py = input.pointer_y;
        if (!input.pointer_down and !input.pointer_pressed) self.drag = .{};
        if (input.pointer_pressed) {
            self.drag = .{};
            var bar_hit: ?usize = null;
            var i = self.nodes.items.len;
            while (i > 0) {
                i -= 1;
                if (!self.isActive(i)) continue;
                const bar = self.scrollBar(i) orelse continue;
                if (!intersect(bar.track, self.nodes.items[i].clip).contains(px, py)) continue;
                const grab = if (bar.thumb.contains(px, py)) py - bar.thumb.y else bar.thumb.h / 2;
                self.drag = .{ .kind = .scrollbar, .id = self.nodes.items[i].id, .grab = grab };
                bar_hit = i;
                break;
            }
            if (bar_hit) |index| {
                try self.dragScrollBar(index, py);
            } else if (self.hitTest(px, py)) |index| {
                const n = &self.nodes.items[index];
                self.moveFocus(&current, index);
                switch (n.kind) {
                    .button, .list_item => try self.emit(.activate, n.id),
                    .slider => {
                        self.drag = .{ .kind = .slider, .id = n.id };
                        if (self.sliderFromPointer(index)) try self.emit(.changed, n.id);
                    },
                    .text_field => {
                        self.drag = .{ .kind = .text, .id = n.id };
                        self.caretFromPointer(index, input.shift);
                    },
                    else => {},
                }
            }
        } else if (input.pointer_down and self.drag.kind != .none) {
            if (self.indexOf(self.drag.id)) |index| {
                switch (self.drag.kind) {
                    .slider => if (self.isFocusableNode(index) and self.sliderFromPointer(index)) {
                        try self.emit(.changed, self.drag.id);
                    },
                    .text => if (self.isFocusableNode(index)) self.caretFromPointer(index, true),
                    .scrollbar => try self.dragScrollBar(index, py),
                    .none => {},
                }
            } else self.drag = .{};
        }

        // The mouse wheel scrolls the scroll list under the pointer.
        if (input.wheel_y != 0) {
            if (self.scrollListAt(px, py)) |index| {
                const id = self.nodes.items[index].id;
                try self.scrollTo(index, self.scrollOf(id) - input.wheel_y * self.theme.scroll_step);
            }
        }

        // Text, Backspace, Delete, the caret keys and the clipboard edit the
        // field that has focus.
        if (current) |index| {
            const n = &self.nodes.items[index];
            if (n.kind == .text_field) {
                if (n.value) |value| {
                    if (try self.editText(value)) try self.emit(.changed, n.id);
                }
            }
        }

        // Tab and Shift+Tab.
        if (keys.tab) {
            if (self.nextStop(current, !input.shift)) |next| self.moveFocus(&current, next);
        }

        // The arrow keys, Home and End: in a list, on a slider, then in a
        // container with `arrows`. A text field uses them for its caret.
        if (current) |index| {
            const n = &self.nodes.items[index];
            var used = false;
            switch (n.kind) {
                .list_item => if (n.parent != no_parent and isListKind(self.nodes.items[n.parent].kind)) {
                    if (keys.up or keys.down) {
                        used = true;
                        if (self.neighbourItem(index, keys.down)) |next| self.moveFocus(&current, next);
                    } else if (keys.home or keys.end) {
                        if (self.endItem(index, keys.end)) |next| self.moveFocus(&current, next);
                    }
                },
                .slider => {
                    used = true;
                    if (sliderKeys(n, keys)) try self.emit(.changed, n.id);
                },
                .text_field => used = true,
                else => {},
            }
            if (!used) {
                const dir: ?Dir = if (keys.left) .left else if (keys.right) .right else if (keys.up) .up else if (keys.down) .down else null;
                if (dir) |d| {
                    if (self.spatialNext(index, d)) |next| self.moveFocus(&current, next);
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

        // The list or `arrows` container that holds the focus remembers it,
        // for the next Tab.
        if (current) |index| {
            const n = &self.nodes.items[index];
            if (n.kind == .list_item and n.parent != no_parent) {
                const list = &self.nodes.items[n.parent];
                if (isListKind(list.kind)) try self.setActive(list.id, n.id);
            }
            if (self.arrowsContainer(index)) |container| {
                try self.setActive(self.nodes.items[container].id, n.id);
            }
        }

        if (current) |index| {
            if (self.focus_id != start_focus) try self.scrollIntoView(index);
            if (self.nodes.items[index].kind == .text_field) try self.followCaret(index);
        }

        self.text_input_wanted = if (current) |index| self.nodes.items[index].kind == .text_field else false;
    }

    // ---- Tooltip ----------------------------------------------------------

    fn updateTooltip(self: *Ui) void {
        const input = self.input;
        // The node under the pointer with a tooltip, else the focused node.
        var candidate: ?usize = null;
        var i = self.nodes.items.len;
        while (i > 0) {
            i -= 1;
            const n = &self.nodes.items[i];
            if (n.opts.tooltip.len == 0 or !self.isActive(i)) continue;
            if (n.visible().contains(input.pointer_x, input.pointer_y)) {
                candidate = i;
                break;
            }
        }
        if (candidate == null and self.focus_id != 0) {
            if (self.indexOf(self.focus_id)) |f| {
                if (self.nodes.items[f].opts.tooltip.len > 0) candidate = f;
            }
        }

        const id = if (candidate) |c| self.nodes.items[c].id else 0;
        if (id != self.tip.target) {
            self.tip = .{ .target = id };
        } else if (self.tip.frames < std.math.maxInt(u32)) {
            self.tip.frames += 1;
        }
        if (input.pointer_pressed or input.keys.escape) self.tip.hidden = true;
        const index = candidate orelse return;
        if (self.tip.hidden or self.tip.frames < self.theme.tooltip_delay) return;

        // Below the node, or above it when there is no room below.
        const n = &self.nodes.items[index];
        const pad = self.theme.control_pad / 2;
        const m = self.measurer.measureText(n.opts.tooltip, self.theme.text_size);
        const w = m.w + 2 * pad;
        const h = m.h + 2 * pad;
        const target = n.visible();
        var y = target.y + target.h + 4;
        if (y + h > self.viewport.h) y = target.y - h - 4;
        const x = std.math.clamp(target.x, 0, @max(0, self.viewport.w - w));
        self.tip.shown = true;
        self.tip.text = n.opts.tooltip;
        self.tip.rect = .{ .x = x, .y = @max(0, y), .w = w, .h = h };
    }

    // ---- The semantic tree --------------------------------------------

    fn roleOf(kind: Kind) Role {
        return switch (kind) {
            .row, .column => .group,
            .text => .text,
            .button => .button,
            .list, .scroll_list => .list,
            .list_item => .list_item,
            .text_field => .text_field,
            .image => .image,
            .slider => .slider,
            .screen => .dialog,
        };
    }

    fn lastHash(self: *const Ui, id: u32) ?u64 {
        for (self.live_prev.items) |entry| {
            if (entry.id == id) return entry.hash;
        }
        return null;
    }

    /// True when the node at `index` is in the semantic tree: it is active,
    /// or it holds the top screen (REQ-A11Y-006).
    fn inSemantic(self: *const Ui, index: usize) bool {
        const top = self.top_screen orelse return true;
        if (index >= top) return index < self.nodes.items[top].subtree_end;
        return self.nodes.items[index].subtree_end > top;
    }

    /// The value of a slider as text, in the per-frame buffer. The number of
    /// decimals comes from the step.
    fn sliderText(self: *Ui, n: *const Node) []const u8 {
        if (n.slider.format) |format| {
            const v = if (n.number) |p| p.* else n.slider.min;
            var buf: [64]u8 = undefined;
            return self.print("{s}", .{format(v, &buf)}) catch "";
        }
        if (n.slider.text.len > 0) return n.slider.text;
        const v = if (n.number) |p| p.* else return "";
        var decimals: u8 = 0;
        var s = sliderStep(n);
        while (decimals < 4 and s > 0 and @abs(s - @round(s)) > 1e-4) : (decimals += 1) s *= 10;
        const out = switch (decimals) {
            0 => self.print("{d:.0}", .{v}),
            1 => self.print("{d:.1}", .{v}),
            2 => self.print("{d:.2}", .{v}),
            3 => self.print("{d:.3}", .{v}),
            else => self.print("{d:.4}", .{v}),
        };
        return out catch "";
    }

    fn buildSemantic(self: *Ui) Error!void {
        const items = self.nodes.items;
        self.sem_nodes.clearRetainingCapacity();
        self.sem_children.clearRetainingCapacity();
        self.sem_map.clearRetainingCapacity();
        self.sem_spans.clearRetainingCapacity();
        self.live_next.clearRetainingCapacity();

        // The index of each node in the semantic tree.
        var count: u32 = 0;
        for (0..items.len) |i| {
            if (self.inSemantic(i)) {
                try self.sem_map.append(self.alloc, count);
                count += 1;
            } else {
                try self.sem_map.append(self.alloc, not_in_tree);
            }
        }
        const tip_index: ?u32 = if (self.tip.shown) count else null;
        const map = self.sem_map.items;

        // The children of each node, one run after another, in node order.
        // The tooltip is the last child of the root.
        for (items, 0..) |n, i| {
            const start: u32 = @intCast(self.sem_children.items.len);
            if (map[i] != not_in_tree) {
                var c = i + 1;
                while (c < n.subtree_end) : (c = items[c].subtree_end) {
                    if (map[c] != not_in_tree) try self.sem_children.append(self.alloc, map[c]);
                }
                if (i == 0) {
                    if (tip_index) |t| try self.sem_children.append(self.alloc, t);
                }
            }
            try self.sem_spans.append(self.alloc, .{ start, @as(u32, @intCast(self.sem_children.items.len)) });
        }

        for (items, 0..) |*n, i| {
            if (map[i] == not_in_tree) continue;
            const live = n.kind == .text and n.opts.live;
            var changed = false;
            if (live) {
                const hash = std.hash.Wyhash.hash(0, n.text);
                if (self.lastHash(n.id)) |old| changed = old != hash;
                try self.live_next.append(self.alloc, .{ .id = n.id, .hash = hash });
            }

            var value: []const u8 = "";
            var range: ?semantic.Range = null;
            if (n.value) |v| value = v.slice();
            if (n.kind == .slider) {
                value = self.sliderText(n);
                range = .{
                    .value = if (n.number) |p| p.* else n.slider.min,
                    .min = n.slider.min,
                    .max = n.slider.max,
                };
            }

            const span = self.sem_spans.items[i];
            try self.sem_nodes.append(self.alloc, .{
                .id = n.id,
                .role = roleOf(n.kind),
                .name = n.text,
                .value = value,
                .focused = n.id == self.focus_id and n.id != root_id,
                .disabled = n.opts.disabled,
                .selected = n.opts.selected,
                .live = live,
                .changed = changed,
                .bounds = n.rect,
                .children = self.sem_children.items[span[0]..span[1]],
                .description = n.opts.tooltip,
                .range = range,
            });
        }

        if (self.tip.shown) {
            try self.sem_nodes.append(self.alloc, .{
                .id = tooltip_id,
                .role = .tooltip,
                .name = self.tip.text,
                .value = "",
                .focused = false,
                .disabled = false,
                .selected = false,
                .live = false,
                .changed = false,
                .bounds = self.tip.rect,
                .children = &.{},
            });
        }

        std.mem.swap(std.ArrayList(LiveState), &self.live_prev, &self.live_next);
    }
};

// ---- Tests ----------------------------------------------------------------

test {
    _ = web_mirror;
}

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

// ---- Tests of the widgets ---------------------------------------------------

var test_volume: f32 = 0.5;

fn buildSlider(u: *Ui) anyerror!void {
    try u.beginColumn(1, .{});
    try u.addSlider(2, "Volume", &test_volume, .{ .min = 0, .max = 1, .step = 0.1 }, .{ .w = .{ .fixed = 132 }, .tooltip = "Sound level" });
    u.endContainer();
}

test "slider: the arrow keys, Home and End change the value" {
    var u = testUi();
    defer u.deinit();
    test_volume = 0.5;
    u.setFocus(2);
    try runFrame(&u, .{ .keys = .{ .right = true } }, buildSlider);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), test_volume, 1e-5);
    try std.testing.expectEqual(@as(usize, 1), u.frameEvents().len);
    try std.testing.expectEqual(EventKind.changed, u.frameEvents()[0].kind);
    try runFrame(&u, .{ .keys = .{ .down = true } }, buildSlider);
    try runFrame(&u, .{ .keys = .{ .left = true } }, buildSlider);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), test_volume, 1e-5);
    try runFrame(&u, .{ .keys = .{ .end = true } }, buildSlider);
    try std.testing.expectEqual(@as(f32, 1), test_volume);
    // At the limit, no change and no event.
    try runFrame(&u, .{ .keys = .{ .up = true } }, buildSlider);
    try std.testing.expectEqual(@as(f32, 1), test_volume);
    try std.testing.expectEqual(@as(usize, 0), u.frameEvents().len);
    try runFrame(&u, .{ .keys = .{ .home = true } }, buildSlider);
    try std.testing.expectEqual(@as(f32, 0), test_volume);
}

test "slider: a click sets the value, and a drag follows the pointer" {
    var u = testUi();
    defer u.deinit();
    test_volume = 0;
    try runFrame(&u, .{}, buildSlider);
    // The slider is 132 wide with 8 of padding: the track goes from x = 14
    // to x = 118 (the thumb is 12 wide).
    const track = u.sliderParts(u.indexOf(2).?).track;
    try std.testing.expectEqual(@as(f32, 14), track.x);
    try std.testing.expectEqual(@as(f32, 104), track.w);

    const y = u.bounds(2).?.y + 4;
    try runFrame(&u, .{ .pointer_x = 66, .pointer_y = y, .pointer_pressed = true, .pointer_down = true }, buildSlider);
    try std.testing.expectEqual(@as(?u32, 2), u.focused());
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), test_volume, 1e-5);

    // The pointer leaves the slider while the button is down: the drag goes on.
    try runFrame(&u, .{ .pointer_x = 97, .pointer_y = y + 200, .pointer_down = true }, buildSlider);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), test_volume, 1e-5);
    // After the release, a move does nothing.
    try runFrame(&u, .{ .pointer_x = 20, .pointer_y = y }, buildSlider);
    try runFrame(&u, .{ .pointer_x = 30, .pointer_y = y, .pointer_down = true }, buildSlider);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), test_volume, 1e-5);
}

test "slider: the semantic tree has its value, range and description" {
    var u = testUi();
    defer u.deinit();
    test_volume = 0.3;
    try runFrame(&u, .{}, buildSlider);
    const n = u.semanticTree().find(2).?;
    try std.testing.expectEqual(Role.slider, n.role);
    try std.testing.expectEqualStrings("Volume", n.name);
    try std.testing.expectEqualStrings("0.3", n.value);
    try std.testing.expectEqualStrings("Sound level", n.description);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), n.range.?.value, 1e-6);
    try std.testing.expectEqual(@as(f32, 1), n.range.?.max);
}

fn testPercent(value: f32, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d:.0}%", .{value * 100}) catch "";
}

fn buildPercentSlider(u: *Ui) anyerror!void {
    try u.beginColumn(1, .{});
    try u.addSlider(2, "Volume", &test_volume, .{ .min = 0, .max = 1, .step = 0.1, .format = testPercent }, .{});
    u.endContainer();
}

test "slider: the format text has the value after the key press (REQ-A11Y-009)" {
    var u = testUi();
    defer u.deinit();
    test_volume = 0.5;
    u.setFocus(2);
    try runFrame(&u, .{ .keys = .{ .right = true } }, buildPercentSlider);
    try std.testing.expectEqualStrings("60%", u.semanticTree().find(2).?.value);
}

test "TextValue: caret, selection, insert and delete" {
    var storage: [16]u8 = undefined;
    var v: TextValue = .{ .buffer = &storage };
    try std.testing.expect(v.append("h\u{e9}llo"));
    try std.testing.expectEqual(@as(usize, 6), v.caretPos());

    // The caret moves by code points, not bytes.
    v.setCaret(0, false);
    v.moveRight(false);
    v.moveRight(false);
    try std.testing.expectEqual(@as(usize, 3), v.caretPos());
    try std.testing.expect(v.insert("X"));
    try std.testing.expectEqualStrings("h\u{e9}Xllo", v.slice());

    // Shift+Left twice selects "\u{e9}X". Typing replaces the selection.
    v.moveLeft(true);
    v.moveLeft(true);
    try std.testing.expectEqualStrings("\u{e9}X", v.selectedText());
    try std.testing.expect(v.insert("e"));
    try std.testing.expectEqualStrings("hello", v.slice());
    try std.testing.expectEqual(@as(usize, 2), v.caretPos());

    try std.testing.expect(v.deleteForward());
    try std.testing.expect(v.deleteBackward());
    try std.testing.expectEqualStrings("hlo", v.slice());
    try std.testing.expectEqual(@as(usize, 1), v.caretPos());

    // A selection collapses to its end with Right.
    v.selectAll();
    try std.testing.expectEqualStrings("hlo", v.selectedText());
    v.moveRight(false);
    try std.testing.expect(!v.hasSelection());
    try std.testing.expectEqual(@as(usize, 3), v.caretPos());

    // An offset inside a code point goes back to its start.
    try std.testing.expect(v.insert("\u{e9}"));
    v.setCaret(4, false);
    try std.testing.expectEqual(@as(usize, 3), v.caretPos());

    v.clear();
    try std.testing.expectEqual(@as(usize, 0), v.caretPos());
    try std.testing.expect(!v.hasSelection());
}

var test_field: TextValue = undefined;

fn buildFields(u: *Ui) anyerror!void {
    try u.beginColumn(1, .{});
    try u.addTextField(2, "First", &test_field, .{});
    try u.addTextField(3, "Second", &test_second, .{});
    u.endContainer();
}

var test_second: TextValue = undefined;

test "text field: the keys move the caret and the clipboard copies and pastes" {
    var u = testUi();
    defer u.deinit();
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    test_field = .{ .buffer = &a };
    test_second = .{ .buffer = &b };
    _ = test_field.append("hello world");

    u.setFocus(2);
    try runFrame(&u, .{ .keys = .{ .home = true } }, buildFields);
    try runFrame(&u, .{ .keys = .{ .end = true }, .shift = true }, buildFields);
    try std.testing.expectEqualStrings("hello world", test_field.selectedText());
    try runFrame(&u, .{ .keys = .{ .home = true } }, buildFields);
    for (0..5) |_| try runFrame(&u, .{ .keys = .{ .right = true }, .shift = true }, buildFields);
    try runFrame(&u, .{ .keys = .{ .cut = true } }, buildFields);
    try std.testing.expectEqualStrings(" world", test_field.slice());
    try std.testing.expectEqual(EventKind.changed, u.frameEvents()[0].kind);

    // Paste into the other field: the clipboard is in the Ui.
    try runFrame(&u, tab_key, buildFields);
    try std.testing.expectEqual(@as(?u32, 3), u.focused());
    try runFrame(&u, .{ .keys = .{ .paste = true } }, buildFields);
    try std.testing.expectEqualStrings("hello", test_second.slice());
    try runFrame(&u, .{ .keys = .{ .select_all = true, .copy = true } }, buildFields);
    try runFrame(&u, .{ .keys = .{ .left = true } }, buildFields);
    try runFrame(&u, .{ .keys = .{ .delete = true } }, buildFields);
    try std.testing.expectEqualStrings("ello", test_second.slice());
}

const TestClipboard = struct {
    text: []const u8 = "",
    written: [16]u8 = undefined,
    written_len: usize = 0,

    fn write(context: ?*anyopaque, text: []const u8) void {
        const self: *TestClipboard = @ptrCast(@alignCast(context.?));
        @memcpy(self.written[0..text.len], text);
        self.written_len = text.len;
    }

    fn read(context: ?*anyopaque) []const u8 {
        const self: *TestClipboard = @ptrCast(@alignCast(context.?));
        return self.text;
    }
};

test "text field: a platform clipboard takes the place of the clipboard in the Ui" {
    var u = testUi();
    defer u.deinit();
    var clip: TestClipboard = .{ .text = "pasted\nsecond line" };
    u.clipboard = .{ .context = &clip, .writeFn = TestClipboard.write, .readFn = TestClipboard.read };
    var a: [8]u8 = undefined;
    var b: [8]u8 = undefined;
    test_field = .{ .buffer = &a };
    test_second = .{ .buffer = &b };
    _ = test_field.append("ab");

    u.setFocus(2);
    try runFrame(&u, .{ .keys = .{ .select_all = true, .copy = true } }, buildFields);
    try std.testing.expectEqualStrings("ab", clip.written[0..clip.written_len]);
    // Paste takes the first line, cut to the room in the field.
    try runFrame(&u, .{ .keys = .{ .paste = true } }, buildFields);
    try std.testing.expectEqualStrings("pasted", test_field.slice());
    try runFrame(&u, .{ .keys = .{ .paste = true } }, buildFields);
    try std.testing.expectEqualStrings("pastedpa", test_field.slice());
}

const FakeContext = struct {
    text: [32]u8 = undefined,
    len: usize = 0,
    paste_as_text: bool = true,

    pub fn setPasteAsText(self: *FakeContext, on: bool) void {
        self.paste_as_text = on;
    }
    pub fn setClipboardText(self: *FakeContext, text: []const u8) void {
        @memcpy(self.text[0..text.len], text);
        self.len = text.len;
    }
    pub fn clipboardText(self: *FakeContext) []const u8 {
        return self.text[0..self.len];
    }
};

test "text field: Clipboard.platform uses the clipboard of the context" {
    var u = testUi();
    defer u.deinit();
    var fake: FakeContext = .{};
    u.clipboard = Clipboard.platform(&fake);
    try std.testing.expect(!fake.paste_as_text);
    var a: [16]u8 = undefined;
    var b: [16]u8 = undefined;
    test_field = .{ .buffer = &a };
    test_second = .{ .buffer = &b };
    _ = test_field.append("copy me");

    u.setFocus(2);
    try runFrame(&u, .{ .keys = .{ .select_all = true, .copy = true } }, buildFields);
    try std.testing.expectEqualStrings("copy me", fake.clipboardText());
    // Text from another program arrives in the platform clipboard.
    fake.setClipboardText("other");
    try runFrame(&u, tab_key, buildFields);
    try runFrame(&u, .{ .keys = .{ .paste = true } }, buildFields);
    try std.testing.expectEqualStrings("other", test_second.slice());
}

test "text field: a click puts the caret, and a drag selects" {
    var u = testUi();
    defer u.deinit();
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    test_field = .{ .buffer = &a };
    test_second = .{ .buffer = &b };
    _ = test_field.append("abcdef");
    try runFrame(&u, .{}, buildFields);

    // The text starts at x = 8 (the padding). Each byte is 8 wide.
    const y = u.bounds(2).?.y + 8;
    try runFrame(&u, .{ .pointer_x = 8 + 2 * 8 + 1, .pointer_y = y, .pointer_pressed = true, .pointer_down = true }, buildFields);
    try std.testing.expectEqual(@as(?u32, 2), u.focused());
    try std.testing.expectEqual(@as(usize, 2), test_field.caretPos());
    try runFrame(&u, .{ .pointer_x = 8 + 5 * 8 - 2, .pointer_y = y, .pointer_down = true }, buildFields);
    try std.testing.expectEqualStrings("cde", test_field.selectedText());
}

test "text field: a long text scrolls to keep the caret in view" {
    var u = testUi();
    defer u.deinit();
    var a: [64]u8 = undefined;
    var b: [8]u8 = undefined;
    test_field = .{ .buffer = &a };
    test_second = .{ .buffer = &b };
    u.setFocus(2);
    // 40 bytes are 320 pixels. The field is 240 wide, 224 inside.
    try runFrame(&u, .{ .text = "0123456789012345678901234567890123456789" }, buildFields);
    try std.testing.expectEqual(@as(f32, 320 - 222), u.scrollOf(2));
    try runFrame(&u, .{ .keys = .{ .home = true } }, buildFields);
    try std.testing.expectEqual(@as(f32, 0), u.scrollOf(2));
}

fn buildScroll(u: *Ui) anyerror!void {
    try u.beginColumn(1, .{});
    try u.addButton(2, "Top", .{});
    // 10 items of 32 pixels in a list 100 high: 320 of content.
    try u.beginScrollList(3, "Levels", .{ .w = .{ .fixed = 200 }, .h = .{ .fixed = 100 } });
    for (0..10) |i| try u.addListItem(10 + @as(u32, @intCast(i)), "Item", .{ .w = .fill });
    u.endContainer();
    u.endContainer();
}

test "scroll list: the wheel scrolls it, in its limits" {
    var u = testUi();
    defer u.deinit();
    try runFrame(&u, .{}, buildScroll);
    const list = u.bounds(3).?;
    const over: Input = .{ .pointer_x = list.x + 10, .pointer_y = list.y + 10, .wheel_y = -1 };
    try runFrame(&u, over, buildScroll);
    try std.testing.expectEqual(@as(f32, 40), u.scrollOf(3));
    // The items moved up in the same frame.
    try std.testing.expectEqual(list.y - 40, u.bounds(10).?.y);
    for (0..10) |_| try runFrame(&u, over, buildScroll);
    try std.testing.expectEqual(@as(f32, 220), u.scrollOf(3));
    var up = over;
    up.wheel_y = 20;
    try runFrame(&u, up, buildScroll);
    try std.testing.expectEqual(@as(f32, 0), u.scrollOf(3));
    // The wheel outside the list does nothing.
    try runFrame(&u, .{ .pointer_x = 390, .pointer_y = 290, .wheel_y = -1 }, buildScroll);
    try std.testing.expectEqual(@as(f32, 0), u.scrollOf(3));
}

test "scroll list: the focus scrolls into view, and a hidden item takes no click" {
    var u = testUi();
    defer u.deinit();
    u.setFocus(10);
    try runFrame(&u, .{}, buildScroll);
    // Item 13 is at 96..128 in the content, below the 100 of view.
    const hidden = u.bounds(13).?;
    try runFrame(&u, .{ .pointer_x = hidden.x + 4, .pointer_y = hidden.y + 4, .pointer_pressed = true }, buildScroll);
    try std.testing.expectEqual(@as(usize, 0), u.frameEvents().len);

    for (0..3) |_| try runFrame(&u, .{ .keys = .{ .down = true } }, buildScroll);
    try std.testing.expectEqual(@as(?u32, 13), u.focused());
    try std.testing.expectEqual(@as(f32, 28), u.scrollOf(3));
    const list = u.bounds(3).?;
    const item = u.bounds(13).?;
    try std.testing.expectEqual(list.y + list.h, item.y + item.h);

    try runFrame(&u, .{ .keys = .{ .home = true } }, buildScroll);
    try std.testing.expectEqual(@as(?u32, 10), u.focused());
    try std.testing.expectEqual(@as(f32, 0), u.scrollOf(3));
    try runFrame(&u, .{ .keys = .{ .end = true } }, buildScroll);
    try std.testing.expectEqual(@as(?u32, 19), u.focused());
    try std.testing.expectEqual(@as(f32, 220), u.scrollOf(3));

    // The scroll list is a list in the semantic tree, with all its items.
    const n = u.semanticTree().find(3).?;
    try std.testing.expectEqual(Role.list, n.role);
    try std.testing.expectEqual(@as(usize, 10), n.children.len);
}

test "scroll list: a drag of the scroll bar scrolls it" {
    var u = testUi();
    defer u.deinit();
    try runFrame(&u, .{}, buildScroll);
    const bar = u.scrollBar(u.indexOf(3).?).?;
    // The thumb is 100 * 100 / 320 = 31.25 high, so it moves 68.75.
    try std.testing.expectApproxEqAbs(@as(f32, 31.25), bar.thumb.h, 1e-3);
    const x = bar.thumb.x + 2;
    try runFrame(&u, .{ .pointer_x = x, .pointer_y = bar.thumb.y + 1, .pointer_pressed = true, .pointer_down = true }, buildScroll);
    try std.testing.expectEqual(@as(f32, 0), u.scrollOf(3));
    try runFrame(&u, .{ .pointer_x = x, .pointer_y = bar.thumb.y + 1 + 68.75 / 2.0, .pointer_down = true }, buildScroll);
    try std.testing.expectApproxEqAbs(@as(f32, 110), u.scrollOf(3), 1e-3);
    // The click on the bar did not focus or activate an item.
    try std.testing.expectEqual(@as(?u32, null), u.focused());
}

fn buildTips(u: *Ui) anyerror!void {
    try u.beginColumn(1, .{ .gap = 4 });
    try u.addButton(2, "Save", .{ .tooltip = "Save the game" });
    try u.addButton(3, "Quit", .{});
    u.endContainer();
}

test "tooltip: it shows after the delay, on hover or on focus" {
    var u = Ui.init(std.testing.allocator, .{ .measureFn = fakeMeasure }, .{ .tooltip_delay = 2 });
    defer u.deinit();
    try runFrame(&u, .{ .pointer_x = 390, .pointer_y = 290 }, buildTips);
    const save = u.bounds(2).?;
    const hover: Input = .{ .pointer_x = save.x + 2, .pointer_y = save.y + 2 };
    try runFrame(&u, hover, buildTips);
    try runFrame(&u, hover, buildTips);
    try std.testing.expect(u.tooltip() == null);
    try runFrame(&u, hover, buildTips);
    const tip = u.tooltip().?;
    try std.testing.expectEqualStrings("Save the game", tip.text);
    try std.testing.expectEqual(@as(u32, 2), tip.target);
    // Below the button.
    try std.testing.expect(tip.rect.y >= save.y + save.h);

    // The tooltip is the last child of the root in the semantic tree, and
    // the button has the text as its description.
    const tree = u.semanticTree();
    const node = tree.find(tooltip_id).?;
    try std.testing.expectEqual(Role.tooltip, node.role);
    try std.testing.expectEqualStrings("Save the game", node.name);
    const root = tree.nodes[0];
    try std.testing.expectEqual(tooltip_id, tree.nodes[root.children[root.children.len - 1]].id);
    try std.testing.expectEqualStrings("Save the game", tree.find(2).?.description);

    // A click hides it until the pointer goes to another node.
    var click = hover;
    click.pointer_pressed = true;
    try runFrame(&u, click, buildTips);
    for (0..4) |_| try runFrame(&u, hover, buildTips);
    try std.testing.expect(u.tooltip() == null);
    try std.testing.expect(u.semanticTree().find(tooltip_id) == null);

    // Keyboard focus shows it too, with the pointer away.
    try runFrame(&u, .{ .pointer_x = 390, .pointer_y = 290 }, buildTips);
    try runFrame(&u, .{ .pointer_x = 390, .pointer_y = 290, .keys = .{ .tab = true } }, buildTips);
    try std.testing.expectEqual(@as(?u32, 3), u.focused());
    try runFrame(&u, .{ .pointer_x = 390, .pointer_y = 290, .keys = .{ .tab = true } }, buildTips);
    try std.testing.expectEqual(@as(?u32, 2), u.focused());
    for (0..3) |_| try runFrame(&u, .{ .pointer_x = 390, .pointer_y = 290 }, buildTips);
    try std.testing.expectEqual(@as(u32, 2), u.tooltip().?.target);
}

test "errors: an app node cannot use the tooltip ID" {
    var u = testUi();
    defer u.deinit();
    try u.begin(.{}, 100, 100);
    try std.testing.expectError(error.InvalidId, u.addButton(tooltip_id, "a", .{}));
}

fn buildGrid(u: *Ui) anyerror!void {
    try u.beginColumn(1, .{ .arrows = true, .gap = 4 });
    try u.beginRow(2, .{ .gap = 4 });
    try u.addButton(10, "a", .{ .w = .{ .fixed = 30 } });
    try u.addButton(11, "b", .{ .w = .{ .fixed = 30 } });
    u.endContainer();
    try u.beginRow(3, .{ .gap = 4 });
    try u.addButton(12, "c", .{ .w = .{ .fixed = 30 } });
    try u.addButton(13, "d", .{ .w = .{ .fixed = 30 } });
    u.endContainer();
    u.endContainer();
}

test "arrows: the arrow keys move by position in a container with arrows" {
    var u = testUi();
    defer u.deinit();
    u.setFocus(10);
    try runFrame(&u, .{}, buildGrid);
    try runFrame(&u, .{ .keys = .{ .right = true } }, buildGrid);
    try std.testing.expectEqual(@as(?u32, 11), u.focused());
    try runFrame(&u, .{ .keys = .{ .down = true } }, buildGrid);
    try std.testing.expectEqual(@as(?u32, 13), u.focused());
    try runFrame(&u, .{ .keys = .{ .left = true } }, buildGrid);
    try std.testing.expectEqual(@as(?u32, 12), u.focused());
    // No node to the left: the focus stays.
    try runFrame(&u, .{ .keys = .{ .left = true } }, buildGrid);
    try std.testing.expectEqual(@as(?u32, 12), u.focused());
    try runFrame(&u, .{ .keys = .{ .up = true } }, buildGrid);
    try std.testing.expectEqual(@as(?u32, 10), u.focused());
}

fn buildOverlay(u: *Ui) anyerror!void {
    try u.beginColumn(1, .{ .padding = 10 });
    try u.addButton(2, "Under", .{});
    try u.beginScreen(3, "Over", .{ .w = .fill, .h = .fill });
    try u.addButton(4, "Top", .{});
    u.endContainer();
    try u.addButton(5, "After", .{});
    u.endContainer();
}

test "screen: it covers its parent and takes no room in it" {
    var u = testUi();
    defer u.deinit();
    try runFrame(&u, .{}, buildOverlay);
    // "After" is under "Under", as if the screen were not there.
    try std.testing.expectEqual(u.bounds(2).?.y + 32, u.bounds(5).?.y);
    const column = u.bounds(1).?;
    const screen = u.bounds(3).?;
    try std.testing.expectEqual(column.x + 10, screen.x);
    try std.testing.expectEqual(column.w - 20, screen.w);
    try std.testing.expectEqual(column.h - 20, screen.h);
    // The screen is the top screen even with a node after it in the tree.
    try runFrame(&u, tab_key, buildOverlay);
    try std.testing.expectEqual(@as(?u32, 4), u.focused());
}
