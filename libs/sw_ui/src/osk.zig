//! An on-screen keyboard, for touch screens and gamepads. It is a grid of
//! buttons in a container with `arrows`: the arrow keys (or a D-pad that the
//! app maps to them) move between the keys, Enter or Space (or a gamepad
//! button) presses a key, and a click or a tap presses a key too. `apply`
//! puts the text of the pressed keys into a `TextValue` at its caret.
//!
//! ```zig
//! try keyboard.build(&u, 500, .{});   // in the frame, IDs 500 to 500 + id_span - 1
//! try u.finish();
//! const r = keyboard.apply(&u, 500, &name_value);
//! if (r.done) ...
//! ```
//!
//! The keys are buttons, so the semantic tree has each key with its label.

const std = @import("std");
const ui = @import("ui.zig");

/// The rows of character keys. Each code point of a row is one key.
pub const Layout = struct {
    rows: []const []const u8,
    /// The same rows with Shift. A row has the same number of code points as
    /// the same row in `rows`.
    shifted: []const []const u8,
};

pub const letters: Layout = .{
    .rows = &.{ "1234567890", "qwertyuiop", "asdfghjkl-", "zxcvbnm,.?" },
    .shifted = &.{ "1234567890", "QWERTYUIOP", "ASDFGHJKL_", "ZXCVBNM;:!" },
};

pub const symbols: Layout = .{
    .rows = &.{ "!@#$%^&*()", "-_=+[]{};:", "'\"<>,./?\\|", "\u{e1}\u{e9}\u{ed}\u{f3}\u{fa}\u{f1}\u{e7}\u{fc}\u{df}\u{f8}" },
    .shifted = &.{ "!@#$%^&*()", "-_=+[]{};:", "'\"<>,./?\\|", "\u{c1}\u{c9}\u{cd}\u{d3}\u{da}\u{d1}\u{c7}\u{dc}\u{df}\u{d8}" },
};

/// The keyboard uses the IDs `base_id` to `base_id + id_span - 1`.
pub const id_span: u32 = 128;
/// The most rows of character keys, and the most keys in a row.
pub const max_rows = 6;
pub const max_columns = 16;

const Special = enum(u32) { shift, layer, space, backspace, done };
const special_base: u32 = 1 + max_rows * max_columns;

/// What `apply` did.
pub const Result = struct {
    /// The text of the value changed.
    changed: bool = false,
    /// The Done key was pressed.
    done: bool = false,
};

pub const Keyboard = struct {
    /// The next character key gives the shifted character.
    shift: bool = false,
    /// The symbols layout shows in place of the letters.
    symbols: bool = false,
    letters_layout: Layout = letters,
    symbols_layout: Layout = symbols,
    /// The width and height of a character key, in logical pixels.
    key_size: f32 = 40,
    gap: f32 = 4,

    fn layout(self: *const Keyboard) Layout {
        return if (self.symbols) self.symbols_layout else self.letters_layout;
    }

    fn rowsNow(self: *const Keyboard) []const []const u8 {
        const l = self.layout();
        return if (self.shift) l.shifted else l.rows;
    }

    /// The ID of the character key at `row` and `column`.
    pub fn keyId(base_id: u32, row: usize, column: usize) u32 {
        return base_id + 1 + @as(u32, @intCast(row * max_columns + column));
    }

    fn specialId(base_id: u32, key: Special) u32 {
        return base_id + special_base + @backingInt(key);
    }

    /// The ID of the Done key.
    pub fn doneId(base_id: u32) u32 {
        return specialId(base_id, .done);
    }

    /// Add the keyboard to the tree: a column with `arrows`, with ID
    /// `base_id`. `opts` are the options of the column.
    pub fn build(self: *const Keyboard, u: *ui.Ui, base_id: u32, opts: ui.Opts) ui.Error!void {
        var column = opts;
        column.arrows = true;
        if (column.label.len == 0) column.label = "On-screen keyboard";
        if (column.gap == 0) column.gap = self.gap;
        column.cross_align = .center;
        try u.beginColumn(base_id, column);

        const key: ui.Opts = .{ .w = .{ .fixed = self.key_size }, .h = .{ .fixed = self.key_size } };
        for (self.rowsNow(), 0..) |row, r| {
            if (r >= max_rows) break;
            try u.beginRow(base_id + special_base + 16 + @as(u32, @intCast(r)), .{ .gap = self.gap });
            var c: usize = 0;
            var it = std.unicode.Utf8View.initUnchecked(row).iterator();
            while (it.nextCodepointSlice()) |label| : (c += 1) {
                if (c >= max_columns) break;
                try u.addButton(keyId(base_id, r, c), label, key);
            }
            u.endContainer();
        }

        const wide: ui.Opts = .{ .h = .{ .fixed = self.key_size } };
        try u.beginRow(base_id + special_base + 16 + max_rows, .{ .gap = self.gap });
        try u.addButton(specialId(base_id, .shift), "Shift", .{ .h = wide.h, .selected = self.shift });
        try u.addButton(specialId(base_id, .layer), if (self.symbols) "Letters" else "Symbols", wide);
        try u.addButton(specialId(base_id, .space), "Space", .{ .w = .{ .fixed = self.key_size * 4 }, .h = wide.h });
        try u.addButton(specialId(base_id, .backspace), "Backspace", wide);
        try u.addButton(specialId(base_id, .done), "Done", wide);
        u.endContainer();

        u.endContainer();
    }

    /// The label of the character key with this ID, or null.
    fn keyText(self: *const Keyboard, base_id: u32, id: u32) ?[]const u8 {
        if (id <= base_id or id >= base_id + special_base) return null;
        const k = id - base_id - 1;
        const rows = self.rowsNow();
        const r = k / max_columns;
        if (r >= rows.len) return null;
        var c: usize = k % max_columns;
        var it = std.unicode.Utf8View.initUnchecked(rows[r]).iterator();
        while (it.nextCodepointSlice()) |label| {
            if (c == 0) return label;
            c -= 1;
        }
        return null;
    }

    /// Apply the key presses of the last `finish` to `value`.
    pub fn apply(self: *Keyboard, u: *const ui.Ui, base_id: u32, value: *ui.TextValue) Result {
        var result: Result = .{};
        for (u.frameEvents()) |e| {
            if (e.kind != .activate or e.id < base_id or e.id >= base_id + id_span) continue;
            if (self.keyText(base_id, e.id)) |text| {
                if (value.insert(text)) result.changed = true;
                self.shift = false;
                continue;
            }
            const special = e.id -% (base_id + special_base);
            if (special > @backingInt(Special.done)) continue;
            switch (@as(Special, @fromBackingInt(@intCast(special)))) {
                .shift => self.shift = !self.shift,
                .layer => {
                    self.symbols = !self.symbols;
                    self.shift = false;
                },
                .space => {
                    if (value.insert(" ")) result.changed = true;
                },
                .backspace => {
                    if (value.deleteBackward()) result.changed = true;
                },
                .done => result.done = true,
            }
        }
        return result;
    }
};

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;

fn fakeMeasure(context: ?*const anyopaque, s: []const u8, size: f32) ui.Size {
    _ = context;
    _ = size;
    return .{ .w = @floatFromInt(s.len * 8), .h = 16 };
}

const base: u32 = 1000;

fn frame(u: *ui.Ui, k: *const Keyboard, value: *ui.TextValue, input: ui.Input) !void {
    try u.begin(input, 800, 600);
    try u.addTextField(1, "Name", value, .{});
    try k.build(u, base, .{});
    try u.finish();
}

test "osk: the arrow keys move between keys and Enter types" {
    var u = ui.Ui.init(testing.allocator, .{ .measureFn = fakeMeasure }, .{});
    defer u.deinit();
    var storage: [16]u8 = undefined;
    var value: ui.TextValue = .{ .buffer = &storage };
    var k: Keyboard = .{};

    // "q" is the first key of the second row.
    u.setFocus(Keyboard.keyId(base, 1, 0));
    try frame(&u, &k, &value, .{});
    try frame(&u, &k, &value, .{ .keys = .{ .right = true } });
    try testing.expectEqual(@as(?u32, Keyboard.keyId(base, 1, 1)), u.focused());
    try frame(&u, &k, &value, .{ .keys = .{ .enter = true } });
    try testing.expect(k.apply(&u, base, &value).changed);
    try testing.expectEqualStrings("w", value.slice());

    // Down goes to the key under "w": "s".
    try frame(&u, &k, &value, .{ .keys = .{ .down = true } });
    try testing.expectEqual(@as(?u32, Keyboard.keyId(base, 2, 1)), u.focused());
    try frame(&u, &k, &value, .{ .keys = .{ .up = true } });
    try frame(&u, &k, &value, .{ .keys = .{ .up = true } });
    try testing.expectEqual(@as(?u32, Keyboard.keyId(base, 0, 1)), u.focused());
}

test "osk: Shift, a click, Space, Backspace and Done" {
    var u = ui.Ui.init(testing.allocator, .{ .measureFn = fakeMeasure }, .{});
    defer u.deinit();
    var storage: [16]u8 = undefined;
    var value: ui.TextValue = .{ .buffer = &storage };
    var k: Keyboard = .{};
    try frame(&u, &k, &value, .{});

    const click = struct {
        fn at(ui_: *ui.Ui, id: u32) ui.Input {
            const r = ui_.bounds(id).?;
            return .{ .pointer_x = r.x + r.w / 2, .pointer_y = r.y + r.h / 2, .pointer_pressed = true };
        }
    }.at;

    try frame(&u, &k, &value, click(&u, Keyboard.specialId(base, .shift)));
    _ = k.apply(&u, base, &value);
    try testing.expect(k.shift);
    // The shifted row shows, and the key gives a capital. Shift then lets go.
    try frame(&u, &k, &value, .{});
    try frame(&u, &k, &value, click(&u, Keyboard.keyId(base, 1, 0)));
    _ = k.apply(&u, base, &value);
    try testing.expectEqualStrings("Q", value.slice());
    try testing.expect(!k.shift);

    try frame(&u, &k, &value, click(&u, Keyboard.specialId(base, .space)));
    _ = k.apply(&u, base, &value);
    try frame(&u, &k, &value, click(&u, Keyboard.specialId(base, .layer)));
    _ = k.apply(&u, base, &value);
    try testing.expect(k.symbols);
    try frame(&u, &k, &value, .{});
    try frame(&u, &k, &value, click(&u, Keyboard.keyId(base, 3, 0)));
    _ = k.apply(&u, base, &value);
    try testing.expectEqualStrings("Q \u{e1}", value.slice());

    try frame(&u, &k, &value, click(&u, Keyboard.specialId(base, .backspace)));
    try testing.expect(k.apply(&u, base, &value).changed);
    try testing.expectEqualStrings("Q ", value.slice());

    try frame(&u, &k, &value, click(&u, Keyboard.doneId(base)));
    const r = k.apply(&u, base, &value);
    try testing.expect(r.done and !r.changed);
}

test "osk: the keyboard is one tab stop, and its keys are buttons" {
    var u = ui.Ui.init(testing.allocator, .{ .measureFn = fakeMeasure }, .{});
    defer u.deinit();
    var storage: [16]u8 = undefined;
    var value: ui.TextValue = .{ .buffer = &storage };
    const k: Keyboard = .{};
    const tab: ui.Input = .{ .keys = .{ .tab = true } };

    try frame(&u, &k, &value, tab);
    try testing.expectEqual(@as(?u32, 1), u.focused());
    try frame(&u, &k, &value, tab);
    try testing.expectEqual(@as(?u32, Keyboard.keyId(base, 0, 0)), u.focused());
    try frame(&u, &k, &value, .{ .keys = .{ .right = true } });
    try frame(&u, &k, &value, tab);
    try testing.expectEqual(@as(?u32, 1), u.focused());
    // Shift+Tab comes back to the key that had focus.
    try frame(&u, &k, &value, .{ .keys = .{ .tab = true }, .shift = true });
    try testing.expectEqual(@as(?u32, Keyboard.keyId(base, 0, 1)), u.focused());

    const tree = u.semanticTree();
    const group = tree.find(base).?;
    try testing.expectEqual(ui.Role.group, group.role);
    try testing.expectEqualStrings("On-screen keyboard", group.name);
    try testing.expectEqualStrings("q", tree.find(Keyboard.keyId(base, 1, 0)).?.name);
    try testing.expectEqual(ui.Role.button, tree.find(Keyboard.doneId(base)).?.role);
}
