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
};
