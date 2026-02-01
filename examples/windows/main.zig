// Simple WebGPU triangle example for swindowzig
const std = @import("std");
const sw = @import("sw_app");
const builtin = @import("builtin");

pub fn main() !void {
    try sw.run(.{
        .title = "swindowzig - WebGPU Triangle",
        .size = .{ .w = 800, .h = 600 },
        .tick_hz = 60,
    }, GameCallbacks);
}

const Vertex = struct {
    position: [2]f32,
    color: [3]f32,
};

var pipeline: ?sw.gpu_types.RenderPipeline = null;
var vertex_buffer: ?sw.gpu_types.Buffer = null;

// Debug info tracking
var frame_count: u64 = 0;
var last_fps_update: i64 = 0;
var fps: f32 = 0.0;

const GameCallbacks = struct {
    pub fn init(ctx: *sw.Context) !void {
        const gpu = ctx.gpu();

        // Only initialize GPU resources if GPU is ready (web only for now)
        if (!gpu.isReady()) {
            std.log.info("GPU not ready (native wgpu not linked), running without rendering", .{});
            return;
        }

        // Triangle vertices (position + color)
        const vertices = [_]Vertex{
            .{ .position = .{ 0.0, 0.5 }, .color = .{ 1.0, 0.0, 0.0 } },   // Top (red)
            .{ .position = .{ -0.5, -0.5 }, .color = .{ 0.0, 1.0, 0.0 } }, // Bottom-left (green)
            .{ .position = .{ 0.5, -0.5 }, .color = .{ 0.0, 0.0, 1.0 } },  // Bottom-right (blue)
        };

        // Create vertex buffer
        vertex_buffer = try gpu.createBuffer(.{
            .size = @sizeOf(Vertex) * vertices.len,
            .usage = .{ .vertex = true, .copy_dst = true },
            .mapped_at_creation = false,
        });

        // Upload vertex data
        gpu.writeBuffer(vertex_buffer.?, 0, std.mem.sliceAsBytes(&vertices));

        // Create shader module (WGSL)
        const shader_code =
            \\struct VertexOutput {
            \\    @builtin(position) position: vec4f,
            \\    @location(0) color: vec3f,
            \\}
            \\
            \\@vertex
            \\fn vs_main(@location(0) pos: vec2f, @location(1) color: vec3f) -> VertexOutput {
            \\    var output: VertexOutput;
            \\    output.position = vec4f(pos, 0.0, 1.0);
            \\    output.color = color;
            \\    return output;
            \\}
            \\
            \\@fragment
            \\fn fs_main(input: VertexOutput) -> @location(0) vec4f {
            \\    return vec4f(input.color, 1.0);
            \\}
        ;

        var shader = try gpu.createShaderModule(.{
            .code = shader_code,
        });

        // Create render pipeline
        pipeline = try gpu.createRenderPipeline(.{
            .vertex = .{
                .module = &shader,
                .entry_point = "vs_main",
                .buffers = &[_]sw.gpu_types.VertexBufferLayout{
                    .{
                        .array_stride = @sizeOf(Vertex),
                        .step_mode = .vertex,
                        .attributes = &[_]sw.gpu_types.VertexAttribute{
                            .{ .format = .float32x2, .offset = 0, .shader_location = 0 }, // position
                            .{ .format = .float32x3, .offset = 8, .shader_location = 1 }, // color
                        },
                    },
                },
            },
            .fragment = .{
                .module = &shader,
                .entry_point = "fs_main",
                .targets = &[_]sw.gpu_types.ColorTargetState{
                    .{
                        .format = .bgra8unorm,
                        .blend = null,
                        .write_mask = 0xF,
                    },
                },
            },
            .primitive = .{
                .topology = .triangle_list,
                .front_face = .ccw,
                .cull_mode = .none,
            },
            .multisample = .{
                .count = 1,
                .mask = 0xFFFFFFFF,
                .alpha_to_coverage_enabled = false,
            },
        });
    }

    pub fn tick(ctx: *sw.Context) !void {
        // Calculate FPS
        frame_count += 1;
        const now = std.time.milliTimestamp();
        if (now - last_fps_update >= 500) { // Update every 500ms
            const elapsed_secs = @as(f32, @floatFromInt(now - last_fps_update)) / 1000.0;
            fps = @as(f32, @floatFromInt(frame_count)) / elapsed_secs;
            frame_count = 0;
            last_fps_update = now;

            // Get mouse position
            const input = ctx.input();
            const mouse_x = input.mouse.x;
            const mouse_y = input.mouse.y;

            // Print debug info to console
            std.debug.print("\rFPS: {d:.1} | Mouse: ({d:.0}, {d:.0})    ", .{ fps, mouse_x, mouse_y });
        }
    }

    pub fn render(ctx: *sw.Context) !void {
        const gpu = ctx.gpu();
        if (!gpu.isReady()) return;
        if (pipeline == null or vertex_buffer == null) return;

        // Get the current frame's texture view
        var view = try gpu.getCurrentTextureView();

        // Create command encoder
        const encoder = try gpu.createCommandEncoder();

        // Begin render pass
        const pass = try encoder.beginRenderPass(.{
            .color_attachments = &[_]sw.gpu_types.RenderPassColorAttachment{
                .{
                    .view = &view,
                    .load_op = .clear,
                    .store_op = .store,
                    .clear_value = .{ .r = 0.1, .g = 0.1, .b = 0.1, .a = 1.0 },
                },
            },
        });

        // Draw triangle
        pass.setPipeline(pipeline.?);
        pass.setVertexBuffer(0, vertex_buffer.?, 0, @sizeOf(Vertex) * 3);
        pass.draw(3, 1, 0, 0);
        pass.end();

        // Submit commands
        const command = try encoder.finish();
        gpu.submit(&[_]sw.gpu_types.CommandBuffer{command});

        // Release texture view (command buffer is released in submit())
        view.release();

        // Present frame
        gpu.present();
    }

    pub fn shutdown(ctx: *sw.Context) !void {
        _ = ctx;
        // Cleanup would go here
    }
};
