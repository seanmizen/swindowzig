/// User-facing context provided to all app callbacks.
/// Contains everything you need to build a game or app.
const std = @import("std");
const core = @import("sw_core");
const platform = @import("sw_platform");
const gpu_mod = @import("sw_gpu");

/// The main interface to swindowzig. Passed to init(), tick(), render(), and shutdown().
/// Provides access to timing, input, events, window info, and GPU.
pub const Context = struct {
    alloc: std.mem.Allocator,
    timeline: *core.FixedStepTimeline,
    event_bus: *core.Bus,
    input_snapshot: *core.InputSnapshot,
    backend: platform.backend.Backend,
    gpu_device: *gpu_mod.GPU,
    /// Io for file and clock access, from Config.io. Null in the web build.
    io: ?std.Io = null,
    /// Command-line arguments, from Config.args. Empty in the web build.
    args: []const [:0]const u8 = &.{},

    /// Current tick number (increments at fixed rate, e.g. 120 Hz).
    pub fn tickId(self: *const Context) u64 {
        return self.timeline.currentTick();
    }

    /// Duration of one tick in nanoseconds (e.g. 8,333,333 ns for 120 Hz).
    pub fn dtNs(self: *const Context) u64 {
        return self.timeline.tickDuration();
    }

    /// Monotonic time since app start in nanoseconds.
    pub fn timeNs(self: *const Context) u64 {
        return self.backend.getTime();
    }

    /// Event bus for raw input events. Most apps should use input() instead.
    pub fn bus(self: *Context) *core.Bus {
        return self.event_bus;
    }

    /// Input snapshot for current tick (keyboard, mouse, modifiers, etc).
    pub fn input(self: *const Context) *const core.InputSnapshot {
        return self.input_snapshot;
    }

    /// Window dimensions and DPI scale.
    pub fn window(self: *const Context) platform.platform.WindowInfo {
        return self.backend.getWindowInfo();
    }

    /// GPU interface for rendering (clearScreen, drawLine, drawCircle, etc).
    pub fn gpu(self: *Context) *gpu_mod.GPU {
        return self.gpu_device;
    }

    /// Allocator for dynamic memory (WASM uses wasm_allocator, native uses GPA).
    pub fn allocator(self: *const Context) std.mem.Allocator {
        return self.alloc;
    }

    /// Enable or disable mouse capture (for FPS-style controls).
    /// When enabled, hides cursor and provides relative mouse movement.
    pub fn setMouseCapture(self: *Context, capture: bool) void {
        self.backend.setMouseCapture(capture);
    }

    /// Go to full screen, or back to a window. The new size arrives as a
    /// `resize` event, and `window()` gives it. Native: a borderless window
    /// at the desktop resolution. Web: the browser full screen. The browser
    /// asks for a user gesture: call it on a key press or a click. A refusal
    /// goes to the console, and the game continues.
    pub fn setWindowMode(self: *Context, mode: platform.WindowMode) void {
        self.backend.setWindowMode(mode);
    }

    /// The window mode now. On the web, Escape ends full screen, so read
    /// this value. Do not keep your own copy.
    pub fn windowMode(self: *const Context) platform.WindowMode {
        return self.backend.getWindowMode();
    }

    /// Show the cursor (`normal`), hide it over the window (`hidden`), or
    /// lock it for relative movement (`locked`). On the web, `locked` is
    /// the pointer lock. The browser can refuse it or end it (Escape), and
    /// the game continues (REQ-PLATFORM-001). Read `isCursorLocked` for the
    /// real state. `setMouseCapture` does not change.
    pub fn setCursorMode(self: *Context, mode: platform.CursorMode) void {
        self.backend.setCursorMode(mode);
    }

    /// True while the cursor is locked.
    pub fn isCursorLocked(self: *const Context) bool {
        return self.backend.isCursorLocked();
    }

    /// Write `text` to the system clipboard. The call does not wait. A
    /// `clipboard` event of kind `write` gives the result
    /// (`input().clipboard`). On the web, the browser can refuse the write
    /// (no user gesture, or no focus): then the status is `denied`, and the
    /// console tells why. `clipboardText()` gives the text after the call,
    /// also when the browser refused it (REQ-PLATFORM-002).
    pub fn setClipboardText(self: *Context, text: []const u8) void {
        self.backend.setClipboardText(text);
    }

    /// Start a read of the system clipboard. The call does not wait. A
    /// `clipboard` event of kind `read` gives the result, and
    /// `clipboardText()` gives the text. On the web, the browser can ask
    /// the user for a permission, and can refuse (status `denied`). For the
    /// paste of a text field, use the `paste` event of the web, which needs
    /// no permission.
    pub fn requestClipboardText(self: *Context) void {
        self.backend.requestClipboardText();
    }

    /// The last clipboard text that the platform knows: from a paste, a
    /// read or a write. Native reads the system clipboard on each call. The
    /// slice stays valid until the next clipboard call or event.
    pub fn clipboardText(self: *Context) []const u8 {
        return self.backend.clipboardText();
    }

    /// Web: while this is true (the default), a paste into a text input
    /// also arrives as `text_input`. Set it to false when the game reads
    /// the paste from the `clipboard` event, for example with
    /// `sw_ui.Clipboard.platform`. Native does nothing.
    pub fn setPasteAsText(self: *Context, on: bool) void {
        self.backend.setPasteAsText(on);
    }

    /// Start text input. The platform input method turns on: the OS IME on
    /// native, a focused hidden `<input>` on the web. The engine then sends
    /// `text_input` (committed text) and `text_composition` (text in
    /// composition) events, and `input().text` and `input().composition` fill.
    /// Call it when a text box gains focus.
    ///
    /// On the web, printable keys do not reach the game as `key` events while
    /// text input is on. Keys such as Backspace, Enter and the arrows still do.
    pub fn startTextInput(self: *Context) void {
        self.event_bus.text_input_active = true;
        self.backend.setTextInput(true);
    }

    /// Stop text input. The engine sends no text events until the next
    /// `startTextInput`. A composition in progress is dropped.
    pub fn stopTextInput(self: *Context) void {
        self.event_bus.text_input_active = false;
        self.backend.setTextInput(false);
        self.input_snapshot.composition.len = 0;
    }

    /// Is text input on?
    pub fn isTextInputActive(self: *const Context) bool {
        return self.event_bus.text_input_active;
    }

    /// Block (or unblock) physical keyboard/mouse input from reaching the event bus.
    /// When blocked, only TAS/replayer events and window lifecycle events are processed.
    /// Useful for deterministic TAS runs where real input must not interfere.
    pub fn setInputBlocked(self: *Context, blocked: bool) void {
        self.event_bus.block_physical_input = blocked;
    }

    /// Request the app to shut down cleanly after the current tick completes.
    /// In headless/unlimited mode this terminates the simulation loop.
    /// In windowed mode this is equivalent to the user closing the window.
    pub fn requestShutdown(self: *Context) void {
        // Push with tick_id=0 so the main loop's shutdown scan picks it up next iteration.
        self.event_bus.push(0, 0, .{ .lifecycle = .shutdown }) catch {};
    }
};
