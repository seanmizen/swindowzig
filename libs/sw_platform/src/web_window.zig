//! The web side of the window modes, the cursor modes and the clipboard.
//! The JS side is `backends/wasm/window.ts` and `backends/wasm/clipboard.ts`.
//! `wasm_canvas.zig` puts these functions in the vtable of `WasmBackend`.

const std = @import("std");
const core = @import("sw_core");
const platform = @import("platform.zig");
const clipboard = @import("clipboard.zig");
const wasm_canvas = @import("wasm_canvas.zig");

extern fn jsSetWindowMode(mode: u8) void;
extern fn jsGetWindowMode() u8;
extern fn jsSetCursorMode(mode: u8) void;
extern fn jsCursorLocked() u8;
extern fn jsClipboardWrite(ptr: [*]const u8, len: u32) void;
extern fn jsClipboardRead() void;
extern fn jsSetPasteAsText(on: u8) void;

/// The clipboard text that the web backend knows: the last paste, read or
/// write.
var state: clipboard.ClipboardState = .{};

pub fn setWindowMode(_: *anyopaque, mode: platform.WindowMode) void {
    jsSetWindowMode(@backingInt(mode));
}

pub fn getWindowMode(_: *anyopaque) platform.WindowMode {
    return if (jsGetWindowMode() == @backingInt(platform.WindowMode.fullscreen)) .fullscreen else .windowed;
}

pub fn setCursorMode(_: *anyopaque, mode: platform.CursorMode) void {
    jsSetCursorMode(@backingInt(mode));
}

pub fn isCursorLocked(_: *anyopaque) bool {
    return jsCursorLocked() != 0;
}

pub fn setClipboardText(_: *anyopaque, text: []const u8) void {
    // Keep the text first: a paste in the game then gives it, also when the
    // browser refuses the write.
    state.store(wasm_canvas.global_allocator, text) catch {
        wasm_canvas.pushEvent(.{ .clipboard = clipboard.writeResult(.failed) }, wasm_canvas.global_allocator);
        return;
    };
    const kept = state.slice();
    jsClipboardWrite(kept.ptr, @intCast(kept.len));
}

pub fn requestClipboardText(_: *anyopaque) void {
    jsClipboardRead();
}

pub fn clipboardText(_: *anyopaque) []const u8 {
    return state.slice();
}

pub fn setPasteAsText(_: *anyopaque, on: bool) void {
    jsSetPasteAsText(if (on) 1 else 0);
}

/// JS asks for room for `len` bytes of clipboard text. Returns the address,
/// or 0 when the text is larger than `clipboard.max_text_len`. JS writes
/// the UTF-8 bytes there, then calls `swindowzig_clipboard_event`.
export fn swindowzig_clipboard_reserve(len: u32) usize {
    // A paste before swindowzig_init has no allocator yet.
    if (!wasm_canvas.ready()) return 0;
    const buf = state.reserve(wasm_canvas.global_allocator, len) orelse return 0;
    return @intFromPtr(buf.ptr);
}

/// JS reports a completed clipboard operation. `kind` and `status` are the
/// numbers of `core.ClipboardEventKind` and `core.ClipboardStatus`. For a
/// paste or a read with status ok, the text is the `len` bytes that JS
/// wrote after `swindowzig_clipboard_reserve`.
export fn swindowzig_clipboard_event(kind: u8, status: u8, len: u32) void {
    if (!wasm_canvas.ready()) return;
    const k: core.ClipboardEventKind = switch (kind) {
        0 => .paste,
        1 => .read,
        2 => .write,
        else => return,
    };
    const st: core.ClipboardStatus = switch (status) {
        0 => .ok,
        1 => .unavailable,
        2 => .denied,
        3 => .no_text,
        else => .failed,
    };
    var n: u32 = 0;
    if (k != .write) {
        if (st == .ok) {
            state.truncate(len);
            n = @intCast(state.slice().len);
        } else {
            // A failed read keeps the text that the game knew before.
            n = 0;
        }
    }
    wasm_canvas.pushEvent(.{ .clipboard = .{ .kind = k, .status = st, .len = n } }, wasm_canvas.global_allocator);
}
