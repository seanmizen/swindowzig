// WASM Canvas Backend - JS forwards events to Zig
const std = @import("std");
const core = @import("sw_core");
const backend_mod = @import("backend.zig");
const platform = @import("platform.zig");

// Global event queue for WASM event handlers
var global_event_queue: ?*std.ArrayList(core.Event) = null;
// Global window info reference for resize updates
var global_window_info: ?*platform.WindowInfo = null;

pub const WasmBackend = struct {
    allocator: std.mem.Allocator,
    start_time_ms: f64,
    window_info: platform.WindowInfo,
    event_queue: std.ArrayList(core.Event),
    next_tick_id: u64,

    pub fn create(allocator: std.mem.Allocator) !backend_mod.Backend {
        const self = try allocator.create(WasmBackend);
        self.* = .{
            .allocator = allocator,
            .start_time_ms = 0,
            .window_info = .{
                .width = 1280,
                .height = 720,
                .dpi_scale = 1.0,
            },
            .event_queue = .{},
            .next_tick_id = 0,
        };

        // Set global references for WASM exports
        global_event_queue = &self.event_queue;
        global_window_info = &self.window_info;
        global_allocator = allocator;

        return .{
            .ptr = self,
            .vtable = &.{
                .init = init,
                .deinit = deinit,
                .pollEvents = pollEvents,
                .getTime = getTime,
                .getWindowInfo = getWindowInfo,
                .getWindow = getWindow,
            },
        };
    }

    fn init(ptr: *anyopaque) !void {
        const self: *WasmBackend = @ptrCast(@alignCast(ptr));
        self.start_time_ms = jsGetTime();
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *WasmBackend = @ptrCast(@alignCast(ptr));
        self.event_queue.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn pollEvents(ptr: *anyopaque, bus: *core.Bus) !void {
        const self: *WasmBackend = @ptrCast(@alignCast(ptr));

        // Drain event queue into bus
        for (self.event_queue.items) |event| {
            try bus.push(event.tick_id, event.t_ns, event.payload);
        }
        self.event_queue.clearRetainingCapacity();
    }

    fn getTime(ptr: *anyopaque) u64 {
        const self: *WasmBackend = @ptrCast(@alignCast(ptr));
        const now_ms = jsGetTime();
        const elapsed_ms = now_ms - self.start_time_ms;
        return @as(u64, @intFromFloat(elapsed_ms * 1_000_000.0)); // ms to ns
    }

    fn getWindowInfo(ptr: *anyopaque) platform.WindowInfo {
        const self: *WasmBackend = @ptrCast(@alignCast(ptr));
        return self.window_info;
    }

    fn getWindow(_: *anyopaque) ?*anyopaque {
        // WASM doesn't have a window handle concept
        return null;
    }
};

// Helper to push events from exports
fn pushEvent(payload: core.EventPayload, allocator: std.mem.Allocator) void {
    if (global_event_queue) |queue| {
        const event = core.Event{
            .tick_id = 0,
            .t_ns = @intFromFloat(jsGetTime() * 1_000_000.0),
            .seq = 0,
            .payload = payload,
        };
        queue.append(allocator, event) catch return;
    }
}

// Global allocator ref
var global_allocator: std.mem.Allocator = undefined;

// Map JS keycode to Zig KeyCode
fn mapKeyCode(js_keycode: u16) core.KeyCode {
    return switch (js_keycode) {
        65 => .A, 66 => .B, 67 => .C, 68 => .D, 69 => .E, 70 => .F,
        71 => .G, 72 => .H, 73 => .I, 74 => .J, 75 => .K, 76 => .L,
        77 => .M, 78 => .N, 79 => .O, 80 => .P, 81 => .Q, 82 => .R,
        83 => .S, 84 => .T, 85 => .U, 86 => .V, 87 => .W, 88 => .X,
        89 => .Y, 90 => .Z,
        48 => .Num0, 49 => .Num1, 50 => .Num2, 51 => .Num3, 52 => .Num4,
        53 => .Num5, 54 => .Num6, 55 => .Num7, 56 => .Num8, 57 => .Num9,
        37 => .Left, 38 => .Up, 39 => .Right, 40 => .Down,
        32 => .Space, 13 => .Enter, 27 => .Escape, 9 => .Tab, 8 => .Backspace,
        16 => .Shift, 17 => .Ctrl, 18 => .Alt,
        else => .Unknown,
    };
}

// Event injection from JS (exported from user's main.zig)
export fn swindowzig_event_resize(width: u32, height: u32, dpi_scale: f32) void {
    // Update window info immediately so getWindowInfo() returns correct values
    if (global_window_info) |info| {
        info.width = width;
        info.height = height;
        info.dpi_scale = dpi_scale;
    }
    pushEvent(.{ .resize = .{ .width = width, .height = height, .dpi_scale = dpi_scale } }, global_allocator);
}

// Track current modifier state
var current_mods: core.Modifiers = .{};

export fn swindowzig_event_mouse_move(x: f32, y: f32, dx: f32, dy: f32) void {
    pushEvent(.{ .pointer_move = .{
        .x = x,
        .y = y,
        .dx = dx,
        .dy = dy,
        .device_id = 0,
        .mods = current_mods,
    } }, global_allocator);
}

export fn swindowzig_event_mouse_button(button: u8, down: bool) void {
    const mouse_button: core.MouseButton = @enumFromInt(button);
    pushEvent(.{ .pointer_button = .{
        .button = mouse_button,
        .down = down,
        .mods = current_mods,
    } }, global_allocator);
}

export fn swindowzig_event_key(keycode: u16, down: bool) void {
    const key = mapKeyCode(keycode);

    // Update modifier state
    switch (key) {
        .Ctrl => current_mods.ctrl = down,
        .Shift => current_mods.shift = down,
        .Alt => current_mods.alt = down,
        .Super => current_mods.super = down,
        else => {},
    }

    pushEvent(.{ .key = .{
        .keycode = key,
        .scancode = 0,
        .down = down,
        .repeat = false,
        .mods = current_mods,
    } }, global_allocator);
}

// JS imports
extern fn jsGetTime() f64;
