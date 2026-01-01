// Main app entry point
const std = @import("std");
const core = @import("sw_core");
const platform = @import("sw_platform");
const gpu_mod = @import("sw_gpu");
const Context = @import("context.zig").Context;

pub const Config = struct {
    title: []const u8 = "swindowzig app",
    size: struct { w: u32, h: u32 } = .{ .w = 1280, .h = 720 },
    tick_hz: u32 = 120,
    recording: struct { enabled: bool } = .{ .enabled = false },
};

pub fn run(config: Config, comptime callbacks: type) !void {
    const builtin = @import("builtin");

    // Use WASM-specific allocator for freestanding target
    const is_wasm = switch (builtin.cpu.arch) {
        .wasm32, .wasm64 => true,
        else => false,
    };

    if (comptime is_wasm) {
        return runWasm(config, callbacks, std.heap.wasm_allocator);
    } else {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        return runNative(config, callbacks, gpa.allocator());
    }
}

// WASM initialization (called once)
fn runWasm(config: Config, comptime callbacks: type, allocator: std.mem.Allocator) !void {
    // This is just exports setup for WASM
    _ = config;
    _ = callbacks;
    _ = allocator;
    // The actual frame loop is exported from main.zig
}

// Native loop (for desktop builds)
fn runNative(config: Config, comptime callbacks: type, allocator: std.mem.Allocator) !void {
    _ = config;
    _ = callbacks;
    _ = allocator;
    // TODO: Implement native loop
}
