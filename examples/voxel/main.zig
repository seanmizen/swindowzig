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

const Vec3 = math.Vec3;
const Mat4 = math.Mat4;

const CameraType = @import("camera.zig").Camera(Vec3, Mat4, math);
const RaycastType = @import("raycast.zig").Raycast(Vec3, Chunk);
const raycast = RaycastType.raycast;

const GameState = @import("game_state.zig").GameState;
const OverlayRenderer = @import("overlay.zig").OverlayRenderer;
const player_mod = @import("player.zig");
const Player = player_mod.Player;
const keyboard_hud = @import("keyboard_hud.zig");

// Pause menu button geometry (in logical pixels)
const RESUME_BTN_W: f32 = 200;
const RESUME_BTN_H: f32 = 40;
const BTN_GAP: f32 = 12; // gap between resume and quit buttons

// Application state
const State = struct {
    chunk: Chunk,
    mesh: Mesh,
    camera: CameraType,
    player: Player,
    pipeline: ?gpu_mod.RenderPipeline = null,
    cylinder_pipeline: ?gpu_mod.RenderPipeline = null,
    vertex_buffer: ?gpu_mod.Buffer = null,
    index_buffer: ?gpu_mod.Buffer = null,
    uniform_buffer: ?gpu_mod.Buffer = null,
    bind_group: ?gpu_mod.BindGroup = null,
    depth_texture: ?gpu_mod.Texture = null,
    depth_view: ?gpu_mod.TextureView = null,
    cylinder_vertex_buffer: ?gpu_mod.Buffer = null,
    cylinder_index_buffer: ?gpu_mod.Buffer = null,
    cylinder_verts: std.ArrayList(VoxelVertex) = undefined,
    cylinder_indices: std.ArrayList(u32) = undefined,
    mesh_dirty: bool = true,
    mesh_incremental_dirty: bool = false,
    mouse_captured: bool = false,
    click_locked: bool = false,
    paused_with_mouse: bool = false,
    button_resume_hovered: bool = false,
    button_quit_hovered: bool = false,
    hover_block: ?Vec3 = null,
    game_state: GameState = undefined,
    overlay: OverlayRenderer = undefined,
    tas_replayer: ?core.Replayer = null,
    headless: bool = false,
    third_person: bool = false,
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
};

var state: State = undefined;

fn voxelInit(ctx: *sw.Context) !void {
    std.log.info("Voxel demo init", .{});

    // Explicitly null all optional fields — `var state: State = undefined` bypasses struct defaults
    state.pipeline = null;
    state.cylinder_pipeline = null;
    state.vertex_buffer = null;
    state.index_buffer = null;
    state.uniform_buffer = null;
    state.bind_group = null;
    state.depth_texture = null;
    state.depth_view = null;
    state.cylinder_vertex_buffer = null;
    state.cylinder_index_buffer = null;
    state.hover_block = null;
    state.tas_replayer = null;

    // Initialize chunk
    state.chunk = Chunk.init();
    state.chunk.generateTerrain();

    // Initialize mesh
    state.mesh = Mesh.init(ctx.allocator());

    // Initialize camera
    const window_info = ctx.window();
    const aspect = @as(f32, @floatFromInt(window_info.width)) / @as(f32, @floatFromInt(window_info.height));

    // Spawn player with feet on terrain surface (grass top = y=8).
    state.player = Player.init(24.0, 8.0, 20.0);

    // Camera tracks player eye position; yaw/pitch set for a good starting view.
    const eye = state.player.eyePos();
    state.camera = CameraType.init(Vec3.init(eye[0], eye[1], eye[2]), aspect);
    state.camera.yaw = -std.math.pi / 2.0;
    state.camera.pitch = -0.3;

    // Cylinder scratch buffers (ArrayList new-API: no allocator at init time)
    state.cylinder_verts = std.ArrayList(VoxelVertex){};
    state.cylinder_indices = std.ArrayList(u32){};
    state.third_person = false;
    state.debug_mode = false;
    state.tas_step_mode = false;
    state.tas_step_pending = false;
    state.tas_step_executing = false;
    state.tas_current_tas_tick = 0;
    state.gpu_debug = false;

    state.mesh_dirty = true;
    state.mesh_incremental_dirty = false;
    state.mouse_captured = false;
    state.click_locked = false;
    state.paused_with_mouse = false;
    state.button_resume_hovered = false;
    state.button_quit_hovered = false;
    state.headless = false;

    // Initialize game state layer stack
    state.game_state = GameState.init();

    // Initialize overlay renderer
    state.overlay = OverlayRenderer.init(ctx.allocator());

    // Check for TAS script argument
    const args = try std.process.argsAlloc(ctx.allocator());
    defer std.process.argsFree(ctx.allocator(), args);

    // Pre-scan: collect all flags before processing --tas, so flag order doesn't matter.
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--headless")) state.headless = true;
        if (std.mem.eql(u8, arg, "--tas-step")) state.tas_step_mode = true;
        if (std.mem.eql(u8, arg, "--gpu-debug")) state.gpu_debug = true;
    }

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
            var replayer = core.Replayer.initDirect(ctx.allocator(), events);
            replayer.play();
            state.tas_replayer = replayer;

            if (state.tas_step_mode) {
                // Step mode: start paused so the user advances one tick at a time.
                // Physical input is NOT blocked — we need arrow keys for stepping.
                state.tas_replayer.?.pause();
                std.log.info("TAS step mode: press Right arrow to advance one tick", .{});
            } else {
                // Normal TAS: block physical input for deterministic replay.
                ctx.setInputBlocked(true);
            }

            // Enable debug mode automatically so the keyboard HUD shows TAS input live.
            state.debug_mode = true;
            // Auto-enable GPU debug in step mode so rebuilt faces are highlighted.
            if (state.tas_step_mode) state.gpu_debug = true;
            std.log.info("TAS replayer ready - starting playback (physical input blocked)!", .{});
            break;
        }
    }

    std.log.info("Voxel demo ready", .{});
}

fn voxelTick(ctx: *sw.Context) !void {
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

    // Cmd+T (macOS) / Ctrl+T (Windows/Linux) — toggle third-person camera
    if (input.keyPressed(.T) and (input.mods.super or input.mods.ctrl)) {
        state.third_person = !state.third_person;
        std.log.info("Third-person: {}", .{state.third_person});
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
            state.click_locked = true;
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

            state.player.tick(&state.chunk, dt, state.camera.yaw, fwd, rgt, jump, space_held, sprint);

            // Sync camera position to player eye (or third-person offset).
            const eye = state.player.eyePos();
            if (state.third_person) {
                const fwd_vec = state.camera.forward();
                state.camera.position = Vec3.init(
                    eye[0] - fwd_vec.x * 4.0,
                    eye[1] - fwd_vec.y * 4.0 + 0.5,
                    eye[2] - fwd_vec.z * 4.0,
                );
            } else {
                state.camera.position = Vec3.init(eye[0], eye[1], eye[2]);
            }
        }

        // Mouse look + block interaction — only when was already captured this tick
        // (was_captured = false on resume tick prevents camera jump)
        if (was_captured) {
            state.camera.rotate(
                input.mouse.delta_x,
                -input.mouse.delta_y, // Invert Y for natural feel
            );

            // Release click lock when button is not pressed
            if (!input.buttonPressed(.left)) {
                state.click_locked = false;
            }

            const cam_dir = state.camera.forward();
            const hit = raycast(&state.chunk, state.camera.position, cam_dir, 5.0);

            if (hit.hit) {
                state.hover_block = hit.block_pos;

                // Left click: destroy block (one block per click)
                if (input.buttonPressed(.left) and !state.click_locked) {
                    state.click_locked = true;
                    const bx: i32 = @intFromFloat(hit.block_pos.x);
                    const by: i32 = @intFromFloat(hit.block_pos.y);
                    const bz: i32 = @intFromFloat(hit.block_pos.z);
                    state.chunk.setBlock(bx, by, bz, .air);
                    const t_incr0 = std.time.nanoTimestamp();
                    state.mesh.updateForBlockChange(&state.chunk, bx, by, bz, .{ state.camera.position.x, state.camera.position.y, state.camera.position.z }) catch |err| {
                        std.log.err("Incremental mesh update failed: {} — falling back to full regen", .{err});
                        state.mesh_dirty = true;
                    };
                    const t_incr_us = @divTrunc(std.time.nanoTimestamp() - t_incr0, 1000);
                    std.log.info("[TICK  tick={d:4}] incremental remove ({},{},{}) update={}us", .{ ctx.tickId(), bx, by, bz, t_incr_us });
                    state.mesh_incremental_dirty = true;
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
                    state.chunk.setBlock(px, py, pz, .stone);
                    const t_incr0 = std.time.nanoTimestamp();
                    state.mesh.updateForBlockChange(&state.chunk, px, py, pz, .{ state.camera.position.x, state.camera.position.y, state.camera.position.z }) catch |err| {
                        std.log.err("Incremental mesh update failed: {} — falling back to full regen", .{err});
                        state.mesh_dirty = true;
                    };
                    const t_incr_us = @divTrunc(std.time.nanoTimestamp() - t_incr0, 1000);
                    std.log.info("[TICK  tick={d:4}] incremental place ({},{},{}) update={}us", .{ ctx.tickId(), px, py, pz, t_incr_us });
                    state.mesh_incremental_dirty = true;
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
        state.mesh.decayHighlights(4);
    }
}

// ─── Step-mode HUD ───────────────────────────────────────────────────────────
// 5×7 bitmap font for digits 0–9. Each digit is 7 rows of 5 bits (MSB = left).
const DIGIT_W: f32 = 5;
const DIGIT_H: f32 = 7;
const DIGIT_SCALE: f32 = 3; // each "pixel" is 3×3 screen pixels
const DIGIT_STEP: f32 = (DIGIT_W + 1) * DIGIT_SCALE; // advance per character

const digit_bitmaps = [10][7]u5{
    .{ 0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110 }, // 0
    .{ 0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 }, // 1
    .{ 0b01110, 0b10001, 0b00001, 0b00110, 0b01000, 0b10000, 0b11111 }, // 2
    .{ 0b11111, 0b00010, 0b00100, 0b00110, 0b00001, 0b10001, 0b01110 }, // 3
    .{ 0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010 }, // 4
    .{ 0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110 }, // 5
    .{ 0b01110, 0b10000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110 }, // 6
    .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000 }, // 7
    .{ 0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110 }, // 8
    .{ 0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00001, 0b01110 }, // 9
};

fn drawDigit(overlay: *OverlayRenderer, digit: u8, x: f32, y: f32, col: [4]f32, ow: f32, oh: f32) !void {
    if (digit > 9) return;
    const bm = digit_bitmaps[digit];
    for (bm, 0..) |row, ry| {
        for (0..5) |cx| {
            const bit: u3 = @intCast(4 - cx);
            if ((row >> bit) & 1 == 1) {
                const px = x + @as(f32, @floatFromInt(cx)) * DIGIT_SCALE;
                const py = y + @as(f32, @floatFromInt(ry)) * DIGIT_SCALE;
                try overlay.rect(px, py, DIGIT_SCALE, DIGIT_SCALE, col, ow, oh);
            }
        }
    }
}

fn drawNumber(overlay: *OverlayRenderer, n: u64, x: f32, y: f32, col: [4]f32, ow: f32, oh: f32) !void {
    // Write digits right-to-left into a small fixed buffer, then draw L-to-R.
    var buf: [20]u8 = undefined;
    var len: usize = 0;
    var val = n;
    if (val == 0) {
        buf[0] = 0;
        len = 1;
    } else {
        while (val > 0) {
            buf[len] = @intCast(val % 10);
            len += 1;
            val /= 10;
        }
        // Reverse
        var lo: usize = 0;
        var hi: usize = len - 1;
        while (lo < hi) {
            const tmp = buf[lo];
            buf[lo] = buf[hi];
            buf[hi] = tmp;
            lo += 1;
            hi -= 1;
        }
    }
    for (buf[0..len], 0..) |d, i| {
        try drawDigit(overlay, d, x + @as(f32, @floatFromInt(i)) * DIGIT_STEP, y, col, ow, oh);
    }
}

fn drawStepHud(
    overlay: *OverlayRenderer,
    tas_tick: u64,
    is_executing: bool,
    is_finished: bool,
    current_index: usize,
    total_events: usize,
    ow: f32,
    oh: f32,
) !void {
    const pad: f32 = 8;
    const bar_h: f32 = DIGIT_H * DIGIT_SCALE + pad * 2;
    const bar_w: f32 = 260;
    const bx = (ow - bar_w) / 2.0;
    const by: f32 = 6;

    // Background
    try overlay.rect(bx, by, bar_w, bar_h, .{ 0.04, 0.04, 0.08, 0.88 }, ow, oh);

    // State pill: green = executing step, amber = waiting for Right arrow, grey = finished
    const pill_col: [4]f32 = if (is_finished)
        .{ 0.55, 0.55, 0.55, 1.0 }
    else if (is_executing)
        .{ 0.25, 0.92, 0.35, 1.0 }
    else
        .{ 0.95, 0.72, 0.10, 1.0 };
    try overlay.rect(bx + pad, by + pad, 16, DIGIT_H * DIGIT_SCALE, pill_col, ow, oh);

    // "TICK" label — four small squares in a row, colour matches state
    const lbl_x = bx + pad + 16 + 6;
    const digit_y = by + pad;

    // Draw TAS tick number
    const white = [4]f32{ 0.95, 0.95, 0.95, 1.0 };
    try drawNumber(overlay, tas_tick, lbl_x, digit_y, white, ow, oh);

    // Progress bar (events consumed / total) at the bottom of the panel
    const prog_y = by + bar_h - 5;
    const prog_w = bar_w - pad * 2;
    try overlay.rect(bx + pad, prog_y, prog_w, 3, .{ 0.2, 0.2, 0.25, 0.9 }, ow, oh);
    if (total_events > 0) {
        const frac = @as(f32, @floatFromInt(current_index)) / @as(f32, @floatFromInt(total_events));
        try overlay.rect(bx + pad, prog_y, prog_w * frac, 3, pill_col, ow, oh);
    }
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

    // Regenerate mesh if chunk changed
    const was_dirty = state.mesh_dirty;
    var t_mesh_us: i128 = 0;
    if (state.mesh_dirty) {
        const t0 = std.time.nanoTimestamp();
        mesher_mod.generateMesh(&state.chunk, &state.mesh) catch |err| {
            std.log.err("Failed to generate mesh: {}", .{err});
            return;
        };
        t_mesh_us = @divTrunc(std.time.nanoTimestamp() - t0, 1000);
        state.mesh_dirty = false;
    }

    // Sort mesh by depth every frame (painter's algorithm for correct rendering without depth testing)
    var t_sort_us: i128 = 0;
    var t_upload_us: i128 = 0;
    if (state.mesh.vertices.items.len > 0) {
        const t1 = std.time.nanoTimestamp();
        state.mesh.sortByDepth(.{
            state.camera.position.x,
            state.camera.position.y,
            state.camera.position.z,
        }) catch |err| {
            std.log.err("Failed to sort mesh: {}", .{err});
            return;
        };
        t_sort_us = @divTrunc(std.time.nanoTimestamp() - t1, 1000);

        const t2 = std.time.nanoTimestamp();
        uploadMeshToGPU(g, was_dirty) catch |err| {
            std.log.err("Failed to upload mesh: {}", .{err});
            return;
        };
        t_upload_us = @divTrunc(std.time.nanoTimestamp() - t2, 1000);
    }

    // Per-frame timing log — always emit so we can compare normal vs spike frame
    std.log.info("[RENDER tick={d:4}] dirty={} mesh={d:5}us sort={d:5}us upload={d:5}us  total={d:5}us", .{
        ctx.tickId(),
        was_dirty,
        t_mesh_us,
        t_sort_us,
        t_upload_us,
        t_mesh_us + t_sort_us + t_upload_us,
    });

    // Update uniforms
    const view_proj = state.camera.getViewProjectionMatrix();

    const hover_active: f32 = if (state.hover_block != null) 1.0 else 0.0;
    const hover_pos = state.hover_block orelse Vec3.init(0, 0, 0);

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
    };

    g.writeBuffer(state.uniform_buffer.?, 0, std.mem.sliceAsBytes(&uniforms));

    // Render
    const encoder = g.createCommandEncoder() catch |err| {
        std.log.err("Failed to create encoder: {}", .{err});
        return;
    };

    var view = g.getCurrentTextureView() catch |err| {
        std.log.err("Failed to get texture view: {}", .{err});
        return;
    };
    defer view.release();

    const pass = encoder.beginRenderPass(.{
        .color_attachments = &[_]gpu_mod.RenderPassColorAttachment{.{
            .view = &view,
            .load_op = .clear,
            .store_op = .store,
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

    pass.setPipeline(state.pipeline.?);
    pass.setBindGroup(0, state.bind_group.?);

    if (state.mesh.vertices.items.len > 0) {
        const vertex_count = state.mesh.vertices.items.len;
        const index_count = state.mesh.indices.items.len;

        pass.setVertexBuffer(0, state.vertex_buffer.?, 0, vertex_count * @sizeOf(VoxelVertex));
        pass.setIndexBuffer(state.index_buffer.?, .uint32, 0, index_count * @sizeOf(u32));

        const index_count_u32: u32 = @intCast(index_count);
        pass.drawIndexed(index_count_u32, 1, 0, 0, 0);
    }

    // =========================================================================
    // Player hitbox cylinder (drawn after voxels; no face culling so always visible)
    // =========================================================================
    if (state.debug_mode and state.cylinder_pipeline != null and state.cylinder_vertex_buffer != null) {
        player_mod.buildCylinderMesh(
            state.player.feet_pos,
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
    // Overlay rendering (2D UI on top of 3D world)
    // =========================================================================
    state.overlay.ensurePipeline(g) catch |err| {
        std.log.err("Failed to ensure overlay pipeline: {}", .{err});
    };

    state.overlay.begin();

    // HUD: crosshair (visible when playing, not paused)
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
    }

    // Debug overlay: sidebar with placeholder colored bars
    if (state.game_state.isLayerActive(.debug_overlay)) {
        const bar_w: f32 = 180;
        state.overlay.rect(0, 0, bar_w, overlay_h, .{ 0.0, 0.0, 0.0, 0.5 }, overlay_w, overlay_h) catch {};
        // Placeholder colored bars (future: FPS, pos, chunk info text lines)
        const colors = [_][4]f32{
            .{ 0.2, 0.8, 0.2, 1.0 },
            .{ 0.8, 0.8, 0.2, 1.0 },
            .{ 0.2, 0.5, 0.9, 1.0 },
            .{ 0.9, 0.4, 0.2, 1.0 },
        };
        for (colors, 0..) |col, idx| {
            const bar_y = 8.0 + @as(f32, @floatFromInt(idx)) * 20.0;
            state.overlay.rect(8, bar_y, 100, 14, col, overlay_w, overlay_h) catch {};
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

    g.submit(&[_]gpu_mod.CommandBuffer{cmd});
    g.present();
}

fn voxelShutdown(ctx: *sw.Context) !void {
    state.mesh.deinit();
    state.overlay.deinit();
    state.cylinder_verts.deinit(ctx.allocator());
    state.cylinder_indices.deinit(ctx.allocator());

    if (state.tas_replayer) |*replayer| {
        replayer.deinit();
    }

    std.log.info("Voxel demo shutdown", .{});
}

fn setupGPUResources(g: *gpu_mod.GPU, width: u32, height: u32) !void {
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

fn uploadMeshToGPU(g: *gpu_mod.GPU, mesh_rebuilt: bool) !void {
    const vertex_count = state.mesh.vertices.items.len;
    const index_count = state.mesh.indices.items.len;
    const sorted = state.mesh.sort_indices[0..index_count];
    const structure_changed = mesh_rebuilt or state.mesh_incremental_dirty;

    if (structure_changed) {
        // Vertex/index count changed — recreate GPU buffers.
        if (state.vertex_buffer) |old_buf| old_buf.destroy();
        state.vertex_buffer = try g.createBuffer(.{
            .size = vertex_count * @sizeOf(VoxelVertex),
            .usage = .{ .vertex = true, .copy_dst = true },
        });

        if (state.index_buffer) |old_buf| old_buf.destroy();
        state.index_buffer = try g.createBuffer(.{
            .size = index_count * @sizeOf(u32),
            .usage = .{ .index = true, .copy_dst = true },
        });

        state.mesh_incremental_dirty = false;
    }

    // Write vertex data when structure changed, or every frame when gpu_debug
    // (highlight values decay each tick, so block_type upper bits change).
    if (structure_changed or state.gpu_debug) {
        if (state.gpu_debug) {
            // Temporarily encode highlight intensity into upper 8 bits of block_type.
            const quad_count = vertex_count / 4;
            for (0..quad_count) |qi| {
                const hl = state.mesh.quad_highlight.items[qi];
                if (hl > 0) {
                    const hl32 = @as(u32, hl) << 16;
                    const base = qi * 4;
                    for (base..base + 4) |vi| {
                        state.mesh.vertices.items[vi].block_type |= hl32;
                    }
                }
            }
        }

        g.writeBuffer(state.vertex_buffer.?, 0, std.mem.sliceAsBytes(state.mesh.vertices.items));

        if (state.gpu_debug) {
            // Restore block_type — remove highlight bits so mesh data stays clean.
            const quad_count = vertex_count / 4;
            for (0..quad_count) |qi| {
                const hl = state.mesh.quad_highlight.items[qi];
                if (hl > 0) {
                    const base = qi * 4;
                    for (base..base + 4) |vi| {
                        state.mesh.vertices.items[vi].block_type &= 0xFFFF;
                    }
                }
            }
        }
    }

    // Always write sorted indices — order changes every frame as camera moves.
    g.writeBuffer(state.index_buffer.?, 0, std.mem.sliceAsBytes(sorted));
}
