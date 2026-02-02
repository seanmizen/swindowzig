/// Main app entry point for swindowzig applications.
const std = @import("std");
const core = @import("sw_core");
const platform = @import("sw_platform");
const gpu_mod = @import("sw_gpu");
const Context = @import("context.zig").Context;

/// Configuration for your app (window title, size, tick rate, etc).
pub const Config = struct {
    /// Window title (web: page title, native: window title).
    title: []const u8 = "swindowzig app",
    /// Initial window/canvas size in pixels.
    size: struct { w: u32, h: u32 } = .{ .w = 1280, .h = 720 },
    /// Fixed timestep tick rate in Hz (120 = 8.33ms per tick).
    tick_hz: u32 = 120,
    /// Recording options (not implemented in v0.1).
    recording: struct { enabled: bool } = .{ .enabled = false },
    /// Web-specific input options.
    web_input: struct {
        /// Prevent browser context menu on right-click (default: true for games).
        disable_context_menu: bool = true,
        /// Hide mouse cursor over canvas (default: false, set true to draw custom cursor).
        hide_cursor: bool = false,
    } = .{},
};

/// Main entry point. Call this from your main() function.
/// Provide a Config and a struct with optional init/tick/render/shutdown callbacks.
/// Example: sw.run(.{ .title = "My Game" }, struct { pub fn tick(ctx: *sw.Context) !void { ... } });
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
    // 1. Create SDL2 backend
    const SDL2Backend = platform.native_sdl.SDL2Backend;
    var backend = try SDL2Backend.create(
        allocator,
        config.title,
        config.size.w,
        config.size.h,
    );
    defer backend.deinit();

    try backend.init();

    // 2. Initialize GPU (will fail gracefully on native until wgpu-native is linked)
    var gpu_device: gpu_mod.GPU = .{};
    const window = backend.getWindow();
    gpu_device.init(window, config.size.w, config.size.h) catch |err| {
        std.log.warn("GPU initialization failed: {}, running without rendering", .{err});
    };

    // 4. Initialize timeline
    var timeline = core.FixedStepTimeline.init(config.tick_hz);

    // 5. Initialize event bus
    var event_bus = core.Bus.init(allocator);
    defer event_bus.deinit();

    // 6. Initialize input snapshot
    var input_snapshot = core.InputSnapshot.init();

    // 7. Create context
    var ctx = Context{
        .alloc = allocator,
        .timeline = &timeline,
        .event_bus = &event_bus,
        .input_snapshot = &input_snapshot,
        .backend = backend,
        .gpu_device = &gpu_device,
    };

    // 8. Call user init callback
    if (@hasDecl(callbacks, "init")) {
        try callbacks.init(&ctx);
    }

    // 9. Main loop
    var running = true;
    var last_time = backend.getTime();

    while (running) {
        // Poll events
        try backend.pollEvents(&event_bus);

        // Check for shutdown event
        const tick_events = event_bus.eventsForTick(timeline.currentTick());
        for (tick_events) |event| {
            if (event.payload == .lifecycle and event.payload.lifecycle == .shutdown) {
                running = false;
                break;
            }
        }

        if (!running) break;

        // Update timeline
        const now = backend.getTime();
        const dt_ns = now - last_time;
        last_time = now;

        const ticks = timeline.advance(dt_ns);

        // Update input snapshot from events for current tick
        const events_for_tick = event_bus.eventsForTick(timeline.currentTick());
        input_snapshot.updateFromEvents(events_for_tick);

        // Run tick callbacks
        if (@hasDecl(callbacks, "tick")) {
            var i: u64 = 0;
            while (i < ticks) : (i += 1) {
                try callbacks.tick(&ctx);
            }
        }

        // Render
        if (@hasDecl(callbacks, "render")) {
            try callbacks.render(&ctx);
        }

        // Clear event bus for next frame
        event_bus.clear();
    }

    // 10. Call shutdown callback
    if (@hasDecl(callbacks, "shutdown")) {
        try callbacks.shutdown(&ctx);
    }
}
