// models - sw_render instanced box models with animation.
//
// Many figures walk in front of the camera. Each figure is a tree of
// boxes: a body, a head, two arms with a hand on each, and two legs. The
// game sets the rotation of each part each frame. One draw call draws all
// figures (REQ-GPU-014). A small held object draws in the first-person
// pass, in front of the world, with its own depth range (REQ-GPU-015). A
// small block floats between the camera and the held object. The depth
// range puts the held object in front of the block.
//
// The models draw into the HDR target of the post chain after the sky
// pass, and use `sw_fog`, so far figures fade into the sky.
//
// `sw_render.Lighting` gives the shadows and a point light. The figures
// cast shadows into a cascaded shadow map. The light follows the sun of
// the sky (REQ-GPU-016). A point light moves near the ground in front of
// the figures (REQ-GPU-017).
//
// Two translucent quads float over the ground at the left, and a third
// is under the ground. The translucent pass draws them after the opaque
// scene, from far to near, with the depth test on and the depth write off
// (REQ-GPU-022, REQ-GPU-023). The ground hides the third quad.
//
// A spark emitter at the right throws particles up. The particle pass
// draws them as camera-facing quads in one draw call, from far to near
// (REQ-GPU-024). The check uses two fixed particles in place of the
// emitter.
//
// A performance overlay at the top left draws a chart of the frame times
// with sw_gfx2d (REQ-GPU-029). When the device has GPU timestamps, a pass
// timer times each pass of the frame graph (REQ-GPU-028). T writes the
// pass times to the log. F sets or removes a limit of 30 frames each
// second (REQ-GPU-027).
//
// Keys: Space stops or starts the animation. D turns the first-person
// depth range on or off. L turns the shadows on or off (REQ-GPU-018). P
// turns the point light on or off. Left and Right change the time of day.
//
// Native `--check`: no window. The example draws a fixed pose three times:
// with the first-person depth range, with no depth range, and with the
// shadows off. It reads each frame back and compares pixels with the CPU
// reference of the shader after the CPU tonemap: the figures, the ground
// in the shadow of a figure, the same ground in light, and the ground
// under the point light. It checks the draw calls and the instance
// counts. The pixel through the two translucent quads must be the CPU
// blend of the far quad, then the near quad, over the ground. The same
// test is done for two particles, in one draw call. The background of
// the overlay must have its colour. When the device has GPU timestamps,
// each render pass must have a time. It exits
// with 0 (pass) or 1 (fail).
const std = @import("std");
const sw = @import("sw_app");
const builtin = @import("builtin");
const sw_math = @import("sw_math");
const gpu_mod = @import("sw_gpu");
const sw_render = @import("sw_render");
const sw_gfx2d = @import("sw_gfx2d");

const Mat4 = sw_math.Mat4;
const Quat = sw_math.Quat;
const Vec3 = sw_math.Vec3;
const box_model = sw_render.box_model;

pub const std_options: std.Options = .{
    .logFn = if (builtin.cpu.arch.isWasm()) sw.webLogFn else std.log.defaultLog,
};

pub const main = if (builtin.cpu.arch.isWasm()) mainWasm else mainNative;

// The browser does not call main. backends/wasm/loader.ts calls the exports
// that exportWeb makes.
fn mainWasm() void {}

comptime {
    if (builtin.cpu.arch.isWasm()) sw.exportWeb(config, Callbacks);
}

var check_mode = false;

fn mainNative(init: std.process.Init) !void {
    var c = config;
    c.io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--check")) {
            check_mode = true;
            c.headless = true;
            c.headless_gpu = true;
            c.tick_timing = .unlimited;
        }
    }
    try sw.run(c, Callbacks);
}

const width = 800;
const height = 600;

const config: sw.Config = .{
    .title = "models",
    .size = .{ .w = width, .h = height },
    .tick_hz = 60,
};

// =============================================================================
// The models
// =============================================================================

const green: [3]f32 = .{ 0.20, 0.55, 0.25 };
const skin: [3]f32 = .{ 0.80, 0.60, 0.45 };
const red: [3]f32 = .{ 0.70, 0.15, 0.10 };
const yellow: [3]f32 = .{ 0.90, 0.80, 0.10 };
const blue: [3]f32 = .{ 0.15, 0.20, 0.60 };

/// The part indices of the figure.
const Fig = struct {
    const body = 0;
    const head = 1;
    const right_arm = 2;
    const right_hand = 3;
    const left_arm = 4;
    const left_hand = 5;
    const left_leg = 6;
    const right_leg = 7;
    const count = 8;
};

fn box(min: [3]f32, max: [3]f32, color: [3]f32) sw_render.BoxModelBox {
    return .{ .min = min, .max = max, .color = color };
}

const figure_parts = [Fig.count]sw_render.BoxModelPart{
    .{ .pivot = .{ 0, 1.0, 0 }, .boxes = &.{box(.{ -0.4, 1.0, -0.2 }, .{ 0.4, 2.2, 0.2 }, green)} },
    .{ .parent = Fig.body, .pivot = .{ 0, 2.2, 0 }, .boxes = &.{box(.{ -0.3, 2.2, -0.3 }, .{ 0.3, 2.8, 0.3 }, skin)} },
    .{ .parent = Fig.body, .pivot = .{ 0.55, 2.1, 0 }, .boxes = &.{box(.{ 0.4, 1.2, -0.15 }, .{ 0.7, 2.2, 0.15 }, red)} },
    .{ .parent = Fig.right_arm, .pivot = .{ 0.55, 1.2, 0 }, .boxes = &.{box(.{ 0.4, 0.9, -0.15 }, .{ 0.7, 1.2, 0.15 }, yellow)} },
    .{ .parent = Fig.body, .pivot = .{ -0.55, 2.1, 0 }, .boxes = &.{box(.{ -0.7, 1.2, -0.15 }, .{ -0.4, 2.2, 0.15 }, red)} },
    .{ .parent = Fig.left_arm, .pivot = .{ -0.55, 1.2, 0 }, .boxes = &.{box(.{ -0.7, 0.9, -0.15 }, .{ -0.4, 1.2, 0.15 }, yellow)} },
    .{ .parent = Fig.body, .pivot = .{ -0.2, 1.0, 0 }, .boxes = &.{box(.{ -0.4, 0, -0.2 }, .{ -0.02, 1.0, 0.2 }, blue)} },
    .{ .parent = Fig.body, .pivot = .{ 0.2, 1.0, 0 }, .boxes = &.{box(.{ 0.02, 0, -0.2 }, .{ 0.4, 1.0, 0.2 }, blue)} },
};

/// A unit cube with white albedo. The tint gives the colour.
const block_parts = [_]sw_render.BoxModelPart{
    .{ .boxes = &.{box(.{ -0.5, -0.5, -0.5 }, .{ 0.5, 0.5, 0.5 }, .{ 1, 1, 1 })} },
};

const barrel_color: [3]f32 = .{ 0.30, 0.30, 0.35 };
/// The held object: a barrel along -Z, and a grip that turns under it.
const held_parts = [_]sw_render.BoxModelPart{
    .{ .boxes = &.{box(.{ -0.04, -0.04, -0.3 }, .{ 0.04, 0.04, 0.1 }, barrel_color)} },
    .{ .parent = 0, .pivot = .{ 0, -0.04, 0.03 }, .boxes = &.{box(.{ -0.03, -0.12, 0 }, .{ 0.03, -0.04, 0.06 }, .{ 0.35, 0.20, 0.10 })} },
};

// =============================================================================
// The scene
// =============================================================================

const eye: [3]f32 = .{ 0, 1.6, 6 };
const fog: sw_render.Fog = .{ .start = 25, .end = 70 };
/// The front row: three figures at z = 0.
const front_x = [3]f32{ -3, 0, 3 };
const front_tint = [3][3]f32{ .{ 1, 1, 1 }, .{ 1, 1, 1 }, .{ 0.6, 0.6, 1.0 } };
/// The figures behind the front row, in fog.
const grid_x = [_]f32{ -15, -12, -9, -6, 6, 9, 12, 15 };
const grid_rows = 8;
const figure_count = front_x.len + grid_x.len * grid_rows;
/// The held object in view space.
const held_pos: [3]f32 = .{ 0.25, -0.2, -0.6 };
/// The block between the camera and the held object, in view space.
const block_view_pos: [3]f32 = .{ 0.125, -0.1, -0.25 };
const block_size: f32 = 0.08;
const block_tint: [3]f32 = .{ 0.9, 0.45, 0.1 };
const ground_tint: [3]f32 = .{ 0.25, 0.35, 0.2 };

/// The time of day of the check: the sun is 45 degrees up, to +X.
const check_time: f32 = 0.375;
const cascade_count = 3;
/// The point light of the check, near the ground in front of the figures.
const check_point_light: sw_render.PointLight = .{
    .position = .{ 0.6, 0.4, 2.5 },
    .color = .{ 1.0, 0.6, 0.25 },
    .intensity = 2.0,
    .radius = 2.5,
};

var graph: ?sw_render.FrameGraph = null;
var post: ?sw_render.PostChain = null;
var sky: ?sw_render.Sky = null;
var lighting: ?sw_render.Lighting = null;
var models: ?sw_render.BoxModels = null;
var glass: ?sw_render.Translucent = null;
var sparks: ?sw_render.Particles = null;
var spark_system: ?sw_render.ParticleSystem = null;
var spark_emitter: sw_render.ParticleEmitter = .{
    .position = .{ 4.5, 0.2, 1.5 },
    .rate = 60,
    .speed = .{ 2, 4 },
    .spread = 0.4,
    .life = .{ 0.6, 1.2 },
    .size = 0.08,
    .color = .{ 1.0, 0.7, 0.2, 1.0 },
    .seed = 3,
};

/// The ground point behind the two check particles.
const spark_ground: [3]f32 = .{ -0.4, 0, 1.0 };
/// The check particles: red (far) and blue (near), at alpha 0.5, on the
/// line from the eye to `spark_ground`.
const spark_at = [2]f32{ 0.55, 0.45 };
const spark_color = [2][4]f32{ .{ 1, 0, 0, 0.5 }, .{ 0, 0, 1, 0.5 } };

fn sparkAt(t: f32) [3]f32 {
    var c: [3]f32 = undefined;
    for (0..3) |i| c[i] = eye[i] + t * (spark_ground[i] - eye[i]);
    return c;
}
var overlay: ?sw_gfx2d.Renderer = null;
var timer: ?sw_render.PassTimer = null;
var frame_times: sw_render.FrameTimes = .{};
var limiter: sw_render.FrameLimiter = .{};
var last_frame_ns: ?u64 = null;
const chart_options: sw_render.FrameChartOptions = .{
    .rect = .{ .x = 8, .y = 8, .w = 128, .h = 40 },
    .background = .{ .r = 0.1, .g = 0.1, .b = 0.4 },
};

var figure: sw_render.BoxModelId = undefined;
var block: sw_render.BoxModelId = undefined;
var held: sw_render.BoxModelId = undefined;

var anim_time: f32 = 0;
var anim_on = true;
var depth_range_on = true;
var shadows_on = true;
var point_light_on = true;
var time_of_day: f32 = check_time;

const first_person_view: sw_render.BoxModelView = .{ .depth_range = .{ 0, 0.01 }, .fog = false };
const no_range_view: sw_render.BoxModelView = .{ .depth_range = .{ 0, 1 }, .fog = false };

/// The ground point behind the translucent quads. No figure shades it, and
/// the point light does not reach it.
const glass_ground: [3]f32 = .{ -1.0, 0, 2.5 };
/// The quads: red at alpha 0.5 (far), blue at alpha 0.5 (near), and a
/// green quad under the ground. Each one is on the line from the eye to
/// `glass_ground`, at this part of the line.
const glass_at = [3]f32{ 0.6, 0.4, 1.3 };
const glass_color = [3][4]f32{ .{ 1, 0, 0, 0.5 }, .{ 0, 0, 1, 0.5 }, .{ 0, 1, 0, 0.8 } };

/// A square quad of side 0.2 that faces +Z, at part `t` of the line from
/// the eye to `glass_ground`.
fn glassQuad(t: f32, color: [4]f32) sw_render.TranslucentQuad {
    var c: [3]f32 = undefined;
    for (0..3) |i| c[i] = eye[i] + t * (glass_ground[i] - eye[i]);
    const h: f32 = 0.1;
    return .{
        .{ .pos = .{ c[0] - h, c[1] - h, c[2] }, .color = color },
        .{ .pos = .{ c[0] + h, c[1] - h, c[2] }, .color = color },
        .{ .pos = .{ c[0] + h, c[1] + h, c[2] }, .color = color },
        .{ .pos = .{ c[0] - h, c[1] + h, c[2] }, .color = color },
    };
}

fn v3(a: [3]f32) Vec3 {
    return .{ .x = a[0], .y = a[1], .z = a[2] };
}

fn translation(p: [3]f32) Mat4 {
    return Mat4.translation(p[0], p[1], p[2]);
}

/// A translation and a scale on each axis.
fn placed(p: [3]f32, s: [3]f32) Mat4 {
    var m = translation(p);
    m.data[0] = s[0];
    m.data[5] = s[1];
    m.data[10] = s[2];
    return m;
}

fn axisAngle(axis: [3]f32, angle: f32) Quat {
    return Quat.fromAxisAngle(v3(axis), angle);
}

/// The walk pose at phase `t` (radians): the legs and the arms swing, the
/// head looks round.
fn walkPose(t: f32) [Fig.count]Quat {
    var q: [Fig.count]Quat = @splat(Quat.identity());
    const swing = 0.6 * @sin(t);
    q[Fig.left_leg] = axisAngle(.{ 1, 0, 0 }, swing);
    q[Fig.right_leg] = axisAngle(.{ 1, 0, 0 }, -swing);
    q[Fig.left_arm] = axisAngle(.{ 1, 0, 0 }, -swing);
    q[Fig.right_arm] = axisAngle(.{ 1, 0, 0 }, swing);
    q[Fig.left_hand] = axisAngle(.{ 1, 0, 0 }, -0.4 - 0.3 * @sin(t));
    q[Fig.right_hand] = axisAngle(.{ 1, 0, 0 }, -0.4 + 0.3 * @sin(t));
    q[Fig.head] = axisAngle(.{ 0, 1, 0 }, 0.5 * @sin(t * 0.5));
    return q;
}

/// The pose of the centre figure in the check: the right arm points to +X,
/// and the right hand points up from the elbow.
fn checkPose() [Fig.count]Quat {
    var q: [Fig.count]Quat = @splat(Quat.identity());
    q[Fig.right_arm] = axisAngle(.{ 0, 0, 1 }, std.math.pi / 2.0);
    q[Fig.right_hand] = axisAngle(.{ 0, 0, 1 }, std.math.pi / 2.0);
    return q;
}

fn centreTransform() Mat4 {
    return translation(.{ front_x[1], 0, 0 });
}

fn addInstances(m: *sw_render.BoxModels) !void {
    m.clear();
    const t = if (check_mode) 0 else anim_time;
    // The front row. In the check, the centre figure has the check pose.
    for (front_x, front_tint, 0..) |x, tint, i| {
        const pose = if (check_mode)
            (if (i == 1) checkPose() else @as([Fig.count]Quat, @splat(Quat.identity())))
        else
            walkPose(t * 4 + @as(f32, @floatFromInt(i)));
        try m.add(.world, figure, .{ .transform = translation(.{ x, 0, 0 }), .rotations = &pose, .tint = tint });
    }
    // The grid: each figure walks round a small circle.
    for (0..grid_rows) |row| {
        for (grid_x, 0..) |x, col| {
            const phase: f32 = @floatFromInt(row * 3 + col * 7);
            const z = -15 - 6 * @as(f32, @floatFromInt(row));
            const yaw = t * 0.5 + phase;
            const root = translation(.{ x, 0, z }).mul(axisAngle(.{ 0, 1, 0 }, yaw).toMat4());
            const pose = walkPose(t * 4 + phase);
            try m.add(.world, figure, .{ .transform = root, .rotations = &pose });
        }
    }
    // The ground and the block.
    try m.add(.world, block, .{ .transform = placed(.{ 0, -0.05, -30 }, .{ 200, 0.1, 200 }), .tint = ground_tint });
    const block_world: [3]f32 = .{ eye[0] + block_view_pos[0], eye[1] + block_view_pos[1], eye[2] + block_view_pos[2] };
    try m.add(.world, block, .{ .transform = placed(block_world, @splat(block_size)), .tint = block_tint });
    // The held object, in view space. It bobs while the animation runs.
    const bob = 0.01 * @sin(t * 8);
    const grip = [_]Quat{ Quat.identity(), axisAngle(.{ 1, 0, 0 }, -0.3) };
    try m.add(.first_person, held, .{ .transform = translation(.{ held_pos[0], held_pos[1] + bob, held_pos[2] }), .rotations = &grip });
}

const Callbacks = struct {
    pub fn init(ctx: *sw.Context) !void {
        const gpu = ctx.gpu();
        if (!gpu.isReady()) return;
        const allocator = ctx.allocator();

        // The frame graph: the sky, the scene and the first-person pass on
        // the HDR target. The post chain then runs the tonemap.
        graph = try sw_render.FrameGraph.init(allocator, gpu, .{});
        const g = &graph.?;
        post = try sw_render.PostChain.init(allocator, g, .{});
        const p = &post.?;
        sky = try sw_render.Sky.init(allocator, g, p.hdr, .{ .time = check_time, .fog = fog });
        // The shadow cascades run before the sky and the scene.
        lighting = try sw_render.Lighting.init(allocator, g, .{ .cascades = cascade_count });
        const depth = try g.addTarget(.{ .name = "depth", .format = .depth24plus, .usage = .{ .render_attachment = true } });
        try g.addPass(.{
            .name = "scene",
            .attachments = .{
                // The sky wrote each pixel: keep it.
                .colors = &.{.{ .target = p.hdr, .load_op = .load }},
                .depth = .{ .target = depth },
            },
            .callback = .plain(drawScene),
        });

        // The models receive the lighting, and the world layer casts
        // shadows.
        models = try sw_render.BoxModels.init(allocator, g, .{ .color_format = p.hdr_format, .lighting = lighting.? });
        const m = &models.?;
        figure = try m.addModel(.{ .parts = &figure_parts });
        block = try m.addModel(.{ .parts = &block_parts });
        held = try m.addModel(.{ .parts = &held_parts });
        try m.addFirstPersonPass(.{ .color = p.hdr, .depth = depth, .view = first_person_view });

        // The translucent quads, near quad first, so that only the sort
        // gives the correct blend.
        glass = try sw_render.Translucent.init(allocator, g, .{ .color_format = p.hdr_format, .max_quads = 4 });
        const gl = &glass.?;
        try gl.setQuads(&.{ glassQuad(glass_at[1], glass_color[1]), glassQuad(glass_at[0], glass_color[0]), glassQuad(glass_at[2], glass_color[2]) });
        try gl.addPass(.{ .color = p.hdr, .depth = depth });

        spark_system = try sw_render.ParticleSystem.init(allocator, 256);
        sparks = try sw_render.Particles.init(allocator, g, .{ .color_format = p.hdr_format, .capacity = 256 });
        try sparks.?.addPass(.{ .color = p.hdr, .depth = depth });
        if (check_mode) {
            // The near particle first, so that only the sort gives the
            // correct blend.
            spark_system.?.spawn(.{ .pos = sparkAt(spark_at[1]), .size = 0.15, .color = spark_color[1], .life = 1000 });
            spark_system.?.spawn(.{ .pos = sparkAt(spark_at[0]), .size = 0.15, .color = spark_color[0], .life = 1000 });
        }
        // The performance overlay draws on the screen after the post chain.
        overlay = try sw_gfx2d.Renderer.init(allocator, gpu, .{});
        try g.addPass(.{
            .name = "overlay",
            .order = 2000,
            .attachments = .{ .colors = &.{.{ .target = .screen, .load_op = .load }} },
            .callback = .plain(drawOverlay),
        });
        if (gpu.supportsTimestamps()) {
            timer = try sw_render.PassTimer.init(allocator, gpu, .{});
            g.setTimer(&timer.?);
        } else {
            std.log.info("models: the device has no GPU timestamps. The pass timer is off.", .{});
        }
        std.log.info("models: GPU ready. {d} figures. Space: animation. D: first-person depth range. L: shadows. P: point light. Left/Right: time. T: pass times. F: frame limit.", .{figure_count});
    }

    pub fn tick(ctx: *sw.Context) !void {
        if (check_mode) return;
        const in = ctx.input();
        if (in.keyPressed(.Space)) anim_on = !anim_on;
        if (in.keyPressed(.D)) {
            depth_range_on = !depth_range_on;
            if (models) |*m| m.setFirstPersonView(if (depth_range_on) first_person_view else no_range_view);
        }
        if (in.keyPressed(.L)) {
            shadows_on = !shadows_on;
            if (lighting) |*l| l.setShadowsEnabled(shadows_on);
        }
        if (in.keyPressed(.P)) point_light_on = !point_light_on;
        if (in.keyPressed(.F)) limiter.setTarget(if (limiter.target_fps == null) 30 else null);
        if (in.keyPressed(.T)) {
            if (timer) |*t| {
                for (t.times()) |pt| std.log.info("models: pass {s}: {d:.3} ms", .{ pt.name, pt.ms });
            }
        }
        if (in.keyDown(.Left)) time_of_day -= 0.1 / 60.0;
        if (in.keyDown(.Right)) time_of_day += 0.1 / 60.0;
        if (anim_on) {
            anim_time += 1.0 / 60.0;
            if (spark_system) |*s| {
                _ = spark_emitter.emit(s, 1.0 / 60.0);
                s.step(1.0 / 60.0);
            }
        }
    }

    pub fn render(ctx: *sw.Context) !void {
        const gpu = ctx.gpu();
        if (!gpu.isReady()) return;
        if (models == null) return;
        const g = &graph.?;
        const m = &models.?;

        if (check_mode) setCheckStep();
        try addInstances(m);

        const frame = frameUniforms(gpu.getSurfaceWidth(), gpu.getSurfaceHeight());
        var f = frame;
        sky.?.setTime(time_of_day);
        f.sky = try sky.?.update();
        // The shadow light follows the sun of `f.sky`.
        const l = &lighting.?;
        if (point_light_on) {
            var light = check_point_light;
            if (!check_mode) {
                const a = anim_time * 0.8;
                light.position = .{ 2.0 * @sin(a), 0.4, 1.5 + 1.2 * @cos(a) };
            }
            try l.setPointLights(&.{light});
        } else {
            try l.setPointLights(&.{});
        }
        try l.update(f);
        try glass.?.update(eye);
        try sparks.?.update(&spark_system.?, sw_render.ParticleCamera.fromView(f.view, eye));
        if (try g.execute(f)) {
            if (comptime !builtin.cpu.arch.isWasm()) {
                if (check_mode) try checkFrame(ctx, f);
            }
            gpu.present();
        }
        pace(ctx);
    }

    pub fn shutdown(ctx: *sw.Context) !void {
        if (graph) |*g| g.setTimer(null);
        if (timer) |*t| t.deinit();
        timer = null;
        if (overlay) |*o| o.deinit();
        overlay = null;
        if (glass) |*gl| gl.deinit();
        glass = null;
        if (sparks) |*s| s.deinit();
        sparks = null;
        if (spark_system) |*s| s.deinit(ctx.allocator());
        spark_system = null;
        if (models) |*m| m.deinit();
        models = null;
        if (lighting) |*l| l.deinit();
        lighting = null;
        if (sky) |*s| s.deinit();
        sky = null;
        if (post) |*p| p.deinit();
        post = null;
        if (graph) |*g| g.deinit();
        graph = null;
    }
};

fn frameUniforms(w_px: u32, h_px: u32) sw_render.FrameUniforms {
    const w: f32 = @floatFromInt(@max(w_px, 1));
    const h: f32 = @floatFromInt(@max(h_px, 1));
    const proj = sw_math.perspective(std.math.pi / 3.0, w / h, 0.1, 1000.0);
    const view = sw_math.lookAt(v3(eye), v3(.{ eye[0], eye[1], eye[2] - 1 }), .{ .x = 0, .y = 1, .z = 0 });
    return .{
        .view = view.data,
        .proj = proj.data,
        .view_proj = proj.mul(view).data,
        .camera_pos = .{ eye[0], eye[1], eye[2], 1 },
    };
}

/// Keep the frame time for the chart, and wait for the frame limit.
/// Native only: the web build has no clock here.
fn pace(ctx: *sw.Context) void {
    const io = ctx.io orelse return;
    if (check_mode) {
        // Fixed times: the check does not depend on the speed of the
        // machine.
        frame_times.push(10);
        return;
    }
    const now: u64 = @intCast(@max(std.Io.Timestamp.now(io, .awake).toNanoseconds(), 0));
    if (last_frame_ns) |last| frame_times.push(@as(f32, @floatFromInt(now -| last)) / std.time.ns_per_ms);
    const wait_ns = limiter.wait(now);
    if (wait_ns > 0) io.sleep(.fromNanoseconds(wait_ns), .awake) catch {};
    last_frame_ns = @intCast(@max(std.Io.Timestamp.now(io, .awake).toNanoseconds(), 0));
}

fn drawOverlay(pass: *sw_render.Pass) !void {
    const o = &overlay.?;
    o.beginFrame(pass.width, pass.height, 1);
    try sw_render.drawFrameChart(o, &frame_times, chart_options);
    try o.flush(pass.render.?);
}

fn drawScene(pass: *sw_render.Pass) !void {
    try models.?.draw(pass, .world, .{});
}

// =============================================================================
// Native check: pixels against the CPU reference, and the draw calls
// =============================================================================

const Step = struct {
    name: []const u8,
    depth_range: bool,
    shadows: bool = true,
};

const steps = [_]Step{
    .{ .name = "first-person depth range", .depth_range = true },
    .{ .name = "no depth range", .depth_range = false },
    .{ .name = "shadows off", .depth_range = true, .shadows = false },
};

var check_frame: u32 = 0;
var check_ok = true;

/// Each step draws two frames. The check reads the second one.
fn setCheckStep() void {
    const step = steps[check_frame / 2];
    models.?.setFirstPersonView(if (step.depth_range) first_person_view else no_range_view);
    lighting.?.setShadowsEnabled(step.shadows);
}

fn checkFrame(ctx: *sw.Context, frame: sw_render.FrameUniforms) !void {
    defer check_frame += 1;
    if (check_frame % 2 == 0) return;
    const step = steps[check_frame / 2];
    const allocator = ctx.allocator();
    const gpu = ctx.gpu();
    const pixels = try gpu.captureFrame(allocator);
    defer allocator.free(pixels);
    if (!checkStep(step, frame, pixels, gpu.getSurfaceWidth(), gpu.getSurfaceHeight())) check_ok = false;
    if (check_frame / 2 + 1 == steps.len) {
        std.log.info("models: check {s}", .{if (check_ok) "passed" else "FAILED"});
        std.process.exit(if (check_ok) 0 else 1);
    }
}

/// The display colour of a linear HDR colour: the CPU tonemap of the chain.
fn display(c: [3]f32) [3]u8 {
    const t: sw_render.Tonemap = .{};
    var out: [3]u8 = undefined;
    for (0..3) |i| out[i] = @intFromFloat(@round(sw_render.post.tonemapChannel(c[i], t, true) * 255.0));
    return out;
}

fn maxDiff(a: [3]u8, b: [3]u8) u32 {
    var d: u32 = 0;
    for (0..3) |i| d = @max(d, @abs(@as(i32, a[i]) - @as(i32, b[i])));
    return d;
}

/// The pixel of a point, with the matrix `m` to clip space.
fn project(m: [16]f32, p: [3]f32, w: u32, h: u32) [2]u32 {
    const c = (Mat4{ .data = m }).mulVec4(.{ .x = p[0], .y = p[1], .z = p[2], .w = 1 });
    const nx = c.x / c.w;
    const ny = c.y / c.w;
    const fw: f32 = @floatFromInt(w);
    const fh: f32 = @floatFromInt(h);
    return .{ @intFromFloat((nx + 1) * 0.5 * fw), @intFromFloat((1 - ny) * 0.5 * fh) };
}

fn transformPoint(m: Mat4, p: [3]f32) [3]f32 {
    const v = m.mulVec4(.{ .x = p[0], .y = p[1], .z = p[2], .w = 1 });
    return .{ v.x, v.y, v.z };
}

fn distance(a: [3]f32, b: [3]f32) f32 {
    const d: [3]f32 = .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
    return @sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
}

fn pixelAt(pixels: []const u8, w: u32, xy: [2]u32) [3]u8 {
    const i = (xy[1] * w + xy[0]) * 4;
    return .{ pixels[i + 2], pixels[i + 1], pixels[i] };
}

/// The CPU colour of a box face with the normal `normal`, its albedo and
/// tint, at the point `world`, with the shadow factor `shadow`.
/// `fogged`: a world-space face, with the fog and the point lights. Else
/// a view-space face (the held object): no fog, no shadow, no point light.
fn litColor(frame: sw_render.FrameUniforms, albedo: [3]f32, tint: [3]f32, normal: [3]f32, world: [3]f32, shadow: f32, fogged: bool) [3]u8 {
    const light = models.?.getLight();
    const lt = lighting.?;
    const points: [3]f32 = if (fogged) sw_render.lighting.pointLights(lt.uniforms(), world, normal) else .{ 0, 0, 0 };
    var c = box_model.shadeLit(albedo, tint, normal, lt.lightDirection(), light, shadow, points);
    if (fogged) c = sw_render.sky.applyFog(frame.sky, c, distance(world, eye));
    return display(c);
}

/// A face that turns to the camera (+Z), in light.
fn faceColor(frame: sw_render.FrameUniforms, albedo: [3]f32, tint: [3]f32, world: [3]f32, fogged: bool) [3]u8 {
    return litColor(frame, albedo, tint, .{ 0, 0, 1 }, world, 1, fogged);
}

fn brightness(c: [3]u8) i32 {
    return @as(i32, c[0]) + c[1] + c[2];
}

fn expectPixel(step: Step, what: []const u8, pixels: []const u8, w: u32, xy: [2]u32, want: [3]u8) bool {
    const got = pixelAt(pixels, w, xy);
    const d = maxDiff(got, want);
    if (d > 3) {
        std.log.err("models: {s}: {s} at ({d}, {d}) is {any}, the CPU reference is {any}", .{ step.name, what, xy[0], xy[1], got, want });
        return false;
    }
    std.log.info("models: {s}: {s} at ({d}, {d}) is {any}, difference {d}", .{ step.name, what, xy[0], xy[1], got, d });
    return true;
}

fn checkStep(step: Step, frame: sw_render.FrameUniforms, pixels: []const u8, w: u32, h: u32) bool {
    var ok = true;
    const vp = frame.view_proj;

    // One draw call for each model and layer: the figures and the blocks
    // in the world, and the held object in the first-person pass.
    const s = models.?.stats();
    const want_instances = figure_count + 2 + 1;
    const want_records = figure_count * Fig.count + 2 + held_parts.len;
    std.log.info("models: {s}: {d} draw calls, {d} instances, {d} part records", .{ step.name, s.draw_calls, s.instances, s.records });
    if (s.draw_calls != 3 or s.instances != want_instances or s.records != want_records) {
        std.log.err("models: {s}: the counts must be 3 draw calls, {d} instances, {d} records", .{ step.name, want_instances, want_records });
        ok = false;
    }
    // The world layer (the figures and the blocks) draws into each
    // cascade with the shadows on, and into none with the shadows off.
    const want_shadow_calls: u32 = if (step.shadows) 2 * cascade_count else 0;
    std.log.info("models: {s}: {d} shadow draw calls", .{ step.name, s.shadow_draw_calls });
    if (s.shadow_draw_calls != want_shadow_calls) {
        std.log.err("models: {s}: the shadow draw calls must be {d}", .{ step.name, want_shadow_calls });
        ok = false;
    }

    // The hand of the centre figure: the arm points to +X, and the hand
    // points up from the elbow (1.45, 2.1). The pixel is on the front face
    // of the posed hand, near its tip, clear of the arm.
    var mats: [Fig.count]Mat4 = undefined;
    const pose = checkPose();
    box_model.pose(&figure_parts, centreTransform(), &pose, &mats) catch unreachable;
    const hand = transformPoint(mats[Fig.right_hand], .{ 0.55, 0.95, 0.15 });
    if (@abs(hand[0] - 1.45) > 1e-4 or @abs(hand[1] - 2.35) > 1e-4) {
        std.log.err("models: the hand is at {any}, not at (1.45, 2.35)", .{hand});
        ok = false;
    }
    ok = expectPixel(step, "posed hand", pixels, w, project(vp, hand, w, h), faceColor(frame, yellow, .{ 1, 1, 1 }, hand, true)) and ok;

    // The arm at its rest position: the pose moved it, so the pixel is not
    // the arm colour.
    const rest_arm: [3]f32 = .{ 0.55, 1.7, 0.15 };
    const rest_xy = project(vp, rest_arm, w, h);
    const rest_want = faceColor(frame, red, .{ 1, 1, 1 }, rest_arm, true);
    const rest_got = pixelAt(pixels, w, rest_xy);
    std.log.info("models: {s}: the rest position of the arm at ({d}, {d}) is {any}", .{ step.name, rest_xy[0], rest_xy[1], rest_got });
    if (maxDiff(rest_got, rest_want) <= 20) {
        std.log.err("models: {s}: the arm is still at its rest position", .{step.name});
        ok = false;
    }

    // The bodies of the other front figures: two instances of one draw,
    // the right one with a tint.
    for ([_]usize{ 0, 2 }) |i| {
        const body: [3]f32 = .{ front_x[i], 1.6, 0.2 };
        ok = expectPixel(step, if (i == 0) "left body" else "right body (tinted)", pixels, w, project(vp, body, w, h), faceColor(frame, green, front_tint[i], body, true)) and ok;
    }

    // The block between the camera and the held object.
    const block_face: [3]f32 = .{ eye[0] + block_view_pos[0], eye[1] + block_view_pos[1], eye[2] + block_view_pos[2] + block_size / 2 };
    ok = expectPixel(step, "block", pixels, w, project(vp, block_face, w, h), faceColor(frame, .{ 1, 1, 1 }, block_tint, block_face, true)) and ok;

    // The back face of the held object, in view space. The view has no
    // rotation, so the light in view space is the world light. With the
    // depth range, the held object covers the block. With no depth range,
    // the block covers it.
    const held_face: [3]f32 = .{ held_pos[0], held_pos[1], held_pos[2] + 0.1 };
    const held_xy = project(frame.proj, held_face, w, h);
    if (step.depth_range) {
        ok = expectPixel(step, "held object in front of the block", pixels, w, held_xy, faceColor(frame, barrel_color, .{ 1, 1, 1 }, held_face, false)) and ok;
    } else {
        ok = expectPixel(step, "block in front of the held object", pixels, w, held_xy, faceColor(frame, .{ 1, 1, 1 }, block_tint, block_face, true)) and ok;
    }
    ok = checkShadows(step, frame, pixels, w, h) and ok;
    ok = checkGlass(step, frame, pixels, w, h) and ok;
    ok = checkSparks(step, frame, pixels, w, h) and ok;
    ok = checkOverlay(step, pixels, w) and ok;
    return ok;
}

/// The ground in the shadow of the centre body, the same ground in light,
/// and the ground under the point light (REQ-GPU-016, REQ-GPU-017,
/// REQ-GPU-018).
fn checkShadows(step: Step, frame: sw_render.FrameUniforms, pixels: []const u8, w: u32, h: u32) bool {
    var ok = true;
    const vp = frame.view_proj;
    const up: [3]f32 = .{ 0, 1, 0 };
    const l = lighting.?.lightDirection();
    // The light follows the sun of the sky.
    const sun = sw_render.sky.sunDirection(check_time, (sw_render.SkySettings{}).tilt);
    if (@abs(l[0] - sun[0]) > 1e-4 or @abs(l[1] - sun[1]) > 1e-4 or @abs(l[2] - sun[2]) > 1e-4) {
        std.log.err("models: {s}: the shadow light {any} is not the sun {any}", .{ step.name, l, sun });
        ok = false;
    }

    // The centre of the body of the centre figure, moved along the light
    // to the top of the ground (y = 0).
    const body_min: [3]f32 = .{ -0.4, 1.0, -0.2 };
    const body_max: [3]f32 = .{ 0.4, 2.2, 0.2 };
    const t = 1.6 / l[1];
    const shadowed: [3]f32 = .{ -l[0] * t, 0, -l[2] * t };
    // The same ground with no caster between it and the light. Each front
    // figure is in a box from z = -0.3 to 0.3, and the ray goes to +Z.
    const lit: [3]f32 = .{ -2.2, 0, 1.2 };
    if (!sw_render.lighting.rayHitsBox(shadowed, l, body_min, body_max)) {
        std.log.err("models: the shadow point {any} is not behind the body", .{shadowed});
        ok = false;
    }
    for (front_x) |x| {
        if (sw_render.lighting.rayHitsBox(lit, l, .{ x - 0.7, 0, -0.3 }, .{ x + 1.8, 2.8, 0.3 })) {
            std.log.err("models: the lit point {any} is behind a figure", .{lit});
            ok = false;
        }
    }

    const shadow_factor: f32 = if (step.shadows) 0 else 1;
    const want_shadowed = litColor(frame, .{ 1, 1, 1 }, ground_tint, up, shadowed, shadow_factor, true);
    const want_lit = litColor(frame, .{ 1, 1, 1 }, ground_tint, up, lit, 1, true);
    const shadowed_xy = project(vp, shadowed, w, h);
    const lit_xy = project(vp, lit, w, h);
    ok = expectPixel(step, "ground in the body shadow", pixels, w, shadowed_xy, want_shadowed) and ok;
    ok = expectPixel(step, "ground in light", pixels, w, lit_xy, want_lit) and ok;
    const got_shadowed = pixelAt(pixels, w, shadowed_xy);
    const got_lit = pixelAt(pixels, w, lit_xy);
    if (step.shadows) {
        // The shadow removes the sun light: the CPU reference is much
        // darker, and so is the frame.
        const want_drop = brightness(want_lit) - brightness(want_shadowed);
        const got_drop = brightness(got_lit) - brightness(got_shadowed);
        std.log.info("models: {s}: the shadow is darker by {d} (the CPU reference: {d})", .{ step.name, got_drop, want_drop });
        if (want_drop < 60 or @abs(got_drop - want_drop) > 9) {
            std.log.err("models: {s}: the shadow must be darker by about {d}", .{ step.name, want_drop });
            ok = false;
        }
    } else if (maxDiff(got_shadowed, got_lit) > 3) {
        std.log.err("models: {s}: with no shadows, the shadow point {any} must equal the lit point {any}", .{ step.name, got_shadowed, got_lit });
        ok = false;
    }

    // The ground under the point light.
    const under: [3]f32 = .{ check_point_light.position[0], 0, check_point_light.position[2] };
    const under_xy = project(vp, under, w, h);
    const want_under = litColor(frame, .{ 1, 1, 1 }, ground_tint, up, under, 1, true);
    ok = expectPixel(step, "ground under the point light", pixels, w, under_xy, want_under) and ok;
    // With no point light, the CPU reference is the same as the lit ground.
    const light = models.?.getLight();
    const no_point = display(box_model.shadeLit(.{ 1, 1, 1 }, ground_tint, up, l, light, 1, .{ 0, 0, 0 }));
    const gain = brightness(pixelAt(pixels, w, under_xy)) - brightness(no_point);
    std.log.info("models: {s}: the point light adds {d}", .{ step.name, gain });
    if (gain < 60) {
        std.log.err("models: {s}: the point light must make the ground brighter", .{step.name});
        ok = false;
    }
    return ok;
}

/// The pixel through the translucent quads: the CPU blend of the far red
/// quad, then the near blue quad, over the ground. The green quad under
/// the ground must not show (REQ-GPU-022, REQ-GPU-023).
fn checkGlass(step: Step, frame: sw_render.FrameUniforms, pixels: []const u8, w: u32, h: u32) bool {
    var ok = true;
    const up: [3]f32 = .{ 0, 1, 0 };
    const lt = lighting.?;
    const light = models.?.getLight();
    const l = lt.lightDirection();
    for (front_x) |x| {
        if (sw_render.lighting.rayHitsBox(glass_ground, l, .{ x - 0.7, 0, -0.3 }, .{ x + 1.8, 2.8, 0.3 })) {
            std.log.err("models: the glass ground point {any} is behind a figure", .{glass_ground});
            ok = false;
        }
    }
    const points = sw_render.lighting.pointLights(lt.uniforms(), glass_ground, up);
    var ground = box_model.shadeLit(.{ 1, 1, 1 }, ground_tint, up, l, light, 1, points);
    ground = sw_render.sky.applyFog(frame.sky, ground, distance(glass_ground, eye));
    const red_c: [3]f32 = .{ glass_color[0][0], glass_color[0][1], glass_color[0][2] };
    const blue_c: [3]f32 = .{ glass_color[1][0], glass_color[1][1], glass_color[1][2] };
    const blend = sw_render.translucent.over;
    const want = display(blend(blend(ground, red_c, glass_color[0][3]), blue_c, glass_color[1][3]));
    const xy = project(frame.view_proj, glass_ground, w, h);
    ok = expectPixel(step, "ground through the translucent quads", pixels, w, xy, want) and ok;
    const got = pixelAt(pixels, w, xy);
    // The near quad is blue: blue is over red.
    if (got[2] <= got[0]) {
        std.log.err("models: {s}: the translucent quads drew near to far", .{step.name});
        ok = false;
    }
    if (glass.?.sort_count != 1) {
        std.log.err("models: {s}: the quads sorted {d} times. The camera does not move, so they must sort one time", .{ step.name, glass.?.sort_count });
        ok = false;
    }
    return ok;
}

/// The pixel through the two check particles: the CPU blend of the far
/// red particle, then the near blue particle, over the ground. One draw
/// call draws both (REQ-GPU-024).
fn checkSparks(step: Step, frame: sw_render.FrameUniforms, pixels: []const u8, w: u32, h: u32) bool {
    var ok = true;
    const up: [3]f32 = .{ 0, 1, 0 };
    const lt = lighting.?;
    const l = lt.lightDirection();
    for (front_x) |x| {
        if (sw_render.lighting.rayHitsBox(spark_ground, l, .{ x - 0.7, 0, -0.3 }, .{ x + 1.8, 2.8, 0.3 })) {
            std.log.err("models: the spark ground point {any} is behind a figure", .{spark_ground});
            ok = false;
        }
    }
    const points = sw_render.lighting.pointLights(lt.uniforms(), spark_ground, up);
    var ground = box_model.shadeLit(.{ 1, 1, 1 }, ground_tint, up, l, models.?.getLight(), 1, points);
    ground = sw_render.sky.applyFog(frame.sky, ground, distance(spark_ground, eye));
    const blend = sw_render.translucent.over;
    const far: [3]f32 = .{ spark_color[0][0], spark_color[0][1], spark_color[0][2] };
    const near: [3]f32 = .{ spark_color[1][0], spark_color[1][1], spark_color[1][2] };
    const want = display(blend(blend(ground, far, spark_color[0][3]), near, spark_color[1][3]));
    ok = expectPixel(step, "ground through two particles", pixels, w, project(frame.view_proj, spark_ground, w, h), want) and ok;
    if (sparks.?.draw_calls != 1) {
        std.log.err("models: {s}: the particles used {d} draw calls, not 1", .{ step.name, sparks.?.draw_calls });
        ok = false;
    }
    return ok;
}

/// The overlay background at the top left, and the pass times when the
/// device has GPU timestamps.
fn checkOverlay(step: Step, pixels: []const u8, w: u32) bool {
    var ok = true;
    const bg = chart_options.background;
    const want: [3]u8 = .{ @intFromFloat(@round(bg.r * 255)), @intFromFloat(@round(bg.g * 255)), @intFromFloat(@round(bg.b * 255)) };
    ok = expectPixel(step, "overlay background", pixels, w, .{ 9, 9 }, want) and ok;
    const t = if (timer) |*pt| pt else return ok;
    for ([_][]const u8{ "scene", "sw_translucent", "sw_particles", "overlay" }) |name| {
        const ms = t.find(name) orelse {
            std.log.err("models: {s}: the pass timer has no time for the pass {s}", .{ step.name, name });
            ok = false;
            continue;
        };
        if (!(ms >= 0 and ms < 10_000)) {
            std.log.err("models: {s}: the pass {s} has the time {d} ms", .{ step.name, name, ms });
            ok = false;
        }
    }
    if (!(t.total() > 0)) {
        std.log.err("models: {s}: the sum of the pass times is {d} ms, not more than 0", .{ step.name, t.total() });
        ok = false;
    }
    std.log.info("models: {s}: {d} passes timed, {d:.3} ms on the GPU", .{ step.name, t.times().len, t.total() });
    return ok;
}
