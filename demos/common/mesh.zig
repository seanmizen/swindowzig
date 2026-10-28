//! A triangle mesh renderer on the sw_render frame graph. The demos draw
//! the cow, the arena and the guns with it.
//!
//! Each mesh is a static vertex buffer. Each frame, the game calls
//! `clear`, then `add` for each draw, and the scene pass calls `draw`. The
//! world layer receives the shadows and the point lights of
//! `sw_render.Lighting`, casts shadows, and fades into the fog. The
//! first-person layer is in view space, in its own pass with its own depth
//! target, so a held gun is always in front of the world. A line mesh
//! draws a wireframe with no light.
//!
//! The pipelines take the MSAA sample count of the colour target, so the
//! cow demo can show MSAA (REQ-GPU-040).
const std = @import("std");
const gpu_mod = @import("sw_gpu");
const sw_math = @import("sw_math");
const sw_render = @import("sw_render");

const Mat4 = sw_math.Mat4;

pub const Vertex = extern struct {
    pos: [3]f32,
    normal: [3]f32,
    color: [3]f32,
    /// The ambient occlusion of the vertex, 0 to 1. 1: no occlusion.
    ao: f32 = 1,
};

pub const Kind = enum { triangles, lines };
pub const Layer = enum { world, first_person };
pub const MeshId = enum(u32) { _ };

/// One draw of a mesh.
pub const Draw = struct {
    mesh: MeshId,
    model: Mat4 = Mat4.identity(),
    tint: [3]f32 = .{ 1, 1, 1 },
    /// Multiply the colour by the vertex AO.
    ao: bool = true,
    /// The mesh casts a shadow (world layer only).
    cast_shadow: bool = true,
};

pub const Options = struct {
    color_format: gpu_mod.TextureFormat = .rgba16float,
    depth_format: gpu_mod.TextureFormat = .depth24plus,
    /// The MSAA sample count of the colour and depth targets.
    sample_count: u32 = 1,
    lighting: sw_render.Lighting,
};

/// The per-draw uniforms, with the layout of `DemoDraw` in the WGSL.
const DrawUniforms = extern struct {
    model: [16]f32,
    view_proj: [16]f32,
    /// rgb: the sun light. w: 1 when the vertex AO is on.
    light_color: [4]f32,
    /// rgb: the ambient light. w: 1 for a view-space draw.
    ambient: [4]f32,
    /// rgb: the tint. w: 1 for a draw with no light.
    tint: [4]f32,
    /// x: 1 with fog. y: 1 with the shadows and the point lights.
    flags: [4]f32,
};

const common_wgsl =
    \\struct DemoDraw {
    \\    model: mat4x4<f32>,
    \\    view_proj: mat4x4<f32>,
    \\    light_color: vec4<f32>,
    \\    ambient: vec4<f32>,
    \\    tint: vec4<f32>,
    \\    flags: vec4<f32>,
    \\}
    \\@group(1) @binding(0) var<uniform> demo_draw: DemoDraw;
    \\
    \\struct DemoOut {
    \\    @builtin(position) pos: vec4<f32>,
    \\    @location(0) world: vec3<f32>,
    \\    @location(1) normal: vec3<f32>,
    \\    @location(2) color: vec3<f32>,
    \\}
    \\
    \\@vertex fn vs_main(@location(0) pos: vec3<f32>, @location(1) normal: vec3<f32>, @location(2) color: vec3<f32>, @location(3) ao: f32) -> DemoOut {
    \\    var out: DemoOut;
    \\    let w = demo_draw.model * vec4<f32>(pos, 1.0);
    \\    out.pos = demo_draw.view_proj * w;
    \\    out.world = w.xyz;
    \\    out.normal = (demo_draw.model * vec4<f32>(normal, 0.0)).xyz;
    \\    let occlusion = mix(1.0, ao, demo_draw.light_color.w);
    \\    out.color = color * demo_draw.tint.rgb * occlusion;
    \\    return out;
    \\}
    \\
;

const lit_wgsl = sw_render.lighting.shader(2, common_wgsl ++
    \\@fragment fn fs_main(in: DemoOut) -> @location(0) vec4<f32> {
    \\    if (demo_draw.tint.w > 0.5) {
    \\        return vec4<f32>(in.color, 1.0);
    \\    }
    \\    let n = normalize(in.normal);
    \\    var l = sw_light_dir();
    \\    var shadow = 1.0;
    \\    var points = vec3<f32>(0.0);
    \\    if (demo_draw.ambient.w > 0.5) {
    \\        l = (sw_frame.view * vec4<f32>(l, 0.0)).xyz;
    \\    }
    \\    if (demo_draw.flags.y > 0.5) {
    \\        shadow = sw_shadow(in.world, n);
    \\        points = sw_point_lights(in.world, n);
    \\    }
    \\    let d = max(dot(n, l), 0.0);
    \\    var c = in.color * (demo_draw.ambient.rgb + demo_draw.light_color.rgb * (d * shadow) + points);
    \\    if (demo_draw.flags.x > 0.5) {
    \\        c = sw_fog(c, in.world);
    \\    }
    \\    return vec4<f32>(c, 1.0);
    \\}
    \\
);

const unlit_wgsl = sw_render.wgsl.shader(common_wgsl ++
    \\@fragment fn fs_main(in: DemoOut) -> @location(0) vec4<f32> {
    \\    return vec4<f32>(in.color, 1.0);
    \\}
    \\
);

const vertex_buffers = [_]gpu_mod.VertexBufferLayout{.{
    .array_stride = @sizeOf(Vertex),
    .attributes = &[_]gpu_mod.VertexAttribute{
        .{ .format = .float32x3, .offset = @offsetOf(Vertex, "pos"), .shader_location = 0 },
        .{ .format = .float32x3, .offset = @offsetOf(Vertex, "normal"), .shader_location = 1 },
        .{ .format = .float32x3, .offset = @offsetOf(Vertex, "color"), .shader_location = 2 },
        .{ .format = .float32, .offset = @offsetOf(Vertex, "ao"), .shader_location = 3 },
    },
}};

const Mesh = struct {
    buffer: gpu_mod.Buffer,
    count: u32,
    kind: Kind,
};

const Item = struct { layer: Layer, draw: Draw };

const State = struct {
    allocator: std.mem.Allocator,
    graph: *sw_render.FrameGraph,
    options: Options,
    lighting: sw_render.Lighting,
    lit: gpu_mod.RenderPipeline,
    lines: gpu_mod.RenderPipeline,
    shadow: gpu_mod.RenderPipeline,
    layout: gpu_mod.BindGroupLayout,
    bind_group: gpu_mod.BindGroup,
    meshes: std.ArrayList(Mesh) = .empty,
    items: std.ArrayList(Item) = .empty,
    light: sw_render.WeatherLight = .{},
    fog: bool = true,
    /// The view and projection of the frame, for the first-person layer.
    proj: [16]f32 = sw_render.wgsl.identity,
    view_proj: [16]f32 = sw_render.wgsl.identity,
    /// The quads and the draw calls of the last world draw.
    draw_calls: u32 = 0,
    first_person_pass: ?sw_render.PassId = null,

    fn uniforms(self: *const State, d: Draw, kind: Kind, view_proj: [16]f32, view_space: bool, world: bool) DrawUniforms {
        const unlit = kind == .lines;
        return .{
            .model = d.model.data,
            .view_proj = view_proj,
            .light_color = .{ self.light.sun[0], self.light.sun[1], self.light.sun[2], if (d.ao) 1 else 0 },
            .ambient = .{ self.light.ambient[0], self.light.ambient[1], self.light.ambient[2], if (view_space) 1 else 0 },
            .tint = .{ d.tint[0], d.tint[1], d.tint[2], if (unlit) 1 else 0 },
            .flags = .{ if (world and self.fog) 1 else 0, if (world) 1 else 0, 0, 0 },
        };
    }

    fn drawLayer(self: *State, pass: *sw_render.Pass, layer: Layer) !void {
        const rp = pass.render orelse return error.NoRenderPass;
        const view_space = layer == .first_person;
        const vp = if (view_space) self.proj else self.view_proj;
        var bound: ?Kind = null;
        var calls: u32 = 0;
        for (self.items.items) |it| {
            if (it.layer != layer) continue;
            const m = self.meshes.items[@backingInt(it.draw.mesh)];
            if (m.count == 0) continue;
            if (bound != m.kind) {
                rp.setPipeline(if (m.kind == .lines) self.lines else self.lit);
                pass.bindFrame();
                if (m.kind == .triangles) try self.lighting.bind(pass, 2);
                bound = m.kind;
            }
            const offset = try pass.push(self.uniforms(it.draw, m.kind, vp, view_space, !view_space));
            rp.setBindGroupWithOffsets(1, self.bind_group, &.{offset});
            rp.setVertexBuffer(0, m.buffer, 0, @as(u64, m.count) * @sizeOf(Vertex));
            rp.draw(m.count, 1, 0, 0);
            calls += 1;
        }
        if (layer == .world) self.draw_calls = calls;
    }

    fn drawShadow(self: *State, cp: *sw_render.ShadowCasterPass) anyerror!void {
        const rp = cp.pass.render orelse return error.NoRenderPass;
        var bound = false;
        for (self.items.items) |it| {
            if (it.layer != .world or !it.draw.cast_shadow) continue;
            const m = self.meshes.items[@backingInt(it.draw.mesh)];
            if (m.kind != .triangles or m.count == 0) continue;
            if (!bound) {
                rp.setPipeline(self.shadow);
                cp.pass.bindFrame();
                bound = true;
            }
            const offset = try cp.pass.push(self.uniforms(it.draw, m.kind, cp.view_proj.data, false, false));
            rp.setBindGroupWithOffsets(1, self.bind_group, &.{offset});
            rp.setVertexBuffer(0, m.buffer, 0, @as(u64, m.count) * @sizeOf(Vertex));
            rp.draw(m.count, 1, 0, 0);
        }
    }

    fn runFirstPerson(self: *State, pass: *sw_render.Pass) anyerror!void {
        try self.drawLayer(pass, .first_person);
    }
};

pub const Renderer = struct {
    state: *State,

    pub fn init(allocator: std.mem.Allocator, graph: *sw_render.FrameGraph, options: Options) !Renderer {
        const gpu = graph.gpu;
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        var layout = try gpu.createBindGroupLayout(.{
            .label = "demo_mesh",
            .entries = &[_]gpu_mod.BindGroupLayoutEntry{
                sw_render.UniformRing.layoutEntry(0, .{ .vertex = true, .fragment = true }, @sizeOf(DrawUniforms)),
            },
        });
        const bind_group = try gpu.createBindGroup(.{
            .label = "demo_mesh",
            .layout = &layout,
            .entries = &[_]gpu_mod.BindGroupEntry{graph.ring.bindGroupEntry(0, @sizeOf(DrawUniforms))},
        });
        var lighting = options.lighting;
        var lit_layout = try gpu.createPipelineLayout(.{
            .label = "demo_mesh_lit",
            .bind_group_layouts = &[_]*gpu_mod.BindGroupLayout{ &graph.frame_layout, &layout, lighting.layout() },
        });
        var plain_layout = try gpu.createPipelineLayout(.{
            .label = "demo_mesh_plain",
            .bind_group_layouts = &[_]*gpu_mod.BindGroupLayout{ &graph.frame_layout, &layout },
        });
        var lit_module = try gpu.createShaderModule(.{ .label = "demo_mesh_lit", .code = lit_wgsl });
        var unlit_module = try gpu.createShaderModule(.{ .label = "demo_mesh_unlit", .code = unlit_wgsl });
        const ms: gpu_mod.MultisampleState = .{ .count = options.sample_count };
        const lit = try gpu.createRenderPipeline(.{
            .label = "demo_mesh_lit",
            .layout = &lit_layout,
            .vertex = .{ .module = &lit_module, .entry_point = "vs_main", .buffers = &vertex_buffers },
            .fragment = .{
                .module = &lit_module,
                .entry_point = "fs_main",
                .targets = &[_]gpu_mod.ColorTargetState{.{ .format = options.color_format }},
            },
            .primitive = .{ .topology = .triangle_list, .cull_mode = .back },
            .depth_stencil = .{ .format = options.depth_format, .depth_write_enabled = true, .depth_compare = .less },
            .multisample = ms,
        });
        const lines = try gpu.createRenderPipeline(.{
            .label = "demo_mesh_lines",
            .layout = &plain_layout,
            .vertex = .{ .module = &unlit_module, .entry_point = "vs_main", .buffers = &vertex_buffers },
            .fragment = .{
                .module = &unlit_module,
                .entry_point = "fs_main",
                .targets = &[_]gpu_mod.ColorTargetState{.{ .format = options.color_format }},
            },
            .primitive = .{ .topology = .line_list, .cull_mode = .none },
            .depth_stencil = .{ .format = options.depth_format, .depth_write_enabled = false, .depth_compare = .less_equal },
            .multisample = ms,
        });
        const shadow = try gpu.createRenderPipeline(.{
            .label = "demo_mesh_shadow",
            .layout = &plain_layout,
            .vertex = .{ .module = &unlit_module, .entry_point = "vs_main", .buffers = &vertex_buffers },
            .primitive = .{ .topology = .triangle_list, .cull_mode = .none },
            .depth_stencil = .{ .format = sw_render.Lighting.format, .depth_write_enabled = true, .depth_compare = .less },
            .multisample = .{ .count = 1 },
        });
        state.* = .{
            .allocator = allocator,
            .graph = graph,
            .options = options,
            .lighting = lighting,
            .lit = lit,
            .lines = lines,
            .shadow = shadow,
            .layout = layout,
            .bind_group = bind_group,
        };
        try lighting.addCaster(.of(State, state, State.drawShadow));
        return .{ .state = state };
    }

    /// Release the meshes. Call it before the `deinit` of the lighting and
    /// of the graph.
    pub fn deinit(self: *Renderer) void {
        const s = self.state;
        s.lighting.removeCaster(s);
        if (s.first_person_pass) |p| s.graph.setPassEnabled(p, false);
        for (s.meshes.items) |*m| m.buffer.destroy();
        s.meshes.deinit(s.allocator);
        s.items.deinit(s.allocator);
        s.bind_group.release();
        s.allocator.destroy(s);
        self.* = undefined;
    }

    /// Make a static mesh. `kind = .lines` reads each two vertices as a line.
    pub fn addMesh(self: *Renderer, vertices: []const Vertex, kind: Kind) !MeshId {
        const s = self.state;
        const size = @max(@as(u64, vertices.len) * @sizeOf(Vertex), @sizeOf(Vertex));
        var buffer = try s.graph.gpu.createBuffer(.{
            .label = "demo_mesh_vertices",
            .size = size,
            .usage = .{ .vertex = true, .copy_dst = true },
        });
        errdefer buffer.destroy();
        if (vertices.len > 0) try s.graph.uploads.write(buffer, 0, std.mem.sliceAsBytes(vertices));
        try s.meshes.append(s.allocator, .{ .buffer = buffer, .count = @intCast(vertices.len), .kind = kind });
        return @fromBackingInt(@intCast(s.meshes.items.len - 1));
    }

    /// Remove the draws of the last frame.
    pub fn clear(self: *Renderer) void {
        self.state.items.clearRetainingCapacity();
    }

    pub fn add(self: *Renderer, layer: Layer, d: Draw) !void {
        try self.state.items.append(self.state.allocator, .{ .layer = layer, .draw = d });
    }

    /// The sun and the ambient light of this frame
    /// (`sw_render.weather.skyLight`).
    pub fn setLight(self: *Renderer, light: sw_render.WeatherLight) void {
        self.state.light = light;
    }

    pub fn setFog(self: *Renderer, on: bool) void {
        self.state.fog = on;
    }

    /// The camera of this frame. Call it before `FrameGraph.execute`.
    pub fn setFrame(self: *Renderer, frame: sw_render.FrameUniforms) void {
        self.state.proj = frame.proj;
        self.state.view_proj = frame.view_proj;
    }

    /// Draw the world layer into `pass` (the scene pass).
    pub fn draw(self: *Renderer, pass: *sw_render.Pass) !void {
        try self.state.drawLayer(pass, .world);
    }

    /// The draw calls of the last world draw.
    pub fn drawCalls(self: *const Renderer) u32 {
        return self.state.draw_calls;
    }

    /// Add a pass that draws the first-person layer over `color`, with its
    /// own depth target (cleared each frame).
    pub fn addFirstPersonPass(self: *Renderer, color: sw_render.TargetId, order: i32) !void {
        const s = self.state;
        const depth = try s.graph.addTarget(.{
            .name = "demo_first_person_depth",
            .format = s.options.depth_format,
            .sample_count = s.options.sample_count,
            .usage = .{ .render_attachment = true },
        });
        try s.graph.addPass(.{
            .name = "demo_first_person",
            .order = order,
            .attachments = .{
                .colors = &.{.{ .target = color, .load_op = .load }},
                .depth = .{ .target = depth },
            },
            .callback = .of(State, s, State.runFirstPerson),
        });
        s.first_person_pass = s.graph.findPass("demo_first_person");
    }
};

// =============================================================================
// Mesh building
// =============================================================================

/// Builds the vertices of a mesh on the CPU.
pub const Builder = struct {
    allocator: std.mem.Allocator,
    vertices: std.ArrayList(Vertex) = .empty,

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Builder) void {
        self.vertices.deinit(self.allocator);
    }

    /// A quad with the corners in counter-clockwise order from the front.
    /// The diagonal goes through the pair of corners with the larger AO sum,
    /// so the AO has no visible seam.
    pub fn quad(self: *Builder, p: [4][3]f32, normal: [3]f32, color: [3]f32, ao: [4]f32) !void {
        const flip = ao[0] + ao[2] < ao[1] + ao[3];
        const order: [6]usize = if (flip) .{ 1, 2, 3, 1, 3, 0 } else .{ 0, 1, 2, 0, 2, 3 };
        for (order) |i| try self.vertices.append(self.allocator, .{ .pos = p[i], .normal = normal, .color = color, .ao = ao[i] });
    }

    /// An axis-aligned box.
    pub fn box(self: *Builder, min: [3]f32, max: [3]f32, color: [3]f32) !void {
        try self.orientedBox(Mat4.identity(), min, max, color);
    }

    /// A box from `min` to `max` in the frame `m`.
    pub fn orientedBox(self: *Builder, m: Mat4, min: [3]f32, max: [3]f32, color: [3]f32) !void {
        const c = struct {
            fn at(mm: Mat4, lo: [3]f32, hi: [3]f32, i: u3) [3]f32 {
                const p: [3]f32 = .{ if (i & 1 != 0) hi[0] else lo[0], if (i & 2 != 0) hi[1] else lo[1], if (i & 4 != 0) hi[2] else lo[2] };
                return xform(mm, p);
            }
        }.at;
        // Each face: four corner indices (bit 0 x, bit 1 y, bit 2 z),
        // counter-clockwise from outside, and the normal.
        const faces = [6]struct { [4]u3, [3]f32 }{
            .{ .{ 1, 3, 7, 5 }, .{ 1, 0, 0 } },
            .{ .{ 4, 6, 2, 0 }, .{ -1, 0, 0 } },
            .{ .{ 2, 6, 7, 3 }, .{ 0, 1, 0 } },
            .{ .{ 0, 1, 5, 4 }, .{ 0, -1, 0 } },
            .{ .{ 4, 5, 7, 6 }, .{ 0, 0, 1 } },
            .{ .{ 1, 0, 2, 3 }, .{ 0, 0, -1 } },
        };
        for (faces) |f| {
            var p: [4][3]f32 = undefined;
            for (f[0], 0..) |idx, k| p[k] = c(m, min, max, idx);
            const n = xdir(m, f[1]);
            try self.quad(p, n, color, .{ 1, 1, 1, 1 });
        }
    }

    pub fn items(self: *const Builder) []const Vertex {
        return self.vertices.items;
    }
};

pub fn xform(m: Mat4, p: [3]f32) [3]f32 {
    const d = m.data;
    return .{
        d[0] * p[0] + d[4] * p[1] + d[8] * p[2] + d[12],
        d[1] * p[0] + d[5] * p[1] + d[9] * p[2] + d[13],
        d[2] * p[0] + d[6] * p[1] + d[10] * p[2] + d[14],
    };
}

pub fn xdir(m: Mat4, p: [3]f32) [3]f32 {
    const d = m.data;
    const v: [3]f32 = .{
        d[0] * p[0] + d[4] * p[1] + d[8] * p[2],
        d[1] * p[0] + d[5] * p[1] + d[9] * p[2],
        d[2] * p[0] + d[6] * p[1] + d[10] * p[2],
    };
    const l = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    return if (l > 1e-6) .{ v[0] / l, v[1] / l, v[2] / l } else v;
}
