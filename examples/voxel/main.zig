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

/// Max mesh generations per tick (keeps tick time bounded during chunk loading).
/// Mesh gen runs in tick so render frames stay smooth.
const MESH_GENS_PER_TICK: usize = 1;

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

// Pause menu button geometry (in logical pixels)
const RESUME_BTN_W: f32 = 200;
const RESUME_BTN_H: f32 = 40;
const BTN_GAP: f32 = 12; // gap between resume and quit buttons

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
    button_resume_hovered: bool = false,
    button_quit_hovered: bool = false,
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
    state.button_resume_hovered = false;
    state.button_quit_hovered = false;
    state.headless = false;

    // Initialize game state layer stack
    state.game_state = GameState.init();

    // Initialize overlay renderer
    state.overlay = OverlayRenderer.init(ctx.allocator());

    // Default MSAA config (var state = undefined bypasses struct field defaults)
    state.msaa_config = .{ .method = .msaa, .msaa_samples = 4 };
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
    }
    std.log.info("MSAA config (post-parse): method={s} requested_samples={}", .{
        @tagName(state.msaa_config.method), state.msaa_config.msaa_samples,
    });
    std.log.info("World preset: {s}", .{@tagName(state.world_preset)});

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
        .{ .coord = lx, .at_min = true,  .dx = -1, .dz =  0 }, // −X edge
        .{ .coord = lx, .at_min = false, .dx =  1, .dz =  0 }, // +X edge
        .{ .coord = lz, .at_min = true,  .dx =  0, .dz = -1 }, // −Z edge
        .{ .coord = lz, .at_min = false, .dx =  0, .dz =  1 }, // +Z edge
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
            &nb_lc.chunk, nb_lx, wy, nb_lz,
            camera_pos,
            nb_lc.worldX(), nb_lc.worldZ(),
            world.asBlockGetter(),
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

/// Teleport player to the first 1×2 air column at-or-above the current spawn_point.
/// This is the anti-griefing respawn: if someone places a block on spawn, the next
/// respawn finds the next clear Y slot instead of embedding the player in rock.
fn doRespawn() void {
    const resolved = resolveSpawnPos(&state.world, state.spawn_point);
    state.player.feet_pos = resolved;
    state.player.velocity = .{ 0, 0, 0 };
    state.player.on_ground = false;
    std.log.info("Respawned at ({d:.1}, {d:.1}, {d:.1})", .{
        resolved[0], resolved[1], resolved[2],
    });
}

fn voxelTick(ctx: *sw.Context) !void {
    // Update world: load chunks progressively around active region anchors.
    // The player is currently the only anchor.
    try state.world.update(&[_]world_mod.RegionAnchor{
        .{ .position = state.player.feet_pos },
    });

    // Generate meshes for dirty chunks — runs in tick so render frames stay smooth.
    {
        var mesh_gens: usize = 0;
        var it = state.world.chunks.iterator();
        while (it.next()) |entry| {
            if (mesh_gens >= MESH_GENS_PER_TICK) break;
            const lc = entry.value_ptr.*;
            if (!lc.mesh_dirty) continue;
            const t0 = std.time.nanoTimestamp();
            mesher_mod.generateMesh(
                &lc.chunk,
                &lc.mesh,
                lc.worldX(),
                lc.worldZ(),
                state.world.asBlockGetter(),
            ) catch |err| {
                std.log.err("Mesh gen failed for chunk ({},{}): {}", .{ lc.cx, lc.cz, err });
                continue;
            };
            const t_us = @divTrunc(std.time.nanoTimestamp() - t0, 1000);
            std.log.info("[MESH] chunk ({},{}) gen={}us quads={}", .{ lc.cx, lc.cz, t_us, lc.mesh.indices.items.len / 6 });
            lc.mesh_dirty = false;
            lc.mesh_incremental_dirty = true;
            mesh_gens += 1;
        }
    }

    // World loading gate: wait for the spawn chunk to exist AND have its mesh
    // generated before placing the player. The render loop shows a loading
    // screen during this phase. Gameplay input and TAS playback are both
    // deferred until loading completes.
    if (state.world_loading) {
        const bx: i32 = @intFromFloat(@floor(state.spawn_point[0]));
        const bz: i32 = @intFromFloat(@floor(state.spawn_point[2]));
        if (state.world.getChunkAtBlock(bx, bz)) |lc| {
            if (!lc.mesh_dirty) {
                // Spawn chunk meshed — resolve final spawn position and lock it in.
                const resolved = resolveSpawnPos(&state.world, state.spawn_point);
                state.player.feet_pos = resolved;
                state.player.velocity = .{ 0, 0, 0 };
                state.player.on_ground = false;
                state.spawn_point = resolved; // permanent — first-spawn locks XYZ
                state.spawn_resolved = true;
                state.world_loading = false;
                std.log.info("World ready — spawned at ({d:.1}, {d:.1}, {d:.1})", .{
                    resolved[0], resolved[1], resolved[2],
                });

                // Remap TAS event tick_ids so tick 1 = first post-loading tick.
                // The replayer is in .stopped state from voxelInit; we start it now.
                if (state.tas_replayer) |*r| {
                    if (r.state == .stopped) {
                        const offset: u64 = ctx.tickId() + 1;
                        for (r.events.items) |*ev| {
                            ev.tick_id += offset;
                        }
                        if (!state.tas_step_mode) {
                            r.play();
                            // play() resets current_index to 0 — events are in order
                            // so this is fine (we haven't consumed any yet).
                        }
                        std.log.info("TAS replayer: remapped event tick_ids by +{} and started", .{offset});
                    }
                }
            }
        }
        // Skip gameplay input processing while loading.
        return;
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
            // Resume: deactivate pause menu, recapture mouse if we had it before pausing
            state.game_state.togglePauseMenu();
            if (state.paused_with_mouse) {
                ctx.setMouseCapture(true);
                state.mouse_captured = true;
                state.paused_with_mouse = false;
            }
            std.log.info("Resumed (ESC)", .{});
        } else {
            // Open menu: save mouse state, then release mouse
            state.paused_with_mouse = state.mouse_captured;
            state.game_state.togglePauseMenu();
            if (state.mouse_captured) {
                ctx.setMouseCapture(false);
                state.mouse_captured = false;
            }
            std.log.info("Paused (ESC)", .{});
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
    if (state.game_state.isLayerActive(.pause_menu)) {
        const win = ctx.window();
        // Mouse coords from SDL are logical pixels; window width/height are drawable (physical).
        // Divide by dpi_scale to get logical screen dimensions for hit testing.
        const logical_w = @as(f32, @floatFromInt(win.width)) / win.dpi_scale;
        const logical_h = @as(f32, @floatFromInt(win.height)) / win.dpi_scale;
        const btn_x = (logical_w - RESUME_BTN_W) / 2.0;
        // Center the button pair vertically
        const total_btn_h = RESUME_BTN_H * 2 + BTN_GAP;
        const resume_y = (logical_h - total_btn_h) / 2.0;
        const quit_y = resume_y + RESUME_BTN_H + BTN_GAP;

        const mx = input.mouse.x;
        const my = input.mouse.y;
        state.button_resume_hovered =
            mx >= btn_x and mx <= btn_x + RESUME_BTN_W and
            my >= resume_y and my <= resume_y + RESUME_BTN_H;
        state.button_quit_hovered =
            mx >= btn_x and mx <= btn_x + RESUME_BTN_W and
            my >= quit_y and my <= quit_y + RESUME_BTN_H;

        if (input.buttonPressed(.left) and state.button_resume_hovered) {
            state.game_state.togglePauseMenu();
            if (state.paused_with_mouse) {
                ctx.setMouseCapture(true);
                state.mouse_captured = true;
                state.paused_with_mouse = false;
            }
            state.button_resume_hovered = false;
            std.log.info("Resumed (button click)", .{});
        }

        if (input.buttonPressed(.left) and state.button_quit_hovered) {
            std.log.info("Quit (button click)", .{});
            std.process.exit(0);
        }
    } else {
        state.button_resume_hovered = false;
        state.button_quit_hovered = false;
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
            const eye = state.player.eyePos();
            const fwd_vec = state.camera.forward();
            const cam_dist: f32 = 4.0;
            switch (state.camera_view) {
                .first_person => {
                    state.camera.position = Vec3.init(eye[0], eye[1], eye[2]);
                },
                .third_person_back => {
                    state.camera.position = Vec3.init(
                        eye[0] - fwd_vec.x * cam_dist,
                        eye[1] - fwd_vec.y * cam_dist,
                        eye[2] - fwd_vec.z * cam_dist,
                    );
                },
                .third_person_front => {
                    state.camera.position = Vec3.init(
                        eye[0] + fwd_vec.x * cam_dist,
                        eye[1] + fwd_vec.y * cam_dist,
                        eye[2] + fwd_vec.z * cam_dist,
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

                // Left click: destroy block — buttonPressed fires only on the down edge,
                // so exactly one block is destroyed per click no matter how fast you click.
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
                            &lc.chunk, lbx, by, lbz,
                            cam_pos_arr,
                            lc.worldX(), lc.worldZ(),
                            state.world.asBlockGetter(),
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
                            &lc.chunk, lpx, py, lpz,
                            cam_pos_arr2,
                            lc.worldX(), lc.worldZ(),
                            state.world.asBlockGetter(),
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
    state.overlay.ensurePipeline(g, g.getSampleCount()) catch |err| {
        std.log.err("Loading screen: ensurePipeline failed: {}", .{err});
        return err;
    };

    const encoder = try g.createCommandEncoder();
    var swap_view = try g.getCurrentTextureView();
    defer swap_view.release();

    // Match the main render path's MSAA setup so the loading screen looks identical
    // whether MSAA is on or off.
    const use_msaa = g.msaa_color_view != null;
    var msaa_cv: gpu_mod.TextureView = undefined;
    if (use_msaa) msaa_cv = g.msaa_color_view.?;
    const color_view: *gpu_mod.TextureView = if (use_msaa) &msaa_cv else &swap_view;
    const resolve_target: ?*gpu_mod.TextureView = if (use_msaa) &swap_view else null;
    const color_store: gpu_mod.StoreOp = if (use_msaa) .discard else .store;

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

    state.overlay.draw(g, pass);
    pass.end();

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
    const fog_end: f32   = render_dist_blocks * 0.85;

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

    // MSAA: render into the multisampled target and resolve to the swapchain texture.
    // When MSAA is off (sample_count == 1) the swapchain view is used directly.
    const use_msaa = g.msaa_color_view != null;
    var msaa_cv: gpu_mod.TextureView = undefined;
    if (use_msaa) msaa_cv = g.msaa_color_view.?;
    const color_view: *gpu_mod.TextureView = if (use_msaa) &msaa_cv else &swap_view;
    const resolve_target: ?*gpu_mod.TextureView = if (use_msaa) &swap_view else null;
    const color_store: gpu_mod.StoreOp = if (use_msaa) .discard else .store;

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

    // Draw chunks back-to-front (painter's algorithm at chunk level).
    // Build a temporary sorted list of chunks by distance from camera.
    var sorted_chunks = std.ArrayList(*world_mod.LoadedChunk){};
    defer sorted_chunks.deinit(ctx.allocator());
    {
        var it = state.world.chunks.valueIterator();
        while (it.next()) |lc_ptr| {
            if (lc_ptr.*.mesh.vertices.items.len == 0) continue;
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
    // Spawn point debug marker (debug mode; red translucent cylinder)
    // Reuses the same scratch buffers and GPU buffers as the player hitbox —
    // they're drawn sequentially so there's no overlap.
    // =========================================================================
    if (state.debug_mode and state.cylinder_pipeline != null and state.cylinder_vertex_buffer != null) {
        player_mod.buildCylinderMesh(
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
    // =========================================================================
    state.overlay.ensurePipeline(g, g.getSampleCount()) catch |err| {
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

    // Pause menu overlay
    if (state.game_state.isLayerActive(.pause_menu)) {
        // Semi-transparent dark fullscreen overlay
        state.overlay.rect(0, 0, overlay_w, overlay_h, .{ 0.0, 0.0, 0.0, 0.55 }, overlay_w, overlay_h) catch {};

        const btn_x = (overlay_w - RESUME_BTN_W) / 2.0;
        const total_btn_h = RESUME_BTN_H * 2 + BTN_GAP;
        const resume_y = (overlay_h - total_btn_h) / 2.0;
        const quit_y = resume_y + RESUME_BTN_H + BTN_GAP;
        const border: f32 = 2;

        // Resume button: border then fill
        state.overlay.rect(btn_x - border, resume_y - border, RESUME_BTN_W + border * 2, RESUME_BTN_H + border * 2, .{ 0.85, 0.85, 0.85, 1.0 }, overlay_w, overlay_h) catch {};
        const resume_fill = if (state.button_resume_hovered)
            [4]f32{ 0.55, 0.55, 0.55, 1.0 }
        else
            [4]f32{ 0.35, 0.35, 0.35, 1.0 };
        state.overlay.rect(btn_x, resume_y, RESUME_BTN_W, RESUME_BTN_H, resume_fill, overlay_w, overlay_h) catch {};

        // Quit button: border then reddish-grey fill
        state.overlay.rect(btn_x - border, quit_y - border, RESUME_BTN_W + border * 2, RESUME_BTN_H + border * 2, .{ 0.75, 0.60, 0.60, 1.0 }, overlay_w, overlay_h) catch {};
        const quit_fill = if (state.button_quit_hovered)
            [4]f32{ 0.58, 0.35, 0.35, 1.0 }
        else
            [4]f32{ 0.42, 0.25, 0.25, 1.0 };
        state.overlay.rect(btn_x, quit_y, RESUME_BTN_W, RESUME_BTN_H, quit_fill, overlay_w, overlay_h) catch {};

        // Button text labels — scale 2, centred on each button
        const btn_text_scale: f32 = 2.0;
        const btn_text_h = GLYPH_H * btn_text_scale;
        const white = [4]f32{ 1.0, 1.0, 1.0, 1.0 };

        const resume_label = "RESUME GAME";
        const resume_label_w = @as(f32, @floatFromInt(resume_label.len)) * (GLYPH_W + GLYPH_GAP) * btn_text_scale;
        const resume_text_x = btn_x + (RESUME_BTN_W - resume_label_w) / 2.0;
        const resume_text_y = resume_y + (RESUME_BTN_H - btn_text_h) / 2.0;
        drawText(&state.overlay, resume_label, resume_text_x, resume_text_y, white, btn_text_scale, overlay_w, overlay_h) catch {};

        const quit_label = "EXIT GAME";
        const quit_label_w = @as(f32, @floatFromInt(quit_label.len)) * (GLYPH_W + GLYPH_GAP) * btn_text_scale;
        const quit_text_x = btn_x + (RESUME_BTN_W - quit_label_w) / 2.0;
        const quit_text_y = quit_y + (RESUME_BTN_H - btn_text_h) / 2.0;
        drawText(&state.overlay, quit_label, quit_text_x, quit_text_y, white, btn_text_scale, overlay_w, overlay_h) catch {};
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

    state.overlay.draw(g, pass);

    pass.end();

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
    // Configure MSAA from CLI --msaa flag (default: 4× MSAA)
    try g.configureMSAA(state.msaa_config, width, height);
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
            .{ .format = .float32x3, .offset = 0,  .shader_location = 0 }, // pos
            .{ .format = .float32x3, .offset = 12, .shader_location = 1 }, // normal
            .{ .format = .uint32,    .offset = 24, .shader_location = 2 }, // block_type
            .{ .format = .float32x2, .offset = 28, .shader_location = 3 }, // uv
            .{ .format = .float32,   .offset = 36, .shader_location = 4 }, // ao
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
