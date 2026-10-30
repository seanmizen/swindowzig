// SDL2 Native Backend
const std = @import("std");
const builtin = @import("builtin");
const core = @import("sw_core");
const backend_mod = @import("backend.zig");
const platform = @import("platform.zig");
const storage = @import("storage.zig");
const clipboard = @import("clipboard.zig");
const gamepad = @import("gamepad.zig");

// The SDL2 headers, translated by build.zig (addTranslateC on sdl.h).
const sdl = @import("sdl");

pub const SDL2Backend = struct {
    allocator: std.mem.Allocator,
    window: *sdl.SDL_Window,
    start_time: i64,
    window_info: platform.WindowInfo,
    clipboard: clipboard.ClipboardState = .{},
    /// The slot of each open game controller, by SDL instance ID
    /// (REQ-INPUT-005).
    pad_slots: gamepad.Slots(sdl.SDL_JoystickID, core.max_gamepads) = .{},
    pads: [core.max_gamepads]?*sdl.SDL_GameController = @splat(null),

    pub fn create(allocator: std.mem.Allocator, title: []const u8, width: u32, height: u32) !backend_mod.Backend {
        const self = try allocator.create(SDL2Backend);
        errdefer allocator.destroy(self);

        // Set SDL hints BEFORE SDL_Init / SDL_CreateWindow.
        //
        // MOUSE_FOCUS_CLICKTHROUGH=1: when an unfocused window is clicked, deliver
        // the click as a normal mouseDown event instead of swallowing it as a
        // focus-only click. Without this, alt-tabbing back to the game and clicking
        // a pause-menu button requires *two* clicks (one to focus, one to act).
        //
        // Note on macOS trackpad latency: this hint does NOT eliminate the ~80–120 ms
        // tap-to-click delay that the OS adds while it disambiguates a tap from a
        // double-tap or drag-start. That delay is system-level (Trackpad prefs) and
        // cannot be bypassed via SDL — see the "macOS Trackpad Click Latency" section
        // in CLAUDE.md.
        _ = sdl.SDL_SetHint(sdl.SDL_HINT_MOUSE_FOCUS_CLICKTHROUGH, "1");

        // Let the OS draw the IME candidate list. The game draws the
        // composition text itself.
        _ = sdl.SDL_SetHint(sdl.SDL_HINT_IME_SHOW_UI, "1");

        // macOS: full screen is a borderless window on the same Space, with
        // no animation. A full-screen Space ignores the request of an app
        // that is not active, and its animation delays the size change.
        _ = sdl.SDL_SetHint(sdl.SDL_HINT_VIDEO_MAC_FULLSCREEN_SPACES, "0");

        // Initialize SDL
        if (sdl.SDL_Init(sdl.SDL_INIT_VIDEO) < 0) {
            std.log.err("SDL_Init failed: {s}", .{sdl.SDL_GetError()});
            return error.SDLInitFailed;
        }

        // Game controllers. SDL sends SDL_CONTROLLERDEVICEADDED for each
        // controller that is connected now, and for each one that connects
        // later. Without the subsystem the game continues with no gamepads.
        if (sdl.SDL_InitSubSystem(sdl.SDL_INIT_GAMECONTROLLER) < 0) {
            std.log.warn("SDL game controller init failed: {s}. Gamepads are not available.", .{sdl.SDL_GetError()});
        }

        // Create window
        const title_z = try allocator.dupeSentinel(u8, title, 0);
        defer allocator.free(title_z);

        // Windows: the window stays hidden until sw_app calls showWindow
        // after the init callback. The AccessKit Windows adapter must
        // subclass the window before it is shown (REQ-PLATFORM-004).
        const visibility: u32 = if (builtin.os.tag == .windows) sdl.SDL_WINDOW_HIDDEN else sdl.SDL_WINDOW_SHOWN;
        const window = sdl.SDL_CreateWindow(
            title_z.ptr,
            sdl.SDL_WINDOWPOS_CENTERED,
            sdl.SDL_WINDOWPOS_CENTERED,
            @intCast(width),
            @intCast(height),
            visibility | sdl.SDL_WINDOW_RESIZABLE | sdl.SDL_WINDOW_ALLOW_HIGHDPI,
        ) orelse {
            std.log.err("SDL_CreateWindow failed: {s}", .{sdl.SDL_GetError()});
            sdl.SDL_Quit();
            return error.SDLWindowCreationFailed;
        };

        // SDL turns text input on at window creation on desktop. Text input
        // is off until the game calls Context.startTextInput.
        sdl.SDL_StopTextInput();

        self.* = .{
            .allocator = allocator,
            .window = window,
            .start_time = @intCast(sdl.SDL_GetTicks64()),
            .window_info = queryWindowInfo(window),
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
                .setMouseCapture = setMouseCapture,
                .setTextInput = setTextInput,
                .setWindowMode = setWindowMode,
                .getWindowMode = getWindowMode,
                .setCursorMode = setCursorMode,
                .isCursorLocked = isCursorLocked,
                .setClipboardText = setClipboardText,
                .requestClipboardText = requestClipboardText,
                .clipboardText = clipboardText,
                .getNativeWindow = getNativeWindow,
                .showWindow = showWindow,
            },
        };
    }

    fn init(_: *anyopaque) !void {
        // Window already created in create()
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *SDL2Backend = @ptrCast(@alignCast(ptr));
        self.clipboard.deinit(self.allocator);
        for (self.pads) |pad| if (pad) |gc| sdl.SDL_GameControllerClose(gc);
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
                            self.window_info = queryWindowInfo(self.window);
                            try pushResize(bus, now_ns, self.window_info);
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
                    const keycode = sdlKeyToKeyCode(key_event.keysym.sym, key_event.keysym.scancode);

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

                sdl.SDL_CONTROLLERDEVICEADDED => try self.openPad(bus, now_ns, event.cdevice.which),

                sdl.SDL_CONTROLLERDEVICEREMOVED => {
                    // For a removal, `which` is the instance ID.
                    const slot = self.pad_slots.disconnect(event.cdevice.which) orelse continue;
                    if (self.pads[slot]) |gc| sdl.SDL_GameControllerClose(gc);
                    self.pads[slot] = null;
                    try bus.push(0, now_ns, .{ .gamepad_connection = .{ .pad = slot, .connected = false } });
                },

                sdl.SDL_CONTROLLERBUTTONDOWN, sdl.SDL_CONTROLLERBUTTONUP => {
                    const b = event.cbutton;
                    const slot = self.pad_slots.find(b.which) orelse continue;
                    const button = sdlPadButton(b.button) orelse continue;
                    try bus.push(0, now_ns, .{ .gamepad_button = .{
                        .pad = slot,
                        .button = button,
                        .down = event.type == sdl.SDL_CONTROLLERBUTTONDOWN,
                    } });
                },

                sdl.SDL_CONTROLLERAXISMOTION => {
                    const a = event.caxis;
                    const slot = self.pad_slots.find(a.which) orelse continue;
                    const axis = sdlPadAxis(a.axis) orelse continue;
                    const value = switch (axis) {
                        .left_trigger, .right_trigger => gamepad.triggerFromSdl(a.value),
                        else => gamepad.stickFromSdl(a.value),
                    };
                    try bus.push(0, now_ns, .{ .gamepad_axis = .{ .pad = slot, .axis = axis, .value = value } });
                },

                sdl.SDL_TEXTINPUT => {
                    // The bus drops this while text input is off.
                    const text_event = event.text;
                    const text = cText(&text_event.text);
                    if (text.len > 0) {
                        try bus.push(0, now_ns, core.event.textInputPayload(text));
                    }
                },

                sdl.SDL_TEXTEDITING => {
                    // SDL sends empty text when the composition ends.
                    // start and length count code points; the event counts bytes.
                    const edit = event.edit;
                    const text = cText(&edit.text);
                    const cursor = core.event.utf8OffsetOfCodePoint(text, @intCast(@max(edit.start, 0)));
                    const end = core.event.utf8OffsetOfCodePoint(text, @intCast(@max(edit.start, 0) + @max(edit.length, 0)));
                    try bus.push(0, now_ns, core.event.textCompositionPayload(text, cursor, end - cursor));
                },

                else => {},
            }
        }

        // A move to a monitor with another DPI scale changes the pixel size,
        // but SDL does not always send SIZE_CHANGED for it (the size in
        // points stays the same). Compare the pixel size each poll
        // (REQ-PLATFORM-003).
        const info = queryWindowInfo(self.window);
        if (platform.windowInfoChanged(self.window_info, info)) {
            self.window_info = info;
            try pushResize(bus, getTime(ptr), info);
        }

        try self.clipboard.flush(bus, getTime(ptr));
    }

    /// Open the game controller at SDL device index `index`, and give it a
    /// slot. A controller with no free slot stays closed.
    fn openPad(self: *SDL2Backend, bus: *core.Bus, now_ns: u64, index: i32) !void {
        const gc = sdl.SDL_GameControllerOpen(index) orelse {
            std.log.warn("SDL_GameControllerOpen failed: {s}", .{sdl.SDL_GetError()});
            return;
        };
        const id = sdl.SDL_JoystickInstanceID(sdl.SDL_GameControllerGetJoystick(gc));
        if (self.pad_slots.find(id)) |_| {
            // SDL can report the same controller two times. The open above
            // added one reference, so close it.
            sdl.SDL_GameControllerClose(gc);
            return;
        }
        const slot = self.pad_slots.connect(id) orelse {
            std.log.warn("gamepad: {d} gamepads are connected. The engine ignores the new one.", .{core.max_gamepads});
            sdl.SDL_GameControllerClose(gc);
            return;
        };
        self.pads[slot] = gc;
        std.log.info("gamepad {d} connected: {s}", .{ slot, cName(sdl.SDL_GameControllerName(gc)) });
        try bus.push(0, now_ns, .{ .gamepad_connection = .{ .pad = slot, .connected = true } });
    }

    fn cName(name: [*c]const u8) []const u8 {
        if (name == null) return "(no name)";
        return std.mem.span(@as([*:0]const u8, @ptrCast(name)));
    }

    /// An SDL game controller button as a core gamepad button, by position.
    fn sdlPadButton(button: u8) ?core.GamepadButton {
        return switch (button) {
            sdl.SDL_CONTROLLER_BUTTON_A => .south,
            sdl.SDL_CONTROLLER_BUTTON_B => .east,
            sdl.SDL_CONTROLLER_BUTTON_X => .west,
            sdl.SDL_CONTROLLER_BUTTON_Y => .north,
            sdl.SDL_CONTROLLER_BUTTON_LEFTSHOULDER => .left_shoulder,
            sdl.SDL_CONTROLLER_BUTTON_RIGHTSHOULDER => .right_shoulder,
            sdl.SDL_CONTROLLER_BUTTON_BACK => .back,
            sdl.SDL_CONTROLLER_BUTTON_START => .start,
            sdl.SDL_CONTROLLER_BUTTON_GUIDE => .guide,
            sdl.SDL_CONTROLLER_BUTTON_LEFTSTICK => .left_stick,
            sdl.SDL_CONTROLLER_BUTTON_RIGHTSTICK => .right_stick,
            sdl.SDL_CONTROLLER_BUTTON_DPAD_UP => .dpad_up,
            sdl.SDL_CONTROLLER_BUTTON_DPAD_DOWN => .dpad_down,
            sdl.SDL_CONTROLLER_BUTTON_DPAD_LEFT => .dpad_left,
            sdl.SDL_CONTROLLER_BUTTON_DPAD_RIGHT => .dpad_right,
            else => null,
        };
    }

    fn sdlPadAxis(axis: u8) ?core.GamepadAxis {
        return switch (axis) {
            sdl.SDL_CONTROLLER_AXIS_LEFTX => .left_x,
            sdl.SDL_CONTROLLER_AXIS_LEFTY => .left_y,
            sdl.SDL_CONTROLLER_AXIS_RIGHTX => .right_x,
            sdl.SDL_CONTROLLER_AXIS_RIGHTY => .right_y,
            sdl.SDL_CONTROLLER_AXIS_TRIGGERLEFT => .left_trigger,
            sdl.SDL_CONTROLLER_AXIS_TRIGGERRIGHT => .right_trigger,
            else => null,
        };
    }

    /// The pixel size and the DPI scale of the window now.
    fn queryWindowInfo(window: *sdl.SDL_Window) platform.WindowInfo {
        var drawable_w: c_int = 0;
        var drawable_h: c_int = 0;
        var window_w: c_int = 0;
        var window_h: c_int = 0;
        sdl.SDL_GL_GetDrawableSize(window, &drawable_w, &drawable_h);
        sdl.SDL_GetWindowSize(window, &window_w, &window_h);
        const w: u32 = @intCast(@max(drawable_w, 0));
        const h: u32 = @intCast(@max(drawable_h, 0));
        return .{ .width = w, .height = h, .dpi_scale = platform.dpiScale(w, @intCast(@max(window_w, 0))) };
    }

    fn pushResize(bus: *core.Bus, now_ns: u64, info: platform.WindowInfo) !void {
        try bus.push(0, now_ns, .{ .resize = .{
            .width = info.width,
            .height = info.height,
            .dpi_scale = info.dpi_scale,
        } });
    }

    fn getTime(ptr: *anyopaque) u64 {
        const self: *SDL2Backend = @ptrCast(@alignCast(ptr));
        const now: i64 = @intCast(sdl.SDL_GetTicks64());
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

    /// The native handle from SDL_GetWindowWMInfo, the focus, and the place
    /// of the window on the screen (REQ-A11Y-007).
    fn showWindow(ptr: *anyopaque) void {
        const self: *SDL2Backend = @ptrCast(@alignCast(ptr));
        sdl.SDL_ShowWindow(self.window);
    }

    fn getNativeWindow(ptr: *anyopaque) platform.NativeWindow {
        const self: *SDL2Backend = @ptrCast(@alignCast(ptr));
        var out: platform.NativeWindow = .{};
        var info = std.mem.zeroes(sdl.SDL_SysWMinfo);
        sdl.SDL_GetVersion(&info.version);
        if (sdl.SDL_GetWindowWMInfo(self.window, &info) == sdl.SDL_TRUE) {
            switch (builtin.os.tag) {
                .macos => if (info.subsystem == sdl.SDL_SYSWM_COCOA) {
                    out.kind = .cocoa;
                    out.handle = @ptrCast(info.info.cocoa.window);
                },
                .windows => if (info.subsystem == sdl.SDL_SYSWM_WINDOWS) {
                    out.kind = .win32;
                    out.handle = @ptrCast(info.info.win.window);
                },
                else => {
                    if (info.subsystem == sdl.SDL_SYSWM_X11) out.kind = .x11;
                    if (info.subsystem == sdl.SDL_SYSWM_WAYLAND) out.kind = .wayland;
                },
            }
        }
        out.focused = (sdl.SDL_GetWindowFlags(self.window) & sdl.SDL_WINDOW_INPUT_FOCUS) != 0;
        sdl.SDL_GetWindowPosition(self.window, &out.x, &out.y);
        sdl.SDL_GetWindowSize(self.window, &out.w, &out.h);
        var top: c_int = 0;
        var left: c_int = 0;
        var bottom: c_int = 0;
        var right: c_int = 0;
        if (sdl.SDL_GetWindowBordersSize(self.window, &top, &left, &bottom, &right) == 0) {
            out.border_top = top;
            out.border_left = left;
            out.border_bottom = bottom;
            out.border_right = right;
        }
        return out;
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

    // Map an SDL key to our KeyCode enum. The key symbol (the layout) gives
    // the letters, digits and the other keys of sdlKeycodeToKeyCode. The
    // scancode (the physical key) gives the punctuation and navigation keys,
    // as KeyboardEvent.code does on the web (REQ-INPUT-002).
    fn sdlKeyToKeyCode(sym: c_int, scancode: c_uint) core.KeyCode {
        const by_symbol = sdlKeycodeToKeyCode(sym);
        if (by_symbol != .Unknown) return by_symbol;
        return sdlScancodeToKeyCode(scancode);
    }

    // The punctuation and navigation keys, by physical position. Each name is
    // the key at that position on a US keyboard.
    fn sdlScancodeToKeyCode(scancode: c_uint) core.KeyCode {
        return switch (scancode) {
            sdl.SDL_SCANCODE_GRAVE => .Grave,
            sdl.SDL_SCANCODE_MINUS => .Minus,
            sdl.SDL_SCANCODE_EQUALS => .Equal,
            sdl.SDL_SCANCODE_LEFTBRACKET => .LeftBracket,
            sdl.SDL_SCANCODE_RIGHTBRACKET => .RightBracket,
            sdl.SDL_SCANCODE_BACKSLASH => .Backslash,
            sdl.SDL_SCANCODE_SEMICOLON => .Semicolon,
            sdl.SDL_SCANCODE_APOSTROPHE => .Quote,
            sdl.SDL_SCANCODE_COMMA => .Comma,
            sdl.SDL_SCANCODE_PERIOD => .Period,
            sdl.SDL_SCANCODE_SLASH => .Slash,
            sdl.SDL_SCANCODE_DELETE => .Delete,
            sdl.SDL_SCANCODE_HOME => .Home,
            sdl.SDL_SCANCODE_END => .End,
            sdl.SDL_SCANCODE_PAGEUP => .PageUp,
            sdl.SDL_SCANCODE_PAGEDOWN => .PageDown,
            sdl.SDL_SCANCODE_INSERT => .Insert,
            else => .Unknown,
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

    fn setMouseCapture(_: *anyopaque, capture: bool) void {
        _ = sdl.SDL_SetRelativeMouseMode(if (capture) 1 else 0);
    }

    fn setTextInput(_: *anyopaque, active: bool) void {
        if (active) sdl.SDL_StartTextInput() else sdl.SDL_StopTextInput();
    }

    // Full screen is a borderless window at the desktop resolution. The
    // display mode does not change, so the switch is fast and the other
    // windows stay. The size change arrives as SIZE_CHANGED.
    fn setWindowMode(ptr: *anyopaque, mode: platform.WindowMode) void {
        const self: *SDL2Backend = @ptrCast(@alignCast(ptr));
        const flags: u32 = switch (mode) {
            .windowed => 0,
            .fullscreen => sdl.SDL_WINDOW_FULLSCREEN_DESKTOP,
        };
        if (sdl.SDL_SetWindowFullscreen(self.window, flags) != 0) {
            std.log.warn("SDL_SetWindowFullscreen failed: {s}", .{sdl.SDL_GetError()});
        }
    }

    fn getWindowMode(ptr: *anyopaque) platform.WindowMode {
        const self: *SDL2Backend = @ptrCast(@alignCast(ptr));
        const flags = sdl.SDL_GetWindowFlags(self.window);
        return if ((flags & sdl.SDL_WINDOW_FULLSCREEN) != 0) .fullscreen else .windowed;
    }

    // setMouseCapture does not change: it sets the relative mode only.
    fn setCursorMode(_: *anyopaque, mode: platform.CursorMode) void {
        const relative: bool = mode == .locked;
        if (sdl.SDL_SetRelativeMouseMode(if (relative) 1 else 0) != 0) {
            std.log.warn("SDL_SetRelativeMouseMode failed: {s}", .{sdl.SDL_GetError()});
        }
        // In the relative mode SDL hides the cursor itself.
        _ = sdl.SDL_ShowCursor(if (mode == .hidden) sdl.SDL_DISABLE else sdl.SDL_ENABLE);
    }

    fn isCursorLocked(_: *anyopaque) bool {
        return sdl.SDL_GetRelativeMouseMode() != 0;
    }

    // The SDL clipboard does not wait, but the result goes out as an event
    // on the next poll. So a game gets the same events as on the web.
    fn setClipboardText(ptr: *anyopaque, text: []const u8) void {
        const self: *SDL2Backend = @ptrCast(@alignCast(ptr));
        const status: core.ClipboardStatus = blk: {
            self.clipboard.store(self.allocator, text) catch break :blk .failed;
            const z = self.allocator.dupeSentinel(u8, self.clipboard.slice(), 0) catch break :blk .failed;
            defer self.allocator.free(z);
            if (sdl.SDL_SetClipboardText(z.ptr) != 0) {
                std.log.warn("SDL_SetClipboardText failed: {s}", .{sdl.SDL_GetError()});
                break :blk .failed;
            }
            break :blk .ok;
        };
        self.clipboard.queue(clipboard.writeResult(status));
    }

    fn requestClipboardText(ptr: *anyopaque) void {
        const self: *SDL2Backend = @ptrCast(@alignCast(ptr));
        const status = self.readSdlClipboard();
        self.clipboard.queue(clipboard.readResult(status, self.clipboard.slice().len));
    }

    fn clipboardText(ptr: *anyopaque) []const u8 {
        const self: *SDL2Backend = @ptrCast(@alignCast(ptr));
        _ = self.readSdlClipboard();
        return self.clipboard.slice();
    }

    /// Copy the SDL clipboard text into the clipboard state.
    fn readSdlClipboard(self: *SDL2Backend) core.ClipboardStatus {
        if (sdl.SDL_HasClipboardText() == 0) {
            self.clipboard.text.clearRetainingCapacity();
            return .no_text;
        }
        const raw = sdl.SDL_GetClipboardText() orelse return .failed;
        defer sdl.SDL_free(@ptrCast(raw));
        const text = std.mem.span(@as([*:0]const u8, @ptrCast(raw)));
        self.clipboard.store(self.allocator, text) catch return .failed;
        return if (text.len == 0) .no_text else .ok;
    }

    /// The bytes of a NUL-terminated SDL text field, without the NUL.
    fn cText(text: anytype) []const u8 {
        const bytes: [*]const u8 = @ptrCast(text);
        const n = std.mem.indexOfScalar(u8, bytes[0..text.len], 0) orelse text.len;
        return bytes[0..n];
    }
};

/// Point the local key-value storage (storage.zig) at the per-user data
/// directory of the game. SDL makes the directory when it does not exist.
/// `org` and `app` name the directory, for example "seanmizen" and "same-again".
/// An error here leaves storage unavailable. The game continues.
pub fn initStorage(io: std.Io, org: [*:0]const u8, app: [*:0]const u8) !void {
    const pref = sdl.SDL_GetPrefPath(org, app) orelse {
        std.log.warn("SDL_GetPrefPath failed: {s}", .{sdl.SDL_GetError()});
        return error.StorageUnavailable;
    };
    defer sdl.SDL_free(@ptrCast(pref));
    const dir = try std.Io.Dir.cwd().openDir(io, std.mem.span(pref), .{});
    storage.useDirectory(dir, io);
}
