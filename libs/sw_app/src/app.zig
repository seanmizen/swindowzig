/// Main app entry point for swindowzig applications.
const std = @import("std");
const core = @import("sw_core");
const platform = @import("sw_platform");
const gpu_mod = @import("sw_gpu");
const Context = @import("context.zig").Context;

/// Controls how the main loop advances ticks relative to wall clock time.
pub const TickTiming = enum {
    /// Standard fixed-timestep: ticks fire at tick_hz rate based on wall clock.
    realtime,
    /// Run as fast as possible: one tick per loop iteration, no sleeping.
    /// Useful for headless simulation and TAS analysis.
    unlimited,
};

/// Configuration for your app (window title, size, tick rate, etc).
pub const Config = struct {
    /// Window title (web: page title, native: window title).
    title: []const u8 = "swindowzig app",
    /// Initial window/canvas size in pixels.
    size: struct { w: u32, h: u32 } = .{ .w = 1280, .h = 720 },
    /// Fixed timestep tick rate in Hz (120 = 8.33ms per tick).
    tick_hz: u32 = 120,
    /// When true: no window, no GPU, render callbacks are skipped.
    /// Useful for deterministic TAS simulation and server-side game logic.
    headless: bool = false,
    /// Tick timing mode. Default .realtime follows wall clock.
    /// Use .unlimited to run as fast as possible (pairs naturally with headless).
    tick_timing: TickTiming = .realtime,
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
    // 1. Create backend (SDL2 for windowed, NullBackend for headless)
    var null_impl: platform.null_backend.NullBackend = .{};
    var backend: platform.Backend = if (config.headless) blk: {
        std.log.info("Headless mode: no window, no GPU, tick_timing={s}", .{@tagName(config.tick_timing)});
        break :blk null_impl.backend();
    } else blk: {
        const sdl_backend = try platform.native_sdl.SDL2Backend.create(
            allocator,
            config.title,
            config.size.w,
            config.size.h,
        );
        break :blk sdl_backend;
    };
    defer if (!config.headless) backend.deinit();

    try backend.init();

    // 2. Initialize GPU — skipped in headless mode (isReady() stays false, render early-returns)
    var gpu_device: gpu_mod.GPU = .{};
    if (!config.headless) {
        const window = backend.getWindow();
        gpu_device.init(window, config.size.w, config.size.h) catch |err| {
            std.log.warn("GPU initialization failed: {}, running without rendering", .{err});
        };
    }

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
        // Poll events (platform pushes with tick_id=0 = "pending")
        try backend.pollEvents(&event_bus);

        // Check for shutdown by scanning all pending events directly
        for (event_bus.events.items) |ev| {
            if (std.meta.activeTag(ev.payload) == .lifecycle and ev.payload.lifecycle == .shutdown) {
                running = false;
                break;
            }
        }

        if (!running) break;

        // Update timeline — advance() computes pending ticks without advancing tick_id.
        // .realtime: dt from wall clock (standard fixed-timestep).
        // .unlimited: always inject exactly one tick's worth of time → one tick per loop.
        const dt_ns: u64 = switch (config.tick_timing) {
            .realtime => blk: {
                const now = backend.getTime();
                const dt = now - last_time;
                last_time = now;
                break :blk dt;
            },
            .unlimited => blk: {
                null_impl.advanceTime(timeline.tickDuration());
                break :blk timeline.tickDuration();
            },
        };

        _ = timeline.advance(dt_ns);

        // Assign pending (tick_id=0) platform events to the first tick of this frame.
        // This ensures SDL input only fires once (in tick N), not in every catch-up tick.
        event_bus.assignPendingToTick(timeline.currentTick() + 1);

        // Run tick callbacks — step() advances tick_id by 1 each iteration.
        // ctx.tickId() is always correct for the current iteration.
        if (@hasDecl(callbacks, "tick")) {
            while (timeline.step()) {
                if (@hasDecl(callbacks, "preTick")) {
                    try callbacks.preTick(&ctx);
                }
                const events_for_tick = event_bus.eventsForTick(timeline.currentTick());
                input_snapshot.updateFromEvents(events_for_tick);
                try callbacks.tick(&ctx);
            }
        }

        // Render — skipped in headless mode
        if (!config.headless) {
            if (@hasDecl(callbacks, "render")) {
                try callbacks.render(&ctx);
            }
        }

        // Check if any tick/render callback requested shutdown (e.g. ctx.requestShutdown())
        for (event_bus.events.items) |ev| {
            if (std.meta.activeTag(ev.payload) == .lifecycle and ev.payload.lifecycle == .shutdown) {
                running = false;
                break;
            }
        }

        // Clear event bus for next frame
        event_bus.clear();
    }

    // 10. Call shutdown callback
    if (@hasDecl(callbacks, "shutdown")) {
        try callbacks.shutdown(&ctx);
    }
}
