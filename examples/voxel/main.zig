const std = @import("std");
const sw = @import("sw_app");
const gpu_mod = @import("sw_gpu");
const core = @import("sw_core");
const math = @import("sw_math");

pub fn main() !void {
    try sw.run(.{
        .title = "Voxel Demo - Minecraft Creative Mode",
        .size = .{ .w = 1280, .h = 720 },
        .tick_hz = 120,
    }, Callbacks);
}

const Callbacks = struct {
    pub fn init(ctx: *sw.Context) !void {
        try voxelInit(ctx);
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

// Pause menu button geometry (in logical pixels)
const RESUME_BTN_W: f32 = 200;
const RESUME_BTN_H: f32 = 40;
const BTN_GAP: f32 = 12; // gap between resume and quit buttons

// Application state
const State = struct {
    chunk: Chunk,
    mesh: Mesh,
    camera: CameraType,
    pipeline: ?gpu_mod.RenderPipeline = null,
    vertex_buffer: ?gpu_mod.Buffer = null,
    index_buffer: ?gpu_mod.Buffer = null,
    uniform_buffer: ?gpu_mod.Buffer = null,
    bind_group: ?gpu_mod.BindGroup = null,
    depth_texture: ?gpu_mod.Texture = null,
    depth_view: ?gpu_mod.TextureView = null,
    mesh_dirty: bool = true,
    mouse_captured: bool = false,
    click_locked: bool = false,
    paused_with_mouse: bool = false,
    button_resume_hovered: bool = false,
    button_quit_hovered: bool = false,
    hover_block: ?Vec3 = null,
    game_state: GameState = undefined,
    overlay: OverlayRenderer = undefined,
    tas_replayer: ?core.Replayer = null,
    tas_events: ?std.ArrayList(core.Event) = null,
};

var state: State = undefined;

fn voxelInit(ctx: *sw.Context) !void {
    std.log.info("Voxel demo init", .{});

    // Explicitly null all optional fields — `var state: State = undefined` bypasses struct defaults
    state.pipeline = null;
    state.vertex_buffer = null;
    state.index_buffer = null;
    state.uniform_buffer = null;
    state.bind_group = null;
    state.depth_texture = null;
    state.depth_view = null;
    state.hover_block = null;
    state.tas_replayer = null;
    state.tas_events = null;

    // Initialize chunk
    state.chunk = Chunk.init();
    state.chunk.generateTerrain();

    // Initialize mesh
    state.mesh = Mesh.init(ctx.allocator());

    // Initialize camera
    const window_info = ctx.window();
    const aspect = @as(f32, @floatFromInt(window_info.width)) / @as(f32, @floatFromInt(window_info.height));

    // Position camera for good view of the wider flat world (48x48 chunk)
    state.camera = CameraType.init(Vec3.init(24, 14, 44), aspect);

    // Point camera towards the chunk center
    state.camera.yaw = -std.math.pi / 2.0; // Look in -Z direction
    state.camera.pitch = -0.3; // Downward angle

    state.mesh_dirty = true;
    state.mouse_captured = false;
    state.click_locked = false;
    state.paused_with_mouse = false;
    state.button_resume_hovered = false;
    state.button_quit_hovered = false;

    // Initialize game state layer stack
    state.game_state = GameState.init();

    // Initialize overlay renderer
    state.overlay = OverlayRenderer.init(ctx.allocator());

    // Check for TAS script argument
    const args = try std.process.argsAlloc(ctx.allocator());
    defer std.process.argsFree(ctx.allocator(), args);

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

            // Convert to events
            const events = try tas_script.toEvents(120); // 120 Hz tick rate
            state.tas_events = events;

            std.log.info("TAS script loaded: {} commands, {} ticks duration", .{
                tas_script.entries.items.len,
                tas_script.getDuration(),
            });

            // Create replayer from events
            var replay_buffer = std.ArrayList(u8){};
            var serializer = core.serialize.Serializer.init(replay_buffer.writer(ctx.allocator()).any());
            try serializer.writeHeader(120);
            for (events.items) |event| {
                try serializer.writeEvent(event);
            }

            var fbs = std.io.fixedBufferStream(replay_buffer.items);
            var replayer = try core.Replayer.init(ctx.allocator(), fbs.reader().any());
            try replayer.loadAll();
            replayer.play();

            state.tas_replayer = replayer;

            std.log.info("TAS replayer ready - starting playback!", .{});
            break;
        }
    }

    std.log.info("Voxel demo ready", .{});
}

fn voxelTick(ctx: *sw.Context) !void {
    // Feed TAS events if replaying
    if (state.tas_replayer) |*replayer| {
        try replayer.feedTick(ctx.tickId(), ctx.bus());

        // Log playback status
        if (ctx.tickId() % 60 == 0) {
            std.log.info("TAS playback: tick={} state={}", .{ ctx.tickId(), replayer.state });
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

    if (input.keyPressed(.F3)) {
        state.game_state.toggleDebugOverlay();
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
    if (state.game_state.gameplayReceivesInput()) {
        // Click to capture mouse (first click after startup / after resume)
        if (!state.mouse_captured and input.buttonPressed(.left)) {
            state.mouse_captured = true;
            ctx.setMouseCapture(true);
            state.click_locked = true;
            std.log.info("Mouse captured (clicked)", .{});
        }

        // WASD movement (only when mouse is captured)
        if (state.mouse_captured) {
            var forward: f32 = 0;
            var right: f32 = 0;
            var up: f32 = 0;

            if (input.keyDown(.W)) forward += 1;
            if (input.keyDown(.S)) forward -= 1;
            if (input.keyDown(.D)) right += 1;
            if (input.keyDown(.A)) right -= 1;
            if (input.keyDown(.Space)) up += 1;
            if (input.keyDown(.Shift)) up -= 1;

            state.camera.move(forward, right, up, dt);
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
                    state.mesh_dirty = true;
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
                    state.mesh_dirty = true;
                }
            } else {
                state.hover_block = null;
            }
        } else {
            state.hover_block = null;
        }
    } else {
        // Pause menu or another captures_all layer is blocking gameplay
        state.hover_block = null;
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
    if (state.mesh_dirty) {
        mesher_mod.generateMesh(&state.chunk, &state.mesh) catch |err| {
            std.log.err("Failed to generate mesh: {}", .{err});
            return;
        };

        state.mesh_dirty = false;
    }

    // Sort mesh by depth every frame (painter's algorithm for correct rendering without depth testing)
    if (state.mesh.vertices.items.len > 0) {
        state.mesh.sortByDepth(.{
            state.camera.position.x,
            state.camera.position.y,
            state.camera.position.z,
        }) catch |err| {
            std.log.err("Failed to sort mesh: {}", .{err});
            return;
        };

        uploadMeshToGPU(g) catch |err| {
            std.log.err("Failed to upload mesh: {}", .{err});
            return;
        };
    }

    // Update uniforms
    const view_proj = state.camera.getViewProjectionMatrix();

    const hover_active: f32 = if (state.hover_block != null) 1.0 else 0.0;
    const hover_pos = state.hover_block orelse Vec3.init(0, 0, 0);

    const uniforms = [_]f32{
        // view_proj (16 floats)
        view_proj.data[0],  view_proj.data[1],  view_proj.data[2],  view_proj.data[3],
        view_proj.data[4],  view_proj.data[5],  view_proj.data[6],  view_proj.data[7],
        view_proj.data[8],  view_proj.data[9],  view_proj.data[10], view_proj.data[11],
        view_proj.data[12], view_proj.data[13], view_proj.data[14], view_proj.data[15],
        // camera_pos + padding (4 floats)
        state.camera.position.x, state.camera.position.y, state.camera.position.z, 0,
        // hover_block + hover_active (4 floats)
        hover_pos.x, hover_pos.y, hover_pos.z, hover_active,
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

    if (state.tas_replayer) |*replayer| {
        replayer.deinit();
    }

    if (state.tas_events) |*events| {
        events.deinit(ctx.allocator());
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

    // Create render pipeline
    state.pipeline = try g.createRenderPipeline(.{
        .layout = &pipeline_layout,
        .vertex = .{
            .module = &shader,
            .entry_point = "vs_main",
            .buffers = &[_]sw.gpu_types.VertexBufferLayout{.{
                .array_stride = @sizeOf(VoxelVertex),
                .attributes = &[_]sw.gpu_types.VertexAttribute{
                    .{ .format = .float32x3, .offset = 0, .shader_location = 0 }, // pos
                    .{ .format = .float32x3, .offset = 12, .shader_location = 1 }, // normal
                    .{ .format = .uint32, .offset = 24, .shader_location = 2 }, // block_type
                    .{ .format = .float32x2, .offset = 28, .shader_location = 3 }, // uv
                },
            }},
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
            .cull_mode = .back, // Back-face culling
        },
        // WORKAROUND: Hardware depth testing crashes on Metal (wgpu-native v0.19.4.1 bug)
        // Using software depth sorting (painter's algorithm) instead - see sortByDepth()
        // .depth_stencil = .{
        //     .format = .depth32float,
        //     .depth_write_enabled = true,
        //     .depth_compare = .less,
        // },
    });

    std.log.info("GPU resources created", .{});
}

fn uploadMeshToGPU(g: *gpu_mod.GPU) !void {
    const vertex_bytes = state.mesh.vertices.items.len * @sizeOf(VoxelVertex);
    const index_bytes = state.mesh.indices.items.len * @sizeOf(u32);

    // Create/recreate vertex buffer (destroy old one first to avoid leak)
    if (state.vertex_buffer) |old_buf| {
        old_buf.destroy();
    }
    state.vertex_buffer = try g.createBuffer(.{
        .size = vertex_bytes,
        .usage = .{ .vertex = true, .copy_dst = true },
    });
    g.writeBuffer(state.vertex_buffer.?, 0, std.mem.sliceAsBytes(state.mesh.vertices.items));

    // Create/recreate index buffer (destroy old one first to avoid leak)
    if (state.index_buffer) |old_buf| {
        old_buf.destroy();
    }
    state.index_buffer = try g.createBuffer(.{
        .size = index_bytes,
        .usage = .{ .index = true, .copy_dst = true },
    });
    g.writeBuffer(state.index_buffer.?, 0, std.mem.sliceAsBytes(state.mesh.indices.items));
}
