// The renderer of the shooter demo (REQ-DEMO-020): the snowy arena, the
// bots, the guns and the effects, as frame graph passes.
//
// The engine features, each from `sw_render`:
//
// - The sky and the fog (`Sky`), with a winter morning light.
// - The shadows (`Lighting`): the arena, the guns and the bots cast them.
//   The muzzle flashes are point lights.
// - The bots: one box model (`BoxModels`, body_model.zig) for all bodies.
// - A cloud layer (`Clouds`) and falling snow (`Precipitation`). A height
//   map of the arena stops the snow on the ground and on the cover.
// - The particles (`Particles`): the muzzle flashes, the impacts and the
//   snow that a bullet or a running bot throws up (impact_fx.zig).
//
// The passes of this file:
//
// - `shooter_world` (order 0): the arena and the guns of the bots, from
//   the gun models of guns.bin (a triangle mesh with the lit shader), and
//   the box models of the bots.
// - `shooter_view` (order 90): the gun in the hands of the player, after
//   the snow and the particles, with its own depth.
//
// The scene reads no clock. The caller gives the time of each frame from
// the tick count (REQ-DEMO-004).
const std = @import("std");
const gpu_mod = @import("sw_gpu");
const sw_math = @import("sw_math");
const sw_render = @import("sw_render");
const vec = @import("vec.zig");
const mesh_mod = @import("mesh.zig");
const arena = @import("arena.zig");
const weapon = @import("weapon.zig");
const npc = @import("npc.zig");
const body_model = @import("body_model.zig");
const game_mod = @import("game.zig");
const fx = @import("impact_fx.zig");
const V3 = vec.V3;
const v3 = vec.v3;
const Mat4 = vec.Mat4;
const Pass = sw_render.Pass;

/// The settings that a script changes one at a time.
pub const Settings = struct {
    /// The time of day: 0.25 sunrise, 0.5 noon.
    time: f32 = 0.37,
    snow: bool = true,
    clouds: bool = true,
    fog: bool = true,
    shadows: bool = true,
    exposure: f32 = 0.8,
};

pub const Options = struct {
    shadow_map_size: u32 = 2048,
    shadow_cascades: u32 = 2,
    fxaa_quality: gpu_mod.FxaaQuality = .medium,
};

const fog: sw_render.Fog = .{ .start = 6, .end = 70, .max = 0.85 };
const fov_y: f32 = 70.0 * std.math.pi / 180.0;
const view_fov_y: f32 = 54.0 * std.math.pi / 180.0;
const max_dyn_vertices = 96 * 1024;
const particle_capacity = 2048;

/// The per-draw uniforms: `ShDraw` in the WGSL.
const DrawUniforms = extern struct {
    view_proj: [16]f32,
    /// rgb: the direct light.
    light: [4]f32,
    /// rgb: the ambient light.
    ambient: [4]f32,
};

const draw_body =
    \\struct ShDraw {
    \\    view_proj: mat4x4<f32>,
    \\    light: vec4<f32>,
    \\    ambient: vec4<f32>,
    \\}
    \\@group(1) @binding(0) var<uniform> sh: ShDraw;
    \\
    \\struct ShOut {
    \\    @builtin(position) pos: vec4<f32>,
    \\    @location(0) world: vec3<f32>,
    \\    @location(1) normal: vec3<f32>,
    \\    @location(2) color: vec3<f32>,
    \\    @location(3) @interpolate(flat) mat: f32,
    \\}
    \\
    \\@vertex fn vs_main(
    \\    @location(0) pos: vec3<f32>,
    \\    @location(1) normal: vec3<f32>,
    \\    @location(2) color: vec3<f32>,
    \\    @location(3) mat: f32,
    \\) -> ShOut {
    \\    var out: ShOut;
    \\    out.pos = sh.view_proj * vec4<f32>(pos, 1.0);
    \\    out.world = pos;
    \\    out.normal = normal;
    \\    out.color = color;
    \\    out.mat = mat;
    \\    return out;
    \\}
    \\
;

const lit_shader = sw_render.lighting.shader(2, draw_body ++
    \\@fragment fn fs_main(in: ShOut) -> @location(0) vec4<f32> {
    \\    // Material 4 glows: it takes no light.
    \\    if (in.mat > 3.5 && in.mat < 4.5) {
    \\        return vec4<f32>(in.color * 7.0, 1.0);
    \\    }
    \\    let n = normalize(in.normal);
    \\    let shadow = sw_shadow(in.world, n);
    \\    let d = max(dot(n, sw_light_dir()), 0.0);
    \\    // More sky light from above, and the snow lights the faces below.
    \\    let hemi = 0.8 + 0.2 * n.y;
    \\    var c = in.color * (sh.ambient.rgb * hemi + sh.light.rgb * (d * shadow) + sw_point_lights(in.world, n));
    \\    c = sw_fog(c, in.world);
    \\    return vec4<f32>(c, 1.0);
    \\}
    \\
);

const shadow_shader = sw_render.wgsl.shader(draw_body);

const vertex_buffers = [_]gpu_mod.VertexBufferLayout{.{
    .array_stride = @sizeOf(mesh_mod.Vertex),
    .attributes = &[_]gpu_mod.VertexAttribute{
        .{ .format = .float32x3, .offset = @offsetOf(mesh_mod.Vertex, "pos"), .shader_location = 0 },
        .{ .format = .float32x3, .offset = @offsetOf(mesh_mod.Vertex, "nrm"), .shader_location = 1 },
        .{ .format = .float32x3, .offset = @offsetOf(mesh_mod.Vertex, "col"), .shader_location = 2 },
        .{ .format = .float32, .offset = @offsetOf(mesh_mod.Vertex, "mat"), .shader_location = 3 },
    },
}};

/// The camera of one frame.
pub const Camera = struct {
    eye: V3,
    yaw: f32,
    pitch: f32,
    roll: f32 = 0,
    /// The camera follows a bot: no gun in the hands.
    follow: bool = false,
};

pub const Stats = struct {
    world_vertices: u32 = 0,
    dynamic_vertices: u32 = 0,
    bots: u32 = 0,
    particles: u32 = 0,
};

const shape_size = 64;

const State = struct {
    allocator: std.mem.Allocator,
    graph: *sw_render.FrameGraph,
    post: *sw_render.PostChain,
    options: Options,
    current: Settings,
    sky: sw_render.Sky,
    lighting: sw_render.Lighting,
    clouds: sw_render.Clouds,
    snow: sw_render.Precipitation,
    models: sw_render.BoxModels,
    bot_model: sw_render.BoxModelId,
    particles: sw_render.Particles,
    soft: gpu_mod.Texture,
    soft_view: gpu_mod.TextureView,
    draw_layout: gpu_mod.BindGroupLayout,
    draw_group: gpu_mod.BindGroup,
    lit: gpu_mod.RenderPipeline,
    shadow: gpu_mod.RenderPipeline,
    world_buffer: gpu_mod.Buffer,
    world_count: u32,
    dyn_buffer: gpu_mod.Buffer,
    dyn: mesh_mod.Mesh,
    /// The vertices of `dyn` in the world (the bot guns). The rest is the
    /// gun in the hands.
    dyn_world: u32 = 0,
    dyn_count: u32 = 0,
    shape_pixels: [shape_size * shape_size * 4]u8 = undefined,
    world_pass: sw_render.PassId = undefined,
    view_pass: sw_render.PassId = undefined,
    frame_view_proj: [16]f32 = sw_render.wgsl.identity,
    gun_view_proj: [16]f32 = sw_render.wgsl.identity,
    light: [3]f32 = .{ 1, 1, 1 },
    ambient: [3]f32 = .{ 0.3, 0.3, 0.3 },
    posed: [game_mod.max_bots]body_model.Posed = undefined,
    stats: Stats = .{},

    fn uniforms(self: *const State, view_proj: [16]f32) DrawUniforms {
        return .{
            .view_proj = view_proj,
            .light = .{ self.light[0], self.light[1], self.light[2], 0 },
            .ambient = .{ self.ambient[0], self.ambient[1], self.ambient[2], 0 },
        };
    }

    fn drawRange(self: *State, pass: *Pass, buffer: gpu_mod.Buffer, first: u32, count: u32, view_proj: [16]f32) !void {
        if (count == 0) return;
        const rp = pass.render.?;
        const offset = try pass.push(self.uniforms(view_proj));
        rp.setBindGroupWithOffsets(1, self.draw_group, &.{offset});
        rp.setVertexBuffer(0, buffer, 0, @as(u64, first + count) * @sizeOf(mesh_mod.Vertex));
        rp.draw(count, 1, first, 0);
    }

    fn runWorld(self: *State, pass: *Pass) anyerror!void {
        const rp = pass.render orelse return error.NoRenderPass;
        rp.setPipeline(self.lit);
        pass.bindFrame();
        try self.lighting.bind(pass, 2);
        try self.drawRange(pass, self.world_buffer, 0, self.world_count, self.frame_view_proj);
        try self.drawRange(pass, self.dyn_buffer, 0, self.dyn_world, self.frame_view_proj);
        try self.models.draw(pass, .world, .{});
    }

    fn runView(self: *State, pass: *Pass) anyerror!void {
        const rp = pass.render orelse return error.NoRenderPass;
        rp.setPipeline(self.lit);
        pass.bindFrame();
        try self.lighting.bind(pass, 2);
        try self.drawRange(pass, self.dyn_buffer, self.dyn_world, self.dyn_count - self.dyn_world, self.gun_view_proj);
    }

    fn drawShadow(self: *State, cp: *sw_render.ShadowCasterPass) anyerror!void {
        const rp = cp.pass.render orelse return;
        rp.setPipeline(self.shadow);
        cp.pass.bindFrame();
        try self.drawRange(cp.pass, self.world_buffer, 0, self.world_count, cp.view_proj.data);
        try self.drawRange(cp.pass, self.dyn_buffer, 0, self.dyn_world, cp.view_proj.data);
    }

    /// The light colours from the sky state.
    fn updateLight(self: *State) void {
        const s = self.sky.state();
        const day = s.daylight;
        const tw = s.twilight;
        const sun = [3]f32{ 1.0, 0.9 - 0.3 * tw, 0.8 - 0.5 * tw };
        const moon = [3]f32{ 0.10, 0.12, 0.20 };
        for (0..3) |i| {
            self.light[i] = sun[i] * (3.0 * day) + moon[i] * (1 - day);
            self.ambient[i] = 0.2 * s.zenith[i] + 0.16 * s.horizon[i] + 0.03;
        }
        self.models.setLight(.{ .color = self.light, .ambient = self.ambient });
    }

    fn makeShape(self: *State) void {
        for (0..shape_size) |y| {
            for (0..shape_size) |x| {
                const fx_: f32 = @floatFromInt(x);
                const fy: f32 = @floatFromInt(y);
                const n = 0.65 * valueNoise(fx_ / 6, fy / 6, shape_size / 6) + 0.35 * valueNoise(fx_ / 3, fy / 3, shape_size / 3);
                const i = (y * shape_size + x) * 4;
                const grey: u8 = @intFromFloat(205 + 40 * noiseHash(@intCast(x + 7), @intCast(y + 3)));
                self.shape_pixels[i..][0..4].* = .{ grey, grey, grey, if (n > 0.5) 255 else 0 };
            }
        }
    }
};

fn noiseHash(x: i32, y: i32) f32 {
    var h: u32 = @as(u32, @bitCast(x)) *% 374761393 +% @as(u32, @bitCast(y)) *% 668265263;
    h = (h ^ (h >> 13)) *% 1274126177;
    h ^= h >> 16;
    return @as(f32, @floatFromInt(h & 0xffff)) / 65535.0;
}

/// A value noise that repeats every `period` texels.
fn valueNoise(x: f32, y: f32, period: i32) f32 {
    const x0: i32 = @intFromFloat(@floor(x));
    const y0: i32 = @intFromFloat(@floor(y));
    const fx_ = x - @floor(x);
    const fy = y - @floor(y);
    const sx = fx_ * fx_ * (3 - 2 * fx_);
    const sy = fy * fy * (3 - 2 * fy);
    const a = noiseHash(@mod(x0, period), @mod(y0, period));
    const b = noiseHash(@mod(x0 + 1, period), @mod(y0, period));
    const c = noiseHash(@mod(x0, period), @mod(y0 + 1, period));
    const d = noiseHash(@mod(x0 + 1, period), @mod(y0 + 1, period));
    return (a * (1 - sx) + b * sx) * (1 - sy) + (c * (1 - sx) + d * sx) * sy;
}

/// The static triangles of the arena: each box, with a snow cap on top.
fn buildWorld(out: *mesh_mod.Mesh) void {
    for (arena.boxes[0..arena.box_count]) |b| {
        out.box(b.min, b.max, b.color, 0);
        if (b.kind != .ground) {
            // The snow cap: a little larger than the top, and not solid.
            const lip: f32 = if (b.kind == .wall) 0 else 0.03;
            out.box(v3(b.min[0] - lip, b.max[1], b.min[2] - lip), v3(b.max[0] + lip, b.max[1] + 0.06, b.max[2] + lip), arena.snow_color, 0);
        }
    }
    // Drifts of snow along the foot of the outer wall.
    const h = arena.half;
    for ([_][2]V3{
        .{ v3(-h, 0, -h), v3(h, 0.25, -h + 0.9) },
        .{ v3(-h, 0, h - 0.9), v3(h, 0.25, h) },
        .{ v3(-h, 0, -h), v3(-h + 0.9, 0.25, h) },
        .{ v3(h - 0.9, 0, -h), v3(h, 0.25, h) },
    }) |d| out.box(d[0], d[1], arena.snow_color, 0);
}

pub const Scene = struct {
    state: *State,

    pub fn init(allocator: std.mem.Allocator, graph: *sw_render.FrameGraph, post: *sw_render.PostChain, options: Options) !Scene {
        const gpu = graph.gpu;
        const s = try allocator.create(State);
        errdefer allocator.destroy(s);

        var sky = try sw_render.Sky.init(allocator, graph, post.hdr, .{ .time = 0.37, .fog = fog });
        errdefer sky.deinit();
        var lighting = try sw_render.Lighting.init(allocator, graph, .{
            .cascades = options.shadow_cascades,
            .map_size = options.shadow_map_size,
            .shadows = .{ .distance = 45, .caster_distance = 60 },
        });
        errdefer lighting.deinit();

        const depth = try graph.addTarget(.{ .name = "shooter_depth", .format = .depth24plus, .usage = .{ .render_attachment = true, .texture_binding = true } });
        const view_depth = try graph.addTarget(.{ .name = "shooter_view_depth", .format = .depth24plus, .usage = .{ .render_attachment = true } });

        var draw_layout = try gpu.createBindGroupLayout(.{
            .label = "shooter_draw",
            .entries = &[_]gpu_mod.BindGroupLayoutEntry{
                sw_render.UniformRing.layoutEntry(0, .{ .vertex = true, .fragment = true }, @sizeOf(DrawUniforms)),
            },
        });
        const draw_group = try gpu.createBindGroup(.{
            .label = "shooter_draw",
            .layout = &draw_layout,
            .entries = &[_]gpu_mod.BindGroupEntry{graph.ring.bindGroupEntry(0, @sizeOf(DrawUniforms))},
        });
        var lit_layout = try gpu.createPipelineLayout(.{
            .label = "shooter_lit",
            .bind_group_layouts = &[_]*gpu_mod.BindGroupLayout{ &graph.frame_layout, &draw_layout, lighting.layout() },
        });
        var lit_module = try gpu.createShaderModule(.{ .label = "shooter_lit", .code = lit_shader });
        const lit = try gpu.createRenderPipeline(.{
            .label = "shooter_lit",
            .layout = &lit_layout,
            .vertex = .{ .module = &lit_module, .entry_point = "vs_main", .buffers = &vertex_buffers },
            .fragment = .{ .module = &lit_module, .entry_point = "fs_main", .targets = &[_]gpu_mod.ColorTargetState{.{ .format = post.hdr_format }} },
            // The gun models have faces of both windings.
            .primitive = .{ .topology = .triangle_list, .cull_mode = .none },
            .depth_stencil = .{ .format = .depth24plus, .depth_write_enabled = true, .depth_compare = .less },
            .multisample = .{ .count = 1 },
        });
        var shadow_layout = try gpu.createPipelineLayout(.{
            .label = "shooter_shadow",
            .bind_group_layouts = &[_]*gpu_mod.BindGroupLayout{ &graph.frame_layout, &draw_layout },
        });
        var shadow_module = try gpu.createShaderModule(.{ .label = "shooter_shadow", .code = shadow_shader });
        const shadow = try gpu.createRenderPipeline(.{
            .label = "shooter_shadow",
            .layout = &shadow_layout,
            .vertex = .{ .module = &shadow_module, .entry_point = "vs_main", .buffers = &vertex_buffers },
            .primitive = .{ .topology = .triangle_list, .cull_mode = .none },
            .depth_stencil = .{ .format = sw_render.Lighting.format, .depth_write_enabled = true, .depth_compare = .less },
            .multisample = .{ .count = 1 },
        });

        // The static arena.
        var world = mesh_mod.Mesh.init(allocator);
        defer world.verts.deinit(allocator);
        buildWorld(&world);
        const wbytes = std.mem.sliceAsBytes(world.verts.items);
        const world_buffer = try gpu.createBuffer(.{ .label = "shooter_world", .size = wbytes.len, .usage = .{ .vertex = true, .copy_dst = true } });
        gpu.writeBuffer(world_buffer, 0, wbytes);
        const dyn_buffer = try gpu.createBuffer(.{ .label = "shooter_dynamic", .size = max_dyn_vertices * @sizeOf(mesh_mod.Vertex), .usage = .{ .vertex = true, .copy_dst = true } });

        // The bots.
        var models = try sw_render.BoxModels.init(allocator, graph, .{ .color_format = post.hdr_format, .lighting = lighting });
        errdefer models.deinit();
        const bot_model = try models.addModel(.{ .parts = &body_model.parts });

        // A soft round sprite for the particles.
        const soft_size = 32;
        const soft = try gpu.createTexture(.{
            .label = "shooter_soft",
            .size = .{ .width = soft_size, .height = soft_size },
            .format = .rgba8unorm,
            .usage = .{ .texture_binding = true, .copy_dst = true },
        });
        var px: [soft_size * soft_size * 4]u8 = undefined;
        for (0..soft_size) |y| {
            for (0..soft_size) |x| {
                const dx = (@as(f32, @floatFromInt(x)) + 0.5) / (soft_size / 2) - 1;
                const dy = (@as(f32, @floatFromInt(y)) + 0.5) / (soft_size / 2) - 1;
                const r = @sqrt(dx * dx + dy * dy);
                const a = std.math.clamp(1 - r, 0, 1);
                const i = (y * soft_size + x) * 4;
                px[i..][0..4].* = .{ 255, 255, 255, @intFromFloat(255 * a * a * (3 - 2 * a)) };
            }
        }
        gpu.writeTexture(soft, &px, soft_size * 4, soft_size, .{ .width = soft_size, .height = soft_size });
        const soft_view = try soft.createView(.{ .dimension = .@"2d" });

        s.* = .{
            .allocator = allocator,
            .graph = graph,
            .post = post,
            .options = options,
            .current = .{},
            .sky = sky,
            .lighting = lighting,
            .clouds = undefined,
            .snow = undefined,
            .models = models,
            .bot_model = bot_model,
            .particles = undefined,
            .soft = soft,
            .soft_view = soft_view,
            .draw_layout = draw_layout,
            .draw_group = draw_group,
            .lit = lit,
            .shadow = shadow,
            .world_buffer = world_buffer,
            .world_count = @intCast(world.verts.items.len),
            .dyn_buffer = dyn_buffer,
            .dyn = mesh_mod.Mesh.init(allocator),
        };
        try s.dyn.verts.ensureTotalCapacity(allocator, max_dyn_vertices);
        s.particles = try sw_render.Particles.init(allocator, graph, .{ .color_format = post.hdr_format, .capacity = particle_capacity, .texture = &s.soft_view });
        try s.particles.addPass(.{ .color = post.hdr, .depth = depth });
        s.makeShape();
        s.clouds = try sw_render.Clouds.init(allocator, graph, post.hdr, .{
            .depth = depth,
            .shape = .{ .width = shape_size, .height = shape_size, .pixels = &s.shape_pixels },
            .settings = .{ .bottom = 70, .thickness = 5, .cell_size = 9, .wind = .{ 2.0, 0.6 }, .color = .{ 0.92, 0.93, 0.96 }, .opacity = 0.9, .fade_start = 160, .fade_end = 320 },
        });
        var snow_settings = sw_render.PrecipitationSettings.snow();
        snow_settings.count = 9000;
        snow_settings.radius = 22;
        snow_settings.size = 0.04;
        s.snow = try sw_render.Precipitation.init(allocator, graph, post.hdr, .{ .depth = depth, .settings = snow_settings });
        try s.snow.setHeightMap(.{
            .origin = .{ arena.map_origin, arena.map_origin },
            .cell_size = arena.map_cell,
            .width = arena.map_cells,
            .depth = arena.map_cells,
            .heights = &arena.heights,
        });

        try graph.addPass(.{
            .name = "shooter_world",
            .order = 0,
            .attachments = .{
                .colors = &.{.{ .target = post.hdr, .load_op = .load }},
                .depth = .{ .target = depth },
            },
            .callback = .of(State, s, State.runWorld),
        });
        try graph.addPass(.{
            .name = "shooter_view",
            .order = 90,
            .attachments = .{
                .colors = &.{.{ .target = post.hdr, .load_op = .load }},
                .depth = .{ .target = view_depth },
            },
            .callback = .of(State, s, State.runView),
        });
        s.world_pass = graph.findPass("shooter_world").?;
        s.view_pass = graph.findPass("shooter_view").?;
        try s.lighting.addCaster(.of(State, s, State.drawShadow));
        var self: Scene = .{ .state = s };
        try self.apply(.{});
        try post.setFxaa(options.fxaa_quality);
        return self;
    }

    pub fn deinit(self: *Scene) void {
        const s = self.state;
        s.graph.setPassEnabled(s.world_pass, false);
        s.graph.setPassEnabled(s.view_pass, false);
        s.lighting.removeCaster(s);
        s.snow.deinit();
        s.clouds.deinit();
        s.particles.deinit();
        s.soft_view.release();
        s.soft.destroy();
        s.models.deinit();
        s.world_buffer.destroy();
        s.dyn_buffer.destroy();
        s.dyn.verts.deinit(s.allocator);
        s.draw_group.release();
        s.lighting.deinit();
        s.sky.deinit();
        s.allocator.destroy(s);
        self.* = undefined;
    }

    pub fn settings(self: *const Scene) Settings {
        return self.state.current;
    }

    pub fn apply(self: *Scene, new: Settings) !void {
        const s = self.state;
        s.current = new;
        s.sky.setTime(new.time);
        s.sky.fog = if (new.fog) fog else null;
        s.lighting.setShadowsEnabled(new.shadows);
        s.clouds.setEnabled(new.clouds);
        s.snow.setEnabled(new.snow);
        s.post.setTonemap(.{ .curve = .aces, .exposure = new.exposure });
    }

    /// The colour of the light on the dust of the particles.
    pub fn dustLight(self: *const Scene) V3 {
        const s = self.state;
        return v3(
            std.math.clamp(s.ambient[0] * 1.6 + s.light[0] * 0.35, 0, 1.4),
            std.math.clamp(s.ambient[1] * 1.6 + s.light[1] * 0.35, 0, 1.4),
            std.math.clamp(s.ambient[2] * 1.6 + s.light[2] * 0.35, 0, 1.4),
        );
    }

    /// Build the frame: the camera, the bots, the guns, the lights, the
    /// particles. Call it one time each frame before `FrameGraph.execute`.
    /// `seconds` is the tick time.
    pub fn frame(self: *Scene, width: u32, height: u32, cam: Camera, g: *const game_mod.Game, particles: *const fx.System, seconds: f64) !sw_render.FrameUniforms {
        const s = self.state;
        const w: f32 = @floatFromInt(@max(width, 1));
        const h: f32 = @floatFromInt(@max(height, 1));
        const fwd = vec.forward(cam.yaw, cam.pitch);
        const right0 = vec.norm(vec.cross(fwd, v3(0, 1, 0)));
        const up0 = vec.cross(right0, fwd);
        // The lean rolls the camera about the view axis.
        const right = right0 * vec.s(@cos(cam.roll)) - up0 * vec.s(@sin(cam.roll));
        const up = vec.cross(right, fwd);
        const e = cam.eye;
        const at = e + fwd;
        const proj = sw_math.perspective(fov_y, w / h, 0.05, 400.0);
        const view = sw_math.lookAt(.{ .x = e[0], .y = e[1], .z = e[2] }, .{ .x = at[0], .y = at[1], .z = at[2] }, .{ .x = up[0], .y = up[1], .z = up[2] });
        var f: sw_render.FrameUniforms = .{
            .view = view.data,
            .proj = proj.data,
            .view_proj = proj.mul(view).data,
            .camera_pos = .{ e[0], e[1], e[2], 1 },
            .time = @floatCast(seconds),
        };
        f.sky = try s.sky.update();
        s.frame_view_proj = f.view_proj;
        s.gun_view_proj = sw_math.perspective(view_fov_y, w / h, 0.01, 10.0).mul(view).data;
        s.updateLight();

        // The bots and their guns.
        s.models.clear();
        s.dyn.clear();
        var lights: [game_mod.max_bots + 1]sw_render.PointLight = undefined;
        var light_n: usize = 0;
        var bots: u32 = 0;
        for (g.bots[0..g.bot_n], 0..) |*b, i| {
            const sk = b.skeleton();
            s.posed[i] = body_model.pose(sk);
            const hurt = b.hurt;
            try s.models.add(.world, s.bot_model, .{
                .transform = s.posed[i].transform,
                .rotations = &s.posed[i].rotations,
                .tint = .{ 1 + 14 * hurt, 1, 1 },
            });
            bots += 1;
            if (b.alive()) {
                weapon.addModel(&s.dyn, b.gun, b.gunMatrix(sk), Mat4.identity(), 0);
                if (b.flash > 0 and light_n < lights.len) {
                    const m = b.muzzle(sk);
                    lights[light_n] = .{ .position = .{ m[0], m[1], m[2] }, .color = .{ 1.0, 0.7, 0.35 }, .intensity = 3, .radius = 7 };
                    light_n += 1;
                }
            }
        }
        s.dyn_world = @intCast(s.dyn.verts.items.len);

        // The gun in the hands, in the world space of the camera.
        if (g.alive() and !cam.follow) {
            const cam_world: Mat4 = .{ .data = .{
                right[0], right[1], right[2], 0,
                up[0],    up[1],    up[2],    0,
                -fwd[0],  -fwd[1],  -fwd[2],  0,
                e[0],     e[1],     e[2],     1,
            } };
            const sp = @sqrt(g.you.vel[0] * g.you.vel[0] + g.you.vel[2] * g.you.vel[2]) / 6.4;
            const p = g.hands.pose(g.item, g.you.stride * 2.2, @min(sp, 1.2));
            weapon.addModel(&s.dyn, g.item.model, cam_world.mul(p.gun), p.mag, 0);
            if (g.hands.flash > 0 and light_n < lights.len) {
                const m = vec.xform(cam_world.mul(p.gun), p.muzzle);
                lights[light_n] = .{ .position = .{ m[0], m[1], m[2] }, .color = .{ 1.0, 0.7, 0.35 }, .intensity = 3, .radius = 7 };
                light_n += 1;
            }
        }
        if (s.dyn.verts.items.len > max_dyn_vertices) s.dyn.verts.shrinkRetainingCapacity(max_dyn_vertices);
        s.dyn_count = @intCast(s.dyn.verts.items.len);
        s.dyn_world = @min(s.dyn_world, s.dyn_count);
        if (s.dyn_count > 0) try s.graph.uploads.write(s.dyn_buffer, 0, std.mem.sliceAsBytes(s.dyn.verts.items));
        try s.lighting.setPointLights(lights[0..light_n]);
        try s.lighting.update(f);

        const input: sw_render.WeatherInput = .{ .camera = .{ e[0], e[1], e[2] }, .seconds = seconds, .light = sw_render.weather.skyLight(s.sky.state()) };
        try s.clouds.update(input);
        try s.snow.update(input);
        try s.particles.update(particles, sw_render.ParticleCamera.fromView(f.view, .{ e[0], e[1], e[2] }));
        s.stats = .{
            .world_vertices = s.world_count,
            .dynamic_vertices = s.dyn_count,
            .bots = bots,
            .particles = @intCast(particles.count()),
        };
        return f;
    }

    pub fn stats(self: *const Scene) Stats {
        return self.state.stats;
    }

    pub fn modelStats(self: *const Scene) sw_render.BoxModelStats {
        return self.state.models.stats();
    }

    /// Project a world point to the screen, in pixels, or null behind the
    /// camera.
    pub fn project(self: *const Scene, p: V3, width: u32, height: u32) ?[2]f32 {
        const m = self.state.frame_view_proj;
        const x = m[0] * p[0] + m[4] * p[1] + m[8] * p[2] + m[12];
        const y = m[1] * p[0] + m[5] * p[1] + m[9] * p[2] + m[13];
        const wc = m[3] * p[0] + m[7] * p[1] + m[11] * p[2] + m[15];
        if (wc < 0.05) return null;
        const w: f32 = @floatFromInt(width);
        const h: f32 = @floatFromInt(height);
        return .{ (x / wc * 0.5 + 0.5) * w, (0.5 - y / wc * 0.5) * h };
    }
};
