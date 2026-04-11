const std = @import("std");
const sw = @import("sw_app");
const gpu_mod = @import("sw_gpu");
const core = @import("sw_core");
const math = @import("sw_math");

pub fn main() !void {
    // Read --headless flag before sw.run() so we can set Config accordingly.
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);

    var headless = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--headless")) headless = true;
    }

    try sw.run(.{
        .title = "Voxel Demo - Minecraft Creative Mode",
        .size = .{ .w = 1280, .h = 720 },
        .tick_hz = 120,
        .headless = headless,
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
/// Rationale for M=1: meshing a 48×256×48 column scans 589,824 blocks and
/// currently costs ~2.3ms on the dev laptop. At 120 Hz sim the frame budget
/// is 8.3ms — one mesh per tick leaves plenty of headroom for physics and
/// rendering. If the player sprints past the async outer ring faster than
/// one-chunk-per-tick, they'll briefly see a seam; in practice running speed
/// is capped well below that threshold. Bump if sprint speed increases.
/// The pregen phase bypasses this cap and meshes everything in one go.
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
const MENU_MAIN_COUNT: u8 = 3;
const MENU_SETTINGS_COUNT: u8 = 6;
const MENU_EXIT_COUNT: u8 = 2;

// Settings entry indices (matches the rendered order).
const SETTINGS_IDX_AA: u8 = 0;
const SETTINGS_IDX_AO: u8 = 1;
const SETTINGS_IDX_LIGHTING: u8 = 2;
const SETTINGS_IDX_FRUSTUM: u8 = 3;
const SETTINGS_IDX_RENDER_DIST: u8 = 4;
const SETTINGS_IDX_BACK: u8 = 5;

fn menuEntryCount(screen: MenuScreen) u8 {
    return switch (screen) {
        .main => MENU_MAIN_COUNT,
        .settings => MENU_SETTINGS_COUNT,
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

/// Cycle the value of the Settings entry at `idx` by `dir` (+1 / -1).
/// AA Method writes through to `state.msaa_config`. AO Strategy cycles
/// state.ao_strategy (none/classic/moore). Render Distance writes to
/// `state.render_distance_stub` with no live effect. Mutations log a
/// "(applies on next chunk remesh / next frame)" hint — wiring up live
/// pipeline rebuilds and chunk remeshes is a follow-up task.
fn cycleSettingsValue(idx: u8, dir: i32) void {
    switch (idx) {
        SETTINGS_IDX_AA => {
            // Cycle: none → msaa(4) → fxaa → none …
            const next_method: gpu_mod.AAMethod = switch (state.msaa_config.method) {
                .none => if (dir > 0) .msaa else .fxaa,
                .msaa => if (dir > 0) .fxaa else .none,
                .fxaa => if (dir > 0) .none else .msaa,
                // Other AAMethod variants aren't reachable from this picker yet —
                // collapse them back to .none rather than getting stuck.
                else => .none,
            };
            const next_samples: u32 = if (next_method == .msaa) 4 else 1;
            state.msaa_config = .{ .method = next_method, .msaa_samples = next_samples };
            std.log.info("Settings: AA Method -> {s} (applies on next pipeline rebuild)", .{@tagName(next_method)});
        },
        SETTINGS_IDX_AO => {
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
        SETTINGS_IDX_LIGHTING => {
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
        SETTINGS_IDX_FRUSTUM => {
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
        SETTINGS_IDX_RENDER_DIST => {
            const min_rd: i32 = 1;
            const max_rd: i32 = 16;
            var next_rd = state.render_distance_stub + dir;
            if (next_rd < min_rd) next_rd = max_rd;
            if (next_rd > max_rd) next_rd = min_rd;
            state.render_distance_stub = next_rd;
            std.log.info("Settings: Render Distance -> {} (no live effect — stub)", .{next_rd});
        },
        else => {},
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
    /// Stub for the Settings → Render Distance picker. world_mod.RENDER_DISTANCE is a
    /// const today, so this value has no live effect — it's wired purely so the picker
    /// has somewhere to write to. Will become a real field once render-distance live
    /// reload lands.
    render_distance_stub: i32 = 4,
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
    /// MSAA config parsed from --msaa=N CLI flag. Default: 4× MSAA.
    msaa_config: gpu_mod.AntiAliasingConfig = .{ .method = .msaa, .msaa_samples = 4 },
    /// Ambient-occlusion sampling strategy parsed from --ao=<none|classic|moore>.
    /// Default: classic (preserves prior behaviour). The future in-game settings
    /// menu reads/writes this same field; changing it at runtime requires marking
    /// every loaded chunk's mesh dirty so they get remeshed with the new sampler.
    ao_strategy: gpu_mod.AOStrategy = .classic,
    /// World-lighting mode parsed from --lighting=<none|skylight>. Default:
    /// skylight (caves are dark). `.none` is the regression-test baseline that
    /// makes every face fully lit by sky regardless of how enclosed it is.
    /// Mutating this at runtime requires `mesh_dirty = true` on every loaded
    /// chunk because skylight is baked per-vertex at mesh time, same as AO.
    lighting_mode: gpu_mod.LightingMode = .skylight,
    /// --dump-frame=<path>: capture first rendered frame to a PPM file then exit.
    dump_frame_path: ?[]const u8 = null,
    dump_frame_done: bool = false,
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
    state.render_distance_stub = world_mod.RENDER_DISTANCE;
    state.headless = false;

    // Initialize game state layer stack
    state.game_state = GameState.init();

    // Initialize overlay renderer
    state.overlay = OverlayRenderer.init(ctx.allocator());

    // Default MSAA config (var state = undefined bypasses struct field defaults)
    state.msaa_config = .{ .method = .msaa, .msaa_samples = 4 };
    // Default AO strategy: classic (matches behaviour pre-strategy-enum).
    state.ao_strategy = .classic;
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
    state.dump_frame_path = null;
    state.dump_frame_done = false;

    // Check for TAS script argument
    const args = try std.process.argsAlloc(ctx.allocator());
    defer std.process.argsFree(ctx.allocator(), args);

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
        if (std.mem.startsWith(u8, arg, "--world=")) {
            const val = std.mem.sliceTo(arg["--world=".len..], 0);
            if (std.mem.eql(u8, val, "flatland")) {
                state.world_preset = .flatland;
            } else if (std.mem.eql(u8, val, "hilly")) {
                state.world_preset = .hilly;
            } else {
                std.log.err("--world: invalid value '{s}'. Accepted: flatland, hilly", .{val});
                std.process.exit(1);
            }
        }
        if (std.mem.startsWith(u8, arg, "--msaa=")) {
            const val = arg["--msaa=".len..];
            if (std.mem.eql(u8, val, "none") or std.mem.eql(u8, val, "0")) {
                state.msaa_config = .{ .method = .none, .msaa_samples = 1 };
            } else if (std.mem.eql(u8, val, "1")) {
                state.msaa_config = .{ .method = .msaa, .msaa_samples = 1 };
            } else if (std.mem.eql(u8, val, "2")) {
                state.msaa_config = .{ .method = .msaa, .msaa_samples = 2 };
            } else if (std.mem.eql(u8, val, "4")) {
                state.msaa_config = .{ .method = .msaa, .msaa_samples = 4 };
            } else if (std.mem.eql(u8, val, "8")) {
                state.msaa_config = .{ .method = .msaa, .msaa_samples = 8 };
            } else {
                std.log.err("--msaa: invalid value '{s}'. Accepted: none, 0, 1, 2, 4, 8", .{val});
                std.process.exit(1);
            }
        }
        if (std.mem.startsWith(u8, arg, "--aa=")) {
            const val = arg["--aa=".len..];
            if (std.mem.eql(u8, val, "none")) {
                state.msaa_config = .{ .method = .none, .msaa_samples = 1 };
            } else if (std.mem.eql(u8, val, "msaa")) {
                // Keep the sample count from --msaa=N if set earlier, default 4×.
                if (state.msaa_config.method != .msaa) {
                    state.msaa_config = .{ .method = .msaa, .msaa_samples = 4 };
                }
            } else if (std.mem.eql(u8, val, "fxaa")) {
                state.msaa_config = .{ .method = .fxaa, .msaa_samples = 1 };
            } else {
                std.log.err("--aa: invalid value '{s}'. Accepted: none, msaa, fxaa", .{val});
                std.process.exit(1);
            }
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
                std.process.exit(1);
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
    }
    std.log.info("AA config (post-parse): method={s} requested_samples={}", .{
        @tagName(state.msaa_config.method), state.msaa_config.msaa_samples,
    });
    std.log.info("AO strategy (post-parse): {s}", .{@tagName(state.ao_strategy)});
    std.log.info("Lighting mode (post-parse): {s}", .{@tagName(state.lighting_mode)});
    std.log.info("World preset: {s}", .{@tagName(state.world_preset)});
    std.log.info("Frustum cull: strategy={s} fov={d:.0}°", .{
        state.frustum_strategy.label(), state.frustum_fov_deg,
    });

    // Initialize world with the selected preset (deferred until here so --world= works).
    state.world = try world_mod.World.init(ctx.allocator(), state.world_preset);

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
fn pregenStep(world: *world_mod.World, spawn_cx: i32, spawn_cz: i32, ao_strategy: gpu_mod.AOStrategy, lighting_mode: gpu_mod.LightingMode) !bool {
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
            mesher_mod.generateMesh(
                &lc.chunk,
                &lc.mesh,
                lc.worldX(),
                lc.worldZ(),
                world.asBlockGetter(),
                ao_strategy,
                lighting_mode,
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

fn voxelTick(ctx: *sw.Context) !void {
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

        const ring_ready = pregenStep(&state.world, spawn_cx, spawn_cz, state.ao_strategy, state.lighting_mode) catch |err| blk: {
            std.log.err("Pregen step failed: {}", .{err});
            break :blk false;
        };
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

    // Update world: load chunks progressively around active region anchors.
    // The player is currently the only anchor. This is the async background
    // fill that keeps the outer ring growing as the player walks.
    try state.world.update(&[_]world_mod.RegionAnchor{
        .{ .position = state.player.feet_pos },
    });

    // Generate meshes for dirty chunks — runs in tick so render frames stay smooth.
    // Gated: a chunk can only be meshed once all four horizontal neighbours are
    // themselves generated. This prevents seam holes where the mesher would
    // otherwise cull faces against unloaded .air neighbours.
    {
        var mesh_gens: usize = 0;
        var it = state.world.chunks.iterator();
        while (it.next()) |entry| {
            if (mesh_gens >= MESH_GENS_PER_TICK) break;
            const lc = entry.value_ptr.*;
            if (!lc.mesh_dirty) continue;
            if (!state.world.hasAllNeighborsGenerated(lc.cx, lc.cz)) continue;
            const t0 = std.time.nanoTimestamp();
            mesher_mod.generateMesh(
                &lc.chunk,
                &lc.mesh,
                lc.worldX(),
                lc.worldZ(),
                state.world.asBlockGetter(),
                state.ao_strategy,
                state.lighting_mode,
            ) catch |err| {
                std.log.err("Mesh gen failed for chunk ({},{}): {}", .{ lc.cx, lc.cz, err });
                continue;
            };
            const t_us = @divTrunc(std.time.nanoTimestamp() - t0, 1000);
            std.log.info("[MESH] chunk ({},{}) gen={}us quads={}", .{ lc.cx, lc.cz, t_us, lc.mesh.indices.items.len / 6 });
            lc.state = .meshed;
            lc.mesh_dirty = false;
            lc.mesh_incremental_dirty = true;
            mesh_gens += 1;
        }
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
                .settings => switch (state.menu_settings_idx) {
                    SETTINGS_IDX_BACK => {
                        state.menu_screen = .main;
                        std.log.info("Menu: -> main (Back)", .{});
                    },
                    // Pickers: Enter cycles forward (same as Right) so a one-key
                    // workflow works on keyboards without arrow keys.
                    SETTINGS_IDX_AA => cycleSettingsValue(SETTINGS_IDX_AA, 1),
                    SETTINGS_IDX_AO => cycleSettingsValue(SETTINGS_IDX_AO, 1),
                    SETTINGS_IDX_LIGHTING => cycleSettingsValue(SETTINGS_IDX_LIGHTING, 1),
                    SETTINGS_IDX_FRUSTUM => cycleSettingsValue(SETTINGS_IDX_FRUSTUM, 1),
                    SETTINGS_IDX_RENDER_DIST => cycleSettingsValue(SETTINGS_IDX_RENDER_DIST, 1),
                    else => {},
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
                        std.process.exit(0);
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
                        eye[0], eye[1], eye[2],
                        -fwd_vec.x, -fwd_vec.y, -fwd_vec.z,
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
                        eye[0], eye[1], eye[2],
                        fwd_vec.x, fwd_vec.y, fwd_vec.z,
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
                    _ = state.world.setBlock(bx, by, bz, .air);
                    const cam_pos_arr = [3]f32{ state.camera.position.x, state.camera.position.y, state.camera.position.z };
                    if (state.world.getChunkAtBlock(bx, bz)) |lc| {
                        const lcx = world_mod.chunkCoordOf(bx);
                        const lcz = world_mod.chunkCoordOf(bz);
                        const lbx = bx - lcx * chunk_mod.CHUNK_W;
                        const lbz = bz - lcz * chunk_mod.CHUNK_W;
                        const t_incr0 = std.time.nanoTimestamp();
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
                        const t_incr_us = @divTrunc(std.time.nanoTimestamp() - t_incr0, 1000);
                        std.log.info("[TICK  tick={d:4}] incremental remove ({},{},{}) update={}us", .{ ctx.tickId(), bx, by, bz, t_incr_us });
                    }
                    updateBoundaryNeighbors(&state.world, bx, by, bz, cam_pos_arr);
                }

                // Right click: place block on adjacent face
                if (input.buttonPressed(.right)) {
                    const place_pos = Vec3.init(
                        hit.block_pos.x + hit.face_normal.x,
                        hit.block_pos.y + hit.face_normal.y,
                        hit.block_pos.z + hit.face_normal.z,
                    );
                    const px: i32 = @intFromFloat(place_pos.x);
                    const py: i32 = @intFromFloat(place_pos.y);
                    const pz: i32 = @intFromFloat(place_pos.z);
                    _ = state.world.setBlock(px, py, pz, .stone);
                    const cam_pos_arr2 = [3]f32{ state.camera.position.x, state.camera.position.y, state.camera.position.z };
                    if (state.world.getChunkAtBlock(px, pz)) |lc| {
                        const lcx = world_mod.chunkCoordOf(px);
                        const lcz = world_mod.chunkCoordOf(pz);
                        const lpx = px - lcx * chunk_mod.CHUNK_W;
                        const lpz = pz - lcz * chunk_mod.CHUNK_W;
                        const t_incr0 = std.time.nanoTimestamp();
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
                        const t_incr_us = @divTrunc(std.time.nanoTimestamp() - t_incr0, 1000);
                        std.log.info("[TICK  tick={d:4}] incremental place ({},{},{}) update={}us", .{ ctx.tickId(), px, py, pz, t_incr_us });
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
    {
        var it = state.world.chunks.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const lc = entry.value_ptr.*;
            if (lc.mesh.vertices.items.len == 0) continue;

            lc.mesh.sortByDepth(.{
                state.camera.position.x,
                state.camera.position.y,
                state.camera.position.z,
            }) catch |err| {
                std.log.err("Sort failed for chunk ({},{}): {}", .{ lc.cx, lc.cz, err });
                continue;
            };

            const gop = state.chunk_gpu.getOrPut(key) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = .{};
            uploadChunkMeshToGPU(g, lc, gop.value_ptr, lc.mesh_incremental_dirty) catch |err| {
                std.log.err("Upload failed for chunk ({},{}): {}", .{ lc.cx, lc.cz, err });
                continue;
            };
            if (lc.mesh_incremental_dirty) lc.mesh_incremental_dirty = false;
        }
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
    const render_dist_blocks: f32 = @as(f32, @floatFromInt(world_mod.RENDER_DISTANCE)) * @as(f32, @floatFromInt(chunk_mod.CHUNK_W));
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
                .settings => switch (i) {
                    SETTINGS_IDX_AA => blk: {
                        const aa_label = aaMethodLabel(state.msaa_config.method);
                        const s = std.fmt.bufPrint(&entry_buf, "AA Method: {s}", .{aa_label}) catch "AA Method: ?";
                        break :blk s;
                    },
                    SETTINGS_IDX_AO => blk: {
                        const ao_label = @tagName(state.ao_strategy);
                        const s = std.fmt.bufPrint(&entry_buf, "AO Strategy: {s}", .{ao_label}) catch "AO Strategy: ?";
                        break :blk s;
                    },
                    SETTINGS_IDX_LIGHTING => blk: {
                        const light_label = @tagName(state.lighting_mode);
                        const s = std.fmt.bufPrint(&entry_buf, "Lighting: {s}", .{light_label}) catch "Lighting: ?";
                        break :blk s;
                    },
                    SETTINGS_IDX_FRUSTUM => blk: {
                        const s = std.fmt.bufPrint(&entry_buf, "Frustum: {s} ({d:.0}°)", .{
                            state.frustum_strategy.label(), state.frustum_fov_deg,
                        }) catch "Frustum: ?";
                        break :blk s;
                    },
                    SETTINGS_IDX_RENDER_DIST => blk: {
                        const s = std.fmt.bufPrint(&entry_buf, "Render Distance: {} (no live effect)", .{state.render_distance_stub}) catch "Render Distance: ?";
                        break :blk s;
                    },
                    SETTINGS_IDX_BACK => "Back",
                    else => "",
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

    // Debug overlay: sidebar with live game state values
    if (state.game_state.isLayerActive(.debug_overlay)) {
        const dbg_scale: f32 = 2.0;
        const dbg_line_h: f32 = (GLYPH_H + 2) * dbg_scale; // 18 px per line
        const dbg_margin_x: f32 = 10;
        const dbg_margin_y: f32 = 10;
        const dbg_bar_w: f32 = 210;
        const dbg_col = [4]f32{ 0.9, 0.9, 0.9, 1.0 };

        state.overlay.rect(0, 0, dbg_bar_w, overlay_h, .{ 0.0, 0.0, 0.0, 0.55 }, overlay_w, overlay_h) catch {};

        var dbg_buf: [64]u8 = undefined;
        var line_y: f32 = dbg_margin_y;

        // Player position (eye height = feet + 1.6)
        {
            const s = std.fmt.bufPrint(&dbg_buf, "X: {d:.1}", .{state.player.feet_pos[0]}) catch "X: ?";
            drawText(&state.overlay, s, dbg_margin_x, line_y, dbg_col, dbg_scale, overlay_w, overlay_h) catch {};
            line_y += dbg_line_h;
        }
        {
            const s = std.fmt.bufPrint(&dbg_buf, "Y: {d:.1}", .{state.player.feet_pos[1] + 1.6}) catch "Y: ?";
            drawText(&state.overlay, s, dbg_margin_x, line_y, dbg_col, dbg_scale, overlay_w, overlay_h) catch {};
            line_y += dbg_line_h;
        }
        {
            const s = std.fmt.bufPrint(&dbg_buf, "Z: {d:.1}", .{state.player.feet_pos[2]}) catch "Z: ?";
            drawText(&state.overlay, s, dbg_margin_x, line_y, dbg_col, dbg_scale, overlay_w, overlay_h) catch {};
            line_y += dbg_line_h;
        }

        // Chunk coordinates
        {
            const pcx = world_mod.chunkCoordOf(@as(i32, @intFromFloat(@floor(state.player.feet_pos[0]))));
            const pcz = world_mod.chunkCoordOf(@as(i32, @intFromFloat(@floor(state.player.feet_pos[2]))));
            const s = std.fmt.bufPrint(&dbg_buf, "CHUNK: {},{}", .{ pcx, pcz }) catch "CHUNK: ?";
            drawText(&state.overlay, s, dbg_margin_x, line_y, dbg_col, dbg_scale, overlay_w, overlay_h) catch {};
            line_y += dbg_line_h;
        }

        // Tick count
        {
            const s = std.fmt.bufPrint(&dbg_buf, "TICK: {}", .{ctx.tickId()}) catch "TICK: ?";
            drawText(&state.overlay, s, dbg_margin_x, line_y, dbg_col, dbg_scale, overlay_w, overlay_h) catch {};
            line_y += dbg_line_h;
        }

        // Facing direction (yaw and pitch in integer degrees)
        {
            const yaw_deg = @as(i32, @intFromFloat(std.math.round(state.camera.yaw * (180.0 / std.math.pi))));
            const s = std.fmt.bufPrint(&dbg_buf, "YAW: {}", .{yaw_deg}) catch "YAW: ?";
            drawText(&state.overlay, s, dbg_margin_x, line_y, dbg_col, dbg_scale, overlay_w, overlay_h) catch {};
            line_y += dbg_line_h;
        }
        {
            const pitch_deg = @as(i32, @intFromFloat(std.math.round(state.camera.pitch * (180.0 / std.math.pi))));
            const s = std.fmt.bufPrint(&dbg_buf, "PITCH: {}", .{pitch_deg}) catch "PITCH: ?";
            drawText(&state.overlay, s, dbg_margin_x, line_y, dbg_col, dbg_scale, overlay_w, overlay_h) catch {};
            line_y += dbg_line_h;
        }

        // Frustum cull strategy + drawn/culled chunk counts. The freeze
        // indicator goes on its own line in red so the user notices the
        // diagnostic mode is engaged.
        {
            const s = std.fmt.bufPrint(&dbg_buf, "FRUSTUM: {s} {d:.0}d", .{
                state.frustum_strategy.label(),
                state.frustum_fov_deg,
            }) catch "FRUSTUM: ?";
            drawText(&state.overlay, s, dbg_margin_x, line_y, dbg_col, dbg_scale, overlay_w, overlay_h) catch {};
            line_y += dbg_line_h;
        }
        {
            const s = std.fmt.bufPrint(&dbg_buf, "CHUNKS: {}/{}", .{
                state.frustum_drawn,
                state.frustum_drawn + state.frustum_culled,
            }) catch "CHUNKS: ?";
            drawText(&state.overlay, s, dbg_margin_x, line_y, dbg_col, dbg_scale, overlay_w, overlay_h) catch {};
            line_y += dbg_line_h;
        }
        if (state.frozen_frustum != null) {
            const red = [4]f32{ 1.0, 0.4, 0.4, 1.0 };
            drawText(&state.overlay, "FRUSTUM FROZEN", dbg_margin_x, line_y, red, dbg_scale, overlay_w, overlay_h) catch {};
            line_y += dbg_line_h;
        }

        // Target block (from raycast hover)
        {
            const target_str: []const u8 = if (state.hover_block) |hb| blk: {
                const bx: i32 = @intFromFloat(@floor(hb.x));
                const by: i32 = @intFromFloat(@floor(hb.y));
                const bz: i32 = @intFromFloat(@floor(hb.z));
                const bt = state.world.getBlock(bx, by, bz);
                break :blk switch (bt) {
                    .air => "TARGET: AIR",
                    .grass => "TARGET: GRASS",
                    .dirt => "TARGET: DIRT",
                    .stone => "TARGET: STONE",
                    .bedrock => "TARGET: BEDROCK",
                    .debug_marker => "TARGET: DEBUG",
                };
            } else "TARGET: NONE";
            drawText(&state.overlay, target_str, dbg_margin_x, line_y, dbg_col, dbg_scale, overlay_w, overlay_h) catch {};
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

    // --dump-frame: capture the surface texture BEFORE present, write PPM, then exit.
    // When a TAS is running, defer capture until the TAS has finished so both MSAA
    // comparison runs dump the same deterministic game state. Without a TAS,
    // capture on the first post-loading frame.
    const dump_ready = blk: {
        if (state.world_loading) break :blk false;
        if (state.tas_replayer) |*r| break :blk (r.state == .finished);
        break :blk true;
    };
    if (state.dump_frame_path) |path| {
        if (!state.dump_frame_done and dump_ready) {
            state.dump_frame_done = true;
            g.submit(&[_]gpu_mod.CommandBuffer{cmd});
            // Capture pixels (surface has CopySrc usage; call before present)
            const pixels = g.captureFrame(ctx.allocator()) catch |err| {
                std.log.err("captureFrame failed: {}", .{err});
                g.present();
                return;
            };
            defer ctx.allocator().free(pixels);
            g.present();

            // Write PPM P6 (binary RGB). Build in a byte buffer then write once.
            // Use GPU surface dimensions — on Retina, ctx.window().width/height are
            // physical pixels, which match the GPU swapchain size captured above.
            const w = g.getSurfaceWidth();
            const h = g.getSurfaceHeight();
            // Header: "P6\n<w> <h>\n255\n"
            var hdr_buf: [64]u8 = undefined;
            const hdr = std.fmt.bufPrint(&hdr_buf, "P6\n{} {}\n255\n", .{ w, h }) catch unreachable;
            // Body: w*h*3 RGB bytes
            const rgb = ctx.allocator().alloc(u8, w * h * 3) catch {
                std.log.err("OOM allocating PPM buffer", .{});
                std.process.exit(1);
            };
            defer ctx.allocator().free(rgb);
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
            const file = std.fs.cwd().createFile(path, .{}) catch |err| {
                std.log.err("Cannot create {s}: {}", .{ path, err });
                std.process.exit(1);
            };
            file.writeAll(hdr) catch unreachable;
            file.writeAll(rgb) catch unreachable;
            file.close();
            std.log.info("Frame captured: {s} ({}×{} px)", .{ path, w, h });
            std.process.exit(0);
        }
    }

    g.submit(&[_]gpu_mod.CommandBuffer{cmd});
    g.present();
}

fn voxelShutdown(ctx: *sw.Context) !void {
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

    std.log.info("Voxel demo shutdown", .{});
}

fn setupGPUResources(g: *gpu_mod.GPU, width: u32, height: u32) !void {
    // Configure AA from CLI --msaa / --aa flags (default: 4× MSAA)
    try g.configureMSAA(state.msaa_config, width, height);
    if (state.msaa_config.method == .fxaa) {
        try g.configureFXAA(width, height);
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
