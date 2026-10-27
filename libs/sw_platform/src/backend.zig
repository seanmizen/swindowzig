const std = @import("std");
const core = @import("sw_core");
const Event = core.Event;
const EventPayload = core.EventPayload;
const platform = @import("platform.zig");
const WindowInfo = platform.WindowInfo;
const WindowMode = platform.WindowMode;
const CursorMode = platform.CursorMode;

/// Backend interface that all platforms must implement
pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        init: *const fn (ptr: *anyopaque) anyerror!void,
        deinit: *const fn (ptr: *anyopaque) void,
        pollEvents: *const fn (ptr: *anyopaque, bus: *core.Bus) anyerror!void,
        getTime: *const fn (ptr: *anyopaque) u64,
        getWindowInfo: *const fn (ptr: *anyopaque) WindowInfo,
        getWindow: *const fn (ptr: *anyopaque) ?*anyopaque,
        setMouseCapture: *const fn (ptr: *anyopaque, capture: bool) void,
        setTextInput: *const fn (ptr: *anyopaque, active: bool) void,
        // The entries below have defaults, so a VTable that a game makes
        // with the entries above still compiles. The defaults do nothing.
        setWindowMode: *const fn (ptr: *anyopaque, mode: WindowMode) void = defaults.setWindowMode,
        getWindowMode: *const fn (ptr: *anyopaque) WindowMode = defaults.getWindowMode,
        setCursorMode: *const fn (ptr: *anyopaque, mode: CursorMode) void = defaults.setCursorMode,
        isCursorLocked: *const fn (ptr: *anyopaque) bool = defaults.isCursorLocked,
        setClipboardText: *const fn (ptr: *anyopaque, text: []const u8) void = defaults.setClipboardText,
        requestClipboardText: *const fn (ptr: *anyopaque) void = defaults.requestClipboardText,
        clipboardText: *const fn (ptr: *anyopaque) []const u8 = defaults.clipboardText,
        setPasteAsText: *const fn (ptr: *anyopaque, on: bool) void = defaults.setPasteAsText,
    };

    const defaults = struct {
        fn setWindowMode(_: *anyopaque, _: WindowMode) void {}
        fn getWindowMode(_: *anyopaque) WindowMode {
            return .windowed;
        }
        fn setCursorMode(_: *anyopaque, _: CursorMode) void {}
        fn isCursorLocked(_: *anyopaque) bool {
            return false;
        }
        fn setClipboardText(_: *anyopaque, _: []const u8) void {}
        fn requestClipboardText(_: *anyopaque) void {}
        fn clipboardText(_: *anyopaque) []const u8 {
            return "";
        }
        fn setPasteAsText(_: *anyopaque, _: bool) void {}
    };

    pub fn init(self: Backend) !void {
        return self.vtable.init(self.ptr);
    }

    pub fn deinit(self: Backend) void {
        self.vtable.deinit(self.ptr);
    }

    pub fn pollEvents(self: Backend, bus: *core.Bus) !void {
        return self.vtable.pollEvents(self.ptr, bus);
    }

    pub fn getTime(self: Backend) u64 {
        return self.vtable.getTime(self.ptr);
    }

    pub fn getWindowInfo(self: Backend) WindowInfo {
        return self.vtable.getWindowInfo(self.ptr);
    }

    pub fn getWindow(self: Backend) ?*anyopaque {
        return self.vtable.getWindow(self.ptr);
    }

    pub fn setMouseCapture(self: Backend, capture: bool) void {
        return self.vtable.setMouseCapture(self.ptr, capture);
    }

    /// Turn the platform input method on or off. While it is on, the backend
    /// sends `text_input` and `text_composition` events.
    pub fn setTextInput(self: Backend, active: bool) void {
        return self.vtable.setTextInput(self.ptr, active);
    }

    /// Go to full screen or back to a window. The size change arrives as a
    /// `resize` event.
    pub fn setWindowMode(self: Backend, mode: WindowMode) void {
        self.vtable.setWindowMode(self.ptr, mode);
    }

    /// The window mode now. On the web, the browser can end full screen
    /// (Escape), so this reads the real state.
    pub fn getWindowMode(self: Backend) WindowMode {
        return self.vtable.getWindowMode(self.ptr);
    }

    /// Show, hide or lock the cursor.
    pub fn setCursorMode(self: Backend, mode: CursorMode) void {
        self.vtable.setCursorMode(self.ptr, mode);
    }

    /// True while the cursor is locked. On the web, the browser can refuse
    /// or end the pointer lock, so this reads the real state.
    pub fn isCursorLocked(self: Backend) bool {
        return self.vtable.isCursorLocked(self.ptr);
    }

    /// Start a write of `text` to the clipboard. A `clipboard` event of
    /// kind `write` gives the result.
    pub fn setClipboardText(self: Backend, text: []const u8) void {
        self.vtable.setClipboardText(self.ptr, text);
    }

    /// Start a read of the clipboard. A `clipboard` event of kind `read`
    /// gives the result, and `clipboardText` gives the text.
    pub fn requestClipboardText(self: Backend) void {
        self.vtable.requestClipboardText(self.ptr);
    }

    /// The last clipboard text that the platform knows.
    pub fn clipboardText(self: Backend) []const u8 {
        return self.vtable.clipboardText(self.ptr);
    }

    /// Web: when true (the default), a paste into the text input also
    /// types the text as `text_input` events. When false, a paste sends
    /// only the `clipboard` event of kind `paste`.
    pub fn setPasteAsText(self: Backend, on: bool) void {
        self.vtable.setPasteAsText(self.ptr, on);
    }
};
