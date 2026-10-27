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
// Keys: Space stops or starts the animation. D turns the first-person
// depth range on or off.
//
// Native `--check`: no window. The example draws a fixed pose two times:
// with the first-person depth range, and with no depth range. It reads
// each frame back and compares pixels with the CPU reference of the shader
// after the CPU tonemap. It checks the draw calls and the instance counts.
// It exits with 0 (pass) or 1 (fail).
const std = @import("std");
const sw = @import("sw_app");
const builtin = @import("builtin");
const sw_math = @import("sw_math");
const gpu_mod = @import("sw_gpu");
const sw_render = @import("sw_render");

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

var graph: ?sw_render.FrameGraph = null;
var post: ?sw_render.PostChain = null;
var sky: ?sw_render.Sky = null;
var models: ?sw_render.BoxModels = null;
var figure: sw_render.BoxModelId = undefined;
var block: sw_render.BoxModelId = undefined;
var held: sw_render.BoxModelId = undefined;

var anim_time: f32 = 0;
var anim_on = true;
var depth_range_on = true;

const first_person_view: sw_render.BoxModelView = .{ .depth_range = .{ 0, 0.01 }, .fog = false };
const no_range_view: sw_render.BoxModelView = .{ .depth_range = .{ 0, 1 }, .fog = false };

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
        sky = try sw_render.Sky.init(allocator, g, p.hdr, .{ .time = 0.5, .fog = fog });
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

        models = try sw_render.BoxModels.init(allocator, g, .{ .color_format = p.hdr_format });
        const m = &models.?;
        figure = try m.addModel(.{ .parts = &figure_parts });
        block = try m.addModel(.{ .parts = &block_parts });
        held = try m.addModel(.{ .parts = &held_parts });
        try m.addFirstPersonPass(.{ .color = p.hdr, .depth = depth, .view = first_person_view });
        std.log.info("models: GPU ready. {d} figures. Space: animation. D: first-person depth range.", .{figure_count});
    }

    pub fn tick(ctx: *sw.Context) !void {
        if (check_mode) return;
        const in = ctx.input();
        if (in.keyPressed(.Space)) anim_on = !anim_on;
        if (in.keyPressed(.D)) {
            depth_range_on = !depth_range_on;
            if (models) |*m| m.setFirstPersonView(if (depth_range_on) first_person_view else no_range_view);
        }
        if (anim_on) anim_time += 1.0 / 60.0;
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
        f.sky = try sky.?.update();
        if (try g.execute(f)) {
            if (comptime !builtin.cpu.arch.isWasm()) {
                if (check_mode) try checkFrame(ctx, f);
            }
            gpu.present();
        }
    }

    pub fn shutdown(ctx: *sw.Context) !void {
        _ = ctx;
        if (models) |*m| m.deinit();
        models = null;
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

fn drawScene(pass: *sw_render.Pass) !void {
    try models.?.draw(pass, .world, .{});
}

// =============================================================================
// Native check: pixels against the CPU reference, and the draw calls
// =============================================================================

const Step = struct {
    name: []const u8,
    depth_range: bool,
};

const steps = [_]Step{
    .{ .name = "first-person depth range", .depth_range = true },
    .{ .name = "no depth range", .depth_range = false },
};

var check_frame: u32 = 0;
var check_ok = true;

/// Each step draws two frames. The check reads the second one.
fn setCheckStep() void {
    const step = steps[check_frame / 2];
    models.?.setFirstPersonView(if (step.depth_range) first_person_view else no_range_view);
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

/// A face that turns to the camera (+Z), with its albedo and tint, at the
/// point `world`. `fogged`: the world fog applies.
fn faceColor(frame: sw_render.FrameUniforms, albedo: [3]f32, tint: [3]f32, world: [3]f32, fogged: bool) [3]u8 {
    const light = models.?.getLight();
    var c = box_model.shade(albedo, tint, .{ 0, 0, 1 }, light.unitDir(), light);
    if (fogged) c = sw_render.sky.applyFog(frame.sky, c, distance(world, eye));
    return display(c);
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
    return ok;
}
