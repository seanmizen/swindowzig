const std = @import("std");
const gpu = @import("sw_gpu");

const UIVertex = struct {
    position: [2]f32,
    color: [4]f32,
};

pub const OverlayRenderer = struct {
    pipeline: ?gpu.RenderPipeline,
    vertex_buffer: ?gpu.Buffer,
    buffer_byte_capacity: usize,
    vertices: std.ArrayList(UIVertex),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) OverlayRenderer {
        return .{
            .pipeline = null,
            .vertex_buffer = null,
            .buffer_byte_capacity = 0,
            .vertices = std.ArrayList(UIVertex){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *OverlayRenderer) void {
        self.vertices.deinit(self.allocator);
        if (self.vertex_buffer) |buf| buf.destroy();
    }

    pub fn ensurePipeline(self: *OverlayRenderer, g: *gpu.GPU, sample_count: u32) !void {
        if (self.pipeline != null) return;

        const shader_code =
            \\struct VertexOutput {
            \\    @builtin(position) position: vec4f,
            \\    @location(0) color: vec4f,
            \\}
            \\
            \\@vertex
            \\fn vs_main(@location(0) pos: vec2f, @location(1) color: vec4f) -> VertexOutput {
            \\    var output: VertexOutput;
            \\    output.position = vec4f(pos, 0.0, 1.0);
            \\    output.color = color;
            \\    return output;
            \\}
            \\
            \\@fragment
            \\fn fs_main(input: VertexOutput) -> @location(0) vec4f {
            \\    return input.color;
            \\}
        ;

        var shader = try g.createShaderModule(.{ .code = shader_code });

        self.pipeline = try g.createRenderPipeline(.{
            .vertex = .{
                .module = &shader,
                .entry_point = "vs_main",
                .buffers = &[_]gpu.VertexBufferLayout{.{
                    .array_stride = @sizeOf(UIVertex),
                    .attributes = &[_]gpu.VertexAttribute{
                        .{ .format = .float32x2, .offset = 0, .shader_location = 0 },
                        .{ .format = .float32x4, .offset = 8, .shader_location = 1 },
                    },
                }},
            },
            .fragment = .{
                .module = &shader,
                .entry_point = "fs_main",
                .targets = &[_]gpu.ColorTargetState{.{
                    .format = .bgra8unorm,
                    .blend = gpu.BlendState{
                        .color = .{
                            .operation = .add,
                            .src_factor = .src_alpha,
                            .dst_factor = .one_minus_src_alpha,
                        },
                        .alpha = .{
                            .operation = .add,
                            .src_factor = .one,
                            .dst_factor = .zero,
                        },
                    },
                }},
            },
            .primitive = .{
                .topology = .triangle_list,
                .cull_mode = .none,
            },
            .multisample = .{ .count = sample_count },
        });
    }

    pub fn begin(self: *OverlayRenderer) void {
        self.vertices.clearRetainingCapacity();
    }

    /// Add a filled rectangle to the overlay (pixel coords, converted to NDC internally).
    pub fn rect(self: *OverlayRenderer, x: f32, y: f32, w: f32, h: f32, color: [4]f32, screen_w: f32, screen_h: f32) !void {
        const x1 = (x / screen_w) * 2.0 - 1.0;
        const y1 = 1.0 - (y / screen_h) * 2.0;
        const x2 = ((x + w) / screen_w) * 2.0 - 1.0;
        const y2 = 1.0 - ((y + h) / screen_h) * 2.0;

        // Triangle 1: TL, TR, BL
        try self.vertices.append(self.allocator, .{ .position = .{ x1, y1 }, .color = color });
        try self.vertices.append(self.allocator, .{ .position = .{ x2, y1 }, .color = color });
        try self.vertices.append(self.allocator, .{ .position = .{ x1, y2 }, .color = color });
        // Triangle 2: TR, BR, BL
        try self.vertices.append(self.allocator, .{ .position = .{ x2, y1 }, .color = color });
        try self.vertices.append(self.allocator, .{ .position = .{ x2, y2 }, .color = color });
        try self.vertices.append(self.allocator, .{ .position = .{ x1, y2 }, .color = color });
    }

    /// Upload vertices and draw all rects in the current frame.
    /// GPU buffer is grown automatically when vertex data exceeds current capacity.
    pub fn draw(self: *OverlayRenderer, g: *gpu.GPU, pass: gpu.RenderPassEncoder) void {
        if (self.vertices.items.len == 0) return;
        if (self.pipeline == null) return;

        const bytes = std.mem.sliceAsBytes(self.vertices.items);

        // Grow GPU buffer if the current frame's vertex data exceeds capacity.
        if (bytes.len > self.buffer_byte_capacity) {
            if (self.vertex_buffer) |buf| buf.destroy();
            const new_cap = bytes.len * 2; // 2× headroom to amortise future growth
            self.vertex_buffer = g.createBuffer(.{
                .size = new_cap,
                .usage = .{ .vertex = true, .copy_dst = true },
            }) catch {
                self.vertex_buffer = null;
                self.buffer_byte_capacity = 0;
                return;
            };
            self.buffer_byte_capacity = new_cap;
        }

        g.writeBuffer(self.vertex_buffer.?, 0, bytes);

        pass.setPipeline(self.pipeline.?);
        pass.setVertexBuffer(0, self.vertex_buffer.?, 0, bytes.len);
        pass.draw(@intCast(self.vertices.items.len), 1, 0, 0);
    }
};
