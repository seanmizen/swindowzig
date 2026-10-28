//! The sky pass of a frame graph: a gradient, a sun, a moon, stars at
//! night, and an optional cube-map skybox, from a time of day
//! (REQ-GPU-010). The sky also gives the fog colour, so the fog of the
//! scene meets the sky at the horizon (REQ-GPU-011).
//!
//! The sky pass draws one triangle over its target, before the scene. It
//! writes each pixel, so the scene passes on the same target use
//! `load_op = .load`. With a `PostChain`, the target is `post.hdr`, and the
//! sun and the sky go through the tonemap.
//!
//! ```zig
//! var sky = try render.Sky.init(allocator, &graph, post.hdr, .{ .fog = .{ .start = 48, .end = 96 } });
//! defer sky.deinit();
//! // Each frame:
//! sky.setTime(time_of_day); // 0 midnight, 0.25 sunrise, 0.5 noon, 0.75 sunset
//! var frame: render.FrameUniforms = .{ .view = view, .proj = proj, .view_proj = vp, .camera_pos = eye };
//! frame.sky = try sky.update();
//! if (try graph.execute(frame)) gpu.present();
//! ```
//!
//! A scene shader applies the fog with `sw_fog(colour, world_pos)` from the
//! shared WGSL prefix. `sky.state()` gives the sun and moon directions and
//! the daylight for the scene light.

const std = @import("std");
const gpu_mod = @import("sw_gpu");
const frame_graph = @import("frame_graph.zig");
const plan = @import("plan.zig");
const sky_plan = @import("sky_plan.zig");
const wgsl = @import("wgsl.zig");

const FrameGraph = frame_graph.FrameGraph;
const Pass = frame_graph.Pass;
const PassId = frame_graph.PassId;
const TargetId = plan.TargetId;

pub const Settings = sky_plan.Settings;
pub const Fog = sky_plan.Fog;
pub const State = sky_plan.State;

pub const Options = struct {
    /// The frame graph order of the sky pass. It must be lower than the
    /// order of the scene passes on the same target.
    order: i32 = -100,
    settings: Settings = .{},
    /// The time of day, 0 to 1.
    time: f32 = 0.5,
    /// Null: no fog.
    fog: ?Fog = null,
};

/// A cube texture with six faces, for `Sky.setCubeMap`.
pub const CubeMap = struct {
    texture: gpu_mod.Texture,
    view: gpu_mod.TextureView,

    /// Make a cube map of `size` by `size` texels from six RGBA8 images in
    /// the face sequence +X, -X, +Y, -Y, +Z, -Z. Each image has
    /// `size * size * 4` bytes. `.rgba8unorm_srgb` decodes sRGB colour to
    /// linear colour when the sky reads it.
    pub fn init(gpu: *gpu_mod.GPU, size: u32, faces: [6][]const u8, format: gpu_mod.TextureFormat) !CubeMap {
        for (faces) |f| {
            if (f.len != @as(usize, size) * size * 4) return error.BadFaceSize;
        }
        const texture = try gpu.createTexture(.{
            .label = "sw_sky_cube",
            .size = .{ .width = size, .height = size, .depth_or_array_layers = 6 },
            .format = format,
            .usage = .{ .texture_binding = true, .copy_dst = true },
        });
        errdefer texture.destroy();
        for (faces, 0..) |f, layer| {
            gpu.writeTextureRegion(texture, f, .{
                .origin = .{ .z = @intCast(layer) },
                .size = .{ .width = size, .height = size, .depth_or_array_layers = 1 },
                .bytes_per_row = size * 4,
                .rows_per_image = size,
            });
        }
        const view = try texture.createView(.{ .dimension = .cube, .array_layer_count = 6 });
        return .{ .texture = texture, .view = view };
    }

    pub fn deinit(self: *CubeMap) void {
        self.view.release();
        self.texture.destroy();
        self.* = undefined;
    }
};

/// The GPU objects of the pass. It has a stable address: the frame graph
/// keeps a pointer to it in the pass callback.
const Runner = struct {
    pipeline: gpu_mod.RenderPipeline,
    layout: gpu_mod.BindGroupLayout,
    buffer: gpu_mod.Buffer,
    sampler: gpu_mod.Sampler,
    /// A black cube map of 1 by 1 texels, for when the game gives none.
    blank: CubeMap,
    group: ?gpu_mod.BindGroup = null,

    fn run(self: *Runner, pass: *Pass) anyerror!void {
        const rp = pass.render.?;
        rp.setPipeline(self.pipeline);
        pass.bindFrame();
        rp.setBindGroup(sky_plan.pass_group, self.group.?);
        rp.draw(3, 1, 0, 0);
    }

    fn bind(self: *Runner, gpu: *gpu_mod.GPU, view: *gpu_mod.TextureView) !void {
        const group = try gpu.createBindGroup(.{
            .label = "sw_sky",
            .layout = &self.layout,
            .entries = &[_]gpu_mod.BindGroupEntry{
                .{ .binding = 0, .buffer = &self.buffer, .size = @sizeOf(sky_plan.PassUniforms) },
                .{ .binding = 1, .texture_view = view },
                .{ .binding = 2, .sampler = &self.sampler },
            },
        });
        if (self.group) |g| g.release();
        self.group = group;
    }
};

pub const Sky = struct {
    allocator: std.mem.Allocator,
    graph: *FrameGraph,
    /// The sky pass in the frame graph.
    pass: PassId,
    settings: Settings,
    /// The time of day, 0 to 1. Use `setTime`.
    time: f32,
    /// Null: no fog.
    fog: ?Fog,
    /// The cube-map tint while a cube map is on.
    cube_tint: ?[3]f32 = null,
    runner: *Runner,

    /// Add the sky pass on `target` to `graph`. The graph must stay at its
    /// address while the sky exists.
    pub fn init(allocator: std.mem.Allocator, graph: *FrameGraph, target: TargetId, options: Options) !Sky {
        const gpu = graph.gpu;
        if (graph.findPass("sw_sky") != null) return error.DuplicatePassName;
        const runner = try allocator.create(Runner);
        errdefer allocator.destroy(runner);

        var layout = try gpu.createBindGroupLayout(.{
            .label = "sw_sky",
            .entries = &[_]gpu_mod.BindGroupLayoutEntry{
                .{ .binding = 0, .visibility = .{ .fragment = true }, .buffer = .{ .type = .uniform, .min_binding_size = @sizeOf(sky_plan.PassUniforms) } },
                .{ .binding = 1, .visibility = .{ .fragment = true }, .texture = .{ .sample_type = .float, .view_dimension = .cube } },
                .{ .binding = 2, .visibility = .{ .fragment = true }, .sampler = .{ .type = .filtering } },
            },
        });
        var buffer = try gpu.createBuffer(.{
            .label = "sw_sky_pass",
            .size = @sizeOf(sky_plan.PassUniforms),
            .usage = .{ .uniform = true, .copy_dst = true },
        });
        errdefer buffer.destroy();
        const sampler = try gpu.createSampler(.{
            .label = "sw_sky_sampler",
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_filter = .linear,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
        });
        const black = [_]u8{ 0, 0, 0, 255 };
        var blank = try CubeMap.init(gpu, 1, .{ &black, &black, &black, &black, &black, &black }, .rgba8unorm);
        errdefer blank.deinit();

        var pipeline_layout = try gpu.createPipelineLayout(.{
            .label = "sw_sky",
            .bind_group_layouts = &[_]*gpu_mod.BindGroupLayout{ &graph.frame_layout, &layout },
        });
        var module = try gpu.createShaderModule(.{ .label = "sw_sky", .code = sky_plan.shader });
        const pipeline = try gpu.createRenderPipeline(.{
            .label = "sw_sky",
            .layout = &pipeline_layout,
            .vertex = .{ .module = &module, .entry_point = "vs_main" },
            .fragment = .{
                .module = &module,
                .entry_point = "fs_main",
                .targets = &[_]gpu_mod.ColorTargetState{.{ .format = graph.targetFormat(target) }},
            },
            .primitive = .{ .topology = .triangle_list, .cull_mode = .none },
            // A multisampled target gets a multisampled sky (REQ-GPU-040).
            .multisample = .{ .count = graph.targetSampleCount(target) },
        });
        runner.* = .{
            .pipeline = pipeline,
            .layout = layout,
            .buffer = buffer,
            .sampler = sampler,
            .blank = blank,
        };
        try runner.bind(gpu, &runner.blank.view);
        errdefer runner.group.?.release();

        try graph.addPass(.{
            .name = "sw_sky",
            .order = options.order,
            .attachments = .{ .colors = &.{.{ .target = target, .load_op = .clear }} },
            .callback = .of(Runner, runner, Runner.run),
        });
        var self: Sky = .{
            .allocator = allocator,
            .graph = graph,
            .pass = graph.findPass("sw_sky").?,
            .settings = options.settings,
            .time = sky_plan.wrapTime(options.time),
            .fog = options.fog,
            .runner = runner,
        };
        // The pass has valid uniforms before the first `update`.
        _ = try self.update();
        return self;
    }

    /// Release the sky. Call it before `FrameGraph.deinit`. The graph keeps
    /// the pass, but the pass does not run.
    pub fn deinit(self: *Sky) void {
        self.graph.setPassEnabled(self.pass, false);
        const r = self.runner;
        if (r.group) |g| g.release();
        r.blank.deinit();
        r.buffer.destroy();
        self.allocator.destroy(r);
        self.* = undefined;
    }

    /// Set the time of day. 0 is midnight, 0.25 sunrise, 0.5 noon and 0.75
    /// sunset. A value out of 0 to 1 wraps.
    pub fn setTime(self: *Sky, time: f32) void {
        self.time = sky_plan.wrapTime(time);
    }

    /// The sky at the current time: the sun and moon directions, the
    /// daylight and the colours.
    pub fn state(self: *const Sky) State {
        return sky_plan.state(self.time, self.settings);
    }

    /// Call it one time each frame, before `FrameGraph.execute`. It stages
    /// the uniforms of the sky pass, and gives the value for
    /// `FrameUniforms.sky`.
    pub fn update(self: *Sky) !wgsl.SkyUniforms {
        const s = self.state();
        const pass_uniforms = sky_plan.passUniforms(s, self.settings, self.cube_tint);
        try self.graph.uploads.writeValue(self.runner.buffer, 0, pass_uniforms);
        return sky_plan.uniforms(s, self.settings, self.fog);
    }

    /// Show a cube-map skybox in place of the gradient. The sky multiplies
    /// its colour by `tint` (linear RGB). The sun, the moon and the stars
    /// stay on top of it. Null: the gradient again. The cube map must stay
    /// valid while the sky uses it. With a cube map, set `Fog.color` to
    /// match the horizon of the cube map.
    pub fn setCubeMap(self: *Sky, cube: ?*CubeMap, tint: [3]f32) !void {
        if (cube) |c| {
            try self.runner.bind(self.graph.gpu, &c.view);
            self.cube_tint = tint;
        } else {
            try self.runner.bind(self.graph.gpu, &self.runner.blank.view);
            self.cube_tint = null;
        }
    }

    /// Draw the sky (true) or skip the pass (false).
    pub fn setEnabled(self: *Sky, enabled: bool) void {
        self.graph.setPassEnabled(self.pass, enabled);
    }
};
