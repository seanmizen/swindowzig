// Interactive rotating triangle example for swindowzig
const std = @import("std");
const sw = @import("sw_app");
const builtin = @import("builtin");

pub fn main() !void {
    try sw.run(.{
        .title = "swindowzig - Rotating Triangle (Click & Drag)",
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

// Rotation state
var rotation: f32 = 0.0;
var is_dragging: bool = false;
var last_mouse_x: f32 = 0.0;

// Button state
const Button = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    
    fn contains(self: Button, mx: f32, my: f32) bool {
        return mx >= self.x and mx <= self.x + self.width and
               my >= self.y and my <= self.y + self.height;
    }
};

var reset_button = Button{ .x = 10, .y = 10, .width = 100, .height = 40 };
var button_hovered: bool = false;

// Debug info tracking
var frame_count: u64 = 0;
var last_fps_update: i64 = 0;
var fps: f32 = 0.0;

// Frame limiting
const target_fps: u64 = 60;
const frame_time_ns: u64 = std.time.ns_per_s / target_fps;
var last_frame_time: i128 = 0;

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

        // Create vertex buffer (larger to hold button vertices too)
        vertex_buffer = try gpu.createBuffer(.{
            .size = @sizeOf(Vertex) * 10,
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
                .count = 1, // No MSAA (4x requires multisampled render target)
                .mask = 0xFFFFFFFF,
                .alpha_to_coverage_enabled = false,
            },
        });
    }

    pub fn tick(ctx: *sw.Context) !void {
        const input = ctx.input();
        
        // Check button hover
        button_hovered = reset_button.contains(input.mouse.x, input.mouse.y);
        
        // Check button click
        if (button_hovered and input.buttonDown(.left)) {
            rotation = 0.0;
        }
        
        // Handle mouse drag for rotation (only if not over button)
        if (!button_hovered and input.buttonDown(.left)) {
            if (!is_dragging) {
                is_dragging = true;
                last_mouse_x = input.mouse.x;
            } else {
                const delta_x = input.mouse.x - last_mouse_x;
                rotation += delta_x * 0.01; // Sensitivity factor
                last_mouse_x = input.mouse.x;
            }
        } else {
            is_dragging = false;
        }
        
        // Calculate FPS
        frame_count += 1;
        const now = std.time.milliTimestamp();
        if (now - last_fps_update >= 500) { // Update every 500ms
            const elapsed_secs = @as(f32, @floatFromInt(now - last_fps_update)) / 1000.0;
            fps = @as(f32, @floatFromInt(frame_count)) / elapsed_secs;
            frame_count = 0;
            last_fps_update = now;

            // Print debug info to console
            std.debug.print("\rFPS: {d:.1} | Rotation: {d:.2} rad | Dragging: {}    ", .{ fps, rotation, is_dragging });
        }
    }

    pub fn render(ctx: *sw.Context) !void {
        const gpu = ctx.gpu();
        if (!gpu.isReady()) return;
        if (pipeline == null or vertex_buffer == null) return;

        // Frame limiting: sleep for remainder to hit target FPS
        const now = std.time.nanoTimestamp();
        if (last_frame_time > 0) {
            const elapsed = now - last_frame_time;
            if (elapsed < frame_time_ns) {
                std.Thread.sleep(@intCast(frame_time_ns - @as(u64, @intCast(elapsed))));
            }
        }
        last_frame_time = std.time.nanoTimestamp();

        // Prepare all vertices (triangle + button)
        const base_triangle = [_]Vertex{
            .{ .position = .{ 0.0, 0.5 }, .color = .{ 1.0, 0.0, 0.0 } },   // Top (red)
            .{ .position = .{ -0.5, -0.5 }, .color = .{ 0.0, 1.0, 0.0 } }, // Bottom-left (green)
            .{ .position = .{ 0.5, -0.5 }, .color = .{ 0.0, 0.0, 1.0 } },  // Bottom-right (blue)
        };
        
        // Rotate triangle vertices
        var all_vertices: [9]Vertex = undefined;
        const c = @cos(rotation);
        const s = @sin(rotation);
        
        for (base_triangle, 0..) |v, i| {
            all_vertices[i] = .{
                .position = .{
                    v.position[0] * c - v.position[1] * s,
                    v.position[0] * s + v.position[1] * c,
                },
                .color = v.color,
            };
        }
        
        // Add button vertices (2 triangles = 6 vertices)
        const btn_x1 = (reset_button.x / 400.0) - 1.0;
        const btn_y1 = 1.0 - (reset_button.y / 300.0);
        const btn_x2 = ((reset_button.x + reset_button.width) / 400.0) - 1.0;
        const btn_y2 = 1.0 - ((reset_button.y + reset_button.height) / 300.0);
        
        const button_color: [3]f32 = if (button_hovered) .{ 0.8, 0.8, 0.8 } else .{ 0.5, 0.5, 0.5 };
        
        all_vertices[3] = .{ .position = .{ btn_x1, btn_y1 }, .color = button_color };
        all_vertices[4] = .{ .position = .{ btn_x2, btn_y1 }, .color = button_color };
        all_vertices[5] = .{ .position = .{ btn_x1, btn_y2 }, .color = button_color };
        all_vertices[6] = .{ .position = .{ btn_x2, btn_y1 }, .color = button_color };
        all_vertices[7] = .{ .position = .{ btn_x2, btn_y2 }, .color = button_color };
        all_vertices[8] = .{ .position = .{ btn_x1, btn_y2 }, .color = button_color };
        
        // Upload all vertices at once
        gpu.writeBuffer(vertex_buffer.?, 0, std.mem.sliceAsBytes(&all_vertices));

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

        pass.setPipeline(pipeline.?);
        pass.setVertexBuffer(0, vertex_buffer.?, 0, @sizeOf(Vertex) * 9);
        
        // Draw triangle (first 3 vertices)
        pass.draw(3, 1, 0, 0);
        
        // Draw button (next 6 vertices)
        pass.draw(6, 1, 3, 0);
        
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
