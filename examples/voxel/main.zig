const std = @import("std");
const builtin = @import("builtin");
const sw = @import("sw_app");
const gpu_mod = @import("sw_gpu");
const core = @import("sw_core");
const math = @import("sw_math");

// `is_wasm` gates all OS-dependent code paths (CLI parsing, TAS file IO,
// frame dumping, process.exit). The native path is unchanged — see the
// matching `if (comptime !is_wasm)` blocks throughout this file.
const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

// Custom std_options.logFn: on wasm32-freestanding, std.log.* otherwise
// reaches for std.debug.print → std.posix.writev → STDERR_FILENO, AND the
// default formatter pulls in std.time.nanoTimestamp → clock_gettime → more
// missing posix symbols. On wasm we route everything through a jsLog extern.
// On native the default log path still works — this override only kicks in
// when something actually calls std.log.*.
pub const std_options: std.Options = .{
    .logFn = swindowzigLogFn,
};

extern fn jsLog(ptr: [*]const u8, len: u32) void;

/// Wasm-safe replacement for `std.process.exit`. On native it terminates
/// the process as expected. On wasm32-freestanding `std.process.exit`
/// references `system.exit` which doesn't exist, so we trap instead —
/// the browser will surface it as a runtime error, which is fine because
/// reaching this path in the WASM build is already a logic bug. Split into
/// two separate fns so Zig doesn't flag `_ = code` as a pointless discard
/// when the alternate branch also uses `code`.
const fatalExit = if (is_wasm) fatalExitWasm else fatalExitNative;

fn fatalExitWasm(code: u8) noreturn {
    _ = code;
    @trap();
}

fn fatalExitNative(code: u8) noreturn {
    std.process.exit(code);
}

/// Perf-logging timestamp. Native uses std.time.nanoTimestamp, wasm
/// returns 0 — the few call sites are perf-measurement logs that can
/// safely report 0µs in the browser. Split into two functions so Zig's
/// comptime compile-time dispatch fully elides the std.time import on
/// wasm32-freestanding (which has no clock_gettime / clockid_t).
const perfNowNs = if (is_wasm) perfNowNsWasm else perfNowNsNative;

fn perfNowNsWasm() i128 {
    return 0;
}

fn perfNowNsNative() i128 {
    return std.time.nanoTimestamp();
}

fn swindowzigLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime fmt: []const u8,
    args: anytype,
) void {
    _ = scope;
    if (comptime is_wasm) {
        // On wasm: format into a stack buffer, hand bytes to the JS host.
        // No posix, no time, no threading.
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &buf,
            "[" ++ @tagName(level) ++ "] " ++ fmt,
            args,
        ) catch blk: {
            break :blk "[" ++ @tagName(level) ++ "] <log truncated>";
        };
        jsLog(msg.ptr, @intCast(msg.len));
    } else {
        // Native: plain stderr via std.debug.print. std.debug.print is
        // gated for native targets only on this branch so the posix
        // symbols it transitively references never get pulled into the
        // wasm dependency graph.
        std.debug.print("[" ++ @tagName(level) ++ "] " ++ fmt ++ "\n", args);
    }
}

pub fn main() !void {
    if (comptime is_wasm) {
        // WASM never takes the native main() path — sw.run() is driven from
        // the exported swindowzig_init/frame entry points at the bottom of
        // this file. Having `main` return early keeps the freestanding linker
        // happy while still letting the native build keep its behaviour.
        return;
    }

    // Read --headless / --dump-frame / --compare-golden flags before sw.run()
    // so we can set Config accordingly. When --headless is combined with
    // --dump-frame= (or --compare-golden=, which implies a capture), we
    // auto-promote to headless-offscreen GPU mode: no window, but the GPU
    // still initialises and renders to an offscreen texture so captureFrame
    // can read it. See examples/voxel/docs/headless-regressions.md.
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);

    var headless = false;
    var has_dump = false;
    var has_compare = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--headless")) headless = true;
        if (std.mem.startsWith(u8, arg, "--dump-frame=")) has_dump = true;
        if (std.mem.startsWith(u8, arg, "--compare-golden=")) has_compare = true;
    }
    const headless_gpu = headless and (has_dump or has_compare);

    try sw.run(.{
        .title = "Voxel Demo - Minecraft Creative Mode",
        .size = .{ .w = 1280, .h = 720 },
        .tick_hz = 120,
        .headless = headless,
        .headless_gpu = headless_gpu,
        .tick_timing = if (headless) .unlimited else .realtime,
    }, Callbacks);
}

const Callbacks = struct {
    pub fn init(ctx: *sw.Context) !void {
        try voxelInit(ctx);
    }

    /// preTick: inject TAS events BEFORE input snapshot is computed this tick.
    pub fn preTick(ctx: *sw.Context) !void {
        if (state.tas_replayer) |*replayer| {
            if (state.tas_step_mode) {
                // Step mode: events are injected one group at a time, triggered by Right arrow.
                // We reset tas_step_executing each preTick so it's only true for the ONE tick
                // during which TAS events are active.
                state.tas_step_executing = false;
                if (state.tas_step_pending) {
                    state.tas_step_pending = false;
                    // Pop the next TAS event group and remap to the current sim tick_id.
                    // This ensures eventsForTick(currentTick) picks them up correctly.
                    if (replayer.current_index < replayer.events.items.len) {
                        const target = replayer.events.items[replayer.current_index].tick_id;
                        const sim_tick = ctx.tickId();
                        while (replayer.current_index < replayer.events.items.len) {
                            const e = replayer.events.items[replayer.current_index];
                            if (e.tick_id != target) break;
                            try ctx.bus().push(sim_tick, e.t_ns, e.payload);
                            replayer.current_index += 1;
                        }
                        if (replayer.current_index >= replayer.events.items.len) {
                            replayer.state = .finished;
                        }
                        state.tas_current_tas_tick = target;
                        state.tas_step_executing = true;
                        std.log.info("[STEP] TAS tick {} → sim tick {} (idx {}/{})", .{
                            target,
                            sim_tick,
                            replayer.current_index,
                            replayer.events.items.len,
                        });
                    }
                }
            } else {
                try replayer.feedTick(ctx.tickId(), ctx.bus());
            }
        }
    }

    pub fn tick(ctx: *sw.Context) !void {
        try voxelTick(ctx);
    }

    pub fn render(ctx: *sw.Context) !void {
        try voxelRender(ctx);
    }

    pub fn shutdown(ctx: *sw.Context) !void {
        try voxelShutdown(ctx);
    }
};

const chunk_mod = @import("chunk.zig");
const Chunk = chunk_mod.Chunk;
const BlockType = chunk_mod.BlockType;

const mesher_mod = @import("mesher.zig");
const Mesh = mesher_mod.Mesh;
const VoxelVertex = mesher_mod.VoxelVertex;

const world_mod = @import("world.zig");
const world_gen = @import("world_gen.zig");
const async_chunks_mod = if (!is_wasm) @import("async_chunks.zig") else struct {
    pub const Pipeline = struct {
        pub fn init(_: std.mem.Allocator) !*Pipeline { unreachable; }
        pub fn drainSorted(_: *Pipeline, _: *std.ArrayList(Result), _: std.mem.Allocator) !void { unreachable; }
        pub fn submit(_: *Pipeline, _: anytype) !void { unreachable; }
        pub fn deinit(_: *Pipeline) void { unreachable; }
    };
    pub const Result = struct {
        cx: i32 = 0,
        cz: i32 = 0,
        chunk_ptr: ?*chunk_mod.Chunk = null,
        mesh: ?mesher_mod.Mesh = null,
    };
};

const Vec3 = math.Vec3;
const Mat4 = math.Mat4;

const CameraType = @import("camera.zig").Camera(Vec3, Mat4, math);
const WorldRaycastType = @import("raycast.zig").Raycast(Vec3, world_mod.World);
const worldRaycast = WorldRaycastType.raycast;
const camera_clip = @import("camera_clip.zig");
const frustum_mod = @import("frustum.zig");

/// 3PV camera-clip skin: distance to keep between the camera origin and the
/// nearest solid voxel face. Must exceed the near-plane half-diagonal so the
/// frustum corners can't poke into a wall and become see-through. With the
/// default fov=60° / near=0.1 / aspect~16:9 the half-diagonal is ~0.12, so
/// 0.2 leaves a comfortable margin without making 3PV feel too pulled-in.
const CAMERA_CLIP_SKIN: f32 = 0.2;

/// Adapter that gives `camera_clip.safeCameraDistance` an `isSolid()` method
/// over the real `world_mod.World`. The helper is generic so it can also be
/// unit-tested against a fake world (see camera_clip.zig).
const IsSolidWorld = struct {
    world: *const world_mod.World,
    pub fn isSolid(self: IsSolidWorld, x: i32, y: i32, z: i32) bool {
        return self.world.getBlock(x, y, z) != .air;
    }
};

/// Max mesh generations per tick (keeps tick time bounded during chunk loading).
/// Mesh gen runs in tick so render frames stay smooth.
///
/// Rationale for M=1: at `CHUNK_W = 16` (flipped April 2026 on the
/// `voxel/chunk-size-perf` branch — previously 48), meshing a 16×256×16
/// column scans 65 536 blocks and costs ~2 ms in Debug on flatland, ~0.3 ms
/// in ReleaseFast. At 120 Hz sim the frame budget is 8.3 ms — one mesh per
/// tick leaves plenty of headroom for physics and rendering, with a ~10×
/// safety margin against the old 48-wide chunks' worst-case 20 ms mesh
/// spike. See `examples/voxel/docs/chunk-size-investigation.md` for the
/// measured ReleaseFast/Debug numbers and the "why 16 bounds tail spikes"
/// writeup. If you bump `MESH_GENS_PER_TICK`, reconsider seam handling —
/// you still only get one-chunk-per-tick of async outer ring growth, so
/// sprinting past it briefly shows a seam.
const MESH_GENS_PER_TICK: usize = 1;

/// Pregen-phase chunk generation budget per tick. Runs only while
/// state.world_loading is true. Much larger than the gameplay budget because
/// (a) the player isn't rendered yet, so we don't care about frame smoothness,
/// and (b) we want the loading screen to clear fast.
///
/// Rationale: 5×5 = 25 chunks / 8 per tick ≈ 4 ticks of generation.
/// At 120Hz sim that's ~33ms wall-clock — barely enough for the loading
/// animation to draw one full wave. Higher values don't help; lower values
/// make the screen hang.
const PREGEN_CHUNKS_PER_TICK: usize = 8;

/// Pregen-phase mesh generation budget per tick. Meshing is the slow part
/// (~2.3ms/chunk vs ~1ms/chunk for generation). 4 per tick = 4 × 2.3ms ≈ 9ms,
/// comparable to the 8.3ms tick budget. The loading screen doesn't need
/// 120Hz responsiveness so a tick overrun here is fine.
/// Inner 3×3 = 9 meshes / 4 per tick ≈ 3 ticks of meshing.
const PREGEN_MESH_GENS_PER_TICK: usize = 4;

/// Max gen+mesh jobs the async path will enqueue per tick during gameplay.
/// Each enqueue copies up to 8 × ~1.15 MB neighbour snapshots for the job, so
/// the per-tick memcpy cost scales linearly with this. 4 keeps memcpy under
/// ~40 MB/tick = ~3.6 ms worst case on a 10 GB/s memcpy, but in practice the
/// typical chunk has 4–6 neighbours populated so the real cost is lower.
const ASYNC_GEN_ENQUEUE_PER_TICK: usize = 4;

/// Max mesh-only (remesh-for-dirty-neighbour) jobs the async path will
/// enqueue per tick. Same memcpy-cost reasoning as above. Kept separate so
/// fresh-chunk loading doesn't starve out the dirty-remesh work.
const ASYNC_MESH_ONLY_ENQUEUE_PER_TICK: usize = 2;

const GameState = @import("game_state.zig").GameState;
const OverlayRenderer = @import("overlay.zig").OverlayRenderer;
const bitmap_font = @import("bitmap_font.zig");
const drawText = bitmap_font.drawText;
const drawCenteredText = bitmap_font.drawCenteredText;
const drawStepHud = bitmap_font.drawStepHud;
const GLYPH_W = bitmap_font.GLYPH_W;
const GLYPH_H = bitmap_font.GLYPH_H;
const GLYPH_GAP = bitmap_font.GLYPH_GAP;
const player_mod = @import("player.zig");
const Player = player_mod.Player;
const keyboard_hud = @import("keyboard_hud.zig");

/// Camera perspective: cycles first → back → front via Cmd+V / Ctrl+V.
const CameraView = enum {
    first_person,
    third_person_back,
    third_person_front,

    fn next(self: CameraView) CameraView {
        return switch (self) {
            .first_person => .third_person_back,
            .third_person_back => .third_person_front,
            .third_person_front => .first_person,
        };
    }

    fn label(self: CameraView) []const u8 {
        return switch (self) {
            .first_person => "first-person",
            .third_person_back => "third-person (back)",
            .third_person_front => "third-person (front)",
        };
    }
};

// ─── Pause menu state machine ────────────────────────────────────────────────
// Three screens reachable from the gameplay esc-menu:
//   main         → "Resume", "Settings", "Exit"
//   settings     → AA Method, AO Strategy, Render Distance, Back
//   exit_confirm → "No" (default), "Yes"
// Esc is contextual:
//   gameplay → main
//   main     → close, resume gameplay
//   settings → main
//   exit_confirm → main
const MenuScreen = enum { main, settings, exit_confirm };

// Per-screen entry counts. Kept here so nav wraparound has a single source of truth.
// The settings screen count is dynamic (see `settingsEntryCount`) — kept separate
// so fixed screens can still hard-code their totals.
const MENU_MAIN_COUNT: u8 = 3;
const MENU_EXIT_COUNT: u8 = 2;

// Settings entries. The rendered order depends on the current AA method so
// that a method-specific quality row (MSAA samples / FXAA quality) only takes
// up a slot when it is actually meaningful. Fixed tail entries come after:
//     AA Method                                      (always)
//     → MSAA Samples   (only when method == .msaa)
//     → FXAA Quality   (only when method == .fxaa)
//     AO Strategy      (always)
//     Lighting         (always)
//     Frustum          (always)
//     Render Distance  (always)
//     Back             (always)
//
// `settingsEntryAt(i)` returns the logical entry at visual index `i` under
// the current method; `settingsEntryCount()` returns the row total. Both are
// pure functions of the current `state.msaa_config.method`, so navigation,
// rendering, and input dispatch all stay in sync automatically.
const SettingsEntry = enum {
    aa_method,
    msaa_samples,
    fxaa_quality,
    ao_strategy,
    lighting,
    frustum,
    render_dist,
    back,
};

fn settingsEntryCount() u8 {
    // 6 fixed entries (AA Method, AO Strategy, Lighting, Frustum, Render Distance, Back)
    // plus one optional quality entry when MSAA or FXAA is active.
    return switch (state.msaa_config.method) {
        .msaa, .fxaa => 7,
        else => 6,
    };
}

fn settingsEntryAt(i: u8) SettingsEntry {
    // Row 0 is always AA Method. Row 1 is the method-specific quality when
    // either MSAA or FXAA is active, otherwise we skip directly into the
    // fixed tail. From the first fixed tail row onward the layout is the
    // same regardless of method, so we compute a single offset-aware index.
    if (i == 0) return .aa_method;
    const has_quality = switch (state.msaa_config.method) {
        .msaa, .fxaa => true,
        else => false,
    };
    if (has_quality and i == 1) {
        return switch (state.msaa_config.method) {
            .msaa => .msaa_samples,
            .fxaa => .fxaa_quality,
            else => unreachable,
        };
    }
    const tail_start: u8 = if (has_quality) 2 else 1;
    const tail_idx: u8 = i - tail_start;
    return switch (tail_idx) {
        0 => .ao_strategy,
        1 => .lighting,
        2 => .frustum,
        3 => .render_dist,
        4 => .back,
        else => .back,
    };
}

fn menuEntryCount(screen: MenuScreen) u8 {
    return switch (screen) {
        .main => MENU_MAIN_COUNT,
        .settings => settingsEntryCount(),
        .exit_confirm => MENU_EXIT_COUNT,
    };
}

/// Display label for the AA Method picker. Kept short so the centred entry line
/// stays within the bitmap-font safe area at scale 3.
fn aaMethodLabel(method: gpu_mod.AAMethod) []const u8 {
    return switch (method) {
        .none => "None",
        .msaa => "MSAA",
        .fxaa => "FXAA",
        .smaa => "SMAA",
        .ssaa => "SSAA",
        .taa => "TAA",
    };
}

/// Cycle the value of the Settings entry at visual index `idx` by `dir` (+1 / -1).
/// AA Method / MSAA Samples / FXAA Quality all write through to
/// `state.msaa_config` / `state.fxaa_quality`. AO Strategy cycles
/// state.ao_strategy (none/classic/moore). Lighting flips between
/// none and skylight. Render Distance writes to
/// `state.render_distance_stub` with no live effect on the loaded region
/// (wiring up live spiral rebuild is a follow-up task).
fn cycleSettingsValue(idx: u8, dir: i32) void {
    const entry = settingsEntryAt(idx);
    switch (entry) {
        .aa_method => {
            // Cycle: none → msaa → fxaa → none …
            // When landing on MSAA the sample count snaps to 4 (the widest-
            // supported native sample count for bgra8unorm); when landing on
            // FXAA the quality snaps to whatever was most recently chosen
            // (preserved on the state field so re-entering FXAA keeps it).
            const next_method: gpu_mod.AAMethod = switch (state.msaa_config.method) {
                .none => if (dir > 0) .msaa else .fxaa,
                .msaa => if (dir > 0) .fxaa else .none,
                .fxaa => if (dir > 0) .none else .msaa,
                else => .none,
            };
            const next_samples: u32 = if (next_method == .msaa)
                if (state.msaa_config.msaa_samples >= 2) state.msaa_config.msaa_samples else 4
            else
                1;
            state.msaa_config = .{
                .method = next_method,
                .msaa_samples = next_samples,
                .fxaa_quality = state.msaa_config.fxaa_quality,
            };
            std.log.info("Settings: AA Method -> {s} (applies on next pipeline rebuild)", .{@tagName(next_method)});
        },
        .msaa_samples => {
            // Cycle MSAA sample count across 2 / 4 / 8. The GPU wrapper
            // caps the requested count for the current surface format at
            // pipeline-create time — see configureMSAA in gpu.zig.
            const cur = state.msaa_config.msaa_samples;
            const next: u32 = if (dir > 0) switch (cur) {
                2 => 4,
                4 => 8,
                8 => 2,
                else => 4,
            } else switch (cur) {
                2 => 8,
                4 => 2,
                8 => 4,
                else => 4,
            };
            state.msaa_config.msaa_samples = next;
            std.log.info("Settings: MSAA Samples -> {} (applies on next pipeline rebuild)", .{next});
        },
        .fxaa_quality => {
            // Cycle FXAA quality tier: low → medium → high → low …
            // Mark the AA pipeline dirty so the render loop re-runs
            // configureFXAA with the new token substitutions on the next tick.
            const next: gpu_mod.FxaaQuality = switch (state.msaa_config.fxaa_quality) {
                .low => if (dir > 0) .medium else .high,
                .medium => if (dir > 0) .high else .low,
                .high => if (dir > 0) .low else .medium,
            };
            state.msaa_config.fxaa_quality = next;
            state.aa_dirty = true;
            std.log.info("Settings: FXAA Quality -> {s} (pipeline rebuild queued)", .{@tagName(next)});
        },
        .ao_strategy => {
            // Cycle through the three usable strategies: none → classic → moore → none …
            // propagated and ssao are not yet implemented; skip them.
            const next_ao: gpu_mod.AOStrategy = switch (state.ao_strategy) {
                .none => if (dir > 0) .classic else .moore,
                .classic => if (dir > 0) .moore else .none,
                .moore, .propagated, .ssao => if (dir > 0) .none else .classic,
            };
            state.ao_strategy = next_ao;
            std.log.info("Settings: AO Strategy -> {s} (applies on next chunk remesh)", .{@tagName(next_ao)});
        },
        .lighting => {
            // Two-state toggle today (none ↔ skylight). dir is implicitly
            // ignored here — we flip on every press, same as a checkbox.
            // Mark every loaded chunk dirty so the new mode applies live
            // (skylight is baked per-vertex at mesh time, same as AO).
            const next_mode: gpu_mod.LightingMode = switch (state.lighting_mode) {
                .none => .skylight,
                .skylight => .none,
            };
            state.lighting_mode = next_mode;
            var it = state.world.chunks.valueIterator();
            while (it.next()) |lc_ptr| {
                lc_ptr.*.mesh_dirty = true;
            }
            std.log.info("Settings: Lighting -> {s} (every loaded chunk marked dirty)", .{@tagName(next_mode)});
        },
        .frustum => {
            // Cycle: none → sphere → cone → none …
            // Live: writes through to state.frustum_strategy. The freeze
            // toggle (Cmd+F) is intentionally NOT cleared on cycle so the
            // user can A/B strategies against the same frozen viewpoint.
            state.frustum_strategy = state.frustum_strategy.cycle(dir);
            std.log.info("Settings: Frustum -> {s} (live; fov={d:.0}°)", .{
                state.frustum_strategy.label(),
                state.frustum_fov_deg,
            });
        },
        .render_dist => {
            const min_rd: i32 = 1;
            const max_rd: i32 = 16;
            var next_rd = state.render_distance_stub + dir;
            if (next_rd < min_rd) next_rd = max_rd;
            if (next_rd > max_rd) next_rd = min_rd;
            state.render_distance_stub = next_rd;
            std.log.info("Settings: Render Distance -> {} (no live effect — stub)", .{next_rd});
        },
        .back => {},
    }
}

const ChunkGPU = struct {
    vertex_buffer: ?gpu_mod.Buffer = null,
    index_buffer: ?gpu_mod.Buffer = null,
};

// Application state
const State = struct {
    world: world_mod.World,
    chunk_gpu: std.HashMap(world_mod.ChunkKey, ChunkGPU, world_mod.ChunkKey.HashContext, std.hash_map.default_max_load_percentage),
    camera: CameraType,
    player: Player,
    pipeline: ?gpu_mod.RenderPipeline = null,
    cylinder_pipeline: ?gpu_mod.RenderPipeline = null,
    uniform_buffer: ?gpu_mod.Buffer = null,
    bind_group: ?gpu_mod.BindGroup = null,
    depth_texture: ?gpu_mod.Texture = null,
    depth_view: ?gpu_mod.TextureView = null,
    cylinder_vertex_buffer: ?gpu_mod.Buffer = null,
    cylinder_index_buffer: ?gpu_mod.Buffer = null,
    cylinder_verts: std.ArrayList(VoxelVertex) = undefined,
    cylinder_indices: std.ArrayList(u32) = undefined,
    border_vertex_buffer: ?gpu_mod.Buffer = null,
    border_index_buffer: ?gpu_mod.Buffer = null,
    border_vert_count: usize = 0,
    border_idx_count: usize = 0,
    mouse_captured: bool = false,
    paused_with_mouse: bool = false,
    /// Current pause-menu screen (only meaningful when the pause_menu layer is active).
    menu_screen: MenuScreen = .main,
    /// Per-screen selection indices, kept independently so backing out and re-entering
    /// a screen restores its previous selection.
    menu_main_idx: u8 = 0,
    menu_settings_idx: u8 = 0,
    /// Exit-confirm defaults to "No" (index 0). Reset every time we enter the screen
    /// to make accidental Enter+Enter on Exit always safe.
    menu_exit_idx: u8 = 0,
    /// Runtime render distance in chunks, parsed from `--render-distance=N`.
    /// Used to initialise `World.render_distance` once per session — changing
    /// it afterwards requires a world reload, so the in-game settings picker
    /// still writes to `render_distance_stub` instead. Default comes from
    /// `world_mod.DEFAULT_RENDER_DISTANCE` (currently 4).
    render_distance: i32 = world_mod.DEFAULT_RENDER_DISTANCE,
    /// Display-only twin of `render_distance` for the Settings → Render Distance
    /// picker. The loaded-chunk region is still frozen at `World.render_distance`
    /// for the lifetime of the World, so writes here only affect the rendered
    /// label (and the fog curve below, via the same `state.render_distance`
    /// field).
    render_distance_stub: i32 = world_mod.DEFAULT_RENDER_DISTANCE,
    hover_block: ?Vec3 = null,
    game_state: GameState = undefined,
    overlay: OverlayRenderer = undefined,
    tas_replayer: ?core.Replayer = null,
    headless: bool = false,
    camera_view: CameraView = .first_person,
    spawn_point: [3]f32 = .{ 24.0, 64.0, 20.0 },
    /// True once the spawn chunk has loaded and the player has been placed at
    /// the resolved (terrain-safe) position for the current spawn_point.
    spawn_resolved: bool = false,
    debug_mode: bool = false,
    tas_step_mode: bool = false,
    /// Set by Right arrow — preTick will inject the next TAS event group on the next sim tick.
    tas_step_pending: bool = false,
    /// True during the one sim tick when TAS events are being executed; gates gameplay.
    tas_step_executing: bool = false,
    /// The TAS tick_id of the last injected step group (shown in HUD instead of sim tick).
    tas_current_tas_tick: u64 = 0,
    /// GPU debug mode — scaffold for future mesh-rebuild highlighting.
    /// When true (future): quads rebuilt this tick will be tinted a warning colour.
    /// Currently unused; set by Cmd+G or a future CLI flag.
    gpu_debug: bool = false,
    /// AA config parsed from `--aa=<none|msaa|fxaa>` (plus `--msaa=N` /
    /// `--fxaa-quality=<tier>`). Default: FXAA 3.11 at medium quality — this
    /// is the engine-wide ships-by-default AA mode. Override with
    /// `--aa=none --ao=classic --render-distance=4` to reproduce the
    /// pre-default-change behaviour used by existing regression tests.
    msaa_config: gpu_mod.AntiAliasingConfig = .{
        .method = .fxaa,
        .msaa_samples = 1,
        .fxaa_quality = .medium,
    },
    /// Ambient-occlusion sampling strategy parsed from --ao=<none|classic|moore>.
    /// Default: moore (extended indoor-corner darkening). The future in-game
    /// settings menu reads/writes this same field; changing it at runtime
    /// requires marking every loaded chunk's mesh dirty so they get remeshed
    /// with the new sampler.
    ao_strategy: gpu_mod.AOStrategy = .moore,
    /// World-lighting mode parsed from --lighting=<none|skylight>. Default:
    /// skylight (caves are dark). `.none` is the regression-test baseline that
    /// makes every face fully lit by sky regardless of how enclosed it is.
    /// Mutating this at runtime requires `mesh_dirty = true` on every loaded
    /// chunk because skylight is baked per-vertex at mesh time, same as AO.
    lighting_mode: gpu_mod.LightingMode = .skylight,
    /// Block type emitted by right-click placement. Parsed from
    /// `--place-block=<stone|glowstone>`; default stone preserves prior
    /// behaviour. Introduced alongside phase-3 block light so the
    /// `glowstone_cave.tas` regression can place a glowstone without
    /// needing an in-game block-picker UI.
    place_block: chunk_mod.BlockType = .stone,
    /// --dump-frame=<path>: capture first rendered frame to a PPM file then exit.
    dump_frame_path: ?[]const u8 = null,
    dump_frame_done: bool = false,
    /// Set by the settings-menu FXAA quality picker to request a pipeline
    /// rebuild on the next render tick. WGSL has no specialisation constants,
    /// so changing quality requires re-substituting tokens in fxaa.wgsl and
    /// re-creating the shader module + pipeline. Checked at the top of
    /// voxelRender — cleared after the rebuild runs.
    aa_dirty: bool = false,
    /// --compare-golden=<path>: after capturing the frame, compare it pixel-for-pixel
    /// against a golden PPM file. Exits 0 if within tolerance, 1 otherwise. Prints
    /// per-run stats (differing px / total px, max/mean channel delta). Tolerance
    /// knobs: --golden-max-diff-pct, --golden-max-channel-delta.
    compare_golden_path: ?[]const u8 = null,
    /// Max percentage of pixels allowed to differ (0.0 – 100.0). Default 0.5%.
    golden_max_diff_pct: f32 = 0.5,
    /// Max per-channel absolute delta (0 – 255). Pixels with any channel beyond
    /// this threshold count as "differing". Default 2.
    golden_max_channel_delta: u8 = 2,
    /// True while the first spawn chunk is being generated + meshed. Render loop
    /// shows a purple "WORLD LOADING" overlay and skips 3D rendering. Flipped
    /// false once the spawn chunk is meshed and the player has been placed at
    /// the resolved spawn position.
    world_loading: bool = true,
    /// Selected world generation preset. Parsed from --world=<flatland|hilly>.
    world_preset: world_gen.Preset = .hilly,
    /// Frustum-cull strategy parsed from --frustum=<none|sphere|cone>.
    /// Default is `.none` so the feature is opt-in — see frustum.zig header
    /// for the rationale and the cone-vs-sphere math notes.
    frustum_strategy: frustum_mod.Strategy = .none,
    /// Total fov in degrees for the cone strategy. Parsed from
    /// --frustum-fov-deg=<degrees>; default 180 (a no-op short-circuit
    /// chosen so an accidental `--frustum=cone` cannot drop chunks the
    /// player can still see).
    frustum_fov_deg: f32 = 180.0,
    /// When non-null, render reuses this snapshot every frame instead of
    /// rebuilding from the live camera. Toggled by Cmd+F (Ctrl+F on
    /// Win/Linux). Diagnostic only — lets the player fly around and watch
    /// what their previous viewpoint thinks is visible.
    frozen_frustum: ?frustum_mod.Frustum = null,
    /// Diagnostic counters for the debug overlay. Reset every frame at the
    /// top of the chunk-draw loop, written by the cull. NOT used for any
    /// game logic.
    frustum_drawn: u32 = 0,
    frustum_culled: u32 = 0,
    /// F3-style debug overlay rolling FPS sampler. Captured at the top of
    /// voxelRender from real-time deltas (not the fixed-step sim tick rate),
    /// so the displayed FPS reflects actual present cadence even when the
    /// simulation tick rate is unrelated. 60 samples ≈ 1 s window at 60 Hz.
    fps_window_ns: [60]u64 = .{0} ** 60,
    fps_window_idx: usize = 0,
    fps_window_filled: bool = false,
    last_frame_ns: i128 = 0,
    /// Mesher strategy parsed from --meshing=<naive|greedy>. Default: greedy.
    /// Greedy merges coplanar same-material + same-lighting faces into larger
    /// rectangles (5–10× vertex reduction on flatland/hilly). Naive is kept
    /// as a fallback + regression baseline. Changing this at runtime requires
    /// marking every loaded chunk dirty so it re-meshes with the new strategy —
    /// same constraint as `ao_strategy` and `lighting_mode`.
    meshing_mode: mesher_mod.MeshingMode = .greedy,

    // --------------------------------------------------------------------
    // --profile-csv=<path> instrumentation (chunk-size-perf investigation).
    // --------------------------------------------------------------------
    //
    // Per-tick accumulators. voxelTick resets them at the top, accumulates
    // generation + meshing costs inline, and voxelRender adds upload cost
    // then writes a CSV row. Everything is in nanoseconds (u64 is plenty —
    // u64 overflow at 9.2e9 seconds ≈ 292 years). See the docs next to
    // examples/voxel/docs/chunk-size-investigation.md for the baseline
    // numbers this exists to capture.
    //
    // The CSV columns are:
    //   tick, loading, tick_ns, gen_ns, gen_count, mesh_ns, mesh_count,
    //   upload_ns, upload_count, render_ns
    //
    // `loading` is 1 while the pregen loading screen is up and 0 after the
    // player is released, so the analysis script can partition the dataset
    // into "first-paint" and "flyover" halves without guessing.
    profile_csv_path: ?[]const u8 = null,
    profile_csv_file: if (!is_wasm) ?std.fs.File else ?void = null,
    tick_t0_ns: i128 = 0,
    tick_ns: u64 = 0,
    gen_ns: u64 = 0,
    gen_count: u32 = 0,
    mesh_ns: u64 = 0,
    mesh_count: u32 = 0,
    upload_ns: u64 = 0,
    upload_count: u32 = 0,
    render_t0_ns: i128 = 0,
    render_ns: u64 = 0,
    /// Set to the sim tick id of the first tick on which voxelRender
    /// executed with world_loading == false. Used to report "first-paint
    /// time" in the investigation doc.
    first_paint_tick: ?u64 = null,

    // ─── Hotbar (10-slot creative-mode block selector) ───────────────────
    // Per-slot block assignment. `.air` means the slot is empty (no
    // placement allowed when selected). Number keys 1..9 map to slots
    // 0..8; the 0 key maps to slot 9 — matching Minecraft's layout so
    // muscle memory carries over. Defaults are wired in voxelInit
    // because `var state: State = undefined` bypasses field defaults.
    hotbar_slots: [10]chunk_mod.BlockType = .{ .air, .air, .air, .air, .air, .air, .air, .air, .air, .air },
    /// Currently selected slot (0..9). Drives right-click placement and
    /// the brighter border in the overlay.
    hotbar_selected: u8 = 0,
    /// CLI --hotbar=<on|off>. When false the overlay is not drawn but the
    /// number keys still select slots and right-click still places — the
    /// flag is purely cosmetic so screenshots can be taken without the bar.
    hotbar_visible: bool = true,
    /// `--async-chunks=on|off`. When on, chunk gen+mesh runs on a background
    /// worker thread and the main-thread mesh loop is skipped for new chunks
    /// and dirty-neighbour remeshes. When off, restores the legacy synchronous
    /// time-budgeted path. See `examples/voxel/docs/async-chunks.md`.
    async_chunks_enabled: bool = true,
    /// Background gen+mesh pipeline. Non-null iff `async_chunks_enabled`.
    /// Init'd in voxelInit after the world, deinit'd in voxelShutdown before
    /// the world so the worker thread is joined before any world data is torn
    /// down.
    async_pipeline: ?*async_chunks_mod.Pipeline = null,
    /// Scratch list reused every tick to receive drained async results.
    async_result_scratch: std.ArrayList(async_chunks_mod.Result) = .{},
};

var state: State = undefined;

fn voxelInit(ctx: *sw.Context) !void {
    std.log.info("Voxel demo init", .{});

    // Explicitly null all optional fields — `var state: State = undefined` bypasses struct defaults
    state.pipeline = null;
    state.cylinder_pipeline = null;
    state.uniform_buffer = null;
    state.bind_group = null;
    state.depth_texture = null;
    state.depth_view = null;
    state.cylinder_vertex_buffer = null;
    state.cylinder_index_buffer = null;
    state.border_vertex_buffer = null;
    state.border_index_buffer = null;
    state.border_vert_count = 0;
    state.border_idx_count = 0;
    state.hover_block = null;
    state.tas_replayer = null;

    // Default preset (overridden by --world= below, parsed AFTER this block).
    // We init the world with the default first and recreate if the flag overrides.
    state.world_preset = .hilly;
    state.world_loading = true;

    // World init is deferred until after arg parsing (so --world= can select the preset).
    state.chunk_gpu = std.HashMap(world_mod.ChunkKey, ChunkGPU, world_mod.ChunkKey.HashContext, std.hash_map.default_max_load_percentage).init(ctx.allocator());

    // Initialize camera
    const window_info = ctx.window();
    const aspect = @as(f32, @floatFromInt(window_info.width)) / @as(f32, @floatFromInt(window_info.height));

    // Spawn player with feet on terrain surface (grass top = y=8).
    state.player = Player.init(24.0, 64.0, 20.0);

    // Camera tracks player eye position; yaw/pitch set for a good starting view.
    const eye = state.player.eyePos();
    state.camera = CameraType.init(Vec3.init(eye[0], eye[1], eye[2]), aspect);
    state.camera.yaw = -std.math.pi / 2.0;
    state.camera.pitch = -0.3;

    // Cylinder scratch buffers (ArrayList new-API: no allocator at init time)
    state.cylinder_verts = std.ArrayList(VoxelVertex){};
    state.cylinder_indices = std.ArrayList(u32){};
    state.spawn_point = .{ 24.0, 64.0, 20.0 };
    state.spawn_resolved = false;
    state.camera_view = .first_person;
    state.debug_mode = false;
    state.tas_step_mode = false;
    state.tas_step_pending = false;
    state.tas_step_executing = false;
    state.tas_current_tas_tick = 0;
    state.gpu_debug = false;

    state.mouse_captured = false;
    state.paused_with_mouse = false;
    state.menu_screen = .main;
    state.menu_main_idx = 0;
    state.menu_settings_idx = 0;
    state.menu_exit_idx = 0;
    // Runtime render distance: default from world_mod, overridden by
    // `--render-distance=N` below. `render_distance_stub` shadows the same
    // value for the Settings picker label.
    state.render_distance = world_mod.DEFAULT_RENDER_DISTANCE;
    state.render_distance_stub = world_mod.DEFAULT_RENDER_DISTANCE;
    state.headless = false;

    // Initialize game state layer stack
    state.game_state = GameState.init();

    // Initialize overlay renderer
    state.overlay = OverlayRenderer.init(ctx.allocator());

    // Default AA config: FXAA 3.11 at medium quality (ships-by-default).
    // `--aa=...`, `--msaa=N`, and `--fxaa-quality=<tier>` override below.
    state.msaa_config = .{
        .method = .fxaa,
        .msaa_samples = 1,
        .fxaa_quality = .medium,
    };
    // Default AO strategy: moore (extended indoor-corner AO).
    state.ao_strategy = .moore;
    // Default lighting: skylight (caves dark). `--lighting=none` overrides.
    state.lighting_mode = .skylight;
    // Frustum-cull defaults: opt-in (.none) and a 180° fov no-op so any
    // future user toggling on .cone via the menu without changing fov gets
    // a safe identity cull until they tighten it.
    state.frustum_strategy = .none;
    state.frustum_fov_deg = 180.0;
    state.frozen_frustum = null;
    state.frustum_drawn = 0;
    state.frustum_culled = 0;
    state.fps_window_ns = .{0} ** 60;
    state.fps_window_idx = 0;
    state.fps_window_filled = false;
    state.last_frame_ns = 0;
    // Default meshing: greedy. `--meshing=naive` falls back to the old
    // one-quad-per-face path used by the existing regression baselines.
    state.meshing_mode = .greedy;
    state.dump_frame_path = null;
    state.dump_frame_done = false;
    state.compare_golden_path = null;
    state.golden_max_diff_pct = 0.5;
    state.golden_max_channel_delta = 2;
    // Default async mode: ON. `--async-chunks=off` restores the legacy sync
    // time-budgeted gen+mesh loop.
    state.async_chunks_enabled = true;
    state.async_pipeline = null;
    state.async_result_scratch = .{};

    // Hotbar defaults: slot 1 = stone, slot 2 = grass, slot 3 = dirt.
    // Slot 4 was reserved for glowstone but `voxel/block-light` has not been
    // merged yet (no glowstone BlockType to assign), so it stays empty —
    // TODO: switch to .glowstone once block-light lands. Slots 5-10 empty.
    state.hotbar_slots = .{ .stone, .grass, .dirt, .air, .air, .air, .air, .air, .air, .air };
    state.hotbar_selected = 0;
    state.hotbar_visible = true;

    // CLI flag parsing — native only. WASM builds never have process args;
    // they use the hardcoded defaults set above (hilly world, skylight,
    // classic AO, 4× MSAA) which is exactly what the browser should show.
    const args: [][:0]u8 = if (comptime is_wasm)
        &[_][:0]u8{}
    else
        try std.process.argsAlloc(ctx.allocator());
    defer if (comptime !is_wasm) std.process.argsFree(ctx.allocator(), args);

    // Pre-scan: collect all flags before processing --tas, so flag order doesn't matter.
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--headless")) state.headless = true;
        if (std.mem.eql(u8, arg, "--tas-step")) state.tas_step_mode = true;
        if (std.mem.eql(u8, arg, "--gpu-debug")) state.gpu_debug = true;
        if (std.mem.startsWith(u8, arg, "--dump-frame=")) {
            const raw: []const u8 = arg["--dump-frame=".len..];
            const p = std.mem.sliceTo(raw, 0);
            // dupe so the path survives argsFree at end of voxelInit
            state.dump_frame_path = try ctx.allocator().dupe(u8, p);
        }
        if (std.mem.startsWith(u8, arg, "--compare-golden=")) {
            const raw: []const u8 = arg["--compare-golden=".len..];
            const p = std.mem.sliceTo(raw, 0);
            state.compare_golden_path = try ctx.allocator().dupe(u8, p);
        }
        if (std.mem.startsWith(u8, arg, "--golden-max-diff-pct=")) {
            const val = std.mem.sliceTo(arg["--golden-max-diff-pct=".len..], 0);
            state.golden_max_diff_pct = std.fmt.parseFloat(f32, val) catch {
                std.log.err("--golden-max-diff-pct: cannot parse '{s}' as f32", .{val});
                std.process.exit(1);
            };
        }
        if (std.mem.startsWith(u8, arg, "--golden-max-channel-delta=")) {
            const val = std.mem.sliceTo(arg["--golden-max-channel-delta=".len..], 0);
            state.golden_max_channel_delta = std.fmt.parseInt(u8, val, 10) catch {
                std.log.err("--golden-max-channel-delta: cannot parse '{s}' as u8", .{val});
                std.process.exit(1);
            };
        }
        if (std.mem.startsWith(u8, arg, "--world=")) {
            const val = std.mem.sliceTo(arg["--world=".len..], 0);
            if (std.mem.eql(u8, val, "flatland")) {
                state.world_preset = .flatland;
            } else if (std.mem.eql(u8, val, "hilly")) {
                state.world_preset = .hilly;
            } else {
                std.log.err("--world: invalid value '{s}'. Accepted: flatland, hilly", .{val});
                fatalExit(1);
            }
        }
        if (std.mem.startsWith(u8, arg, "--msaa=")) {
            const val = arg["--msaa=".len..];
            // `--msaa=N` always implies method=msaa; preserves any fxaa_quality
            // already parsed (though FXAA is inactive when method=msaa anyway).
            const q = state.msaa_config.fxaa_quality;
            if (std.mem.eql(u8, val, "none") or std.mem.eql(u8, val, "0")) {
                state.msaa_config = .{ .method = .none, .msaa_samples = 1, .fxaa_quality = q };
            } else if (std.mem.eql(u8, val, "1")) {
                state.msaa_config = .{ .method = .msaa, .msaa_samples = 1, .fxaa_quality = q };
            } else if (std.mem.eql(u8, val, "2")) {
                state.msaa_config = .{ .method = .msaa, .msaa_samples = 2, .fxaa_quality = q };
            } else if (std.mem.eql(u8, val, "4")) {
                state.msaa_config = .{ .method = .msaa, .msaa_samples = 4, .fxaa_quality = q };
            } else if (std.mem.eql(u8, val, "8")) {
                state.msaa_config = .{ .method = .msaa, .msaa_samples = 8, .fxaa_quality = q };
            } else {
                std.log.err("--msaa: invalid value '{s}'. Accepted: none, 0, 1, 2, 4, 8", .{val});
                fatalExit(1);
            }
        }
        if (std.mem.startsWith(u8, arg, "--aa=")) {
            const val = arg["--aa=".len..];
            // Preserve method-specific knobs (sample count, FXAA quality) when
            // switching methods so `--aa=fxaa --fxaa-quality=high` and
            // `--msaa=8 --aa=msaa` work regardless of flag order.
            const samples = state.msaa_config.msaa_samples;
            const q = state.msaa_config.fxaa_quality;
            if (std.mem.eql(u8, val, "none")) {
                state.msaa_config = .{ .method = .none, .msaa_samples = 1, .fxaa_quality = q };
            } else if (std.mem.eql(u8, val, "msaa")) {
                // Keep the sample count from --msaa=N if set earlier; default
                // to 4 when it isn't already a valid MSAA sample count.
                const s: u32 = if (samples >= 2) samples else 4;
                state.msaa_config = .{ .method = .msaa, .msaa_samples = s, .fxaa_quality = q };
            } else if (std.mem.eql(u8, val, "fxaa")) {
                state.msaa_config = .{ .method = .fxaa, .msaa_samples = 1, .fxaa_quality = q };
            } else {
                std.log.err("--aa: invalid value '{s}'. Accepted: none, msaa, fxaa", .{val});
                fatalExit(1);
            }
        }
        if (std.mem.startsWith(u8, arg, "--fxaa-quality=")) {
            const val = arg["--fxaa-quality=".len..];
            if (std.mem.eql(u8, val, "low")) {
                state.msaa_config.fxaa_quality = .low;
            } else if (std.mem.eql(u8, val, "medium") or std.mem.eql(u8, val, "med")) {
                state.msaa_config.fxaa_quality = .medium;
            } else if (std.mem.eql(u8, val, "high")) {
                state.msaa_config.fxaa_quality = .high;
            } else {
                std.log.err("--fxaa-quality: invalid value '{s}'. Accepted: low, medium, high", .{val});
                std.process.exit(1);
            }
        }
        if (std.mem.startsWith(u8, arg, "--render-distance=")) {
            const val = arg["--render-distance=".len..];
            const n = std.fmt.parseInt(i32, val, 10) catch {
                std.log.err("--render-distance: invalid value '{s}'. Expected a positive integer.", .{val});
                std.process.exit(1);
                unreachable;
            };
            if (n < 1 or n > 32) {
                std.log.err("--render-distance: value {} out of range [1, 32].", .{n});
                std.process.exit(1);
            }
            state.render_distance = n;
            state.render_distance_stub = n;
        }
        if (std.mem.startsWith(u8, arg, "--ao=")) {
            const val = arg["--ao=".len..];
            if (std.mem.eql(u8, val, "none")) {
                state.ao_strategy = .none;
            } else if (std.mem.eql(u8, val, "classic")) {
                state.ao_strategy = .classic;
            } else if (std.mem.eql(u8, val, "moore")) {
                state.ao_strategy = .moore;
            } else {
                std.log.err("--ao: invalid value '{s}'. Accepted: none, classic, moore", .{val});
                fatalExit(1);
            }
        }
        if (std.mem.startsWith(u8, arg, "--hotbar=")) {
            const val = arg["--hotbar=".len..];
            if (std.mem.eql(u8, val, "on")) {
                state.hotbar_visible = true;
            } else if (std.mem.eql(u8, val, "off")) {
                state.hotbar_visible = false;
            } else {
                std.log.err("--hotbar: invalid value '{s}'. Accepted: on, off", .{val});
                std.process.exit(1);
            }
        }
        if (std.mem.startsWith(u8, arg, "--lighting=")) {
            const val = arg["--lighting=".len..];
            if (std.mem.eql(u8, val, "none")) {
                state.lighting_mode = .none;
            } else if (std.mem.eql(u8, val, "skylight")) {
                state.lighting_mode = .skylight;
            } else {
                std.log.err("--lighting: invalid value '{s}'. Accepted: none, skylight", .{val});
                fatalExit(1);
            }
        }
        if (std.mem.startsWith(u8, arg, "--frustum=")) {
            const val = std.mem.sliceTo(arg["--frustum=".len..], 0);
            if (frustum_mod.Strategy.fromString(val)) |s| {
                state.frustum_strategy = s;
            } else {
                std.log.err("--frustum: invalid value '{s}'. Accepted: none, sphere, cone", .{val});
                std.process.exit(1);
            }
        }
        if (std.mem.startsWith(u8, arg, "--frustum-fov-deg=")) {
            const val = std.mem.sliceTo(arg["--frustum-fov-deg=".len..], 0);
            const parsed = std.fmt.parseFloat(f32, val) catch {
                std.log.err("--frustum-fov-deg: not a number: '{s}'", .{val});
                std.process.exit(1);
            };
            if (parsed < 0.0 or parsed > 360.0) {
                std.log.err("--frustum-fov-deg: must be in [0, 360], got {d}", .{parsed});
                std.process.exit(1);
            }
            state.frustum_fov_deg = parsed;
        }
        if (std.mem.startsWith(u8, arg, "--profile-csv=")) {
            // --profile-csv=<path>: write a per-tick timing row for the
            // chunk-size-perf investigation. Columns (header written on
            // file open):
            //   tick, loading, tick_ns, gen_ns, gen_count, mesh_ns,
            //   mesh_count, upload_ns, upload_count, render_ns
            // See examples/voxel/docs/chunk-size-investigation.md for the
            // baseline + experiment numbers this produces.
            const raw: []const u8 = arg["--profile-csv=".len..];
            const p = std.mem.sliceTo(raw, 0);
            state.profile_csv_path = try ctx.allocator().dupe(u8, p);
        }
        if (std.mem.startsWith(u8, arg, "--debug-overlay=")) {
            // Force the F3-style debug overlay on at boot. Default is off so
            // production runs (and the framespike regression) aren't visually
            // contaminated. Same shape as the other engine toggles.
            const val = std.mem.sliceTo(arg["--debug-overlay=".len..], 0);
            if (std.mem.eql(u8, val, "on")) {
                if (!state.game_state.isLayerActive(.debug_overlay)) {
                    state.game_state.toggleDebugOverlay();
                }
            } else if (std.mem.eql(u8, val, "off")) {
                if (state.game_state.isLayerActive(.debug_overlay)) {
                    state.game_state.toggleDebugOverlay();
                }
            } else {
                std.log.err("--debug-overlay: invalid value '{s}'. Accepted: on, off", .{val});
                std.process.exit(1);
            }
        }
        if (std.mem.startsWith(u8, arg, "--place-block=")) {
            const val = arg["--place-block=".len..];
            if (std.mem.eql(u8, val, "stone")) {
                state.place_block = .stone;
            } else if (std.mem.eql(u8, val, "glowstone")) {
                state.place_block = .glowstone;
            } else {
                std.log.err("--place-block: invalid value '{s}'. Accepted: stone, glowstone", .{val});
                std.process.exit(1);
            }
        }
        if (std.mem.startsWith(u8, arg, "--meshing=")) {
            const val = std.mem.sliceTo(arg["--meshing=".len..], 0);
            if (std.mem.eql(u8, val, "naive")) {
                state.meshing_mode = .naive;
            } else if (std.mem.eql(u8, val, "greedy")) {
                state.meshing_mode = .greedy;
            } else {
                std.log.err("--meshing: invalid value '{s}'. Accepted: naive, greedy", .{val});
                std.process.exit(1);
            }
        }
        if (std.mem.startsWith(u8, arg, "--async-chunks=")) {
            const val = arg["--async-chunks=".len..];
            if (std.mem.eql(u8, val, "on")) {
                state.async_chunks_enabled = true;
            } else if (std.mem.eql(u8, val, "off")) {
                state.async_chunks_enabled = false;
            } else {
                std.log.err("--async-chunks: invalid value '{s}'. Accepted: on, off", .{val});
                std.process.exit(1);
            }
        }
    }
    std.log.info("AA config (post-parse): method={s} requested_samples={} fxaa_quality={s}", .{
        @tagName(state.msaa_config.method),
        state.msaa_config.msaa_samples,
        @tagName(state.msaa_config.fxaa_quality),
    });
    std.log.info("AO strategy (post-parse): {s}", .{@tagName(state.ao_strategy)});
    std.log.info("Lighting mode (post-parse): {s}", .{@tagName(state.lighting_mode)});
    std.log.info("Meshing mode (post-parse): {s}", .{@tagName(state.meshing_mode)});
    std.log.info("World preset: {s}", .{@tagName(state.world_preset)});
    std.log.info("Frustum cull: strategy={s} fov={d:.0}°", .{
        state.frustum_strategy.label(), state.frustum_fov_deg,
    });
    std.log.info("Render distance (post-parse): {} chunks", .{state.render_distance});

    // Initialize world with the selected preset and CLI-selected render
    // distance (deferred until here so --world= / --render-distance= work
    // regardless of flag order).
    state.world = try world_mod.World.init(ctx.allocator(), state.world_preset, state.render_distance);

    // Open the profile CSV if requested. Writing the header here means every
    // subsequent row can be appended without a seek. Failures log a warning
    // and disable the feature so a bad path doesn't crash the TAS run.
    if (comptime !is_wasm) {
        if (state.profile_csv_path) |p| {
        if (std.fs.cwd().createFile(p, .{ .truncate = true })) |f| {
            state.profile_csv_file = f;
            const header = "tick,loading,chunk_w,tick_ns,gen_ns,gen_count,mesh_ns,mesh_count,upload_ns,upload_count,render_ns\n";
            f.writeAll(header) catch |err| {
                std.log.err("--profile-csv: header write failed: {}", .{err});
            };
            std.log.info("--profile-csv: writing to '{s}' (chunk_w={d})", .{ p, chunk_mod.CHUNK_W });
        } else |err| {
            std.log.err("--profile-csv: failed to open '{s}': {}", .{ p, err });
            state.profile_csv_file = null;
            state.profile_csv_path = null;
        }
        }
    }

    // Initialize the background gen+mesh pipeline if async mode is enabled.
    // The worker thread starts immediately and blocks on the empty job queue
    // until main pushes the first job in voxelTick.
    if (comptime !is_wasm) std.log.info("Async chunks (post-parse): {s}", .{if (state.async_chunks_enabled) "on" else "off"});
    if (comptime !is_wasm) {
        if (state.async_chunks_enabled) {
            state.async_pipeline = async_chunks_mod.Pipeline.init(ctx.allocator()) catch |init_err| blk: {
            std.log.err("Async pipeline init failed ({}) — falling back to sync mesh loop", .{init_err});
            state.async_chunks_enabled = false;
                break :blk null;
            };
        }
    } else {
        state.async_chunks_enabled = false;
    }

    // TAS loading — native only. `TasScript.parseFile` calls std.fs.cwd()
    // which pulls in posix symbols that don't exist on wasm32-freestanding.
    // The browser build never loads TAS scripts anyway; users replay via the
    // native binary.
    if (comptime !is_wasm) {
        for (args, 0..) |arg, i| {
            if (std.mem.eql(u8, arg, "--tas") and i + 1 < args.len) {
                const tas_path = args[i + 1];
                std.log.info("Loading TAS script: {s}", .{tas_path});

                // Parse TAS script
                var tas_script = core.TasScript.parseFile(ctx.allocator(), tas_path) catch |err| {
                    std.log.err("Failed to parse TAS script: {}", .{err});
                    return err;
                };
                defer tas_script.deinit();

                std.log.info("TAS script loaded: {} commands, {} ticks duration", .{
                    tas_script.entries.items.len,
                    tas_script.getDuration(),
                });

                // Convert TAS entries → events, transfer ownership directly to the replayer.
                // No serialize/deserialize roundtrip needed.
                const events = try tas_script.toEvents(120); // 120 Hz
                const replayer = core.Replayer.initDirect(ctx.allocator(), events);
                // Leave replayer in .stopped state. It will be remapped and .play()ed
                // when world loading completes (see voxelTick). This ensures TAS tick 1
                // aligns with the first post-loading sim tick regardless of load duration.
                state.tas_replayer = replayer;

                if (state.tas_step_mode) {
                    std.log.info("TAS step mode: press Right arrow to advance one tick", .{});
                } else {
                    // Normal TAS: block physical input for deterministic replay.
                    ctx.setInputBlocked(true);
                }

                // Enable debug mode automatically so the keyboard HUD shows TAS input live.
                state.debug_mode = true;
                // Auto-enable GPU debug in step mode so rebuilt faces are highlighted.
                if (state.tas_step_mode) state.gpu_debug = true;
                std.log.info("TAS replayer ready — will start after world loading completes", .{});
                break;
            }
        }
    }

    // --debug=on|off final pass: parsed AFTER TAS init so it overrides the
    // automatic `state.debug_mode = true` that TAS load forces (the keyboard
    // HUD wants to be visible during a normal TAS run, but the
    // debug_overlay.sh regression test needs to capture a clean baseline with
    // debug_mode=off even when a TAS is loaded for camera determinism).
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--debug=")) {
            const val = std.mem.sliceTo(arg["--debug=".len..], 0);
            if (std.mem.eql(u8, val, "on")) {
                state.debug_mode = true;
            } else if (std.mem.eql(u8, val, "off")) {
                state.debug_mode = false;
            } else {
                std.log.err("--debug: invalid value '{s}'. Accepted: on, off", .{val});
                std.process.exit(1);
            }
        }
    }

    std.log.info("Voxel demo ready", .{});
}

/// After a block is placed/destroyed at world (wx, wy, wz), check if it sits on a
/// chunk boundary. If so, call updateForBlockChange on the block just across that
/// boundary in the neighbouring chunk — otherwise that block's face toward the
/// changed block will remain stale (visible gap or missing face).
fn updateBoundaryNeighbors(world: *world_mod.World, wx: i32, wy: i32, wz: i32, camera_pos: [3]f32) void {
    const cx = world_mod.chunkCoordOf(wx);
    const cz = world_mod.chunkCoordOf(wz);
    const lx = wx - cx * chunk_mod.CHUNK_W;
    const lz = wz - cz * chunk_mod.CHUNK_W;

    // Four horizontal neighbours; Y never crosses a chunk boundary.
    const checks = [_]struct { coord: i32, at_min: bool, dx: i32, dz: i32 }{
        .{ .coord = lx, .at_min = true, .dx = -1, .dz = 0 }, // −X edge
        .{ .coord = lx, .at_min = false, .dx = 1, .dz = 0 }, // +X edge
        .{ .coord = lz, .at_min = true, .dx = 0, .dz = -1 }, // −Z edge
        .{ .coord = lz, .at_min = false, .dx = 0, .dz = 1 }, // +Z edge
    };
    for (checks) |c| {
        const at_boundary = if (c.at_min) c.coord == 0 else c.coord == chunk_mod.CHUNK_W - 1;
        if (!at_boundary) continue;

        const nb_wx = wx + c.dx;
        const nb_wz = wz + c.dz;
        const nb_lc = world.getChunkAtBlock(nb_wx, nb_wz) orelse continue;
        const nb_cx = world_mod.chunkCoordOf(nb_wx);
        const nb_cz = world_mod.chunkCoordOf(nb_wz);
        const nb_lx = nb_wx - nb_cx * chunk_mod.CHUNK_W;
        const nb_lz = nb_wz - nb_cz * chunk_mod.CHUNK_W;

        if (state.meshing_mode == .greedy) {
            // Greedy merged quads can't be patched by
            // `updateForBlockChange` (see comment on the dig handler). Mark
            // the neighbour chunk dirty for a full re-mesh.
            nb_lc.mesh_dirty = true;
            continue;
        }
        nb_lc.mesh.updateForBlockChange(
            &nb_lc.chunk,
            nb_lx,
            wy,
            nb_lz,
            camera_pos,
            nb_lc.worldX(),
            nb_lc.worldZ(),
            world.asBlockGetter(),
            state.ao_strategy,
            state.lighting_mode,
        ) catch {
            nb_lc.mesh_dirty = true;
        };
        nb_lc.mesh_incremental_dirty = true;
    }
}

/// Scan upward from spawn[Y] to find the first 1×2 (width×height) air column.
/// Returns a feet position that puts the player clear of any terrain.
/// Must only be called once the chunk at (spawn[0], spawn[2]) is loaded;
/// unloaded chunks look like air and would give a bogus result.
fn resolveSpawnPos(world: *const world_mod.World, spawn: [3]f32) [3]f32 {
    const bx: i32 = @intFromFloat(@floor(spawn[0]));
    const bz: i32 = @intFromFloat(@floor(spawn[2]));
    // Start at the block the spawn point sits in (minimum y=1 to avoid bedrock floor).
    const start_y: i32 = @max(1, @as(i32, @intFromFloat(@floor(spawn[1]))));
    var y: i32 = start_y;
    while (y < 254) : (y += 1) {
        if (world.getBlock(bx, y, bz) == .air and
            world.getBlock(bx, y + 1, bz) == .air)
        {
            return .{ spawn[0], @as(f32, @floatFromInt(y)), spawn[2] };
        }
    }
    return spawn; // already above terrain (or chunk not generating normally)
}

/// Y coordinate just above the heightmap surface at world (wx, wz). This is the
/// "overworld Y" — the block a player's feet occupy when standing on top of the
/// grass cap. Used for first-ever spawn resolution so we never start from a Y
/// embedded in rock on hilly preset spawns.
fn surfaceFeetY(world: *const world_mod.World, wx: i32, wz: i32) i32 {
    return world_gen.sampleHeight(wx, wz, world.gen_config) + 1;
}

/// True iff placing a 1×1×1 block at world (px, py, pz) would intersect the
/// player's AABB. Used to refuse hotbar right-click placements that would
/// embed the player inside their own block. Block AABB is [px,px+1)³;
/// player AABB is the cylinder's bounding box: ±PLAYER_RADIUS in X/Z and
/// [feet_y, feet_y + PLAYER_HEIGHT] in Y.
fn placementIntersectsPlayer(px: i32, py: i32, pz: i32, feet: [3]f32) bool {
    const min_x = feet[0] - player_mod.PLAYER_RADIUS;
    const max_x = feet[0] + player_mod.PLAYER_RADIUS;
    const min_y = feet[1];
    const max_y = feet[1] + player_mod.PLAYER_HEIGHT;
    const min_z = feet[2] - player_mod.PLAYER_RADIUS;
    const max_z = feet[2] + player_mod.PLAYER_RADIUS;

    const bx0 = @as(f32, @floatFromInt(px));
    const bx1 = bx0 + 1.0;
    const by0 = @as(f32, @floatFromInt(py));
    const by1 = by0 + 1.0;
    const bz0 = @as(f32, @floatFromInt(pz));
    const bz1 = bz0 + 1.0;

    return min_x < bx1 and max_x > bx0 and
        min_y < by1 and max_y > by0 and
        min_z < bz1 and max_z > bz0;
}

/// CPU-side base block colour matching `voxel.wgsl:getBlockColor`. Used by
/// the hotbar overlay to draw thumbnails that visually match the in-world
/// blocks. Grass intentionally returns its top-face green so the slot icon
/// reads as "grass" at a glance, not "dirt".
fn hotbarBlockColor(bt: chunk_mod.BlockType) [3]f32 {
    return switch (bt) {
        .grass => .{ 0.4, 0.8, 0.2 },
        .dirt => .{ 0.6, 0.4, 0.2 },
        .stone => .{ 0.5, 0.5, 0.5 },
        .bedrock => .{ 0.3, 0.3, 0.3 },
        .glowstone => .{ 1.0, 0.9, 0.3 },
        .debug_marker => .{ 1.0, 0.0, 0.0 },
        .air => .{ 0.0, 0.0, 0.0 },
    };
}

/// CPU port of `voxel.wgsl:texelHash`. Returns a deterministic [0,1] hash
/// for an integer texel coordinate so the hotbar thumbnails use the exact
/// same noise pattern as the in-world block faces. The constants and
/// rotations must stay in sync with the WGSL version — if either drifts,
/// the hotbar icons stop matching their world textures.
fn texelHashCpu(px: u32, py: u32) f32 {
    var h: u32 = px *% 1664525 +% py *% 1013904223 +% 0xDEADBEEF;
    h ^= h >> 16;
    h *%= 2246822519;
    h ^= h >> 13;
    h *%= 3266489917;
    h ^= h >> 16;
    return @as(f32, @floatFromInt(h & 0xFF)) / 255.0;
}

/// Sync the camera position to the player's eye position. Call this any time
/// the player is teleported outside of the gameplay-input branch (initial
/// spawn after world loading completes, manual respawn, void-death respawn) so
/// the rendered view follows the player on the very next frame instead of
/// lagging behind until first input.
fn syncCameraToPlayer() void {
    const eye = state.player.eyePos();
    state.camera.position = Vec3.init(eye[0], eye[1], eye[2]);
}

/// Pregen step: generate up to K chunks in a (2*R+1)×(2*R+1) square around the
/// spawn chunk column, then mesh up to M chunks whose four horizontal neighbours
/// are all generated. Returns true once the entire INNER ring (the (2*(R-1)+1)
/// square centred on spawn) is meshed — meaning every chunk inside the outer
/// ring that has all-neighbours-present has completed meshing and the player
/// can safely be released without the loading screen having to linger.
///
/// Inner ring size: for R = PREGEN_RADIUS = 2 the outer square is 5×5 and the
/// inner square is 3×3 (9 chunks), since only cells whose four neighbours are
/// also inside the 5×5 can satisfy `hasAllNeighborsGenerated`.
///
/// Running cost: bursts through PREGEN_CHUNKS_PER_TICK generations and
/// PREGEN_MESH_GENS_PER_TICK mesh builds per call. Caller ticks this until it
/// returns true, keeping the loading screen animated between ticks.
fn pregenStep(world: *world_mod.World, spawn_cx: i32, spawn_cz: i32, ao_strategy: gpu_mod.AOStrategy, lighting_mode: gpu_mod.LightingMode, meshing_mode: mesher_mod.MeshingMode) !bool {
    const R = world_mod.PREGEN_RADIUS;

    // Pass 1 — generate every chunk inside the (2R+1)^2 outer square that is
    // not yet present. Inside-out order so the innermost (meshable) ones
    // come online first.
    var gens: usize = 0;
    var r: i32 = 0;
    outer_gen: while (r <= R) : (r += 1) {
        var dz: i32 = -r;
        while (dz <= r) : (dz += 1) {
            var dx: i32 = -r;
            while (dx <= r) : (dx += 1) {
                // Skip cells from inner radii we've already visited.
                if (@max(@abs(dx), @abs(dz)) != r) continue;
                if (gens >= PREGEN_CHUNKS_PER_TICK) break :outer_gen;
                if (try world.generateChunk(spawn_cx + dx, spawn_cz + dz)) {
                    gens += 1;
                }
            }
        }
    }

    // Pass 2 — mesh any chunk inside the inner (2*(R-1)+1)^2 square that has
    // all four neighbours generated. Only the inner ring can mesh cleanly;
    // the outer ring is intentionally left unmeshed (it's the buffer so the
    // inner ring can mesh without seam holes).
    const inner_r = R - 1;
    var meshes: usize = 0;
    var idz: i32 = -inner_r;
    outer_mesh: while (idz <= inner_r) : (idz += 1) {
        var idx: i32 = -inner_r;
        while (idx <= inner_r) : (idx += 1) {
            if (meshes >= PREGEN_MESH_GENS_PER_TICK) break :outer_mesh;
            const key = world_mod.ChunkKey{ .cx = spawn_cx + idx, .cz = spawn_cz + idz };
            const lc = world.chunks.get(key) orelse continue;
            if (!lc.mesh_dirty) continue;
            if (!world.hasAllNeighborsGenerated(lc.cx, lc.cz)) continue;
            mesher_mod.generateMeshForMode(
                &lc.chunk,
                &lc.mesh,
                lc.worldX(),
                lc.worldZ(),
                world.asBlockGetter(),
                ao_strategy,
                lighting_mode,
                meshing_mode,
            ) catch |err| {
                std.log.err("[PREGEN] mesh gen failed for chunk ({},{}): {}", .{ lc.cx, lc.cz, err });
                continue;
            };
            lc.state = .meshed;
            lc.mesh_dirty = false;
            lc.mesh_incremental_dirty = true;
            meshes += 1;
        }
    }

    // Ready? All cells inside the inner square must be .meshed.
    var cz: i32 = -inner_r;
    while (cz <= inner_r) : (cz += 1) {
        var cx: i32 = -inner_r;
        while (cx <= inner_r) : (cx += 1) {
            const key = world_mod.ChunkKey{ .cx = spawn_cx + cx, .cz = spawn_cz + cz };
            const lc = world.chunks.get(key) orelse return false;
            if (lc.state != .meshed or lc.mesh_dirty) return false;
        }
    }
    return true;
}

/// Teleport player to the first 1×2 air column at-or-above the current spawn_point.
/// This is the anti-griefing respawn: if someone places a block on spawn, the next
/// respawn finds the next clear Y slot instead of embedding the player in rock.
/// Build a 3×3 neighbour-snapshot array for an async chunk job. Each
/// non-center slot is filled with a c_allocator-owned Chunk clone if that
/// neighbour is present in the world map, or left null if missing. The
/// center slot is handled by the caller (null for gen+mesh, non-null for
/// mesh-only).
///
/// On error, any snapshots already allocated are freed and the error is
/// propagated — this is what keeps the partial-failure path leak-free.
fn buildNeighbourSnapshots(world: *const world_mod.World, cx: i32, cz: i32) ![8]?*chunk_mod.Chunk {
    var out: [8]?*chunk_mod.Chunk = .{ null, null, null, null, null, null, null, null };
    errdefer for (out) |slot| {
        if (slot) |p| async_chunks_mod.freeChunk(p);
    };

    var idx: usize = 0;
    var dcz: i32 = -1;
    while (dcz <= 1) : (dcz += 1) {
        var dcx: i32 = -1;
        while (dcx <= 1) : (dcx += 1) {
            if (dcx == 0 and dcz == 0) continue;
            const nk = world_mod.ChunkKey{ .cx = cx + dcx, .cz = cz + dcz };
            if (world.chunks.get(nk)) |nlc| {
                out[idx] = try async_chunks_mod.cloneChunk(&nlc.chunk);
            }
            idx += 1;
        }
    }
    return out;
}

/// Unpack a linear `[8]?*Chunk` (skipping center) into the full 9-slot
/// `[9]?*Chunk` layout the pipeline expects. Slot 4 is the center and is
/// filled by the caller.
fn expandNeighboursToFullGrid(n8: [8]?*chunk_mod.Chunk) [9]?*chunk_mod.Chunk {
    var full: [9]?*chunk_mod.Chunk = .{ null, null, null, null, null, null, null, null, null };
    // Input order: (dcx,dcz) iteration = (-1,-1),(0,-1),(1,-1),(-1,0),(1,0),(-1,1),(0,1),(1,1)
    // Grid indices: slot = (dcz+1)*3 + (dcx+1)
    const map = [8]usize{ 0, 1, 2, 3, 5, 6, 7, 8 };
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        full[map[i]] = n8[i];
    }
    return full;
}

/// Free a 9-slot snapshot grid (used when enqueue fails and we need to
/// roll back). Center is included because failure can happen after the
/// caller has populated it.
fn freeFullGrid(full: *[9]?*chunk_mod.Chunk) void {
    for (full) |*slot| {
        if (slot.*) |p| async_chunks_mod.freeChunk(p);
        slot.* = null;
    }
}

/// One async tick: drain completed results, install them, enqueue new jobs
/// (fresh chunks innermost-first + any dirty chunks whose 4 axial neighbours
/// are all present). Replaces the synchronous `world.update` + mesh loop.
fn asyncTick(p: *async_chunks_mod.Pipeline, world: *world_mod.World, player_pos: [3]f32, ao: gpu_mod.AOStrategy, lighting: gpu_mod.LightingMode, alloc: std.mem.Allocator) !void {
    const t_tick_start = perfNowNs();

    // ─── 1. Drain completed results ─────────────────────────────────────
    state.async_result_scratch.clearRetainingCapacity();
    try p.drainSorted(&state.async_result_scratch, alloc);
    const drained_count = state.async_result_scratch.items.len;

    for (state.async_result_scratch.items) |*r| {
        const key = world_mod.ChunkKey{ .cx = r.cx, .cz = r.cz };
        // Single-line per-chunk log for parity with the sync [MESH] line so
        // before/after comparison is trivial via `grep`. `kind` distinguishes
        // fresh gen+mesh from dirty-neighbour remesh.
        const kind_tag: []const u8 = if (r.chunk != null) "gen+mesh" else "mesh-only";
        std.log.info("[ASYNC] chunk ({},{}) {s} worker_us={} quads={}", .{
            r.cx,                             r.cz,
            kind_tag,                         r.worker_us,
            r.indices.len / 6,
        });
        if (r.chunk) |new_chunk| {
            // Gen+mesh result → install as a new LoadedChunk.
            if (world.chunks.contains(key)) {
                // Paranoia: drop the duplicate. Shouldn't happen because the
                // pipeline's in_flight set prevents double-enqueue and we
                // dedupe against `world.chunks.contains` at enqueue time,
                // but be defensive in case a future feature (re-load from
                // disk) races with this path.
                async_chunks_mod.releaseResult(r);
                continue;
            }
            const lc = try world.allocator.create(world_mod.LoadedChunk);
            lc.* = world_mod.LoadedChunk.init(world.allocator, r.cx, r.cz);
            lc.chunk = new_chunk.*;
            async_chunks_mod.freeChunk(new_chunk);
            try async_chunks_mod.installMeshFromResult(&lc.mesh, r);
            std.heap.c_allocator.free(r.vertices);
            std.heap.c_allocator.free(r.indices);
            std.heap.c_allocator.free(r.quad_block);
            std.heap.c_allocator.free(r.quad_highlight);
            lc.state = .meshed;
            lc.mesh_dirty = false;
            lc.mesh_incremental_dirty = true;
            try world.chunks.put(key, lc);

            // Mark the 4 axial neighbours dirty so they'll be re-enqueued
            // as mesh-only jobs next tick — same as the sync path.
            const adjacent = [_]world_mod.ChunkKey{
                .{ .cx = r.cx - 1, .cz = r.cz },
                .{ .cx = r.cx + 1, .cz = r.cz },
                .{ .cx = r.cx, .cz = r.cz - 1 },
                .{ .cx = r.cx, .cz = r.cz + 1 },
            };
            for (adjacent) |nk| {
                if (world.chunks.get(nk)) |nlc| {
                    nlc.mesh_dirty = true;
                }
            }
        } else {
            // Mesh-only result → replace the existing chunk's mesh buffers.
            if (world.chunks.get(key)) |lc| {
                async_chunks_mod.installMeshFromResult(&lc.mesh, r) catch |err| {
                    std.log.err("[ASYNC] mesh install failed for ({},{}): {}", .{ r.cx, r.cz, err });
                };
                lc.state = .meshed;
                lc.mesh_dirty = false;
                lc.mesh_incremental_dirty = true;
            }
            std.heap.c_allocator.free(r.vertices);
            std.heap.c_allocator.free(r.indices);
            std.heap.c_allocator.free(r.quad_block);
            std.heap.c_allocator.free(r.quad_highlight);
        }
    }
    state.async_result_scratch.clearRetainingCapacity();

    // ─── 2. Enqueue gen+mesh jobs for missing spiral-ring chunks ────────
    const player_cx = world_mod.chunkCoordOf(@as(i32, @intFromFloat(@floor(player_pos[0]))));
    const player_cz = world_mod.chunkCoordOf(@as(i32, @intFromFloat(@floor(player_pos[2]))));

    var enqueued_new: usize = 0;
    for (world.spiral_offsets) |off| {
        if (enqueued_new >= ASYNC_GEN_ENQUEUE_PER_TICK) break;
        const cx = player_cx + off.dx;
        const cz = player_cz + off.dz;
        if (world.chunks.contains(.{ .cx = cx, .cz = cz })) continue;
        if (p.isInFlight(cx, cz)) continue;

        const n8 = buildNeighbourSnapshots(world, cx, cz) catch |err| {
            std.log.err("[ASYNC] snapshot alloc failed for ({},{}): {}", .{ cx, cz, err });
            break;
        };
        var full = expandNeighboursToFullGrid(n8);
        // Center stays null — worker will generate it.

        const job = async_chunks_mod.Job{
            .cx = cx,
            .cz = cz,
            .gen_config = world.gen_config,
            .ao = ao,
            .lighting = lighting,
            .snapshots = full,
        };
        const ok = p.tryEnqueue(job) catch |err| {
            std.log.err("[ASYNC] enqueue gen+mesh ({},{}) failed: {}", .{ cx, cz, err });
            freeFullGrid(&full);
            break;
        };
        if (!ok) {
            // At cap or duplicate; roll back the snapshots and stop this tick.
            freeFullGrid(&full);
            break;
        }
        enqueued_new += 1;
    }

    // ─── 3. Enqueue mesh-only jobs for dirty chunks with all 4 axials ───
    var enqueued_mesh: usize = 0;
    var it = world.chunks.iterator();
    while (it.next()) |entry| {
        if (enqueued_mesh >= ASYNC_MESH_ONLY_ENQUEUE_PER_TICK) break;
        const lc = entry.value_ptr.*;
        if (!lc.mesh_dirty) continue;
        if (!world.hasAllNeighborsGenerated(lc.cx, lc.cz)) continue;
        if (p.isInFlight(lc.cx, lc.cz)) continue;

        const n8 = buildNeighbourSnapshots(world, lc.cx, lc.cz) catch |err| {
            std.log.err("[ASYNC] mesh-only snapshot alloc failed for ({},{}): {}", .{ lc.cx, lc.cz, err });
            break;
        };
        var full = expandNeighboursToFullGrid(n8);
        // Center = snapshot of the existing chunk (mesh-only signals worker
        // to skip regeneration and use this Chunk as the mesh target).
        full[4] = async_chunks_mod.cloneChunk(&lc.chunk) catch |err| {
            std.log.err("[ASYNC] mesh-only center snapshot alloc failed for ({},{}): {}", .{ lc.cx, lc.cz, err });
            freeFullGrid(&full);
            break;
        };

        const job = async_chunks_mod.Job{
            .cx = lc.cx,
            .cz = lc.cz,
            .gen_config = world.gen_config,
            .ao = ao,
            .lighting = lighting,
            .snapshots = full,
        };
        const ok = p.tryEnqueue(job) catch |err| {
            std.log.err("[ASYNC] enqueue mesh-only ({},{}) failed: {}", .{ lc.cx, lc.cz, err });
            freeFullGrid(&full);
            break;
        };
        if (!ok) {
            freeFullGrid(&full);
            break;
        }
        // Optimistically clear the dirty flag so we don't re-enqueue the
        // same chunk on the next tick while the current job is in flight.
        // If new neighbour changes arrive during the job, the drain step
        // will re-set dirty when the result lands — EXCEPT nothing does
        // that today. Phase 1 accepts this: the regression TAS scripts
        // don't exercise the case. Follow-up: add versioning if needed.
        lc.mesh_dirty = false;
        enqueued_mesh += 1;
    }

    // ─── 4. Per-tick main-thread cost summary ───────────────────────────
    // Only log on ticks where we actually did something — otherwise this
    // fires every tick and drowns the rest of the log output. The reported
    // figure includes drain+install memcpy and enqueue-time snapshot
    // memcpy. It does NOT include the mesh upload (that happens in the
    // render callback) but uploads are cheap.
    if (drained_count > 0 or enqueued_new > 0 or enqueued_mesh > 0) {
        const tick_us: u64 = @intCast(@divTrunc(perfNowNs() - t_tick_start, 1000));
        std.log.info("[ASYNC] main thread work: drained={} enq_new={} enq_mesh={} main_us={}", .{
            drained_count,
            enqueued_new,
            enqueued_mesh,
            tick_us,
        });
    }
}

/// Returns true when the async pipeline has no pending work — nothing in
/// flight, nothing queued, no dirty chunks still needing remesh. Used by the
/// dump-frame gate to wait for the world to fully converge before capturing.
fn asyncHasPendingWork(p: *async_chunks_mod.Pipeline, world: *const world_mod.World) bool {
    if (p.inFlightCount() > 0) return true;
    var it = world.chunks.iterator();
    while (it.next()) |entry| {
        const lc = entry.value_ptr.*;
        if (lc.mesh_dirty and world.hasAllNeighborsGenerated(lc.cx, lc.cz)) return true;
    }
    return false;
}

fn doRespawn() void {
    const resolved = resolveSpawnPos(&state.world, state.spawn_point);
    state.player.feet_pos = resolved;
    state.player.velocity = .{ 0, 0, 0 };
    state.player.on_ground = false;
    syncCameraToPlayer();
    std.log.info("Respawned at ({d:.1}, {d:.1}, {d:.1})", .{
        resolved[0], resolved[1], resolved[2],
    });
}

/// Flush one per-tick row to the --profile-csv file. Called from a `defer`
/// at the top of voxelRender so every render path — including the
/// world_loading early-return — contributes a row. The row includes
/// chunk_w so downstream analysis can join baseline and experiment CSVs
/// without reading the filenames.
fn flushProfileRow(ctx: *sw.Context) void {
    if (comptime is_wasm) return;
    const f = state.profile_csv_file orelse return;
    // Tick time measured from the tick_t0_ns captured at the top of voxelTick
    // to now (end of render). This bundles tick+render into one "frame" cost,
    // which is what we actually care about for the "see it be slow" metric.
    const now = perfNowNs();
    const tick_ns: u64 = if (state.tick_t0_ns != 0) @intCast(now - state.tick_t0_ns) else 0;
    const render_ns: u64 = if (state.render_t0_ns != 0) @intCast(now - state.render_t0_ns) else 0;
    const tick_id = ctx.tickId();
    const loading: u8 = if (state.world_loading) 1 else 0;
    // Record first-paint tick the first time we run render with loading == 0.
    if (!state.world_loading and state.first_paint_tick == null) {
        state.first_paint_tick = tick_id;
        std.log.info("[PROFILE] first-paint tick={} chunk_w={}", .{ tick_id, chunk_mod.CHUNK_W });
    }
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(
        &buf,
        "{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d}\n",
        .{
            tick_id,
            loading,
            chunk_mod.CHUNK_W,
            tick_ns,
            state.gen_ns,
            state.gen_count,
            state.mesh_ns,
            state.mesh_count,
            state.upload_ns,
            state.upload_count,
            render_ns,
        },
    ) catch return;
    _ = f.writeAll(line) catch {};
}

/// Cheap helper used by the --profile-csv pregen-timing code: returns the
/// number of LoadedChunks currently in `.meshed` state. O(n) over the loaded
/// set, called at most twice per tick during pregen and never during
/// gameplay — no need to maintain a cached count.
fn countMeshedChunks(world: *world_mod.World) usize {
    var n: usize = 0;
    var it = world.chunks.valueIterator();
    while (it.next()) |lc_ptr| {
        if (lc_ptr.*.state == .meshed) n += 1;
    }
    return n;
}

fn voxelTick(ctx: *sw.Context) !void {
    // --profile-csv: reset per-tick accumulators at the top so every phase
    // we time inside this tick (world.update gen, mesh loop, and the pregen
    // fast path during world loading) accumulates into a fresh row. render
    // adds upload_ns then flushes the row.
    if (state.profile_csv_file != null) {
        state.tick_t0_ns = perfNowNs();
        state.tick_ns = 0;
        state.gen_ns = 0;
        state.gen_count = 0;
        state.mesh_ns = 0;
        state.mesh_count = 0;
    }

    // ====================================================================
    // World loading branch: pregen ring around spawn, mesh inner square,
    // release player. Runs while state.world_loading is true. No gameplay
    // input is processed. The render loop shows the loading overlay.
    // ====================================================================
    if (state.world_loading) {
        const spawn_bx: i32 = @intFromFloat(@floor(state.spawn_point[0]));
        const spawn_bz: i32 = @intFromFloat(@floor(state.spawn_point[2]));
        const spawn_cx = world_mod.chunkCoordOf(spawn_bx);
        const spawn_cz = world_mod.chunkCoordOf(spawn_bz);

        // Count pregen gen+mesh into the per-tick profile accumulators. The
        // pregen path bypasses the gameplay mesh loop so we can't reuse the
        // counters added below; we measure the whole pregenStep as a single
        // gen+mesh bundle and split it by diffing chunk count and ring
        // meshed-count before/after.
        const pregen_gen_before: usize = if (state.profile_csv_file != null) state.world.chunks.count() else 0;
        const pregen_mesh_before: usize = if (state.profile_csv_file != null) countMeshedChunks(&state.world) else 0;
        const pregen_t0: i128 = if (state.profile_csv_file != null) perfNowNs() else 0;
        const ring_ready = pregenStep(&state.world, spawn_cx, spawn_cz, state.ao_strategy, state.lighting_mode, state.meshing_mode) catch |err| blk: {
            std.log.err("Pregen step failed: {}", .{err});
            break :blk false;
        };
        if (state.profile_csv_file != null) {
            const pregen_t1 = perfNowNs();
            const dt_ns: u64 = @intCast(pregen_t1 - pregen_t0);
            const gen_after = state.world.chunks.count();
            const mesh_after = countMeshedChunks(&state.world);
            const gens_this_tick: u32 = @intCast(gen_after - pregen_gen_before);
            const meshes_this_tick: u32 = @intCast(mesh_after - pregen_mesh_before);
            // Split the pregen wall time proportionally between gen and mesh
            // phases. Not perfect but good enough to separate the two big
            // costs in the CSV — the exact split matters less than knowing
            // "meshing dominated this tick" vs "generation dominated".
            const total_ops = gens_this_tick + meshes_this_tick;
            if (total_ops > 0) {
                const gen_ns_approx: u64 = dt_ns * gens_this_tick / total_ops;
                state.gen_ns +%= gen_ns_approx;
                state.mesh_ns +%= dt_ns - gen_ns_approx;
            } else {
                state.gen_ns +%= dt_ns;
            }
            state.gen_count +%= gens_this_tick;
            state.mesh_count +%= meshes_this_tick;
        }
        if (!ring_ready) {
            // Still generating/meshing the spawn ring — keep the loading
            // screen visible and run pregenStep again next tick.
            return;
        }

        // Pregen complete: resolve spawn, place player, unlock world.
        // First-ever spawn this session: reset spawn Y to the heightmap
        // surface ("overworld Y") so we don't attempt to start from a Y
        // embedded in rock on hilly worlds.
        if (!state.spawn_resolved) {
            const surf = surfaceFeetY(&state.world, spawn_bx, spawn_bz);
            state.spawn_point[1] = @as(f32, @floatFromInt(surf));
            std.log.info("First-spawn: heightmap surface feet Y={} at ({},{})", .{
                surf, spawn_bx, spawn_bz,
            });
        }

        const resolved = resolveSpawnPos(&state.world, state.spawn_point);

        // Safety net: never un-gate loading with the player inside solid.
        const fbx: i32 = @intFromFloat(@floor(resolved[0]));
        const fby: i32 = @intFromFloat(@floor(resolved[1]));
        const fbz: i32 = @intFromFloat(@floor(resolved[2]));
        std.debug.assert(state.world.getBlock(fbx, fby, fbz) == .air);
        std.debug.assert(state.world.getBlock(fbx, fby + 1, fbz) == .air);

        state.player.feet_pos = resolved;
        state.player.velocity = .{ 0, 0, 0 };
        state.player.on_ground = false;
        state.spawn_point = resolved;
        state.spawn_resolved = true;
        state.world_loading = false;
        syncCameraToPlayer();
        std.log.info("World ready — spawned at ({d:.1}, {d:.1}, {d:.1})", .{
            resolved[0], resolved[1], resolved[2],
        });

        // Remap TAS event tick_ids so tick 1 = first post-loading tick.
        if (state.tas_replayer) |*r| {
            if (r.state == .stopped) {
                const offset: u64 = ctx.tickId() + 1;
                for (r.events.items) |*ev| {
                    ev.tick_id += offset;
                }
                if (!state.tas_step_mode) {
                    r.play();
                }
                std.log.info("TAS replayer: remapped event tick_ids by +{} and started", .{offset});
            }
        }

        // Skip gameplay input on the unlock tick — input starts next tick.
        return;
    }

    var tick_mesh_us: i128 = 0;
    var tick_mesh_chunks: usize = 0;
    var chunks_generated_this_tick: usize = 0;
    var t_world_update_us: i128 = 0;

    // Player chunk coords — used by the mesh-radius gate and eviction pass.
    const player_cx = world_mod.chunkCoordOf(@as(i32, @intFromFloat(@floor(state.player.feet_pos[0]))));
    const player_cz = world_mod.chunkCoordOf(@as(i32, @intFromFloat(@floor(state.player.feet_pos[2]))));

    if (comptime is_wasm) {
        // WASM: always sync path
    } else if (state.async_chunks_enabled and state.async_pipeline != null) {
        // Async path: worker thread owns gen + mesh. Main thread only
        // drains results, installs them, and enqueues new work.
        try asyncTick(
            state.async_pipeline.?,
            &state.world,
            state.player.feet_pos,
            state.ao_strategy,
            state.lighting_mode,
            ctx.allocator(),
        );
    } else {
        // Update world: load chunks progressively around active region anchors.
        // The player is currently the only anchor. This is the async background
        // fill that keeps the outer ring growing as the player walks.
        const gen_before: usize = if (state.profile_csv_file != null) state.world.chunks.count() else 0;
        const gen_t0: i128 = if (state.profile_csv_file != null) perfNowNs() else 0;
        try state.world.update(&[_]world_mod.RegionAnchor{
            .{ .position = state.player.feet_pos },
        });
        {
            const gen_t1 = perfNowNs();
            t_world_update_us = @divTrunc(gen_t1 - gen_t0, 1000);
            const gen_after = state.world.chunks.count();
            chunks_generated_this_tick = gen_after - gen_before;
            if (state.profile_csv_file != null) {
                state.gen_ns +%= @intCast(gen_t1 - gen_t0);
                state.gen_count +%= @intCast(gen_after - gen_before);
            }
        }

        // Generate meshes for dirty chunks — runs in tick so render frames stay smooth.
        // Gated by:
        //   1. `mesh_dirty` (something asked for a rebuild),
        //   2. `hasAllNeighborsGenerated` (no seam-hole risk),
        //   3. distance² ≤ MESH_RADIUS_SQ (don't waste cycles meshing chunks that
        //      are about to be evicted, or that have just been evicted and are
        //      sitting in the hysteresis dead zone with `mesh_dirty = true`).
        {
        var mesh_gens: usize = 0;
        var it = state.world.chunks.iterator();
        while (it.next()) |entry| {
            if (mesh_gens >= MESH_GENS_PER_TICK) break;
            const lc = entry.value_ptr.*;
            if (!lc.mesh_dirty) continue;
            const dcx = lc.cx - player_cx;
            const dcz = lc.cz - player_cz;
            if (dcx * dcx + dcz * dcz > world_mod.MESH_RADIUS_SQ) continue;
            if (!state.world.hasAllNeighborsGenerated(lc.cx, lc.cz)) continue;
            const t0 = perfNowNs();
            mesher_mod.generateMeshForMode(
                &lc.chunk,
                &lc.mesh,
                lc.worldX(),
                lc.worldZ(),
                state.world.asBlockGetter(),
                state.ao_strategy,
                state.lighting_mode,
                state.meshing_mode,
            ) catch |err| {
                std.log.err("Mesh gen failed for chunk ({},{}): {}", .{ lc.cx, lc.cz, err });
                continue;
            };
            const mesh_dt_ns: i128 = perfNowNs() - t0;
            const t_us = @divTrunc(mesh_dt_ns, 1000);
            std.log.info("[MESH] chunk ({},{}) gen={}us quads={}", .{ lc.cx, lc.cz, t_us, lc.mesh.indices.items.len / 6 });
            if (state.profile_csv_file != null) {
                state.mesh_ns +%= @intCast(mesh_dt_ns);
                state.mesh_count +%= 1;
            }
            lc.state = .meshed;
            lc.mesh_dirty = false;
            lc.mesh_incremental_dirty = true;
            mesh_gens += 1;
            tick_mesh_us += t_us;
            tick_mesh_chunks += 1;
        }
    }
    }

    // ====================================================================
    // Mesh eviction — drop GPU + host mesh storage for chunks that have
    // wandered outside the eviction radius.
    //
    // Design notes (long form lives in `world.zig` next to EVICT_RADIUS_SQ
    // and in `examples/voxel/docs/memory.md` § "Mesh eviction"):
    //
    //   - Cheap enough to run every tick: a typical session has ~50 loaded
    //     chunks, each check is two int multiplies + a hashmap lookup.
    //   - Hysteresis: mesh-eligible inside MESH_RADIUS_SQ (= 16 for R=4),
    //     evict outside EVICT_RADIUS_SQ (= 25). Dead zone 17..25 prevents
    //     boundary-wobble flicker.
    //   - On eviction we (a) destroy GPU vertex+index buffers and drop the
    //     entry from `state.chunk_gpu`, then (b) call `evictMesh` on the
    //     LoadedChunk to free its host mesh ArrayLists. The block + skylight
    //     grids stay in RAM.
    //   - Re-entry path: a chunk that's been evicted has `state = .generated`
    //     and `mesh_dirty = true`. When the player walks back inside the
    //     mesh disc, the gated mesh loop above picks it up automatically on
    //     the next tick — no separate code path needed.
    {
        var evicted_this_tick: usize = 0;
        var it = state.world.chunks.valueIterator();
        while (it.next()) |lc_ptr| {
            const lc = lc_ptr.*;
            if (lc.state != .meshed) continue;
            const dcx = lc.cx - player_cx;
            const dcz = lc.cz - player_cz;
            if (dcx * dcx + dcz * dcz <= world_mod.EVICT_RADIUS_SQ) continue;

            // Drop GPU buffers if any are bound. The chunk_gpu entry can be
            // absent (e.g. chunk was meshed this tick but the upload pass
            // hasn't run yet); that's fine — the host-side eviction below
            // is still safe.
            if (state.chunk_gpu.fetchRemove(.{ .cx = lc.cx, .cz = lc.cz })) |kv| {
                if (kv.value.vertex_buffer) |buf| buf.destroy();
                if (kv.value.index_buffer) |buf| buf.destroy();
            }

            lc.evictMesh();
            evicted_this_tick += 1;
        }
        if (evicted_this_tick > 0) {
            std.log.info("[EVICT] {} chunk(s) downgraded to .generated this tick", .{evicted_this_tick});
        }
    }

    // Periodic chunk-state stats so we can verify the eviction loop is
    // actually doing work during a play session. 240 ticks ≈ 2 s at the
    // default 120 Hz sim rate; in headless TAS runs (unlimited tick rate)
    // this still fires roughly once per "TAS second" of script time, which
    // is enough to confirm the counts on the regressions.
    if (ctx.tickId() % 240 == 0) {
        var meshed_count: usize = 0;
        var generated_count: usize = 0;
        var sit = state.world.chunks.valueIterator();
        while (sit.next()) |lc_ptr| {
            switch (lc_ptr.*.state) {
                .meshed => meshed_count += 1,
                .generated => generated_count += 1,
            }
        }
        std.log.info("[CHUNK_STATS] meshed={} generated-only={} total={}", .{
            meshed_count,
            generated_count,
            meshed_count + generated_count,
        });
    }

    // Per-tick spike summary: emit whenever generation or meshing ran this tick.
    if (chunks_generated_this_tick > 0 or tick_mesh_chunks > 0) {
        std.log.info("[SPIKE_TICK] tick={} gen_chunks={} gen_total={}us mesh_chunks={} mesh_total={}us total={}us", .{
            ctx.tickId(),
            chunks_generated_this_tick,
            t_world_update_us,
            tick_mesh_chunks,
            tick_mesh_us,
            t_world_update_us + tick_mesh_us,
        });
    }

    // TAS playback status + headless auto-shutdown when script completes
    if (state.tas_replayer) |*replayer| {
        if (ctx.tickId() % 60 == 0) {
            std.log.info("TAS playback: tick={} state={}", .{ ctx.tickId(), replayer.state });
        }
        if (state.headless and replayer.state == .finished) {
            std.log.info("TAS finished at tick={} — requesting headless shutdown", .{ctx.tickId()});
            ctx.requestShutdown();
            return;
        }
    }

    const input = ctx.input();
    const dt = @as(f32, @floatFromInt(ctx.dtNs())) / 1_000_000_000.0;

    // Snapshot capture state BEFORE global keys modify it.
    // was_captured = false on the tick we resume from pause → prevents camera jump.
    const was_captured = state.mouse_captured;

    // =========================================================================
    // 1. Global keys — always processed regardless of layer state
    // =========================================================================
    if (input.keyPressed(.Escape)) {
        if (state.game_state.isLayerActive(.pause_menu)) {
            // Esc inside the pause menu: contextual pop. Sub-screens go back to main;
            // main closes the menu and resumes gameplay.
            switch (state.menu_screen) {
                .main => {
                    state.game_state.togglePauseMenu();
                    if (state.paused_with_mouse) {
                        ctx.setMouseCapture(true);
                        state.mouse_captured = true;
                        state.paused_with_mouse = false;
                    }
                    std.log.info("Resumed (ESC)", .{});
                },
                .settings, .exit_confirm => {
                    state.menu_screen = .main;
                    std.log.info("Menu: -> main (ESC)", .{});
                },
            }
        } else {
            // Open menu: save mouse state, release the mouse, reset to main screen at top.
            state.paused_with_mouse = state.mouse_captured;
            state.game_state.togglePauseMenu();
            state.menu_screen = .main;
            state.menu_main_idx = 0;
            if (state.mouse_captured) {
                ctx.setMouseCapture(false);
                state.mouse_captured = false;
            }
            std.log.info("Paused (ESC) -> main", .{});
        }
    }

    // Cmd+V (macOS) / Ctrl+V (Windows/Linux) — cycle camera view
    if (input.keyPressed(.V) and (input.mods.super or input.mods.ctrl)) {
        state.camera_view = state.camera_view.next();
        std.log.info("Camera: {s}", .{state.camera_view.label()});
    }

    // Cmd+D (macOS) / Ctrl+D (Windows/Linux) — toggle debug mode (shows hitbox cylinder)
    if (input.keyPressed(.D) and (input.mods.super or input.mods.ctrl)) {
        state.debug_mode = !state.debug_mode;
        std.log.info("Debug mode: {}", .{state.debug_mode});
    }

    // Cmd+G (macOS) / Ctrl+G (Windows/Linux) — toggle GPU debug (highlight rebuilt faces)
    if (input.keyPressed(.G) and (input.mods.super or input.mods.ctrl)) {
        state.gpu_debug = !state.gpu_debug;
        std.log.info("GPU debug: {}", .{state.gpu_debug});
    }

    // Cmd+F (macOS) / Ctrl+F (Windows/Linux) — freeze / un-freeze the cull
    // frustum at the current camera transform. Pressing Cmd+F while the
    // frustum is already frozen un-freezes it.
    //
    // Note: the spec sketch suggested F3 for this toggle, but the voxel-demo
    // CLAUDE.md forbids function keys (they're not on the keyboard HUD and
    // not reliable cross-platform). Cmd+F slots in next to the existing
    // Cmd+D / Cmd+G / Cmd+S / Cmd+V combos.
    if (input.keyPressed(.F) and (input.mods.super or input.mods.ctrl)) {
        if (state.frozen_frustum) |_| {
            state.frozen_frustum = null;
            std.log.info("Frustum freeze: OFF (live frustum)", .{});
        } else {
            const eye = [3]f32{
                state.camera.position.x,
                state.camera.position.y,
                state.camera.position.z,
            };
            const fwd_v = state.camera.forward();
            const fwd = [3]f32{ fwd_v.x, fwd_v.y, fwd_v.z };
            state.frozen_frustum = frustum_mod.Frustum.capture(
                eye,
                fwd,
                state.frustum_fov_deg,
                world_mod.RENDER_DISTANCE,
            );
            std.log.info("Frustum freeze: ON @ ({d:.1},{d:.1},{d:.1}) fwd=({d:.2},{d:.2},{d:.2})", .{
                eye[0], eye[1], eye[2], fwd[0], fwd[1], fwd[2],
            });
        }
    }

    // Cmd+S (macOS) / Ctrl+S (Windows/Linux) — set spawn point to current position (debug override)
    if (input.keyPressed(.S) and (input.mods.super or input.mods.ctrl)) {
        state.spawn_point = state.player.feet_pos;
        std.log.info("Spawn point set to ({d:.1}, {d:.1}, {d:.1})", .{
            state.spawn_point[0], state.spawn_point[1], state.spawn_point[2],
        });
    }

    // R — manual respawn at spawn_point (uses first-air-above logic)
    if (input.keyPressed(.R) and !input.mods.ctrl and !input.mods.super) {
        doRespawn();
    }

    // TAS step mode: Right arrow = queue next step (executed in preTick next tick).
    // Events are remapped to the current sim tick_id so eventsForTick() picks them up.
    if (state.tas_step_mode) {
        if (state.tas_replayer) |*replayer| {
            if (input.keyPressed(.Right)) {
                if (replayer.state != .finished) {
                    state.tas_step_pending = true;
                } else {
                    std.log.info("[STEP] TAS finished — no more ticks to step", .{});
                }
            }
            if (input.keyPressed(.Left)) {
                std.log.info("[STEP] Rewind not supported yet", .{});
            }
        }
    }

    // =========================================================================
    // 2. Pause menu input — only when pause menu is showing
    // =========================================================================
    // Keyboard nav only. Mouse clicks on menu entries are intentionally not wired —
    // see voxel TODO #4. Up/Down navigates within the current screen (with wraparound),
    // Left/Right cycles values for value-picker entries on the Settings screen,
    // Enter activates, and Esc is handled in the global keys block above.
    if (state.game_state.isLayerActive(.pause_menu)) {
        const sel_ptr: *u8 = switch (state.menu_screen) {
            .main => &state.menu_main_idx,
            .settings => &state.menu_settings_idx,
            .exit_confirm => &state.menu_exit_idx,
        };
        const count = menuEntryCount(state.menu_screen);

        // Up/Down: move selection with wraparound.
        if (input.keyPressed(.Up)) {
            sel_ptr.* = if (sel_ptr.* == 0) count - 1 else sel_ptr.* - 1;
        }
        if (input.keyPressed(.Down)) {
            sel_ptr.* = (sel_ptr.* + 1) % count;
        }

        // Left/Right: only meaningful on the Settings screen for value-picker entries.
        if (state.menu_screen == .settings) {
            const left = input.keyPressed(.Left);
            const right = input.keyPressed(.Right);
            if (left or right) {
                const dir: i32 = if (right) 1 else -1;
                cycleSettingsValue(state.menu_settings_idx, dir);
                // AA Method toggle changes the row count (the method-specific
                // quality row appears/disappears). Clamp the selection so the
                // cursor can't end up past the new last row.
                const cnt = settingsEntryCount();
                if (state.menu_settings_idx >= cnt) state.menu_settings_idx = cnt - 1;
            }
        }

        // Enter: activate current entry.
        if (input.keyPressed(.Enter)) {
            switch (state.menu_screen) {
                .main => switch (state.menu_main_idx) {
                    0 => {
                        // Resume
                        state.game_state.togglePauseMenu();
                        if (state.paused_with_mouse) {
                            ctx.setMouseCapture(true);
                            state.mouse_captured = true;
                            state.paused_with_mouse = false;
                        }
                        std.log.info("Resumed (ENTER)", .{});
                    },
                    1 => {
                        // Settings
                        state.menu_screen = .settings;
                        state.menu_settings_idx = 0;
                        std.log.info("Menu: -> settings", .{});
                    },
                    2 => {
                        // Exit -> confirm screen, default to "No"
                        state.menu_screen = .exit_confirm;
                        state.menu_exit_idx = 0;
                        std.log.info("Menu: -> exit_confirm", .{});
                    },
                    else => {},
                },
                .settings => {
                    // Dynamic layout — resolve the entry via settingsEntryAt
                    // so the active index is interpreted through the same
                    // method-aware lens as rendering and left/right cycling.
                    const entry = settingsEntryAt(state.menu_settings_idx);
                    if (entry == .back) {
                        state.menu_screen = .main;
                        std.log.info("Menu: -> main (Back)", .{});
                    } else {
                        // Pickers: Enter cycles forward (same as Right) so a
                        // one-key workflow works on keyboards without arrows.
                        cycleSettingsValue(state.menu_settings_idx, 1);
                        // AA method toggle can shrink/grow the menu (the
                        // quality row appears/disappears). Clamp the
                        // selection so navigation doesn't wrap off the end.
                        const cnt = settingsEntryCount();
                        if (state.menu_settings_idx >= cnt) state.menu_settings_idx = cnt - 1;
                    }
                },
                .exit_confirm => switch (state.menu_exit_idx) {
                    0 => {
                        // No -> back to main
                        state.menu_screen = .main;
                        std.log.info("Menu: -> main (No)", .{});
                    },
                    1 => {
                        // Yes -> exit
                        std.log.info("Quit (ENTER on confirm)", .{});
                        fatalExit(0);
                    },
                    else => {},
                },
            }
        }
    }

    // =========================================================================
    // 3. Gameplay input — only when no captures_all layer above gameplay
    // =========================================================================
    // In TAS step mode, only allow gameplay during the ONE tick when TAS events are executing.
    // All other ticks: game is frozen (no physics, no input) until next Right arrow press.
    const gameplay_ok = state.game_state.gameplayReceivesInput() and
        (!state.tas_step_mode or state.tas_step_executing);
    if (gameplay_ok) {
        // Hotbar selection — number keys 1..9 select slots 0..8, 0 selects
        // slot 9 (matches Minecraft's bottom-row layout). Done before the
        // mouse-capture gate so the player can change slot even while still
        // in "click to capture" state. Modifier-held presses are ignored so
        // Cmd+1 / Ctrl+1 stay free for future shortcuts.
        if (!input.mods.ctrl and !input.mods.super) {
            const num_keys = [_]struct { k: core.KeyCode, slot: u8 }{
                .{ .k = .Num1, .slot = 0 },
                .{ .k = .Num2, .slot = 1 },
                .{ .k = .Num3, .slot = 2 },
                .{ .k = .Num4, .slot = 3 },
                .{ .k = .Num5, .slot = 4 },
                .{ .k = .Num6, .slot = 5 },
                .{ .k = .Num7, .slot = 6 },
                .{ .k = .Num8, .slot = 7 },
                .{ .k = .Num9, .slot = 8 },
                .{ .k = .Num0, .slot = 9 },
            };
            for (num_keys) |nk| {
                if (input.keyPressed(nk.k)) {
                    state.hotbar_selected = nk.slot;
                    std.log.info("Hotbar: slot {} selected ({s})", .{
                        nk.slot + 1,
                        @tagName(state.hotbar_slots[nk.slot]),
                    });
                }
            }
        }

        // Click to capture mouse (first click after startup / after resume)
        if (!state.mouse_captured and input.buttonPressed(.left)) {
            state.mouse_captured = true;
            ctx.setMouseCapture(true);
            std.log.info("Mouse captured (clicked)", .{});
        }

        // WASD + physics (only when mouse is captured)
        if (state.mouse_captured) {
            var fwd: f32 = 0;
            var rgt: f32 = 0;

            // Suppress movement when Ctrl or Cmd/Super is held — these start a "mode"
            // (e.g. Ctrl+D = debug toggle, Cmd+D = debug toggle on macOS).
            if (!input.mods.ctrl and !input.mods.super) {
                if (input.keyDown(.W)) fwd += 1;
                if (input.keyDown(.S)) fwd -= 1;
                if (input.keyDown(.D)) rgt += 1;
                if (input.keyDown(.A)) rgt -= 1;
            }

            const jump = input.keyPressed(.Space);
            const space_held = input.keyDown(.Space);
            const sprint = input.keyDown(.Shift);

            state.player.tick(state.world.asBlockGetter(), dt, state.camera.yaw, fwd, rgt, jump, space_held, sprint);

            // Void death: fell below the world → respawn at spawn_point.
            if (state.player.feet_pos[1] < -10.0) {
                std.log.info("Void death at Y={d:.1}", .{state.player.feet_pos[1]});
                doRespawn();
            }

            // Sync camera position to player eye, offset by camera view.
            // For 3PV, raymarch from the eye toward the desired camera spot
            // and stop short of any solid voxel (see camera_clip.zig) so the
            // camera can never end up clipped into a wall — fixes an exploit
            // where wedging the camera partway into a block left the clipped
            // sliver see-through.
            const eye = state.player.eyePos();
            const fwd_vec = state.camera.forward();
            const cam_dist: f32 = 4.0;
            const solid_world = IsSolidWorld{ .world = &state.world };
            switch (state.camera_view) {
                .first_person => {
                    state.camera.position = Vec3.init(eye[0], eye[1], eye[2]);
                },
                .third_person_back => {
                    const d = camera_clip.safeCameraDistance(
                        solid_world,
                        eye[0],
                        eye[1],
                        eye[2],
                        -fwd_vec.x,
                        -fwd_vec.y,
                        -fwd_vec.z,
                        cam_dist,
                        CAMERA_CLIP_SKIN,
                    );
                    state.camera.position = Vec3.init(
                        eye[0] - fwd_vec.x * d,
                        eye[1] - fwd_vec.y * d,
                        eye[2] - fwd_vec.z * d,
                    );
                },
                .third_person_front => {
                    const d = camera_clip.safeCameraDistance(
                        solid_world,
                        eye[0],
                        eye[1],
                        eye[2],
                        fwd_vec.x,
                        fwd_vec.y,
                        fwd_vec.z,
                        cam_dist,
                        CAMERA_CLIP_SKIN,
                    );
                    state.camera.position = Vec3.init(
                        eye[0] + fwd_vec.x * d,
                        eye[1] + fwd_vec.y * d,
                        eye[2] + fwd_vec.z * d,
                    );
                },
            }
        }

        // Mouse look + block interaction — only when was already captured this tick
        // (was_captured = false on resume tick prevents camera jump)
        if (was_captured) {
            state.camera.rotate(
                input.mouse.delta_x,
                -input.mouse.delta_y, // Invert Y for natural feel
            );

            // Raycast from player eye (not camera) — in third-person the camera is
            // pulled back, but interaction should always be from the player's perspective.
            const cam_dir = state.camera.forward();
            const eye_pos = state.player.eyePos();
            const ray_origin = Vec3.init(eye_pos[0], eye_pos[1], eye_pos[2]);
            const hit = worldRaycast(&state.world, ray_origin, cam_dir, 5.0);

            if (hit.hit) {
                state.hover_block = hit.block_pos;

                // Left click: destroy block on the DOWN edge (buttonPressed = press,
                // not release) so the action fires the instant SDL hands us the
                // mouseDown event. Acting on release would add another full click
                // duration of perceived latency. macOS Trackpad still adds an
                // unavoidable ~80–120 ms tap-to-click delay at the OS level — that's
                // a system pref, not something we can fix in code. See the
                // "macOS Trackpad Click Latency" section of swindowzig/CLAUDE.md.
                if (input.buttonPressed(.left)) {
                    const bx: i32 = @intFromFloat(hit.block_pos.x);
                    const by: i32 = @intFromFloat(hit.block_pos.y);
                    const bz: i32 = @intFromFloat(hit.block_pos.z);
                    _ = try state.world.setBlock(bx, by, bz, .air);
                    const cam_pos_arr = [3]f32{ state.camera.position.x, state.camera.position.y, state.camera.position.z };
                    if (state.world.getChunkAtBlock(bx, bz)) |lc| {
                        const lcx = world_mod.chunkCoordOf(bx);
                        const lcz = world_mod.chunkCoordOf(bz);
                        const lbx = bx - lcx * chunk_mod.CHUNK_W;
                        const lbz = bz - lcz * chunk_mod.CHUNK_W;
                        if (state.meshing_mode == .greedy) {
                            // Greedy quads span multiple blocks, so the
                            // `quad_block` parallel array lookup used by
                            // `updateForBlockChange` can't isolate what to
                            // rebuild. Flag the chunk dirty and let the full
                            // regen pick it up next tick.
                            lc.mesh_dirty = true;
                            std.log.info("[TICK  tick={d:4}] greedy remove ({},{},{}) mesh_dirty=true", .{ ctx.tickId(), bx, by, bz });
                        } else {
                            const t_incr0 = perfNowNs();
                            lc.mesh.updateForBlockChange(
                                &lc.chunk,
                                lbx,
                                by,
                                lbz,
                                cam_pos_arr,
                                lc.worldX(),
                                lc.worldZ(),
                                state.world.asBlockGetter(),
                                state.ao_strategy,
                                state.lighting_mode,
                            ) catch |err| {
                                std.log.err("Incremental mesh update failed: {} — falling back to full regen", .{err});
                                lc.mesh_dirty = true;
                            };
                            lc.mesh_incremental_dirty = true;
                            const t_incr_us = @divTrunc(perfNowNs() - t_incr0, 1000);
                            std.log.info("[TICK  tick={d:4}] incremental remove ({},{},{}) update={}us", .{ ctx.tickId(), bx, by, bz, t_incr_us });
                        }
                    }
                    updateBoundaryNeighbors(&state.world, bx, by, bz, cam_pos_arr);
                }

                // Right click: place the currently-selected hotbar block on
                // the adjacent face. Skipped silently if the slot is empty
                // (.air) or if the placement position would intersect the
                // player's own AABB — we never want to embed the player
                // inside their own block since the next collision pass
                // would resolve them in an unpredictable direction.
                if (input.buttonPressed(.right)) place_blk: {
                    const sel_block = state.hotbar_slots[state.hotbar_selected];
                    if (sel_block == .air) {
                        std.log.info("Hotbar: slot {} is empty — nothing to place", .{state.hotbar_selected + 1});
                        break :place_blk;
                    }
                    const place_pos = Vec3.init(
                        hit.block_pos.x + hit.face_normal.x,
                        hit.block_pos.y + hit.face_normal.y,
                        hit.block_pos.z + hit.face_normal.z,
                    );
                    const px: i32 = @intFromFloat(place_pos.x);
                    const py: i32 = @intFromFloat(place_pos.y);
                    const pz: i32 = @intFromFloat(place_pos.z);

                    if (placementIntersectsPlayer(px, py, pz, state.player.feet_pos)) {
                        std.log.info("Hotbar: refused place at ({},{},{}) — would clip player AABB", .{ px, py, pz });
                        break :place_blk;
                    }

                    _ = try state.world.setBlock(px, py, pz, sel_block);
                    const cam_pos_arr2 = [3]f32{ state.camera.position.x, state.camera.position.y, state.camera.position.z };
                    if (state.world.getChunkAtBlock(px, pz)) |lc| {
                        const lcx = world_mod.chunkCoordOf(px);
                        const lcz = world_mod.chunkCoordOf(pz);
                        const lpx = px - lcx * chunk_mod.CHUNK_W;
                        const lpz = pz - lcz * chunk_mod.CHUNK_W;
                        if (state.meshing_mode == .greedy) {
                            // See note in the break-block path above: greedy
                            // merged quads can't be incrementally updated.
                            lc.mesh_dirty = true;
                            std.log.info("[TICK  tick={d:4}] greedy place ({},{},{}) mesh_dirty=true", .{ ctx.tickId(), px, py, pz });
                        } else {
                            const t_incr0 = perfNowNs();
                            lc.mesh.updateForBlockChange(
                                &lc.chunk,
                                lpx,
                                py,
                                lpz,
                                cam_pos_arr2,
                                lc.worldX(),
                                lc.worldZ(),
                                state.world.asBlockGetter(),
                                state.ao_strategy,
                                state.lighting_mode,
                            ) catch |err| {
                                std.log.err("Incremental mesh update failed: {} — falling back to full regen", .{err});
                                lc.mesh_dirty = true;
                            };
                            lc.mesh_incremental_dirty = true;
                            const t_incr_us = @divTrunc(perfNowNs() - t_incr0, 1000);
                            std.log.info("[TICK  tick={d:4}] incremental place ({},{},{}) update={}us", .{ ctx.tickId(), px, py, pz, t_incr_us });
                        }
                    }
                    updateBoundaryNeighbors(&state.world, px, py, pz, cam_pos_arr2);
                }
            } else {
                if (!state.tas_step_mode or state.tas_step_executing) state.hover_block = null;
            }
        } else {
            if (!state.tas_step_mode or state.tas_step_executing) state.hover_block = null;
        }
    } else {
        // Pause menu or another captures_all layer is blocking gameplay.
        // In TAS step mode between steps, preserve the last hover_block so the outline persists.
        if (!state.tas_step_mode or state.tas_step_executing) state.hover_block = null;
    }

    // GPU debug: decay highlight intensity each tick so rebuilt faces fade out over ~0.5s.
    // In TAS step mode, only decay on executing ticks (preserves highlights between steps).
    if (state.gpu_debug and (!state.tas_step_mode or state.tas_step_executing)) {
        var it = state.world.chunks.valueIterator();
        while (it.next()) |lc_ptr| {
            lc_ptr.*.mesh.decayHighlights(4);
        }
    }
}

/// Build chunk border wireframe: 12 edges of the bounding box, each as two
/// perpendicular thin quads (cross shape) so they're visible from any angle.
/// ox/oz are the world-space X/Z origin of the chunk to draw the border for.
fn buildChunkBorderMesh(g: *gpu_mod.GPU, ox: f32, oz: f32) void {
    const W: f32 = @floatFromInt(chunk_mod.CHUNK_W);
    const H: f32 = @floatFromInt(chunk_mod.CHUNK_H);
    const t: f32 = 0.02; // half-thickness of each line
    const bt: u32 = 101; // block_type for borders
    const n_zero = [3]f32{ 0, 0, 0 }; // normal unused for unlit wireframe

    var verts: [12 * 2 * 4]VoxelVertex = undefined; // 12 edges × 2 quads × 4 verts
    var idxs: [12 * 2 * 6]u32 = undefined; // 12 edges × 2 quads × 6 indices
    var vi: u32 = 0;
    var ii: usize = 0;

    // Helper: append one quad (4 verts, 6 indices)
    const addQ = struct {
        fn f(v: *[12 * 2 * 4]VoxelVertex, idx: *[12 * 2 * 6]u32, base: *u32, iptr: *usize, p0: [3]f32, p1: [3]f32, p2: [3]f32, p3: [3]f32, block_type: u32, normal: [3]f32) void {
            const b = base.*;
            v[b + 0] = .{ .pos = p0, .normal = normal, .block_type = block_type, .uv = .{ 0, 0 } };
            v[b + 1] = .{ .pos = p1, .normal = normal, .block_type = block_type, .uv = .{ 0, 1 } };
            v[b + 2] = .{ .pos = p2, .normal = normal, .block_type = block_type, .uv = .{ 1, 1 } };
            v[b + 3] = .{ .pos = p3, .normal = normal, .block_type = block_type, .uv = .{ 1, 0 } };
            idx[iptr.*] = b;
            idx[iptr.* + 1] = b + 1;
            idx[iptr.* + 2] = b + 2;
            idx[iptr.* + 3] = b;
            idx[iptr.* + 4] = b + 2;
            idx[iptr.* + 5] = b + 3;
            base.* += 4;
            iptr.* += 6;
        }
    }.f;

    // Vertical edges (4 corners, each a cross of XZ-perpendicular quads)
    const corners = [_][2]f32{ .{ 0, 0 }, .{ W, 0 }, .{ 0, W }, .{ W, W } };
    for (corners) |c| {
        const cx = ox + c[0];
        const cz = oz + c[1];
        // Quad facing ±Z
        addQ(&verts, &idxs, &vi, &ii, .{ cx - t, 0, cz }, .{ cx - t, H, cz }, .{ cx + t, H, cz }, .{ cx + t, 0, cz }, bt, n_zero);
        // Quad facing ±X
        addQ(&verts, &idxs, &vi, &ii, .{ cx, 0, cz - t }, .{ cx, H, cz - t }, .{ cx, H, cz + t }, .{ cx, 0, cz + t }, bt, n_zero);
    }

    // Horizontal edges along X (4: bottom + top, at Z=0 and Z=W)
    const y_levels = [_]f32{ 0, H };
    const z_edges = [_]f32{ oz, oz + W };
    for (y_levels) |y| {
        for (z_edges) |z| {
            // Quad facing ±Y
            addQ(&verts, &idxs, &vi, &ii, .{ ox, y, z - t }, .{ ox + W, y, z - t }, .{ ox + W, y, z + t }, .{ ox, y, z + t }, bt, n_zero);
            // Quad facing ±Z
            addQ(&verts, &idxs, &vi, &ii, .{ ox, y - t, z }, .{ ox + W, y - t, z }, .{ ox + W, y + t, z }, .{ ox, y + t, z }, bt, n_zero);
        }
    }

    // Horizontal edges along Z (4: bottom + top, at X=0 and X=W)
    const x_edges = [_]f32{ ox, ox + W };
    for (y_levels) |y| {
        for (x_edges) |x| {
            // Quad facing ±Y
            addQ(&verts, &idxs, &vi, &ii, .{ x - t, y, oz }, .{ x + t, y, oz }, .{ x + t, y, oz + W }, .{ x - t, y, oz + W }, bt, n_zero);
            // Quad facing ±X
            addQ(&verts, &idxs, &vi, &ii, .{ x, y - t, oz }, .{ x, y + t, oz }, .{ x, y + t, oz + W }, .{ x, y - t, oz + W }, bt, n_zero);
        }
    }

    state.border_vert_count = vi;
    state.border_idx_count = ii;

    // Create GPU buffers if needed; always re-upload since ox/oz can change frame to frame.
    if (state.border_vertex_buffer == null) {
        state.border_vertex_buffer = g.createBuffer(.{
            .size = verts.len * @sizeOf(VoxelVertex),
            .usage = .{ .vertex = true, .copy_dst = true },
        }) catch return;
        state.border_index_buffer = g.createBuffer(.{
            .size = idxs.len * @sizeOf(u32),
            .usage = .{ .index = true, .copy_dst = true },
        }) catch return;
    }

    g.writeBuffer(state.border_vertex_buffer.?, 0, std.mem.sliceAsBytes(&verts));
    g.writeBuffer(state.border_index_buffer.?, 0, std.mem.sliceAsBytes(&idxs));
}

/// Per-slot constants for the hotbar overlay. Tuned by eye on a 1280×720
/// window: slots are big enough to read the texel pattern but the bar
/// stays out of the way of the crosshair.
const HOTBAR_SLOT_SIZE: f32 = 44.0;
const HOTBAR_SLOT_PAD: f32 = 4.0;
const HOTBAR_BOTTOM_MARGIN: f32 = 18.0;
const HOTBAR_THUMB_GRID: u32 = 16; // matches voxel.wgsl 16×16 face texel grid

/// Draw the persistent 10-slot hotbar centred along the bottom of the
/// screen. Each slot has:
///   - a dark semi-transparent background panel
///   - a 16×16 grid of brightness-varied rects matching the in-world
///     block colour, so the icon visually reads as the block it places
///   - a digit label (1..9, then 0) under the slot
///   - a brighter border around the currently-selected slot
fn drawHotbar(overlay: *OverlayRenderer, screen_w: f32, screen_h: f32) void {
    const slot_count: u32 = 10;
    const total_w: f32 = @as(f32, @floatFromInt(slot_count)) * HOTBAR_SLOT_SIZE +
        @as(f32, @floatFromInt(slot_count - 1)) * HOTBAR_SLOT_PAD;
    const start_x: f32 = (screen_w - total_w) / 2.0;
    // Account for the digit label below each slot when computing the
    // bottom margin so the labels don't fall off the screen.
    const label_scale: f32 = 2.0;
    const label_h: f32 = GLYPH_H * label_scale;
    const label_gap: f32 = 4.0;
    const slot_y: f32 = screen_h - HOTBAR_BOTTOM_MARGIN - label_h - label_gap - HOTBAR_SLOT_SIZE;

    const panel_bg = [4]f32{ 0.0, 0.0, 0.0, 0.55 };
    const border_dim = [4]f32{ 0.55, 0.55, 0.6, 0.9 };
    const border_sel = [4]f32{ 1.0, 0.95, 0.4, 1.0 };
    const label_dim = [4]f32{ 0.7, 0.7, 0.75, 1.0 };
    const label_sel = [4]f32{ 1.0, 0.95, 0.4, 1.0 };

    var i: u32 = 0;
    while (i < slot_count) : (i += 1) {
        const slot_x = start_x + @as(f32, @floatFromInt(i)) * (HOTBAR_SLOT_SIZE + HOTBAR_SLOT_PAD);
        const is_selected = i == state.hotbar_selected;

        // Background panel.
        overlay.rect(slot_x, slot_y, HOTBAR_SLOT_SIZE, HOTBAR_SLOT_SIZE, panel_bg, screen_w, screen_h) catch {};

        // Border (thicker + brighter when selected). 4 thin rects = top,
        // bottom, left, right outline. The selected border is drawn at
        // 3 px to read clearly against the slot panel.
        const bw: f32 = if (is_selected) 3.0 else 1.5;
        const bcol = if (is_selected) border_sel else border_dim;
        // top
        overlay.rect(slot_x, slot_y, HOTBAR_SLOT_SIZE, bw, bcol, screen_w, screen_h) catch {};
        // bottom
        overlay.rect(slot_x, slot_y + HOTBAR_SLOT_SIZE - bw, HOTBAR_SLOT_SIZE, bw, bcol, screen_w, screen_h) catch {};
        // left
        overlay.rect(slot_x, slot_y, bw, HOTBAR_SLOT_SIZE, bcol, screen_w, screen_h) catch {};
        // right
        overlay.rect(slot_x + HOTBAR_SLOT_SIZE - bw, slot_y, bw, HOTBAR_SLOT_SIZE, bcol, screen_w, screen_h) catch {};

        // Block thumbnail — only when slot is non-empty. Drawn inset so
        // the border is visible all the way around. We render a 16×16
        // grid of small rects, each modulated by the same texelHash the
        // shader uses; the resulting square reads as the block's face.
        const sel_block = state.hotbar_slots[i];
        if (sel_block != .air) {
            const inset: f32 = 5.0;
            const icon_x = slot_x + inset;
            const icon_y = slot_y + inset;
            const icon_w = HOTBAR_SLOT_SIZE - inset * 2.0;
            const cell = icon_w / @as(f32, @floatFromInt(HOTBAR_THUMB_GRID));
            const base = hotbarBlockColor(sel_block);
            var ty: u32 = 0;
            while (ty < HOTBAR_THUMB_GRID) : (ty += 1) {
                var tx: u32 = 0;
                while (tx < HOTBAR_THUMB_GRID) : (tx += 1) {
                    const noise = texelHashCpu(tx, ty);
                    // Same 0.875..1.125 mapping as voxel.wgsl.
                    const tb: f32 = 0.875 + noise * 0.25;
                    const rgba = [4]f32{
                        @min(1.0, base[0] * tb),
                        @min(1.0, base[1] * tb),
                        @min(1.0, base[2] * tb),
                        1.0,
                    };
                    const px = icon_x + @as(f32, @floatFromInt(tx)) * cell;
                    const py = icon_y + @as(f32, @floatFromInt(ty)) * cell;
                    // +1 px overdraw avoids subpixel seams between cells.
                    overlay.rect(px, py, cell + 1.0, cell + 1.0, rgba, screen_w, screen_h) catch {};
                }
            }
        }

        // Digit label centred under the slot. Slots 1..9 show "1".."9",
        // slot 10 (index 9) shows "0" — matches the keyboard layout.
        const digit_char: u8 = if (i == 9) '0' else @as(u8, @intCast('1' + i));
        const lcol = if (is_selected) label_sel else label_dim;
        const label_w = GLYPH_W * label_scale;
        const label_x = slot_x + (HOTBAR_SLOT_SIZE - label_w) / 2.0;
        const label_y = slot_y + HOTBAR_SLOT_SIZE + label_gap;
        bitmap_font.drawChar(overlay, digit_char, label_x, label_y, lcol, label_scale, screen_w, screen_h) catch {};
    }
}

/// Render the "WORLD LOADING" screen: dark purple background with animated wavy
/// strips (same effect as the stuck-in-rock overlay) and centred bitmap text.
/// Runs while state.world_loading is true, until the spawn chunk is meshed.
fn renderLoadingScreen(ctx: *sw.Context, g: *gpu_mod.GPU, overlay_w: f32, overlay_h: f32) !void {
    // Overlay pipeline runs in a post-FXAA UI pass at sample_count=1 (see voxelRender).
    state.overlay.ensurePipeline(g, 1) catch |err| {
        std.log.err("Loading screen: ensurePipeline failed: {}", .{err});
        return err;
    };

    const encoder = try g.createCommandEncoder();
    var swap_view = try g.getCurrentTextureView();
    defer swap_view.release();

    // Match the main render path's AA setup so the loading screen is consistent.
    const use_fxaa = g.fxaa_color_view != null;
    const use_msaa = !use_fxaa and g.msaa_color_view != null;
    var fxaa_cv: gpu_mod.TextureView = undefined;
    if (use_fxaa) fxaa_cv = g.fxaa_color_view.?;
    var msaa_cv: gpu_mod.TextureView = undefined;
    if (use_msaa) msaa_cv = g.msaa_color_view.?;
    const color_view: *gpu_mod.TextureView =
        if (use_fxaa) &fxaa_cv else if (use_msaa) &msaa_cv else &swap_view;
    const resolve_target: ?*gpu_mod.TextureView = if (use_msaa) &swap_view else null;
    const color_store: gpu_mod.StoreOp =
        if (use_fxaa) .store else if (use_msaa) .discard else .store;

    // Background pass: just clears to dark purple. The strips and title are
    // drawn in the post-FXAA UI pass below so they aren't blurred.
    const pass = try encoder.beginRenderPass(.{
        .color_attachments = &[_]gpu_mod.RenderPassColorAttachment{.{
            .view = color_view,
            .resolve_target = resolve_target,
            .load_op = .clear,
            .store_op = color_store,
            .clear_value = .{ .r = 0.08, .g = 0.02, .b = 0.12, .a = 1.0 }, // Dark purple
        }},
    });

    // Animated wavy purple strips — same algorithm as the stuck-in-rock overlay,
    // just drawn on the loading screen's clear background.
    state.overlay.begin();
    {
        const t = @as(f32, @floatFromInt(ctx.tickId())) * 0.04;
        const strip_count: usize = 24;
        const strip_h = overlay_h / @as(f32, @floatFromInt(strip_count));
        var i: usize = 0;
        while (i < strip_count) : (i += 1) {
            const fi = @as(f32, @floatFromInt(i));
            const wave = @sin(fi * 0.7 + t) * 0.5 + @sin(fi * 1.3 - t * 0.6) * 0.3;
            const alpha: f32 = 0.04 + @max(0.0, wave) * 0.18;
            const r: f32 = 0.25 + wave * 0.08;
            const b: f32 = 0.45 + @sin(fi * 0.5 + t * 0.3) * 0.1;
            const y_offset = @mod(fi * strip_h - t * 12.0, overlay_h);
            state.overlay.rect(0, y_offset, overlay_w, strip_h, .{ r, 0.05, b, alpha }, overlay_w, overlay_h) catch {};
        }
    }

    // "WORLD LOADING!!!" title — large, centred.
    const white = [4]f32{ 1.0, 1.0, 1.0, 1.0 };
    const title = "WORLD LOADING!!!";
    const title_scale: f32 = 4.0;
    const title_h = GLYPH_H * title_scale;
    const title_y = (overlay_h - title_h) / 2.0 - 20;
    drawCenteredText(&state.overlay, title, title_y, white, title_scale, overlay_w, overlay_h) catch {};

    // Preset line below — smaller, fainter.
    const faint = [4]f32{ 0.8, 0.7, 0.9, 0.9 };
    const preset_scale: f32 = 2.0;
    const preset_h = GLYPH_H * preset_scale;
    const preset_y = title_y + title_h + 20;
    var preset_buf: [64]u8 = undefined;
    const preset_text = std.fmt.bufPrint(&preset_buf, "PRESET: {s}", .{@tagName(state.world_preset)}) catch "PRESET: ?";
    drawCenteredText(&state.overlay, preset_text, preset_y, faint, preset_scale, overlay_w, overlay_h) catch {};
    _ = preset_h;

    pass.end();

    if (use_fxaa) {
        g.runFXAAPass(encoder, &swap_view) catch |err| {
            std.log.err("FXAA pass (loading screen) failed: {}", .{err});
        };
    }

    // UI pass: composites strips + title onto the swapchain at 1 sample, after
    // FXAA, so loading-screen text stays sharp under --aa=fxaa.
    {
        const ui_pass = try encoder.beginRenderPass(.{
            .label = "loading_ui_pass",
            .color_attachments = &[_]gpu_mod.RenderPassColorAttachment{.{
                .view = &swap_view,
                .load_op = .load,
                .store_op = .store,
            }},
        });
        state.overlay.draw(g, ui_pass);
        ui_pass.end();
    }

    const cmd = try encoder.finish();
    g.submit(&[_]gpu_mod.CommandBuffer{cmd});
    g.present();
}

fn voxelRender(ctx: *sw.Context) !void {
    const g = ctx.gpu();

    // --profile-csv: mark render entry (for render_ns) and reset upload
    // accumulators. A defer-scoped flush at the bottom of this function
    // writes the row regardless of which early-return path we take, so
    // every tick is represented in the CSV even when render skips work.
    if (state.profile_csv_file != null) {
        state.render_t0_ns = perfNowNs();
        state.upload_ns = 0;
        state.upload_count = 0;
    }
    defer if (state.profile_csv_file != null) flushProfileRow(ctx);

    // FPS rolling-window sample (real-time deltas, independent of sim tick rate).
    // Sampled here so the F3 overlay shows real present cadence even if the
    // simulation runs at a different rate. 60-sample window ≈ 1 s at 60 Hz.
    {
        const now = perfNowNs();
        if (state.last_frame_ns != 0) {
            const delta_i = now - state.last_frame_ns;
            if (delta_i > 0) {
                state.fps_window_ns[state.fps_window_idx] = @intCast(delta_i);
                state.fps_window_idx = (state.fps_window_idx + 1) % state.fps_window_ns.len;
                if (state.fps_window_idx == 0) state.fps_window_filled = true;
            }
        }
        state.last_frame_ns = now;
    }

    // Check if GPU is ready
    if (!g.isReady()) {
        return;
    }

    // Update aspect ratio if window resized
    const window_info = ctx.window();
    const screen_w = @as(f32, @floatFromInt(window_info.width));
    const screen_h = @as(f32, @floatFromInt(window_info.height));
    const aspect = screen_w / screen_h;
    // Overlay uses logical pixels (what mouse coords and RESUME_BTN_* constants are in).
    // Physical = logical * dpi_scale; dividing back gives consistent hit-test + draw coords.
    const overlay_w = screen_w / window_info.dpi_scale;
    const overlay_h = screen_h / window_info.dpi_scale;
    state.camera.aspect = aspect;

    // Create GPU resources on first render
    if (state.pipeline == null) {
        setupGPUResources(g, window_info.width, window_info.height) catch |err| {
            std.log.err("Failed to setup GPU resources: {}", .{err});
            return;
        };
    }

    // Live AA pipeline rebuild — only the FXAA quality knob is wired for
    // runtime reconfigure today. Changing AA method at runtime would also
    // require rebuilding the main voxel pipeline with a different
    // sample_count, which is a separate follow-up.
    if (state.aa_dirty) {
        state.aa_dirty = false;
        if (state.msaa_config.method == .fxaa) {
            g.configureFXAA(window_info.width, window_info.height, state.msaa_config.fxaa_quality) catch |err| {
                std.log.err("FXAA reconfigure failed: {}", .{err});
            };
        }
    }

    // Early path: world still loading — render a purple loading overlay only.
    // Skips all 3D work, HUD, crosshair, and the --dump-frame capture (which waits
    // for the real scene). Exits via submit+present.
    if (state.world_loading) {
        renderLoadingScreen(ctx, g, overlay_w, overlay_h) catch |err| {
            std.log.err("Loading screen render failed: {}", .{err});
        };
        return;
    }

    // Sort and upload each chunk's mesh.
    var render_sort_us: i128 = 0;
    var render_upload_us: i128 = 0;
    var render_upload_chunks: usize = 0;
    {
        var it = state.world.chunks.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const lc = entry.value_ptr.*;
            if (lc.mesh.vertices.items.len == 0) continue;

            const t_sort = perfNowNs();
            lc.mesh.sortByDepth(.{
                state.camera.position.x,
                state.camera.position.y,
                state.camera.position.z,
            }) catch |err| {
                std.log.err("Sort failed for chunk ({},{}): {}", .{ lc.cx, lc.cz, err });
                continue;
            };
            render_sort_us += @divTrunc(perfNowNs() - t_sort, 1000);

            const gop = state.chunk_gpu.getOrPut(key) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = .{};
            const needed_upload = lc.mesh_incremental_dirty;
            const up_t0: i128 = if (state.profile_csv_file != null and needed_upload) perfNowNs() else 0;
            uploadChunkMeshToGPU(g, lc, gop.value_ptr, lc.mesh_incremental_dirty) catch |err| {
                std.log.err("Upload failed for chunk ({},{}): {}", .{ lc.cx, lc.cz, err });
                continue;
            };
            if (state.profile_csv_file != null and needed_upload) {
                const up_t1 = perfNowNs();
                state.upload_ns +%= @intCast(up_t1 - up_t0);
                state.upload_count +%= 1;
            }
            if (lc.mesh_incremental_dirty) {
                const this_upload_us = @divTrunc(perfNowNs() - up_t0, 1000);
                render_upload_us += this_upload_us;
                render_upload_chunks += 1;
                lc.mesh_incremental_dirty = false;
            }
        }
    }
    if (render_upload_chunks > 0) {
        std.log.info("[SPIKE_RENDER] sort_total={}us upload_total={}us upload_chunks={}", .{
            render_sort_us, render_upload_us, render_upload_chunks,
        });
    }

    // Update uniforms — front-facing view needs a flipped lookAt direction.
    const view_proj = if (state.camera_view == .third_person_front) blk: {
        const fwd = state.camera.forward();
        const target = state.camera.position.add(Vec3.init(-fwd.x, -fwd.y, -fwd.z));
        const view = math.lookAt(state.camera.position, target, Vec3.init(0, 1, 0));
        break :blk state.camera.getProjectionMatrix().mul(view);
    } else state.camera.getViewProjectionMatrix();

    const hover_active: f32 = if (state.hover_block != null) 1.0 else 0.0;
    const hover_pos = state.hover_block orelse Vec3.init(0, 0, 0);

    // Fog distances derived from render distance so fog always matches the loaded world.
    const render_dist_blocks: f32 = @as(f32, @floatFromInt(state.world.render_distance)) * @as(f32, @floatFromInt(chunk_mod.CHUNK_W));
    const fog_start: f32 = render_dist_blocks * 0.50;
    const fog_end: f32 = render_dist_blocks * 0.85;

    const uniforms = [_]f32{
        // view_proj (16 floats)
        view_proj.data[0],       view_proj.data[1],       view_proj.data[2],       view_proj.data[3],
        view_proj.data[4],       view_proj.data[5],       view_proj.data[6],       view_proj.data[7],
        view_proj.data[8],       view_proj.data[9],       view_proj.data[10],      view_proj.data[11],
        view_proj.data[12],      view_proj.data[13],      view_proj.data[14],      view_proj.data[15],
        // camera_pos + padding (4 floats)
        state.camera.position.x, state.camera.position.y, state.camera.position.z, 0,
        // hover_block + hover_active (4 floats)
        hover_pos.x,             hover_pos.y,             hover_pos.z,             hover_active,
        // fog (2 floats)
        fog_start,               fog_end,
    };

    g.writeBuffer(state.uniform_buffer.?, 0, std.mem.sliceAsBytes(&uniforms));

    // Render
    const encoder = g.createCommandEncoder() catch |err| {
        std.log.err("Failed to create encoder: {}", .{err});
        return;
    };

    var swap_view = g.getCurrentTextureView() catch |err| {
        std.log.err("Failed to get texture view: {}", .{err});
        return;
    };
    defer swap_view.release();

    // AA render target selection:
    //   FXAA — render to offscreen texture; a second pass blits FXAA to swapchain.
    //   MSAA — render to multisampled target and resolve directly to swapchain.
    //   none — render directly to swapchain.
    const use_fxaa = g.fxaa_color_view != null;
    const use_msaa = !use_fxaa and g.msaa_color_view != null;
    var fxaa_cv: gpu_mod.TextureView = undefined;
    if (use_fxaa) fxaa_cv = g.fxaa_color_view.?;
    var msaa_cv: gpu_mod.TextureView = undefined;
    if (use_msaa) msaa_cv = g.msaa_color_view.?;
    const color_view: *gpu_mod.TextureView =
        if (use_fxaa) &fxaa_cv else if (use_msaa) &msaa_cv else &swap_view;
    const resolve_target: ?*gpu_mod.TextureView = if (use_msaa) &swap_view else null;
    const color_store: gpu_mod.StoreOp =
        if (use_fxaa) .store else if (use_msaa) .discard else .store;

    const pass = encoder.beginRenderPass(.{
        .color_attachments = &[_]gpu_mod.RenderPassColorAttachment{.{
            .view = color_view,
            .resolve_target = resolve_target,
            .load_op = .clear,
            .store_op = color_store,
            .clear_value = .{ .r = 0.5, .g = 0.7, .b = 1.0, .a = 1.0 }, // Sky blue
        }},
        // WORKAROUND: Depth attachment disabled (see depth_stencil comment in pipeline creation)
        // .depth_stencil_attachment = .{
        //     .view = &state.depth_view.?,
        //     .depth_load_op = .clear,
        //     .depth_store_op = .store,
        //     .depth_clear_value = 1.0,
        // },
    }) catch |err| {
        std.log.err("Failed to begin render pass: {}", .{err});
        return;
    };

    // Build the live frustum from the current camera (or use the frozen
    // snapshot if Cmd+F is active). When the freeze is held we still update
    // the chunk-grid origin to the *frozen* eye, NOT the live camera, so
    // moving around does not silently re-enable nearby chunks via the 3×3
    // safety net — that would defeat the diagnostic.
    const live_frustum: frustum_mod.Frustum = if (state.frozen_frustum) |fz| fz else blk: {
        const eye = [3]f32{
            state.camera.position.x,
            state.camera.position.y,
            state.camera.position.z,
        };
        const fwd_v = state.camera.forward();
        const fwd = [3]f32{ fwd_v.x, fwd_v.y, fwd_v.z };
        break :blk frustum_mod.Frustum.capture(
            eye,
            fwd,
            state.frustum_fov_deg,
            world_mod.RENDER_DISTANCE,
        );
    };

    // Draw chunks back-to-front (painter's algorithm at chunk level).
    // Build a temporary sorted list of chunks by distance from camera,
    // filtering out chunks rejected by the configured cull strategy.
    state.frustum_drawn = 0;
    state.frustum_culled = 0;
    var sorted_chunks = std.ArrayList(*world_mod.LoadedChunk){};
    defer sorted_chunks.deinit(ctx.allocator());
    {
        var it = state.world.chunks.valueIterator();
        while (it.next()) |lc_ptr| {
            if (lc_ptr.*.mesh.vertices.items.len == 0) continue;
            if (!frustum_mod.keepChunk(state.frustum_strategy, live_frustum, lc_ptr.*.cx, lc_ptr.*.cz)) {
                state.frustum_culled += 1;
                continue;
            }
            state.frustum_drawn += 1;
            sorted_chunks.append(ctx.allocator(), lc_ptr.*) catch continue;
        }
    }
    const cam_pos = [3]f32{ state.camera.position.x, state.camera.position.y, state.camera.position.z };
    std.mem.sort(*world_mod.LoadedChunk, sorted_chunks.items, cam_pos, struct {
        fn lt(cam: [3]f32, a: *world_mod.LoadedChunk, b: *world_mod.LoadedChunk) bool {
            const half: f32 = @as(f32, @floatFromInt(chunk_mod.CHUNK_W)) * 0.5;
            const ax = a.worldXf() + half - cam[0];
            const az = a.worldZf() + half - cam[2];
            const bx = b.worldXf() + half - cam[0];
            const bz = b.worldZf() + half - cam[2];
            return (ax * ax + az * az) > (bx * bx + bz * bz); // far-first
        }
    }.lt);

    pass.setPipeline(state.pipeline.?);
    pass.setBindGroup(0, state.bind_group.?);
    for (sorted_chunks.items) |lc| {
        const key = world_mod.ChunkKey{ .cx = lc.cx, .cz = lc.cz };
        const cg = state.chunk_gpu.get(key) orelse continue;
        if (cg.vertex_buffer == null or cg.index_buffer == null) continue;
        pass.setVertexBuffer(0, cg.vertex_buffer.?, 0, lc.mesh.vertices.items.len * @sizeOf(VoxelVertex));
        pass.setIndexBuffer(cg.index_buffer.?, .uint32, 0, lc.mesh.indices.items.len * @sizeOf(u32));
        pass.drawIndexed(@intCast(lc.mesh.indices.items.len), 1, 0, 0, 0);
    }

    // =========================================================================
    // Player hitbox cylinder (drawn after voxels; no face culling so always visible)
    // =========================================================================
    if (state.debug_mode and state.cylinder_pipeline != null and state.cylinder_vertex_buffer != null) {
        player_mod.buildCylinderMesh(
            state.player.feet_pos,
            100, // cyan
            ctx.allocator(),
            &state.cylinder_verts,
            &state.cylinder_indices,
        ) catch |err| {
            std.log.err("Failed to build cylinder mesh: {}", .{err});
        };

        if (state.cylinder_verts.items.len > 0) {
            g.writeBuffer(state.cylinder_vertex_buffer.?, 0, std.mem.sliceAsBytes(state.cylinder_verts.items));
            g.writeBuffer(state.cylinder_index_buffer.?, 0, std.mem.sliceAsBytes(state.cylinder_indices.items));

            pass.setPipeline(state.cylinder_pipeline.?);
            pass.setBindGroup(0, state.bind_group.?);
            pass.setVertexBuffer(0, state.cylinder_vertex_buffer.?, 0, state.cylinder_verts.items.len * @sizeOf(VoxelVertex));
            pass.setIndexBuffer(state.cylinder_index_buffer.?, .uint32, 0, state.cylinder_indices.items.len * @sizeOf(u32));
            pass.drawIndexed(@intCast(state.cylinder_indices.items.len), 1, 0, 0, 0);
        }
    }

    // =========================================================================
    // Spawn point debug marker (debug mode; flat red disc plate on the ground)
    // Reuses the same scratch buffers and GPU buffers as the player hitbox —
    // they're drawn sequentially so there's no overlap.
    // =========================================================================
    if (state.debug_mode and state.cylinder_pipeline != null and state.cylinder_vertex_buffer != null) {
        player_mod.buildDiscMesh(
            state.spawn_point,
            102, // bright red
            ctx.allocator(),
            &state.cylinder_verts,
            &state.cylinder_indices,
        ) catch |err| {
            std.log.err("Failed to build spawn marker mesh: {}", .{err});
        };

        if (state.cylinder_verts.items.len > 0) {
            g.writeBuffer(state.cylinder_vertex_buffer.?, 0, std.mem.sliceAsBytes(state.cylinder_verts.items));
            g.writeBuffer(state.cylinder_index_buffer.?, 0, std.mem.sliceAsBytes(state.cylinder_indices.items));

            pass.setPipeline(state.cylinder_pipeline.?);
            pass.setBindGroup(0, state.bind_group.?);
            pass.setVertexBuffer(0, state.cylinder_vertex_buffer.?, 0, state.cylinder_verts.items.len * @sizeOf(VoxelVertex));
            pass.setIndexBuffer(state.cylinder_index_buffer.?, .uint32, 0, state.cylinder_indices.items.len * @sizeOf(u32));
            pass.drawIndexed(@intCast(state.cylinder_indices.items.len), 1, 0, 0, 0);
        }
    }

    // =========================================================================
    // Chunk border wireframe (debug mode only; uses cylinder pipeline for alpha + no culling)
    // =========================================================================
    if (state.debug_mode and state.cylinder_pipeline != null) {
        // Draw border for the chunk the player is currently in.
        const pcx = world_mod.chunkCoordOf(@as(i32, @intFromFloat(@floor(state.player.feet_pos[0]))));
        const pcz = world_mod.chunkCoordOf(@as(i32, @intFromFloat(@floor(state.player.feet_pos[2]))));
        const border_ox: f32 = @as(f32, @floatFromInt(pcx)) * @as(f32, @floatFromInt(chunk_mod.CHUNK_W));
        const border_oz: f32 = @as(f32, @floatFromInt(pcz)) * @as(f32, @floatFromInt(chunk_mod.CHUNK_W));
        buildChunkBorderMesh(g, border_ox, border_oz);
        if (state.border_vertex_buffer != null and state.border_idx_count > 0) {
            pass.setPipeline(state.cylinder_pipeline.?);
            pass.setBindGroup(0, state.bind_group.?);
            pass.setVertexBuffer(0, state.border_vertex_buffer.?, 0, state.border_vert_count * @sizeOf(VoxelVertex));
            pass.setIndexBuffer(state.border_index_buffer.?, .uint32, 0, state.border_idx_count * @sizeOf(u32));
            pass.drawIndexed(@intCast(state.border_idx_count), 1, 0, 0, 0);
        }
    }

    // =========================================================================
    // Overlay rendering (2D UI on top of 3D world)
    //
    // The overlay (HUD, crosshair, pause menu, debug bar, keyboard HUD, TAS HUD,
    // stuck-in-rock effect) is NOT drawn into the scene render pass — that would
    // run it through the FXAA filter and blur all the text. Instead, vertices are
    // built here, then submitted via a SEPARATE post-FXAA UI render pass that
    // targets the swapchain directly with load_op=.load. The pass always runs at
    // sample_count=1 regardless of AA mode (no MSAA on the resolved swapchain),
    // so the overlay pipeline is created with sample_count=1.
    // =========================================================================
    state.overlay.ensurePipeline(g, 1) catch |err| {
        std.log.err("Failed to ensure overlay pipeline: {}", .{err});
    };

    state.overlay.begin();

    // Inside-block overlay: dark purple with animated wavy strips
    {
        const cam_bx: i32 = @intFromFloat(@floor(state.camera.position.x));
        const cam_by: i32 = @intFromFloat(@floor(state.camera.position.y));
        const cam_bz: i32 = @intFromFloat(@floor(state.camera.position.z));
        if (state.world.getBlock(cam_bx, cam_by, cam_bz) != .air) {
            // Dark purple base
            state.overlay.rect(0, 0, overlay_w, overlay_h, .{ 0.08, 0.02, 0.12, 1 }, overlay_w, overlay_h) catch {};

            // Animated wavy strips — sine-driven horizontal bands that drift upward
            const t = @as(f32, @floatFromInt(ctx.tickId())) * 0.04;
            const strip_count: usize = 24;
            const strip_h = overlay_h / @as(f32, @floatFromInt(strip_count));
            for (0..strip_count) |i| {
                const fi = @as(f32, @floatFromInt(i));
                // Two sine waves at different frequencies for organic movement
                const wave = @sin(fi * 0.7 + t) * 0.5 + @sin(fi * 1.3 - t * 0.6) * 0.3;
                const alpha: f32 = 0.04 + @max(0.0, wave) * 0.12;
                // Slight purple hue shift per strip
                const r: f32 = 0.25 + wave * 0.08;
                const b: f32 = 0.45 + @sin(fi * 0.5 + t * 0.3) * 0.1;
                const y_offset = @mod(fi * strip_h - t * 12.0, overlay_h);
                state.overlay.rect(0, y_offset, overlay_w, strip_h, .{ r, 0.05, b, alpha }, overlay_w, overlay_h) catch {};
            }
        }
    }

    // HUD: crosshair — always at screen centre. Camera and player share yaw/pitch,
    // so screen centre is always the aim direction in both first and third person.
    if (state.game_state.isLayerActive(.hud) and !state.game_state.isWorldPaused()) {
        const cx = overlay_w / 2.0;
        const cy = overlay_h / 2.0;
        const clen: f32 = 10;
        const cthick: f32 = 2;
        const white = [4]f32{ 1, 1, 1, 1 };
        state.overlay.rect(cx - clen, cy - cthick / 2.0, clen * 2, cthick, white, overlay_w, overlay_h) catch {};
        state.overlay.rect(cx - cthick / 2.0, cy - clen, cthick, clen * 2, white, overlay_w, overlay_h) catch {};
    }

    // Hotbar — persistent 10-slot bar centred along the bottom edge.
    // Hidden during pause and when --hotbar=off. The slot icons are drawn
    // as a 16×16 grid of texel rects so they share the same procedural
    // brightness pattern as the in-world block faces (see hotbarBlockColor
    // / texelHashCpu — both ported from voxel.wgsl).
    if (state.hotbar_visible and state.game_state.isLayerActive(.hud) and !state.game_state.isWorldPaused()) {
        drawHotbar(&state.overlay, overlay_w, overlay_h);
    }

    // Pause menu overlay — multi-screen state machine (main / settings / exit_confirm).
    // Layout is purely text: a centred title at the top, then a vertical list of
    // entries. The selected entry gets a "> " prefix and a brighter colour.
    if (state.game_state.isLayerActive(.pause_menu)) {
        // Semi-transparent dark fullscreen overlay
        state.overlay.rect(0, 0, overlay_w, overlay_h, .{ 0.0, 0.0, 0.0, 0.55 }, overlay_w, overlay_h) catch {};

        const title_scale: f32 = 4.0;
        const entry_scale: f32 = 3.0;
        const entry_line_h: f32 = (GLYPH_H + 4) * entry_scale; // ~33 px per line
        const title_h: f32 = GLYPH_H * title_scale;

        const white = [4]f32{ 1.0, 1.0, 1.0, 1.0 };
        const dim = [4]f32{ 0.65, 0.65, 0.70, 1.0 };
        const yellow = [4]f32{ 1.0, 0.90, 0.30, 1.0 };

        const title: []const u8 = switch (state.menu_screen) {
            .main => "PAUSED",
            .settings => "SETTINGS",
            .exit_confirm => "EXIT TO DESKTOP?",
        };

        const count = menuEntryCount(state.menu_screen);
        const total_h = title_h + 40 + entry_line_h * @as(f32, @floatFromInt(count));
        const title_y = (overlay_h - total_h) / 2.0;
        const first_entry_y = title_y + title_h + 40;

        drawCenteredText(&state.overlay, title, title_y, white, title_scale, overlay_w, overlay_h) catch {};

        // Per-screen entry rendering. Each entry is a single line of text built into
        // a small stack buffer; "> " is prepended for the selected row.
        var line_buf: [128]u8 = undefined;
        var entry_buf: [96]u8 = undefined;

        const sel: u8 = switch (state.menu_screen) {
            .main => state.menu_main_idx,
            .settings => state.menu_settings_idx,
            .exit_confirm => state.menu_exit_idx,
        };

        var i: u8 = 0;
        while (i < count) : (i += 1) {
            // Build the per-entry label. value-picker entries include their current value.
            const entry_text: []const u8 = switch (state.menu_screen) {
                .main => switch (i) {
                    0 => "Resume",
                    1 => "Settings",
                    2 => "Exit",
                    else => "",
                },
                .settings => switch (settingsEntryAt(i)) {
                    .aa_method => blk: {
                        const aa_label = aaMethodLabel(state.msaa_config.method);
                        const s = std.fmt.bufPrint(&entry_buf, "AA Method: {s}", .{aa_label}) catch "AA Method: ?";
                        break :blk s;
                    },
                    .msaa_samples => blk: {
                        const s = std.fmt.bufPrint(&entry_buf, "MSAA Samples: {}", .{state.msaa_config.msaa_samples}) catch "MSAA Samples: ?";
                        break :blk s;
                    },
                    .fxaa_quality => blk: {
                        const s = std.fmt.bufPrint(&entry_buf, "FXAA Quality: {s}", .{@tagName(state.msaa_config.fxaa_quality)}) catch "FXAA Quality: ?";
                        break :blk s;
                    },
                    .ao_strategy => blk: {
                        const ao_label = @tagName(state.ao_strategy);
                        const s = std.fmt.bufPrint(&entry_buf, "AO Strategy: {s}", .{ao_label}) catch "AO Strategy: ?";
                        break :blk s;
                    },
                    .lighting => blk: {
                        const light_label = @tagName(state.lighting_mode);
                        const s = std.fmt.bufPrint(&entry_buf, "Lighting: {s}", .{light_label}) catch "Lighting: ?";
                        break :blk s;
                    },
                    .frustum => blk: {
                        const s = std.fmt.bufPrint(&entry_buf, "Frustum: {s} ({d:.0}°)", .{
                            state.frustum_strategy.label(), state.frustum_fov_deg,
                        }) catch "Frustum: ?";
                        break :blk s;
                    },
                    .render_dist => blk: {
                        const s = std.fmt.bufPrint(&entry_buf, "Render Distance: {} (restart required)", .{state.render_distance_stub}) catch "Render Distance: ?";

                        break :blk s;
                    },
                    .back => "Back",
                },
                .exit_confirm => switch (i) {
                    0 => "No",
                    1 => "Yes",
                    else => "",
                },
            };

            const is_selected = i == sel;

            const col: [4]f32 = if (is_selected)
                yellow
            else
                dim;

            // Prepend selection marker so the eye can scan the active row.
            const display = if (is_selected)
                std.fmt.bufPrint(&line_buf, "> {s}", .{entry_text}) catch entry_text
            else
                std.fmt.bufPrint(&line_buf, "  {s}", .{entry_text}) catch entry_text;

            const entry_y = first_entry_y + entry_line_h * @as(f32, @floatFromInt(i));
            drawCenteredText(&state.overlay, display, entry_y, col, entry_scale, overlay_w, overlay_h) catch {};
        }

        // Footer hint line so newcomers know which keys do what without leaving the screen.
        const hint_scale: f32 = 1.5;
        const hint_y = first_entry_y + entry_line_h * @as(f32, @floatFromInt(count)) + 24;
        const hint: []const u8 = switch (state.menu_screen) {
            .main => "UP/DOWN move - ENTER select - ESC resume",
            .settings => "UP/DOWN move - LEFT/RIGHT change - ENTER activate - ESC back",
            .exit_confirm => "UP/DOWN move - ENTER confirm - ESC cancel",
        };
        drawCenteredText(&state.overlay, hint, hint_y, dim, hint_scale, overlay_w, overlay_h) catch {};
    }

    // F3-style debug info panel (top-left, mirrors Minecraft's debug screen).
    // Lives under the existing Cmd+D / Ctrl+D debug mode alongside the
    // keyboard HUD, hitbox cylinder, and chunk borders — Cmd+D IS "the
    // debug screen". Suppressed while the pause menu is up so menu screens
    // stay clean. CLI: --debug=on|off forces the initial state for tests.
    //
    // All values are O(1) per frame: FPS from a rolling-window sampler at
    // the top of voxelRender, drawn/culled from this frame's cull pass,
    // hover block from the existing per-frame raycast. Loaded count is
    // HashMap.count(); meshed count is one bounded iterator pass.
    //
    // Font: scale 2.0 keeps every glyph "pixel" integer-aligned in logical
    // space (5×7 glyph × 2 = 10×14 logical px), so the rasterizer never
    // splits coverage across physical pixels regardless of dpi_scale —
    // tried 1.5 first, but the resulting 7.5×10.5 quads blurred at edges.
    // bitmap_font.zig has only ASCII 0x20-0x5A — no lowercase rendering
    // (auto-uppercased), no degree sign (uses 'D'), no brackets (uses parens).
    if (state.debug_mode and !state.game_state.isLayerActive(.pause_menu)) {
        const dbg_scale: f32 = 2.0; // smaller than menu entries (3.0); integer-aligned glyph quads
        const dbg_line_h: f32 = (GLYPH_H + 2) * dbg_scale; // 18 px per line
        const dbg_edge: f32 = 2; // 2-pixel gutter from screen edge per spec
        const dbg_pad: f32 = 6; // inner padding inside the dark rect
        const dbg_text_x: f32 = dbg_edge + dbg_pad;
        const dbg_text_y0: f32 = dbg_edge + dbg_pad;
        // Conservative fixed background: ~32 chars wide × 21 lines tall.
        // Avoids a two-pass measure-then-draw.
        const dbg_bg_w: f32 = 32 * (GLYPH_W + GLYPH_GAP) * dbg_scale + dbg_pad * 2;
        const dbg_bg_h: f32 = 21 * dbg_line_h + dbg_pad * 2;
        const dbg_col = [4]f32{ 0.95, 0.95, 0.95, 1.0 };

        state.overlay.rect(dbg_edge, dbg_edge, dbg_bg_w, dbg_bg_h, .{ 0.0, 0.0, 0.0, 0.5 }, overlay_w, overlay_h) catch {};

        var dbg_buf: [96]u8 = undefined;
        var line_y: f32 = dbg_text_y0;

        const drawLine = struct {
            fn call(text: []const u8, x: f32, y: *f32, line_h: f32, scale: f32, col: [4]f32, ow: f32, oh: f32) void {
                drawText(&state.overlay, text, x, y.*, col, scale, ow, oh) catch {};
                y.* += line_h;
            }
        }.call;

        // ── Header ────────────────────────────────────────────────────────
        // Voxel + git sha row: cheap git read at startup is non-trivial in
        // a worktree, and the spec explicitly allows skipping. Static title.
        drawLine("VOXEL DEMO", dbg_text_x, &line_y, dbg_line_h, dbg_scale, dbg_col, overlay_w, overlay_h);

        // FPS — rolling-window mean from the sampler at the top of voxelRender.
        {
            const sample_count: usize = if (state.fps_window_filled) state.fps_window_ns.len else state.fps_window_idx;
            if (sample_count > 0) {
                var sum_ns: u64 = 0;
                for (state.fps_window_ns[0..sample_count]) |s| sum_ns += s;
                const mean_ns: f64 = @as(f64, @floatFromInt(sum_ns)) / @as(f64, @floatFromInt(sample_count));
                if (mean_ns > 0) {
                    const fps: f64 = 1_000_000_000.0 / mean_ns;
                    const ms: f64 = mean_ns / 1_000_000.0;
                    const fps_str = std.fmt.bufPrint(&dbg_buf, "FPS: {d:.0}", .{fps}) catch "FPS: ?";
                    drawLine(fps_str, dbg_text_x, &line_y, dbg_line_h, dbg_scale, dbg_col, overlay_w, overlay_h);
                    var ms_buf: [32]u8 = undefined;
                    const ms_str = std.fmt.bufPrint(&ms_buf, "FRAME: {d:.2} MS", .{ms}) catch "FRAME: ? MS";
                    drawLine(ms_str, dbg_text_x, &line_y, dbg_line_h, dbg_scale, dbg_col, overlay_w, overlay_h);
                } else {
                    drawLine("FPS: ?", dbg_text_x, &line_y, dbg_line_h, dbg_scale, dbg_col, overlay_w, overlay_h);
                    drawLine("FRAME: ? MS", dbg_text_x, &line_y, dbg_line_h, dbg_scale, dbg_col, overlay_w, overlay_h);
                }
            } else {
                drawLine("FPS: ?", dbg_text_x, &line_y, dbg_line_h, dbg_scale, dbg_col, overlay_w, overlay_h);
                drawLine("FRAME: ? MS", dbg_text_x, &line_y, dbg_line_h, dbg_scale, dbg_col, overlay_w, overlay_h);
            }
        }

        // Chunks: rendered / loaded (meshed) — `frustum_drawn` is set this
        // frame by the cull; loaded count is the live HashMap size. Meshed
        // count requires a single iterator pass over the HashMap (still
        // bounded by (2*RD+1)² ≤ 81 entries at the default render distance).
        {
            const loaded_count: u32 = @intCast(state.world.chunks.count());
            var meshed_count: u32 = 0;
            var it = state.world.chunks.valueIterator();
            while (it.next()) |lc_ptr| {
                if (lc_ptr.*.state == .meshed) meshed_count += 1;
            }
            const rendered = state.frustum_drawn;
            const s = std.fmt.bufPrint(&dbg_buf, "CHUNKS: {}/{} ({} MESHED)", .{ rendered, loaded_count, meshed_count }) catch "CHUNKS: ?";
            drawLine(s, dbg_text_x, &line_y, dbg_line_h, dbg_scale, dbg_col, overlay_w, overlay_h);
        }

        // Render distance (compile-time constant; --render-distance is reserved).
        {
            const s = std.fmt.bufPrint(&dbg_buf, "RENDER DIST: {}", .{world_mod.RENDER_DISTANCE}) catch "RENDER DIST: ?";
            drawLine(s, dbg_text_x, &line_y, dbg_line_h, dbg_scale, dbg_col, overlay_w, overlay_h);
        }

        // Blank separator
        drawLine(" ", dbg_text_x, &line_y, dbg_line_h, dbg_scale, dbg_col, overlay_w, overlay_h);

        // ── Position ──────────────────────────────────────────────────────
        // XYZ at eye height (feet + 1.6) — what the player actually sees from.
        const eye_x = state.player.feet_pos[0];
        const eye_y = state.player.feet_pos[1] + 1.6;
        const eye_z = state.player.feet_pos[2];
        {
            const s = std.fmt.bufPrint(&dbg_buf, "XYZ: {d:.3} / {d:.3} / {d:.3}", .{ eye_x, eye_y, eye_z }) catch "XYZ: ?";
            drawLine(s, dbg_text_x, &line_y, dbg_line_h, dbg_scale, dbg_col, overlay_w, overlay_h);
        }
        // Block coords (integer floor)
        const block_x: i32 = @intFromFloat(@floor(eye_x));
        const block_y: i32 = @intFromFloat(@floor(eye_y));
        const block_z: i32 = @intFromFloat(@floor(eye_z));
        {
            const s = std.fmt.bufPrint(&dbg_buf, "BLOCK: {} {} {}", .{ block_x, block_y, block_z }) catch "BLOCK: ?";
            drawLine(s, dbg_text_x, &line_y, dbg_line_h, dbg_scale, dbg_col, overlay_w, overlay_h);
        }
        // Chunk coords + local block-in-chunk coords (parens, not brackets)
        {
            const cx = world_mod.chunkCoordOf(block_x);
            const cz = world_mod.chunkCoordOf(block_z);
            const lx = block_x - cx * chunk_mod.CHUNK_W;
            const lz = block_z - cz * chunk_mod.CHUNK_W;
            const s = std.fmt.bufPrint(&dbg_buf, "CHUNK: {}, {} IN ({}, {})", .{ cx, cz, lx, lz }) catch "CHUNK: ?";
            drawLine(s, dbg_text_x, &line_y, dbg_line_h, dbg_scale, dbg_col, overlay_w, overlay_h);
        }
        // Facing: cardinal + yaw/pitch in degrees ('D' since the font has no °).
        // Camera convention: yaw=-π/2 looks toward -Z (= North in MC).
        // forward.x = cos(yaw)*cos(pitch), forward.z = sin(yaw)*cos(pitch).
        {
            const fwd = state.camera.forward();
            const cardinal: []const u8 = if (@abs(fwd.x) >= @abs(fwd.z))
                (if (fwd.x >= 0) "EAST" else "WEST")
            else
                (if (fwd.z >= 0) "SOUTH" else "NORTH");
            const yaw_deg = @as(i32, @intFromFloat(std.math.round(state.camera.yaw * (180.0 / std.math.pi))));
            const pitch_deg = @as(i32, @intFromFloat(std.math.round(state.camera.pitch * (180.0 / std.math.pi))));
            const s = std.fmt.bufPrint(&dbg_buf, "FACING: {s} ({}D / {}D)", .{ cardinal, yaw_deg, pitch_deg }) catch "FACING: ?";
            drawLine(s, dbg_text_x, &line_y, dbg_line_h, dbg_scale, dbg_col, overlay_w, overlay_h);
        }

        // Blank separator
        drawLine(" ", dbg_text_x, &line_y, dbg_line_h, dbg_scale, dbg_col, overlay_w, overlay_h);

        // ── Render settings ──────────────────────────────────────────────
        {
            const s = std.fmt.bufPrint(&dbg_buf, "AO: {s}", .{@tagName(state.ao_strategy)}) catch "AO: ?";
            drawLine(s, dbg_text_x, &line_y, dbg_line_h, dbg_scale, dbg_col, overlay_w, overlay_h);
        }
        {
            const s = std.fmt.bufPrint(&dbg_buf, "LIGHTING: {s}", .{@tagName(state.lighting_mode)}) catch "LIGHTING: ?";
            drawLine(s, dbg_text_x, &line_y, dbg_line_h, dbg_scale, dbg_col, overlay_w, overlay_h);
        }
        {
            const s = std.fmt.bufPrint(&dbg_buf, "ANTIALIAS: {s} ({}X)", .{ aaMethodLabel(state.msaa_config.method), state.msaa_config.msaa_samples }) catch "ANTIALIAS: ?";
            drawLine(s, dbg_text_x, &line_y, dbg_line_h, dbg_scale, dbg_col, overlay_w, overlay_h);
        }

        // Blank separator
        drawLine(" ", dbg_text_x, &line_y, dbg_line_h, dbg_scale, dbg_col, overlay_w, overlay_h);

        // ── Targeted block + light at player ─────────────────────────────
        {
            if (state.hover_block) |hb| {
                const tbx: i32 = @intFromFloat(@floor(hb.x));
                const tby: i32 = @intFromFloat(@floor(hb.y));
                const tbz: i32 = @intFromFloat(@floor(hb.z));
                const bt = state.world.getBlock(tbx, tby, tbz);
                const s = std.fmt.bufPrint(&dbg_buf, "TARGETED: {s} {} {} {}", .{ @tagName(bt), tbx, tby, tbz }) catch "TARGETED: ?";
                drawLine(s, dbg_text_x, &line_y, dbg_line_h, dbg_scale, dbg_col, overlay_w, overlay_h);
            } else {
                drawLine("TARGETED: NONE", dbg_text_x, &line_y, dbg_line_h, dbg_scale, dbg_col, overlay_w, overlay_h);
            }
        }
        // Skylight at the player's feet (clamped to world Y bounds; >CHUNK_H = open sky).
        {
            const sky_y = if (block_y < 0) @as(i32, 0) else block_y;
            const sky = state.world.getSkylight(block_x, sky_y, block_z);
            const s = std.fmt.bufPrint(&dbg_buf, "SKYLIGHT: {}", .{sky}) catch "SKYLIGHT: ?";
            drawLine(s, dbg_text_x, &line_y, dbg_line_h, dbg_scale, dbg_col, overlay_w, overlay_h);
        }
        // Block light at the player's feet. Shows the BFS-propagated block
        // light value from nearby emissive blocks (e.g. glowstone).
        {
            const bl_y = if (block_y < 0) @as(i32, 0) else block_y;
            const bl = state.world.getBlockLight(block_x, bl_y, block_z);
            const s = std.fmt.bufPrint(&dbg_buf, "BLOCK LIGHT: {}", .{bl}) catch "BLOCK LIGHT: ?";
            drawLine(s, dbg_text_x, &line_y, dbg_line_h, dbg_scale, dbg_col, overlay_w, overlay_h);
        }

        // Blank separator
        drawLine(" ", dbg_text_x, &line_y, dbg_line_h, dbg_scale, dbg_col, overlay_w, overlay_h);

        // ── Memory estimate ──────────────────────────────────────────────
        // 576 KB blocks + 576 KB skylight per chunk = ~1.13 MB/chunk.
        // Spec rounds to 576 KB/chunk × loaded; we honour the spec figure.
        {
            const loaded_count: u32 = @intCast(state.world.chunks.count());
            const kb_total: u64 = @as(u64, loaded_count) * 576;
            const mb_total: f32 = @as(f32, @floatFromInt(kb_total)) / 1024.0;
            const s = std.fmt.bufPrint(&dbg_buf, "MEMORY: CHUNKS {d:.1} MB", .{mb_total}) catch "MEMORY: ?";
            drawLine(s, dbg_text_x, &line_y, dbg_line_h, dbg_scale, dbg_col, overlay_w, overlay_h);
        }

        // Frustum freeze indicator (red, on its own line) — diagnostic mode.
        if (state.frozen_frustum != null) {
            const red = [4]f32{ 1.0, 0.4, 0.4, 1.0 };
            drawLine("FRUSTUM FROZEN", dbg_text_x, &line_y, dbg_line_h, dbg_scale, red, overlay_w, overlay_h);
        }
    }

    // Full keyboard HUD — only in debug mode
    if (state.debug_mode) {
        keyboard_hud.draw(&state.overlay, ctx.input(), overlay_w, overlay_h);
    }

    // TAS step mode HUD — tick counter + replayer state bar at top-centre
    if (state.tas_step_mode) {
        if (state.tas_replayer) |*replayer| {
            drawStepHud(
                &state.overlay,
                state.tas_current_tas_tick,
                state.tas_step_executing,
                replayer.state == .finished,
                replayer.current_index,
                replayer.events.items.len,
                overlay_w,
                overlay_h,
            ) catch {};
        }
    }

    pass.end();

    // FXAA post-process pass: blit the offscreen scene texture to the swapchain.
    // Runs BEFORE the UI pass so the UI draws on top of the FXAA-resolved scene
    // and is itself never filtered.
    if (use_fxaa) {
        g.runFXAAPass(encoder, &swap_view) catch |err| {
            std.log.err("FXAA pass failed: {}", .{err});
        };
    }

    // =========================================================================
    // UI render pass — runs AFTER scene+FXAA so the overlay (HUD, menu, crosshair,
    // debug bar, etc.) is composited directly onto the resolved swapchain at
    // 1:1 pixel mapping. load_op=.load preserves whatever the previous pass put
    // in the swap view (FXAA output, MSAA-resolved scene, or directly-rendered
    // scene depending on AA mode). store_op=.store keeps everything for present.
    // =========================================================================
    {
        const ui_pass = encoder.beginRenderPass(.{
            .label = "ui_pass",
            .color_attachments = &[_]gpu_mod.RenderPassColorAttachment{.{
                .view = &swap_view,
                .load_op = .load,
                .store_op = .store,
            }},
        }) catch |err| {
            std.log.err("Failed to begin UI render pass: {}", .{err});
            return;
        };

        state.overlay.draw(g, ui_pass);
        ui_pass.end();
    }

    const cmd = encoder.finish() catch |err| {
        std.log.err("Failed to finish encoder: {}", .{err});
        return;
    };

    // --dump-frame / --compare-golden: capture the rendered texture BEFORE present,
    // optionally write PPM, optionally compare against a golden, then exit.
    // When a TAS is running, defer capture until the TAS has finished so both MSAA
    // comparison runs dump the same deterministic game state. Without a TAS,
    // capture on the first post-loading frame.
    const dump_ready = blk: {
        if (state.world_loading) break :blk false;
        if (state.tas_replayer) |*r| {
            if (r.state != .finished) break :blk false;
        }
        // Async mode: the final mesh state is only stable once the pipeline
        // has fully drained (no in-flight jobs, no dirty chunks awaiting
        // remesh). Otherwise the dump would capture a partial world and
        // produce a non-deterministic PPM across runs. Force the capture
        // to wait one more tick each time the pipeline still has work.
        if (comptime !is_wasm) {
            if (state.async_pipeline) |p| {
                if (asyncHasPendingWork(p, &state.world)) break :blk false;
            }
        }
        break :blk true;
    };
    // --dump-frame / --compare-golden: native only. WASM builds don't accept
    // CLI flags, so dump_frame_path and compare_golden_path are always null
    // in the browser, but the body still references std.fs and std.process.exit
    // which pull in posix — must be comptime-gated.
    const want_capture = (state.dump_frame_path != null) or (state.compare_golden_path != null);
    if (comptime !is_wasm) if (want_capture and !state.dump_frame_done and dump_ready) {
        state.dump_frame_done = true;
        g.submit(&[_]gpu_mod.CommandBuffer{cmd});
        // Capture pixels (target has CopySrc usage; call before present)
        const pixels = g.captureFrame(ctx.allocator()) catch |err| {
            std.log.err("captureFrame failed: {}", .{err});
            g.present();
            return;
        };
        defer ctx.allocator().free(pixels);
        g.present();

        // Use GPU surface dimensions — on Retina, ctx.window().width/height are
        // physical pixels, which match the GPU swapchain size captured above.
        const w = g.getSurfaceWidth();
        const h = g.getSurfaceHeight();
        // BGRA → RGB conversion once; shared by both the PPM writer and the
        // golden comparator.
        const rgb = ctx.allocator().alloc(u8, w * h * 3) catch {
            std.log.err("OOM allocating PPM buffer", .{});
            fatalExit(1);
        };
        defer ctx.allocator().free(rgb);
        {
            var y: u32 = 0;
            while (y < h) : (y += 1) {
                var x: u32 = 0;
                while (x < w) : (x += 1) {
                    const src = (y * w + x) * 4;
                    const dst = (y * w + x) * 3;
                    rgb[dst + 0] = pixels[src + 2]; // R (from B channel in BGRA)
                    rgb[dst + 1] = pixels[src + 1]; // G
                    rgb[dst + 2] = pixels[src + 0]; // B (from R channel in BGRA)
                }
            }
        }

        // Write PPM P6 if --dump-frame was given.
        if (state.dump_frame_path) |path| {
            var hdr_buf: [64]u8 = undefined;
            const hdr = std.fmt.bufPrint(&hdr_buf, "P6\n{} {}\n255\n", .{ w, h }) catch unreachable;
            const file = std.fs.cwd().createFile(path, .{}) catch |err| {
                std.log.err("Cannot create {s}: {}", .{ path, err });
                fatalExit(1);
            };
            file.writeAll(hdr) catch unreachable;
            file.writeAll(rgb) catch unreachable;
            file.close();
            std.log.info("Frame captured: {s} ({}×{} px)", .{ path, w, h });
        }

        // Compare against golden PPM if --compare-golden was given.
        if (state.compare_golden_path) |golden_path| {
            const exit_code = compareAgainstGolden(
                ctx.allocator(),
                golden_path,
                rgb,
                w,
                h,
                state.golden_max_diff_pct,
                state.golden_max_channel_delta,
            ) catch |err| {
                std.log.err("compare-golden failed: {s}: {}", .{ golden_path, err });
                fatalExit(2);
            };
            fatalExit(exit_code);
        }

        fatalExit(0);
    };

    g.submit(&[_]gpu_mod.CommandBuffer{cmd});
    g.present();
}

/// Compare captured RGB frame against a golden PPM P6 file.
///
/// Returns the process exit code to use: 0 = within tolerance, 1 = exceeds
/// tolerance, non-zero error = propagated via error union. Prints a single
/// pass/fail line to stderr and a second stats line with differing-pixel
/// count, percentage, max and mean channel delta.
///
/// Tolerance has two knobs:
///   - max_channel_delta: per-channel abs diff below which the pixel is "equal"
///   - max_diff_pct: percentage of pixels allowed to exceed max_channel_delta
///
/// Only supports P6 ASCII-header PPMs because that is what --dump-frame writes.
fn compareAgainstGolden(
    allocator: std.mem.Allocator,
    golden_path: []const u8,
    captured_rgb: []const u8,
    w: u32,
    h: u32,
    max_diff_pct: f32,
    max_channel_delta: u8,
) !u8 {
    // Read golden file
    const file = std.fs.cwd().openFile(golden_path, .{}) catch |err| {
        std.log.err("golden {s} cannot be opened: {}", .{ golden_path, err });
        return error.GoldenNotFound;
    };
    defer file.close();
    const contents = try file.readToEndAlloc(allocator, 64 * 1024 * 1024);
    defer allocator.free(contents);

    // Parse P6 header: "P6\n<w> <h>\n255\n" (plus optional comment lines starting with '#')
    var idx: usize = 0;
    // magic
    if (contents.len < 3 or contents[0] != 'P' or contents[1] != '6') {
        std.log.err("golden {s}: not a P6 PPM", .{golden_path});
        return error.NotP6;
    }
    idx = 2;
    // skip whitespace + comments, then read 3 numbers
    var nums: [3]u32 = undefined;
    var n: usize = 0;
    while (n < 3 and idx < contents.len) {
        const c = contents[idx];
        if (c == '#') {
            while (idx < contents.len and contents[idx] != '\n') : (idx += 1) {}
            if (idx < contents.len) idx += 1;
            continue;
        }
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            idx += 1;
            continue;
        }
        // parse decimal
        const start = idx;
        while (idx < contents.len and contents[idx] >= '0' and contents[idx] <= '9') : (idx += 1) {}
        if (idx == start) {
            std.log.err("golden {s}: malformed header near byte {}", .{ golden_path, idx });
            return error.MalformedHeader;
        }
        nums[n] = try std.fmt.parseInt(u32, contents[start..idx], 10);
        n += 1;
    }
    if (n != 3) return error.MalformedHeader;
    // One more whitespace byte, then pixel data.
    if (idx >= contents.len) return error.MalformedHeader;
    idx += 1;

    const gw = nums[0];
    const gh = nums[1];
    const gmax = nums[2];
    if (gw != w or gh != h) {
        std.log.err("golden {s}: size mismatch — golden is {}×{}, captured is {}×{}", .{
            golden_path, gw, gh, w, h,
        });
        std.debug.print("FAIL: {s}: size mismatch (golden {}×{} vs captured {}×{})\n", .{
            golden_path, gw, gh, w, h,
        });
        return 1;
    }
    if (gmax != 255) {
        std.log.err("golden {s}: unsupported maxval {}", .{ golden_path, gmax });
        return error.UnsupportedMaxval;
    }

    const expected_bytes: usize = @as(usize, gw) * @as(usize, gh) * 3;
    if (contents.len - idx < expected_bytes) {
        std.log.err("golden {s}: truncated pixel data ({} bytes, expected {})", .{
            golden_path, contents.len - idx, expected_bytes,
        });
        return error.TruncatedPixels;
    }
    const golden_rgb = contents[idx .. idx + expected_bytes];

    // Diff
    var differing_px: u64 = 0;
    var max_delta: u32 = 0;
    var total_delta: u64 = 0;
    const total_px: u64 = @as(u64, gw) * @as(u64, gh);
    var i: usize = 0;
    while (i < expected_bytes) : (i += 3) {
        const dr = @abs(@as(i32, captured_rgb[i + 0]) - @as(i32, golden_rgb[i + 0]));
        const dg = @abs(@as(i32, captured_rgb[i + 1]) - @as(i32, golden_rgb[i + 1]));
        const db = @abs(@as(i32, captured_rgb[i + 2]) - @as(i32, golden_rgb[i + 2]));
        const pixel_max: u32 = @intCast(@max(dr, @max(dg, db)));
        total_delta += @as(u64, @intCast(dr + dg + db));
        if (pixel_max > max_delta) max_delta = pixel_max;
        if (pixel_max > @as(u32, max_channel_delta)) differing_px += 1;
    }

    const diff_pct: f32 = @as(f32, @floatFromInt(differing_px)) * 100.0 / @as(f32, @floatFromInt(total_px));
    const mean_delta: f32 = @as(f32, @floatFromInt(total_delta)) / @as(f32, @floatFromInt(total_px * 3));

    const pass = diff_pct <= max_diff_pct;
    const tag = if (pass) "PASS" else "FAIL";
    std.debug.print(
        "{s}: {s}\n  differing px: {}/{} ({d:.4}%, tol {d:.4}%)\n  max Δ: {} / 255 (tol {})\n  mean Δ: {d:.4} / 255\n",
        .{ tag, golden_path, differing_px, total_px, diff_pct, max_diff_pct, max_delta, max_channel_delta, mean_delta },
    );
    return if (pass) @as(u8, 0) else @as(u8, 1);
}

fn voxelShutdown(ctx: *sw.Context) !void {
    // Join the async worker thread BEFORE tearing down the world — its
    // snapshot pointers reference c_allocator-owned copies, not world
    // data, but we still want the thread gone before we start destroying
    // anything else it could touch via logging/allocator channels.
    if (state.async_pipeline) |p| {
        p.deinit();
        state.async_pipeline = null;
    }
    state.async_result_scratch.deinit(ctx.allocator());

    // Destroy per-chunk GPU buffers
    var it = state.chunk_gpu.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.vertex_buffer) |buf| buf.destroy();
        if (entry.value_ptr.index_buffer) |buf| buf.destroy();
    }
    state.chunk_gpu.deinit();
    state.world.deinit();

    state.overlay.deinit();
    state.cylinder_verts.deinit(ctx.allocator());
    state.cylinder_indices.deinit(ctx.allocator());

    if (state.tas_replayer) |*replayer| {
        replayer.deinit();
    }

    if (state.profile_csv_file) |f| {
        f.close();
        state.profile_csv_file = null;
        if (state.profile_csv_path) |p| {
            std.log.info("[PROFILE] csv closed: {s}", .{p});
        }
    }

    std.log.info("Voxel demo shutdown", .{});
}

fn setupGPUResources(g: *gpu_mod.GPU, width: u32, height: u32) !void {
    // Configure AA from CLI flags (default: FXAA medium quality).
    try g.configureMSAA(state.msaa_config, width, height);
    if (state.msaa_config.method == .fxaa) {
        try g.configureFXAA(width, height, state.msaa_config.fxaa_quality);
    }
    const sample_count = g.getSampleCount();

    // Load shader
    const shader_code = @embedFile("voxel.wgsl");
    std.log.info("Loading shader: {} bytes", .{shader_code.len});
    var shader = try g.createShaderModule(.{ .code = shader_code });

    // Create depth texture (trying depth24plus for better compatibility)
    const depth_tex = try g.createTexture(.{
        .size = .{ .width = width, .height = height, .depth_or_array_layers = 1 },
        .format = .depth24plus,
        .usage = .{ .render_attachment = true },
    });
    state.depth_texture = depth_tex;
    state.depth_view = try depth_tex.createView(.{});

    // Create uniform buffer (256 bytes for alignment)
    state.uniform_buffer = try g.createBuffer(.{
        .size = 256,
        .usage = .{ .uniform = true, .copy_dst = true },
    });

    // Create bind group layout
    var bg_layout = try g.createBindGroupLayout(.{
        .entries = &[_]sw.gpu_types.BindGroupLayoutEntry{.{
            .binding = 0,
            .visibility = .{ .vertex = true, .fragment = true },
            .buffer = .{
                .type = .uniform,
                .has_dynamic_offset = false,
                .min_binding_size = 0,
            },
        }},
    });

    // Create bind group
    state.bind_group = try g.createBindGroup(.{
        .layout = &bg_layout,
        .entries = &[_]gpu_mod.BindGroupEntry{.{
            .binding = 0,
            .buffer = &state.uniform_buffer.?,
            .size = 256,
        }},
    });

    // Create pipeline layout
    var pipeline_layout = try g.createPipelineLayout(.{
        .bind_group_layouts = &[_]*gpu_mod.BindGroupLayout{&bg_layout},
    });

    // Shared vertex buffer layout used by both voxel and cylinder pipelines
    const voxel_vbl = sw.gpu_types.VertexBufferLayout{
        .array_stride = @sizeOf(VoxelVertex),
        .attributes = &[_]sw.gpu_types.VertexAttribute{
            .{ .format = .float32x3, .offset = 0, .shader_location = 0 }, // pos
            .{ .format = .float32x3, .offset = 12, .shader_location = 1 }, // normal
            .{ .format = .uint32, .offset = 24, .shader_location = 2 }, // block_type
            .{ .format = .float32x2, .offset = 28, .shader_location = 3 }, // uv
            .{ .format = .float32, .offset = 36, .shader_location = 4 }, // ao
            .{ .format = .float32, .offset = 40, .shader_location = 5 }, // skylight
            .{ .format = .float32, .offset = 44, .shader_location = 6 }, // block_light
        },
    };

    // Create render pipeline (back-face culled — for opaque voxel geometry)
    state.pipeline = try g.createRenderPipeline(.{
        .layout = &pipeline_layout,
        .vertex = .{
            .module = &shader,
            .entry_point = "vs_main",
            .buffers = &[_]sw.gpu_types.VertexBufferLayout{voxel_vbl},
        },
        .fragment = .{
            .module = &shader,
            .entry_point = "fs_main",
            .targets = &[_]sw.gpu_types.ColorTargetState{.{
                .format = .bgra8unorm,
            }},
        },
        .primitive = .{
            .topology = .triangle_list,
            .front_face = .ccw,
            .cull_mode = .back,
        },
        .multisample = .{ .count = sample_count },
        // WORKAROUND: Hardware depth testing crashes on Metal (wgpu-native v0.19.4.1 bug)
        // Using software depth sorting (painter's algorithm) instead - see sortByDepth()
    });

    // Cylinder pipeline: no face culling + alpha blending so the hitbox is semi-transparent
    // and visible from both inside (first-person) and outside (third-person, F5).
    state.cylinder_pipeline = try g.createRenderPipeline(.{
        .layout = &pipeline_layout,
        .vertex = .{
            .module = &shader,
            .entry_point = "vs_main",
            .buffers = &[_]sw.gpu_types.VertexBufferLayout{voxel_vbl},
        },
        .fragment = .{
            .module = &shader,
            .entry_point = "fs_main",
            .targets = &[_]sw.gpu_types.ColorTargetState{.{
                .format = .bgra8unorm,
                .blend = .{
                    .color = .{ .operation = .add, .src_factor = .src_alpha, .dst_factor = .one_minus_src_alpha },
                    .alpha = .{ .operation = .add, .src_factor = .one, .dst_factor = .zero },
                },
            }},
        },
        .primitive = .{
            .topology = .triangle_list,
            .front_face = .ccw,
            .cull_mode = .none,
        },
        .multisample = .{ .count = sample_count },
    });

    // Pre-allocate fixed-size cylinder GPU buffers (size never changes)
    state.cylinder_vertex_buffer = try g.createBuffer(.{
        .size = player_mod.CYLINDER_VERT_COUNT * @sizeOf(VoxelVertex),
        .usage = .{ .vertex = true, .copy_dst = true },
    });
    state.cylinder_index_buffer = try g.createBuffer(.{
        .size = player_mod.CYLINDER_IDX_COUNT * @sizeOf(u32),
        .usage = .{ .index = true, .copy_dst = true },
    });

    std.log.info("GPU resources created", .{});
}

fn uploadChunkMeshToGPU(g: *gpu_mod.GPU, lc: *world_mod.LoadedChunk, cg: *ChunkGPU, structure_changed: bool) !void {
    const vertex_count = lc.mesh.vertices.items.len;
    const index_count = lc.mesh.indices.items.len;
    if (index_count == 0) return;
    const sorted = lc.mesh.sort_indices[0..index_count];

    if (structure_changed or cg.vertex_buffer == null) {
        if (cg.vertex_buffer) |old| old.destroy();
        cg.vertex_buffer = try g.createBuffer(.{
            .size = vertex_count * @sizeOf(VoxelVertex),
            .usage = .{ .vertex = true, .copy_dst = true },
        });
        if (cg.index_buffer) |old| old.destroy();
        cg.index_buffer = try g.createBuffer(.{
            .size = index_count * @sizeOf(u32),
            .usage = .{ .index = true, .copy_dst = true },
        });
    }

    if (structure_changed or state.gpu_debug) {
        if (state.gpu_debug) {
            const quad_count = vertex_count / 4;
            for (0..quad_count) |qi| {
                const hl = lc.mesh.quad_highlight.items[qi];
                if (hl > 0) {
                    const hl32 = @as(u32, hl) << 16;
                    const base = qi * 4;
                    for (base..base + 4) |vi| {
                        lc.mesh.vertices.items[vi].block_type |= hl32;
                    }
                }
            }
        }
        g.writeBuffer(cg.vertex_buffer.?, 0, std.mem.sliceAsBytes(lc.mesh.vertices.items));
        if (state.gpu_debug) {
            const quad_count = vertex_count / 4;
            for (0..quad_count) |qi| {
                const hl = lc.mesh.quad_highlight.items[qi];
                if (hl > 0) {
                    const base = qi * 4;
                    for (base..base + 4) |vi| {
                        lc.mesh.vertices.items[vi].block_type &= 0xFFFF;
                    }
                }
            }
        }
    }

    g.writeBuffer(cg.index_buffer.?, 0, std.mem.sliceAsBytes(sorted));
}

// ----------------------------------------------------------------------------
// WASM entry shim
// ----------------------------------------------------------------------------
// These exports let the swindowzig WASM bootstrap (backends/wasm/boot.ts)
// drive the voxel engine from the browser. Only compiled when targeting
// wasm32-freestanding — on native, the `comptime if (is_wasm)` gate below
// keeps them out of the binary entirely.
//
// Lifecycle:
//   - JS side initialises WebGPU (navigator.gpu.requestDevice) BEFORE
//     instantiating the WASM module. By the time swindowzig_init() runs,
//     the webgpuRequestAdapter/Device extern calls return real handles.
//   - swindowzig_init() constructs the Context (timeline, bus, input,
//     WasmBackend, GPU), calls voxelInit(&ctx).
//   - swindowzig_frame(ts) polls events from the bus, advances the
//     fixed-step timeline, calls voxelTick/voxelRender.
//
// Default settings are hardcoded: hilly worldgen, skylight lighting,
// classic AO, 4× MSAA, 120 Hz, windowed (not headless).

const platform_mod = @import("sw_platform");

var wasm_timeline: core.FixedStepTimeline = undefined;
var wasm_bus: core.Bus = undefined;
var wasm_input: core.InputSnapshot = undefined;
var wasm_gpu: gpu_mod.GPU = .{};
var wasm_ctx: sw.Context = undefined;
var wasm_backend: platform_mod.Backend = undefined;
var wasm_last_time_ns: u64 = 0;
var wasm_initialised: bool = false;

fn wasmInitImpl() callconv(.c) void {
    if (wasm_initialised) return;
    const alloc = std.heap.wasm_allocator;

    // Construct the WASM backend — it owns the global event queue that
    // the swindowzig_event_* exports (in sw_platform/wasm_canvas.zig)
    // push key and mouse events into.
    wasm_backend = platform_mod.wasm_canvas.WasmBackend.create(alloc) catch return;
    wasm_backend.init() catch return;

    wasm_timeline = core.FixedStepTimeline.init(120);
    wasm_bus = core.Bus.init(alloc);
    wasm_input = core.InputSnapshot.init();

    // GPU.init() on wasm routes to web_bridge.webgpuRequestAdapter/Device
    // which read handles set up by initWebGPU() on the JS side.
    wasm_gpu.init(null, 1280, 720) catch {
        std.log.warn("WASM GPU init failed; engine will run blind", .{});
    };

    wasm_ctx = .{
        .alloc = alloc,
        .timeline = &wasm_timeline,
        .event_bus = &wasm_bus,
        .input_snapshot = &wasm_input,
        .backend = wasm_backend,
        .gpu_device = &wasm_gpu,
    };

    voxelInit(&wasm_ctx) catch |err| {
        std.log.err("voxelInit failed: {s}", .{@errorName(err)});
        return;
    };

    wasm_last_time_ns = wasm_backend.getTime();
    wasm_initialised = true;
}

fn wasmFrameImpl(timestamp_ms: f64) callconv(.c) void {
    _ = timestamp_ms;
    if (!wasm_initialised) return;

    wasm_backend.pollEvents(&wasm_bus) catch return;

    const now = wasm_backend.getTime();
    const dt = now - wasm_last_time_ns;
    wasm_last_time_ns = now;

    _ = wasm_timeline.advance(dt);
    wasm_bus.assignPendingToTick(wasm_timeline.currentTick() + 1);

    while (wasm_timeline.step()) {
        if (@hasDecl(Callbacks, "preTick")) {
            Callbacks.preTick(&wasm_ctx) catch {};
        }
        const ev = wasm_bus.eventsForTick(wasm_timeline.currentTick());
        wasm_input.updateFromEvents(ev);
        voxelTick(&wasm_ctx) catch {};
    }

    voxelRender(&wasm_ctx) catch {};

    wasm_bus.clear();
}

// Constants read by boot.ts for canvas configuration.
const wasm_config_disable_context_menu: u8 = 1;
const wasm_config_hide_cursor: u8 = 0;

comptime {
    if (is_wasm) {
        @export(&wasmInitImpl, .{ .name = "swindowzig_init" });
        @export(&wasmFrameImpl, .{ .name = "swindowzig_frame" });
        @export(&wasm_config_disable_context_menu, .{ .name = "swindowzig_config_disable_context_menu" });
        @export(&wasm_config_hide_cursor, .{ .name = "swindowzig_config_hide_cursor" });
    }
}
