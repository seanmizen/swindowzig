// GPU interface - WebGPU API subset
const std = @import("std");

pub const GPUState = enum {
    pending,
    ready,
    failed,
};

pub const GPU = struct {
    state: GPUState = .pending,

    pub fn isReady(self: *const GPU) bool {
        return self.state == .ready;
    }

    pub fn clearScreen(self: *GPU, r: f32, g: f32, b: f32, a: f32) void {
        if (!self.isReady()) return;
        gpuClearScreen(r, g, b, a);
    }

    pub fn drawLine(self: *GPU, x1: f32, y1: f32, x2: f32, y2: f32, r: f32, g: f32, b: f32, a: f32) void {
        if (!self.isReady()) return;
        gpuDrawLine(x1, y1, x2, y2, r, g, b, a);
    }

    pub fn drawCircle(self: *GPU, x: f32, y: f32, radius: f32, r: f32, g: f32, b: f32, a: f32) void {
        if (!self.isReady()) return;
        gpuDrawCircle(x, y, radius, r, g, b, a);
    }

    pub fn drawFilledRect(self: *GPU, x: f32, y: f32, width: f32, height: f32, r: f32, g: f32, b: f32, a: f32) void {
        if (!self.isReady()) return;
        gpuDrawFilledRect(x, y, width, height, r, g, b, a);
    }

    pub fn drawFilledCircle(self: *GPU, x: f32, y: f32, radius: f32, r: f32, g: f32, b: f32, a: f32) void {
        if (!self.isReady()) return;
        gpuDrawFilledCircle(x, y, radius, r, g, b, a);
    }

    pub fn drawRoundedRect(self: *GPU, x: f32, y: f32, width: f32, height: f32, corner_radius: f32, r: f32, g: f32, b: f32, a: f32) void {
        if (!self.isReady()) return;
        gpuDrawRoundedRect(x, y, width, height, corner_radius, r, g, b, a);
    }

    pub fn beginFrame(self: *GPU) void {
        if (!self.isReady()) return;
        gpuBeginFrame();
    }

    pub fn endFrame(self: *GPU) void {
        if (!self.isReady()) return;
        gpuEndFrame();
    }
};

// WASM imports from gpu namespace
extern "gpu" fn gpuClearScreen(r: f32, g: f32, b: f32, a: f32) void;
extern "gpu" fn gpuDrawLine(x1: f32, y1: f32, x2: f32, y2: f32, r: f32, g: f32, b: f32, a: f32) void;
extern "gpu" fn gpuDrawCircle(x: f32, y: f32, radius: f32, r: f32, g: f32, b: f32, a: f32) void;
extern "gpu" fn gpuDrawFilledRect(x: f32, y: f32, width: f32, height: f32, r: f32, g: f32, b: f32, a: f32) void;
extern "gpu" fn gpuDrawFilledCircle(x: f32, y: f32, radius: f32, r: f32, g: f32, b: f32, a: f32) void;
extern "gpu" fn gpuDrawRoundedRect(x: f32, y: f32, width: f32, height: f32, corner_radius: f32, r: f32, g: f32, b: f32, a: f32) void;
extern "gpu" fn gpuBeginFrame() void;
extern "gpu" fn gpuEndFrame() void;
