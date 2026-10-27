// sky - the sw_render sky, fog and day-night cycle.
//
// The sky pass draws a gradient, a sun, a moon and stars into the HDR
// target of the post chain, from a time of day (REQ-GPU-010). The scene
// pass draws a ground plane and a field of boxes on top. Its shader calls
// `sw_fog` from the shared WGSL prefix, so far objects fade into the
// horizon colour of the sky (REQ-GPU-011). The tonemap of the post chain
// then writes the screen.
//
// Keys: Left and Right change the time. Space stops or starts the clock.
// C turns the cube-map skybox on or off. G turns the fog on or off.
//
// Native `--check`: no window. The example draws the sky at noon, at
// sunrise, at midnight, and with the cube map. It reads each frame back.
// It compares the right half of the screen (sky and ground) with the CPU
// reference of `sw_render.sky`, after the CPU tonemap. It exits with 0
// (pass) or 1 (fail).
const std = @import("std");
const sw = @import("sw_app");
const builtin = @import("builtin");
const sw_math = @import("sw_math");
const gpu_mod = @import("sw_gpu");
const sw_render = @import("sw_render");

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
    .title = "sky",
    .size = .{ .w = width, .h = height },
    .tick_hz = 60,
};

const Vertex = extern struct {
    position: [3]f32,
    normal: [3]f32,
    /// Linear albedo.
    color: [3]f32,
};

/// The ground is a square of this half size around the origin.
const ground_half = 2000.0;
const ground_albedo: [3]f32 = .{ 0.10, 0.16, 0.07 };
const fog: sw_render.Fog = .{ .start = 30, .end = 140 };
const eye: [3]f32 = .{ 0, 2, 0 };
const look_at: [3]f32 = .{ 100, 12, 0 };
/// One day in seconds, while the clock runs.
const day_seconds = 40.0;

const max_boxes = 128;
var vertices: [6 + max_boxes * 36]Vertex = undefined;
var vertex_count: u32 = 0;

var graph: ?sw_render.FrameGraph = null;
var post: ?sw_render.PostChain = null;
var sky: ?sw_render.Sky = null;
var cube: ?sw_render.CubeMap = null;
var pipeline: ?gpu_mod.RenderPipeline = null;
var vertex_buffer: ?gpu_mod.Buffer = null;

var time_of_day: f32 = 0.3;
var clock_on = true;
var cube_on = false;
var fog_on = true;

/// The six faces of the demo cube map, one colour each, in sRGB.
const cube_size = 16;
const cube_colors = [6][3]u8{
    .{ 70, 110, 160 }, // +X
    .{ 150, 90, 120 }, // -X
    .{ 90, 140, 200 }, // +Y
    .{ 60, 60, 50 }, // -Y
    .{ 160, 150, 110 }, // +Z
    .{ 90, 150, 110 }, // -Z
};

const shader_code = sw_render.wgsl.shader(
    \\struct VSOut {
    \\    @builtin(position) pos: vec4f,
    \\    @location(0) world: vec3f,
    \\    @location(1) normal: vec3f,
    \\    @location(2) color: vec3f,
    \\}
    \\
    \\@vertex fn vs_main(
    \\    @location(0) pos: vec3f,
    \\    @location(1) normal: vec3f,
    \\    @location(2) color: vec3f,
    \\) -> VSOut {
    \\    var out: VSOut;
    \\    out.pos = sw_frame.view_proj * vec4f(pos, 1.0);
    \\    out.world = pos;
    \\    out.normal = normal;
    \\    out.color = color;
    \\    return out;
    \\}
    \\
    \\@fragment fn fs_main(in: VSOut) -> @location(0) vec4f {
    \\    // The sky light: the zenith and horizon colours, and the sun.
    \\    let s = sw_frame.sky;
    \\    let sun = max(dot(in.normal, s.sun_dir.xyz), 0.0) * 1.5 * smoothstep(-0.05, 0.05, s.sun_dir.y);
    \\    let light = 0.6 * s.zenith.rgb + 0.6 * s.horizon.rgb + vec3f(sun + 0.02);
    \\    return vec4f(sw_fog(in.color * light, in.world), 1.0);
    \\}
);

/// The CPU reference of the scene shader for the ground.
fn groundColor(u: sw_render.SkyUniforms, dist: f32) [3]f32 {
    const sun = @max(u.sun_dir[1], 0.0) * 1.5 * sw_render.sky.smoothstep(-0.05, 0.05, u.sun_dir[1]);
    var c: [3]f32 = undefined;
    for (0..3) |i| c[i] = ground_albedo[i] * (0.6 * u.zenith[i] + 0.6 * u.horizon[i] + sun + 0.02);
    return sw_render.sky.applyFog(u, c, dist);
}

const Callbacks = struct {
    pub fn init(ctx: *sw.Context) !void {
        const gpu = ctx.gpu();
        if (!gpu.isReady()) return;
        const allocator = ctx.allocator();

        buildScene();
        vertex_buffer = try gpu.createBuffer(.{
            .size = @sizeOf(Vertex) * vertex_count,
            .usage = .{ .vertex = true, .copy_dst = true },
        });
        gpu.writeBuffer(vertex_buffer.?, 0, std.mem.sliceAsBytes(vertices[0..vertex_count]));

        // The frame graph: the sky pass, then the scene pass, on the HDR
        // target. The post chain then runs the tonemap.
        graph = try sw_render.FrameGraph.init(allocator, gpu, .{});
        const g = &graph.?;
        post = try sw_render.PostChain.init(allocator, g, .{});
        const p = &post.?;
        sky = try sw_render.Sky.init(allocator, g, p.hdr, .{ .time = time_of_day, .fog = fog });
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

        var faces: [6][cube_size * cube_size * 4]u8 = undefined;
        var face_slices: [6][]const u8 = undefined;
        for (&faces, cube_colors, 0..) |*f, c, i| {
            var j: usize = 0;
            while (j < f.len) : (j += 4) f[j..][0..4].* = .{ c[0], c[1], c[2], 255 };
            face_slices[i] = f;
        }
        cube = try sw_render.CubeMap.init(gpu, cube_size, face_slices, .rgba8unorm_srgb);

        var pipeline_layout = try gpu.createPipelineLayout(.{
            .bind_group_layouts = &[_]*gpu_mod.BindGroupLayout{&g.frame_layout},
        });
        var shader = try gpu.createShaderModule(.{ .code = shader_code });
        pipeline = try gpu.createRenderPipeline(.{
            .layout = &pipeline_layout,
            .vertex = .{
                .module = &shader,
                .entry_point = "vs_main",
                .buffers = &[_]gpu_mod.VertexBufferLayout{.{
                    .array_stride = @sizeOf(Vertex),
                    .attributes = &[_]gpu_mod.VertexAttribute{
                        .{ .format = .float32x3, .offset = 0, .shader_location = 0 },
                        .{ .format = .float32x3, .offset = 12, .shader_location = 1 },
                        .{ .format = .float32x3, .offset = 24, .shader_location = 2 },
                    },
                }},
            },
            .fragment = .{
                .module = &shader,
                .entry_point = "fs_main",
                .targets = &[_]gpu_mod.ColorTargetState{.{ .format = p.hdr_format }},
            },
            .primitive = .{ .topology = .triangle_list, .cull_mode = .none },
            .depth_stencil = .{ .format = .depth24plus, .depth_write_enabled = true, .depth_compare = .less },
            .multisample = .{ .count = 1 },
        });
        std.log.info("sky: GPU ready. Left/Right: time. Space: clock. C: cube map. G: fog.", .{});
    }

    pub fn tick(ctx: *sw.Context) !void {
        if (check_mode) return;
        const in = ctx.input();
        const dt: f32 = 1.0 / 60.0;
        if (in.keyPressed(.Space)) clock_on = !clock_on;
        if (in.keyPressed(.C)) {
            cube_on = !cube_on;
            if (sky) |*s| try s.setCubeMap(if (cube_on) &cube.? else null, .{ 1, 1, 1 });
        }
        if (in.keyPressed(.G)) {
            fog_on = !fog_on;
            if (sky) |*s| s.fog = if (fog_on) fog else null;
        }
        if (in.keyDown(.Left)) time_of_day -= dt * 0.1;
        if (in.keyDown(.Right)) time_of_day += dt * 0.1;
        if (clock_on) time_of_day += dt / day_seconds;
        time_of_day = sw_render.sky.wrapTime(time_of_day);
    }

    pub fn render(ctx: *sw.Context) !void {
        const gpu = ctx.gpu();
        if (!gpu.isReady()) return;
        if (pipeline == null) return;
        const g = &graph.?;
        const s = &sky.?;

        if (check_mode) try setCheckStep();
        s.setTime(time_of_day);

        const w: f32 = @floatFromInt(@max(gpu.getSurfaceWidth(), 1));
        const h: f32 = @floatFromInt(@max(gpu.getSurfaceHeight(), 1));
        const proj = sw_math.perspective(std.math.pi / 3.0, w / h, 0.1, 5000.0);
        const view = sw_math.lookAt(
            .{ .x = eye[0], .y = eye[1], .z = eye[2] },
            .{ .x = look_at[0], .y = look_at[1], .z = look_at[2] },
            .{ .x = 0, .y = 1, .z = 0 },
        );
        var frame: sw_render.FrameUniforms = .{
            .view = view.data,
            .proj = proj.data,
            .view_proj = proj.mul(view).data,
            .camera_pos = .{ eye[0], eye[1], eye[2], 1 },
        };
        frame.sky = try s.update();
        if (try g.execute(frame)) {
            if (comptime !builtin.cpu.arch.isWasm()) {
                if (check_mode) try checkFrame(ctx, frame);
            }
            gpu.present();
        }
    }

    pub fn shutdown(ctx: *sw.Context) !void {
        _ = ctx;
        if (sky) |*s| s.deinit();
        sky = null;
        if (cube) |*c| c.deinit();
        cube = null;
        if (post) |*p| p.deinit();
        post = null;
        if (graph) |*g| g.deinit();
        graph = null;
    }
};

fn drawScene(pass: *sw_render.Pass) !void {
    const rp = pass.render.?;
    rp.setPipeline(pipeline.?);
    pass.bindFrame();
    rp.setVertexBuffer(0, vertex_buffer.?, 0, @sizeOf(Vertex) * vertex_count);
    rp.draw(vertex_count, 1, 0, 0);
}

// =============================================================================
// The scene: a ground plane, and boxes on the left side (z < 0)
// =============================================================================

fn push(v: Vertex) void {
    vertices[vertex_count] = v;
    vertex_count += 1;
}

fn buildScene() void {
    vertex_count = 0;
    const g = ground_half;
    const up: [3]f32 = .{ 0, 1, 0 };
    const corners = [4][3]f32{ .{ -g, 0, -g }, .{ g, 0, -g }, .{ g, 0, g }, .{ -g, 0, g } };
    for ([_]usize{ 0, 1, 2, 0, 2, 3 }) |i| push(.{ .position = corners[i], .normal = up, .color = ground_albedo });

    // The boxes stay at z <= -3, so the right half of the screen shows only
    // the sky and the ground.
    var n: u32 = 0;
    var x: f32 = 8;
    while (x < 200 and n < max_boxes) : (x += 9) {
        var z: f32 = -4;
        while (z > -60 and n < max_boxes) : (z -= 11) {
            const hash = @as(u32, @intFromFloat(x * 7 + -z * 13)) *% 2654435761;
            const tall = 1.0 + @as(f32, @floatFromInt(hash >> 28)) * 0.6;
            const tint = @as(f32, @floatFromInt((hash >> 20) & 0xff)) / 255.0;
            addBox(.{ x, 0, z }, .{ 1.2, tall, 1.2 }, .{ 0.25 + 0.3 * tint, 0.22, 0.30 - 0.15 * tint });
            n += 1;
        }
    }
}

fn addBox(base: [3]f32, size: [3]f32, color: [3]f32) void {
    const lo: [3]f32 = .{ base[0] - size[0] / 2, base[1], base[2] - size[2] / 2 };
    const hi: [3]f32 = .{ base[0] + size[0] / 2, base[1] + size[1], base[2] + size[2] / 2 };
    // Each face: an axis, a side, and the two other axes.
    for (0..3) |axis| {
        for ([_]bool{ false, true }) |positive| {
            var normal: [3]f32 = .{ 0, 0, 0 };
            normal[axis] = if (positive) 1 else -1;
            const a = (axis + 1) % 3;
            const b = (axis + 2) % 3;
            var quad: [4][3]f32 = undefined;
            for (0..4) |k| {
                var p: [3]f32 = undefined;
                p[axis] = if (positive) hi[axis] else lo[axis];
                p[a] = if (k == 1 or k == 2) hi[a] else lo[a];
                p[b] = if (k >= 2) hi[b] else lo[b];
                quad[k] = p;
            }
            for ([_]usize{ 0, 1, 2, 0, 2, 3 }) |i| push(.{ .position = quad[i], .normal = normal, .color = color });
        }
    }
}

// =============================================================================
// Native check: the sky and the fog against the CPU reference
// =============================================================================

const Step = struct {
    name: []const u8,
    time: f32,
    cube: bool = false,
};

const steps = [_]Step{
    .{ .name = "noon", .time = 0.5 },
    .{ .name = "sunrise", .time = 0.27 },
    .{ .name = "midnight", .time = 0.0 },
    .{ .name = "noon with the cube map", .time = 0.5, .cube = true },
};

var check_frame: u32 = 0;
var check_ok = true;

/// Each step draws two frames. The check reads the second one.
fn setCheckStep() !void {
    const step = steps[check_frame / 2];
    time_of_day = step.time;
    if (step.cube != cube_on) {
        cube_on = step.cube;
        try sky.?.setCubeMap(if (cube_on) &cube.? else null, .{ 1, 1, 1 });
    }
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
        std.log.info("sky: check {s}", .{if (check_ok) "passed" else "FAILED"});
        std.process.exit(if (check_ok) 0 else 1);
    }
}

fn srgbDecode(c: u8) f32 {
    const x = @as(f32, @floatFromInt(c)) / 255.0;
    if (x <= 0.04045) return x / 12.92;
    return std.math.pow(f32, (x + 0.055) / 1.055, 2.4);
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

fn checkStep(step: Step, frame: sw_render.FrameUniforms, pixels: []const u8, w: u32, h: u32) bool {
    const u = frame.sky;
    const s = sky.?.state();
    const pass_uniforms = sw_render.sky.passUniforms(s, sky.?.settings, if (step.cube) [3]f32{ 1, 1, 1 } else null);
    var ok = true;
    var compared: u32 = 0;
    var bad: u32 = 0;
    var worst: u32 = 0;
    var star_pixels: u32 = 0;
    var ground_pixels: u32 = 0;
    var full_fog: u32 = 0;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = w / 2 + 20;
        while (x < w) : (x += 1) {
            const dir = sw_render.sky.viewRay(frame.view, frame.proj, sw_render.sky.pixelNdc(x, y, w, h));
            var want: [3]f32 = undefined;
            // The ray hits the ground plane (y = 0) inside the square, or
            // it sees the sky.
            const t = if (dir[1] < 0) -eye[1] / dir[1] else std.math.inf(f32);
            const hx = eye[0] + dir[0] * t;
            const hz = eye[2] + dir[2] * t;
            if (t < std.math.inf(f32) and @abs(hx) < ground_half and @abs(hz) < ground_half) {
                want = groundColor(u, t);
                ground_pixels += 1;
                if (sw_render.sky.fogAmount(u, t) >= 1.0) full_fog += 1;
            } else {
                const c = cube_colors[sw_render.sky.cubeFace(dir)];
                const cube_linear: [3]f32 = .{ srgbDecode(c[0]), srgbDecode(c[1]), srgbDecode(c[2]) };
                want = sw_render.sky.passColor(u, pass_uniforms, dir, cube_linear);
                if (sw_render.sky.stars(pass_uniforms, dir) * pass_uniforms.stars[3] > 0.05 and dir[1] > 0.1) star_pixels += 1;
            }
            const i = (y * w + x) * 4;
            const got: [3]u8 = .{ pixels[i + 2], pixels[i + 1], pixels[i] };
            const d = maxDiff(got, display(want));
            worst = @max(worst, d);
            if (d > 3) {
                if (bad < 5) std.log.err("sky: {s}: pixel ({d}, {d}) is {any}, the CPU reference is {any}", .{ step.name, x, y, got, display(want) });
                bad += 1;
            }
            compared += 1;
        }
    }
    std.log.info("sky: {s}: {d} pixels, {d} ground, {d} in full fog, {d} star pixels, {d} differ, largest difference {d}", .{ step.name, compared, ground_pixels, full_fog, star_pixels, bad, worst });
    if (bad > 0) ok = false;
    // Each step must test the ground, full fog and the sky.
    if (ground_pixels == 0 or full_fog == 0 or ground_pixels == compared) {
        std.log.err("sky: {s}: the view does not show the ground, the fog and the sky", .{step.name});
        ok = false;
    }
    // Stars at night, and none in the day.
    if ((s.daylight < 0.01 and star_pixels == 0) or (s.daylight > 0.5 and star_pixels > 0)) {
        std.log.err("sky: {s}: {d} star pixels with daylight {d:.2}", .{ step.name, star_pixels, s.daylight });
        ok = false;
    }

    // The sun at sunrise: the pixel at the sun centre is near white.
    if (std.mem.eql(u8, step.name, "sunrise")) {
        const v = frame.view;
        const d = s.sun_dir;
        const vx = v[0] * d[0] + v[4] * d[1] + v[8] * d[2];
        const vy = v[1] * d[0] + v[5] * d[1] + v[9] * d[2];
        const vz = v[2] * d[0] + v[6] * d[1] + v[10] * d[2];
        const nx = frame.proj[0] * vx / -vz;
        const ny = frame.proj[5] * vy / -vz;
        const px: u32 = @intFromFloat((nx + 1) * 0.5 * @as(f32, @floatFromInt(w)));
        const py: u32 = @intFromFloat((1 - ny) * 0.5 * @as(f32, @floatFromInt(h)));
        const i = (py * w + px) * 4;
        const got: [3]u8 = .{ pixels[i + 2], pixels[i + 1], pixels[i] };
        std.log.info("sky: sunrise: the sun is at pixel ({d}, {d}), colour {any}", .{ px, py, got });
        if (got[0] < 230 or got[1] < 200) {
            std.log.err("sky: sunrise: the sun is not bright", .{});
            ok = false;
        }
    }
    return ok;
}
