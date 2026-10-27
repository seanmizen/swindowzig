//! Instanced box models: trees of boxes that the game animates part by
//! part. One draw call draws all instances of one model (REQ-GPU-014).
//!
//! The game adds each model one time. Each frame it clears the instances,
//! adds each instance with a transform and one rotation for each part, and
//! draws a layer in a frame graph pass. The CPU makes one matrix for each
//! part of each instance. The first draw of a frame stages all records in
//! one storage buffer through the staged uploads of the graph
//! (REQ-GPU-006). The vertex shader reads the record of its part with
//! `instance_index`.
//!
//! The `.first_person` layer is for a model in front of the camera, such
//! as a held object. Its instances are in view space. Its pass draws after
//! the scene, with its own depth range near the near plane, so the world
//! never covers it (REQ-GPU-015).
//!
//! ```zig
//! var models = try render.BoxModels.init(allocator, &graph, .{ .color_format = post.hdr_format });
//! defer models.deinit();
//! const figure = try models.addModel(.{ .parts = &figure_parts });
//! try models.addFirstPersonPass(.{ .color = post.hdr, .depth = depth });
//! // Each frame, before `graph.execute`:
//! models.clear();
//! try models.add(.world, figure, .{ .transform = m, .rotations = &pose });
//! // In the scene pass on `post.hdr`:
//! try models.draw(pass, .world, .{});
//! ```
//!
//! The model colours are linear, and the shader calls `sw_fog`, so a model
//! fades into the sky as the rest of the scene does.
//!
//! With `Options.lighting`, the `.world` layer casts shadows into each
//! cascade of the `Lighting`, and the draws get the shadows and the point
//! lights (REQ-GPU-016, REQ-GPU-017). The light direction then comes from
//! the `Lighting` (the sun by default). `Light` gives the colours.

const std = @import("std");
const gpu_mod = @import("sw_gpu");
const sw_math = @import("sw_math");
const frame_graph = @import("frame_graph.zig");
const lighting_mod = @import("lighting.zig");
const plan = @import("plan.zig");
const ring_mod = @import("ring.zig");
const model_plan = @import("box_model_plan.zig");
const wgsl = @import("wgsl.zig");

const Mat4 = sw_math.Mat4;
const Quat = sw_math.Quat;
const FrameGraph = frame_graph.FrameGraph;
const Pass = frame_graph.Pass;
const PassId = frame_graph.PassId;
const TargetId = plan.TargetId;

pub const ModelDesc = model_plan.ModelDesc;
pub const Part = model_plan.Part;
pub const Box = model_plan.Box;
pub const Light = model_plan.Light;

/// The bind group index of the box model bindings.
pub const group: u32 = 1;

/// A set of instances that one pass draws.
pub const Layer = enum(u1) {
    /// Instances in world space, with the frame camera.
    world,
    /// Instances in view space, in front of the world. See
    /// `BoxModels.addFirstPersonPass`.
    first_person,
};
const layer_count = 2;

/// The handle of one model, from `BoxModels.addModel`.
pub const ModelId = enum(u16) {
    _,

    pub fn index(self: ModelId) usize {
        return @backingInt(self);
    }
};

pub const Options = struct {
    /// The format of the colour target. Use `PostChain.hdr_format` for the
    /// HDR target.
    color_format: gpu_mod.TextureFormat = .rgba16float,
    depth_format: gpu_mod.TextureFormat = .depth24plus,
    /// The most part records in one frame: the sum of the parts of each
    /// instance, over all models and layers. Each record is 80 bytes.
    max_records: u32 = 16 * 1024,
    /// Receive the shadows and the point lights of this lighting. Deinit
    /// the models before the lighting.
    lighting: ?lighting_mod.Lighting = null,
    /// With `lighting`: draw the `.world` layer into each shadow cascade.
    cast_shadows: bool = true,
};

pub const Instance = struct {
    /// Model space to world space (`.world`) or to view space
    /// (`.first_person`). Use rotations, translations and uniform scales.
    transform: Mat4 = Mat4.identity(),
    /// One rotation for each part, in part order. A part with no rotation
    /// in the slice does not turn.
    rotations: []const Quat = &.{},
    /// Multiplies the albedo of each box (linear RGB).
    tint: [3]f32 = .{ 1, 1, 1 },
};

/// The camera and the depth of one draw.
pub const View = struct {
    /// Instance space to clip space. Null: `sw_frame.view_proj` for
    /// `.world`, and `sw_frame.proj` for `.first_person` (the light then
    /// turns with `sw_frame.view`).
    view_proj: ?Mat4 = null,
    /// The depth range of the draw, near and far, in 0 to 1. NDC depth `d`
    /// becomes `near + d * (far - near)`.
    depth_range: [2]f32 = .{ 0, 1 },
    /// Apply `sw_fog` with the world position.
    fog: bool = true,
};

pub const FirstPersonOptions = struct {
    /// The colour target of the scene, for example `PostChain.hdr`.
    color: TargetId,
    /// The depth target of the scene. The pass keeps its contents, so
    /// later passes still see the world depth.
    depth: TargetId,
    /// The frame graph order. It must be higher than the order of the
    /// scene passes on the same targets.
    order: i32 = 100,
    /// A depth range near the near plane puts the model in front of the
    /// world. `setFirstPersonView` changes it.
    view: View = .{ .depth_range = .{ 0, 0.01 }, .fog = false },
};

/// The work of the current frame (or the last frame, after `execute`).
pub const Stats = struct {
    /// The draw calls of `draw`. The shadow draws are not in this count,
    /// nor in `instances` and `records`.
    draw_calls: u32 = 0,
    /// The draw calls into the shadow cascades.
    shadow_draw_calls: u32 = 0,
    instances: u32 = 0,
    records: u32 = 0,
};

const Model = struct {
    vertex_buffer: gpu_mod.Buffer,
    vertex_count: u32,
    /// A copy of the parts with no boxes: the pivots and the parents.
    parts: []model_plan.Part,
    records: [layer_count]std.ArrayList(model_plan.PartRecord) = @splat(.empty),
    /// The index of the first record of each layer in the storage buffer.
    base: [layer_count]u32 = @splat(0),
};

/// The state behind `BoxModels`. It has a stable address: the first-person
/// pass keeps a pointer to it.
const State = struct {
    allocator: std.mem.Allocator,
    graph: *FrameGraph,
    options: Options,
    pipeline: gpu_mod.RenderPipeline,
    /// The depth-only pipeline of the shadow casts.
    shadow_pipeline: ?gpu_mod.RenderPipeline = null,
    lighting: ?lighting_mod.Lighting = null,
    layout: gpu_mod.BindGroupLayout,
    storage: gpu_mod.Buffer,
    bind_group: gpu_mod.BindGroup,
    models: std.ArrayList(Model) = .empty,
    /// The records of all instances that `add` gave since `clear`.
    record_count: u32 = 0,
    /// The records changed since the last upload.
    dirty: bool = false,
    light: Light = .{},
    first_person: View = .{},
    first_person_pass: ?PassId = null,
    stats: Stats = .{},
    stats_frame: u32 = 0,

    fn deinit(self: *State) void {
        if (self.lighting) |*l| l.removeCaster(self);
        for (self.models.items) |*m| {
            m.vertex_buffer.destroy();
            self.allocator.free(m.parts);
            for (&m.records) |*r| r.deinit(self.allocator);
        }
        self.models.deinit(self.allocator);
        self.bind_group.release();
        self.storage.destroy();
    }

    /// Stage the records of all layers in one block (REQ-GPU-006).
    fn upload(self: *State) !void {
        var offset: u32 = 0;
        const stride = @sizeOf(model_plan.PartRecord);
        for (0..layer_count) |layer| {
            for (self.models.items) |*m| {
                m.base[layer] = offset;
                const records = m.records[layer].items;
                if (records.len == 0) continue;
                try self.graph.uploads.write(self.storage, @as(u64, offset) * stride, std.mem.sliceAsBytes(records));
                offset += @intCast(records.len);
            }
        }
        self.dirty = false;
    }

    fn resetStats(self: *State) void {
        if (self.stats_frame != self.graph.frame_count) {
            self.stats = .{};
            self.stats_frame = self.graph.frame_count;
        }
    }

    fn draw(self: *State, pass: *Pass, layer: Layer, view: View) !void {
        self.resetStats();
        const lit = self.lighting != null;
        const dir = if (self.lighting) |l| l.lightDirection() else self.light.unitDir();
        const calls = try self.drawWith(pass, layer, view, self.pipeline, dir, lit);
        self.stats.draw_calls += calls;
    }

    /// Draw the `.world` layer into one shadow cascade.
    fn drawShadow(self: *State, cp: *lighting_mod.CasterPass) anyerror!void {
        self.resetStats();
        const pipeline = self.shadow_pipeline orelse return;
        const view: View = .{ .view_proj = cp.view_proj, .fog = false };
        const calls = try self.drawWith(cp.pass, .world, view, pipeline, .{ 0, 1, 0 }, false);
        self.stats.shadow_draw_calls += calls;
    }

    /// Draw each model of `layer` with `pipeline`. Give the draw calls.
    fn drawWith(self: *State, pass: *Pass, layer: Layer, view: View, pipeline: gpu_mod.RenderPipeline, dir: [3]f32, lit: bool) !u32 {
        if (self.dirty) try self.upload();
        const rp = pass.render orelse return error.NoRenderPass;
        const l = @backingInt(layer);
        const mode: model_plan.CameraMode = if (view.view_proj != null) .custom else switch (layer) {
            .world => .frame,
            .first_person => .frame_view_space,
        };
        var bound = false;
        var calls: u32 = 0;
        for (self.models.items) |*m| {
            const records = m.records[l].items;
            if (records.len == 0) continue;
            const parts: u32 = @intCast(m.parts.len);
            const instances: u32 = @intCast(records.len / m.parts.len);
            const uniforms: model_plan.DrawUniforms = .{
                .view_proj = if (view.view_proj) |vp| vp.data else wgsl.identity,
                .light_dir = .{ dir[0], dir[1], dir[2], 0 },
                .light_color = .{ self.light.color[0], self.light.color[1], self.light.color[2], 0 },
                .ambient = .{ self.light.ambient[0], self.light.ambient[1], self.light.ambient[2], 0 },
                .depth_range = .{ view.depth_range[0], view.depth_range[1], 0, 0 },
                .info = .{ m.base[l], parts, @backingInt(mode), @intFromBool(view.fog) },
            };
            const offset = try pass.push(uniforms);
            if (!bound) {
                rp.setPipeline(pipeline);
                pass.bindFrame();
                if (lit) try self.lighting.?.bind(pass, model_plan.lighting_group);
                bound = true;
            }
            rp.setBindGroupWithOffsets(group, self.bind_group, &.{offset});
            rp.setVertexBuffer(0, m.vertex_buffer, 0, @as(u64, m.vertex_count) * @sizeOf(model_plan.Vertex));
            rp.draw(m.vertex_count, instances, 0, 0);
            calls += 1;
            // The instance and record counts are of the lit draws only.
            if (pipeline.handle == self.pipeline.handle) {
                self.stats.instances += instances;
                self.stats.records += @intCast(records.len);
            }
        }
        return calls;
    }

    fn runFirstPerson(self: *State, pass: *Pass) anyerror!void {
        try self.draw(pass, .first_person, self.first_person);
    }
};

const vertex_buffers = [_]gpu_mod.VertexBufferLayout{.{
    .array_stride = @sizeOf(model_plan.Vertex),
    .attributes = &[_]gpu_mod.VertexAttribute{
        .{ .format = .float32x3, .offset = @offsetOf(model_plan.Vertex, "position"), .shader_location = 0 },
        .{ .format = .float32x3, .offset = @offsetOf(model_plan.Vertex, "normal"), .shader_location = 1 },
        .{ .format = .float32x3, .offset = @offsetOf(model_plan.Vertex, "color"), .shader_location = 2 },
        .{ .format = .uint32, .offset = @offsetOf(model_plan.Vertex, "part"), .shader_location = 3 },
    },
}};

pub const BoxModels = struct {
    state: *State,

    /// Make the pipeline and the storage buffer. The graph must stay at its
    /// address while the models exist.
    pub fn init(allocator: std.mem.Allocator, graph: *FrameGraph, options: Options) !BoxModels {
        const gpu = graph.gpu;
        if (options.max_records == 0) return error.NoRecords;
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);

        const storage_size = @as(u64, options.max_records) * @sizeOf(model_plan.PartRecord);
        var storage = try gpu.createBuffer(.{
            .label = "sw_box_models_parts",
            .size = storage_size,
            .usage = .{ .storage = true, .copy_dst = true },
        });
        errdefer storage.destroy();
        var layout = try gpu.createBindGroupLayout(.{
            .label = "sw_box_models",
            .entries = &[_]gpu_mod.BindGroupLayoutEntry{
                ring_mod.UniformRing.layoutEntry(0, .{ .vertex = true, .fragment = true }, @sizeOf(model_plan.DrawUniforms)),
                .{ .binding = 1, .visibility = .{ .vertex = true }, .buffer = .{ .type = .read_only_storage, .min_binding_size = @sizeOf(model_plan.PartRecord) } },
            },
        });
        const bind_group = try gpu.createBindGroup(.{
            .label = "sw_box_models",
            .layout = &layout,
            .entries = &[_]gpu_mod.BindGroupEntry{
                graph.ring.bindGroupEntry(0, @sizeOf(model_plan.DrawUniforms)),
                .{ .binding = 1, .buffer = &storage, .size = storage_size },
            },
        });
        errdefer bind_group.release();

        // The lit pipeline has the lighting group at group 2.
        var layouts: [3]*gpu_mod.BindGroupLayout = .{ &graph.frame_layout, &layout, undefined };
        var layout_count: usize = 2;
        if (options.lighting) |l| {
            layouts[model_plan.lighting_group] = l.layout();
            layout_count = 3;
        }
        var pipeline_layout = try gpu.createPipelineLayout(.{
            .label = "sw_box_models",
            .bind_group_layouts = layouts[0..layout_count],
        });
        var module = try gpu.createShaderModule(.{
            .label = "sw_box_models",
            .code = if (options.lighting != null) model_plan.shader_lit else model_plan.shader,
        });
        const pipeline = try gpu.createRenderPipeline(.{
            .label = "sw_box_models",
            .layout = &pipeline_layout,
            .vertex = .{ .module = &module, .entry_point = "vs_main", .buffers = &vertex_buffers },
            .fragment = .{
                .module = &module,
                .entry_point = "fs_main",
                .targets = &[_]gpu_mod.ColorTargetState{.{ .format = options.color_format }},
            },
            .primitive = .{ .topology = .triangle_list, .cull_mode = .back },
            .depth_stencil = .{ .format = options.depth_format, .depth_write_enabled = true, .depth_compare = .less },
            .multisample = .{ .count = 1 },
        });
        state.* = .{
            .allocator = allocator,
            .graph = graph,
            .options = options,
            .pipeline = pipeline,
            .lighting = options.lighting,
            .layout = layout,
            .storage = storage,
            .bind_group = bind_group,
        };

        // The shadow casts: a depth-only pipeline with no fragment stage.
        // Both faces draw, so a thin box casts from each side.
        if (options.lighting) |l| {
            if (options.cast_shadows) {
                var shadow_layout = try gpu.createPipelineLayout(.{
                    .label = "sw_box_models_shadow",
                    .bind_group_layouts = layouts[0..2],
                });
                var shadow_module = try gpu.createShaderModule(.{ .label = "sw_box_models_shadow", .code = model_plan.shader });
                state.shadow_pipeline = try gpu.createRenderPipeline(.{
                    .label = "sw_box_models_shadow",
                    .layout = &shadow_layout,
                    .vertex = .{ .module = &shadow_module, .entry_point = "vs_main", .buffers = &vertex_buffers },
                    .primitive = .{ .topology = .triangle_list, .cull_mode = .none },
                    .depth_stencil = .{ .format = lighting_mod.Lighting.format, .depth_write_enabled = true, .depth_compare = .less },
                    .multisample = .{ .count = 1 },
                });
                var lt = l;
                try lt.addCaster(.of(State, state, State.drawShadow));
            }
        }
        return .{ .state = state };
    }

    /// Release the models. Call it before `FrameGraph.deinit`, and before
    /// the `deinit` of `Options.lighting`. The graph keeps the first-person
    /// pass, but the pass does not run.
    pub fn deinit(self: *BoxModels) void {
        const s = self.state;
        if (s.first_person_pass) |p| s.graph.setPassEnabled(p, false);
        s.deinit();
        s.allocator.destroy(s);
        self.* = undefined;
    }

    /// Add a model: build its mesh into a vertex buffer. The model keeps no
    /// pointer into `desc`.
    pub fn addModel(self: *BoxModels, desc: ModelDesc) !ModelId {
        const s = self.state;
        try model_plan.validate(desc);
        if (s.models.items.len > std.math.maxInt(u16)) return error.TooManyModels;
        const count = model_plan.vertexCount(desc);
        if (count == 0) return error.NoBoxes;
        const vertices = try s.allocator.alloc(model_plan.Vertex, count);
        defer s.allocator.free(vertices);
        model_plan.buildMesh(desc, vertices);

        const parts = try s.allocator.alloc(model_plan.Part, desc.parts.len);
        errdefer s.allocator.free(parts);
        for (parts, desc.parts) |*dst, src| dst.* = .{ .parent = src.parent, .pivot = src.pivot };

        const gpu = s.graph.gpu;
        const bytes = std.mem.sliceAsBytes(vertices);
        const buffer = try gpu.createBuffer(.{
            .label = "sw_box_model",
            .size = bytes.len,
            .usage = .{ .vertex = true, .copy_dst = true },
        });
        errdefer buffer.destroy();
        gpu.writeBuffer(buffer, 0, bytes);
        try s.models.append(s.allocator, .{ .vertex_buffer = buffer, .vertex_count = @intCast(count), .parts = parts });
        return @fromBackingInt(@as(u16, @intCast(s.models.items.len - 1)));
    }

    /// The number of parts of a model.
    pub fn partCount(self: *const BoxModels, model: ModelId) usize {
        return self.state.models.items[model.index()].parts.len;
    }

    /// Remove all instances of all layers. Call it one time each frame,
    /// before the `add` calls of the frame. With no `clear`, the instances
    /// stay, and the draws need no upload.
    pub fn clear(self: *BoxModels) void {
        const s = self.state;
        for (s.models.items) |*m| {
            for (&m.records) |*r| r.clearRetainingCapacity();
        }
        s.record_count = 0;
        s.dirty = true;
    }

    /// Add one instance of `model` to `layer`, in the pose that `instance`
    /// gives.
    pub fn add(self: *BoxModels, layer: Layer, model: ModelId, instance: Instance) !void {
        const s = self.state;
        if (model.index() >= s.models.items.len) return error.UnknownModel;
        const m = &s.models.items[model.index()];
        const n: u32 = @intCast(m.parts.len);
        if (s.record_count + n > s.options.max_records) return error.TooManyRecords;
        var matrices: [model_plan.max_parts]Mat4 = undefined;
        try model_plan.pose(m.parts, instance.transform, instance.rotations, matrices[0..n]);
        const records = try m.records[@backingInt(layer)].addManyAsSlice(s.allocator, n);
        const tint: [4]f32 = .{ instance.tint[0], instance.tint[1], instance.tint[2], 1 };
        for (records, matrices[0..n]) |*r, mat| r.* = .{ .model = mat.data, .tint = tint };
        s.record_count += n;
        s.dirty = true;
    }

    /// Draw each model that has instances in `layer`: one draw call for
    /// each model. Call it in a frame graph pass whose colour and depth
    /// formats match `Options`.
    pub fn draw(self: *BoxModels, pass: *Pass, layer: Layer, view: View) !void {
        try self.state.draw(pass, layer, view);
    }

    /// Add a frame graph pass that draws the `.first_person` layer after
    /// the scene, on the colour and depth targets of the scene
    /// (REQ-GPU-015).
    pub fn addFirstPersonPass(self: *BoxModels, options: FirstPersonOptions) !void {
        const s = self.state;
        if (s.first_person_pass != null) return error.DuplicatePassName;
        if (s.graph.findPass("sw_box_models_first_person") != null) return error.DuplicatePassName;
        try s.graph.addPass(.{
            .name = "sw_box_models_first_person",
            .order = options.order,
            .attachments = .{
                .colors = &.{.{ .target = options.color, .load_op = .load }},
                .depth = .{ .target = options.depth, .load_op = .load },
            },
            .callback = .of(State, s, State.runFirstPerson),
        });
        s.first_person_pass = s.graph.findPass("sw_box_models_first_person").?;
        s.first_person = options.view;
    }

    /// Change the camera and the depth range of the first-person pass.
    pub fn setFirstPersonView(self: *BoxModels, view: View) void {
        self.state.first_person = view;
    }

    pub fn setLight(self: *BoxModels, light: Light) void {
        self.state.light = light;
    }

    pub fn getLight(self: *const BoxModels) Light {
        return self.state.light;
    }

    /// The draw calls, instances and records of the current frame. After
    /// `FrameGraph.execute`, the values of the frame that it submitted.
    pub fn stats(self: *const BoxModels) Stats {
        return self.state.stats;
    }
};
