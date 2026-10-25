//! The web entry for an app that uses `sw.run`. On the web, the browser does
//! not call `main`. `backends/wasm/loader.ts` calls two exports:
//! `swindowzig_init` one time, then `swindowzig_frame` on each animation
//! frame. `exportWeb` makes these two exports from the config and the
//! callbacks of the app:
//!
//! ```zig
//! comptime {
//!     if (builtin.cpu.arch.isWasm()) sw.exportWeb(config, Callbacks);
//! }
//! ```
//!
//! The frame loop is the loop of `run` on native: poll the events, run the
//! ticks, then `frame` and `render`. An app with its own exports (the voxel
//! example) does not call `exportWeb`.
//!
//! The default `std.log` function does not compile for freestanding wasm.
//! Set `webLogFn` as the log function of the web build:
//!
//! ```zig
//! pub const std_options: std.Options = .{
//!     .logFn = if (builtin.cpu.arch.isWasm()) sw.webLogFn else std.log.defaultLog,
//! };
//! ```

const std = @import("std");
const core = @import("sw_core");
const platform = @import("sw_platform");
const gpu_mod = @import("sw_gpu");
const Config = @import("app.zig").Config;
const Context = @import("context.zig").Context;

extern fn jsLog(ptr: [*]const u8, len: u32) void;

/// A `std_options.logFn` for the web build. It gives each message to the
/// browser console through the `env.jsLog` import.
pub fn webLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime fmt: []const u8,
    args: anytype,
) void {
    _ = scope;
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "[" ++ @tagName(level) ++ "] " ++ fmt, args) catch
        "[" ++ @tagName(level) ++ "] <log truncated>";
    jsLog(msg.ptr, @intCast(msg.len));
}

/// Export `swindowzig_init` and `swindowzig_frame` for this app. Call it
/// from a `comptime` block, on the wasm build only.
pub fn exportWeb(comptime config: Config, comptime callbacks: type) void {
    const Loop = WebLoop(config, callbacks);
    @export(&Loop.init, .{ .name = "swindowzig_init" });
    @export(&Loop.frame, .{ .name = "swindowzig_frame" });
}

fn WebLoop(comptime config: Config, comptime callbacks: type) type {
    return struct {
        var timeline: core.FixedStepTimeline = undefined;
        var bus: core.Bus = undefined;
        var input: core.InputSnapshot = undefined;
        var gpu: gpu_mod.GPU = .{};
        var ctx: Context = undefined;
        var backend: platform.Backend = undefined;
        var last_time_ns: u64 = 0;
        var running = false;

        fn init() callconv(.c) void {
            if (running) return;
            const alloc = std.heap.wasm_allocator;
            // The backend owns the event queue of the swindowzig_event_*
            // exports (sw_platform wasm_canvas.zig).
            backend = platform.wasm_canvas.WasmBackend.create(alloc) catch return;
            backend.init() catch return;
            timeline = core.FixedStepTimeline.init(config.tick_hz);
            bus = core.Bus.init(alloc);
            input = core.InputSnapshot.init();
            // The loader starts WebGPU before it starts the wasm.
            gpu.init(null, config.size.w, config.size.h) catch {
                std.log.warn("web GPU init failed: the app runs with no rendering", .{});
            };
            ctx = .{
                .alloc = alloc,
                .timeline = &timeline,
                .event_bus = &bus,
                .input_snapshot = &input,
                .backend = backend,
                .gpu_device = &gpu,
            };
            if (@hasDecl(callbacks, "init")) {
                callbacks.init(&ctx) catch |err| {
                    std.log.err("init failed: {s}", .{@errorName(err)});
                    return;
                };
            }
            last_time_ns = backend.getTime();
            running = true;
        }

        fn frame(timestamp_ms: f64) callconv(.c) void {
            _ = timestamp_ms;
            if (!running) return;
            backend.pollEvents(&bus) catch return;

            // The canvas size arrives as a resize event after init.
            const info = backend.getWindowInfo();
            gpu.setSurfaceSize(info.width, info.height);

            const now = backend.getTime();
            const ticks = timeline.advance(now - last_time_ns);
            last_time_ns = now;

            // A frame with 0 ticks keeps its pending events for the next
            // tick, so a key-up event is not lost.
            if (ticks > 0) bus.assignPendingToTick(timeline.currentTick() + 1);
            if (@hasDecl(callbacks, "tick")) {
                while (timeline.step()) {
                    if (@hasDecl(callbacks, "preTick")) {
                        callbacks.preTick(&ctx) catch |err| logError("preTick", err);
                    }
                    input.updateFromEvents(bus.eventsForTick(timeline.currentTick()));
                    callbacks.tick(&ctx) catch |err| logError("tick", err);
                }
            }
            if (@hasDecl(callbacks, "frame")) {
                callbacks.frame(&ctx) catch |err| logError("frame", err);
            }
            if (@hasDecl(callbacks, "render")) {
                callbacks.render(&ctx) catch |err| logError("render", err);
            }
            if (ticks > 0 or !@hasDecl(callbacks, "tick")) bus.clear();
        }

        fn logError(comptime phase: []const u8, err: anyerror) void {
            std.log.err(phase ++ " failed: {s}", .{@errorName(err)});
        }
    };
}
