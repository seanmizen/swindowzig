// Woke Asteroids - A classic game reimagined
const std = @import("std");
const sw = @import("sw_app");
const builtin = @import("builtin");
const game_mod = @import("game.zig");
const renderer_mod = @import("renderer.zig");

// Custom log function for WASM (no stderr available)
pub const std_options: std.Options = .{
    .logFn = if (builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64) wasmLogFn else std.log.defaultLog,
};

fn wasmLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = level;
    _ = scope;
    _ = format;
    _ = args;
    // No-op for WASM - could call JS console.log via extern function
}

// Global state for WASM
var game_state: game_mod.Game = undefined;
var renderer: renderer_mod.Renderer = undefined;
var timeline: sw.core_types.FixedStepTimeline = undefined;
var bus: sw.core_types.Bus = undefined;
var input_snapshot: sw.core_types.InputSnapshot = undefined;
var backend: sw.platform_types.Backend = undefined;
var gpu_device: sw.gpu_types.GPU = undefined;
var audio: sw.audio_types.Audio = undefined;
var ctx: sw.Context = undefined;
var initialized: bool = false;
var last_time: u64 = 0;

// Performance tracking
var frame_count: u32 = 0;
var tick_count_this_second: u32 = 0;
var fps: u32 = 0;
var tps: u32 = 0;
var second_timer: u64 = 0;

pub fn main() !void {
    try sw.run(.{
        .title = "Woke Asteroids",
        .size = .{ .w = 1280, .h = 720 },
        .tick_hz = 120,
    }, struct {});
}

// WASM exports
export fn swindowzig_init() void {
    if (initialized) return;

    const allocator = std.heap.wasm_allocator;

    // Initialize timeline
    timeline = sw.core_types.FixedStepTimeline.init(120);

    // Initialize bus
    bus = sw.core_types.Bus.init(allocator);

    // Initialize input
    input_snapshot = sw.core_types.InputSnapshot.init();

    // Initialize backend
    backend = sw.platform_types.WasmBackend.create(allocator) catch return;
    backend.init() catch return;

    // Initialize GPU
    gpu_device = sw.gpu_types.GPU{ .state = .ready };

    // Initialize Audio
    audio = sw.audio_types.Audio.init();

    // Create context
    ctx = sw.Context{
        .alloc = allocator,
        .timeline = &timeline,
        .event_bus = &bus,
        .input_snapshot = &input_snapshot,
        .backend = backend,
        .gpu_device = &gpu_device,
    };

    // Initialize game
    const window = ctx.window();
    game_state = game_mod.Game.init(
        @floatFromInt(window.width),
        @floatFromInt(window.height),
    );
    renderer = renderer_mod.Renderer.init(
        @floatFromInt(window.width),
        @floatFromInt(window.height),
    );

    initialized = true;
}

export fn swindowzig_frame(timestamp_ms: f64) void {
    if (!initialized) return;

    // Convert timestamp to nanoseconds
    const now: u64 = @intFromFloat(timestamp_ms * 1_000_000.0);
    const frame_dt = if (last_time > 0) now - last_time else 16_666_666;
    last_time = now;

    // Poll events
    backend.pollEvents(&bus) catch return;

    // Advance timeline
    const ticks_to_run = timeline.advance(frame_dt);

    // Sync game dimensions with window size
    const window = ctx.window();
    game_state.setDimensions(@floatFromInt(window.width), @floatFromInt(window.height));
    renderer.setDimensions(@floatFromInt(window.width), @floatFromInt(window.height));

    // Always process input events, even if no ticks run this frame
    // This prevents keyup events from being lost when ticks_to_run == 0
    const all_events = bus.eventsForTick(0);
    input_snapshot.updateFromEvents(all_events);

    // Run ticks
    var i: u32 = 0;
    while (i < ticks_to_run) : (i += 1) {
        // Get input from snapshot (already updated above)
        const input = game_mod.Input{
            .thrust = input_snapshot.keyDown(.W) or input_snapshot.keyDown(.Up),
            .turn_left = input_snapshot.keyDown(.A) or input_snapshot.keyDown(.Left),
            .turn_right = input_snapshot.keyDown(.D) or input_snapshot.keyDown(.Right),
            .fire = input_snapshot.keyDown(.Space),
        };

        // Log fire state for ticks 1000-2000
        const tick = game_state.tick_count;
        const cooldown_before = game_state.fire_cooldown;
        const will_fire = input.fire and cooldown_before <= 0 and game_state.ship.alive;

        if (tick >= 1000 and tick <= 2000) {
            jsLogFireState(tick, input.fire, will_fire, cooldown_before);
        }

        // Update game logic
        const dt = @as(f32, @floatFromInt(ctx.dtNs())) / 1_000_000_000.0;
        game_state.update(input, dt);

        // Play sounds based on game events
        if (game_state.events.fired) {
            audio.laser();
        }
        if (game_state.events.asteroid_hit) {
            audio.explosion();
        }
        if (game_state.events.ship_died) {
            audio.explosion();
        }
        if (game_state.events.thrust) {
            audio.thrust();
        }
    }

    // Clear processed events
    bus.clear();

    // Track performance metrics
    frame_count += 1;
    tick_count_this_second += ticks_to_run;
    second_timer += frame_dt;

    // Update FPS/TPS every second
    const one_second_ns: u64 = 1_000_000_000;
    if (second_timer >= one_second_ns) {
        fps = frame_count;
        tps = tick_count_this_second;
        frame_count = 0;
        tick_count_this_second = 0;
        second_timer -= one_second_ns;
    }

    // Render
    if (ctx.gpu().isReady()) {
        renderer.draw(&ctx, &game_state) catch return;
    }

    // Update debug info
    updateDebugInfo();
}

fn updateDebugInfo() void {
    // Count active asteroids
    var asteroid_count: u32 = 0;
    for (game_state.asteroids) |asteroid| {
        if (asteroid.active) asteroid_count += 1;
    }

    // Count active bullets
    var bullet_count: u32 = 0;
    for (game_state.bullets) |bullet| {
        if (bullet.active) bullet_count += 1;
    }

    // Export to JS global
    jsSetDebugInfo(
        game_state.tick_count,
        game_state.ship.alive,
        asteroid_count,
        game_state.score,
        fps,
        tps,
        bullet_count,
    );
}

extern fn jsSetDebugInfo(tick: u64, ship_alive: bool, asteroid_count: u32, score: u32, fps_val: u32, tps_val: u32, bullet_count: u32) void;
extern fn jsLogFireState(tick: u64, space_down: bool, fired: bool, cooldown_remaining: f32) void;
