//! A stack of screens, for menus that open other menus: a main menu, then
//! its settings, then a page of the settings. The app keeps its own screen
//! type (often an enum) and builds the top screen with `Ui.beginScreen`.
//!
//! The stack remembers the focus of each screen. `push` keeps the focus of
//! the screen under the new one and moves the focus to the first tab stop of
//! the new screen. `pop` gives the old focus back. Escape (a `cancel` event)
//! or a Back button calls `pop`.
//!
//! ```zig
//! var screens: sw_ui.ScreenStack(Screen, 8) = .{};
//! try screens.push(&u, .settings);
//! // Each frame: build the screens in the stack with `beginScreen`.
//! // On a cancel event: _ = screens.pop(&u);
//! ```

const std = @import("std");
const ui = @import("ui.zig");

pub fn ScreenStack(comptime Screen: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        pub const Entry = struct {
            screen: Screen,
            /// The focus of the screen under this one when this one opened.
            return_focus: ?u32,
        };

        entries: [capacity]Entry = undefined,
        len: usize = 0,

        /// Open `screen` on top. The focus moves to its first tab stop in the
        /// next `finish`.
        pub fn push(self: *Self, u: *ui.Ui, screen: Screen) error{StackFull}!void {
            if (self.len >= capacity) return error.StackFull;
            self.entries[self.len] = .{ .screen = screen, .return_focus = u.focused() };
            self.len += 1;
            u.focusFirst();
        }

        /// Close the top screen and give the focus back to the node that had
        /// it before the screen opened. Null if the stack is empty.
        pub fn pop(self: *Self, u: *ui.Ui) ?Screen {
            if (self.len == 0) return null;
            self.len -= 1;
            const e = self.entries[self.len];
            if (e.return_focus) |id| u.setFocus(id) else u.clearFocus();
            return e.screen;
        }

        /// The top screen, or null.
        pub fn top(self: *const Self) ?Screen {
            return if (self.len == 0) null else self.entries[self.len - 1].screen;
        }

        /// The screens, from the bottom to the top.
        pub fn items(self: *const Self) []const Entry {
            return self.entries[0..self.len];
        }

        /// Pop the top screen if the last `finish` sent a `cancel` event
        /// (Escape). True when a screen closed.
        pub fn handleCancel(self: *Self, u: *ui.Ui) bool {
            if (self.len == 0) return false;
            for (u.frameEvents()) |e| {
                if (e.kind == .cancel) return self.pop(u) != null;
            }
            return false;
        }
    };
}

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;

fn fakeMeasure(context: ?*const anyopaque, s: []const u8, size: f32) ui.Size {
    _ = context;
    _ = size;
    return .{ .w = @floatFromInt(s.len * 8), .h = 16 };
}

const TestScreen = enum { options, sound };

/// The base menu, then each screen of the stack over it. The buttons of a
/// screen are at its bottom, so they are not over the base menu.
fn frame(u: *ui.Ui, stack: anytype, input: ui.Input) !void {
    try u.begin(input, 400, 300);
    try u.beginColumn(1, .{});
    try u.addButton(10, "Play", .{});
    try u.addButton(11, "Options", .{});
    u.endContainer();
    for (stack.items()) |e| switch (e.screen) {
        .options => {
            try u.beginScreen(20, "Options", .{ .w = .fill, .h = .fill, .main_align = .end });
            try u.addButton(21, "Sound", .{});
            try u.addButton(22, "Back", .{});
            u.endContainer();
        },
        .sound => {
            try u.beginScreen(30, "Sound", .{ .w = .fill, .h = .fill, .main_align = .end });
            try u.addButton(31, "Back", .{});
            u.endContainer();
        },
    };
    try u.finish();
}

test "screen stack: push moves the focus in, pop gives it back" {
    var u = ui.Ui.init(testing.allocator, .{ .measureFn = fakeMeasure }, .{});
    defer u.deinit();
    var stack: ScreenStack(TestScreen, 4) = .{};

    u.setFocus(11);
    try frame(&u, &stack, .{});
    try testing.expectEqual(@as(?u32, 11), u.focused());

    try stack.push(&u, .options);
    try frame(&u, &stack, .{});
    try testing.expectEqual(@as(?u32, 21), u.focused());
    try testing.expectEqual(@as(?TestScreen, .options), stack.top());

    try stack.push(&u, .sound);
    try frame(&u, &stack, .{});
    try testing.expectEqual(@as(?u32, 31), u.focused());

    // Escape closes the top screen, and the focus goes back to "Sound".
    try frame(&u, &stack, .{ .keys = .{ .escape = true } });
    try testing.expect(stack.handleCancel(&u));
    try frame(&u, &stack, .{});
    try testing.expectEqual(@as(?u32, 21), u.focused());

    try testing.expectEqual(@as(?TestScreen, .options), stack.pop(&u));
    try frame(&u, &stack, .{});
    try testing.expectEqual(@as(?u32, 11), u.focused());
    try testing.expectEqual(@as(?TestScreen, null), stack.pop(&u));
}

test "screen stack: only the top screen takes input and is in the semantic tree" {
    var u = ui.Ui.init(testing.allocator, .{ .measureFn = fakeMeasure }, .{});
    defer u.deinit();
    var stack: ScreenStack(TestScreen, 4) = .{};
    try stack.push(&u, .options);
    try stack.push(&u, .sound);
    try frame(&u, &stack, .{});

    // Tab stays in the top screen.
    try frame(&u, &stack, .{ .keys = .{ .tab = true } });
    try testing.expectEqual(@as(?u32, 31), u.focused());

    // A click on a button under the top screen does nothing.
    const play = u.bounds(10).?;
    try frame(&u, &stack, .{ .pointer_x = play.x + 1, .pointer_y = play.y + 1, .pointer_pressed = true });
    try testing.expectEqual(@as(usize, 0), u.frameEvents().len);
    try testing.expectEqual(@as(?u32, 31), u.focused());

    // setFocus on a node under the top screen does nothing.
    u.setFocus(21);
    try frame(&u, &stack, .{});
    try testing.expectEqual(@as(?u32, 31), u.focused());

    const tree = u.semanticTree();
    try testing.expect(tree.find(10) == null);
    try testing.expect(tree.find(20) == null);
    const top = tree.find(30).?;
    try testing.expectEqual(ui.Role.dialog, top.role);
    try testing.expectEqualStrings("Sound", top.name);
    try testing.expectEqual(@as(usize, 1), top.children.len);
    try testing.expectEqual(@as(u32, 31), tree.nodes[top.children[0]].id);
    // The root holds the screen directly.
    try testing.expectEqual(@as(usize, 1), tree.nodes[0].children.len);
    try testing.expectEqual(@as(u32, 30), tree.nodes[tree.nodes[0].children[0]].id);
}

test "screen stack: a full stack gives an error" {
    var u = ui.Ui.init(testing.allocator, .{ .measureFn = fakeMeasure }, .{});
    defer u.deinit();
    var stack: ScreenStack(TestScreen, 1) = .{};
    try stack.push(&u, .options);
    try testing.expectError(error.StackFull, stack.push(&u, .sound));
}
