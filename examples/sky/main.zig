// sky - the sw_render sky, fog, day-night cycle, clouds and weather.
//
// The sky pass draws a gradient, a sun, a moon and stars into the HDR
// target of the post chain, from a time of day (REQ-GPU-010). The scene
// pass draws a ground plane and a field of boxes on top. Its shader calls
// `sw_fog` from the shared WGSL prefix, so far objects fade into the
// horizon colour of the sky (REQ-GPU-011). The cloud pass draws a layer of
// boxes from a shape image that the example makes, and the wind moves it
// (REQ-GPU-020). The precipitation pass draws snow or rain around the
// camera. A height map stops it on the ground and on the boxes
// (REQ-GPU-021). The tonemap of the post chain then writes the screen.
//
// The fog can also come from a post effect that reads the depth target
// (REQ-GPU-030). Then the scene shader does not call `sw_fog`.
//
// Three more effects make the sky alive: cloud shadows on the ground
// (REQ-GPU-031), soft clouds with a bright rim toward the sun
// (REQ-GPU-032), and light shafts toward the sun (REQ-GPU-033).
//
// Keys: Left and Right change the time. Space stops or starts the clock.
// C turns the cube-map skybox on or off. G turns the fog on or off. K
// turns the clouds on or off. R changes the weather: snow, rain, none. E
// changes the fog between the scene shader and the post effect. H turns
// the light shafts on or off. J turns the cloud shadows on or off. O
// changes the clouds between boxes and soft clouds.
//
// Native `--check`: no window. The example draws the sky at noon, at
// sunrise, at midnight, with the cube map, with clouds, with snow and with
// rain, and at noon and sunrise with the fog post effect in place of the
// shader fog, with soft clouds, with cloud shadows and with light shafts.
// It reads each frame back. It compares the right half of the screen
// (sky, clouds and ground) with the CPU reference of `sw_render.sky` and
// `sw_render.weather`, after the CPU tonemap. For snow and rain it checks
// the particles one by one: a particle above the height map has the CPU
// reference colour, and a particle under it does not draw. It exits with
// 0 (pass) or 1 (fail). `--dump DIR` also writes each checked frame to
// DIR as a PPM image.
//
// Native `--perf`: no window, 1920 by 1080. The example times the GPU
// passes (REQ-GPU-028) with box clouds, soft clouds, cloud shadows and
// light shafts, and writes the mean time of each pass to the log.
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
var perf_mode = false;
var dump_dir: ?[]const u8 = null;

fn mainNative(init: std.process.Init) !void {
    var c = config;
    c.io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args[1..], 1..) |arg, i| {
        if (std.mem.eql(u8, arg, "--check")) {
            check_mode = true;
            c.headless = true;
            c.headless_gpu = true;
            c.tick_timing = .unlimited;
        }
        if (std.mem.eql(u8, arg, "--dump") and i + 1 < args.len) dump_dir = args[i + 1];
        if (std.mem.eql(u8, arg, "--perf")) {
            perf_mode = true;
            c.headless = true;
            c.headless_gpu = true;
            c.tick_timing = .unlimited;
            c.size = .{ .w = 1920, .h = 1080 };
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
/// The base centre and the size of each box, for the height map.
var boxes: [max_boxes][2][3]f32 = undefined;
var box_count: u32 = 0;

var graph: ?sw_render.FrameGraph = null;
var post: ?sw_render.PostChain = null;
var sky: ?sw_render.Sky = null;
var cube: ?sw_render.CubeMap = null;
var pipeline: ?gpu_mod.RenderPipeline = null;
/// The scene pipeline with no `sw_fog`, for the fog post effect.
var pipeline_no_fog: ?gpu_mod.RenderPipeline = null;
var fog_effect: sw_render.PostEffectId = undefined;
var post_fog_on = false;
var shadow_effect: sw_render.PostEffectId = undefined;
var shafts: ?sw_render.LightShafts = null;
var shafts_on = false;
var shadows_on = false;
var timer: ?sw_render.PassTimer = null;
var vertex_buffer: ?gpu_mod.Buffer = null;
var clouds: ?sw_render.Clouds = null;
var precipitation: ?sw_render.Precipitation = null;

var time_of_day: f32 = 0.3;
var clock_on = true;
var cube_on = false;
var fog_on = true;
var clouds_on = true;
const Weather = enum { snow, rain, none };
var weather: Weather = .snow;
/// The time of the wind and the fall, in seconds.
var seconds: f64 = 0;

// The cloud shape: one texel for each cell, made from a value noise.
const shape_size = 48;
var shape_pixels: [shape_size * shape_size * 4]u8 = undefined;
const cloud_settings: sw_render.CloudSettings = .{
    .bottom = 34,
    .thickness = 6,
    .cell_size = 9,
    .wind = .{ 2.0, 0.6 },
    .fade_start = 220,
    .fade_end = 320,
};

// The height map: the ground (0) and the box tops, in cells of 0.25
// around the camera.
const map_cell = 0.25;
const map_half = 24.0;
const map_size: u32 = @intFromFloat(2 * map_half / map_cell);
var heights: [map_size * map_size]f32 = undefined;
/// The roof of the check: a part of the map, in front of the camera on
/// the right, at this height. The scene does not draw it.
const roof_height = 3.0;
const roof_lo: [2]f32 = .{ 3, 1 };
const roof_hi: [2]f32 = .{ 15, 13 };

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
    \\fn scene_color(in: VSOut) -> vec3f {
    \\    // The sky light: the zenith and horizon colours, and the sun.
    \\    let s = sw_frame.sky;
    \\    let sun = max(dot(in.normal, s.sun_dir.xyz), 0.0) * 1.5 * smoothstep(-0.05, 0.05, s.sun_dir.y);
    \\    let light = 0.6 * s.zenith.rgb + 0.6 * s.horizon.rgb + vec3f(sun + 0.02);
    \\    return in.color * light;
    \\}
    \\
    \\@fragment fn fs_main(in: VSOut) -> @location(0) vec4f {
    \\    return vec4f(sw_fog(scene_color(in), in.world), 1.0);
    \\}
    \\
    \\// The fog post effect gives the fog.
    \\@fragment fn fs_no_fog(in: VSOut) -> @location(0) vec4f {
    \\    return vec4f(scene_color(in), 1.0);
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
        // The fog post effect reads the depth.
        const depth = try g.addTarget(.{ .name = "depth", .format = .depth24plus, .usage = .{ .render_attachment = true, .texture_binding = true } });
        fog_effect = try p.addDepthFog(depth);
        try p.setEffectEnabled(fog_effect, false);
        try g.addPass(.{
            .name = "scene",
            .attachments = .{
                // The sky wrote each pixel: keep it.
                .colors = &.{.{ .target = p.hdr, .load_op = .load }},
                .depth = .{ .target = depth },
            },
            .callback = .plain(drawScene),
        });

        // The clouds and the weather draw after the scene, with the scene
        // depth.
        makeShape();
        clouds = try sw_render.Clouds.init(allocator, g, p.hdr, .{
            .depth = depth,
            .shape = .{ .width = shape_size, .height = shape_size, .pixels = &shape_pixels },
            .settings = cloud_settings,
        });
        precipitation = try sw_render.Precipitation.init(allocator, g, p.hdr, .{ .depth = depth });
        buildHeightMap(false);
        try precipitation.?.setHeightMap(heightMap());
        try setWeather(weather);

        // The cloud shadows and the light shafts: post effects that read
        // the depth. Both start off.
        shadow_effect = try clouds.?.addShadowEffect(p, depth);
        try p.setEffectEnabled(shadow_effect, false);
        shafts = try sw_render.LightShafts.init(p, depth, .{});
        try shafts.?.setEnabled(false);
        if (perf_mode) {
            timer = try sw_render.PassTimer.init(allocator, gpu, .{});
            g.setTimer(&timer.?);
        }

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
        pipeline = try makePipeline(gpu, &pipeline_layout, &shader, "fs_main");
        pipeline_no_fog = try makePipeline(gpu, &pipeline_layout, &shader, "fs_no_fog");
        std.log.info("sky: GPU ready. Left/Right: time. Space: clock. C: cube map. G: fog. K: clouds. R: weather. E: fog post effect. H: light shafts. J: cloud shadows. O: soft clouds.", .{});
    }

    fn makePipeline(gpu: *gpu_mod.GPU, layout: *gpu_mod.PipelineLayout, shader: *gpu_mod.ShaderModule, fragment: []const u8) !gpu_mod.RenderPipeline {
        return gpu.createRenderPipeline(.{
            .layout = layout,
            .vertex = .{
                .module = shader,
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
                .module = shader,
                .entry_point = fragment,
                .targets = &[_]gpu_mod.ColorTargetState{.{ .format = post.?.hdr_format }},
            },
            .primitive = .{ .topology = .triangle_list, .cull_mode = .none },
            .depth_stencil = .{ .format = .depth24plus, .depth_write_enabled = true, .depth_compare = .less },
            .multisample = .{ .count = 1 },
        });
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
        if (in.keyPressed(.E)) try setPostFog(!post_fog_on);
        if (in.keyPressed(.H)) try setShafts(!shafts_on);
        if (in.keyPressed(.J)) try setCloudShadows(!shadows_on);
        if (in.keyPressed(.O)) clouds.?.settings.soft = !clouds.?.settings.soft;
        if (in.keyPressed(.K)) {
            clouds_on = !clouds_on;
            if (clouds) |*cl| cl.setEnabled(clouds_on);
        }
        if (in.keyPressed(.R)) try setWeather(switch (weather) {
            .snow => .rain,
            .rain => .none,
            .none => .snow,
        });
        seconds += dt;
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
        if (perf_mode) try setPerfStep();
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
            .time = @floatCast(seconds),
        };
        frame.sky = try s.update();
        const input = weatherInput();
        try clouds.?.update(input);
        try precipitation.?.update(input);
        if (try g.execute(frame)) {
            if (comptime !builtin.cpu.arch.isWasm()) {
                if (check_mode) try checkFrame(ctx, frame);
                if (perf_mode) perfFrame();
            }
            gpu.present();
        }
    }

    pub fn shutdown(ctx: *sw.Context) !void {
        _ = ctx;
        if (graph) |*g| g.setTimer(null);
        if (timer) |*t| t.deinit();
        timer = null;
        if (shafts) |*sh| sh.deinit();
        shafts = null;
        if (precipitation) |*pr| pr.deinit();
        precipitation = null;
        if (clouds) |*cl| cl.deinit();
        clouds = null;
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

fn weatherInput() sw_render.WeatherInput {
    return .{ .camera = eye, .seconds = seconds, .light = sw_render.weather.skyLight(sky.?.state()) };
}

fn setWeather(w: Weather) !void {
    weather = w;
    const pr = &precipitation.?;
    switch (w) {
        .snow => pr.settings = sw_render.PrecipitationSettings.snow(),
        .rain => pr.settings = sw_render.PrecipitationSettings.rain(),
        .none => {},
    }
    pr.setEnabled(w != .none);
}

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
    const fx = x - @floor(x);
    const fy = y - @floor(y);
    const sx = fx * fx * (3 - 2 * fx);
    const sy = fy * fy * (3 - 2 * fy);
    const a = noiseHash(@mod(x0, period), @mod(y0, period));
    const b = noiseHash(@mod(x0 + 1, period), @mod(y0, period));
    const c = noiseHash(@mod(x0, period), @mod(y0 + 1, period));
    const d = noiseHash(@mod(x0 + 1, period), @mod(y0 + 1, period));
    return (a * (1 - sx) + b * sx) * (1 - sy) + (c * (1 - sx) + d * sx) * sy;
}

/// The cloud shape: two octaves of noise that repeat with the image. A
/// texel over the threshold is a cloud box. The RGB is a light grey to
/// white.
fn makeShape() void {
    for (0..shape_size) |y| {
        for (0..shape_size) |x| {
            const fx: f32 = @floatFromInt(x);
            const fy: f32 = @floatFromInt(y);
            const n = 0.65 * valueNoise(fx / 6, fy / 6, shape_size / 6) + 0.35 * valueNoise(fx / 3, fy / 3, shape_size / 3);
            const i = (y * shape_size + x) * 4;
            const grey: u8 = @intFromFloat(225 + 30 * noiseHash(@intCast(x + 7), @intCast(y + 3)));
            shape_pixels[i..][0..4].* = .{ grey, grey, grey, if (n > 0.55) 255 else 0 };
        }
    }
}

fn shapeFilled(_: void, t: [2]i32) bool {
    return shape_pixels[(@as(usize, @intCast(t[1])) * shape_size + @as(usize, @intCast(t[0]))) * 4 + 3] >= 128;
}

fn shapeTint(_: void, t: [2]i32) [3]f32 {
    const i = (@as(usize, @intCast(t[1])) * shape_size + @as(usize, @intCast(t[0]))) * 4;
    return .{ @as(f32, @floatFromInt(shape_pixels[i])) / 255.0, @as(f32, @floatFromInt(shape_pixels[i + 1])) / 255.0, @as(f32, @floatFromInt(shape_pixels[i + 2])) / 255.0 };
}

/// The ground (0) and the top of each box. With `roof`, also the roof of
/// the check.
fn buildHeightMap(roof: bool) void {
    for (0..map_size) |z| {
        for (0..map_size) |x| {
            const wx = -map_half + (@as(f32, @floatFromInt(x)) + 0.5) * map_cell;
            const wz = -map_half + (@as(f32, @floatFromInt(z)) + 0.5) * map_cell;
            var h: f32 = 0;
            for (boxes[0..box_count]) |b| {
                if (@abs(wx - b[0][0]) < b[1][0] / 2 and @abs(wz - b[0][2]) < b[1][2] / 2) h = @max(h, b[1][1]);
            }
            if (roof and wx >= roof_lo[0] and wx < roof_hi[0] and wz >= roof_lo[1] and wz < roof_hi[1]) h = roof_height;
            heights[z * map_size + x] = h;
        }
    }
}

fn heightMap() sw_render.HeightMap {
    return .{ .origin = .{ -map_half, -map_half }, .cell_size = map_cell, .width = map_size, .depth = map_size, .heights = &heights };
}

fn mapHeight(_: void, c: [2]i32) f32 {
    return heights[@as(usize, @intCast(c[1])) * map_size + @as(usize, @intCast(c[0]))];
}

fn setShafts(on: bool) !void {
    shafts_on = on;
    try shafts.?.setEnabled(on);
}

fn setCloudShadows(on: bool) !void {
    shadows_on = on;
    try post.?.setEffectEnabled(shadow_effect, on);
}

/// The fog from the post effect (true) or from the scene shader (false).
fn setPostFog(on: bool) !void {
    post_fog_on = on;
    try post.?.setEffectEnabled(fog_effect, on);
}

fn drawScene(pass: *sw_render.Pass) !void {
    const rp = pass.render.?;
    rp.setPipeline(if (post_fog_on) pipeline_no_fog.? else pipeline.?);
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
    defer box_count = n;
    var x: f32 = 8;
    while (x < 200 and n < max_boxes) : (x += 9) {
        var z: f32 = -4;
        while (z > -60 and n < max_boxes) : (z -= 11) {
            const hash = @as(u32, @intFromFloat(x * 7 + -z * 13)) *% 2654435761;
            const tall = 1.0 + @as(f32, @floatFromInt(hash >> 28)) * 0.6;
            const tint = @as(f32, @floatFromInt((hash >> 20) & 0xff)) / 255.0;
            addBox(.{ x, 0, z }, .{ 1.2, tall, 1.2 }, .{ 0.25 + 0.3 * tint, 0.22, 0.30 - 0.15 * tint });
            boxes[n] = .{ .{ x, 0, z }, .{ 1.2, tall, 1.2 } };
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
// Native check: the sky, the fog, the clouds and the weather against the
// CPU reference
// =============================================================================

const Step = struct {
    name: []const u8,
    time: f32,
    cube: bool = false,
    clouds: bool = false,
    weather: Weather = .none,
    fog: sw_render.Fog = fog,
    /// The fog post effect in place of the shader fog (REQ-GPU-030).
    post_fog: bool = false,
    /// The soft clouds (REQ-GPU-032).
    soft: bool = false,
    /// The cloud shadow effect (REQ-GPU-031).
    cloud_shadows: bool = false,
    /// The light shafts (REQ-GPU-033).
    shafts: bool = false,
    /// The time of the wind and the fall.
    seconds: f64 = check_seconds,
};

/// The wind and fall time of the check.
const check_seconds = 12.25;
/// Denser fog for the weather steps: the far particles fade.
const weather_fog: sw_render.Fog = .{ .start = 4, .end = 40 };

const steps = [_]Step{
    .{ .name = "noon", .time = 0.5 },
    .{ .name = "sunrise", .time = 0.27 },
    .{ .name = "midnight", .time = 0.0 },
    .{ .name = "noon with the cube map", .time = 0.5, .cube = true },
    .{ .name = "clouds at noon", .time = 0.5, .clouds = true },
    .{ .name = "clouds at sunrise", .time = 0.27, .clouds = true },
    .{ .name = "clouds 40 seconds later", .time = 0.5, .clouds = true, .seconds = check_seconds + 40 },
    .{ .name = "snow", .time = 0.5, .weather = .snow, .fog = weather_fog },
    .{ .name = "rain", .time = 0.45, .weather = .rain, .fog = weather_fog },
    .{ .name = "noon with the fog post effect", .time = 0.5, .post_fog = true },
    .{ .name = "sunrise with the fog post effect", .time = 0.27, .post_fog = true },
    .{ .name = "soft clouds at noon", .time = 0.5, .clouds = true, .soft = true },
    .{ .name = "soft clouds at sunrise", .time = 0.27, .clouds = true, .soft = true },
    .{ .name = "cloud shadows in the morning", .time = 0.4, .clouds = true, .cloud_shadows = true },
    .{ .name = "light shafts at sunrise", .time = 0.27, .shafts = true },
    .{ .name = "light shafts with the sun behind the camera", .time = 0.75, .shafts = true },
};

/// The frame of the "sunrise" step, for the light shaft step.
var sunrise_pixels: ?[]u8 = null;

var check_frame: u32 = 0;
var check_ok = true;

/// Each step draws two frames. The check reads the second one.
fn setCheckStep() !void {
    const step = steps[check_frame / 2];
    time_of_day = step.time;
    seconds = step.seconds;
    if (step.cube != cube_on) {
        cube_on = step.cube;
        try sky.?.setCubeMap(if (cube_on) &cube.? else null, .{ 1, 1, 1 });
    }
    sky.?.fog = step.fog;
    if (step.post_fog != post_fog_on) try setPostFog(step.post_fog);
    if (step.shafts != shafts_on) try setShafts(step.shafts);
    if (step.cloud_shadows != shadows_on) try setCloudShadows(step.cloud_shadows);
    clouds.?.settings.soft = step.soft;
    clouds_on = step.clouds;
    clouds.?.setEnabled(step.clouds);
    if (step.weather != weather) {
        try setWeather(step.weather);
        // The roof of the check is in the height map of the weather steps.
        buildHeightMap(step.weather != .none);
        try precipitation.?.setHeightMap(heightMap());
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
    const w = gpu.getSurfaceWidth();
    const h = gpu.getSurfaceHeight();
    if (dump_dir) |dir| dump(ctx, dir, check_frame / 2, pixels, w, h);
    if (std.mem.eql(u8, step.name, "sunrise")) sunrise_pixels = try allocator.dupe(u8, pixels);
    const ok = if (std.mem.eql(u8, step.name, "light shafts at sunrise"))
        checkShafts(step, frame, pixels, w, h)
    else
        checkStep(step, frame, pixels, w, h);
    if (!ok) check_ok = false;
    if (check_frame / 2 + 1 == steps.len) {
        std.log.info("sky: check {s}", .{if (check_ok) "passed" else "FAILED"});
        std.process.exit(if (check_ok) 0 else 1);
    }
}

/// Write the BGRA frame as a PPM image `DIR/sky-N.ppm`.
fn dump(ctx: *sw.Context, dir: []const u8, index: u32, pixels: []const u8, w: u32, h: u32) void {
    const allocator = ctx.allocator();
    const io = ctx.io.?;
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/sky-{d}.ppm", .{ dir, index }) catch return;
    const rgb = allocator.alloc(u8, w * h * 3) catch return;
    defer allocator.free(rgb);
    for (0..w * h) |i| rgb[i * 3 ..][0..3].* = .{ pixels[i * 4 + 2], pixels[i * 4 + 1], pixels[i * 4] };
    var head_buf: [64]u8 = undefined;
    const head = std.fmt.bufPrint(&head_buf, "P6\n{d} {d}\n255\n", .{ w, h }) catch return;
    const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch |err| {
        std.log.err("sky: cannot write {s}: {}", .{ path, err });
        return;
    };
    defer file.close(io);
    file.writeStreamingAll(io, head) catch return;
    file.writeStreamingAll(io, rgb) catch return;
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

fn pixelAt(pixels: []const u8, w: u32, x: u32, y: u32) [3]u8 {
    const i = (y * w + x) * 4;
    return .{ pixels[i + 2], pixels[i + 1], pixels[i] };
}

const V3 = [3]f32;

fn add3(a: V3, b: V3) V3 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}

fn sub3(a: V3, b: V3) V3 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

fn scale3(a: V3, k: f32) V3 {
    return .{ a[0] * k, a[1] * k, a[2] * k };
}

fn mix3(a: V3, b: V3, t: f32) V3 {
    return add3(scale3(a, 1 - t), scale3(b, t));
}

/// The distance to the ground plane along `dir`, or infinity.
fn groundDistance(dir: V3) f32 {
    if (dir[1] >= 0) return std.math.inf(f32);
    const t = -eye[1] / dir[1];
    const hx = eye[0] + dir[0] * t;
    const hz = eye[2] + dir[2] * t;
    if (@abs(hx) >= ground_half or @abs(hz) >= ground_half) return std.math.inf(f32);
    return t;
}

/// The colour of the sky or the ground along `dir`, with no clouds and no
/// particles.
fn backgroundColor(u: sw_render.SkyUniforms, pass_uniforms: sw_render.sky.PassUniforms, dir: V3) V3 {
    const t = groundDistance(dir);
    if (t < std.math.inf(f32)) return groundColor(u, t);
    const c = cube_colors[sw_render.sky.cubeFace(dir)];
    const cube_linear: V3 = .{ srgbDecode(c[0]), srgbDecode(c[1]), srgbDecode(c[2]) };
    return sw_render.sky.passColor(u, pass_uniforms, dir, cube_linear);
}

fn rayAt(frame: sw_render.FrameUniforms, x: f32, y: f32, w: u32, h: u32) V3 {
    const ndc: [2]f32 = .{ x / @as(f32, @floatFromInt(w)) * 2 - 1, 1 - y / @as(f32, @floatFromInt(h)) * 2 };
    return sw_render.sky.viewRay(frame.view, frame.proj, ndc);
}

fn cloudAt(cu: sw_render.weather.CloudUniforms, u: sw_render.SkyUniforms, dir: V3) ?sw_render.weather.CloudSample {
    return sw_render.weather.cloudSample(cu, u, eye[1], dir, {}, shapeFilled, shapeTint);
}

fn sameCloud(a: ?sw_render.weather.CloudSample, b: ?sw_render.weather.CloudSample) bool {
    if (a == null or b == null) return a == null and b == null;
    const p = a.?.hit;
    const q = b.?.hit;
    // Soft clouds: the ray length in the cloud changes fast at the
    // corner of a box.
    if (@abs((p.exit - p.t) - (q.exit - q.t)) > 0.25 * @max(p.exit - p.t, 1)) return false;
    return p.cell[0] == q.cell[0] and p.cell[1] == q.cell[1] and std.mem.eql(f32, &p.normal, &q.normal);
}

fn checkStep(step: Step, frame: sw_render.FrameUniforms, pixels: []const u8, w: u32, h: u32) bool {
    const u = frame.sky;
    const s = sky.?.state();
    const pass_uniforms = sw_render.sky.passUniforms(s, sky.?.settings, if (step.cube) [3]f32{ 1, 1, 1 } else null);
    if (step.weather != .none) return checkWeather(step, frame, pixels, w, h, pass_uniforms);
    const cu = clouds.?.uniforms(weatherInput());
    var ok = true;
    var compared: u32 = 0;
    var bad: u32 = 0;
    var worst: u32 = 0;
    var star_pixels: u32 = 0;
    var ground_pixels: u32 = 0;
    var full_fog: u32 = 0;
    var cloud_pixels: u32 = 0;
    var fogged_clouds: u32 = 0;
    var cloud_edges: u32 = 0;
    var soft_edges: u32 = 0;
    var soft_between: u32 = 0;
    var shadow_pixels: u32 = 0;
    var shadow_edges: u32 = 0;
    var shadow_darker: u32 = 0;
    var shadow_visible: u32 = 0;
    if (step.shafts and sw_render.shafts.sunScreen(frame.view_proj, s.sun_dir) != null) {
        std.log.err("sky: {s}: the sun is not behind the camera", .{step.name});
        ok = false;
    }
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = w / 2 + 20;
        while (x < w) : (x += 1) {
            const fx = @as(f32, @floatFromInt(x)) + 0.5;
            const fy = @as(f32, @floatFromInt(y)) + 0.5;
            const dir = rayAt(frame, fx, fy, w, h);
            var want = backgroundColor(u, pass_uniforms, dir);
            const t = groundDistance(dir);
            if (t < std.math.inf(f32)) {
                ground_pixels += 1;
                if (sw_render.sky.fogAmount(u, t) >= 1.0) full_fog += 1;
                if (step.cloud_shadows) {
                    // A pixel on the edge of a shadow can differ between
                    // the CPU and the GPU: skip it.
                    const sh = shadowAt(cu, fx, fy, frame, w, h);
                    var edge = false;
                    for ([_][2]f32{ .{ -0.45, -0.45 }, .{ 0.45, -0.45 }, .{ -0.45, 0.45 }, .{ 0.45, 0.45 } }) |o| {
                        if (shadowAt(cu, fx + o[0], fy + o[1], frame, w, h) != sh) edge = true;
                    }
                    if (edge) {
                        shadow_edges += 1;
                        continue;
                    }
                    if (sh > 0) {
                        const sun_lit = display(want);
                        want = sw_render.weather.shadowed(want, .{ u.fog_color[0], u.fog_color[1], u.fog_color[2] }, sw_render.sky.fogAmount(u, t), sh);
                        shadow_pixels += 1;
                        // The fog hides a far shadow: test the pixels where
                        // the CPU reference is darker than in the sun.
                        const lit_sum = @as(u32, sun_lit[0]) + sun_lit[1] + sun_lit[2];
                        const ref = display(want);
                        if (@as(u32, ref[0]) + ref[1] + ref[2] + 3 <= lit_sum) {
                            shadow_visible += 1;
                            const got = pixelAt(pixels, w, x, y);
                            if (@as(u32, got[0]) + got[1] + got[2] < lit_sum) shadow_darker += 1;
                        }
                    }
                }
            } else if (sw_render.sky.stars(pass_uniforms, dir) * pass_uniforms.stars[3] > 0.05 and dir[1] > 0.1) {
                star_pixels += 1;
            }
            if (step.clouds and t == std.math.inf(f32)) {
                const c = cloudAt(cu, u, dir);
                // A pixel on the edge of a box can differ by a float bit
                // between the CPU and the GPU. Skip a pixel whose corners
                // see a different box face.
                const corners = [_][2]f32{ .{ -0.45, -0.45 }, .{ 0.45, -0.45 }, .{ -0.45, 0.45 }, .{ 0.45, 0.45 } };
                var edge = false;
                for (corners) |o| {
                    if (!sameCloud(c, cloudAt(cu, u, rayAt(frame, fx + o[0], fy + o[1], w, h)))) edge = true;
                }
                if (edge) {
                    cloud_edges += 1;
                    continue;
                }
                if (c) |cs| {
                    const sky_color = display(want);
                    want = mix3(want, cs.color, cs.alpha);
                    if (step.soft and cs.alpha > 0.1 and cs.alpha < 0.5) {
                        // A soft edge: between the cloud and the sky.
                        soft_edges += 1;
                        const got = pixelAt(pixels, w, x, y);
                        const cloud = display(cs.color);
                        var between = true;
                        for (0..3) |i| {
                            if (@as(u32, got[i]) + 2 < @min(sky_color[i], cloud[i]) or got[i] > @as(u32, @max(sky_color[i], cloud[i])) + 2) between = false;
                        }
                        if (between) soft_between += 1;
                    }
                    if (cs.alpha > 0.3) cloud_pixels += 1;
                    const f = sw_render.sky.fogAmount(u, cs.hit.t);
                    if (f > 0.1 and f < 0.9) fogged_clouds += 1;
                }
            }
            const got = pixelAt(pixels, w, x, y);
            const d = maxDiff(got, display(want));
            worst = @max(worst, d);
            if (d > 3) {
                if (bad < 5) std.log.err("sky: {s}: pixel ({d}, {d}) is {any}, the CPU reference is {any}", .{ step.name, x, y, got, display(want) });
                bad += 1;
            }
            compared += 1;
        }
    }
    std.log.info("sky: {s}: {d} pixels, {d} ground, {d} in full fog, {d} star pixels, {d} cloud pixels ({d} in part fog, {d} edges skipped), {d} differ, largest difference {d}", .{ step.name, compared, ground_pixels, full_fog, star_pixels, cloud_pixels, fogged_clouds, cloud_edges, bad, worst });
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
    // The cloud steps must test many cloud pixels, some of them in fog, and
    // only a few edges.
    // A soft cloud has more edges: the ray length in the cloud also
    // changes at the corners of the boxes.
    if (step.clouds and (cloud_pixels < 2000 or fogged_clouds < 500 or cloud_edges > compared / @as(u32, if (step.soft) 10 else 20))) {
        std.log.err("sky: {s}: {d} cloud pixels, {d} in part fog, {d} edges", .{ step.name, cloud_pixels, fogged_clouds, cloud_edges });
        ok = false;
    }
    if (step.soft) {
        std.log.info("sky: {s}: {d} soft edge pixels, {d} between the cloud and the sky colour", .{ step.name, soft_edges, soft_between });
        if (soft_edges < 200 or soft_between != soft_edges) {
            std.log.err("sky: {s}: the soft edges are not between the cloud and the sky colour", .{step.name});
            ok = false;
        }
    }
    if (step.cloud_shadows) {
        std.log.info("sky: {s}: {d} ground pixels in a cloud shadow ({d} edges skipped), {d} of {d} visible shadow pixels darker than in the sun", .{ step.name, shadow_pixels, shadow_edges, shadow_darker, shadow_visible });
        if (shadow_visible < 300 or shadow_darker != shadow_visible) {
            std.log.err("sky: {s}: the cloud shadows are not darker than the sunlit ground", .{step.name});
            ok = false;
        }
    }
    if (step.clouds and step.seconds == check_seconds and !step.soft and !step.cloud_shadows) {
        // One cloud pixel, in the log: a box face on the right of the
        // screen. 40 seconds later the wind moved the box away.
        const px = w / 2 + 120;
        const py: u32 = 130;
        const dir = rayAt(frame, @as(f32, @floatFromInt(px)) + 0.5, @as(f32, @floatFromInt(py)) + 0.5, w, h);
        if (cloudAt(cu, u, dir)) |c| {
            const want = display(mix3(backgroundColor(u, pass_uniforms, dir), c.color, c.alpha));
            const got = pixelAt(pixels, w, px, py);
            std.log.info("sky: {s}: pixel ({d}, {d}) is {any}: a cloud at distance {d:.1}, texel {any}, alpha {d:.2}; the CPU reference is {any}", .{ step.name, px, py, got, c.hit.t, c.hit.cell, c.alpha, want });
            if (maxDiff(got, want) > 3) ok = false;
        } else {
            std.log.err("sky: {s}: pixel ({d}, {d}) has no cloud", .{ step.name, px, py });
            ok = false;
        }
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
        const got = pixelAt(pixels, w, px, py);
        std.log.info("sky: sunrise: the sun is at pixel ({d}, {d}), colour {any}", .{ px, py, got });
        if (got[0] < 230 or got[1] < 200) {
            std.log.err("sky: sunrise: the sun is not bright", .{});
            ok = false;
        }
    }
    return ok;
}

/// The cloud shadow of the ground point at the pixel (x, y), or 0 for the
/// sky.
fn shadowAt(cu: sw_render.weather.CloudUniforms, x: f32, y: f32, frame: sw_render.FrameUniforms, w: u32, h: u32) f32 {
    const dir = rayAt(frame, x, y, w, h);
    const t = groundDistance(dir);
    if (t == std.math.inf(f32)) return 0;
    return sw_render.weather.cloudShadow(cu, eye, add3(eye, scale3(dir, t)), {}, shapeFilled);
}

/// The light shafts at sunrise: the pixels under the sun are brighter
/// than in the frame of the "sunrise" step, with no shafts.
fn checkShafts(step: Step, frame: sw_render.FrameUniforms, pixels: []const u8, w: u32, h: u32) bool {
    const before = sunrise_pixels orelse {
        std.log.err("sky: {s}: no frame of the sunrise step", .{step.name});
        return false;
    };
    const sun = sw_render.shafts.sunScreen(frame.view_proj, sky.?.state().sun_dir) orelse {
        std.log.err("sky: {s}: the sun is behind the camera", .{step.name});
        return false;
    };
    const sx: u32 = @intFromFloat(sun[0] * @as(f32, @floatFromInt(w)));
    const sy: u32 = @intFromFloat(sun[1] * @as(f32, @floatFromInt(h)));
    var brighter: u32 = 0;
    var tested: u32 = 0;
    var largest: i32 = 0;
    var dy: u32 = 20;
    while (dy <= 200 and sy + dy < h) : (dy += 10) {
        const a = pixelAt(before, w, sx, sy + dy);
        const b = pixelAt(pixels, w, sx, sy + dy);
        const gain = @as(i32, b[0]) + b[1] + b[2] - (@as(i32, a[0]) + a[1] + a[2]);
        largest = @max(largest, gain);
        tested += 1;
        if (gain >= 3) brighter += 1;
    }
    std.log.info("sky: {s}: the sun is at ({d}, {d}). {d} of {d} pixels under it are brighter than with no shafts, largest gain {d}", .{ step.name, sx, sy, brighter, tested, largest });
    if (tested == 0 or brighter * 2 < tested) {
        std.log.err("sky: {s}: the light shafts do not make the pixels under the sun brighter", .{step.name});
        return false;
    }
    return true;
}

// =============================================================================
// Native perf: the GPU time of each effect at 1920 by 1080
// =============================================================================

const PerfStep = struct {
    name: []const u8,
    time: f32,
    soft: bool = false,
    cloud_shadows: bool = false,
    shafts: bool = false,
};

const perf_steps = [_]PerfStep{
    .{ .name = "box clouds", .time = 0.5 },
    .{ .name = "soft clouds", .time = 0.5, .soft = true },
    .{ .name = "cloud shadows", .time = 0.5, .cloud_shadows = true },
    .{ .name = "light shafts", .time = 0.27, .shafts = true },
};
const perf_warmup = 5;
const perf_frames = 30;
const perf_passes = [_][]const u8{ "sw_clouds", "sw_cloud_shadows", "sw_light_shafts", "scene", "sw_post_tonemap" };
var perf_frame: u32 = 0;
var perf_sums: [perf_passes.len]f64 = @splat(0);
var perf_total: f64 = 0;

fn setPerfStep() !void {
    const step = perf_steps[perf_frame / (perf_warmup + perf_frames)];
    time_of_day = step.time;
    seconds = check_seconds;
    sky.?.fog = fog;
    clouds_on = true;
    clouds.?.setEnabled(true);
    clouds.?.settings.soft = step.soft;
    if (weather != .none) try setWeather(.none);
    if (step.shafts != shafts_on) try setShafts(step.shafts);
    if (step.cloud_shadows != shadows_on) try setCloudShadows(step.cloud_shadows);
}

fn perfFrame() void {
    defer perf_frame += 1;
    const per = perf_warmup + perf_frames;
    const step = perf_steps[perf_frame / per];
    const t = &(timer orelse {
        std.log.err("sky: --perf needs GPU timestamps", .{});
        std.process.exit(1);
    });
    if (perf_frame % per >= perf_warmup) {
        for (perf_passes, 0..) |name, i| perf_sums[i] += t.find(name) orelse 0;
        perf_total += t.total();
    }
    if (perf_frame % per + 1 < per) return;
    const n: f64 = perf_frames;
    std.log.info("sky: perf {s}: all passes {d:.3} ms. clouds {d:.3} ms, cloud shadows {d:.3} ms, light shafts {d:.3} ms, scene {d:.3} ms, tonemap {d:.3} ms", .{
        step.name,        perf_total / n,   perf_sums[0] / n,
        perf_sums[1] / n, perf_sums[2] / n, perf_sums[3] / n,
        perf_sums[4] / n,
    });
    perf_sums = @splat(0);
    perf_total = 0;
    if (perf_frame / per + 1 == perf_steps.len) std.process.exit(0);
}

/// A particle on the screen: the centre pixel and a radius that holds all
/// of its pixels.
const ScreenParticle = struct {
    index: u32,
    x: f32,
    y: f32,
    radius: f32,
    active: bool,
    /// The centre in world space.
    world: V3,
    /// The radius after the pixel minimum, and the opacity factor.
    size: f32,
    alpha: f32,
    /// The ground height under the centre.
    ground: f32,
};

/// The view-space position of the world point `p`.
fn toView(v: [16]f32, p: V3) V3 {
    return .{
        v[0] * p[0] + v[4] * p[1] + v[8] * p[2] + v[12],
        v[1] * p[0] + v[5] * p[1] + v[9] * p[2] + v[13],
        v[2] * p[0] + v[6] * p[1] + v[10] * p[2] + v[14],
    };
}

/// The pixel position of the view-space point `q`.
fn toPixel(proj: [16]f32, q: V3, w: u32, h: u32) [2]f32 {
    const nx = (proj[0] * q[0] + proj[8] * q[2]) / -q[2];
    const ny = (proj[5] * q[1] + proj[9] * q[2]) / -q[2];
    return .{ (nx + 1) * 0.5 * @as(f32, @floatFromInt(w)), (1 - ny) * 0.5 * @as(f32, @floatFromInt(h)) };
}

fn checkWeather(step: Step, frame: sw_render.FrameUniforms, pixels: []const u8, w: u32, h: u32, pass_uniforms: sw_render.sky.PassUniforms) bool {
    const weather_mod = sw_render.weather;
    const u = frame.sky;
    const pr = &precipitation.?;
    const pu = pr.uniforms(weatherInput());
    const snow = step.weather == .snow;
    const focal = frame.proj[5] * @as(f32, @floatFromInt(h)) * 0.5;
    const v = frame.view;
    const right: V3 = .{ v[0], v[4], v[8] };
    const up: V3 = .{ v[1], v[5], v[9] };
    const back: V3 = .{ v[2], v[6], v[10] };

    // The screen position of each particle in front of the camera.
    var list: std.ArrayList(ScreenParticle) = .empty;
    defer list.deinit(std.heap.page_allocator);
    const n = pr.settings.active();
    var stopped_in_view: u32 = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const p = weather_mod.particle(pu, i);
        const world = add3(eye, p.rel);
        const q = toView(v, world);
        if (q[2] > -0.2 or p.fade <= 0) continue;
        const g = weather_mod.groundAt(pu, p.rel[0], p.rel[2], {}, mapHeight);
        const ps = weather_mod.pixelSize(pu, p.size, @sqrt(sw_render.sky.dot(p.rel, p.rel)), focal);
        const c = toPixel(frame.proj, q, w, h);
        var radius = ps[0] * focal / -q[2] * std.math.sqrt2 + 2;
        if (!snow) {
            // The streak: half its length along the fall direction.
            const vel: V3 = .{ pu.wind[0], -pu.motion[1] * p.speed, pu.wind[2] };
            const tip = toPixel(frame.proj, toView(v, add3(world, scale3(vel, 0.5 * pu.wind[3]))), w, h);
            radius += @sqrt((tip[0] - c[0]) * (tip[0] - c[0]) + (tip[1] - c[1]) * (tip[1] - c[1]));
        }
        const active = eye[1] + p.rel[1] >= g;
        if (!active and world[1] > 0) stopped_in_view += 1;
        list.append(std.heap.page_allocator, .{
            .index = i,
            .x = c[0],
            .y = c[1],
            .radius = radius,
            .active = active,
            .world = world,
            .size = ps[0],
            .alpha = p.fade * pu.shape[1] * ps[1],
            .ground = g,
        }) catch return false;
    }

    var ok = true;
    var stopped_checked: u32 = 0;
    var active_checked: u32 = 0;
    var bad: u32 = 0;
    var worst: u32 = 0;
    const x_min: f32 = @floatFromInt(w / 2 + 20);
    for (list.items) |a| {
        const px = @floor(a.x);
        const py = @floor(a.y);
        if (px < x_min or px >= @as(f32, @floatFromInt(w)) or py < 0 or py >= @as(f32, @floatFromInt(h))) continue;
        // Skip a particle that another drawn particle can cover.
        var covered = false;
        for (list.items) |b| {
            if (b.index == a.index or !b.active) continue;
            const dx = b.x - a.x;
            const dy = b.y - a.y;
            const reach = b.radius + if (a.active) a.radius else 1.5;
            if (dx * dx + dy * dy < reach * reach) {
                covered = true;
                break;
            }
        }
        if (covered) continue;
        const ux: u32 = @intFromFloat(px);
        const uy: u32 = @intFromFloat(py);
        const dir = rayAt(frame, px + 0.5, py + 0.5, w, h);
        const background = backgroundColor(u, pass_uniforms, dir);
        const got = pixelAt(pixels, w, ux, uy);
        var want = background;
        if (a.active) {
            if (!snow) continue;
            // The flake plane faces the camera. The pixel ray meets it at `t`.
            const t = sw_render.sky.dot(sub3(a.world, eye), back) / sw_render.sky.dot(dir, back);
            if (t >= groundDistance(dir)) continue;
            const hit = add3(eye, scale3(dir, t));
            if (hit[1] < a.ground) continue;
            const off = sub3(hit, a.world);
            const uv: [2]f32 = .{ sw_render.sky.dot(off, right) / a.size, sw_render.sky.dot(off, up) / a.size };
            const f = weather_mod.snowFragment(pu, uv, a.alpha);
            const alpha = f[3] * (1 - sw_render.sky.fogAmount(u, t));
            if (alpha <= 0.001) continue;
            want = mix3(background, sw_render.sky.applyFog(u, .{ f[0], f[1], f[2] }, t), alpha);
            active_checked += 1;
        } else {
            stopped_checked += 1;
        }
        const d = maxDiff(got, display(want));
        worst = @max(worst, d);
        if (d > 4) {
            if (bad < 5) std.log.err("sky: {s}: particle {d} ({s}) at pixel ({d}, {d}) is {any}, the CPU reference is {any}", .{ step.name, a.index, if (a.active) "falls" else "under the height map", ux, uy, got, display(want) });
            bad += 1;
        }
    }

    // Rain: count the pixels that the streaks change.
    var changed: u32 = 0;
    if (!snow) {
        var y: u32 = 0;
        while (y < h) : (y += 2) {
            var x: u32 = w / 2 + 20;
            while (x < w) : (x += 2) {
                const dir = rayAt(frame, @as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5, w, h);
                if (maxDiff(pixelAt(pixels, w, x, y), display(backgroundColor(u, pass_uniforms, dir))) > 6) changed += 1;
            }
        }
    }

    std.log.info("sky: {s}: {d} particles in view, {d} under the height map above the ground; checked {d} falling and {d} stopped, {d} differ, largest difference {d}, {d} rain pixels", .{ step.name, list.items.len, stopped_in_view, active_checked, stopped_checked, bad, worst, changed });
    if (bad > 0) ok = false;
    if (stopped_checked < 20 or stopped_in_view < 50) {
        std.log.err("sky: {s}: too few particles under the height map to check", .{step.name});
        ok = false;
    }
    if (snow and active_checked < 20) {
        std.log.err("sky: {s}: too few falling flakes to check", .{step.name});
        ok = false;
    }
    if (!snow and changed < 100) {
        std.log.err("sky: {s}: the rain changes too few pixels", .{step.name});
        ok = false;
    }
    return ok;
}
