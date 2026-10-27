// Null (headless) backend — no window, no GPU, all calls are no-ops.
// getTime() returns a synthetic monotonic clock driven by tickNs() calls.
const std = @import("std");
const core = @import("sw_core");
const platform = @import("platform.zig");
const backend_mod = @import("backend.zig");
const clipboard = @import("clipboard.zig");

pub const NullBackend = struct {
    elapsed_ns: u64 = 0,
    window_mode: platform.WindowMode = .windowed,
    cursor_mode: platform.CursorMode = .normal,
    /// A clipboard in memory. Each operation completes on the next poll, as
    /// on the native platform.
    clipboard: clipboard.ClipboardState = .{},

    const clip_alloc = std.heap.page_allocator;

    const vtable = backend_mod.Backend.VTable{
        .init = init,
        .deinit = deinit,
        .pollEvents = pollEvents,
        .getTime = getTime,
        .getWindowInfo = getWindowInfo,
        .getWindow = getWindow,
        .setMouseCapture = setMouseCapture,
        .setTextInput = setTextInput,
        .setWindowMode = setWindowMode,
        .getWindowMode = getWindowMode,
        .setCursorMode = setCursorMode,
        .isCursorLocked = isCursorLocked,
        .setClipboardText = setClipboardText,
        .requestClipboardText = requestClipboardText,
        .clipboardText = clipboardText,
    };

    pub fn backend(self: *NullBackend) backend_mod.Backend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Advance the synthetic clock by ns nanoseconds. Call once per tick in unlimited mode.
    pub fn advanceTime(self: *NullBackend, ns: u64) void {
        self.elapsed_ns += ns;
    }

    fn init(_: *anyopaque) anyerror!void {}
    fn deinit(ptr: *anyopaque) void {
        const self: *NullBackend = @ptrCast(@alignCast(ptr));
        self.clipboard.deinit(clip_alloc);
    }

    fn pollEvents(ptr: *anyopaque, bus: *core.Bus) anyerror!void {
        const self: *NullBackend = @ptrCast(@alignCast(ptr));
        try self.clipboard.flush(bus, self.elapsed_ns);
    }

    fn getTime(ptr: *anyopaque) u64 {
        const self: *NullBackend = @ptrCast(@alignCast(ptr));
        return self.elapsed_ns;
    }

    fn getWindowInfo(_: *anyopaque) platform.WindowInfo {
        return .{ .width = 1280, .height = 720, .dpi_scale = 1.0 };
    }

    fn getWindow(_: *anyopaque) ?*anyopaque {
        return null;
    }

    fn setMouseCapture(_: *anyopaque, _: bool) void {}
    fn setTextInput(_: *anyopaque, _: bool) void {}

    fn setWindowMode(ptr: *anyopaque, mode: platform.WindowMode) void {
        const self: *NullBackend = @ptrCast(@alignCast(ptr));
        self.window_mode = mode;
    }

    fn getWindowMode(ptr: *anyopaque) platform.WindowMode {
        const self: *NullBackend = @ptrCast(@alignCast(ptr));
        return self.window_mode;
    }

    fn setCursorMode(ptr: *anyopaque, mode: platform.CursorMode) void {
        const self: *NullBackend = @ptrCast(@alignCast(ptr));
        self.cursor_mode = mode;
    }

    fn isCursorLocked(ptr: *anyopaque) bool {
        const self: *NullBackend = @ptrCast(@alignCast(ptr));
        return self.cursor_mode == .locked;
    }

    fn setClipboardText(ptr: *anyopaque, text: []const u8) void {
        const self: *NullBackend = @ptrCast(@alignCast(ptr));
        self.clipboard.store(clip_alloc, text) catch {
            self.clipboard.queue(clipboard.writeResult(.failed));
            return;
        };
        self.clipboard.queue(clipboard.writeResult(.ok));
    }

    fn requestClipboardText(ptr: *anyopaque) void {
        const self: *NullBackend = @ptrCast(@alignCast(ptr));
        const len = self.clipboard.slice().len;
        self.clipboard.queue(clipboard.readResult(if (len == 0) .no_text else .ok, len));
    }

    fn clipboardText(ptr: *anyopaque) []const u8 {
        const self: *NullBackend = @ptrCast(@alignCast(ptr));
        return self.clipboard.slice();
    }
};

test "the null backend completes a clipboard write and read on the next poll" {
    var null_backend: NullBackend = .{};
    const b = null_backend.backend();
    defer b.deinit();
    var bus = core.Bus.init(std.testing.allocator);
    defer bus.deinit();

    b.setClipboardText("copied");
    b.requestClipboardText();
    try std.testing.expectEqual(@as(usize, 0), bus.events.items.len);
    try b.pollEvents(&bus);
    try std.testing.expectEqual(@as(usize, 2), bus.events.items.len);
    const read = bus.events.items[1].payload.clipboard;
    try std.testing.expectEqual(core.ClipboardEventKind.read, read.kind);
    try std.testing.expectEqual(core.ClipboardStatus.ok, read.status);
    try std.testing.expectEqualStrings("copied", b.clipboardText());
}

test "the null backend keeps the window and cursor modes" {
    var null_backend: NullBackend = .{};
    const b = null_backend.backend();
    defer b.deinit();
    try std.testing.expectEqual(platform.WindowMode.windowed, b.getWindowMode());
    b.setWindowMode(.fullscreen);
    try std.testing.expectEqual(platform.WindowMode.fullscreen, b.getWindowMode());
    try std.testing.expect(!b.isCursorLocked());
    b.setCursorMode(.locked);
    try std.testing.expect(b.isCursorLocked());
    // setMouseCapture does not change: it is a separate entry.
    b.setMouseCapture(false);
    try std.testing.expect(b.isCursorLocked());
}
