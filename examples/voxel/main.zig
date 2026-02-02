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
    state.camera = CameraType.init(Vec3.init(8, 12, 20), aspect);

    // Point camera towards the chunk (in -Z direction with slight downward tilt)
    state.camera.yaw = -std.math.pi / 2.0; // Look in -Z direction
    state.camera.pitch = -0.3; // Slight downward angle

    state.mesh_dirty = true;
    state.mouse_captured = false;

    std.log.info("Voxel demo ready", .{});
}

fn voxelTick(ctx: *sw.Context) !void {
    const input = ctx.input();

    // Click to capture mouse
    if (!state.mouse_captured and input.buttonPressed(.left)) {
        state.mouse_captured = true;
        ctx.setMouseCapture(true);
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

    // Debug: Log movement input
    if (forward != 0 or right != 0 or up != 0) {
        const dt_ns = ctx.dtNs();
        std.log.info("Movement input: forward={d:.1}, right={d:.1}, up={d:.1}, dt_ns={}, dt={d:.6}", .{ forward, right, up, dt_ns, dt });
    }

    state.camera.move(forward, right, up, dt);

    // Mouse look (only when captured)
    if (state.mouse_captured) {
        if (input.mouse.delta_x != 0 or input.mouse.delta_y != 0) {
            std.log.info("Mouse delta: dx={d:.1}, dy={d:.1}", .{ input.mouse.delta_x, input.mouse.delta_y });
        }
        state.camera.rotate(
            input.mouse.delta_x,
            -input.mouse.delta_y, // Invert Y for natural feel
        );

        // Block interaction
        const cam_dir = state.camera.forward();
        const hit = raycast(&state.chunk, state.camera.position, cam_dir, 10.0);

        if (hit.hit) {
            // Left click: destroy block
            if (input.buttonPressed(.left)) {
                const bx: i32 = @intFromFloat(hit.block_pos.x);
                const by: i32 = @intFromFloat(hit.block_pos.y);
                const bz: i32 = @intFromFloat(hit.block_pos.z);
                state.chunk.setBlock(bx, by, bz, .air);
                state.mesh_dirty = true;
            }

            // Right click: place block
            if (input.buttonPressed(.right)) {
                // Place on the face that was hit
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
        }
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
        setupGPUResources(g) catch |err| {
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

        if (state.mesh.vertices.items.len > 0) {
            uploadMeshToGPU(g) catch |err| {
                std.log.err("Failed to upload mesh: {}", .{err});
                return;
            };
        }

        state.mesh_dirty = false;
        std.log.info("Mesh regenerated: {} vertices, {} indices", .{ state.mesh.vertices.items.len, state.mesh.indices.items.len });
    }

    // Update uniforms
    const view_proj = state.camera.getViewProjectionMatrix();

    // Debug: log camera direction on first frame
    if (ctx.tickId() == 1) {
        const fwd = state.camera.forward();
        std.log.info("Camera forward: ({d:.2}, {d:.2}, {d:.2}), yaw: {d:.2}, pitch: {d:.2}", .{
            fwd.x, fwd.y, fwd.z, state.camera.yaw, state.camera.pitch,
        });
        std.log.info("ViewProj matrix [0-3]: {d:.3} {d:.3} {d:.3} {d:.3}", .{
            view_proj.data[0], view_proj.data[1], view_proj.data[2], view_proj.data[3],
        });
    }

    const uniforms = [_]f32{
        view_proj.data[0],  view_proj.data[1],  view_proj.data[2],  view_proj.data[3],
        view_proj.data[4],  view_proj.data[5],  view_proj.data[6],  view_proj.data[7],
        view_proj.data[8],  view_proj.data[9],  view_proj.data[10], view_proj.data[11],
        view_proj.data[12], view_proj.data[13], view_proj.data[14], view_proj.data[15],
        state.camera.position.x, state.camera.position.y, state.camera.position.z, 0, // camera_pos + padding
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
        // TODO: Re-enable depth attachment
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
        pass.setVertexBuffer(0, state.vertex_buffer.?, 0, state.mesh.vertices.items.len * @sizeOf(VoxelVertex));
        pass.setIndexBuffer(state.index_buffer.?, .uint32, 0, state.mesh.indices.items.len * @sizeOf(u32));
        pass.drawIndexed(@intCast(state.mesh.indices.items.len), 1, 0, 0, 0);
    }

    pass.end();

    const cmd = encoder.finish() catch |err| {
        std.log.err("Failed to finish encoder: {}", .{err});
        return;
    };

    g.submit(&[_]gpu_mod.CommandBuffer{cmd});
    g.present();

    // Print FPS occasionally
    if (ctx.tickId() % 120 == 0) {
        std.log.info("Camera: ({d:.1}, {d:.1}, {d:.1}) | Captured: {} | Vertices: {}", .{
            state.camera.position.x,
            state.camera.position.y,
            state.camera.position.z,
            state.mouse_captured,
            state.mesh.vertices.items.len,
        });
    }
}

fn voxelShutdown(ctx: *sw.Context) !void {
    _ = ctx;
    state.mesh.deinit();
    std.log.info("Voxel demo shutdown", .{});
}

fn setupGPUResources(g: *gpu_mod.GPU) !void {
    // Load shader
    const shader_code = @embedFile("voxel.wgsl");
    var shader = try g.createShaderModule(.{ .code = shader_code });

    // TODO: Re-enable depth texture once we fix the native WebGPU texture creation
    // For now, skip depth testing to get the demo running
    // const depth_tex = try g.createTexture(.{
    //     .size = .{ .width = 1280, .height = 720, .depth_or_array_layers = 1 },
    //     .format = .depth32float,
    //     .usage = .{ .render_attachment = true },
    // });
    // state.depth_texture = depth_tex;
    // state.depth_view = try depth_tex.createView(.{});

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
            .cull_mode = .none, // Temporarily disable culling to debug
        },
        // TODO: Re-enable depth testing
        // .depth_stencil = .{
        //     .format = .depth32float,
        //     .depth_write_enabled = true,
        //     .depth_compare = .less,
        // },
    });

    std.log.info("GPU resources created", .{});
}

fn uploadMeshToGPU(g: *gpu_mod.GPU) !void {
    // Create/recreate vertex buffer
    if (state.vertex_buffer) |old_buf| {
        _ = old_buf; // TODO: release old buffer
    }
    state.vertex_buffer = try g.createBuffer(.{
        .size = state.mesh.vertices.items.len * @sizeOf(VoxelVertex),
        .usage = .{ .vertex = true, .copy_dst = true },
    });
    g.writeBuffer(state.vertex_buffer.?, 0, std.mem.sliceAsBytes(state.mesh.vertices.items));

    // Create/recreate index buffer
    if (state.index_buffer) |old_buf| {
        _ = old_buf; // TODO: release old buffer
    }
    state.index_buffer = try g.createBuffer(.{
        .size = state.mesh.indices.items.len * @sizeOf(u32),
        .usage = .{ .index = true, .copy_dst = true },
    });
    g.writeBuffer(state.index_buffer.?, 0, std.mem.sliceAsBytes(state.mesh.indices.items));
}
