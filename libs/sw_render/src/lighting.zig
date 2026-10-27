//! Cascaded shadow maps for one directional light, and point lights
//! (REQ-GPU-016, REQ-GPU-017, REQ-GPU-018).
//!
//! `Lighting.init` adds one fixed-size depth target and one frame graph
//! pass for each cascade. Each pass calls the shadow casters that the game
//! added with `addCaster`. A caster draws its geometry with
//! `CasterPass.view_proj` in a depth-only pipeline (`format`).
//! `BoxModels` is a caster when the game sets its `Options.lighting`.
//!
//! Each frame, before `FrameGraph.execute`, the game calls `update` with
//! the frame uniforms. `update` fits the cascades to the camera, and
//! stages the lighting uniforms. By default the light follows the sun of
//! `FrameUniforms.sky` (the moon at night).
//!
//! A lit pass puts `layout` in its pipeline layout and the WGSL include
//! (`lighting_plan.include(group)`) after the shared prefix. It calls
//! `bind(pass, group)` before its draws. Its shader then calls
//! `sw_shadow`, `sw_point_lights` and `sw_light_dir`.
//!
//! ```zig
//! var lighting = try render.Lighting.init(allocator, &graph, .{});
//! defer lighting.deinit();
//! // Each frame:
//! try lighting.setPointLights(&.{.{ .position = torch, .color = .{ 1, 0.6, 0.3 } }});
//! try lighting.update(frame);
//! if (try graph.execute(frame)) gpu.present();
//! // In a lit pass:
//! try lighting.bind(pass, render.lighting.default_group);
//! ```

const std = @import("std");
const gpu_mod = @import("sw_gpu");
const sw_math = @import("sw_math");
const frame_graph = @import("frame_graph.zig");
const plan = @import("plan.zig");
const lighting_plan = @import("lighting_plan.zig");
const wgsl = @import("wgsl.zig");

const Mat4 = sw_math.Mat4;
const FrameGraph = frame_graph.FrameGraph;
const Pass = frame_graph.Pass;
const PassId = frame_graph.PassId;
const TargetId = plan.TargetId;

pub const PointLight = lighting_plan.PointLight;
pub const ShadowSettings = lighting_plan.ShadowSettings;

pub const Options = struct {
    /// The width and height of the depth map of each cascade, in texels.
    map_size: u32 = 2048,
    /// The number of cascades, 1 to `lighting_plan.max_cascades`.
    cascades: u32 = 3,
    /// The frame graph order of the first cascade pass. Cascade `i` has
    /// `order + i`. It must be lower than the order of the lit passes.
    order: i32 = -1000,
    shadows: ShadowSettings = .{},
};

/// What a shadow caster gets for one cascade.
pub const CasterPass = struct {
    /// The frame graph pass. Its render pass has the depth map of the
    /// cascade as its only attachment.
    pass: *Pass,
    cascade: u32,
    /// World space to the clip space of the cascade.
    view_proj: Mat4,
    /// The depth format of the map. Use it for the caster pipeline.
    format: gpu_mod.TextureFormat,
};

/// The function and the user pointer of a shadow caster.
pub const CasterCallback = struct {
    user: ?*anyopaque,
    run: *const fn (user: ?*anyopaque, pass: *CasterPass) anyerror!void,

    /// A caster that calls `f(user, pass)`.
    pub fn of(comptime T: type, user: *T, comptime f: fn (*T, *CasterPass) anyerror!void) CasterCallback {
        return .{ .user = user, .run = struct {
            fn run(u: ?*anyopaque, pass: *CasterPass) anyerror!void {
                return f(@ptrCast(@alignCast(u.?)), pass);
            }
        }.run };
    }
};

/// The pass names of the cascades. A pass name must stay valid while the
/// graph exists.
const pass_names = [lighting_plan.max_cascades][]const u8{ "sw_shadow_0", "sw_shadow_1", "sw_shadow_2", "sw_shadow_3" };
const target_names = [lighting_plan.max_cascades][]const u8{ "sw_shadow_map_0", "sw_shadow_map_1", "sw_shadow_map_2", "sw_shadow_map_3" };

const CascadeRunner = struct {
    state: *State,
    index: u32,

    fn run(self: *CascadeRunner, pass: *Pass) anyerror!void {
        const s = self.state;
        var cp: CasterPass = .{
            .pass = pass,
            .cascade = self.index,
            .view_proj = s.cascades[self.index].view_proj,
            .format = State.format,
        };
        for (s.casters.items) |c| try c.run(c.user, &cp);
    }
};

/// The state behind `Lighting`. It has a stable address: the passes keep
/// pointers to it.
pub const State = struct {
    const format: gpu_mod.TextureFormat = .depth32float;

    allocator: std.mem.Allocator,
    graph: *FrameGraph,
    options: Options,
    settings: ShadowSettings,
    targets: [lighting_plan.max_cascades]TargetId = undefined,
    passes: [lighting_plan.max_cascades]PassId = undefined,
    runners: [lighting_plan.max_cascades]CascadeRunner = undefined,
    cascades: [lighting_plan.max_cascades]lighting_plan.Cascade = @splat(.{ .view_proj = Mat4.identity(), .split = 0, .texel = 0 }),
    buffer: gpu_mod.Buffer,
    layout: gpu_mod.BindGroupLayout,
    sampler: gpu_mod.Sampler,
    bind_group: ?gpu_mod.BindGroup = null,
    bound_generation: u32 = 0,
    casters: std.ArrayList(CasterCallback) = .empty,
    points: [lighting_plan.max_point_lights]PointLight = undefined,
    point_count: usize = 0,
    light_override: ?[3]f32 = null,
    light_dir: [3]f32 = .{ 0, 1, 0 },
    uniforms: lighting_plan.LightingUniforms = .{},

    fn deinit(self: *State) void {
        for (self.passes[0..self.options.cascades]) |p| self.graph.setPassEnabled(p, false);
        if (self.bind_group) |g| g.release();
        self.casters.deinit(self.allocator);
        self.buffer.destroy();
    }

    fn setPassesEnabled(self: *State) void {
        for (self.passes[0..self.options.cascades]) |p| self.graph.setPassEnabled(p, self.settings.enabled);
    }
};

pub const Lighting = struct {
    state: *State,

    /// The depth format of each cascade map, for caster pipelines.
    pub const format = State.format;

    /// Add the cascade targets and passes to `graph`, and make the uniform
    /// buffer, the sampler and the bind group layout. The graph must stay
    /// at its address while the lighting exists.
    pub fn init(allocator: std.mem.Allocator, graph: *FrameGraph, options: Options) !Lighting {
        if (options.cascades == 0 or options.cascades > lighting_plan.max_cascades) return error.BadCascadeCount;
        if (options.map_size == 0) return error.BadMapSize;
        if (graph.findPass(pass_names[0]) != null) return error.DuplicatePassName;
        const gpu = graph.gpu;
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);

        var buffer = try gpu.createBuffer(.{
            .label = "sw_lighting",
            .size = @sizeOf(lighting_plan.LightingUniforms),
            .usage = .{ .uniform = true, .copy_dst = true },
        });
        errdefer buffer.destroy();
        const sampler = try gpu.createSampler(.{
            .label = "sw_shadow_sampler",
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_filter = .nearest,
            .compare = .less_equal,
        });
        const visibility: gpu_mod.ShaderStage = .{ .vertex = true, .fragment = true };
        var entries: [2 + lighting_plan.max_cascades]gpu_mod.BindGroupLayoutEntry = undefined;
        entries[0] = .{
            .binding = lighting_plan.uniforms_binding,
            .visibility = visibility,
            .buffer = .{ .type = .uniform, .min_binding_size = @sizeOf(lighting_plan.LightingUniforms) },
        };
        entries[1] = .{ .binding = lighting_plan.sampler_binding, .visibility = .{ .fragment = true }, .sampler = .{ .type = .comparison } };
        for (0..lighting_plan.max_cascades) |i| {
            entries[2 + i] = .{
                .binding = lighting_plan.map_binding + @as(u32, @intCast(i)),
                .visibility = .{ .fragment = true },
                .texture = .{ .sample_type = .depth, .view_dimension = .@"2d" },
            };
        }
        const group_layout = try gpu.createBindGroupLayout(.{ .label = "sw_lighting", .entries = &entries });

        state.* = .{
            .allocator = allocator,
            .graph = graph,
            .options = options,
            .settings = options.shadows,
            .buffer = buffer,
            .layout = group_layout,
            .sampler = sampler,
        };
        for (0..options.cascades) |i| {
            const target = try graph.addTarget(.{
                .name = target_names[i],
                .format = State.format,
                .size = .{ .fixed = .{ .width = options.map_size, .height = options.map_size } },
            });
            state.targets[i] = target;
            state.runners[i] = .{ .state = state, .index = @intCast(i) };
            try graph.addPass(.{
                .name = pass_names[i],
                .order = options.order + @as(i32, @intCast(i)),
                .attachments = .{ .depth = .{ .target = target } },
                .callback = .of(CascadeRunner, &state.runners[i], CascadeRunner.run),
            });
            state.passes[i] = graph.findPass(pass_names[i]).?;
        }
        state.setPassesEnabled();
        return .{ .state = state };
    }

    /// Release the lighting. Call it after the `deinit` of each caster
    /// (for example `BoxModels`), and before `FrameGraph.deinit`. The
    /// graph keeps the passes, but they do not run.
    pub fn deinit(self: *Lighting) void {
        const s = self.state;
        s.deinit();
        s.allocator.destroy(s);
        self.* = undefined;
    }

    /// The bind group layout of the lighting group. Put it in the pipeline
    /// layout of each lit pipeline, at the group of the WGSL include.
    pub fn layout(self: *const Lighting) *gpu_mod.BindGroupLayout {
        return &self.state.layout;
    }

    /// Add a shadow caster. Each cascade pass calls it.
    pub fn addCaster(self: *Lighting, caster: CasterCallback) !void {
        try self.state.casters.append(self.state.allocator, caster);
    }

    /// Remove each caster with the user pointer `user`.
    pub fn removeCaster(self: *Lighting, user: ?*anyopaque) void {
        const list = &self.state.casters;
        var i: usize = 0;
        while (i < list.items.len) {
            if (list.items[i].user == user) {
                _ = list.orderedRemove(i);
            } else i += 1;
        }
    }

    /// Turn the shadows on or off (REQ-GPU-018). Off: the cascade passes
    /// do not run, and `sw_shadow` gives 1.
    pub fn setShadowsEnabled(self: *Lighting, enabled: bool) void {
        self.state.settings.enabled = enabled;
        self.state.setPassesEnabled();
    }

    pub fn shadowsEnabled(self: *const Lighting) bool {
        return self.state.settings.enabled;
    }

    /// Change the shadow settings. `enabled` has the effect of
    /// `setShadowsEnabled`.
    pub fn setShadowSettings(self: *Lighting, settings: ShadowSettings) void {
        self.state.settings = settings;
        self.state.setPassesEnabled();
    }

    pub fn shadowSettings(self: *const Lighting) ShadowSettings {
        return self.state.settings;
    }

    /// Set the vector to the shadow light, in world space. Null: follow
    /// the sun of `FrameUniforms.sky`, and the moon at night (the default).
    pub fn setLightDirection(self: *Lighting, dir: ?[3]f32) void {
        self.state.light_override = dir;
    }

    /// The unit vector to the shadow light of the last `update`.
    pub fn lightDirection(self: *const Lighting) [3]f32 {
        return self.state.light_dir;
    }

    /// Set the point lights of the frame (REQ-GPU-017). The lighting
    /// copies them. They stay until the next call.
    pub fn setPointLights(self: *Lighting, lights: []const PointLight) !void {
        if (lights.len > lighting_plan.max_point_lights) return error.TooManyPointLights;
        @memcpy(self.state.points[0..lights.len], lights);
        self.state.point_count = lights.len;
    }

    /// Fit the cascades to the camera of `frame`, and stage the uniforms.
    /// Call it one time each frame, before `FrameGraph.execute`.
    pub fn update(self: *Lighting, frame: wgsl.FrameUniforms) !void {
        const s = self.state;
        const dir = if (s.light_override) |d| d else lighting_plan.lightFromSky(frame.sky);
        const n = s.options.cascades;
        try lighting_plan.fitCascades(frame.view, frame.proj, dir, s.settings, s.options.map_size, s.cascades[0..n]);
        s.uniforms = try lighting_plan.uniforms(s.cascades[0..n], dir, s.settings, s.options.map_size, s.points[0..s.point_count]);
        s.light_dir = .{ s.uniforms.light_dir[0], s.uniforms.light_dir[1], s.uniforms.light_dir[2] };
        try s.graph.uploads.writeValue(s.buffer, 0, s.uniforms);
    }

    /// The uniforms of the last `update`, for a CPU reference.
    pub fn uniforms(self: *const Lighting) lighting_plan.LightingUniforms {
        return self.state.uniforms;
    }

    /// The cascades of the last `update`.
    pub fn cascades(self: *const Lighting) []const lighting_plan.Cascade {
        return self.state.cascades[0..self.state.options.cascades];
    }

    /// Set the lighting group at `group` in a lit pass. The first call
    /// after a target change makes the bind group again.
    pub fn bind(self: *Lighting, pass: *Pass, group: u32) !void {
        const s = self.state;
        const graph = s.graph;
        if (s.bind_group == null or s.bound_generation != graph.generation) {
            if (s.bind_group) |g| g.release();
            s.bind_group = null;
            var entries: [2 + lighting_plan.max_cascades]gpu_mod.BindGroupEntry = undefined;
            entries[0] = .{
                .binding = lighting_plan.uniforms_binding,
                .buffer = &s.buffer,
                .size = @sizeOf(lighting_plan.LightingUniforms),
            };
            entries[1] = .{ .binding = lighting_plan.sampler_binding, .sampler = &s.sampler };
            for (0..lighting_plan.max_cascades) |i| {
                // A map that the options do not use gets the last map.
                const t = s.targets[@min(i, s.options.cascades - 1)];
                entries[2 + i] = .{ .binding = lighting_plan.map_binding + @as(u32, @intCast(i)), .texture_view = graph.view(t) };
            }
            s.bind_group = try graph.gpu.createBindGroup(.{ .label = "sw_lighting", .layout = &s.layout, .entries = &entries });
            s.bound_generation = graph.generation;
        }
        const rp = pass.render orelse return error.NoRenderPass;
        rp.setBindGroup(group, s.bind_group.?);
    }
};
