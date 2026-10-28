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
//!
//! A game with its own render pass and many sets of quads (for example
//! one set for each chunk of a world) uses `Pipeline` and `Batch` with a
//! `FrameBinding` in place of a frame graph (REQ-GPU-040). The game can
//! write the vertices of a batch to its buffer itself and give only the
//! quad centres for the sort:
//!
//! ```zig
//! var frame = try render.FrameBinding.init(gpu);
//! var pipe = try render.TranslucentPipeline.init(gpu, &frame.layout, .{ .color_format = .bgra8unorm, .sample_count = 4 });
//! var batch = try render.TranslucentBatch.init(allocator, gpu, quad_count, 1);
//! gpu.writeBuffer(batch.vertex_buffer, 0, vertex_bytes);
//! try batch.setCenters(centers);
//! // Each frame:
//! frame.write(gpu, .{ .view_proj = vp });
//! try batch.update(gpu, camera_pos);
//! pipe.draw(render_pass, frame.bind_group, &batch);
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
    /// The sample count of the targets (MSAA).
    sample_count: u32 = 1,
};

/// The formats of the targets of a `Pipeline`.
pub const PipelineOptions = struct {
    color_format: gpu_mod.TextureFormat = .rgba16float,
    depth_format: gpu_mod.TextureFormat = .depth24plus,
    /// The sample count of the targets (MSAA).
    sample_count: u32 = 1,
};

fn createPipeline(gpu: *gpu_mod.GPU, frame_layout: *gpu_mod.BindGroupLayout, options: PipelineOptions) !gpu_mod.RenderPipeline {
    var layouts = [_]*gpu_mod.BindGroupLayout{frame_layout};
    var pipeline_layout = try gpu.createPipelineLayout(.{
        .label = "sw_translucent",
        .bind_group_layouts = &layouts,
    });
    var module = try gpu.createShaderModule(.{ .label = "sw_translucent", .code = plan.shader });
    return gpu.createRenderPipeline(.{
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
        .multisample = .{ .count = options.sample_count },
    });
}

/// The translucent pipeline for a render pass of the game, with no frame
/// graph (REQ-GPU-040). Group 0 is the frame uniforms of a `FrameBinding`.
pub const Pipeline = struct {
    pipeline: gpu_mod.RenderPipeline,

    /// `frame_layout` is the layout of the frame uniforms, for example
    /// `FrameBinding.layout`.
    pub fn init(gpu: *gpu_mod.GPU, frame_layout: *gpu_mod.BindGroupLayout, options: PipelineOptions) !Pipeline {
        return .{ .pipeline = try createPipeline(gpu, frame_layout, options) };
    }

    /// Draw the quads of `batch`, far to near, in `rp`. `frame` is the
    /// bind group of the frame uniforms. The pass formats must match the
    /// options. This sets the pipeline and group 0 of the pass.
    pub fn draw(self: *const Pipeline, rp: gpu_mod.RenderPassEncoder, frame: gpu_mod.BindGroup, batch: *const Batch) void {
        const n = batch.count();
        if (n == 0) return;
        rp.setPipeline(self.pipeline);
        rp.setBindGroup(0, frame);
        rp.setVertexBuffer(0, batch.vertex_buffer, 0, @as(u64, n) * 4 * @sizeOf(Vertex));
        rp.setIndexBuffer(batch.index_buffer, .uint32, 0, @as(u64, n) * 6 * @sizeOf(u32));
        rp.drawIndexed(n * 6, 1, 0, 0, 0);
    }
};

/// One set of translucent quads with its own buffers and its own sort
/// (REQ-GPU-023, REQ-GPU-040). The vertices of quad i are the vertices
/// 4i to 4i + 3 of `vertex_buffer`. The index buffer holds the quads far
/// to near. Each write goes straight to the queue (`gpu.writeBuffer`), so
/// a batch needs no frame graph.
pub const Batch = struct {
    allocator: std.mem.Allocator,
    vertex_buffer: gpu_mod.Buffer,
    index_buffer: gpu_mod.Buffer,
    /// The most quads that the buffers hold.
    capacity: u32,
    centers: std.ArrayList([3]f32) = .empty,
    indices: std.ArrayList(u32) = .empty,
    sorter: plan.Sorter = .{},
    sort_state: plan.SortState,
    /// The number of sorts since `init`. A test reads it.
    sort_count: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, gpu: *gpu_mod.GPU, capacity: u32, resort_distance: f32) !Batch {
        if (capacity == 0) return error.NoQuads;
        var vertex_buffer = try gpu.createBuffer(.{
            .label = "sw_translucent_batch_vertices",
            .size = @as(u64, capacity) * 4 * @sizeOf(Vertex),
            .usage = .{ .vertex = true, .copy_dst = true },
        });
        errdefer vertex_buffer.destroy();
        const index_buffer = try gpu.createBuffer(.{
            .label = "sw_translucent_batch_indices",
            .size = @as(u64, capacity) * 6 * @sizeOf(u32),
            .usage = .{ .index = true, .copy_dst = true },
        });
        return .{
            .allocator = allocator,
            .vertex_buffer = vertex_buffer,
            .index_buffer = index_buffer,
            .capacity = capacity,
            .sort_state = .{ .resort_distance = resort_distance },
        };
    }

    pub fn deinit(self: *Batch) void {
        self.centers.deinit(self.allocator);
        self.indices.deinit(self.allocator);
        self.sorter.deinit(self.allocator);
        self.vertex_buffer.destroy();
        self.index_buffer.destroy();
        self.* = undefined;
    }

    /// The number of quads.
    pub fn count(self: *const Batch) u32 {
        return @intCast(self.centers.items.len);
    }

    /// Give the centres of the quads. The game wrote their vertices to
    /// `vertex_buffer` from offset 0, 4 for each quad. The next `update`
    /// sorts them.
    pub fn setCenters(self: *Batch, centers: []const [3]f32) !void {
        if (centers.len > self.capacity) return error.TooManyQuads;
        try self.centers.resize(self.allocator, centers.len);
        @memcpy(self.centers.items, centers);
        try self.indices.resize(self.allocator, centers.len * 6);
        self.sort_state.invalidate();
    }

    /// Write the vertices of `quads` and their centres.
    pub fn setQuads(self: *Batch, gpu: *gpu_mod.GPU, quads: []const Quad) !void {
        if (quads.len > self.capacity) return error.TooManyQuads;
        try self.centers.resize(self.allocator, quads.len);
        for (quads, self.centers.items) |q, *c| c.* = plan.center(q);
        try self.indices.resize(self.allocator, quads.len * 6);
        if (quads.len > 0) gpu.writeBuffer(self.vertex_buffer, 0, std.mem.sliceAsBytes(quads));
        self.sort_state.invalidate();
    }

    /// Sort the quads for a camera at `camera` when the camera moved the
    /// resort distance or the quads changed. Give true after a sort.
    pub fn update(self: *Batch, gpu: *gpu_mod.GPU, camera: [3]f32) !bool {
        if (self.centers.items.len == 0) return false;
        if (!self.sort_state.needsSort(camera)) return false;
        try self.sorter.sort(self.allocator, self.centers.items, camera, self.indices.items);
        gpu.writeBuffer(self.index_buffer, 0, std.mem.sliceAsBytes(self.indices.items));
        self.sort_count += 1;
        return true;
    }
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
        const pipeline = try createPipeline(gpu, &graph.frame_layout, .{
            .color_format = options.color_format,
            .depth_format = options.depth_format,
            .sample_count = options.sample_count,
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
