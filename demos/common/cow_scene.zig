//! The turning cow: the cow on a stand in a field, with a fence and trees
//! that go into the fog. The cow demo changes one setting at a time, and
//! the menu demo draws the scene behind its menu. Each setting applies at
//! the next frame.
//!
//! The scene has its own frame graph: the shadow cascades, the sky, the
//! scene pass, the post chain (the tonemap and FXAA) and the 2D overlay.
//! With MSAA, the sky and the scene draw into a multisampled HDR target
//! that the scene pass resolves (REQ-GPU-040). A change between MSAA and
//! no MSAA makes the graph again.
const std = @import("std");
const sw = @import("sw_app");
const gpu_mod = @import("sw_gpu");
const sw_math = @import("sw_math");
const sw_render = @import("sw_render");
const mesh = @import("mesh.zig");
const cow = @import("cow.zig");
const overlay_mod = @import("overlay.zig");

const Mat4 = sw_math.Mat4;

pub const AntiAliasing = enum { off, fxaa, msaa };
pub const Meshing = enum { naive, greedy };
pub const SkyStyle = enum { day, violet };

pub const Settings = struct {
    aa: AntiAliasing = .fxaa,
    fxaa_quality: gpu_mod.FxaaQuality = .medium,
    meshing: Meshing = .greedy,
    wireframe: bool = false,
    curve: sw_render.TonemapCurve = .aces,
    exposure: f32 = 1.0,
    palette: u8 = 0,
    /// The time of day, 0 to 1 (0.5 is noon).
    time: f32 = 0.36,
    shadows: bool = true,
    ao: bool = true,
    fog: bool = true,
    sky: SkyStyle = .day,
    /// The turn of the cow, in radians each second.
    turn_speed: f32 = 0.45,
    /// The shadow cascades and the size of each map: they make the graph
    /// again when they change.
    cascades: u32 = 3,
    shadow_map_size: u32 = 2048,

    /// The settings of a graphics preset.
    pub fn fromGraphics(g: sw_render.GraphicsSettings) Settings {
        return .{
            .aa = switch (g.anti_aliasing) {
                .none => .off,
                .fxaa => .fxaa,
                .msaa4, .msaa8 => .msaa,
            },
            .fxaa_quality = g.fxaa_quality,
            .shadows = g.shadows,
            .cascades = g.shadow_cascades,
            .shadow_map_size = g.shadow_map_size,
        };
    }
};

pub const curve_names = [_][]const u8{ "clamp", "Reinhard", "ACES" };

const msaa_samples = 4;
const stand_height: f32 = 0.35;
const eye: [3]f32 = .{ 0, 1.75, 5.4 };
const look_at: [3]f32 = .{ 0, 0.8, 0 };
const fog: sw_render.Fog = .{ .start = 7, .end = 34 };

const violet_palette: sw_render.SkyPalette = .{
    .day_zenith = .{ 0.25, 0.10, 0.45 },
    .day_horizon = .{ 0.90, 0.55, 0.70 },
    .twilight = .{ 0.95, 0.35, 0.55 },
    .sun = .{ 1.0, 0.85, 0.95 },
};

pub const DrawHud = overlay_mod.DrawFn;

/// The parts of the scene that belong to one frame graph.
const Built = struct {
    graph: sw_render.FrameGraph,
    post: sw_render.PostChain,
    sky: sw_render.Sky,
    lighting: sw_render.Lighting,
    meshes: mesh.Renderer,
    overlay: *overlay_mod.Overlay,
    msaa: bool,
    cascades: u32,
    map_size: u32,
    cow: [cow.palettes.len][2][2]mesh.MeshId,
    wire: [2][2]mesh.MeshId,
    world: mesh.MeshId,
    stand: mesh.MeshId,
};

pub const Scene = struct {
    allocator: std.mem.Allocator,
    gpu: *gpu_mod.GPU,
    settings: Settings,
    built: ?*Built = null,
    /// The turn of the cow, in radians. `step` changes it on the fixed
    /// timestep.
    angle: f32 = 0,
    /// The orbit of the camera round the cow, in radians: the menu demo
    /// moves it with the mouse and the gamepad.
    yaw: f32 = 0,
    pitch: f32 = 0,
    /// The quad count of each cow mesh: [meshing][ao].
    quads: [2][2]u32 = .{ .{ 0, 0 }, .{ 0, 0 } },
    offline: bool,
    hud_user: ?*anyopaque,
    hud: DrawHud,
    /// The CPU vertices of the meshes, made one time.
    grid: cow.Grid,

    pub fn create(allocator: std.mem.Allocator, gpu: *gpu_mod.GPU, settings: Settings, offline: bool, hud_user: ?*anyopaque, hud: DrawHud) !*Scene {
        const self = try allocator.create(Scene);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .gpu = gpu,
            .settings = settings,
            .offline = offline,
            .hud_user = hud_user,
            .hud = hud,
            .grid = cow.build(),
        };
        try self.build();
        return self;
    }

    pub fn destroy(self: *Scene) void {
        self.teardown();
        self.allocator.destroy(self);
    }

    pub fn overlay(self: *Scene) *overlay_mod.Overlay {
        return self.built.?.overlay;
    }

    /// The quads of the cow mesh that the settings draw.
    pub fn quadCount(self: *const Scene) u32 {
        return self.quads[@backingInt(self.settings.meshing)][@intFromBool(self.settings.ao)];
    }

    /// The draw calls of the scene pass in the last frame.
    pub fn drawCalls(self: *const Scene) u32 {
        const b = self.built orelse return 0;
        return b.meshes.drawCalls();
    }

    pub fn eye(self: *const Scene) [3]f32 {
        return eyeAt(self.yaw, self.pitch);
    }

    /// Turn the cow. Call it once each tick.
    pub fn step(self: *Scene, dt: f32) void {
        self.angle = @mod(self.angle + self.settings.turn_speed * dt, std.math.tau);
    }

    fn teardown(self: *Scene) void {
        const b = self.built orelse return;
        b.graph.setTimer(null);
        b.overlay.destroy();
        b.meshes.deinit();
        b.lighting.deinit();
        b.sky.deinit();
        b.post.deinit();
        b.graph.deinit();
        self.allocator.destroy(b);
        self.built = null;
    }

    fn build(self: *Scene) !void {
        const allocator = self.allocator;
        const s = self.settings;
        const b = try allocator.create(Built);
        errdefer allocator.destroy(b);
        b.msaa = s.aa == .msaa;
        b.cascades = s.cascades;
        b.map_size = s.shadow_map_size;
        b.graph = try sw_render.FrameGraph.init(allocator, self.gpu, .{});
        const g = &b.graph;
        b.post = try sw_render.PostChain.init(allocator, g, .{});
        const p = &b.post;
        const samples: u32 = if (b.msaa) msaa_samples else 1;
        // The sky and the scene draw into `color`: the HDR target, or a
        // multisampled copy that the scene pass resolves into it.
        const color = if (b.msaa)
            try g.addTarget(.{ .name = "demo_hdr_msaa", .format = p.hdr_format, .sample_count = samples, .usage = .{ .render_attachment = true } })
        else
            p.hdr;
        const depth = try g.addTarget(.{ .name = "demo_depth", .format = .depth24plus, .sample_count = samples, .usage = .{ .render_attachment = true } });
        b.sky = try sw_render.Sky.init(allocator, g, color, .{ .time = s.time, .fog = fog });
        b.lighting = try sw_render.Lighting.init(allocator, g, .{ .cascades = s.cascades, .map_size = s.shadow_map_size, .shadows = .{ .distance = 25 } });
        try g.addPass(.{
            .name = "demo_scene",
            .attachments = .{
                .colors = &.{.{ .target = color, .resolve = if (b.msaa) p.hdr else null, .load_op = .load }},
                .depth = .{ .target = depth },
            },
            .callback = .of(Built, b, drawScene),
        });
        b.meshes = try mesh.Renderer.init(allocator, g, .{ .color_format = p.hdr_format, .sample_count = samples, .lighting = b.lighting });
        try self.buildMeshes(b);
        b.overlay = try overlay_mod.Overlay.create(allocator, g, self.offline, self.hud_user, self.hud);
        self.built = b;
        try self.applyLive();
    }

    fn buildMeshes(self: *Scene, b: *Built) !void {
        const allocator = self.allocator;
        for (0..2) |m| for (0..2) |a| {
            const ao = a == 1;
            var quads = if (m == 0) try cow.meshNaive(allocator, &self.grid, ao) else try cow.meshGreedy(allocator, &self.grid, ao);
            defer quads.deinit(allocator);
            self.quads[m][a] = @intCast(quads.items.len);
            for (cow.palettes, 0..) |pal, pi| {
                var builder = mesh.Builder.init(allocator);
                defer builder.deinit();
                for (quads.items) |q| {
                    var corners: [4][3]f32 = undefined;
                    var aos: [4]f32 = undefined;
                    for (0..4) |i| {
                        corners[i] = cow.toMetres(q.corners[i]);
                        aos[i] = cow.aoFactor(q.ao[i]);
                    }
                    try builder.quad(corners, q.normal, pal[@backingInt(q.color)], aos);
                }
                b.cow[pi][m][a] = try b.meshes.addMesh(builder.items(), .triangles);
            }
            // The wireframe: the four edges of each quad, a little in front
            // of the face.
            var lines: std.ArrayList(mesh.Vertex) = .empty;
            defer lines.deinit(allocator);
            for (quads.items) |q| {
                for (0..4) |i| {
                    for ([_]usize{ i, (i + 1) % 4 }) |k| {
                        var c = cow.toMetres(q.corners[k]);
                        for (0..3) |j| c[j] += q.normal[j] * 0.003;
                        try lines.append(allocator, .{ .pos = c, .normal = q.normal, .color = .{ 0.1, 2.0, 0.4 } });
                    }
                }
            }
            b.wire[m][a] = try b.meshes.addMesh(lines.items, .lines);
        };

        // The stand: a dark plinth with a lighter top.
        var stand = mesh.Builder.init(allocator);
        defer stand.deinit();
        try stand.box(.{ -1.7, 0, -0.95 }, .{ 1.7, stand_height - 0.05, 0.95 }, .{ 0.12, 0.08, 0.05 });
        try stand.box(.{ -1.75, stand_height - 0.05, -1.0 }, .{ 1.75, stand_height, 1.0 }, .{ 0.45, 0.32, 0.18 });
        b.stand = try b.meshes.addMesh(stand.items(), .triangles);

        // The field: the ground, a round fence and two rings of trees, all
        // at fixed places. The far ones go into the fog.
        var world = mesh.Builder.init(allocator);
        defer world.deinit();
        try world.box(.{ -80, -0.2, -80 }, .{ 80, 0, 80 }, .{ 0.16, 0.30, 0.10 });
        const posts = 36;
        for (0..posts) |i| {
            const a = @as(f32, @floatFromInt(i)) / posts * std.math.tau;
            const r: f32 = 9;
            const x = r * @cos(a);
            const z = r * @sin(a);
            try world.orientedBox(Mat4.translation(x, 0, z).mul(Mat4.rotationY(-a)), .{ -0.08, 0, -0.08 }, .{ 0.08, 1.1, 0.08 }, .{ 0.35, 0.25, 0.15 });
            const a2 = (@as(f32, @floatFromInt(i)) + 0.5) / posts * std.math.tau;
            const half = r * @sin(std.math.pi / @as(f32, posts)) + 0.05;
            for ([_]f32{ 0.45, 0.85 }) |y| {
                try world.orientedBox(Mat4.translation(r * @cos(a2), y, r * @sin(a2)).mul(Mat4.rotationY(-a2)), .{ -0.04, 0, -half }, .{ 0.04, 0.1, half }, .{ 0.42, 0.30, 0.18 });
            }
        }
        var seed: u32 = 12345;
        for (0..60) |i| {
            seed = seed *% 1664525 +% 1013904223;
            const jitter = @as(f32, @floatFromInt(seed >> 16 & 0xFF)) / 255.0;
            const a = @as(f32, @floatFromInt(i)) * 2.39996 + jitter;
            const r: f32 = 13 + @as(f32, @floatFromInt(i % 6)) * 4 + jitter * 3;
            const x = r * @cos(a);
            const z = r * @sin(a);
            const h: f32 = 1.6 + jitter * 1.5;
            try world.box(.{ x - 0.15, 0, z - 0.15 }, .{ x + 0.15, h, z + 0.15 }, .{ 0.25, 0.16, 0.08 });
            const w: f32 = 0.9 + jitter * 0.6;
            try world.box(.{ x - w, h - 0.2, z - w }, .{ x + w, h + 1.4 + jitter, z + w }, .{ 0.08, 0.22 + jitter * 0.08, 0.06 });
        }
        b.world = try b.meshes.addMesh(world.items(), .triangles);
    }

    /// Apply the settings that need no new graph.
    fn applyLive(self: *Scene) !void {
        const b = self.built.?;
        const s = self.settings;
        try b.post.setFxaa(if (s.aa == .fxaa) s.fxaa_quality else null);
        b.post.setTonemap(.{ .curve = s.curve, .exposure = s.exposure });
        b.lighting.setShadowsEnabled(s.shadows);
        b.sky.setTime(s.time);
        b.sky.fog = if (s.fog) fog else null;
        b.sky.settings.palette = if (s.sky == .violet) violet_palette else .{};
        b.meshes.setFog(s.fog);
    }

    /// Use new settings. A change of the MSAA or of the shadow maps makes
    /// the graph again.
    pub fn apply(self: *Scene, s: Settings) !void {
        self.settings = s;
        const b = self.built.?;
        if (b.msaa != (s.aa == .msaa) or b.cascades != s.cascades or b.map_size != s.shadow_map_size) {
            self.teardown();
            try self.build();
            return;
        }
        try self.applyLive();
    }

    /// Draw one frame. Give true when the graph ran: then read the frame
    /// back if needed, and call `gpu.present()`.
    pub fn render(self: *Scene, ctx: *sw.Context) !bool {
        const b = self.built.?;
        const s = self.settings;
        const m = &b.meshes;
        m.clear();
        try m.add(.world, .{ .mesh = b.world, .ao = false });
        const turn = Mat4.rotationY(self.angle);
        try m.add(.world, .{ .mesh = b.stand, .model = turn, .ao = false });
        const cow_model = turn.mul(Mat4.translation(0, stand_height, 0));
        const mi = @backingInt(s.meshing);
        const ai = @intFromBool(s.ao);
        try m.add(.world, .{ .mesh = b.cow[s.palette % cow.palettes.len][mi][ai], .model = cow_model, .ao = s.ao });
        if (s.wireframe) try m.add(.world, .{ .mesh = b.wire[mi][ai], .model = cow_model, .cast_shadow = false });

        const w: f32 = @floatFromInt(@max(self.gpu.getSurfaceWidth(), 1));
        const h: f32 = @floatFromInt(@max(self.gpu.getSurfaceHeight(), 1));
        const proj = sw_math.perspective(50.0 * std.math.pi / 180.0, w / h, 0.05, 400.0);
        const e = self.eye();
        const view = sw_math.lookAt(v3(e), v3(look_at), .{ .x = 0, .y = 1, .z = 0 });
        var frame: sw_render.FrameUniforms = .{
            .view = view.data,
            .proj = proj.data,
            .view_proj = proj.mul(view).data,
            .camera_pos = .{ e[0], e[1], e[2], 1 },
        };
        frame.sky = try b.sky.update();
        m.setLight(sw_render.weather.skyLight(b.sky.state()));
        m.setFrame(frame);
        try b.lighting.update(frame);
        b.overlay.frameDone(ctx);
        return try b.graph.execute(frame);
    }
};

/// The camera position: `eye` turned round `look_at` by the orbit.
fn eyeAt(yaw: f32, pitch: f32) [3]f32 {
    const d: [3]f32 = .{ eye[0] - look_at[0], eye[1] - look_at[1], eye[2] - look_at[2] };
    const r = @sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
    const base_pitch = std.math.asin(d[1] / r);
    const p = std.math.clamp(base_pitch + pitch, 0.02, 1.3);
    const h = r * @cos(p);
    return .{ look_at[0] + h * @sin(yaw), look_at[1] + r * @sin(p), look_at[2] + h * @cos(yaw) };
}

fn v3(a: [3]f32) sw_math.Vec3 {
    return .{ .x = a[0], .y = a[1], .z = a[2] };
}

fn drawScene(b: *Built, pass: *sw_render.Pass) anyerror!void {
    try b.meshes.draw(pass);
}

/// The clock text of a time of day: "14:30".
pub fn clock(buf: []u8, time: f32) []const u8 {
    const minutes: u32 = @intFromFloat(@mod(time, 1.0) * 24 * 60);
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ minutes / 60, minutes % 60 }) catch "";
}
