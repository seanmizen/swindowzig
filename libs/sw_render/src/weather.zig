//! The cloud pass and the precipitation pass of a frame graph
//! (REQ-GPU-020, REQ-GPU-021). `weather_plan.zig` has the rules and the
//! CPU reference of the shaders.
//!
//! Both passes draw on the scene colour target after the opaque scene, for
//! example on `PostChain.hdr`. With the depth target of the scene, the
//! scene hides the clouds and the particles behind it. Neither pass writes
//! the depth.
//!
//! ```zig
//! var clouds = try render.Clouds.init(allocator, &graph, post.hdr, .{
//!     .depth = depth,
//!     .shape = .{ .width = 64, .height = 64, .pixels = shape_rgba },
//!     .settings = .{ .bottom = 140 },
//! });
//! defer clouds.deinit();
//! var snow = try render.Precipitation.init(allocator, &graph, post.hdr, .{ .depth = depth });
//! defer snow.deinit();
//! try snow.setHeightMap(.{ .origin = .{ x0, z0 }, .width = 64, .depth = 64, .heights = heights });
//! // Each frame, before `graph.execute`:
//! const input: render.weather.FrameInput = .{
//!     .camera = eye,
//!     .seconds = time,
//!     .light = render.weather.skyLight(sky.state()),
//! };
//! try clouds.update(input);
//! try snow.update(input);
//! ```

const std = @import("std");
const gpu_mod = @import("sw_gpu");
const frame_graph = @import("frame_graph.zig");
const layout = @import("layout.zig");
const plan = @import("plan.zig");
const weather_plan = @import("weather_plan.zig");
const post_mod = @import("post.zig");

const FrameGraph = frame_graph.FrameGraph;
const Pass = frame_graph.Pass;
const PassId = frame_graph.PassId;
const TargetId = plan.TargetId;

pub const CloudSettings = weather_plan.CloudSettings;
pub const PrecipitationSettings = weather_plan.PrecipitationSettings;
pub const PrecipitationKind = weather_plan.PrecipitationKind;
pub const HeightMap = weather_plan.HeightMap;
pub const FrameInput = weather_plan.FrameInput;
pub const Light = weather_plan.Light;

const alpha_blend: gpu_mod.BlendState = .{
    .color = .{ .src_factor = .src_alpha, .dst_factor = .one_minus_src_alpha },
    .alpha = .{ .src_factor = .one, .dst_factor = .one_minus_src_alpha },
};

fn makePipeline(
    graph: *FrameGraph,
    label: []const u8,
    group_layout: *gpu_mod.BindGroupLayout,
    code: []const u8,
    fragment_entry: []const u8,
    target: TargetId,
    depth: ?TargetId,
) !gpu_mod.RenderPipeline {
    const gpu = graph.gpu;
    var pipeline_layout = try gpu.createPipelineLayout(.{
        .label = label,
        .bind_group_layouts = &[_]*gpu_mod.BindGroupLayout{ &graph.frame_layout, group_layout },
    });
    var module = try gpu.createShaderModule(.{ .label = label, .code = code });
    return gpu.createRenderPipeline(.{
        .label = label,
        .layout = &pipeline_layout,
        .vertex = .{ .module = &module, .entry_point = "vs_main" },
        .fragment = .{
            .module = &module,
            .entry_point = fragment_entry,
            .targets = &[_]gpu_mod.ColorTargetState{.{ .format = graph.targetFormat(target), .blend = alpha_blend }},
        },
        .primitive = .{ .topology = .triangle_list, .cull_mode = .none },
        .depth_stencil = if (depth) |d| .{ .format = graph.targetFormat(d), .depth_write_enabled = false, .depth_compare = .less } else null,
        .multisample = .{ .count = 1 },
    });
}

/// One texture of a pass, with its view and the bind group of the pass.
const Binding = struct {
    texture: gpu_mod.Texture,
    view: gpu_mod.TextureView,
    group: gpu_mod.BindGroup,
    width: u32,
    height: u32,

    fn release(self: Binding) void {
        self.group.release();
        self.view.release();
        self.texture.destroy();
    }
};

/// The GPU objects of a cloud or precipitation pass. It has a stable
/// address: the frame graph keeps a pointer to it in the pass callback.
const Runner = struct {
    graph: *FrameGraph,
    pipeline: gpu_mod.RenderPipeline,
    layout: gpu_mod.BindGroupLayout,
    buffer: gpu_mod.Buffer,
    uniform_size: u64,
    format: gpu_mod.TextureFormat,
    texel_bytes: u32,
    current: ?Binding = null,
    /// A texture that a new size replaced. A queued write can still use
    /// it, so the runner destroys it after the next submit.
    old: ?Binding = null,
    old_frame: u32 = 0,
    /// The vertices and the instances of the draw.
    vertices: u32,
    instances: u32 = 1,

    fn create(allocator: std.mem.Allocator, graph: *FrameGraph, comptime U: type, label: []const u8, code: []const u8, fragment_entry: []const u8, texture: @FieldType(gpu_mod.BindGroupLayoutEntry, "texture"), format: gpu_mod.TextureFormat, texel_bytes: u32, vertices: u32, target: TargetId, depth: ?TargetId) !*Runner {
        const gpu = graph.gpu;
        const runner = try allocator.create(Runner);
        errdefer allocator.destroy(runner);
        var group_layout = try gpu.createBindGroupLayout(.{
            .label = label,
            .entries = &[_]gpu_mod.BindGroupLayoutEntry{
                .{ .binding = 0, .visibility = .{ .vertex = true, .fragment = true }, .buffer = .{ .type = .uniform, .min_binding_size = @sizeOf(U) } },
                .{ .binding = 1, .visibility = .{ .vertex = true, .fragment = true }, .texture = texture },
            },
        });
        var buffer = try gpu.createBuffer(.{
            .label = label,
            .size = @sizeOf(U),
            .usage = .{ .uniform = true, .copy_dst = true },
        });
        errdefer buffer.destroy();
        const pipeline = try makePipeline(graph, label, &group_layout, code, fragment_entry, target, depth);
        runner.* = .{
            .graph = graph,
            .pipeline = pipeline,
            .layout = group_layout,
            .buffer = buffer,
            .uniform_size = @sizeOf(U),
            .format = format,
            .texel_bytes = texel_bytes,
            .vertices = vertices,
        };
        return runner;
    }

    fn destroy(self: *Runner, allocator: std.mem.Allocator) void {
        if (self.current) |b| b.release();
        if (self.old) |b| b.release();
        self.buffer.destroy();
        allocator.destroy(self);
    }

    fn run(self: *Runner, pass: *Pass) anyerror!void {
        if (self.instances == 0) return;
        const rp = pass.render.?;
        rp.setPipeline(self.pipeline);
        pass.bindFrame();
        rp.setBindGroup(weather_plan.pass_group, self.current.?.group);
        rp.draw(self.vertices, self.instances, 0, 0);
    }

    /// Destroy the old texture after a submit.
    fn collect(self: *Runner) void {
        if (self.old) |b| {
            if (self.graph.frame_count != self.old_frame) {
                b.release();
                self.old = null;
            }
        }
    }

    /// Write `data` (`width` by `height` texels) to the texture. A new
    /// size makes a new texture and bind group.
    fn write(self: *Runner, width: u32, height: u32, data: []const u8) !void {
        const gpu = self.graph.gpu;
        self.collect();
        const same = if (self.current) |b| b.width == width and b.height == height else false;
        if (!same) {
            // One old texture at most: a second resize in the same frame
            // replaces a texture that no submit used.
            if (self.old != null and self.current != null) return error.TooManyResizes;
            const texture = try gpu.createTexture(.{
                .size = .{ .width = width, .height = height, .depth_or_array_layers = 1 },
                .format = self.format,
                .usage = .{ .texture_binding = true, .copy_dst = true },
            });
            errdefer texture.destroy();
            var view = try texture.createView(.{});
            errdefer view.release();
            const group = try gpu.createBindGroup(.{
                .layout = &self.layout,
                .entries = &[_]gpu_mod.BindGroupEntry{
                    .{ .binding = 0, .buffer = &self.buffer, .size = self.uniform_size },
                    .{ .binding = 1, .texture_view = &view },
                },
            });
            if (self.current) |b| {
                self.old = b;
                self.old_frame = self.graph.frame_count;
            }
            self.current = .{ .texture = texture, .view = view, .group = group, .width = width, .height = height };
        }
        gpu.writeTextureRegion(self.current.?.texture, data, .{
            .size = .{ .width = width, .height = height, .depth_or_array_layers = 1 },
            .bytes_per_row = width * self.texel_bytes,
            .rows_per_image = height,
        });
    }
};

/// Add the pass of `runner` to the graph.
fn addPass(graph: *FrameGraph, name: []const u8, order: i32, runner: *Runner, target: TargetId, depth: ?TargetId) !PassId {
    if (graph.findPass(name) != null) return error.DuplicatePassName;
    // The pass loads the depth and does not change it. The graph copies
    // the colour list.
    const colors = [_]plan.ColorAttachment{.{ .target = target, .load_op = .load }};
    try graph.addPass(.{
        .name = name,
        .order = order,
        .attachments = .{
            .colors = &colors,
            .depth = if (depth) |d| .{ .target = d, .load_op = .load } else null,
        },
        .callback = .of(Runner, runner, Runner.run),
    });
    return graph.findPass(name).?;
}

// =============================================================================
// The clouds
// =============================================================================

pub const CloudOptions = struct {
    /// The frame graph order. It must be higher than the order of the
    /// opaque scene passes on the same targets.
    order: i32 = 50,
    /// The depth target of the scene. Null: the clouds draw over the scene.
    depth: ?TargetId = null,
    /// The shape: RGBA8, one texel for each cell. A texel with alpha 128
    /// or more is a cloud box. Its RGB multiplies the cloud colour.
    shape: layout.Image,
    settings: CloudSettings = .{},
};

/// A cloud layer at a set height that moves with the wind (REQ-GPU-020).
pub const Clouds = struct {
    allocator: std.mem.Allocator,
    graph: *FrameGraph,
    /// The cloud pass in the frame graph.
    pass: PassId,
    /// The game can change the settings at any time. `update` reads them.
    settings: CloudSettings,
    runner: *Runner,
    /// The cloud shadow effect of `addShadowEffect`.
    shadow_effect: ?struct { post: *post_mod.PostChain, id: post_mod.EffectId } = null,

    /// Add the cloud pass on `target` to `graph`. The graph must stay at
    /// its address while the clouds exist.
    pub fn init(allocator: std.mem.Allocator, graph: *FrameGraph, target: TargetId, options: CloudOptions) !Clouds {
        if (graph.findPass("sw_clouds") != null) return error.DuplicatePassName;
        const runner = try Runner.create(
            allocator,
            graph,
            weather_plan.CloudUniforms,
            "sw_clouds",
            weather_plan.cloud_shader,
            if (options.depth != null) "fs_main" else "fs_flat",
            .{ .sample_type = .float, .view_dimension = .@"2d" },
            .rgba8unorm,
            4,
            3,
            target,
            options.depth,
        );
        errdefer runner.destroy(allocator);
        var self: Clouds = .{
            .allocator = allocator,
            .graph = graph,
            .pass = undefined,
            .settings = options.settings,
            .runner = runner,
        };
        try self.setShape(options.shape);
        self.pass = try addPass(graph, "sw_clouds", options.order, runner, target, options.depth);
        try self.update(.{ .camera = .{ 0, 0, 0 }, .seconds = 0 });
        return self;
    }

    /// Release the clouds. Call it before `FrameGraph.deinit`. The graph
    /// keeps the pass, but the pass does not run.
    pub fn deinit(self: *Clouds) void {
        self.graph.setPassEnabled(self.pass, false);
        self.runner.destroy(self.allocator);
        self.* = undefined;
    }

    /// Give a new shape image (RGBA8). The pass uses it from the next frame.
    pub fn setShape(self: *Clouds, shape: layout.Image) !void {
        if (shape.width == 0 or shape.height == 0) return error.EmptyShape;
        if (shape.pixels.len != @as(usize, shape.width) * shape.height * 4) return error.BadShapeSize;
        try self.runner.write(shape.width, shape.height, shape.pixels);
        if (self.shadow_effect) |e| e.post.setEffectParams(e.id, self.runner.current.?.group);
    }

    /// Add the cloud shadows (REQ-GPU-031) as an HDR effect of `post` that
    /// reads `depth`, the depth target of the scene. Each pixel with
    /// geometry under a cloud gets darker, with `CloudSettings.shadow`.
    /// The shadow uses the shape, the wind and the height of the cloud
    /// layer. Turn it off with `post.setEffectEnabled`, or with a shadow
    /// of 0. The clouds must stay at their address while the chain
    /// exists. The pass is `sw_cloud_shadows`.
    pub fn addShadowEffect(self: *Clouds, post: *post_mod.PostChain, depth: TargetId) !post_mod.EffectId {
        if (self.shadow_effect != null) return error.DuplicateEffectName;
        const id = try post.addEffect(.{
            .name = "sw_cloud_shadows",
            .kind = .hdr,
            .code = weather_plan.cloud_shadow_shader,
            .depth = depth,
            .params = .{ .layout = &self.runner.layout, .bind_group = self.runner.current.?.group },
        });
        self.shadow_effect = .{ .post = post, .id = id };
        return id;
    }

    /// The uniforms of the frame `input`, with the current settings.
    pub fn uniforms(self: *const Clouds, input: FrameInput) weather_plan.CloudUniforms {
        const b = self.runner.current.?;
        return weather_plan.cloudUniforms(self.settings, b.width, b.height, input);
    }

    /// Call it one time each frame, before `FrameGraph.execute`. It stages
    /// the uniforms of the cloud pass.
    pub fn update(self: *Clouds, input: FrameInput) !void {
        self.runner.collect();
        try self.graph.uploads.writeValue(self.runner.buffer, 0, self.uniforms(input));
    }

    /// Draw the clouds (true) or skip the pass (false).
    pub fn setEnabled(self: *Clouds, enabled: bool) void {
        self.graph.setPassEnabled(self.pass, enabled);
    }
};

// =============================================================================
// The precipitation
// =============================================================================

pub const PrecipitationOptions = struct {
    /// The frame graph order. It must be higher than the order of the
    /// opaque scene passes and of the cloud pass on the same targets.
    order: i32 = 60,
    /// The depth target of the scene. Null: the particles draw over the
    /// scene.
    depth: ?TargetId = null,
    settings: PrecipitationSettings = .{},
};

/// The position and the size of the height map, from `setHeightMap`.
const MapInfo = struct {
    origin: [2]f32,
    cell_size: f32,
    width: u32,
    depth: u32,
};

/// Rain or snow in a column around the camera (REQ-GPU-021).
pub const Precipitation = struct {
    allocator: std.mem.Allocator,
    graph: *FrameGraph,
    /// The precipitation pass in the frame graph.
    pass: PassId,
    /// The game can change the settings at any time. `update` reads them.
    settings: PrecipitationSettings,
    /// The height map, or null.
    map: ?MapInfo = null,
    runner: *Runner,

    /// Add the precipitation pass on `target` to `graph`. The graph must
    /// stay at its address while the precipitation exists.
    pub fn init(allocator: std.mem.Allocator, graph: *FrameGraph, target: TargetId, options: PrecipitationOptions) !Precipitation {
        if (graph.findPass("sw_precipitation") != null) return error.DuplicatePassName;
        const runner = try Runner.create(
            allocator,
            graph,
            weather_plan.PrecipitationUniforms,
            "sw_precipitation",
            weather_plan.precipitation_shader,
            "fs_main",
            .{ .sample_type = .unfilterable_float, .view_dimension = .@"2d" },
            .r32float,
            4,
            6,
            target,
            options.depth,
        );
        errdefer runner.destroy(allocator);
        // A 1 by 1 map texture until the game gives a map.
        const zero = [_]f32{0};
        try runner.write(1, 1, std.mem.sliceAsBytes(&zero));
        var self: Precipitation = .{
            .allocator = allocator,
            .graph = graph,
            .pass = try addPass(graph, "sw_precipitation", options.order, runner, target, options.depth),
            .settings = options.settings,
            .runner = runner,
        };
        try self.update(.{ .camera = .{ 0, 0, 0 }, .seconds = 0 });
        return self;
    }

    /// Release the precipitation. Call it before `FrameGraph.deinit`. The
    /// graph keeps the pass, but the pass does not run.
    pub fn deinit(self: *Precipitation) void {
        self.graph.setPassEnabled(self.pass, false);
        self.runner.destroy(self.allocator);
        self.* = undefined;
    }

    /// Give the ground heights around the camera. A particle under the
    /// ground height of its cell does not draw. Out of the map there is no
    /// ground. Give a new map when the camera moves near its edge. The
    /// pass uses it from the next frame. A map of a new size can wait for
    /// the next frame: give the same size again in one frame, or get
    /// `error.TooManyResizes`.
    pub fn setHeightMap(self: *Precipitation, map: HeightMap) !void {
        if (map.width == 0 or map.depth == 0) return error.EmptyHeightMap;
        if (map.heights.len != @as(usize, map.width) * map.depth) return error.BadHeightMapSize;
        if (!(map.cell_size > 0)) return error.BadCellSize;
        try self.runner.write(map.width, map.depth, std.mem.sliceAsBytes(map.heights));
        self.map = .{ .origin = map.origin, .cell_size = map.cell_size, .width = map.width, .depth = map.depth };
    }

    /// Remove the height map. The particles then fall to the bottom of the
    /// column.
    pub fn clearHeightMap(self: *Precipitation) void {
        self.map = null;
    }

    /// The uniforms of the frame `input`, with the current settings and map.
    pub fn uniforms(self: *const Precipitation, input: FrameInput) weather_plan.PrecipitationUniforms {
        var map: ?HeightMap = null;
        if (self.map) |m| map = .{ .origin = m.origin, .cell_size = m.cell_size, .width = m.width, .depth = m.depth, .heights = &.{} };
        return weather_plan.precipitationUniforms(self.settings, map, input);
    }

    /// Call it one time each frame, before `FrameGraph.execute`. It stages
    /// the uniforms of the pass, and sets the number of particles.
    pub fn update(self: *Precipitation, input: FrameInput) !void {
        self.runner.collect();
        self.runner.instances = self.settings.active();
        try self.graph.uploads.writeValue(self.runner.buffer, 0, self.uniforms(input));
    }

    /// Draw the precipitation (true) or skip the pass (false).
    pub fn setEnabled(self: *Precipitation, enabled: bool) void {
        self.graph.setPassEnabled(self.pass, enabled);
    }
};
