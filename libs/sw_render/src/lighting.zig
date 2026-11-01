//! Cascaded shadow maps for one directional light, and point lights with
//! cube shadow maps (REQ-GPU-016, REQ-GPU-017, REQ-GPU-018, REQ-GPU-044).
//!
//! `Lighting.init` adds one fixed-size depth target and one frame graph
//! pass for each cascade. `setShadowMap` changes the map size and the
//! cascade count while the game runs (REQ-GPU-043). Each pass calls the shadow casters that the game
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
//! A point light with `shadow = true` gets a cube shadow map (REQ-GPU-044).
//! The pass `sw_point_shadows` draws the 6 faces of a cube with the same
//! casters as the cascades (`CasterPass.point` is not null). It draws a
//! cube only when the light moved, its radius changed, the game set
//! `shadow_changed`, or a caster was added or removed. Thus a light that
//! does not move costs no shadow pass after its first frame. A light that
//! moves draws its cube again in each frame.
//!
//! ```zig
//! var lighting = try render.Lighting.init(allocator, &graph, .{});
//! defer lighting.deinit();
//! // Each frame:
//! try lighting.setPointLights(&.{
//!     .{ .position = lamp, .radius = 8, .shadow = true }, // still: drawn one time
//!     .{ .position = rail_pos, .radius = 6, .shadow = true }, // moves: drawn each frame
//!     .{ .position = torch, .color = .{ 1, 0.6, 0.3 } }, // no shadow
//! });
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
    /// `order + i`. The point shadow pass has `order +
    /// lighting_plan.max_cascades`. It must be lower than the order of the
    /// lit passes.
    order: i32 = -1000,
    shadows: ShadowSettings = .{},
    /// The most point lights with a shadow, 0 to
    /// `lighting_plan.max_point_shadows` (REQ-GPU-044).
    point_shadows: u32 = lighting_plan.max_point_shadows,
    /// The width and height of each face of a point light cube map, in
    /// texels. The lighting makes a cube map when a light first needs it.
    point_map_size: u32 = 512,
    /// The near plane of the cube faces, in world units. A caster nearer
    /// to the light than this does not cast a shadow.
    point_near: f32 = 0.05,
};

/// What a shadow caster gets for one cascade or one cube face.
pub const CasterPass = struct {
    /// The frame graph pass. Its render pass has the depth map of the
    /// cascade or of the cube face as its only attachment.
    pass: *Pass,
    /// The cascade. 0 for a cube face.
    cascade: u32,
    /// World space to the clip space of the cascade or of the cube face.
    view_proj: Mat4,
    /// The depth format of the map. Use it for the caster pipeline.
    format: gpu_mod.TextureFormat,
    /// Null for a cascade. For a face of a point light cube map: the light
    /// and the face (REQ-GPU-044).
    point: ?PointFace = null,
};

/// One face of a point light cube map, for a caster.
pub const PointFace = struct {
    /// The index of the light in the last `setPointLights`.
    light: u32,
    /// The cube map, 0 to `lighting_plan.max_point_shadows - 1`.
    slot: u32,
    /// The face, 0 to 5 (`lighting_plan.cube_faces`).
    face: u32,
    /// The position of the light.
    position: [3]f32,
    /// The far plane of the face: the radius of the light. A caster
    /// farther than this from the light can skip its draw.
    radius: f32,
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

/// The bindings of the lighting group: the uniforms, the sampler, the
/// cascade maps and the cube maps.
const bind_count = 2 + lighting_plan.max_cascades + lighting_plan.max_point_shadows;

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

/// The light that a cube map holds (REQ-GPU-044).
pub const PointKey = struct {
    position: [3]f32,
    radius: f32,
};

/// True when the cube map must be drawn again: it has no drawn light, or
/// the light moved, or its radius changed.
pub fn pointNeedsDraw(drawn: ?PointKey, now: PointKey) bool {
    const d = drawn orelse return true;
    return !std.meta.eql(d, now);
}

/// The pass name of the point shadows.
const point_pass_name = "sw_point_shadows";

/// The `PassTimer` name of each face of each cube map.
const face_names = blk: {
    var names: [lighting_plan.max_point_shadows][6][]const u8 = undefined;
    for (0..lighting_plan.max_point_shadows) |s| {
        for (0..6) |f| names[s][f] = std.fmt.comptimePrint("sw_point_shadow_{d}_face_{d}", .{ s, f });
    }
    break :blk names;
};

/// One cube map of a point light shadow.
const PointSlot = struct {
    texture: ?gpu_mod.Texture = null,
    /// The cube view for the lit passes.
    cube: ?gpu_mod.TextureView = null,
    /// A 2D view of each face, for the caster passes.
    faces: [6]?gpu_mod.TextureView = @splat(null),
    /// The light of the last draw. Null: the map holds no valid draw.
    drawn: ?PointKey = null,
    /// The index of the light of this frame, or null.
    light: ?u32 = null,
    key: PointKey = .{ .position = .{ 0, 0, 0 }, .radius = 0 },
    /// Draw the 6 faces in the next pass.
    draw: bool = false,

    fn release(self: *PointSlot) void {
        for (&self.faces) |*f| {
            if (f.*) |v| v.release();
            f.* = null;
        }
        if (self.cube) |v| v.release();
        if (self.texture) |t| t.destroy();
        self.cube = null;
        self.texture = null;
        self.drawn = null;
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
    /// The cascades that have a target and a pass in the graph. It is
    /// `options.cascades` or more: `setShadowMap` does not remove a pass.
    built: u32 = 0,
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
    /// The cube maps of the point light shadows (REQ-GPU-044).
    slots: [lighting_plan.max_point_shadows]PointSlot = @splat(.{}),
    /// The cube map of each point light, or -1.
    slot_of: [lighting_plan.max_point_lights]i32 = @splat(-1),
    point_pass: PassId = undefined,
    point_shadows_on: bool = true,
    /// A 1 x 1 cube for the bindings of the unused cube maps.
    empty_cube: gpu_mod.Texture,
    empty_view: gpu_mod.TextureView,
    /// The cube faces that the last point pass drew.
    faces_drawn: u32 = 0,

    fn deinit(self: *State) void {
        for (self.passes[0..self.built]) |p| self.graph.setPassEnabled(p, false);
        self.graph.setPassEnabled(self.point_pass, false);
        if (self.bind_group) |g| g.release();
        for (&self.slots) |*s| s.release();
        self.empty_view.release();
        self.empty_cube.destroy();
        self.casters.deinit(self.allocator);
        self.buffer.destroy();
    }

    /// Draw each cube map again at its next use.
    fn invalidatePoints(self: *State) void {
        for (&self.slots) |*s| s.drawn = null;
    }

    /// Make the cube map of slot `k` if it has no texture.
    fn ensureSlot(self: *State, k: usize) !void {
        const slot = &self.slots[k];
        if (slot.texture != null) return;
        const size = self.options.point_map_size;
        const tex = try self.graph.gpu.createTexture(.{
            .label = "sw_point_shadow_map",
            .size = .{ .width = size, .height = size, .depth_or_array_layers = 6 },
            .format = State.format,
            .usage = .{ .render_attachment = true, .texture_binding = true },
        });
        slot.texture = tex;
        slot.cube = try tex.createView(.{ .dimension = .cube, .array_layer_count = 6 });
        for (&slot.faces, 0..) |*f, i| {
            f.* = try tex.createView(.{ .dimension = .@"2d", .base_array_layer = @intCast(i), .array_layer_count = 1 });
        }
        slot.drawn = null;
        // The bind group must take the new cube view.
        if (self.bind_group) |g| g.release();
        self.bind_group = null;
    }

    /// Give each shadowed point light of this frame a cube map, and find
    /// the cube maps to draw.
    fn updatePoints(self: *State) !void {
        self.faces_drawn = 0;
        const near = self.options.point_near;
        var next: u32 = 0;
        for (self.points[0..self.point_count], 0..) |p, i| {
            self.slot_of[i] = -1;
            if (!self.point_shadows_on or !p.shadow or next >= self.options.point_shadows) continue;
            if (!lighting_plan.hasPointShadow(p.radius, near)) continue;
            try self.ensureSlot(next);
            const slot = &self.slots[next];
            if (p.shadow_changed) slot.drawn = null;
            slot.light = @intCast(i);
            slot.key = .{ .position = p.position, .radius = p.radius };
            self.slot_of[i] = @intCast(next);
            next += 1;
        }
        var any = false;
        for (&self.slots, 0..) |*slot, k| {
            if (k >= next) {
                slot.light = null;
                slot.draw = false;
                continue;
            }
            slot.draw = pointNeedsDraw(slot.drawn, slot.key);
            any = any or slot.draw;
        }
        self.graph.setPassEnabled(self.point_pass, any);
    }

    /// The pass of the point shadows: the 6 faces of each cube map to
    /// draw, each one in its own render pass.
    fn runPoints(self: *State, pass: *Pass) anyerror!void {
        const size = self.options.point_map_size;
        const near = self.options.point_near;
        for (&self.slots, 0..) |*slot, k| {
            if (!slot.draw) continue;
            const li = slot.light orelse continue;
            const far = slot.key.radius;
            for (0..6) |f| {
                const rp = try pass.encoder.beginRenderPass(.{
                    .color_attachments = &.{},
                    .depth_stencil_attachment = .{
                        .view = &slot.faces[f].?,
                        .depth_load_op = .clear,
                        .depth_store_op = .store,
                        .depth_clear_value = 1.0,
                        .stencil_read_only = true,
                    },
                    .timestamp_writes = if (self.graph.timer) |t| t.writes(face_names[k][f]) else null,
                });
                defer rp.end();
                var face_pass: Pass = .{
                    .graph = self.graph,
                    .gpu = pass.gpu,
                    .encoder = pass.encoder,
                    .render = rp,
                    .width = size,
                    .height = size,
                };
                var cp: CasterPass = .{
                    .pass = &face_pass,
                    .cascade = 0,
                    .view_proj = lighting_plan.pointFaceViewProj(slot.key.position, lighting_plan.pointNear(far, near), far, @intCast(f)),
                    .format = State.format,
                    .point = .{ .light = li, .slot = @intCast(k), .face = @intCast(f), .position = slot.key.position, .radius = far },
                };
                for (self.casters.items) |c| try c.run(c.user, &cp);
                self.faces_drawn += 1;
            }
            slot.drawn = slot.key;
            slot.draw = false;
        }
    }

    fn setPassesEnabled(self: *State) void {
        for (self.passes[0..self.built], 0..) |p, i| self.graph.setPassEnabled(p, self.settings.enabled and i < self.options.cascades);
    }

    fn mapSize(self: *const State) plan.Size {
        return .{ .fixed = .{ .width = self.options.map_size, .height = self.options.map_size } };
    }

    /// Add the target and the pass of cascade `built`.
    fn addCascade(self: *State) !void {
        const i = self.built;
        const target = try self.graph.addTarget(.{
            .name = target_names[i],
            .format = State.format,
            .size = self.mapSize(),
        });
        self.targets[i] = target;
        self.runners[i] = .{ .state = self, .index = i };
        try self.graph.addPass(.{
            .name = pass_names[i],
            .order = self.options.order + @as(i32, @intCast(i)),
            .attachments = .{ .depth = .{ .target = target } },
            .callback = .of(CascadeRunner, &self.runners[i], CascadeRunner.run),
        });
        self.passes[i] = self.graph.findPass(pass_names[i]).?;
        self.built += 1;
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
        if (options.point_shadows > lighting_plan.max_point_shadows) return error.TooManyPointShadows;
        if (options.point_map_size == 0) return error.BadMapSize;
        if (!(options.point_near > 0)) return error.BadNearPlane;
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
        var entries: [bind_count]gpu_mod.BindGroupLayoutEntry = undefined;
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
        // The cube maps of the point shadows (REQ-GPU-044). With the
        // cascades, the group has 8 depth textures: the WebGPU limit is 16.
        for (0..lighting_plan.max_point_shadows) |i| {
            entries[2 + lighting_plan.max_cascades + i] = .{
                .binding = lighting_plan.point_map_binding + @as(u32, @intCast(i)),
                .visibility = .{ .fragment = true },
                .texture = .{ .sample_type = .depth, .view_dimension = .cube },
            };
        }
        const group_layout = try gpu.createBindGroupLayout(.{ .label = "sw_lighting", .entries = &entries });
        const empty_cube = try gpu.createTexture(.{
            .label = "sw_point_shadow_empty",
            .size = .{ .width = 1, .height = 1, .depth_or_array_layers = 6 },
            .format = State.format,
            .usage = .{ .texture_binding = true },
        });
        errdefer empty_cube.destroy();
        const empty_view = try empty_cube.createView(.{ .dimension = .cube, .array_layer_count = 6 });

        state.* = .{
            .allocator = allocator,
            .graph = graph,
            .options = options,
            .settings = options.shadows,
            .buffer = buffer,
            .layout = group_layout,
            .sampler = sampler,
            .empty_cube = empty_cube,
            .empty_view = empty_view,
        };
        for (0..options.cascades) |_| try state.addCascade();
        state.setPassesEnabled();
        try graph.addPass(.{
            .name = point_pass_name,
            .order = options.order + lighting_plan.max_cascades,
            .callback = .of(State, state, State.runPoints),
        });
        state.point_pass = graph.findPass(point_pass_name).?;
        graph.setPassEnabled(state.point_pass, false);
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

    /// Add a shadow caster. Each cascade pass and each cube face calls
    /// it. The cube maps draw again.
    pub fn addCaster(self: *Lighting, caster: CasterCallback) !void {
        try self.state.casters.append(self.state.allocator, caster);
        self.state.invalidatePoints();
    }

    /// Remove each caster with the user pointer `user`. The cube maps draw
    /// again.
    pub fn removeCaster(self: *Lighting, user: ?*anyopaque) void {
        const list = &self.state.casters;
        var i: usize = 0;
        while (i < list.items.len) {
            if (list.items[i].user == user) {
                _ = list.orderedRemove(i);
            } else i += 1;
        }
        self.state.invalidatePoints();
    }

    /// Draw each point light cube map again at the next `update`, for
    /// example when the casters of the scene changed (REQ-GPU-044). For
    /// one light, set `PointLight.shadow_changed`.
    pub fn invalidatePointShadows(self: *Lighting) void {
        self.state.invalidatePoints();
    }

    /// Turn the point light shadows on or off (REQ-GPU-044). Off: no cube
    /// map draws, and each point light has no shadow. The sun shadows do
    /// not change.
    pub fn setPointShadowsEnabled(self: *Lighting, enabled: bool) void {
        self.state.point_shadows_on = enabled;
    }

    pub fn pointShadowsEnabled(self: *const Lighting) bool {
        return self.state.point_shadows_on;
    }

    /// Change the face size of the point light cube maps while the game
    /// runs. The lighting makes each cube map again at its next use.
    pub fn setPointShadowMap(self: *Lighting, map_size: u32) !void {
        if (map_size == 0) return error.BadMapSize;
        const s = self.state;
        if (map_size == s.options.point_map_size) return;
        s.options.point_map_size = map_size;
        for (&s.slots) |*slot| slot.release();
        if (s.bind_group) |g| g.release();
        s.bind_group = null;
    }

    /// The face size of the point light cube maps, in texels.
    pub fn pointMapSize(self: *const Lighting) u32 {
        return self.state.options.point_map_size;
    }

    /// The cube faces that the point shadow pass drew in the last
    /// `execute`: 6 for each cube map that drew. 0 when each light and its
    /// casters did not move.
    pub fn pointShadowFacesDrawn(self: *const Lighting) u32 {
        return self.state.faces_drawn;
    }

    /// The cube map of point light `i` of the last `update`, or null when
    /// the light has no shadow.
    pub fn pointShadowSlot(self: *const Lighting, i: usize) ?u32 {
        const s = self.state.slot_of[i];
        return if (s < 0) null else @intCast(s);
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

    /// Change the size of each shadow map and the cascade count while the
    /// game runs (REQ-GPU-043). The graph makes the new maps at the next
    /// `execute`. A new cascade gets a new target and pass. A cascade
    /// above the count keeps its pass, but the pass does not run. The
    /// bind group layout does not change, so each lit pipeline stays.
    pub fn setShadowMap(self: *Lighting, map_size: u32, cascade_count: u32) !void {
        const s = self.state;
        const change = try mapChange(s.built, cascade_count, map_size);
        s.options.map_size = map_size;
        s.options.cascades = cascade_count;
        for (s.targets[0..s.built]) |t| s.graph.setTargetSize(t, s.mapSize());
        for (0..change.add) |_| try s.addCascade();
        s.setPassesEnabled();
        // The maps of the unused bindings change with the count.
        if (s.bind_group) |g| g.release();
        s.bind_group = null;
    }

    /// The width and height of each shadow map, in texels.
    pub fn mapSize(self: *const Lighting) u32 {
        return self.state.options.map_size;
    }

    /// The number of cascades.
    pub fn cascadeCount(self: *const Lighting) u32 {
        return self.state.options.cascades;
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
    /// copies them. They stay until the next call. The first
    /// `Options.point_shadows` lights with `shadow = true` get a cube
    /// shadow map, in the order of the list (REQ-GPU-044).
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
        try s.updatePoints();
        lighting_plan.setPointShadows(&s.uniforms, s.settings, s.options.point_map_size, s.options.point_near, s.slot_of[0..s.point_count]);
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
            var entries: [bind_count]gpu_mod.BindGroupEntry = undefined;
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
            for (&s.slots, 0..) |*slot, i| {
                // A cube map with no texture gets the empty cube.
                const v = if (slot.cube) |*c| c else &s.empty_view;
                entries[2 + lighting_plan.max_cascades + i] = .{ .binding = lighting_plan.point_map_binding + @as(u32, @intCast(i)), .texture_view = v };
            }
            s.bind_group = try graph.gpu.createBindGroup(.{ .label = "sw_lighting", .layout = &s.layout, .entries = &entries });
            s.bound_generation = graph.generation;
        }
        const rp = pass.render orelse return error.NoRenderPass;
        rp.setBindGroup(group, s.bind_group.?);
    }
};

/// What `setShadowMap` adds to the graph (REQ-GPU-043).
pub const MapChange = struct {
    /// The number of new cascade targets and passes.
    add: u32,
};

/// Check a new map size and cascade count, and find the cascades to add.
/// `built` is the number of cascades that have a pass in the graph.
pub fn mapChange(built: u32, cascade_count: u32, map_size: u32) error{ BadCascadeCount, BadMapSize }!MapChange {
    if (cascade_count == 0 or cascade_count > lighting_plan.max_cascades) return error.BadCascadeCount;
    if (map_size == 0) return error.BadMapSize;
    return .{ .add = cascade_count -| built };
}

test "lighting: a cube map draws again only when its light moved (REQ-GPU-044)" {
    const lamp: PointKey = .{ .position = .{ 1, 2, 3 }, .radius = 6 };
    // No draw yet: draw it.
    try std.testing.expect(pointNeedsDraw(null, lamp));
    // The same light: no draw.
    try std.testing.expect(!pointNeedsDraw(lamp, lamp));
    // The light moved, or its radius changed: draw it.
    try std.testing.expect(pointNeedsDraw(lamp, .{ .position = .{ 1, 2.001, 3 }, .radius = 6 }));
    try std.testing.expect(pointNeedsDraw(lamp, .{ .position = .{ 1, 2, 3 }, .radius = 7 }));
    // Each face of each cube map has its own timer name.
    try std.testing.expectEqualStrings("sw_point_shadow_3_face_5", face_names[3][5]);
    try std.testing.expectEqual(@as(usize, 10), bind_count);
}

test "lighting: a new cascade count adds only the passes that are not in the graph (REQ-GPU-043)" {
    try std.testing.expectEqual(MapChange{ .add = 2 }, try mapChange(2, 4, 1024));
    try std.testing.expectEqual(MapChange{ .add = 0 }, try mapChange(3, 1, 4096));
    try std.testing.expectEqual(MapChange{ .add = 0 }, try mapChange(2, 2, 2048));
    try std.testing.expectError(error.BadCascadeCount, mapChange(2, 0, 1024));
    try std.testing.expectError(error.BadCascadeCount, mapChange(2, lighting_plan.max_cascades + 1, 1024));
    try std.testing.expectError(error.BadMapSize, mapChange(2, 2, 0));
}
