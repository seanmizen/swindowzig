//! `Translucent`: a pass for translucent quads after the opaque pass, with
//! the depth test on, the depth write off, and the quads sorted from far
//! to near (REQ-GPU-022, REQ-GPU-023). `translucent_plan.zig` has the sort,
//! the states and the CPU reference.
//!
//! ```zig
//! var glass = try render.Translucent.init(allocator, &graph, .{ .color_format = post.hdr_format });
//! try glass.setQuads(&quads);
//! try glass.addPass(.{ .color = post.hdr, .depth = depth });
//! // Each frame, before graph.execute:
//! try glass.update(camera_pos);
//! ```
const std = @import("std");
const gpu_mod = @import("sw_gpu");
const frame_graph = @import("frame_graph.zig");
const plan = @import("translucent_plan.zig");

const FrameGraph = frame_graph.FrameGraph;
const Pass = frame_graph.Pass;
const PassId = frame_graph.PassId;
const TargetId = @import("plan.zig").TargetId;

pub const Vertex = plan.Vertex;
pub const Quad = plan.Quad;

pub const Options = struct {
    /// The format of the colour target, for example the HDR target of the
    /// post chain.
    color_format: gpu_mod.TextureFormat = .rgba16float,
    depth_format: gpu_mod.TextureFormat = .depth24plus,
    /// The most quads that `setQuads` accepts.
    max_quads: u32 = 4096,
    /// Sort again when the camera moves this distance from the position
    /// of the last sort (REQ-GPU-023).
    resort_distance: f32 = 1,
};

pub const PassOptions = struct {
    /// The colour and depth targets of the opaque scene.
    color: TargetId,
    depth: TargetId,
    /// The frame graph order. It must be higher than the order of the
    /// opaque pass. The default is after the clouds (50) and before the
    /// precipitation (60).
    order: i32 = 55,
};

pub const Translucent = struct {
    allocator: std.mem.Allocator,
    graph: *FrameGraph,
    options: Options,
    pipeline: gpu_mod.RenderPipeline,
    vertex_buffer: gpu_mod.Buffer,
    index_buffer: gpu_mod.Buffer,
    centers: std.ArrayList([3]f32) = .empty,
    indices: std.ArrayList(u32) = .empty,
    sorter: plan.Sorter = .{},
    sort_state: plan.SortState,
    /// The number of sorts since `init`. A test reads it.
    sort_count: u32 = 0,
    pass: ?PassId = null,

    /// Make the pipeline and the buffers. The graph must stay at its
    /// address while the pass exists.
    pub fn init(allocator: std.mem.Allocator, graph: *FrameGraph, options: Options) !Translucent {
        const gpu = graph.gpu;
        if (options.max_quads == 0) return error.NoQuads;
        var vertex_buffer = try gpu.createBuffer(.{
            .label = "sw_translucent_vertices",
            .size = @as(u64, options.max_quads) * 4 * @sizeOf(Vertex),
            .usage = .{ .vertex = true, .copy_dst = true },
        });
        errdefer vertex_buffer.destroy();
        var index_buffer = try gpu.createBuffer(.{
            .label = "sw_translucent_indices",
            .size = @as(u64, options.max_quads) * 6 * @sizeOf(u32),
            .usage = .{ .index = true, .copy_dst = true },
        });
        errdefer index_buffer.destroy();
        var layouts = [_]*gpu_mod.BindGroupLayout{&graph.frame_layout};
        var pipeline_layout = try gpu.createPipelineLayout(.{
            .label = "sw_translucent",
            .bind_group_layouts = &layouts,
        });
        var module = try gpu.createShaderModule(.{ .label = "sw_translucent", .code = plan.shader });
        const pipeline = try gpu.createRenderPipeline(.{
            .label = "sw_translucent",
            .layout = &pipeline_layout,
            .vertex = .{ .module = &module, .entry_point = "vs_main", .buffers = &vertex_buffers },
            .fragment = .{
                .module = &module,
                .entry_point = "fs_main",
                .targets = &[_]gpu_mod.ColorTargetState{.{ .format = options.color_format, .blend = plan.blend }},
            },
            // Both sides draw: the camera can see a quad from each side.
            .primitive = .{ .topology = .triangle_list, .cull_mode = .none },
            .depth_stencil = plan.depthStencil(options.depth_format),
            .multisample = .{ .count = 1 },
        });
        return .{
            .allocator = allocator,
            .graph = graph,
            .options = options,
            .pipeline = pipeline,
            .vertex_buffer = vertex_buffer,
            .index_buffer = index_buffer,
            .sort_state = .{ .resort_distance = options.resort_distance },
        };
    }

    /// Release the buffers. Call it before `FrameGraph.deinit`. The graph
    /// keeps the pass, but the pass does not run.
    pub fn deinit(self: *Translucent) void {
        if (self.pass) |p| self.graph.setPassEnabled(p, false);
        self.centers.deinit(self.allocator);
        self.indices.deinit(self.allocator);
        self.sorter.deinit(self.allocator);
        self.vertex_buffer.destroy();
        self.index_buffer.destroy();
        self.* = undefined;
    }

    /// Set the quads. The next `update` sorts them.
    pub fn setQuads(self: *Translucent, quads: []const Quad) !void {
        if (quads.len > self.options.max_quads) return error.TooManyQuads;
        try self.centers.resize(self.allocator, quads.len);
        for (quads, self.centers.items) |q, *c| c.* = plan.center(q);
        try self.indices.resize(self.allocator, quads.len * 6);
        if (quads.len > 0) try self.graph.uploads.write(self.vertex_buffer, 0, std.mem.sliceAsBytes(quads));
        self.sort_state.invalidate();
    }

    /// Sort the quads for a camera at `camera` when the camera moved the
    /// resort distance, or the quads changed. Call it each frame before
    /// `FrameGraph.execute`.
    pub fn update(self: *Translucent, camera: [3]f32) !void {
        if (self.centers.items.len == 0) return;
        if (!self.sort_state.needsSort(camera)) return;
        try self.sorter.sort(self.allocator, self.centers.items, camera, self.indices.items);
        try self.graph.uploads.write(self.index_buffer, 0, std.mem.sliceAsBytes(self.indices.items));
        self.sort_count += 1;
    }

    /// Add a frame graph pass that draws the quads on the colour and depth
    /// targets of the scene, after the opaque pass. The pass keeps a
    /// pointer to `self`, so `self` must stay at its address.
    pub fn addPass(self: *Translucent, options: PassOptions) !void {
        if (self.pass != null) return error.DuplicatePassName;
        if (self.graph.findPass("sw_translucent") != null) return error.DuplicatePassName;
        try self.graph.addPass(.{
            .name = "sw_translucent",
            .order = options.order,
            .attachments = .{
                .colors = &.{.{ .target = options.color, .load_op = .load }},
                .depth = .{ .target = options.depth, .load_op = .load },
            },
            .callback = .of(Translucent, self, draw),
        });
        self.pass = self.graph.findPass("sw_translucent").?;
    }

    /// Draw the quads into `pass`. The pass formats must match `Options`.
    pub fn draw(self: *Translucent, pass: *Pass) anyerror!void {
        const n: u32 = @intCast(self.centers.items.len);
        if (n == 0) return;
        const rp = pass.render orelse return error.NoRenderPass;
        rp.setPipeline(self.pipeline);
        pass.bindFrame();
        rp.setVertexBuffer(0, self.vertex_buffer, 0, @as(u64, n) * 4 * @sizeOf(Vertex));
        rp.setIndexBuffer(self.index_buffer, .uint32, 0, @as(u64, n) * 6 * @sizeOf(u32));
        rp.drawIndexed(n * 6, 1, 0, 0, 0);
    }
};

const vertex_buffers = [_]gpu_mod.VertexBufferLayout{.{
    .array_stride = @sizeOf(Vertex),
    .attributes = &[_]gpu_mod.VertexAttribute{
        .{ .format = .float32x3, .offset = @offsetOf(Vertex, "pos"), .shader_location = 0 },
        .{ .format = .float32x4, .offset = @offsetOf(Vertex, "color"), .shader_location = 1 },
    },
}};
