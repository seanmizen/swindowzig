//! `Particles`: draws the particles of a `particle_plan.System` as
//! camera-facing quads in one draw call, sorted from far to near for the
//! alpha blend (REQ-GPU-024). The pass draws after the opaque scene, with
//! the depth test on and the depth write off. The quads take their colour
//! from a texture, for example an `Atlas`, times the particle colour.
//!
//! ```zig
//! var system = try render.ParticleSystem.init(allocator, 1024);
//! var particles = try render.Particles.init(allocator, &graph, .{ .color_format = post.hdr_format, .capacity = 1024 });
//! try particles.addPass(.{ .color = post.hdr, .depth = depth });
//! // Each tick: emitter.emit(&system, dt); system.step(dt);
//! // Each frame, before graph.execute:
//! try particles.update(&system, render.ParticleCamera.fromView(frame.view, eye));
//! ```
const std = @import("std");
const gpu_mod = @import("sw_gpu");
const frame_graph = @import("frame_graph.zig");
const plan = @import("particle_plan.zig");
const translucent = @import("translucent_plan.zig");

const FrameGraph = frame_graph.FrameGraph;
const Pass = frame_graph.Pass;
const PassId = frame_graph.PassId;
const TargetId = @import("plan.zig").TargetId;

pub const Options = struct {
    color_format: gpu_mod.TextureFormat = .rgba16float,
    depth_format: gpu_mod.TextureFormat = .depth24plus,
    /// The most particles that one frame draws.
    capacity: u32 = 4096,
    /// The texture of the sprites. Null: a white texture, so each quad has
    /// the particle colour. The view must stay valid while the particles
    /// exist.
    texture: ?*gpu_mod.TextureView = null,
};

pub const PassOptions = struct {
    color: TargetId,
    depth: TargetId,
    /// The frame graph order: after the translucent pass (55) and before
    /// the precipitation (60).
    order: i32 = 58,
};

pub const Particles = struct {
    allocator: std.mem.Allocator,
    graph: *FrameGraph,
    options: Options,
    pipeline: gpu_mod.RenderPipeline,
    vertex_buffer: gpu_mod.Buffer,
    bind_group: gpu_mod.BindGroup,
    sampler: gpu_mod.Sampler,
    white: ?gpu_mod.Texture = null,
    white_view: ?gpu_mod.TextureView = null,
    vertices: []plan.Vertex,
    order: std.ArrayList(plan.Key) = .empty,
    vertex_count: u32 = 0,
    /// The draw calls of the last frame. A test reads it.
    draw_calls: u32 = 0,
    pass: ?PassId = null,

    pub fn init(allocator: std.mem.Allocator, graph: *FrameGraph, options: Options) !Particles {
        const gpu = graph.gpu;
        if (options.capacity == 0) return error.NoCapacity;
        const vertices = try allocator.alloc(plan.Vertex, @as(usize, options.capacity) * 6);
        errdefer allocator.free(vertices);
        var vertex_buffer = try gpu.createBuffer(.{
            .label = "sw_particles_vertices",
            .size = @as(u64, options.capacity) * 6 * @sizeOf(plan.Vertex),
            .usage = .{ .vertex = true, .copy_dst = true },
        });
        errdefer vertex_buffer.destroy();

        var white: ?gpu_mod.Texture = null;
        var white_view: ?gpu_mod.TextureView = null;
        errdefer if (white) |t| t.destroy();
        if (options.texture == null) {
            const t = try gpu.createTexture(.{
                .label = "sw_particles_white",
                .size = .{ .width = 1, .height = 1 },
                .format = .rgba8unorm,
                .usage = .{ .texture_binding = true, .copy_dst = true },
            });
            white = t;
            gpu.writeTexture(t, &.{ 255, 255, 255, 255 }, 4, 1, .{ .width = 1, .height = 1 });
            white_view = try t.createView(.{ .dimension = .@"2d" });
        }
        var sampler = try gpu.createSampler(.{
            .label = "sw_particles",
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_filter = .linear,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
        });
        var layout = try gpu.createBindGroupLayout(.{
            .label = "sw_particles",
            .entries = &[_]gpu_mod.BindGroupLayoutEntry{
                .{ .binding = 0, .visibility = .{ .fragment = true }, .texture = .{ .sample_type = .float, .view_dimension = .@"2d" } },
                .{ .binding = 1, .visibility = .{ .fragment = true }, .sampler = .{ .type = .filtering } },
            },
        });
        const view = options.texture orelse &white_view.?;
        const bind_group = try gpu.createBindGroup(.{
            .label = "sw_particles",
            .layout = &layout,
            .entries = &[_]gpu_mod.BindGroupEntry{
                .{ .binding = 0, .texture_view = view },
                .{ .binding = 1, .sampler = &sampler },
            },
        });
        var layouts = [_]*gpu_mod.BindGroupLayout{ &graph.frame_layout, &layout };
        var pipeline_layout = try gpu.createPipelineLayout(.{
            .label = "sw_particles",
            .bind_group_layouts = &layouts,
        });
        var module = try gpu.createShaderModule(.{ .label = "sw_particles", .code = plan.shader });
        const pipeline = try gpu.createRenderPipeline(.{
            .label = "sw_particles",
            .layout = &pipeline_layout,
            .vertex = .{ .module = &module, .entry_point = "vs_main", .buffers = &vertex_buffers },
            .fragment = .{
                .module = &module,
                .entry_point = "fs_main",
                .targets = &[_]gpu_mod.ColorTargetState{.{ .format = options.color_format, .blend = translucent.blend }},
            },
            .primitive = .{ .topology = .triangle_list, .cull_mode = .none },
            .depth_stencil = translucent.depthStencil(options.depth_format),
            .multisample = .{ .count = 1 },
        });
        return .{
            .allocator = allocator,
            .graph = graph,
            .options = options,
            .pipeline = pipeline,
            .vertex_buffer = vertex_buffer,
            .bind_group = bind_group,
            .sampler = sampler,
            .white = white,
            .white_view = white_view,
            .vertices = vertices,
        };
    }

    /// Release the buffers. Call it before `FrameGraph.deinit`. The graph
    /// keeps the pass, but the pass does not run.
    pub fn deinit(self: *Particles) void {
        if (self.pass) |p| self.graph.setPassEnabled(p, false);
        self.bind_group.release();
        if (self.white_view) |v| v.release();
        if (self.white) |t| t.destroy();
        self.vertex_buffer.destroy();
        self.order.deinit(self.allocator);
        self.allocator.free(self.vertices);
        self.* = undefined;
    }

    /// Build the quads of `system` for `camera`, from far to near, and
    /// stage them for the next `FrameGraph.execute`. A system with more
    /// particles than the capacity draws the newest particles.
    pub fn update(self: *Particles, system: *const plan.System, camera: plan.Camera) !void {
        var view = system.*;
        const cap: usize = self.options.capacity;
        if (view.len > cap) {
            view.head = (view.head + view.len - cap) % view.items.len;
            view.len = cap;
        }
        const n = try plan.buildQuads(self.allocator, &view, camera, &self.order, self.vertices);
        self.vertex_count = @intCast(n);
        if (n > 0) try self.graph.uploads.write(self.vertex_buffer, 0, std.mem.sliceAsBytes(self.vertices[0..n]));
    }

    /// Add a frame graph pass that draws the particles on the colour and
    /// depth targets of the scene. The pass keeps a pointer to `self`, so
    /// `self` must stay at its address.
    pub fn addPass(self: *Particles, options: PassOptions) !void {
        if (self.pass != null) return error.DuplicatePassName;
        if (self.graph.findPass("sw_particles") != null) return error.DuplicatePassName;
        try self.graph.addPass(.{
            .name = "sw_particles",
            .order = options.order,
            .attachments = .{
                .colors = &.{.{ .target = options.color, .load_op = .load }},
                .depth = .{ .target = options.depth, .load_op = .load },
            },
            .callback = .of(Particles, self, draw),
        });
        self.pass = self.graph.findPass("sw_particles").?;
    }

    /// Draw the quads of the last `update` in one draw call.
    pub fn draw(self: *Particles, pass: *Pass) anyerror!void {
        self.draw_calls = 0;
        if (self.vertex_count == 0) return;
        const rp = pass.render orelse return error.NoRenderPass;
        rp.setPipeline(self.pipeline);
        pass.bindFrame();
        rp.setBindGroup(1, self.bind_group);
        rp.setVertexBuffer(0, self.vertex_buffer, 0, @as(u64, self.vertex_count) * @sizeOf(plan.Vertex));
        rp.draw(self.vertex_count, 1, 0, 0);
        self.draw_calls = 1;
    }
};

const vertex_buffers = [_]gpu_mod.VertexBufferLayout{.{
    .array_stride = @sizeOf(plan.Vertex),
    .attributes = &[_]gpu_mod.VertexAttribute{
        .{ .format = .float32x3, .offset = @offsetOf(plan.Vertex, "pos"), .shader_location = 0 },
        .{ .format = .float32x2, .offset = @offsetOf(plan.Vertex, "uv"), .shader_location = 1 },
        .{ .format = .float32x4, .offset = @offsetOf(plan.Vertex, "color"), .shader_location = 2 },
    },
}};
