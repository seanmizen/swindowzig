// App module root
const core = @import("sw_core");
const platform = @import("sw_platform");
const gpu_mod = @import("sw_gpu");

pub const app = @import("app.zig");
pub const context = @import("context.zig");

pub const run = app.run;
pub const Config = app.Config;
pub const Context = context.Context;

// Re-export dependencies for user code
pub const core_types = struct {
    pub const FixedStepTimeline = core.FixedStepTimeline;
    pub const Bus = core.Bus;
    pub const InputSnapshot = core.InputSnapshot;
};

pub const platform_types = struct {
    pub const WasmBackend = platform.wasm_canvas.WasmBackend;
    pub const Backend = platform.backend.Backend;
};

pub const gpu_types = struct {
    pub const GPU = gpu_mod.GPU;
};
