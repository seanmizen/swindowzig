// SDL2 Native Backend
const std = @import("std");
const core = @import("sw_core");
const backend_mod = @import("backend.zig");
const platform = @import("platform.zig");

const sdl = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_syswm.h");
});

pub const SDL2Backend = struct {
    allocator: std.mem.Allocator,
    window: *sdl.SDL_Window,
    start_time: i64,
    window_info: platform.WindowInfo,

    pub fn create(allocator: std.mem.Allocator, title: []const u8, width: u32, height: u32) !backend_mod.Backend {
        const self = try allocator.create(SDL2Backend);
        errdefer allocator.destroy(self);

        // Initialize SDL
        if (sdl.SDL_Init(sdl.SDL_INIT_VIDEO) < 0) {
            std.log.err("SDL_Init failed: {s}", .{sdl.SDL_GetError()});
            return error.SDLInitFailed;
        }

        // Create window
        const title_z = try allocator.dupeZ(u8, title);
        defer allocator.free(title_z);

        const window = sdl.SDL_CreateWindow(
            title_z.ptr,
            sdl.SDL_WINDOWPOS_CENTERED,
            sdl.SDL_WINDOWPOS_CENTERED,
            @intCast(width),
            @intCast(height),
            sdl.SDL_WINDOW_SHOWN | sdl.SDL_WINDOW_RESIZABLE | sdl.SDL_WINDOW_ALLOW_HIGHDPI,
        ) orelse {
            std.log.err("SDL_CreateWindow failed: {s}", .{sdl.SDL_GetError()});
            sdl.SDL_Quit();
            return error.SDLWindowCreationFailed;
        };

        // Get actual DPI scale
        var drawable_w: c_int = 0;
        var drawable_h: c_int = 0;
        var window_w: c_int = 0;
        var window_h: c_int = 0;
        sdl.SDL_GL_GetDrawableSize(window, &drawable_w, &drawable_h);
        sdl.SDL_GetWindowSize(window, &window_w, &window_h);

        const dpi_scale = if (window_w > 0)
            @as(f32, @floatFromInt(drawable_w)) / @as(f32, @floatFromInt(window_w))
        else
            1.0;

        self.* = .{
            .allocator = allocator,
            .window = window,
            .start_time = std.time.milliTimestamp(),
            .window_info = .{
                .width = @intCast(drawable_w),
                .height = @intCast(drawable_h),
                .dpi_scale = dpi_scale,
            },
        };

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

    fn init(_: *anyopaque) !void {
        // Window already created in create()
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *SDL2Backend = @ptrCast(@alignCast(ptr));
        sdl.SDL_DestroyWindow(self.window);
        sdl.SDL_Quit();
        self.allocator.destroy(self);
    }

    fn pollEvents(ptr: *anyopaque, bus: *core.Bus) !void {
        const self: *SDL2Backend = @ptrCast(@alignCast(ptr));

        var event: sdl.SDL_Event = undefined;
        while (sdl.SDL_PollEvent(&event) != 0) {
            const now_ns = getTime(ptr);

            switch (event.type) {
                sdl.SDL_QUIT => {
                    try bus.push(0, now_ns, .{ .lifecycle = .shutdown });
                },

                sdl.SDL_WINDOWEVENT => {
                    switch (event.window.event) {
                        sdl.SDL_WINDOWEVENT_RESIZED, sdl.SDL_WINDOWEVENT_SIZE_CHANGED => {
                            // Update window info
                            var drawable_w: c_int = 0;
                            var drawable_h: c_int = 0;
                            var window_w: c_int = 0;
                            var window_h: c_int = 0;
                            sdl.SDL_GL_GetDrawableSize(self.window, &drawable_w, &drawable_h);
                            sdl.SDL_GetWindowSize(self.window, &window_w, &window_h);

                            const dpi_scale = if (window_w > 0)
                                @as(f32, @floatFromInt(drawable_w)) / @as(f32, @floatFromInt(window_w))
                            else
                                1.0;

                            self.window_info.width = @intCast(drawable_w);
                            self.window_info.height = @intCast(drawable_h);
                            self.window_info.dpi_scale = dpi_scale;

                            try bus.push(0, now_ns, .{
                                .resize = .{
                                    .width = self.window_info.width,
                                    .height = self.window_info.height,
                                    .dpi_scale = dpi_scale,
                                },
                            });
                        },
                        sdl.SDL_WINDOWEVENT_FOCUS_GAINED => {
                            try bus.push(0, now_ns, .{ .focus = .{ .focused = true } });
                        },
                        sdl.SDL_WINDOWEVENT_FOCUS_LOST => {
                            try bus.push(0, now_ns, .{ .focus = .{ .focused = false } });
                        },
                        else => {},
                    }
                },

                sdl.SDL_MOUSEMOTION => {
                    const mouse_event = event.motion;
                    try bus.push(0, now_ns, .{
                        .pointer_move = .{
                            .x = @floatFromInt(mouse_event.x),
                            .y = @floatFromInt(mouse_event.y),
                            .dx = @floatFromInt(mouse_event.xrel),
                            .dy = @floatFromInt(mouse_event.yrel),
                            .device_id = mouse_event.which,
                            .mods = getModifiers(),
                        },
                    });
                },

                sdl.SDL_MOUSEBUTTONDOWN, sdl.SDL_MOUSEBUTTONUP => {
                    const button_event = event.button;
                    const button = sdlButtonToMouseButton(button_event.button);
                    try bus.push(0, now_ns, .{
                        .pointer_button = .{
                            .button = button,
                            .down = event.type == sdl.SDL_MOUSEBUTTONDOWN,
                            .mods = getModifiers(),
                        },
                    });
                },

                sdl.SDL_MOUSEWHEEL => {
                    const wheel_event = event.wheel;
                    var dx: f32 = @floatFromInt(wheel_event.x);
                    var dy: f32 = @floatFromInt(wheel_event.y);

                    // SDL_MOUSEWHEEL_FLIPPED means the values are reversed
                    if (wheel_event.direction == sdl.SDL_MOUSEWHEEL_FLIPPED) {
                        dx = -dx;
                        dy = -dy;
                    }

                    try bus.push(0, now_ns, .{
                        .wheel = .{
                            .dx = dx,
                            .dy = dy,
                            .mode = .line,
                            .mods = getModifiers(),
                        },
                    });
                },

                sdl.SDL_KEYDOWN, sdl.SDL_KEYUP => {
                    const key_event = event.key;
                    const keycode = sdlKeycodeToKeyCode(key_event.keysym.sym);

                    try bus.push(0, now_ns, .{
                        .key = .{
                            .keycode = keycode,
                            .scancode = key_event.keysym.scancode,
                            .down = event.type == sdl.SDL_KEYDOWN,
                            .repeat = key_event.repeat != 0,
                            .mods = getModifiers(),
                        },
                    });
                },

                sdl.SDL_TEXTINPUT => {
                    // Convert SDL text input to event
                    const text_event = event.text;
                    var utf8_buf: [32]u8 = [_]u8{0} ** 32;
                    var len: u8 = 0;

                    // Copy SDL text to buffer (text is null-terminated)
                    while (len < 32 and text_event.text[len] != 0) : (len += 1) {
                        utf8_buf[len] = @intCast(text_event.text[len]);
                    }

                    if (len > 0) {
                        try bus.push(0, now_ns, .{
                            .text = .{
                                .utf8 = utf8_buf,
                                .len = len,
                            },
                        });
                    }
                },

                else => {},
            }
        }
    }

    fn getTime(ptr: *anyopaque) u64 {
        const self: *SDL2Backend = @ptrCast(@alignCast(ptr));
        const now = std.time.milliTimestamp();
        const elapsed = now - self.start_time;
        return @as(u64, @intCast(elapsed)) * 1_000_000; // Convert ms to ns
    }

    fn getWindowInfo(ptr: *anyopaque) platform.WindowInfo {
        const self: *SDL2Backend = @ptrCast(@alignCast(ptr));
        return self.window_info;
    }

    fn getWindow(ptr: *anyopaque) ?*anyopaque {
        const self: *SDL2Backend = @ptrCast(@alignCast(ptr));
        return @ptrCast(self.window);
    }

    // Helper to get current keyboard modifiers
    fn getModifiers() core.Modifiers {
        const mod_state = sdl.SDL_GetModState();
        return .{
            .shift = (mod_state & sdl.KMOD_SHIFT) != 0,
            .ctrl = (mod_state & sdl.KMOD_CTRL) != 0,
            .alt = (mod_state & sdl.KMOD_ALT) != 0,
            .super = (mod_state & sdl.KMOD_GUI) != 0,
            .caps_lock = (mod_state & sdl.KMOD_CAPS) != 0,
            .num_lock = (mod_state & sdl.KMOD_NUM) != 0,
        };
    }

    // Map SDL mouse button to our MouseButton enum
    fn sdlButtonToMouseButton(button: u8) core.MouseButton {
        return switch (button) {
            sdl.SDL_BUTTON_LEFT => .left,
            sdl.SDL_BUTTON_RIGHT => .right,
            sdl.SDL_BUTTON_MIDDLE => .middle,
            sdl.SDL_BUTTON_X1 => .x1,
            sdl.SDL_BUTTON_X2 => .x2,
            else => .left, // Default to left
        };
    }

    // Map SDL keycode to our KeyCode enum
    fn sdlKeycodeToKeyCode(sym: c_int) core.KeyCode {
        return switch (sym) {
            // Letters
            sdl.SDLK_a => .A,
            sdl.SDLK_b => .B,
            sdl.SDLK_c => .C,
            sdl.SDLK_d => .D,
            sdl.SDLK_e => .E,
            sdl.SDLK_f => .F,
            sdl.SDLK_g => .G,
            sdl.SDLK_h => .H,
            sdl.SDLK_i => .I,
            sdl.SDLK_j => .J,
            sdl.SDLK_k => .K,
            sdl.SDLK_l => .L,
            sdl.SDLK_m => .M,
            sdl.SDLK_n => .N,
            sdl.SDLK_o => .O,
            sdl.SDLK_p => .P,
            sdl.SDLK_q => .Q,
            sdl.SDLK_r => .R,
            sdl.SDLK_s => .S,
            sdl.SDLK_t => .T,
            sdl.SDLK_u => .U,
            sdl.SDLK_v => .V,
            sdl.SDLK_w => .W,
            sdl.SDLK_x => .X,
            sdl.SDLK_y => .Y,
            sdl.SDLK_z => .Z,

            // Numbers
            sdl.SDLK_0 => .Num0,
            sdl.SDLK_1 => .Num1,
            sdl.SDLK_2 => .Num2,
            sdl.SDLK_3 => .Num3,
            sdl.SDLK_4 => .Num4,
            sdl.SDLK_5 => .Num5,
            sdl.SDLK_6 => .Num6,
            sdl.SDLK_7 => .Num7,
            sdl.SDLK_8 => .Num8,
            sdl.SDLK_9 => .Num9,

            // Arrow keys
            sdl.SDLK_LEFT => .Left,
            sdl.SDLK_RIGHT => .Right,
            sdl.SDLK_UP => .Up,
            sdl.SDLK_DOWN => .Down,

            // Special keys
            sdl.SDLK_SPACE => .Space,
            sdl.SDLK_RETURN => .Enter,
            sdl.SDLK_ESCAPE => .Escape,
            sdl.SDLK_TAB => .Tab,
            sdl.SDLK_BACKSPACE => .Backspace,
            sdl.SDLK_LSHIFT, sdl.SDLK_RSHIFT => .Shift,
            sdl.SDLK_LCTRL, sdl.SDLK_RCTRL => .Ctrl,
            sdl.SDLK_LALT, sdl.SDLK_RALT => .Alt,
            sdl.SDLK_LGUI, sdl.SDLK_RGUI => .Super,

            // Function keys
            sdl.SDLK_F1 => .F1,
            sdl.SDLK_F2 => .F2,
            sdl.SDLK_F3 => .F3,
            sdl.SDLK_F4 => .F4,
            sdl.SDLK_F5 => .F5,
            sdl.SDLK_F6 => .F6,
            sdl.SDLK_F7 => .F7,
            sdl.SDLK_F8 => .F8,
            sdl.SDLK_F9 => .F9,
            sdl.SDLK_F10 => .F10,
            sdl.SDLK_F11 => .F11,
            sdl.SDLK_F12 => .F12,

            else => .Unknown,
        };
    }
};
