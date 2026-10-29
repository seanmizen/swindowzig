//! The cow scene: the turning cow on its stand, as frame graph passes
//! (REQ-DEMO-005). The cow demo shows it with captions, and another demo
//! (a menu) can use it as a live background.
//!
//! The scene adds its passes to a frame graph and a post chain that the
//! caller owns:
//!
//! ```zig
//! var graph = try sw_render.FrameGraph.init(allocator, gpu, .{});
//! var post = try sw_render.PostChain.init(allocator, &graph, .{});
//! var scene = try CowScene.init(allocator, &graph, &post, .{});
//! defer scene.deinit(); // before post.deinit and graph.deinit
//! // Each tick (fixed step):
//! scene.tick(1.0 / 60.0);
//! // Each frame:
//! const frame = try scene.frame(gpu.getSurfaceWidth(), gpu.getSurfaceHeight());
//! if (try graph.execute(frame)) gpu.present();
//! // Change a setting:
//! var s = scene.settings();
//! s.aa = .msaa;
//! try scene.apply(s);
//! ```
//!
//! The passes:
//!
//! - The shadow cascades of `sw_render.Lighting` (order -1000 up).
//! - The sky of `sw_render.Sky` on `post.hdr` (order -100), or the
//!   `cow_clear` pass with a plain colour when the sky is off.
//! - `cow_scene` (order 0): the ground, the pedestal, the cow and the
//!   wireframe on `post.hdr`.
//! - With MSAA: `cow_scene_msaa` draws the same into a multisampled layer
//!   with a clear background, and `cow_composite` (order 1) puts the
//!   resolved layer over the sky.
//!
//! A pass that the caller adds on `.screen` after the post chain (order
//! 2000 or more) draws on top of the finished frame: a caption or a menu.
//!
//! The scene reads no clock. The turn angle moves only in `tick`, so one
//! sequence of ticks and settings gives the same frames (REQ-DEMO-004).

const std = @import("std");
const gpu_mod = @import("sw_gpu");
const sw_math = @import("sw_math");
const sw_render = @import("sw_render");
const voxel_mesh = @import("voxel_mesh.zig");
const cow_model = @import("cow_model.zig");
const reflect = @import("reflect.zig");

const Mat4 = sw_math.Mat4;
const Vec3 = sw_math.Vec3;
const FrameGraph = sw_render.FrameGraph;
const Pass = sw_render.Pass;
const PassId = sw_render.PassId;

pub const AntiAliasing = enum { off, fxaa, msaa };

/// The settings that a demo script changes one at a time.
pub const Settings = struct {
    aa: AntiAliasing = .fxaa,
    meshing: voxel_mesh.Mode = .greedy,
    /// Draw the edges of each quad over the model.
    wireframe: bool = false,
    tonemap: sw_render.TonemapCurve = .aces,
    exposure: f32 = 1.0,
    palette: cow_model.PaletteId = .classic,
    /// The time of day: 0 midnight, 0.25 sunrise, 0.5 noon, 0.75 sunset.
    time: f32 = 0.4,
    shadows: bool = true,
    ao: bool = true,
    fog: bool = true,
    sky: bool = true,
    /// The turn speed of the cow, in radians each second.
    spin: f32 = 0.5,
};

pub const Options = struct {
    settings: Settings = .{},
    msaa_samples: u32 = 4,
    fxaa_quality: gpu_mod.FxaaQuality = .medium,
    shadow_map_size: u32 = 2048,
    shadow_cascades: u32 = 2,
};

pub const Stats = struct {
    /// The quads of the pedestal and of the turning model (not the ground).
    quads: u32 = 0,
    triangles: u32 = 0,
    vertices: u32 = 0,
};

/// The per-draw uniforms: `CowDraw` in the WGSL.
const DrawUniforms = extern struct {
    model: [16]f32,
    view_proj: [16]f32,
    /// rgb: the direct light. w: the occlusion strength (0: off).
    light_color: [4]f32,
    /// rgb: the ambient light.
    ambient: [4]f32,
    /// rgb: the wireframe colour. w: the clip depth offset of the lines.
    wire: [4]f32,
    palette: [cow_model.palette_size][4]f32,
};

const draw_body =
    \\struct CowDraw {
    \\    model: mat4x4<f32>,
    \\    view_proj: mat4x4<f32>,
    \\    light_color: vec4<f32>,
    \\    ambient: vec4<f32>,
    \\    wire: vec4<f32>,
    \\    palette: array<vec4<f32>, 16>,
    \\}
    \\@group(1) @binding(0) var<uniform> cow: CowDraw;
    \\
    \\struct CowOut {
    \\    @builtin(position) pos: vec4<f32>,
    \\    @location(0) world: vec3<f32>,
    \\    @location(1) normal: vec3<f32>,
    \\    @location(2) ao: f32,
    \\    @location(3) @interpolate(flat) color: u32,
    \\}
    \\
    \\@vertex fn vs_main(
    \\    @location(0) pos: vec3<f32>,
    \\    @location(1) normal: vec3<f32>,
    \\    @location(2) ao: f32,
    \\    @location(3) color: u32,
    \\) -> CowOut {
    \\    let world = cow.model * vec4<f32>(pos, 1.0);
    \\    var out: CowOut;
    \\    out.pos = cow.view_proj * world;
    \\    // The lines of the wireframe move a little toward the camera.
    \\    out.pos.z -= cow.wire.w * out.pos.w;
    \\    out.world = world.xyz;
    \\    out.normal = (cow.model * vec4<f32>(normal, 0.0)).xyz;
    \\    out.ao = ao;
    \\    out.color = color;
    \\    return out;
    \\}
    \\
;

const lit_shader = sw_render.lighting.shader(2, draw_body ++
    \\@fragment fn fs_main(in: CowOut) -> @location(0) vec4<f32> {
    \\    let n = normalize(in.normal);
    \\    let albedo = cow.palette[in.color].rgb;
    \\    let shadow = sw_shadow(in.world, n);
    \\    let d = max(dot(n, sw_light_dir()), 0.0);
    \\    let occ = mix(1.0, 0.3 + 0.7 * in.ao, cow.light_color.w);
    \\    let direct = cow.light_color.rgb * (d * shadow * mix(1.0, occ, 0.5));
    \\    var c = albedo * (cow.ambient.rgb * occ + direct);
    \\    c = sw_fog(c, in.world);
    \\    return vec4<f32>(c, 1.0);
    \\}
    \\
    \\@fragment fn fs_wire(in: CowOut) -> @location(0) vec4<f32> {
    \\    return vec4<f32>(cow.wire.rgb, 1.0);
    \\}
    \\
);

/// The shadow casts use the vertex stage only.
const shadow_shader = sw_render.wgsl.shader(draw_body);

const composite_shader =
    \\@group(0) @binding(0) var cow_layer: texture_2d<f32>;
    \\
    \\@vertex fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4<f32> {
    \\    let uv = vec2<f32>(f32((i << 1u) & 2u), f32(i & 2u));
    \\    return vec4<f32>(uv * 2.0 - 1.0, 0.0, 1.0);
    \\}
    \\
    \\@fragment fn fs_main(@builtin(position) p: vec4<f32>) -> @location(0) vec4<f32> {
    \\    return textureLoad(cow_layer, vec2<i32>(p.xy), 0);
    \\}
    \\
;

const vertex_buffers = [_]gpu_mod.VertexBufferLayout{.{
    .array_stride = @sizeOf(voxel_mesh.Vertex),
    .attributes = &[_]gpu_mod.VertexAttribute{
        .{ .format = .float32x3, .offset = @offsetOf(voxel_mesh.Vertex, "pos"), .shader_location = 0 },
        .{ .format = .float32x3, .offset = @offsetOf(voxel_mesh.Vertex, "normal"), .shader_location = 1 },
        .{ .format = .float32, .offset = @offsetOf(voxel_mesh.Vertex, "ao"), .shader_location = 2 },
        .{ .format = .uint32, .offset = @offsetOf(voxel_mesh.Vertex, "color"), .shader_location = 3 },
    },
}};

/// One mesh in GPU buffers.
const GpuMesh = struct {
    vertices: gpu_mod.Buffer,
    triangles: gpu_mod.Buffer,
    lines: gpu_mod.Buffer,
    vertex_count: u32,
    triangle_count: u32,
    line_count: u32,
    quads: u32,

    fn upload(gpu: *gpu_mod.GPU, mesh: voxel_mesh.Mesh) !GpuMesh {
        const v = std.mem.sliceAsBytes(mesh.vertices.items);
        const t = std.mem.sliceAsBytes(mesh.triangles.items);
        const l = std.mem.sliceAsBytes(mesh.lines.items);
        const vb = try gpu.createBuffer(.{ .label = "cow_vertices", .size = v.len, .usage = .{ .vertex = true, .copy_dst = true } });
        errdefer vb.destroy();
        const tb = try gpu.createBuffer(.{ .label = "cow_triangles", .size = t.len, .usage = .{ .index = true, .copy_dst = true } });
        errdefer tb.destroy();
        const lb = try gpu.createBuffer(.{ .label = "cow_lines", .size = l.len, .usage = .{ .index = true, .copy_dst = true } });
        gpu.writeBuffer(vb, 0, v);
        gpu.writeBuffer(tb, 0, t);
        gpu.writeBuffer(lb, 0, l);
        return .{
            .vertices = vb,
            .triangles = tb,
            .lines = lb,
            .vertex_count = @intCast(mesh.vertices.items.len),
            .triangle_count = @intCast(mesh.triangles.items.len),
            .line_count = @intCast(mesh.lines.items.len),
            .quads = mesh.quads,
        };
    }

    fn deinit(self: *GpuMesh) void {
        self.vertices.destroy();
        self.triangles.destroy();
        self.lines.destroy();
        self.* = undefined;
    }
};

/// Where the camera is. The cow turns, the camera stays.
const eye: [3]f32 = .{ 2.5, 1.55, 3.1 };
const look_at: [3]f32 = .{ 0, 1.0, 0 };
const fov_y: f32 = 40.0 * std.math.pi / 180.0;
const fog: sw_render.Fog = .{ .start = 4, .end = 40, .max = 0.9 };
const studio_color: gpu_mod.Color = .{ .r = 0.16, .g = 0.17, .b = 0.2, .a = 1 };
const wire_color: [3]f32 = .{ 1.6, 1.2, 0.2 };
const ground_half: f32 = 40;

/// The state behind `CowScene`. It has a stable address: the passes and
/// the shadow caster keep a pointer to it.
const State = struct {
    allocator: std.mem.Allocator,
    graph: *FrameGraph,
    post: *sw_render.PostChain,
    options: Options,
    current: Settings,
    sky: sw_render.Sky,
    lighting: sw_render.Lighting,
    draw_layout: gpu_mod.BindGroupLayout,
    draw_group: gpu_mod.BindGroup,
    /// [0]: one sample. [1]: `Options.msaa_samples`.
    lit: [2]gpu_mod.RenderPipeline,
    wire: [2]gpu_mod.RenderPipeline,
    shadow: gpu_mod.RenderPipeline,
    composite: gpu_mod.RenderPipeline,
    composite_layout: gpu_mod.BindGroupLayout,
    composite_group: ?gpu_mod.BindGroup = null,
    composite_generation: u32 = 0,
    layer: sw_render.TargetId,
    turning_grid: voxel_mesh.Grid,
    pedestal_grid: voxel_mesh.Grid,
    turning: ?GpuMesh = null,
    pedestal: ?GpuMesh = null,
    ground: GpuMesh,
    meshed: ?struct { mode: voxel_mesh.Mode, ao: bool } = null,
    clear_pass: PassId,
    scene_pass: PassId,
    msaa_pass: PassId,
    composite_pass: PassId,
    /// The turn angle of the cow, in radians.
    angle: f32 = 0,
    /// The scene time in seconds: the sum of the tick steps.
    time: f32 = 0,
    palette: cow_model.Palette,
    light_color: [3]f32 = .{ 1, 1, 1 },
    ambient: [3]f32 = .{ 0.3, 0.3, 0.3 },
    /// The view projection of the current frame.
    frame_view_proj: [16]f32 = sw_render.wgsl.identity,

    fn turningModel(self: *const State) Mat4 {
        return Mat4.translation(0, cow_model.pedestal_top, 0).mul(Mat4.rotationY(self.angle));
    }

    fn uniforms(self: *const State, model: Mat4, view_proj: [16]f32, wire_offset: f32) DrawUniforms {
        var u: DrawUniforms = .{
            .model = model.data,
            .view_proj = view_proj,
            .light_color = .{ self.light_color[0], self.light_color[1], self.light_color[2], if (self.current.ao) 1 else 0 },
            .ambient = .{ self.ambient[0], self.ambient[1], self.ambient[2], 0 },
            .wire = .{ wire_color[0], wire_color[1], wire_color[2], wire_offset },
            .palette = undefined,
        };
        for (self.palette, 0..) |c, i| u.palette[i] = .{ c[0], c[1], c[2], 1 };
        return u;
    }

    /// Draw `mesh` with `pipeline`: the triangles, or the lines.
    fn drawMesh(self: *State, pass: *Pass, mesh: *const GpuMesh, model: Mat4, view_proj: [16]f32, lines: bool) !void {
        const rp = pass.render.?;
        const offset = try pass.push(self.uniforms(model, view_proj, if (lines) 0.0004 else 0));
        rp.setBindGroupWithOffsets(1, self.draw_group, &.{offset});
        rp.setVertexBuffer(0, mesh.vertices, 0, @as(u64, mesh.vertex_count) * @sizeOf(voxel_mesh.Vertex));
        if (lines) {
            rp.setIndexBuffer(mesh.lines, .uint32, 0, @as(u64, mesh.line_count) * 4);
            rp.drawIndexed(mesh.line_count, 1, 0, 0, 0);
        } else {
            rp.setIndexBuffer(mesh.triangles, .uint32, 0, @as(u64, mesh.triangle_count) * 4);
            rp.drawIndexed(mesh.triangle_count, 1, 0, 0, 0);
        }
    }

    fn drawScene(self: *State, pass: *Pass, variant: usize) !void {
        const rp = pass.render orelse return error.NoRenderPass;
        const view_proj = self.frame_view_proj;
        rp.setPipeline(self.lit[variant]);
        pass.bindFrame();
        try self.lighting.bind(pass, 2);
        try self.drawMesh(pass, &self.ground, Mat4.identity(), view_proj, false);
        try self.drawMesh(pass, &self.pedestal.?, Mat4.identity(), view_proj, false);
        try self.drawMesh(pass, &self.turning.?, self.turningModel(), view_proj, false);
        if (self.current.wireframe) {
            rp.setPipeline(self.wire[variant]);
            pass.bindFrame();
            try self.lighting.bind(pass, 2);
            try self.drawMesh(pass, &self.pedestal.?, Mat4.identity(), view_proj, true);
            try self.drawMesh(pass, &self.turning.?, self.turningModel(), view_proj, true);
        }
    }

    fn runScene(self: *State, pass: *Pass) anyerror!void {
        try self.drawScene(pass, 0);
    }

    fn runMsaa(self: *State, pass: *Pass) anyerror!void {
        try self.drawScene(pass, 1);
    }

    fn runClear(_: *State, _: *Pass) anyerror!void {}

    fn runComposite(self: *State, pass: *Pass) anyerror!void {
        const rp = pass.render.?;
        const graph = pass.graph;
        if (self.composite_group == null or self.composite_generation != graph.generation) {
            if (self.composite_group) |g| g.release();
            self.composite_group = null;
            self.composite_group = try pass.gpu.createBindGroup(.{
                .layout = &self.composite_layout,
                .entries = &.{.{ .binding = 0, .texture_view = pass.view(self.layer) }},
            });
            self.composite_generation = graph.generation;
        }
        rp.setPipeline(self.composite);
        rp.setBindGroup(0, self.composite_group.?);
        rp.draw(3, 1, 0, 0);
    }

    fn drawShadow(self: *State, cp: *sw_render.ShadowCasterPass) anyerror!void {
        const rp = cp.pass.render orelse return;
        rp.setPipeline(self.shadow);
        cp.pass.bindFrame();
        try self.drawMesh(cp.pass, &self.pedestal.?, Mat4.identity(), cp.view_proj.data, false);
        try self.drawMesh(cp.pass, &self.turning.?, self.turningModel(), cp.view_proj.data, false);
    }

    /// Mesh the models again when the meshing mode or the occlusion changed.
    fn remesh(self: *State) !void {
        const want = .{ .mode = self.current.meshing, .ao = self.current.ao };
        if (self.meshed) |m| {
            if (m.mode == want.mode and m.ao == want.ao) return;
        }
        const gpu = self.graph.gpu;
        var t = try voxel_mesh.build(self.allocator, self.turning_grid, .{
            .mode = want.mode,
            .ao = want.ao,
            .scale = cow_model.voxel_size,
            .origin = cow_model.turning_origin,
        });
        defer t.deinit(self.allocator);
        var p = try voxel_mesh.build(self.allocator, self.pedestal_grid, .{
            .mode = want.mode,
            .ao = want.ao,
            .scale = cow_model.voxel_size,
            .origin = cow_model.pedestal_origin,
        });
        defer p.deinit(self.allocator);
        var new_t = try GpuMesh.upload(gpu, t);
        errdefer new_t.deinit();
        const new_p = try GpuMesh.upload(gpu, p);
        if (self.turning) |*m| m.deinit();
        if (self.pedestal) |*m| m.deinit();
        self.turning = new_t;
        self.pedestal = new_p;
        self.meshed = .{ .mode = want.mode, .ao = want.ao };
    }

    /// The light colours from the sky state.
    fn updateLight(self: *State) void {
        const s = self.sky.state();
        const day = s.daylight;
        const tw = s.twilight;
        const sun = [3]f32{ 1.0, 0.92 - 0.3 * tw, 0.82 - 0.5 * tw };
        const moon = [3]f32{ 0.10, 0.12, 0.20 };
        const z = s.zenith;
        const h = s.horizon;
        for (0..3) |i| {
            self.light_color[i] = sun[i] * (2.4 * day) + moon[i] * (1 - day);
            self.ambient[i] = 0.3 * z[i] + 0.2 * h[i] + 0.02;
        }
    }
};

pub const CowScene = struct {
    state: *State,

    /// Add the passes of the scene to `graph` and `post`. Both must stay at
    /// their addresses while the scene exists.
    pub fn init(allocator: std.mem.Allocator, graph: *FrameGraph, post: *sw_render.PostChain, options: Options) !CowScene {
        const gpu = graph.gpu;
        const s = try allocator.create(State);
        errdefer allocator.destroy(s);

        var sky = try sw_render.Sky.init(allocator, graph, post.hdr, .{ .time = options.settings.time, .fog = fog });
        errdefer sky.deinit();
        var lighting = try sw_render.Lighting.init(allocator, graph, .{
            .cascades = options.shadow_cascades,
            .map_size = options.shadow_map_size,
            .shadows = .{ .distance = 12, .caster_distance = 12 },
        });
        errdefer lighting.deinit();

        var draw_layout = try gpu.createBindGroupLayout(.{
            .label = "cow_draw",
            .entries = &[_]gpu_mod.BindGroupLayoutEntry{
                sw_render.UniformRing.layoutEntry(0, .{ .vertex = true, .fragment = true }, @sizeOf(DrawUniforms)),
            },
        });
        const draw_group = try gpu.createBindGroup(.{
            .label = "cow_draw",
            .layout = &draw_layout,
            .entries = &[_]gpu_mod.BindGroupEntry{graph.ring.bindGroupEntry(0, @sizeOf(DrawUniforms))},
        });

        var lit_layout = try gpu.createPipelineLayout(.{
            .label = "cow_lit",
            .bind_group_layouts = &[_]*gpu_mod.BindGroupLayout{ &graph.frame_layout, &draw_layout, lighting.layout() },
        });
        var lit_module = try gpu.createShaderModule(.{ .label = "cow_lit", .code = lit_shader });
        const fmt = post.hdr_format;
        var lit: [2]gpu_mod.RenderPipeline = undefined;
        var wire: [2]gpu_mod.RenderPipeline = undefined;
        for (0..2) |i| {
            const samples: u32 = if (i == 0) 1 else options.msaa_samples;
            lit[i] = try gpu.createRenderPipeline(.{
                .label = "cow_lit",
                .layout = &lit_layout,
                .vertex = .{ .module = &lit_module, .entry_point = "vs_main", .buffers = &vertex_buffers },
                .fragment = .{ .module = &lit_module, .entry_point = "fs_main", .targets = &[_]gpu_mod.ColorTargetState{.{ .format = fmt }} },
                .primitive = .{ .topology = .triangle_list, .cull_mode = .back },
                .depth_stencil = .{ .format = .depth24plus, .depth_write_enabled = true, .depth_compare = .less },
                .multisample = .{ .count = samples },
            });
            wire[i] = try gpu.createRenderPipeline(.{
                .label = "cow_wire",
                .layout = &lit_layout,
                .vertex = .{ .module = &lit_module, .entry_point = "vs_main", .buffers = &vertex_buffers },
                .fragment = .{ .module = &lit_module, .entry_point = "fs_wire", .targets = &[_]gpu_mod.ColorTargetState{.{ .format = fmt }} },
                .primitive = .{ .topology = .line_list, .cull_mode = .none },
                .depth_stencil = .{ .format = .depth24plus, .depth_write_enabled = false, .depth_compare = .less_equal },
                .multisample = .{ .count = samples },
            });
        }

        var shadow_layout = try gpu.createPipelineLayout(.{
            .label = "cow_shadow",
            .bind_group_layouts = &[_]*gpu_mod.BindGroupLayout{ &graph.frame_layout, &draw_layout },
        });
        var shadow_module = try gpu.createShaderModule(.{ .label = "cow_shadow", .code = shadow_shader });
        const shadow = try gpu.createRenderPipeline(.{
            .label = "cow_shadow",
            .layout = &shadow_layout,
            .vertex = .{ .module = &shadow_module, .entry_point = "vs_main", .buffers = &vertex_buffers },
            .primitive = .{ .topology = .triangle_list, .cull_mode = .none },
            .depth_stencil = .{ .format = sw_render.Lighting.format, .depth_write_enabled = true, .depth_compare = .less },
            .multisample = .{ .count = 1 },
        });

        var composite_layout = try gpu.createBindGroupLayout(.{
            .label = "cow_composite",
            .entries = &[_]gpu_mod.BindGroupLayoutEntry{
                .{ .binding = 0, .visibility = .{ .fragment = true }, .texture = .{ .sample_type = .float } },
            },
        });
        var composite_pl = try gpu.createPipelineLayout(.{
            .label = "cow_composite",
            .bind_group_layouts = &[_]*gpu_mod.BindGroupLayout{&composite_layout},
        });
        var composite_module = try gpu.createShaderModule(.{ .label = "cow_composite", .code = composite_shader });
        const over: @FieldType(gpu_mod.BlendState, "color") = .{ .operation = .add, .src_factor = .one, .dst_factor = .one_minus_src_alpha };
        const composite = try gpu.createRenderPipeline(.{
            .label = "cow_composite",
            .layout = &composite_pl,
            .vertex = .{ .module = &composite_module, .entry_point = "vs_main" },
            .fragment = .{ .module = &composite_module, .entry_point = "fs_main", .targets = &[_]gpu_mod.ColorTargetState{.{
                .format = fmt,
                .blend = .{ .color = over, .alpha = over },
            }} },
            .primitive = .{ .topology = .triangle_list, .cull_mode = .none },
            .multisample = .{ .count = 1 },
        });

        // The targets and the passes.
        const depth = try graph.addTarget(.{ .name = "cow_depth", .format = .depth24plus, .usage = .{ .render_attachment = true } });
        const msaa_color = try graph.addTarget(.{ .name = "cow_msaa", .format = fmt, .sample_count = options.msaa_samples, .usage = .{ .render_attachment = true } });
        const msaa_depth = try graph.addTarget(.{ .name = "cow_msaa_depth", .format = .depth24plus, .sample_count = options.msaa_samples, .usage = .{ .render_attachment = true } });
        const layer = try graph.addTarget(.{ .name = "cow_layer", .format = fmt });

        var turning_grid = try cow_model.turning(allocator);
        errdefer turning_grid.deinit(allocator);
        var pedestal_grid = try cow_model.pedestal(allocator);
        errdefer pedestal_grid.deinit(allocator);
        var ground_mesh: voxel_mesh.Mesh = .{};
        defer ground_mesh.deinit(allocator);
        const g = ground_half;
        try ground_mesh.addQuad(allocator, .{ .{ -g, 0, g }, .{ g, 0, g }, .{ g, 0, -g }, .{ -g, 0, -g } }, @splat(3), .{ 0, 1, 0 }, cow_model.Color.ground);

        s.* = .{
            .allocator = allocator,
            .graph = graph,
            .post = post,
            .options = options,
            .current = options.settings,
            .sky = sky,
            .lighting = lighting,
            .draw_layout = draw_layout,
            .draw_group = draw_group,
            .lit = lit,
            .wire = wire,
            .shadow = shadow,
            .composite = composite,
            .composite_layout = composite_layout,
            .layer = layer,
            .turning_grid = turning_grid,
            .pedestal_grid = pedestal_grid,
            .ground = try GpuMesh.upload(gpu, ground_mesh),
            .clear_pass = undefined,
            .scene_pass = undefined,
            .msaa_pass = undefined,
            .composite_pass = undefined,
            .palette = cow_model.palette(options.settings.palette),
        };

        try graph.addPass(.{
            .name = "cow_clear",
            .order = -99,
            .attachments = .{ .colors = &.{.{ .target = post.hdr, .load_op = .clear, .clear_value = studio_color }} },
            .callback = .of(State, s, State.runClear),
        });
        try graph.addPass(.{
            .name = "cow_scene",
            .order = 0,
            .attachments = .{
                .colors = &.{.{ .target = post.hdr, .load_op = .load }},
                .depth = .{ .target = depth },
            },
            .callback = .of(State, s, State.runScene),
        });
        try graph.addPass(.{
            .name = "cow_scene_msaa",
            .order = 0,
            .attachments = .{
                .colors = &.{.{ .target = msaa_color, .resolve = layer, .load_op = .clear, .store_op = .discard, .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 0 } }},
                .depth = .{ .target = msaa_depth, .store_op = .discard },
            },
            .callback = .of(State, s, State.runMsaa),
        });
        try graph.addPass(.{
            .name = "cow_composite",
            .order = 1,
            .attachments = .{ .colors = &.{.{ .target = post.hdr, .load_op = .load }} },
            .callback = .of(State, s, State.runComposite),
        });
        s.clear_pass = graph.findPass("cow_clear").?;
        s.scene_pass = graph.findPass("cow_scene").?;
        s.msaa_pass = graph.findPass("cow_scene_msaa").?;
        s.composite_pass = graph.findPass("cow_composite").?;
        try s.lighting.addCaster(.of(State, s, State.drawShadow));

        var self: CowScene = .{ .state = s };
        try self.applyAll(options.settings, true);
        return self;
    }

    /// Release the scene. Call it before the `deinit` of the post chain
    /// and of the graph. The graph keeps the passes, but they do not run.
    pub fn deinit(self: *CowScene) void {
        const s = self.state;
        for ([_]PassId{ s.clear_pass, s.scene_pass, s.msaa_pass, s.composite_pass }) |p| s.graph.setPassEnabled(p, false);
        s.lighting.removeCaster(s);
        if (s.turning) |*m| m.deinit();
        if (s.pedestal) |*m| m.deinit();
        s.ground.deinit();
        if (s.composite_group) |g| g.release();
        s.draw_group.release();
        s.turning_grid.deinit(s.allocator);
        s.pedestal_grid.deinit(s.allocator);
        s.lighting.deinit();
        s.sky.deinit();
        s.allocator.destroy(s);
        self.* = undefined;
    }

    /// The current settings.
    pub fn settings(self: *const CowScene) Settings {
        return self.state.current;
    }

    /// Change the settings. Only the parts that changed do work: a new
    /// meshing mode or occlusion makes the meshes again.
    pub fn apply(self: *CowScene, new: Settings) !void {
        try self.applyAll(new, false);
    }

    fn applyAll(self: *CowScene, new: Settings, first: bool) !void {
        const s = self.state;
        const old = s.current;
        s.current = new;
        const g = s.graph;
        if (first or old.aa != new.aa) {
            try s.post.setFxaa(if (new.aa == .fxaa) s.options.fxaa_quality else null);
            const msaa = new.aa == .msaa;
            g.setPassEnabled(s.scene_pass, !msaa);
            g.setPassEnabled(s.msaa_pass, msaa);
            g.setPassEnabled(s.composite_pass, msaa);
        }
        s.post.setTonemap(.{ .curve = new.tonemap, .exposure = new.exposure });
        s.lighting.setShadowsEnabled(new.shadows);
        s.sky.setEnabled(new.sky);
        g.setPassEnabled(s.clear_pass, !new.sky);
        s.sky.fog = if (new.fog) fog else null;
        s.sky.setTime(new.time);
        s.palette = cow_model.palette(new.palette);
        try s.remesh();
    }

    /// Change one setting by its name and a text value, as a demo script
    /// does: `set aa msaa`, `set exposure 1.5`, `set shadows off`.
    pub fn set(self: *CowScene, name: []const u8, value: []const u8) !void {
        var n = self.state.current;
        try reflect.setField(Settings, &n, name, value);
        try self.apply(n);
    }

    /// One fixed step of `dt` seconds: the cow turns.
    pub fn tick(self: *CowScene, dt: f32) void {
        const s = self.state;
        s.time += dt;
        s.angle = @mod(s.angle + s.current.spin * dt, std.math.tau);
    }

    /// Set the turn angle (radians), for a fixed pose.
    pub fn setAngle(self: *CowScene, angle: f32) void {
        self.state.angle = angle;
    }

    /// Make the frame uniforms for a surface of `width` by `height`
    /// pixels, and update the sky and the shadow cascades. Call it one time
    /// each frame, before `FrameGraph.execute`.
    pub fn frame(self: *CowScene, width: u32, height: u32) !sw_render.FrameUniforms {
        const s = self.state;
        const w: f32 = @floatFromInt(@max(width, 1));
        const h: f32 = @floatFromInt(@max(height, 1));
        const proj = sw_math.perspective(fov_y, w / h, 0.1, 200.0);
        const view = sw_math.lookAt(
            .{ .x = eye[0], .y = eye[1], .z = eye[2] },
            .{ .x = look_at[0], .y = look_at[1], .z = look_at[2] },
            .{ .x = 0, .y = 1, .z = 0 },
        );
        var f: sw_render.FrameUniforms = .{
            .view = view.data,
            .proj = proj.data,
            .view_proj = proj.mul(view).data,
            .camera_pos = .{ eye[0], eye[1], eye[2], 1 },
            .time = s.time,
        };
        f.sky = try s.sky.update();
        s.frame_view_proj = f.view_proj;
        s.updateLight();
        try s.lighting.update(f);
        return f;
    }

    pub fn stats(self: *const CowScene) Stats {
        const s = self.state;
        var out: Stats = .{};
        for ([_]?GpuMesh{ s.turning, s.pedestal }) |m| {
            if (m) |mesh| {
                out.quads += mesh.quads;
                out.triangles += mesh.triangle_count / 3;
                out.vertices += mesh.vertex_count;
            }
        }
        return out;
    }
};
