// Null (headless) backend — no window, no GPU, all calls are no-ops.
// getTime() returns a synthetic monotonic clock driven by tickNs() calls.
const std = @import("std");
const core = @import("sw_core");
const platform = @import("platform.zig");
const backend_mod = @import("backend.zig");

pub const NullBackend = struct {
    elapsed_ns: u64 = 0,

    const vtable = backend_mod.Backend.VTable{
        .init = init,
        .deinit = deinit,
        .pollEvents = pollEvents,
        .getTime = getTime,
        .getWindowInfo = getWindowInfo,
        .getWindow = getWindow,
        .setMouseCapture = setMouseCapture,
    };

    pub fn backend(self: *NullBackend) backend_mod.Backend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Advance the synthetic clock by ns nanoseconds. Call once per tick in unlimited mode.
    pub fn advanceTime(self: *NullBackend, ns: u64) void {
        self.elapsed_ns += ns;
    }

    fn init(_: *anyopaque) anyerror!void {}
    fn deinit(_: *anyopaque) void {}
    fn pollEvents(_: *anyopaque, _: *core.Bus) anyerror!void {}

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
};
