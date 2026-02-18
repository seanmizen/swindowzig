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
    hover_block: ?Vec3 = null, // Block currently under the crosshair (null = none)
    tas_replayer: ?core.Replayer = null,
    tas_events: ?std.ArrayList(core.Event) = null,
};

var state: State = undefined;

fn voxelInit(ctx: *sw.Context) !void {
    std.log.info("Voxel demo init", .{});

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

    // Record capture state at the START of this tick (before we potentially change it).
    // Block interaction only runs when the mouse was ALREADY captured — Minecraft's behavior:
    // first click captures only, never also destroys.
    const was_captured = state.mouse_captured;

    // Click to capture mouse
    if (!state.mouse_captured and input.buttonPressed(.left)) {
        state.mouse_captured = true;
        ctx.setMouseCapture(true);
        state.click_locked = true; // Don't act on the capture click
        std.log.info("Mouse captured (clicked)", .{});
    }

    // ESC to release mouse
    if (state.mouse_captured and input.keyPressed(.Escape)) {
        state.mouse_captured = false;
        ctx.setMouseCapture(false);
        std.log.info("Mouse released (ESC)", .{});
    }

    const dt = @as(f32, @floatFromInt(ctx.dtNs())) / 1_000_000_000.0;

    // Movement (WASD + Space/Shift) - works always
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

    // Mouse look + block interaction (only when mouse was already captured this tick)
    if (was_captured) {
        state.camera.rotate(
            input.mouse.delta_x,
            -input.mouse.delta_y, // Invert Y for natural feel
        );

        // Release click lock when button is not pressed — debounce against multi-tick button events
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

            // Right click: place block on adjacent face (one block per click)
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
}

fn voxelRender(ctx: *sw.Context) !void {
    const g = ctx.gpu();

    // Check if GPU is ready
    if (!g.isReady()) {
        return;
    }

    // Update aspect ratio if window resized
    const window_info = ctx.window();
    const aspect = @as(f32, @floatFromInt(window_info.width)) / @as(f32, @floatFromInt(window_info.height));
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

    // Create/recreate vertex buffer
    if (state.vertex_buffer) |old_buf| {
        _ = old_buf; // TODO: release old buffer
    }
    state.vertex_buffer = try g.createBuffer(.{
        .size = vertex_bytes,
        .usage = .{ .vertex = true, .copy_dst = true },
    });
    g.writeBuffer(state.vertex_buffer.?, 0, std.mem.sliceAsBytes(state.mesh.vertices.items));

    // Create/recreate index buffer
    if (state.index_buffer) |old_buf| {
        _ = old_buf; // TODO: release old buffer
    }
    state.index_buffer = try g.createBuffer(.{
        .size = index_bytes,
        .usage = .{ .index = true, .copy_dst = true },
    });
    g.writeBuffer(state.index_buffer.?, 0, std.mem.sliceAsBytes(state.mesh.indices.items));
}
