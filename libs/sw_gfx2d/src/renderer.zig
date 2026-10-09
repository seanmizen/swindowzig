//! GPU side of the 2D renderer. It owns the pipeline, the buffers and the
//! textures. Shapes go into a `Batch`. `flush` uploads the batch and draws it
//! with one draw call for each texture change.

const std = @import("std");
const gpu_mod = @import("sw_gpu");
const batch_mod = @import("batch.zig");
const projection = @import("projection.zig");

pub const Batch = batch_mod.Batch;
pub const Color = batch_mod.Color;
pub const Rect = batch_mod.Rect;
pub const Texture = batch_mod.Texture;
pub const Vertex = batch_mod.Vertex;

pub const Options = struct {
    /// Format of the render target. It must match the colour attachment.
    format: gpu_mod.TextureFormat = .bgra8unorm,
    /// Sample count of the colour attachment.
    sample_count: u32 = 1,
};

pub const Filter = enum { nearest, linear };

const shader_code =
    \\struct Uniforms { proj: mat4x4<f32> }
    \\@group(0) @binding(0) var<uniform> u: Uniforms;
    \\@group(0) @binding(1) var tex: texture_2d<f32>;
    \\@group(0) @binding(2) var samp: sampler;
    \\
    \\struct VSOut {
    \\    @builtin(position) pos: vec4f,
    \\    @location(0) uv: vec2f,
    \\    @location(1) color: vec4f,
    \\}
    \\
    \\@vertex fn vs_main(
    \\    @location(0) pos: vec2f,
    \\    @location(1) uv: vec2f,
    \\    @location(2) color: vec4f,
    \\) -> VSOut {
    \\    var out: VSOut;
    \\    out.pos = u.proj * vec4f(pos, 0.0, 1.0);
    \\    out.uv = uv;
    \\    out.color = color;
    \\    return out;
    \\}
    \\
    \\@fragment fn fs_main(in: VSOut) -> @location(0) vec4f {
    \\    return textureSample(tex, samp, in.uv) * in.color;
    \\}
;

const initial_quads = 256;
const uniform_size = 256;

const TextureEntry = struct {
    texture: gpu_mod.Texture,
    view: gpu_mod.TextureView,
    bind_group: gpu_mod.BindGroup,
};

pub const Renderer = struct {
    alloc: std.mem.Allocator,
    gpu: *gpu_mod.GPU,
    batch: Batch = .{},

    pipeline: gpu_mod.RenderPipeline,
    bind_group_layout: gpu_mod.BindGroupLayout,
    uniform_buffer: gpu_mod.Buffer,
    nearest: gpu_mod.Sampler,
    linear: gpu_mod.Sampler,
    vertex_buffer: gpu_mod.Buffer,
    index_buffer: gpu_mod.Buffer,
    vertex_capacity: usize,
    index_capacity: usize,
    textures: std.ArrayList(TextureEntry) = .empty,

    // The projection for the current frame, set by `beginFrame`.
    proj: projection.Matrix,
    logical: projection.Size,

    pub fn init(alloc: std.mem.Allocator, gpu: *gpu_mod.GPU, options: Options) !Renderer {
        var shader = try gpu.createShaderModule(.{ .code = shader_code });

        var bgl = try gpu.createBindGroupLayout(.{
            .entries = &[_]gpu_mod.BindGroupLayoutEntry{
                .{ .binding = 0, .visibility = .{ .vertex = true }, .buffer = .{ .type = .uniform } },
                .{ .binding = 1, .visibility = .{ .fragment = true }, .texture = .{} },
                .{ .binding = 2, .visibility = .{ .fragment = true }, .sampler = .{} },
            },
        });
        var layout = try gpu.createPipelineLayout(.{
            .bind_group_layouts = &[_]*gpu_mod.BindGroupLayout{&bgl},
        });

        // Straight alpha blending: out = src * src.a + dst * (1 - src.a).
        const blend: gpu_mod.BlendState = .{
            .color = .{ .operation = .add, .src_factor = .src_alpha, .dst_factor = .one_minus_src_alpha },
            .alpha = .{ .operation = .add, .src_factor = .one, .dst_factor = .one_minus_src_alpha },
        };
        const pipeline = try gpu.createRenderPipeline(.{
            .layout = &layout,
            .vertex = .{
                .module = &shader,
                .entry_point = "vs_main",
                .buffers = &[_]gpu_mod.VertexBufferLayout{.{
                    .array_stride = @sizeOf(Vertex),
                    .attributes = &[_]gpu_mod.VertexAttribute{
                        .{ .format = .float32x2, .offset = @offsetOf(Vertex, "pos"), .shader_location = 0 },
                        .{ .format = .float32x2, .offset = @offsetOf(Vertex, "uv"), .shader_location = 1 },
                        .{ .format = .float32x4, .offset = @offsetOf(Vertex, "color"), .shader_location = 2 },
                    },
                }},
            },
            .fragment = .{
                .module = &shader,
                .entry_point = "fs_main",
                .targets = &[_]gpu_mod.ColorTargetState{.{ .format = options.format, .blend = blend }},
            },
            .primitive = .{ .topology = .triangle_list, .front_face = .ccw, .cull_mode = .none },
            .multisample = .{ .count = options.sample_count },
        });

        const vertex_capacity = initial_quads * 4;
        const index_capacity = initial_quads * 6;

        var self: Renderer = .{
            .alloc = alloc,
            .gpu = gpu,
            .pipeline = pipeline,
            .bind_group_layout = bgl,
            .uniform_buffer = try gpu.createBuffer(.{
                .size = uniform_size,
                .usage = .{ .uniform = true, .copy_dst = true },
            }),
            .nearest = try gpu.createSampler(.{ .mag_filter = .nearest, .min_filter = .nearest }),
            .linear = try gpu.createSampler(.{ .mag_filter = .linear, .min_filter = .linear }),
            .vertex_buffer = try gpu.createBuffer(.{
                .size = vertex_capacity * @sizeOf(Vertex),
                .usage = .{ .vertex = true, .copy_dst = true },
            }),
            .index_buffer = try gpu.createBuffer(.{
                .size = index_capacity * @sizeOf(u32),
                .usage = .{ .index = true, .copy_dst = true },
            }),
            .vertex_capacity = vertex_capacity,
            .index_capacity = index_capacity,
            .proj = projection.ortho(1, 1),
            .logical = .{ .w = 1, .h = 1 },
        };
        errdefer self.deinit();

        // Texture 0: one white texel, for solid shapes.
        const white = try self.createTexture(1, 1, &.{ 255, 255, 255, 255 }, .nearest);
        std.debug.assert(white.id == batch_mod.white_texture.id);
        return self;
    }

    pub fn deinit(self: *Renderer) void {
        for (self.textures.items) |entry| {
            entry.bind_group.release();
            entry.view.release();
            entry.texture.destroy();
        }
        self.textures.deinit(self.alloc);
        self.batch.deinit(self.alloc);
        self.vertex_buffer.destroy();
        self.index_buffer.destroy();
        self.uniform_buffer.destroy();
    }

    /// Upload an RGBA8 image (4 bytes a texel, rows packed, `width * height * 4`
    /// bytes) and return a handle for `drawTexture`.
    pub fn createTexture(
        self: *Renderer,
        width: u32,
        height: u32,
        rgba: []const u8,
        filter: Filter,
    ) !Texture {
        if (width == 0 or height == 0) return error.EmptyTexture;
        if (rgba.len != @as(usize, width) * height * 4) return error.BadTextureSize;
        const gpu = self.gpu;

        const texture = try gpu.createTexture(.{
            .size = .{ .width = width, .height = height },
            .format = .rgba8unorm,
            .usage = .{ .texture_binding = true, .copy_dst = true },
        });
        errdefer texture.destroy();
        gpu.writeTexture(texture, rgba, width * 4, height, .{ .width = width, .height = height });

        var view = try texture.createView(.{});
        errdefer view.release();

        var sampler = switch (filter) {
            .nearest => self.nearest,
            .linear => self.linear,
        };
        const bind_group = try gpu.createBindGroup(.{
            .layout = &self.bind_group_layout,
            .entries = &[_]gpu_mod.BindGroupEntry{
                .{ .binding = 0, .buffer = &self.uniform_buffer, .size = uniform_size },
                .{ .binding = 1, .texture_view = &view },
                .{ .binding = 2, .sampler = &sampler },
            },
        });
        errdefer bind_group.release();

        try self.textures.append(self.alloc, .{ .texture = texture, .view = view, .bind_group = bind_group });
        return .{ .id = @intCast(self.textures.items.len - 1), .width = width, .height = height };
    }

    /// Start a frame. `width` and `height` are the surface size in device
    /// pixels and `dpi_scale` comes from the resize event or `ctx.window()`.
    /// Drawing is in logical pixels: device pixels divided by `dpi_scale`.
    pub fn beginFrame(self: *Renderer, width: u32, height: u32, dpi_scale: f32) void {
        self.batch.reset();
        self.logical = projection.logicalSize(width, height, dpi_scale);
        self.proj = projection.ortho(self.logical.w, self.logical.h);
    }

    /// The drawable size in logical pixels, from the last `beginFrame`.
    pub fn size(self: *const Renderer) projection.Size {
        return self.logical;
    }

    pub fn fillRect(self: *Renderer, rect: Rect, color: Color) !void {
        try self.batch.fillRect(self.alloc, rect, color);
    }

    pub fn strokeRect(self: *Renderer, rect: Rect, line_width: f32, color: Color) !void {
        try self.batch.strokeRect(self.alloc, rect, line_width, color);
    }

    /// Draw `src` (texels, null for the whole texture) of `texture` into `dst`.
    pub fn drawTexture(self: *Renderer, texture: Texture, dst: Rect, src: ?Rect, tint: Color) !void {
        try self.batch.drawTexture(self.alloc, texture, dst, src, tint);
    }

    /// Number of draw calls `flush` makes for the shapes so far.
    pub fn drawCallCount(self: *const Renderer) usize {
        return self.batch.calls.items.len;
    }

    /// Upload the shapes and draw them into `pass`. Later shapes draw over
    /// earlier ones.
    pub fn flush(self: *Renderer, pass: gpu_mod.RenderPassEncoder) !void {
        const b = &self.batch;
        if (b.calls.items.len == 0) return;
        const gpu = self.gpu;

        try self.reserve(b.vertices.items.len, b.indices.items.len);
        gpu.writeBuffer(self.uniform_buffer, 0, std.mem.sliceAsBytes(&self.proj));
        gpu.writeBuffer(self.vertex_buffer, 0, std.mem.sliceAsBytes(b.vertices.items));
        gpu.writeBuffer(self.index_buffer, 0, std.mem.sliceAsBytes(b.indices.items));

        pass.setPipeline(self.pipeline);
        pass.setVertexBuffer(0, self.vertex_buffer, 0, b.vertices.items.len * @sizeOf(Vertex));
        pass.setIndexBuffer(self.index_buffer, .uint32, 0, b.indices.items.len * @sizeOf(u32));
        for (b.calls.items) |call| {
            pass.setBindGroup(0, self.textures.items[call.texture].bind_group);
            pass.drawIndexed(call.index_count, 1, call.first_index, 0, 0);
        }
    }

    /// Grow the vertex and index buffers to hold the batch.
    fn reserve(self: *Renderer, vertices: usize, indices: usize) !void {
        if (vertices > self.vertex_capacity) {
            const capacity = try std.math.ceilPowerOfTwo(usize, vertices);
            const buffer = try self.gpu.createBuffer(.{
                .size = capacity * @sizeOf(Vertex),
                .usage = .{ .vertex = true, .copy_dst = true },
            });
            self.vertex_buffer.destroy();
            self.vertex_buffer = buffer;
            self.vertex_capacity = capacity;
        }
        if (indices > self.index_capacity) {
            const capacity = try std.math.ceilPowerOfTwo(usize, indices);
            const buffer = try self.gpu.createBuffer(.{
                .size = capacity * @sizeOf(u32),
                .usage = .{ .index = true, .copy_dst = true },
            });
            self.index_buffer.destroy();
            self.index_buffer = buffer;
            self.index_capacity = capacity;
        }
    }
};
