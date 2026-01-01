// User-facing context
const std = @import("std");
const core = @import("sw_core");
const platform = @import("sw_platform");
const gpu_mod = @import("sw_gpu");

pub const Context = struct {
    alloc: std.mem.Allocator,
    timeline: *core.FixedStepTimeline,
    event_bus: *core.Bus,
    input_snapshot: *core.InputSnapshot,
    backend: platform.backend.Backend,
    gpu_device: *gpu_mod.GPU,

    pub fn tickId(self: *const Context) u64 {
        return self.timeline.currentTick();
    }

    pub fn dtNs(self: *const Context) u64 {
        return self.timeline.tickDuration();
    }

    pub fn timeNs(self: *const Context) u64 {
        return self.backend.getTime();
    }

    pub fn bus(self: *Context) *core.Bus {
        return self.event_bus;
    }

    pub fn input(self: *const Context) *const core.InputSnapshot {
        return self.input_snapshot;
    }

    pub fn window(self: *const Context) platform.platform.WindowInfo {
        return self.backend.getWindowInfo();
    }

    pub fn gpu(self: *Context) *gpu_mod.GPU {
        return self.gpu_device;
    }

    pub fn allocator(self: *const Context) std.mem.Allocator {
        return self.alloc;
    }
};
