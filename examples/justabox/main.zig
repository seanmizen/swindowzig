// justabox - A single colored box that slowly spins.
// Dead simple. MEGA KISS. No camera movement, no input, no complexity.
const std = @import("std");
const sw = @import("sw_app");
const sw_math = @import("sw_math");
const gpu_mod = @import("sw_gpu");

pub fn main() !void {
    try sw.run(.{
        .title = "justabox",
        .size = .{ .w = 800, .h = 600 },
        .tick_hz = 60,
    }, Callbacks);
}

const Vertex = struct {
    position: [3]f32,
    color: [3]f32,
};

// 6 faces, 4 vertices each = 24 vertices total
// Each face gets a distinct color. CCW winding for back-face culling.
// Face order: +X (red), -X (cyan), +Y (green), -Y (magenta), +Z (blue), -Z (yellow)
const cube_vertices = [24]Vertex{
    // +X face (red): right side
    .{ .position = .{ 0.5, -0.5, -0.5 }, .color = .{ 1.0, 0.2, 0.2 } },
    .{ .position = .{ 0.5,  0.5, -0.5 }, .color = .{ 1.0, 0.2, 0.2 } },
    .{ .position = .{ 0.5,  0.5,  0.5 }, .color = .{ 1.0, 0.2, 0.2 } },
    .{ .position = .{ 0.5, -0.5,  0.5 }, .color = .{ 1.0, 0.2, 0.2 } },

    // -X face (cyan): left side
    .{ .position = .{ -0.5, -0.5,  0.5 }, .color = .{ 0.2, 1.0, 1.0 } },
    .{ .position = .{ -0.5,  0.5,  0.5 }, .color = .{ 0.2, 1.0, 1.0 } },
    .{ .position = .{ -0.5,  0.5, -0.5 }, .color = .{ 0.2, 1.0, 1.0 } },
    .{ .position = .{ -0.5, -0.5, -0.5 }, .color = .{ 0.2, 1.0, 1.0 } },

    // +Y face (green): top
    .{ .position = .{ -0.5, 0.5, -0.5 }, .color = .{ 0.2, 1.0, 0.2 } },
    .{ .position = .{ -0.5, 0.5,  0.5 }, .color = .{ 0.2, 1.0, 0.2 } },
    .{ .position = .{  0.5, 0.5,  0.5 }, .color = .{ 0.2, 1.0, 0.2 } },
    .{ .position = .{  0.5, 0.5, -0.5 }, .color = .{ 0.2, 1.0, 0.2 } },

    // -Y face (magenta): bottom
    .{ .position = .{  0.5, -0.5, -0.5 }, .color = .{ 1.0, 0.2, 1.0 } },
    .{ .position = .{  0.5, -0.5,  0.5 }, .color = .{ 1.0, 0.2, 1.0 } },
    .{ .position = .{ -0.5, -0.5,  0.5 }, .color = .{ 1.0, 0.2, 1.0 } },
    .{ .position = .{ -0.5, -0.5, -0.5 }, .color = .{ 1.0, 0.2, 1.0 } },

    // +Z face (blue): front
    .{ .position = .{ -0.5, -0.5, 0.5 }, .color = .{ 0.2, 0.2, 1.0 } },
    .{ .position = .{  0.5, -0.5, 0.5 }, .color = .{ 0.2, 0.2, 1.0 } },
    .{ .position = .{  0.5,  0.5, 0.5 }, .color = .{ 0.2, 0.2, 1.0 } },
    .{ .position = .{ -0.5,  0.5, 0.5 }, .color = .{ 0.2, 0.2, 1.0 } },

    // -Z face (yellow): back
    .{ .position = .{  0.5, -0.5, -0.5 }, .color = .{ 1.0, 1.0, 0.2 } },
    .{ .position = .{ -0.5, -0.5, -0.5 }, .color = .{ 1.0, 1.0, 0.2 } },
    .{ .position = .{ -0.5,  0.5, -0.5 }, .color = .{ 1.0, 1.0, 0.2 } },
    .{ .position = .{  0.5,  0.5, -0.5 }, .color = .{ 1.0, 1.0, 0.2 } },
};

// Base indices for one face (quad = 2 triangles, CCW)
const face_indices_base = [6]u16{ 0, 1, 2, 0, 2, 3 };

// 6 faces x 6 indices = 36 total indices
const num_faces = 6;
var sorted_indices: [36]u16 = undefined;

// Face order for back-to-front sorting
var face_order: [num_faces]usize = .{ 0, 1, 2, 3, 4, 5 };

var pipeline: ?sw.gpu_types.RenderPipeline = null;
var vertex_buffer: ?gpu_mod.Buffer = null;
var index_buffer: ?gpu_mod.Buffer = null;
var uniform_buffer: ?gpu_mod.Buffer = null;
var bind_group: ?gpu_mod.BindGroup = null;
var angle: f32 = 0.0;

// Frame timing
const target_fps: u64 = 60;
const frame_time_ns: u64 = std.time.ns_per_s / target_fps;
var last_frame_time: i128 = 0;

const shader_code =
    \\struct Uniforms { mvp: mat4x4<f32> }
    \\@group(0) @binding(0) var<uniform> u: Uniforms;
    \\
    \\struct VSOut {
    \\    @builtin(position) pos: vec4f,
    \\    @location(0) color: vec3f,
    \\}
    \\
    \\@vertex fn vs_main(
    \\    @location(0) pos: vec3f,
    \\    @location(1) color: vec3f,
    \\) -> VSOut {
    \\    var out: VSOut;
    \\    out.pos = u.mvp * vec4f(pos, 1.0);
    \\    out.color = color;
    \\    return out;
    \\}
    \\
    \\@fragment fn fs_main(in: VSOut) -> @location(0) vec4f {
    \\    return vec4f(in.color, 1.0);
    \\}
;

const Callbacks = struct {
    pub fn init(ctx: *sw.Context) !void {
        const gpu = ctx.gpu();
        if (!gpu.isReady()) return;

        // Vertex buffer
        vertex_buffer = try gpu.createBuffer(.{
            .size = @sizeOf(Vertex) * 24,
            .usage = .{ .vertex = true, .copy_dst = true },
        });
        gpu.writeBuffer(vertex_buffer.?, 0, std.mem.sliceAsBytes(&cube_vertices));

        // Index buffer (updated each frame for depth sorting)
        buildIndices();
        index_buffer = try gpu.createBuffer(.{
            .size = @sizeOf(u16) * 36,
            .usage = .{ .index = true, .copy_dst = true },
        });
        gpu.writeBuffer(index_buffer.?, 0, std.mem.sliceAsBytes(&sorted_indices));

        // Uniform buffer: mat4x4 = 64 bytes, padded to 256
        uniform_buffer = try gpu.createBuffer(.{
            .size = 256,
            .usage = .{ .uniform = true, .copy_dst = true },
        });

        // Bind group layout + bind group
        var bg_layout = try gpu.createBindGroupLayout(.{
            .entries = &[_]sw.gpu_types.BindGroupLayoutEntry{.{
                .binding = 0,
                .visibility = .{ .vertex = true },
                .buffer = .{ .type = .uniform },
            }},
        });
        bind_group = try gpu.createBindGroup(.{
            .layout = &bg_layout,
            .entries = &[_]gpu_mod.BindGroupEntry{.{
                .binding = 0,
                .buffer = &uniform_buffer.?,
                .size = 256,
            }},
        });

        // Pipeline layout
        var pipeline_layout = try gpu.createPipelineLayout(.{
            .bind_group_layouts = &[_]*gpu_mod.BindGroupLayout{&bg_layout},
        });

        // Shader
        var shader = try gpu.createShaderModule(.{ .code = shader_code });

        // Render pipeline
        pipeline = try gpu.createRenderPipeline(.{
            .layout = &pipeline_layout,
            .vertex = .{
                .module = &shader,
                .entry_point = "vs_main",
                .buffers = &[_]sw.gpu_types.VertexBufferLayout{.{
                    .array_stride = @sizeOf(Vertex),
                    .attributes = &[_]sw.gpu_types.VertexAttribute{
                        .{ .format = .float32x3, .offset = 0, .shader_location = 0 },
                        .{ .format = .float32x3, .offset = 12, .shader_location = 1 },
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
                .cull_mode = .back,
            },
            .multisample = .{
                .count = 1,
                .mask = 0xFFFFFFFF,
                .alpha_to_coverage_enabled = false,
            },
        });

        std.log.info("justabox: GPU ready", .{});
    }

    pub fn tick(ctx: *sw.Context) !void {
        _ = ctx;
        angle += 0.01; // ~0.6 deg/frame at 60hz = one full rotation per ~10 seconds
    }

    pub fn render(ctx: *sw.Context) !void {
        const gpu = ctx.gpu();
        if (!gpu.isReady()) return;
        if (pipeline == null) return;

        // Frame limiting
        const now = std.time.nanoTimestamp();
        if (last_frame_time > 0) {
            const elapsed = now - last_frame_time;
            if (elapsed < frame_time_ns) {
                std.Thread.sleep(@intCast(frame_time_ns - @as(u64, @intCast(elapsed))));
            }
        }
        last_frame_time = std.time.nanoTimestamp();

        // Build MVP matrix
        const proj = sw_math.perspective(
            std.math.pi / 3.0, // 60 degree fov
            800.0 / 600.0,
            0.1,
            100.0,
        );
        const view = sw_math.lookAt(
            .{ .x = 2.0, .y = 2.0, .z = 4.0 },
            .{ .x = 0.0, .y = 0.0, .z = 0.0 },
            .{ .x = 0.0, .y = 1.0, .z = 0.0 },
        );
        const rot = sw_math.Mat4.rotationY(angle);
        const mvp = proj.mul(view.mul(rot));

        // Upload MVP to uniform buffer
        gpu.writeBuffer(uniform_buffer.?, 0, std.mem.sliceAsBytes(&mvp.data));

        // Sort faces back-to-front (painter's algorithm, no hardware depth testing)
        sortFaces();
        buildIndices();
        gpu.writeBuffer(index_buffer.?, 0, std.mem.sliceAsBytes(&sorted_indices));

        // Render
        var view_tex = try gpu.getCurrentTextureView();
        const encoder = try gpu.createCommandEncoder();
        const pass = try encoder.beginRenderPass(.{
            .color_attachments = &[_]sw.gpu_types.RenderPassColorAttachment{.{
                .view = &view_tex,
                .load_op = .clear,
                .store_op = .store,
                .clear_value = .{ .r = 0.08, .g = 0.08, .b = 0.12, .a = 1.0 },
            }},
        });

        pass.setPipeline(pipeline.?);
        pass.setBindGroup(0, bind_group.?);
        pass.setVertexBuffer(0, vertex_buffer.?, 0, @sizeOf(Vertex) * 24);
        pass.setIndexBuffer(index_buffer.?, .uint16, 0, @sizeOf(u16) * 36);
        pass.drawIndexed(36, 1, 0, 0, 0);
        pass.end();

        const cmd = try encoder.finish();
        gpu.submit(&[_]sw.gpu_types.CommandBuffer{cmd});
        view_tex.release();
        gpu.present();
    }

    pub fn shutdown(ctx: *sw.Context) !void {
        _ = ctx;
    }
};

// Compute centroid of each face (average of 4 vertices after rotation)
// and sort face_order back-to-front relative to camera at (2, 2, 4).
fn sortFaces() void {
    const cam = sw_math.Vec3{ .x = 2.0, .y = 2.0, .z = 4.0 };
    const rot = sw_math.Mat4.rotationY(angle);

    var distances: [num_faces]f32 = undefined;
    for (0..num_faces) |f| {
        var cx: f32 = 0;
        var cy: f32 = 0;
        var cz: f32 = 0;
        for (0..4) |v| {
            const p = cube_vertices[f * 4 + v].position;
            // Rotate vertex
            const rx = rot.get(0, 0) * p[0] + rot.get(0, 1) * p[1] + rot.get(0, 2) * p[2];
            const ry = rot.get(1, 0) * p[0] + rot.get(1, 1) * p[1] + rot.get(1, 2) * p[2];
            const rz = rot.get(2, 0) * p[0] + rot.get(2, 1) * p[1] + rot.get(2, 2) * p[2];
            cx += rx;
            cy += ry;
            cz += rz;
        }
        cx /= 4.0;
        cy /= 4.0;
        cz /= 4.0;
        const dx = cx - cam.x;
        const dy = cy - cam.y;
        const dz = cz - cam.z;
        distances[f] = dx * dx + dy * dy + dz * dz;
    }

    // Insertion sort (only 6 elements, descending = back-to-front)
    for (1..num_faces) |i| {
        const key = face_order[i];
        const key_dist = distances[key];
        var j: usize = i;
        while (j > 0 and distances[face_order[j - 1]] < key_dist) {
            face_order[j] = face_order[j - 1];
            j -= 1;
        }
        face_order[j] = key;
    }
}

fn buildIndices() void {
    for (face_order, 0..) |face, i| {
        const base: u16 = @intCast(face * 4);
        const out = i * 6;
        for (face_indices_base, 0..) |idx, k| {
            sorted_indices[out + k] = base + idx;
        }
    }
}
