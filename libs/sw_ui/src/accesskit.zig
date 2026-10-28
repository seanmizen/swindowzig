//! The native screen-reader backend: it sends the sw_ui semantic tree to
//! AccessKit (accesskit-c), and AccessKit gives it to the platform
//! accessibility API: UI Automation on Windows, NSAccessibility on macOS,
//! AT-SPI on Linux (REQ-A11Y-007).
//!
//! The backend is optional. `zig build -Daccesskit=true` turns it on and links
//! `libaccesskit` from `~/.local/lib` (`docs/accesskit.md`). With the option
//! off (the default), `enabled` is false, each function here does nothing,
//! and no C symbol is referenced. The web build uses `web_mirror.zig`.
//!
//! Use:
//!
//! ```zig
//! var ak: sw_ui.accesskit.Adapter = .{};   // keep it at a fixed address
//! ak.start(alloc, sw_ui.accesskit.windowState(ctx.nativeWindow()), "Title");
//! // each frame, after u.finish():
//! ak.syncWindow(sw_ui.accesskit.windowState(ctx.nativeWindow()));
//! try ak.publish(u.semanticTree(), win.dpi_scale);
//! while (ak.takeAction()) |req| { ... }    // focus and click requests
//! ak.stop();
//! ```
//!
//! Each `publish` sends only the nodes that changed and the focus
//! (`accesskit_map.diff`). AccessKit then tells the screen reader about a
//! focus change, and speaks a live region whose text changed (REQ-A11Y-008).
//!
//! Threads. AccessKit can call the activation handler and the action handler
//! on its own thread (the AT-SPI thread on Linux). The handlers read the
//! current snapshot and write the action queue under `lock`. The main thread
//! never calls AccessKit while it holds `lock`, so the two locks cannot
//! deadlock.

const std = @import("std");
const builtin = @import("builtin");
const options = @import("sw_ui_options");
const map = @import("accesskit_map.zig");
const semantic = @import("semantic.zig");

/// True when the build links accesskit-c and this backend sends the tree.
pub const enabled = options.accesskit and !builtin.cpu.arch.isWasm();

/// The native window that the adapter attaches to.
pub const WindowHandle = union(enum) {
    /// Linux and the BSDs: the AT-SPI adapter needs no window handle.
    none,
    /// macOS: the `NSWindow *` of the window.
    cocoa_window: *anyopaque,
    /// Windows: the `HWND` of the window.
    win32_hwnd: *anyopaque,
};

/// The state of the window that AccessKit needs.
pub const WindowState = struct {
    handle: WindowHandle = .none,
    /// The window has the keyboard focus.
    focused: bool = false,
    /// Screen coordinates of the window with its frame (Linux only).
    outer: map.Bounds = .{},
    /// Screen coordinates of the client area (Linux only).
    inner: map.Bounds = .{},
};

/// Make a `WindowState` from a `sw_platform.NativeWindow`
/// (`ctx.nativeWindow()`). sw_ui does not import sw_platform, so this reads
/// the fields by name.
pub fn windowState(nw: anytype) WindowState {
    const handle: WindowHandle = switch (nw.kind) {
        .cocoa => if (nw.handle) |h| .{ .cocoa_window = h } else .none,
        .win32 => if (nw.handle) |h| .{ .win32_hwnd = h } else .none,
        else => .none,
    };
    const x: f64 = @floatFromInt(nw.x);
    const y: f64 = @floatFromInt(nw.y);
    const w: f64 = @floatFromInt(nw.w);
    const h: f64 = @floatFromInt(nw.h);
    return .{
        .handle = handle,
        .focused = nw.focused,
        .inner = .{ .x0 = x, .y0 = y, .x1 = x + w, .y1 = y + h },
        .outer = .{
            .x0 = x - @as(f64, @floatFromInt(nw.border_left)),
            .y0 = y - @as(f64, @floatFromInt(nw.border_top)),
            .x1 = x + w + @as(f64, @floatFromInt(nw.border_right)),
            .y1 = y + h + @as(f64, @floatFromInt(nw.border_bottom)),
        },
    };
}

/// A request from the screen reader. The app applies it to its `Ui`: focus
/// is `Ui.setFocus(target)`, click activates the node.
pub const ActionRequest = struct {
    kind: map.Action,
    target: u32,
};

const queue_len = 32;

const SpinLock = struct {
    held: std.atomic.Value(bool) = .init(false),

    fn lock(self: *SpinLock) void {
        while (self.held.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }

    fn unlock(self: *SpinLock) void {
        self.held.store(false, .release);
    }
};

pub const Adapter = struct {
    gpa: std.mem.Allocator = undefined,
    title: []const u8 = "",
    /// The platform adapter, or null before `start` and after `stop`.
    native: ?*anyopaque = null,
    /// The last tree that `publish` got. The activation handler reads it.
    current: ?map.Snapshot = null,
    /// The indices into `current.nodes` for the next tree update.
    pending: std.ArrayList(u32) = .empty,
    window: WindowState = .{},
    window_synced: bool = false,
    lock: SpinLock = .{},
    actions: [queue_len]ActionRequest = undefined,
    action_count: usize = 0,

    /// Attach AccessKit to the window. `self` must not move until `stop`:
    /// AccessKit keeps a pointer to it. A failure logs a warning, and the app
    /// continues with no screen-reader support.
    pub fn start(self: *Adapter, gpa: std.mem.Allocator, window: WindowState, title: []const u8) void {
        if (comptime !enabled) return;
        self.gpa = gpa;
        self.title = title;
        self.window = window;
        self.native = Platform.create(self, window);
        if (self.native == null) {
            std.log.warn("sw_ui: AccessKit did not start on this window", .{});
            return;
        }
        self.window_synced = false;
        self.syncWindow(window);
    }

    /// Detach AccessKit and free the memory.
    pub fn stop(self: *Adapter) void {
        if (comptime !enabled) return;
        if (self.native) |n| Platform.free(n);
        self.native = null;
        self.lock.lock();
        if (self.current) |*s| s.deinit();
        self.current = null;
        self.lock.unlock();
        self.pending.deinit(self.gpa);
        self.pending = .empty;
    }

    /// Tell AccessKit the focus state and the position of the window, when
    /// they changed.
    pub fn syncWindow(self: *Adapter, window: WindowState) void {
        if (comptime !enabled) return;
        const n = self.native orelse return;
        const first = !self.window_synced;
        if (first or window.focused != self.window.focused) Platform.setWindowFocus(n, window.focused);
        if (first or !std.meta.eql(window.outer, self.window.outer) or !std.meta.eql(window.inner, self.window.inner)) {
            Platform.setWindowBounds(n, window.outer, window.inner);
        }
        self.window = window;
        self.window_synced = true;
    }

    /// Send the changes of `tree` to AccessKit. `scale` is the DPI scale of
    /// the window (physical pixels for each logical pixel).
    pub fn publish(self: *Adapter, tree: semantic.SemanticTree, scale: f32) std.mem.Allocator.Error!void {
        if (comptime !enabled) return;
        const n = self.native orelse return;
        var next = try map.Snapshot.init(self.gpa, tree, .{ .title = self.title, .scale = scale });
        errdefer next.deinit();
        const prev: ?*const map.Snapshot = if (self.current) |*s| s else null;
        const d = try map.diff(self.gpa, prev, &next, &self.pending);
        if (d.isEmpty()) {
            next.deinit();
            return;
        }

        // Only this thread writes `current`, so the update factory below
        // reads it with no lock.
        self.lock.lock();
        var old = self.current;
        self.current = next;
        self.lock.unlock();
        if (old) |*s| s.deinit();

        Platform.update(n, self);
    }

    /// The next request from the screen reader, or null.
    pub fn takeAction(self: *Adapter) ?ActionRequest {
        if (comptime !enabled) return null;
        self.lock.lock();
        defer self.lock.unlock();
        if (self.action_count == 0) return null;
        const first = self.actions[0];
        std.mem.copyForwards(ActionRequest, self.actions[0 .. self.action_count - 1], self.actions[1..self.action_count]);
        self.action_count -= 1;
        return first;
    }

    // ---- AccessKit callbacks ------------------------------------------

    /// The activation handler: the full tree. AccessKit calls it when a
    /// screen reader first asks for the tree.
    fn activationHandler(userdata: ?*anyopaque) callconv(.c) ?*c.TreeUpdate {
        const self: *Adapter = @ptrCast(@alignCast(userdata.?));
        self.lock.lock();
        defer self.lock.unlock();
        if (self.current) |*s| return fullUpdate(s);
        // No tree yet: only the window.
        const root = c.accesskit_node_new(@backingInt(map.Role.window));
        const update = c.accesskit_tree_update_with_capacity_and_focus(1, 0);
        c.accesskit_tree_update_set_tree_info(update, treeInfo(0));
        c.accesskit_tree_update_push_node(update, 0, root);
        return update;
    }

    /// The update factory of `publish`: the changed nodes and the focus.
    fn updateFactory(userdata: ?*anyopaque) callconv(.c) ?*c.TreeUpdate {
        const self: *Adapter = @ptrCast(@alignCast(userdata.?));
        const s = &self.current.?;
        const update = c.accesskit_tree_update_with_capacity_and_focus(self.pending.items.len, s.focus);
        for (self.pending.items) |i| {
            const node = &s.nodes[i];
            c.accesskit_tree_update_push_node(update, node.id, toC(node));
        }
        return update;
    }

    fn actionHandler(request: *c.RawActionRequest, userdata: ?*anyopaque) callconv(.c) void {
        defer c.accesskit_action_request_free(request);
        const self: *Adapter = @ptrCast(@alignCast(userdata.?));
        const kind: map.Action = switch (request.action) {
            @backingInt(map.Action.click) => .click,
            @backingInt(map.Action.focus) => .focus,
            @backingInt(map.Action.decrement) => .decrement,
            @backingInt(map.Action.increment) => .increment,
            else => return,
        };
        if (request.target_node > std.math.maxInt(u32)) return;
        self.lock.lock();
        defer self.lock.unlock();
        if (self.action_count == queue_len) return;
        self.actions[self.action_count] = .{ .kind = kind, .target = @intCast(request.target_node) };
        self.action_count += 1;
    }

    fn deactivationHandler(_: ?*anyopaque) callconv(.c) void {}
};

fn treeInfo(root: u64) *c.TreeInfo {
    const info = c.accesskit_tree_info_new(root);
    c.accesskit_tree_info_set_toolkit_name(info, "swindowzig");
    return info;
}

fn fullUpdate(s: *const map.Snapshot) *c.TreeUpdate {
    const update = c.accesskit_tree_update_with_capacity_and_focus(s.nodes.len, s.focus);
    c.accesskit_tree_update_set_tree_info(update, treeInfo(s.root));
    for (s.nodes) |*node| c.accesskit_tree_update_push_node(update, node.id, toC(node));
    return update;
}

/// Build an accesskit-c node. The tree update takes ownership of it.
fn toC(n: *const map.Node) *c.Node {
    const node = c.accesskit_node_new(@backingInt(n.role));
    if (n.label.len > 0) c.accesskit_node_set_label(node, n.label.ptr);
    if (n.value.len > 0) c.accesskit_node_set_value(node, n.value.ptr);
    if (n.description.len > 0) c.accesskit_node_set_description(node, n.description.ptr);
    c.accesskit_node_set_bounds(node, .{ .x0 = n.bounds.x0, .y0 = n.bounds.y0, .x1 = n.bounds.x1, .y1 = n.bounds.y1 });
    if (n.children.len > 0) c.accesskit_node_set_children(node, n.children.len, n.children.ptr);
    var buf: [4]map.Action = undefined;
    for (n.actions.list(&buf)) |a| c.accesskit_node_add_action(node, @backingInt(a));
    if (n.live != .off) c.accesskit_node_set_live(node, @backingInt(n.live));
    if (n.disabled) c.accesskit_node_set_disabled(node);
    if (n.selected) |v| c.accesskit_node_set_selected(node, v);
    if (n.modal) c.accesskit_node_set_modal(node);
    if (n.range) |r| {
        c.accesskit_node_set_numeric_value(node, r.value);
        c.accesskit_node_set_min_numeric_value(node, r.min);
        c.accesskit_node_set_max_numeric_value(node, r.max);
    }
    return node;
}

/// The platform adapter: one implementation for each OS. Only the branch of
/// the target OS is compiled.
const Platform = switch (builtin.os.tag) {
    .macos => struct {
        fn create(a: *Adapter, w: WindowState) ?*anyopaque {
            const window = switch (w.handle) {
                .cocoa_window => |h| h,
                else => return null,
            };
            // SDL2 makes its windows from the NSWindow subclass SDLWindow.
            // The focus forwarder lets VoiceOver find the focused node.
            c.accesskit_macos_add_focus_forwarder_to_window_class("SDLWindow");
            return c.accesskit_macos_subclassing_adapter_for_window(window, Adapter.activationHandler, a, Adapter.actionHandler, a);
        }
        fn free(n: *anyopaque) void {
            c.accesskit_macos_subclassing_adapter_free(n);
        }
        fn update(n: *anyopaque, a: *Adapter) void {
            if (c.accesskit_macos_subclassing_adapter_update_if_active(n, Adapter.updateFactory, a)) |events| {
                c.accesskit_macos_queued_events_raise(events);
            }
        }
        fn setWindowFocus(n: *anyopaque, focused: bool) void {
            if (c.accesskit_macos_subclassing_adapter_update_view_focus_state(n, focused)) |events| {
                c.accesskit_macos_queued_events_raise(events);
            }
        }
        fn setWindowBounds(_: *anyopaque, _: map.Bounds, _: map.Bounds) void {}
    },
    .windows => struct {
        fn create(a: *Adapter, w: WindowState) ?*anyopaque {
            const hwnd = switch (w.handle) {
                .win32_hwnd => |h| h,
                else => return null,
            };
            return c.accesskit_windows_subclassing_adapter_new(hwnd, Adapter.activationHandler, a, Adapter.actionHandler, a);
        }
        fn free(n: *anyopaque) void {
            c.accesskit_windows_subclassing_adapter_free(n);
        }
        fn update(n: *anyopaque, a: *Adapter) void {
            if (c.accesskit_windows_subclassing_adapter_update_if_active(n, Adapter.updateFactory, a)) |events| {
                c.accesskit_windows_queued_events_raise(events);
            }
        }
        // The subclassing adapter reads the window focus itself.
        fn setWindowFocus(_: *anyopaque, _: bool) void {}
        fn setWindowBounds(_: *anyopaque, _: map.Bounds, _: map.Bounds) void {}
    },
    // Linux and the BSDs: AT-SPI over D-Bus.
    else => struct {
        fn create(a: *Adapter, _: WindowState) ?*anyopaque {
            return c.accesskit_unix_adapter_new(Adapter.activationHandler, a, Adapter.actionHandler, a, Adapter.deactivationHandler, a);
        }
        fn free(n: *anyopaque) void {
            c.accesskit_unix_adapter_free(n);
        }
        fn update(n: *anyopaque, a: *Adapter) void {
            c.accesskit_unix_adapter_update_if_active(n, Adapter.updateFactory, a);
        }
        fn setWindowFocus(n: *anyopaque, focused: bool) void {
            c.accesskit_unix_adapter_update_window_focus_state(n, focused);
        }
        fn setWindowBounds(n: *anyopaque, outer: map.Bounds, inner: map.Bounds) void {
            c.accesskit_unix_adapter_set_root_window_bounds(n, rect(outer), rect(inner));
        }
    },
};

fn rect(b: map.Bounds) c.Rect {
    return .{ .x0 = b.x0, .y0 = b.y0, .x1 = b.x1, .y1 = b.y1 };
}

/// The accesskit-c 0.23 functions that this file calls (`accesskit.h`). The
/// build has no `@cImport`. Zig emits a reference only for a function that
/// compiled code calls, so a build with `enabled` false links no symbol.
const c = struct {
    const Node = opaque {};
    const TreeUpdate = opaque {};
    const TreeInfo = opaque {};
    const QueuedEvents = opaque {};

    const Rect = extern struct { x0: f64, y0: f64, x1: f64, y1: f64 };

    /// The first fields of `accesskit_action_request`. This file only reads
    /// them through a pointer that AccessKit gives, so the rest (the action
    /// data) is not declared.
    const RawActionRequest = extern struct {
        action: u8,
        target_tree: [16]u8,
        target_node: u64,
    };

    const Factory = *const fn (?*anyopaque) callconv(.c) ?*TreeUpdate;
    const ActionHandler = *const fn (*RawActionRequest, ?*anyopaque) callconv(.c) void;
    const DeactivationHandler = *const fn (?*anyopaque) callconv(.c) void;

    extern fn accesskit_node_new(role: u8) *Node;
    extern fn accesskit_node_set_label(node: *Node, value: [*:0]const u8) void;
    extern fn accesskit_node_set_value(node: *Node, value: [*:0]const u8) void;
    extern fn accesskit_node_set_description(node: *Node, value: [*:0]const u8) void;
    extern fn accesskit_node_set_bounds(node: *Node, value: Rect) void;
    extern fn accesskit_node_set_children(node: *Node, length: usize, values: [*]const u64) void;
    extern fn accesskit_node_add_action(node: *Node, action: u8) void;
    extern fn accesskit_node_set_live(node: *Node, value: u8) void;
    extern fn accesskit_node_set_disabled(node: *Node) void;
    extern fn accesskit_node_set_selected(node: *Node, value: bool) void;
    extern fn accesskit_node_set_modal(node: *Node) void;
    extern fn accesskit_node_set_numeric_value(node: *Node, value: f64) void;
    extern fn accesskit_node_set_min_numeric_value(node: *Node, value: f64) void;
    extern fn accesskit_node_set_max_numeric_value(node: *Node, value: f64) void;

    extern fn accesskit_tree_info_new(root: u64) *TreeInfo;
    extern fn accesskit_tree_info_set_toolkit_name(tree: *TreeInfo, name: [*:0]const u8) void;
    extern fn accesskit_tree_update_with_capacity_and_focus(capacity: usize, focus: u64) *TreeUpdate;
    extern fn accesskit_tree_update_set_tree_info(update: *TreeUpdate, tree: *TreeInfo) void;
    extern fn accesskit_tree_update_push_node(update: *TreeUpdate, id: u64, node: *Node) void;
    extern fn accesskit_action_request_free(request: *RawActionRequest) void;

    // Linux and the BSDs.
    extern fn accesskit_unix_adapter_new(
        activation_handler: Factory,
        activation_userdata: ?*anyopaque,
        action_handler: ActionHandler,
        action_userdata: ?*anyopaque,
        deactivation_handler: DeactivationHandler,
        deactivation_userdata: ?*anyopaque,
    ) ?*anyopaque;
    extern fn accesskit_unix_adapter_free(adapter: *anyopaque) void;
    extern fn accesskit_unix_adapter_update_if_active(adapter: *anyopaque, factory: Factory, userdata: ?*anyopaque) void;
    extern fn accesskit_unix_adapter_update_window_focus_state(adapter: *anyopaque, is_focused: bool) void;
    extern fn accesskit_unix_adapter_set_root_window_bounds(adapter: *anyopaque, outer: Rect, inner: Rect) void;

    // macOS.
    extern fn accesskit_macos_add_focus_forwarder_to_window_class(class_name: [*:0]const u8) void;
    extern fn accesskit_macos_subclassing_adapter_for_window(
        window: *anyopaque,
        activation_handler: Factory,
        activation_userdata: ?*anyopaque,
        action_handler: ActionHandler,
        action_userdata: ?*anyopaque,
    ) ?*anyopaque;
    extern fn accesskit_macos_subclassing_adapter_free(adapter: *anyopaque) void;
    extern fn accesskit_macos_subclassing_adapter_update_if_active(adapter: *anyopaque, factory: Factory, userdata: ?*anyopaque) ?*QueuedEvents;
    extern fn accesskit_macos_subclassing_adapter_update_view_focus_state(adapter: *anyopaque, is_focused: bool) ?*QueuedEvents;
    extern fn accesskit_macos_queued_events_raise(events: *QueuedEvents) void;

    // Windows.
    extern fn accesskit_windows_subclassing_adapter_new(
        hwnd: *anyopaque,
        activation_handler: Factory,
        activation_userdata: ?*anyopaque,
        action_handler: ActionHandler,
        action_userdata: ?*anyopaque,
    ) ?*anyopaque;
    extern fn accesskit_windows_subclassing_adapter_free(adapter: *anyopaque) void;
    extern fn accesskit_windows_subclassing_adapter_update_if_active(adapter: *anyopaque, factory: Factory, userdata: ?*anyopaque) ?*QueuedEvents;
    extern fn accesskit_windows_queued_events_raise(events: *QueuedEvents) void;
};

// ---- Tests ----------------------------------------------------------------

test "accesskit: windowState reads a native window" {
    const t = std.testing;
    var dummy: u8 = 0;
    // The fields of sw_platform.NativeWindow.
    const TestWindow = struct {
        kind: enum { none, cocoa, win32, x11, wayland },
        handle: ?*anyopaque,
        focused: bool,
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        border_top: i32,
        border_left: i32,
        border_bottom: i32,
        border_right: i32,
    };
    var nw: TestWindow = .{
        .kind = .cocoa,
        .handle = &dummy,
        .focused = true,
        .x = 100,
        .y = 50,
        .w = 800,
        .h = 600,
        .border_top = 28,
        .border_left = 2,
        .border_bottom = 2,
        .border_right = 2,
    };
    const s = windowState(nw);
    try t.expect(s.handle == .cocoa_window);
    try t.expect(s.focused);
    try t.expectEqual(map.Bounds{ .x0 = 100, .y0 = 50, .x1 = 900, .y1 = 650 }, s.inner);
    try t.expectEqual(map.Bounds{ .x0 = 98, .y0 = 22, .x1 = 902, .y1 = 652 }, s.outer);

    nw.kind = .x11;
    try t.expect(windowState(nw).handle == .none);
}

test "accesskit: with the build option off, the adapter does nothing" {
    if (enabled) return error.SkipZigTest;
    var ak: Adapter = .{};
    ak.start(std.testing.allocator, .{}, "app");
    try std.testing.expect(ak.native == null);
    try ak.publish(.{ .nodes = &.{} }, 1);
    try std.testing.expect(ak.takeAction() == null);
    ak.stop();
}
