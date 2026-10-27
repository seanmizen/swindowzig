//! The web side of the gamepads (REQ-INPUT-005). The web Gamepad API has no
//! events for buttons and axes: `backends/wasm/gamepad.ts` reads each
//! gamepad once per frame, before `swindowzig_frame`, and calls these
//! exports for each change. The numbers are the values of
//! `core.GamepadButton` and `core.GamepadAxis`.

const std = @import("std");
const core = @import("sw_core");
const wasm_canvas = @import("wasm_canvas.zig");

/// A gamepad connected to slot `pad` (`connected` 1), or disconnected
/// (`connected` 0).
export fn swindowzig_event_gamepad_connection(pad: u32, connected: u32) void {
    if (!wasm_canvas.ready() or pad >= core.max_gamepads) return;
    wasm_canvas.pushEvent(.{ .gamepad_connection = .{
        .pad = @intCast(pad),
        .connected = connected != 0,
    } }, wasm_canvas.global_allocator);
}

/// A button of the gamepad in slot `pad` went down (`down` 1) or up.
export fn swindowzig_event_gamepad_button(pad: u32, button: u32, down: u32) void {
    if (!wasm_canvas.ready() or pad >= core.max_gamepads) return;
    const b = enumOf(core.GamepadButton, button) orelse return;
    wasm_canvas.pushEvent(.{ .gamepad_button = .{
        .pad = @intCast(pad),
        .button = b,
        .down = down != 0,
    } }, wasm_canvas.global_allocator);
}

/// An axis of the gamepad in slot `pad` has a new raw value.
export fn swindowzig_event_gamepad_axis(pad: u32, axis: u32, value: f32) void {
    if (!wasm_canvas.ready() or pad >= core.max_gamepads) return;
    const a = enumOf(core.GamepadAxis, axis) orelse return;
    wasm_canvas.pushEvent(.{ .gamepad_axis = .{
        .pad = @intCast(pad),
        .axis = a,
        .value = value,
    } }, wasm_canvas.global_allocator);
}

fn enumOf(comptime E: type, v: u32) ?E {
    for (std.enums.values(E)) |m| {
        if (@backingInt(m) == v) return m;
    }
    return null;
}
