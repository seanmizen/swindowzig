//! The plan of the clouds and the precipitation, with no GPU code: the
//! uniforms, the WGSL of the two passes, and the CPU reference of each
//! shader function. `weather.zig` makes the passes. The tests run with no
//! GPU (REQ-GPU-020, REQ-GPU-021).
//!
//! The cloud layer is a slab of world space from `CloudSettings.bottom` to
//! `bottom + thickness`. The game gives a shape image. Each texel of the
//! image is one cell of `cell_size` world units, and the image repeats over
//! the world. A cell with alpha 0.5 or more is a cloud box. The pass walks
//! each view ray through the cells of the slab (a 2D grid walk) and stops at
//! the first box. The wind moves the shape over the world.
//!
//! The precipitation is a set of particles in a column around the camera.
//! The vertex shader makes the position of each particle from its index and
//! the time, so the CPU sends no particle data. A particle stays at its world
//! position while the camera moves, and the column wraps around the camera.
//! A height map from the game gives the ground height of each world cell. A
//! particle under the ground does not draw.
//!
//! Both passes take their light from the sky (`skyLight`), and both use the
//! fog of the shared WGSL prefix.

const std = @import("std");
const wgsl = @import("wgsl.zig");
const sky_plan = @import("sky_plan.zig");

pub const Vec3 = [3]f32;
pub const SkyUniforms = wgsl.SkyUniforms;

const smoothstep = sky_plan.smoothstep;
const dot = sky_plan.dot;

// =============================================================================
// The light
// =============================================================================

/// The light of the clouds and the precipitation, in linear RGB.
pub const Light = struct {
    /// The light from the whole sky.
    ambient: Vec3 = .{ 0.4, 0.45, 0.55 },
    /// The light from the sun. Black at night.
    sun: Vec3 = .{ 1, 1, 1 },
    /// The unit vector to the sun.
    sun_dir: Vec3 = .{ 0, 1, 0 },
};

/// The light of the sky state `s`: the mean of the zenith and the horizon
/// colours as the ambient light, and the colour of the sun disc at a
/// brightness of 1, times the daylight.
pub fn skyLight(s: sky_plan.State) Light {
    var ambient: Vec3 = undefined;
    for (0..3) |i| ambient[i] = 0.5 * (s.zenith[i] + s.horizon[i]);
    const peak = @max(s.sun_color[0], @max(s.sun_color[1], s.sun_color[2]));
    var sun: Vec3 = .{ 0, 0, 0 };
    if (peak > 1e-6) {
        for (0..3) |i| sun[i] = s.sun_color[i] / peak * s.daylight;
    }
    return .{ .ambient = ambient, .sun = sun, .sun_dir = s.sun_dir };
}

/// What the passes need from the game in each frame.
pub const FrameInput = struct {
    /// The camera position. It must be `FrameUniforms.camera_pos`.
    camera: Vec3,
    /// The time in seconds. The wind and the fall use it. A replay gives
    /// the same frames with the same times.
    seconds: f64,
    light: Light = .{},
};

/// `x` modulo `m`, in 0 to m. `m` is more than 0.
pub fn wrap(x: f32, m: f32) f32 {
    return x - m * @floor(x / m);
}

fn wrap64(x: f64, m: f64) f64 {
    const w = x - m * @floor(x / m);
    return if (w >= m) 0 else w;
}

// =============================================================================
// The clouds
// =============================================================================

pub const CloudSettings = struct {
    /// The world height of the bottom of the cloud layer.
    bottom: f32 = 128,
    /// The height of the cloud boxes.
    thickness: f32 = 4,
    /// The world size of one texel of the shape image.
    cell_size: f32 = 12,
    /// The wind, in world units each second, along X and Z.
    wind: [2]f32 = .{ 1.5, 0 },
    /// The cloud colour in linear RGB, before the light. The shape image
    /// RGB multiplies it.
    color: Vec3 = .{ 1, 1, 1 },
    /// The opacity of the clouds, 0 to 1.
    opacity: f32 = 0.85,
    /// The shade of the bottom faces and of the side faces. The top faces
    /// have the shade 1.
    bottom_shade: f32 = 0.7,
    side_shade: f32 = 0.85,
    /// The clouds fade out from this distance to `fade_end`. The pass
    /// stops the ray walk at `fade_end`.
    fade_start: f32 = 256,
    fade_end: f32 = 512,
};

/// The uniforms of the cloud pass, with the memory layout of `SwClouds` in
/// `cloud_shader`.
pub const CloudUniforms = extern struct {
    /// x: bottom, y: top, z: cell size, w: opacity.
    layer: [4]f32 = .{ 128, 132, 12, 0.85 },
    /// xy: the shape texel of the camera, after the wind. zw: the camera
    /// position in that texel along X and Z, in world units.
    camera: [4]f32 = .{ 0, 0, 0, 0 },
    /// x: fade start, y: fade end, z: the most grid steps, w: not used.
    fade: [4]f32 = .{ 256, 512, 64, 0 },
    /// rgb: the cloud colour. w: the bottom shade.
    color: [4]f32 = .{ 1, 1, 1, 0.7 },
    /// rgb: the ambient light. w: the side shade.
    ambient: [4]f32 = .{ 0, 0, 0, 0.85 },
    /// rgb: the sun light. w: not used.
    sun: [4]f32 = .{ 0, 0, 0, 0 },
    /// xyz: the unit vector to the sun. w: not used.
    sun_dir: [4]f32 = .{ 0, 1, 0, 0 },
    /// x: shape width, y: shape height, in texels. zw: not used.
    shape: [4]f32 = .{ 1, 1, 0, 0 },
};

/// The most grid steps of one ray. A ray that crosses more cells before
/// `fade_end` stops early.
pub const max_cloud_steps: u32 = 256;

/// The cloud uniforms of one frame. `width` and `height` are the size of
/// the shape image, in texels.
pub fn cloudUniforms(settings: CloudSettings, width: u32, height: u32, input: FrameInput) CloudUniforms {
    const cs: f64 = settings.cell_size;
    const span_x = cs * @as(f64, @floatFromInt(width));
    const span_z = cs * @as(f64, @floatFromInt(height));
    // The wind moves the shape: a world point is at the shape position
    // `(p - wind * t) / cell`. f64 keeps the precision for a large time.
    const off_x = wrap64(@as(f64, settings.wind[0]) * input.seconds, span_x);
    const off_z = wrap64(@as(f64, settings.wind[1]) * input.seconds, span_z);
    const local_x = wrap64(@as(f64, input.camera[0]) - off_x, span_x);
    const local_z = wrap64(@as(f64, input.camera[2]) - off_z, span_z);
    const cell_x = @floor(local_x / cs);
    const cell_z = @floor(local_z / cs);
    const steps = @min(@ceil(settings.fade_end / settings.cell_size * 1.5) + 2.0, @as(f32, @floatFromInt(max_cloud_steps)));
    const l = input.light;
    return .{
        .layer = .{ settings.bottom, settings.bottom + settings.thickness, settings.cell_size, std.math.clamp(settings.opacity, 0, 1) },
        .camera = .{ @floatCast(cell_x), @floatCast(cell_z), @floatCast(local_x - cell_x * cs), @floatCast(local_z - cell_z * cs) },
        .fade = .{ settings.fade_start, settings.fade_end, steps, 0 },
        .color = .{ settings.color[0], settings.color[1], settings.color[2], settings.bottom_shade },
        .ambient = .{ l.ambient[0], l.ambient[1], l.ambient[2], settings.side_shade },
        .sun = .{ l.sun[0], l.sun[1], l.sun[2], 0 },
        .sun_dir = .{ l.sun_dir[0], l.sun_dir[1], l.sun_dir[2], 0 },
        .shape = .{ @floatFromInt(width), @floatFromInt(height), 0, 0 },
    };
}

/// The first cloud box along a view ray.
pub const CloudHit = struct {
    /// The distance from the camera.
    t: f32,
    /// The face normal. Zero when the camera is in a box.
    normal: Vec3,
    /// The shape texel of the box.
    cell: [2]i32,
};

/// The shape texel of the grid cell `c`, with the image repeated.
pub fn shapeTexel(u: CloudUniforms, c: [2]i32) [2]i32 {
    const w: i32 = @intFromFloat(u.shape[0]);
    const h: i32 = @intFromFloat(u.shape[1]);
    return .{ @mod(c[0], w), @mod(c[1], h) };
}

/// `sw_cloud_hit`: walk the ray from the camera (height `cam_y`) along
/// the unit `dir` through the cells of the slab. `filled(ctx, texel)` gives
/// true for a cloud box.
pub fn cloudHit(u: CloudUniforms, cam_y: f32, dir: Vec3, ctx: anytype, comptime filled: fn (@TypeOf(ctx), [2]i32) bool) ?CloudHit {
    const bottom = u.layer[0];
    const top = u.layer[1];
    const cs = u.layer[2];
    var t0: f32 = 0;
    var t1: f32 = u.fade[1];
    var n: Vec3 = .{ 0, 0, 0 };
    if (@abs(dir[1]) < 1e-6) {
        if (cam_y < bottom or cam_y >= top) return null;
    } else {
        const ta = (bottom - cam_y) / dir[1];
        const tb = (top - cam_y) / dir[1];
        const tn = @min(ta, tb);
        if (tn > 0) {
            t0 = tn;
            n = .{ 0, if (dir[1] > 0) -1 else 1, 0 };
        }
        t1 = @min(@max(ta, tb), t1);
    }
    if (t0 >= t1) return null;
    const px = u.camera[2] + dir[0] * t0;
    const pz = u.camera[3] + dir[2] * t0;
    var cx: i32 = @intFromFloat(@floor(px / cs));
    var cz: i32 = @intFromFloat(@floor(pz / cs));
    const sx: i32 = if (dir[0] >= 0) 1 else -1;
    const sz: i32 = if (dir[2] >= 0) 1 else -1;
    const inf = std.math.inf(f32);
    var tdx = inf;
    var tmx = inf;
    if (@abs(dir[0]) > 1e-8) {
        tdx = cs / @abs(dir[0]);
        const bx = (@as(f32, @floatFromInt(cx)) + @as(f32, if (sx > 0) 1 else 0)) * cs;
        tmx = t0 + (bx - px) / dir[0];
    }
    var tdz = inf;
    var tmz = inf;
    if (@abs(dir[2]) > 1e-8) {
        tdz = cs / @abs(dir[2]);
        const bz = (@as(f32, @floatFromInt(cz)) + @as(f32, if (sz > 0) 1 else 0)) * cs;
        tmz = t0 + (bz - pz) / dir[2];
    }
    const ox: i32 = @intFromFloat(u.camera[0]);
    const oz: i32 = @intFromFloat(u.camera[1]);
    var t = t0;
    const steps: u32 = @intFromFloat(u.fade[2]);
    var i: u32 = 0;
    while (i < steps) : (i += 1) {
        const texel = shapeTexel(u, .{ ox + cx, oz + cz });
        if (filled(ctx, texel)) return .{ .t = t, .normal = n, .cell = texel };
        if (tmx < tmz) {
            t = tmx;
            cx += sx;
            tmx += tdx;
            n = .{ @floatFromInt(-sx), 0, 0 };
        } else {
            t = tmz;
            cz += sz;
            tmz += tdz;
            n = .{ 0, 0, @floatFromInt(-sz) };
        }
        if (t >= t1) return null;
    }
    return null;
}

/// `sw_cloud_shade`: the lit colour of a box face with the normal `n`.
/// `tint` is the RGB of the shape texel.
pub fn cloudShade(u: CloudUniforms, n: Vec3, tint: Vec3) Vec3 {
    const shade: f32 = if (n[1] > 0.5) 1.0 else if (n[1] < -0.5) u.color[3] else if (n[0] != 0 or n[2] != 0) u.ambient[3] else 1.0;
    const diffuse = 0.35 + 0.65 * @max(dot(n, .{ u.sun_dir[0], u.sun_dir[1], u.sun_dir[2] }), 0.0);
    var c: Vec3 = undefined;
    for (0..3) |i| c[i] = u.color[i] * tint[i] * shade * (u.ambient[i] + u.sun[i] * diffuse);
    return c;
}

/// `sw_cloud_alpha`: the opacity at the distance `t`.
pub fn cloudAlpha(u: CloudUniforms, t: f32) f32 {
    return u.layer[3] * (1.0 - smoothstep(u.fade[0], u.fade[1], t));
}

/// The cloud colour and alpha of the pixel with the view ray `dir`, after
/// the fog. The colour is not multiplied by the alpha. The pass blends it
/// over the target with `alpha`.
pub const CloudSample = struct {
    color: Vec3,
    alpha: f32,
    hit: CloudHit,
};

/// The CPU reference of the cloud pass `fs_main` along `dir`. `tint(ctx,
/// texel)` gives the RGB of a shape texel.
pub fn cloudSample(
    u: CloudUniforms,
    sky: SkyUniforms,
    cam_y: f32,
    dir: Vec3,
    ctx: anytype,
    comptime filled: fn (@TypeOf(ctx), [2]i32) bool,
    comptime tint: fn (@TypeOf(ctx), [2]i32) Vec3,
) ?CloudSample {
    const hit = cloudHit(u, cam_y, dir, ctx, filled) orelse return null;
    const lit = cloudShade(u, hit.normal, tint(ctx, hit.cell));
    return .{ .color = sky_plan.applyFog(sky, lit, hit.t), .alpha = cloudAlpha(u, hit.t), .hit = hit };
}

/// The cloud pass: one triangle over the target. Group 0 has the frame
/// uniforms, group 1 the cloud uniforms and the shape texture. `fs_main`
/// writes the depth of the box, so the scene depth hides the clouds.
/// `fs_flat` writes no depth, for a pass with no depth target.
pub const cloud_shader = wgsl.shader(
    \\struct SwClouds {
    \\    layer: vec4<f32>,
    \\    camera: vec4<f32>,
    \\    fade: vec4<f32>,
    \\    color: vec4<f32>,
    \\    ambient: vec4<f32>,
    \\    sun: vec4<f32>,
    \\    sun_dir: vec4<f32>,
    \\    shape: vec4<f32>,
    \\}
    \\@group(1) @binding(0) var<uniform> sw_clouds: SwClouds;
    \\@group(1) @binding(1) var sw_cloud_shape: texture_2d<f32>;
    \\
    \\struct SwCloudHit {
    \\    t: f32,
    \\    found: bool,
    \\    normal: vec3<f32>,
    \\    texel: vec2<i32>,
    \\}
    \\
    \\@vertex fn vs_main(@builtin(vertex_index) vi: u32) -> @builtin(position) vec4<f32> {
    \\    let x = select(-1.0, 3.0, vi == 1u);
    \\    let y = select(-1.0, 3.0, vi == 2u);
    \\    return vec4<f32>(x, y, 0.0, 1.0);
    \\}
    \\
    \\fn sw_cloud_texel(c: vec2<i32>) -> vec2<i32> {
    \\    let size = vec2<i32>(sw_clouds.shape.xy);
    \\    return ((c % size) + size) % size;
    \\}
    \\
    \\fn sw_cloud_hit(cam_y: f32, dir: vec3<f32>) -> SwCloudHit {
    \\    var hit: SwCloudHit;
    \\    hit.found = false;
    \\    let bottom = sw_clouds.layer.x;
    \\    let top = sw_clouds.layer.y;
    \\    let cs = sw_clouds.layer.z;
    \\    var t0 = 0.0;
    \\    var t1 = sw_clouds.fade.y;
    \\    var n = vec3<f32>(0.0);
    \\    if (abs(dir.y) < 1e-6) {
    \\        if (cam_y < bottom || cam_y >= top) {
    \\            return hit;
    \\        }
    \\    } else {
    \\        let ta = (bottom - cam_y) / dir.y;
    \\        let tb = (top - cam_y) / dir.y;
    \\        let tn = min(ta, tb);
    \\        if (tn > 0.0) {
    \\            t0 = tn;
    \\            n = vec3<f32>(0.0, select(1.0, -1.0, dir.y > 0.0), 0.0);
    \\        }
    \\        t1 = min(max(ta, tb), t1);
    \\    }
    \\    if (t0 >= t1) {
    \\        return hit;
    \\    }
    \\    let px = sw_clouds.camera.z + dir.x * t0;
    \\    let pz = sw_clouds.camera.w + dir.z * t0;
    \\    var cx = i32(floor(px / cs));
    \\    var cz = i32(floor(pz / cs));
    \\    let sx = select(-1, 1, dir.x >= 0.0);
    \\    let sz = select(-1, 1, dir.z >= 0.0);
    \\    var tdx = 3.0e38;
    \\    var tmx = 3.0e38;
    \\    if (abs(dir.x) > 1e-8) {
    \\        tdx = cs / abs(dir.x);
    \\        let bx = (f32(cx) + select(0.0, 1.0, sx > 0)) * cs;
    \\        tmx = t0 + (bx - px) / dir.x;
    \\    }
    \\    var tdz = 3.0e38;
    \\    var tmz = 3.0e38;
    \\    if (abs(dir.z) > 1e-8) {
    \\        tdz = cs / abs(dir.z);
    \\        let bz = (f32(cz) + select(0.0, 1.0, sz > 0)) * cs;
    \\        tmz = t0 + (bz - pz) / dir.z;
    \\    }
    \\    let origin = vec2<i32>(sw_clouds.camera.xy);
    \\    var t = t0;
    \\    let steps = u32(sw_clouds.fade.z);
    \\    for (var i = 0u; i < steps; i++) {
    \\        let texel = sw_cloud_texel(origin + vec2<i32>(cx, cz));
    \\        if (textureLoad(sw_cloud_shape, texel, 0).a >= 0.5) {
    \\            hit.found = true;
    \\            hit.t = t;
    \\            hit.normal = n;
    \\            hit.texel = texel;
    \\            return hit;
    \\        }
    \\        if (tmx < tmz) {
    \\            t = tmx;
    \\            cx += sx;
    \\            tmx += tdx;
    \\            n = vec3<f32>(f32(-sx), 0.0, 0.0);
    \\        } else {
    \\            t = tmz;
    \\            cz += sz;
    \\            tmz += tdz;
    \\            n = vec3<f32>(0.0, 0.0, f32(-sz));
    \\        }
    \\        if (t >= t1) {
    \\            return hit;
    \\        }
    \\    }
    \\    return hit;
    \\}
    \\
    \\fn sw_cloud_shade(n: vec3<f32>, tint: vec3<f32>) -> vec3<f32> {
    \\    var shade = 1.0;
    \\    if (n.y < -0.5) {
    \\        shade = sw_clouds.color.w;
    \\    } else if (n.y <= 0.5 && (n.x != 0.0 || n.z != 0.0)) {
    \\        shade = sw_clouds.ambient.w;
    \\    }
    \\    let diffuse = 0.35 + 0.65 * max(dot(n, sw_clouds.sun_dir.xyz), 0.0);
    \\    return sw_clouds.color.rgb * tint * shade * (sw_clouds.ambient.rgb + sw_clouds.sun.rgb * diffuse);
    \\}
    \\
    \\fn sw_cloud_alpha(t: f32) -> f32 {
    \\    return sw_clouds.layer.w * (1.0 - smoothstep(sw_clouds.fade.x, sw_clouds.fade.y, t));
    \\}
    \\
    \\struct SwCloudOut {
    \\    @location(0) color: vec4<f32>,
    \\    @builtin(frag_depth) depth: f32,
    \\}
    \\
    \\// The cloud colour and alpha along `dir`. A negative alpha: no cloud.
    \\fn sw_cloud_pixel(dir: vec3<f32>, out_t: ptr<function, f32>) -> vec4<f32> {
    \\    let cam = sw_frame.camera_pos.xyz;
    \\    let hit = sw_cloud_hit(cam.y, dir);
    \\    if (!hit.found) {
    \\        return vec4<f32>(0.0, 0.0, 0.0, -1.0);
    \\    }
    \\    let tint = textureLoad(sw_cloud_shape, hit.texel, 0).rgb;
    \\    let lit = sw_cloud_shade(hit.normal, tint);
    \\    *out_t = hit.t;
    \\    return vec4<f32>(sw_fog(lit, cam + dir * hit.t), sw_cloud_alpha(hit.t));
    \\}
    \\
    \\@fragment fn fs_main(@builtin(position) pos: vec4<f32>) -> SwCloudOut {
    \\    let dir = sw_view_ray(pos.xy);
    \\    var t = 0.0;
    \\    var out: SwCloudOut;
    \\    out.color = sw_cloud_pixel(dir, &t);
    \\    if (out.color.a < 0.0) {
    \\        discard;
    \\    }
    \\    let clip = sw_frame.view_proj * vec4<f32>(sw_frame.camera_pos.xyz + dir * t, 1.0);
    \\    out.depth = clamp(clip.z / clip.w, 0.0, 1.0);
    \\    return out;
    \\}
    \\
    \\@fragment fn fs_flat(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    \\    var t = 0.0;
    \\    let c = sw_cloud_pixel(sw_view_ray(pos.xy), &t);
    \\    if (c.a < 0.0) {
    \\        discard;
    \\    }
    \\    return c;
    \\}
    \\
);

// =============================================================================
// The precipitation
// =============================================================================

pub const PrecipitationKind = enum(u8) {
    /// Thin streaks along the fall direction.
    rain,
    /// Round flakes that drift from side to side.
    snow,
};

pub const PrecipitationSettings = struct {
    kind: PrecipitationKind = .snow,
    /// The number of particles at intensity 1.
    count: u32 = 12000,
    /// The part of `count` that draws, 0 to 1.
    intensity: f32 = 1,
    /// The radius of the column around the camera.
    radius: f32 = 20,
    /// The height of the column.
    height: f32 = 24,
    /// The part of the column below the camera, 0 to 1.
    below: f32 = 0.35,
    /// The fall speed, in world units each second. Each particle falls at
    /// 1, 1.25, 1.5 or 1.75 times this speed.
    fall_speed: f32 = 1.2,
    /// The wind, in world units each second, along X and Z.
    wind: [2]f32 = .{ 0.3, 0.1 },
    /// The flake radius (snow) or the streak half width (rain), in world
    /// units.
    size: f32 = 0.05,
    /// Rain: the streak length is the speed times this time, in seconds.
    streak: f32 = 0.05,
    /// Snow: how far a flake drifts from side to side, in world units.
    drift: f32 = 0.35,
    /// Snow: the drift speed, in radians each second.
    drift_rate: f32 = 0.9,
    /// The particle colour in linear RGB, before the light.
    color: Vec3 = .{ 1, 1, 1 },
    opacity: f32 = 0.9,
    /// Snow: the shade at the edge of a flake, 0 to 1. A darker edge shows
    /// a flake on a bright sky.
    edge: f32 = 0.45,
    /// A particle nearer than this distance fades out.
    near: f32 = 0.4,
    /// The smallest particle radius on the screen, in pixels. A smaller
    /// particle grows to this size and its opacity falls to keep the same
    /// light.
    min_pixels: f32 = 1.0,

    /// Settings for snow.
    pub fn snow() PrecipitationSettings {
        return .{};
    }

    /// Settings for rain.
    pub fn rain() PrecipitationSettings {
        return .{
            .kind = .rain,
            .count = 6000,
            .fall_speed = 14,
            .wind = .{ 1.0, 0.3 },
            .size = 0.012,
            .streak = 0.05,
            .color = .{ 0.55, 0.6, 0.7 },
            .opacity = 0.5,
            // A near streak is wide and long: fade it out sooner.
            .near = 1.5,
            .min_pixels = 0.6,
        };
    }

    /// The number of particles that draw.
    pub fn active(self: PrecipitationSettings) u32 {
        const f = std.math.clamp(self.intensity, 0, 1) * @as(f32, @floatFromInt(self.count));
        return @intFromFloat(@round(f));
    }
};

/// A ground height for each cell of a grid on the XZ plane. A particle
/// under the ground height of its cell does not draw. Out of the grid,
/// there is no ground.
pub const HeightMap = struct {
    /// The world X and Z of the corner of cell (0, 0).
    origin: [2]f32,
    /// The world size of one cell.
    cell_size: f32 = 1,
    /// The number of cells along X and along Z.
    width: u32,
    depth: u32,
    /// The ground height of each cell, row by row along X: the cell
    /// (x, z) is at `z * width + x`. `width * depth` values.
    heights: []const f32,

    /// The ground height at the world position (x, z). Null out of the grid.
    pub fn at(self: HeightMap, x: f32, z: f32) ?f32 {
        const cx = @floor((x - self.origin[0]) / self.cell_size);
        const cz = @floor((z - self.origin[1]) / self.cell_size);
        if (cx < 0 or cz < 0) return null;
        if (cx >= @as(f32, @floatFromInt(self.width)) or cz >= @as(f32, @floatFromInt(self.depth))) return null;
        const i = @as(usize, @intFromFloat(cz)) * self.width + @as(usize, @intFromFloat(cx));
        return self.heights[i];
    }
};

/// The uniforms of the precipitation pass, with the memory layout of
/// `SwPrecip` in `precipitation_shader`.
pub const PrecipitationUniforms = extern struct {
    /// x: radius, y: height, z: the part below the camera, w: kind (0 rain,
    /// 1 snow).
    column: [4]f32 = .{ 20, 24, 0.35, 1 },
    /// x, z: the camera X and Z minus the wind offset, modulo the column
    /// width. y: the camera Y modulo the column height. w: not used.
    anchor: [4]f32 = .{ 0, 0, 0, 0 },
    /// x: the fall time (seconds, wrapped), y: the fall speed, z: the drift
    /// phase (radians, wrapped), w: the drift distance.
    motion: [4]f32 = .{ 0, 1, 0, 0 },
    /// xz: the wind. y: not used. w: the streak time.
    wind: [4]f32 = .{ 0, 0, 0, 0.05 },
    /// x: size, y: opacity, z: edge shade, w: near fade distance.
    shape: [4]f32 = .{ 0.05, 0.9, 0.45, 0.4 },
    /// rgb: the lit colour. w: the smallest radius in pixels.
    light: [4]f32 = .{ 1, 1, 1, 1 },
    /// xy: the camera X and Z minus the map origin. z: cell size. w: 1
    /// with a height map.
    ground: [4]f32 = .{ 0, 0, 1, 0 },
    /// x: map width, y: map depth, in cells. zw: not used.
    ground_size: [4]f32 = .{ 1, 1, 0, 0 },
};

/// The fall time wraps after this many column heights of fall at the
/// base speed. Each speed factor (1, 1.25, 1.5, 1.75) times 4 is a whole
/// number, so the wrap moves each particle by whole column heights only.
const fall_wrap: f64 = 4.0;

/// The precipitation uniforms of one frame. `map` gives the origin and
/// the size of the height map. Null: no height map.
pub fn precipitationUniforms(settings: PrecipitationSettings, map: ?HeightMap, input: FrameInput) PrecipitationUniforms {
    const width: f64 = 2.0 * @as(f64, settings.radius);
    const height: f64 = settings.height;
    const cam: [3]f64 = .{ input.camera[0], input.camera[1], input.camera[2] };
    const wind_x = @as(f64, settings.wind[0]) * input.seconds;
    const wind_z = @as(f64, settings.wind[1]) * input.seconds;
    const speed = @max(settings.fall_speed, 1e-3);
    const fall_period = fall_wrap * height / @as(f64, speed);
    const drift_phase = wrap64(@as(f64, settings.drift_rate) * input.seconds, std.math.tau);
    var lit: Vec3 = undefined;
    const l = input.light;
    for (0..3) |i| lit[i] = settings.color[i] * (l.ambient[i] + 0.75 * l.sun[i]);
    var u: PrecipitationUniforms = .{
        .column = .{ settings.radius, settings.height, std.math.clamp(settings.below, 0, 1), if (settings.kind == .snow) 1 else 0 },
        .anchor = .{ @floatCast(wrap64(cam[0] - wind_x, width)), @floatCast(wrap64(cam[1], height)), @floatCast(wrap64(cam[2] - wind_z, width)), 0 },
        .motion = .{ @floatCast(wrap64(input.seconds, fall_period)), speed, @floatCast(drift_phase), if (settings.kind == .snow) settings.drift else 0 },
        .wind = .{ settings.wind[0], 0, settings.wind[1], settings.streak },
        .shape = .{ settings.size, std.math.clamp(settings.opacity, 0, 1), std.math.clamp(settings.edge, 0, 1), settings.near },
        .light = .{ lit[0], lit[1], lit[2], settings.min_pixels },
    };
    if (map) |m| {
        u.ground = .{ @floatCast(cam[0] - m.origin[0]), @floatCast(cam[2] - m.origin[1]), m.cell_size, 1 };
        u.ground_size = .{ @floatFromInt(m.width), @floatFromInt(m.depth), 0, 0 };
    }
    return u;
}

/// `sw_precip_hash`: an integer hash.
pub fn precipHash(x: u32) u32 {
    var h = x *% 0x9e3779b1;
    h = (h ^ (h >> 16)) *% 0x7feb352d;
    h = (h ^ (h >> 15)) *% 0x846ca68b;
    return h ^ (h >> 16);
}

/// A value in 0 to 1 from the top 24 bits of `h`.
pub fn unitFloat(h: u32) f32 {
    return @as(f32, @floatFromInt(h >> 8)) * (1.0 / 16777216.0);
}

/// One particle, from `particle`.
pub const Particle = struct {
    /// The position relative to the camera.
    rel: Vec3,
    /// The radius (snow) or half width (rain), before the pixel minimum.
    size: f32,
    /// The fall speed factor: 1, 1.25, 1.5 or 1.75.
    speed: f32,
    /// The fade at the edges of the column and near the camera, 0 to 1.
    fade: f32,
};

/// `sw_precip_particle`: the particle `index` relative to the camera.
pub fn particle(u: PrecipitationUniforms, index: u32) Particle {
    const radius = u.column[0];
    const height = u.column[1];
    const below = u.column[2] * height;
    const width = 2.0 * radius;
    const hx = precipHash(index *% 4);
    const hy = precipHash(index *% 4 +% 1);
    const hz = precipHash(index *% 4 +% 2);
    const hv = precipHash(index *% 4 +% 3);
    const speed = 1.0 + 0.25 * @as(f32, @floatFromInt(hv & 3));
    const fall = u.motion[0] * u.motion[1] * speed;
    var rel: Vec3 = .{
        wrap(unitFloat(hx) * width - u.anchor[0] + radius, width) - radius,
        wrap(unitFloat(hy) * height - fall - u.anchor[1] + below, height) - below,
        wrap(unitFloat(hz) * width - u.anchor[2] + radius, width) - radius,
    };
    const a = @as(f32, @floatFromInt((hv >> 10) & 0x3ff)) * (std.math.tau / 1024.0);
    const b = @as(f32, @floatFromInt((hv >> 20) & 0x3ff)) * (std.math.tau / 1024.0);
    const dp = u.motion[2];
    const amp = u.motion[3];
    rel[0] += amp * (@sin(dp + a) + 0.5 * @sin(2.0 * dp + b));
    rel[2] += amp * (@cos(dp + b) + 0.5 * @cos(2.0 * dp + a));
    const v = (rel[1] + below) / height;
    const horizontal = @sqrt(rel[0] * rel[0] + rel[2] * rel[2]);
    const dist = @sqrt(dot(rel, rel));
    const fade = (1.0 - smoothstep(0.7 * radius, radius, horizontal)) *
        smoothstep(0.0, 0.08, v) * (1.0 - smoothstep(0.92, 1.0, v)) *
        smoothstep(u.shape[3], 2.0 * u.shape[3], dist);
    const size_var = @as(f32, @floatFromInt((hv >> 2) & 0xff)) / 255.0;
    return .{ .rel = rel, .size = u.shape[0] * (0.7 + 0.6 * size_var), .speed = speed, .fade = fade };
}

/// `sw_precip_ground`: the ground height under the camera-relative XZ
/// position `rel`. `height(ctx, cell)` gives the height of a map cell.
/// Out of the map: -1e30.
pub fn groundAt(u: PrecipitationUniforms, rel_x: f32, rel_z: f32, ctx: anytype, comptime height: fn (@TypeOf(ctx), [2]i32) f32) f32 {
    if (u.ground[3] < 0.5) return -1e30;
    const cx = @floor((u.ground[0] + rel_x) / u.ground[2]);
    const cz = @floor((u.ground[1] + rel_z) / u.ground[2]);
    if (cx < 0 or cz < 0 or cx >= u.ground_size[0] or cz >= u.ground_size[1]) return -1e30;
    return height(ctx, .{ @intFromFloat(cx), @intFromFloat(cz) });
}

/// The radius after the pixel minimum, and the opacity factor that keeps
/// the light. `dist` is the distance to the camera. `focal_px` is the
/// height of the target in pixels times `proj[1][1] / 2`.
pub fn pixelSize(u: PrecipitationUniforms, size: f32, dist: f32, focal_px: f32) [2]f32 {
    const px = size * focal_px / @max(dist, 1e-4);
    if (px >= u.light[3] or px <= 0) return .{ size, 1 };
    const k = u.light[3] / px;
    return .{ size * k, 1.0 / (k * k) };
}

/// `sw_precip_snow`: the colour and alpha of a snow flake at `uv` (each
/// axis in -1 to 1 over the flake), before the fog. `alpha` is the opacity
/// of the particle.
pub fn snowFragment(u: PrecipitationUniforms, uv: [2]f32, alpha: f32) [4]f32 {
    const r = @sqrt(uv[0] * uv[0] + uv[1] * uv[1]);
    const disc = 1.0 - smoothstep(0.55, 1.0, r);
    const shade = u.shape[2] + (1.0 - u.shape[2]) * (1.0 - smoothstep(0.0, 0.75, r));
    return .{ u.light[0] * shade, u.light[1] * shade, u.light[2] * shade, disc * alpha };
}

/// `sw_precip_rain`: the colour and alpha of a rain streak at `uv` (x
/// across, y along, each in -1 to 1), before the fog.
pub fn rainFragment(u: PrecipitationUniforms, uv: [2]f32, alpha: f32) [4]f32 {
    const across = 1.0 - smoothstep(0.3, 1.0, @abs(uv[0]));
    const along = 1.0 - smoothstep(0.5, 1.0, @abs(uv[1]));
    return .{ u.light[0], u.light[1], u.light[2], across * along * alpha };
}

/// The precipitation pass: 6 vertices (two triangles) for each instance.
/// Group 0 has the frame uniforms, group 1 the precipitation uniforms and
/// the height map.
pub const precipitation_shader = wgsl.shader(
    \\struct SwPrecip {
    \\    column: vec4<f32>,
    \\    anchor: vec4<f32>,
    \\    motion: vec4<f32>,
    \\    wind: vec4<f32>,
    \\    shape: vec4<f32>,
    \\    light: vec4<f32>,
    \\    ground: vec4<f32>,
    \\    ground_size: vec4<f32>,
    \\}
    \\@group(1) @binding(0) var<uniform> sw_precip: SwPrecip;
    \\@group(1) @binding(1) var sw_precip_heights: texture_2d<f32>;
    \\
    \\fn sw_precip_hash(x: u32) -> u32 {
    \\    var h = x * 0x9e3779b1u;
    \\    h = (h ^ (h >> 16u)) * 0x7feb352du;
    \\    h = (h ^ (h >> 15u)) * 0x846ca68bu;
    \\    return h ^ (h >> 16u);
    \\}
    \\
    \\fn sw_precip_unit(h: u32) -> f32 {
    \\    return f32(h >> 8u) * (1.0 / 16777216.0);
    \\}
    \\
    \\fn sw_precip_wrap(x: f32, m: f32) -> f32 {
    \\    return x - m * floor(x / m);
    \\}
    \\
    \\struct SwParticle {
    \\    rel: vec3<f32>,
    \\    size: f32,
    \\    speed: f32,
    \\    fade: f32,
    \\}
    \\
    \\fn sw_precip_particle(index: u32) -> SwParticle {
    \\    let radius = sw_precip.column.x;
    \\    let height = sw_precip.column.y;
    \\    let below = sw_precip.column.z * height;
    \\    let width = 2.0 * radius;
    \\    let hx = sw_precip_hash(index * 4u);
    \\    let hy = sw_precip_hash(index * 4u + 1u);
    \\    let hz = sw_precip_hash(index * 4u + 2u);
    \\    let hv = sw_precip_hash(index * 4u + 3u);
    \\    var p: SwParticle;
    \\    p.speed = 1.0 + 0.25 * f32(hv & 3u);
    \\    let fall = sw_precip.motion.x * sw_precip.motion.y * p.speed;
    \\    var rel = vec3<f32>(
    \\        sw_precip_wrap(sw_precip_unit(hx) * width - sw_precip.anchor.x + radius, width) - radius,
    \\        sw_precip_wrap(sw_precip_unit(hy) * height - fall - sw_precip.anchor.y + below, height) - below,
    \\        sw_precip_wrap(sw_precip_unit(hz) * width - sw_precip.anchor.z + radius, width) - radius,
    \\    );
    \\    let a = f32((hv >> 10u) & 0x3ffu) * (6.2831853 / 1024.0);
    \\    let b = f32((hv >> 20u) & 0x3ffu) * (6.2831853 / 1024.0);
    \\    let dp = sw_precip.motion.z;
    \\    let amp = sw_precip.motion.w;
    \\    rel.x += amp * (sin(dp + a) + 0.5 * sin(2.0 * dp + b));
    \\    rel.z += amp * (cos(dp + b) + 0.5 * cos(2.0 * dp + a));
    \\    let v = (rel.y + below) / height;
    \\    let horizontal = length(rel.xz);
    \\    p.fade = (1.0 - smoothstep(0.7 * radius, radius, horizontal)) *
    \\        smoothstep(0.0, 0.08, v) * (1.0 - smoothstep(0.92, 1.0, v)) *
    \\        smoothstep(sw_precip.shape.w, 2.0 * sw_precip.shape.w, length(rel));
    \\    p.size = sw_precip.shape.x * (0.7 + 0.6 * f32((hv >> 2u) & 0xffu) / 255.0);
    \\    p.rel = rel;
    \\    return p;
    \\}
    \\
    \\fn sw_precip_ground(rel_x: f32, rel_z: f32) -> f32 {
    \\    let g = sw_precip.ground;
    \\    if (g.w < 0.5) {
    \\        return -1e30;
    \\    }
    \\    let c = floor((g.xy + vec2<f32>(rel_x, rel_z)) / g.z);
    \\    if (c.x < 0.0 || c.y < 0.0 || c.x >= sw_precip.ground_size.x || c.y >= sw_precip.ground_size.y) {
    \\        return -1e30;
    \\    }
    \\    return textureLoad(sw_precip_heights, vec2<i32>(c), 0).r;
    \\}
    \\
    \\fn sw_precip_snow(uv: vec2<f32>, alpha: f32) -> vec4<f32> {
    \\    let r = length(uv);
    \\    let disc = 1.0 - smoothstep(0.55, 1.0, r);
    \\    let shade = sw_precip.shape.z + (1.0 - sw_precip.shape.z) * (1.0 - smoothstep(0.0, 0.75, r));
    \\    return vec4<f32>(sw_precip.light.rgb * shade, disc * alpha);
    \\}
    \\
    \\fn sw_precip_rain(uv: vec2<f32>, alpha: f32) -> vec4<f32> {
    \\    let across = 1.0 - smoothstep(0.3, 1.0, abs(uv.x));
    \\    let along = 1.0 - smoothstep(0.5, 1.0, abs(uv.y));
    \\    return vec4<f32>(sw_precip.light.rgb, across * along * alpha);
    \\}
    \\
    \\struct SwPrecipOut {
    \\    @builtin(position) pos: vec4<f32>,
    \\    @location(0) uv: vec2<f32>,
    \\    @location(1) world: vec3<f32>,
    \\    @location(2) @interpolate(flat) alpha: f32,
    \\    @location(3) @interpolate(flat) ground: f32,
    \\}
    \\
    \\@vertex fn vs_main(@builtin(vertex_index) vi: u32, @builtin(instance_index) ii: u32) -> SwPrecipOut {
    \\    var out: SwPrecipOut;
    \\    let p = sw_precip_particle(ii);
    \\    let cam = sw_frame.camera_pos.xyz;
    \\    let ground = sw_precip_ground(p.rel.x, p.rel.z);
    \\    out.ground = ground;
    \\    // A particle under the ground, or with no light, does not draw.
    \\    if (cam.y + p.rel.y < ground || p.fade <= 0.0) {
    \\        out.pos = vec4<f32>(0.0, 0.0, 2.0, 1.0);
    \\        return out;
    \\    }
    \\    var corners = array<vec2<f32>, 6>(
    \\        vec2<f32>(-1.0, -1.0), vec2<f32>(1.0, -1.0), vec2<f32>(1.0, 1.0),
    \\        vec2<f32>(-1.0, -1.0), vec2<f32>(1.0, 1.0), vec2<f32>(-1.0, 1.0),
    \\    );
    \\    let c = corners[vi];
    \\    let dist = length(p.rel);
    \\    let focal = sw_frame.proj[1][1] * sw_frame.viewport.y * 0.5;
    \\    var size = p.size;
    \\    var alpha = p.fade * sw_precip.shape.y;
    \\    let px = size * focal / max(dist, 1e-4);
    \\    if (px < sw_precip.light.w && px > 0.0) {
    \\        let k = sw_precip.light.w / px;
    \\        size *= k;
    \\        alpha /= k * k;
    \\    }
    \\    var offset: vec3<f32>;
    \\    if (sw_precip.column.w > 0.5) {
    \\        let m = sw_frame.view;
    \\        let right = vec3<f32>(m[0].x, m[1].x, m[2].x);
    \\        let up = vec3<f32>(m[0].y, m[1].y, m[2].y);
    \\        offset = (right * c.x + up * c.y) * size;
    \\    } else {
    \\        let vel = vec3<f32>(sw_precip.wind.x, -sw_precip.motion.y * p.speed, sw_precip.wind.z);
    \\        let half_len = vel * (0.5 * sw_precip.wind.w);
    \\        var side = cross(half_len, p.rel);
    \\        side = side / max(length(side), 1e-6);
    \\        offset = side * (c.x * size) - half_len * c.y;
    \\    }
    \\    let world = cam + p.rel + offset;
    \\    out.pos = sw_frame.view_proj * vec4<f32>(world, 1.0);
    \\    out.uv = c;
    \\    out.world = world;
    \\    out.alpha = alpha;
    \\    return out;
    \\}
    \\
    \\@fragment fn fs_main(in: SwPrecipOut) -> @location(0) vec4<f32> {
    \\    if (in.world.y < in.ground) {
    \\        discard;
    \\    }
    \\    var c: vec4<f32>;
    \\    if (sw_precip.column.w > 0.5) {
    \\        c = sw_precip_snow(in.uv, in.alpha);
    \\    } else {
    \\        c = sw_precip_rain(in.uv, in.alpha);
    \\    }
    \\    let dist = distance(in.world, sw_frame.camera_pos.xyz);
    \\    c.a *= 1.0 - sw_fog_amount(dist);
    \\    if (c.a <= 0.001) {
    \\        discard;
    \\    }
    \\    return vec4<f32>(sw_fog(c.rgb, in.world), c.a);
    \\}
    \\
);

/// The bind group of the cloud pass and of the precipitation pass.
pub const pass_group: u32 = 1;

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

const TestShape = struct {
    width: u32,
    height: u32,
    cells: []const bool,

    fn filled(self: *const TestShape, t: [2]i32) bool {
        return self.cells[@as(usize, @intCast(t[1])) * self.width + @as(usize, @intCast(t[0]))];
    }

    fn white(_: *const TestShape, _: [2]i32) Vec3 {
        return .{ 1, 1, 1 };
    }
};

fn noonInput(camera: Vec3, seconds: f64) FrameInput {
    return .{ .camera = camera, .seconds = seconds, .light = skyLight(sky_plan.state(0.5, .{})) };
}

test "weather: a ray hits the first cloud box, and the wind moves the shape (REQ-GPU-020)" {
    // A 4 by 4 shape with one box at texel (2, 1).
    var cells: [16]bool = @splat(false);
    cells[1 * 4 + 2] = true;
    const shape: TestShape = .{ .width = 4, .height = 4, .cells = &cells };
    const set: CloudSettings = .{ .bottom = 100, .thickness = 4, .cell_size = 10, .wind = .{ 2, 0 } };
    // The camera at (5, 0, 5): texel (0, 0), 5 units into it.
    const u = cloudUniforms(set, 4, 4, noonInput(.{ 5, 0, 5 }, 0));
    try testing.expectEqual(@as(f32, 0), u.camera[0]);
    try testing.expectApproxEqAbs(@as(f32, 5), u.camera[2], 1e-5);
    // Straight up from the camera: texel (0, 0) is empty.
    try testing.expect(cloudHit(u, 0, .{ 0, 1, 0 }, &shape, TestShape.filled) == null);
    // A ray to the bottom face of the box at the world centre (25, 100, 15).
    const to = sky_plan.normalize(.{ 20, 100, 10 });
    const hit = cloudHit(u, 0, to, &shape, TestShape.filled).?;
    try testing.expectEqual([2]i32{ 2, 1 }, hit.cell);
    try testing.expectEqual(Vec3{ 0, -1, 0 }, hit.normal);
    try testing.expectApproxEqAbs(@sqrt(@as(f32, 20 * 20 + 100 * 100 + 10 * 10)), hit.t, 1e-3);
    // A flat ray in the slab hits the side of the box (x = 20).
    const side = cloudHit(u, 102, sky_plan.normalize(.{ 1, 0, 0.5 }), &shape, TestShape.filled).?;
    try testing.expectEqual(Vec3{ -1, 0, 0 }, side.normal);
    try testing.expectApproxEqAbs(@as(f32, 15) * @sqrt(@as(f32, 1.25)), side.t, 1e-3);
    // After 5 seconds the wind moved the shape 10 units (one cell) along
    // +X: the box is at world X 30 to 40, and the old ray misses it.
    const later = cloudUniforms(set, 4, 4, noonInput(.{ 5, 0, 5 }, 5));
    try testing.expectEqual(@as(f32, 3), later.camera[0]);
    try testing.expect(cloudHit(later, 0, to, &shape, TestShape.filled) == null);
    const moved = cloudHit(later, 0, sky_plan.normalize(.{ 30, 100, 10 }), &shape, TestShape.filled).?;
    try testing.expectEqual([2]i32{ 2, 1 }, moved.cell);
    // The shape repeats: the same box 40 units along -Z.
    const repeat = cloudHit(u, 0, sky_plan.normalize(.{ 20, 100, -30 }), &shape, TestShape.filled).?;
    try testing.expectEqual([2]i32{ 2, 1 }, repeat.cell);
    // A ray down from under the layer, or past the fade end, has no hit.
    try testing.expect(cloudHit(u, 0, .{ 0, -1, 0 }, &shape, TestShape.filled) == null);
    var far = set;
    far.fade_end = 50;
    try testing.expect(cloudHit(cloudUniforms(far, 4, 4, noonInput(.{ 5, 0, 5 }, 0)), 0, to, &shape, TestShape.filled) == null);
}

test "weather: a large time and a far camera keep the precision (REQ-GPU-020)" {
    const set: CloudSettings = .{ .cell_size = 12, .wind = .{ 1.5, -0.5 } };
    const u = cloudUniforms(set, 64, 32, noonInput(.{ 1.0e6 + 3, 70, -2.5e6 }, 1.0e7));
    try testing.expect(u.camera[0] >= 0 and u.camera[0] < 64 and u.camera[0] == @floor(u.camera[0]));
    try testing.expect(u.camera[1] >= 0 and u.camera[1] < 32 and u.camera[1] == @floor(u.camera[1]));
    try testing.expect(u.camera[2] >= 0 and u.camera[2] < 12);
    try testing.expect(u.camera[3] >= 0 and u.camera[3] < 12);
    // One second later the camera moved 1.5 units back along X, in the shape.
    const v = cloudUniforms(set, 64, 32, noonInput(.{ 1.0e6 + 3, 70, -2.5e6 }, 1.0e7 + 1));
    const a = u.camera[0] * 12 + u.camera[2];
    const b = v.camera[0] * 12 + v.camera[2];
    try testing.expectApproxEqAbs(@as(f32, 1.5), wrap(a - b, 64 * 12), 1e-3);
}

test "weather: the sun lights the clouds, and the fog and the fade hide far clouds (REQ-GPU-020)" {
    const set: CloudSettings = .{};
    const noon = cloudUniforms(set, 1, 1, noonInput(.{ 0, 0, 0 }, 0));
    const night = cloudUniforms(set, 1, 1, .{ .camera = .{ 0, 0, 0 }, .seconds = 0, .light = skyLight(sky_plan.state(0.0, .{})) });
    const white: Vec3 = .{ 1, 1, 1 };
    const top = cloudShade(noon, .{ 0, 1, 0 }, white);
    const bottom = cloudShade(noon, .{ 0, -1, 0 }, white);
    try testing.expect(top[0] > bottom[0] and top[1] > bottom[1]);
    try testing.expect(top[0] > 1.0);
    // At night the clouds are dark.
    try testing.expect(cloudShade(night, .{ 0, 1, 0 }, white)[0] < 0.05);
    // The opacity falls from the fade start to the fade end.
    try testing.expectApproxEqAbs(set.opacity, cloudAlpha(noon, 10), 1e-6);
    try testing.expectEqual(@as(f32, 0), cloudAlpha(noon, set.fade_end));
    // A box in full fog has the fog colour.
    const one = [_]bool{true};
    const shape: TestShape = .{ .width = 1, .height = 1, .cells = &one };
    const s = sky_plan.state(0.5, .{});
    const fogged = sky_plan.uniforms(s, .{}, .{ .start = 10, .end = 50 });
    const sample = cloudSample(noon, fogged, 0, .{ 0, 1, 0 }, &shape, TestShape.filled, TestShape.white).?;
    for (0..3) |i| try testing.expectApproxEqAbs(s.horizon[i], sample.color[i], 1e-5);
    const clear = sky_plan.uniforms(s, .{}, null);
    const lit = cloudSample(noon, clear, 0, .{ 0, 1, 0 }, &shape, TestShape.filled, TestShape.white).?;
    for (0..3) |i| try testing.expectApproxEqAbs(bottom[i], lit.color[i], 1e-5);
}

test "weather: the particles stay in the column and stay in place while the camera moves (REQ-GPU-021)" {
    const set = PrecipitationSettings.snow();
    const cam: Vec3 = .{ 1000.5, 64, -321.25 };
    const u = precipitationUniforms(set, null, noonInput(cam, 12.5));
    var i: u32 = 0;
    while (i < 2000) : (i += 1) {
        const p = particle(u, i);
        // The drift can move a flake a little out of the column.
        const slack = set.drift * 1.5 + 1e-3;
        try testing.expect(@abs(p.rel[0]) <= set.radius + slack and @abs(p.rel[2]) <= set.radius + slack);
        try testing.expect(p.rel[1] >= -set.below * set.height - 1e-3 and p.rel[1] < (1 - set.below) * set.height + 1e-3);
        try testing.expect(p.fade >= 0 and p.fade <= 1);
    }
    // The camera moves 3 units: a particle away from the column edge keeps
    // its world position.
    const moved: Vec3 = .{ cam[0] + 3, cam[1] + 1, cam[2] - 2 };
    const v = precipitationUniforms(set, null, noonInput(moved, 12.5));
    var same: u32 = 0;
    i = 0;
    while (i < 500) : (i += 1) {
        const a = particle(u, i);
        const b = particle(v, i);
        if (@abs(a.rel[0]) > set.radius - 6 or @abs(a.rel[2]) > set.radius - 6) continue;
        if (a.rel[1] < -set.below * set.height + 2 or a.rel[1] > (1 - set.below) * set.height - 2) continue;
        for (0..3) |k| try testing.expectApproxEqAbs(cam[k] + a.rel[k], moved[k] + b.rel[k], 2e-3);
        same += 1;
    }
    try testing.expect(same > 100);
}

test "weather: particles fall, and the wrap of the fall time moves no particle (REQ-GPU-021)" {
    var set = PrecipitationSettings.rain();
    set.wind = .{ 0, 0 };
    const cam: Vec3 = .{ 0, 10, 0 };
    const a = precipitationUniforms(set, null, noonInput(cam, 1.0));
    const b = precipitationUniforms(set, null, noonInput(cam, 1.05));
    var fell: u32 = 0;
    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        const p = particle(a, i);
        const q = particle(b, i);
        const want = -set.fall_speed * p.speed * 0.05;
        if (@abs(q.rel[1] - p.rel[1] - want) < 1e-3) fell += 1;
    }
    // A particle that wrapped to the column top does not count.
    try testing.expect(fell > 180);
    // Just before and just after the wrap of the fall time.
    const period: f64 = 4.0 * set.height / set.fall_speed;
    const before = precipitationUniforms(set, null, noonInput(cam, period - 1e-4));
    const after = precipitationUniforms(set, null, noonInput(cam, period + 1e-4));
    i = 0;
    while (i < 200) : (i += 1) {
        const p = particle(before, i);
        const q = particle(after, i);
        const dy = wrap(q.rel[1] - p.rel[1] + 1, set.height) - 1;
        try testing.expect(@abs(dy) < 0.02);
    }
}

const TestMap = struct {
    map: HeightMap,

    fn height(self: *const TestMap, c: [2]i32) f32 {
        return self.map.heights[@as(usize, @intCast(c[1])) * self.map.width + @as(usize, @intCast(c[0]))];
    }
};

test "weather: the height map gives the ground under a particle (REQ-GPU-021)" {
    // A 4 by 2 map of 2-unit cells from (-4, -2).
    const heights = [_]f32{ 0, 1, 2, 3, 10, 11, 12, 13 };
    const map: HeightMap = .{ .origin = .{ -4, -2 }, .cell_size = 2, .width = 4, .depth = 2, .heights = &heights };
    try testing.expectEqual(@as(?f32, 0), map.at(-4, -2));
    try testing.expectEqual(@as(?f32, 3), map.at(3.9, -1));
    try testing.expectEqual(@as(?f32, 12), map.at(0.5, 1.5));
    try testing.expectEqual(@as(?f32, null), map.at(4.1, 0));
    try testing.expectEqual(@as(?f32, null), map.at(0, -2.1));
    const t: TestMap = .{ .map = map };
    const cam: Vec3 = .{ 1, 5, 0.5 };
    const u = precipitationUniforms(.{}, map, noonInput(cam, 0));
    // The shader lookup with a camera-relative position gives the same height.
    var x: f32 = -6;
    while (x < 6) : (x += 0.37) {
        var z: f32 = -3;
        while (z < 3) : (z += 0.41) {
            const want = map.at(x, z) orelse -1e30;
            try testing.expectEqual(want, groundAt(u, x - cam[0], z - cam[2], &t, TestMap.height));
        }
    }
    // No map: no ground.
    const none = precipitationUniforms(.{}, null, noonInput(cam, 0));
    try testing.expectEqual(@as(f32, -1e30), groundAt(none, 0, 0, &t, TestMap.height));
}

test "weather: a snow flake has a bright centre, a darker edge, and a soft rim (REQ-GPU-021)" {
    const u = precipitationUniforms(PrecipitationSettings.snow(), null, noonInput(.{ 0, 0, 0 }, 0));
    const centre = snowFragment(u, .{ 0, 0 }, 1);
    const edge = snowFragment(u, .{ 0.8, 0 }, 1);
    const out = snowFragment(u, .{ 1, 0.1 }, 1);
    try testing.expectApproxEqAbs(@as(f32, 1), centre[3], 1e-6);
    try testing.expect(edge[0] < centre[0] and edge[3] > 0 and edge[3] < 1);
    try testing.expectEqual(@as(f32, 0), out[3]);
    // In the day the flake centre is brighter than the sky at the horizon.
    const s = sky_plan.state(0.5, .{});
    try testing.expect(centre[0] > s.horizon[0] and centre[1] > s.horizon[1] and centre[2] > s.horizon[2]);
    // A far flake grows to the pixel minimum, and keeps its light.
    const ps = pixelSize(u, 0.03, 60, 500);
    try testing.expectApproxEqAbs(@as(f32, 1.0), ps[0] * 500 / 60, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.03 * 0.03), ps[0] * ps[0] * ps[1], 1e-6);
    try testing.expectEqual([2]f32{ 0.03, 1 }, pixelSize(u, 0.03, 1, 500));
    // The rain streak.
    const ru = precipitationUniforms(PrecipitationSettings.rain(), null, noonInput(.{ 0, 0, 0 }, 0));
    try testing.expectApproxEqAbs(@as(f32, 0.5), rainFragment(ru, .{ 0, 0 }, 0.5)[3], 1e-6);
    try testing.expectEqual(@as(f32, 0), rainFragment(ru, .{ 1, 0 }, 0.5)[3]);
    try testing.expectEqual(@as(u32, 3000), (PrecipitationSettings{ .count = 6000, .intensity = 0.5 }).active());
}

test "weather: the shader structs have the layouts of the Zig uniforms (REQ-GPU-020, REQ-GPU-021)" {
    try testing.expect(std.mem.startsWith(u8, cloud_shader, wgsl.prefix));
    try testing.expect(std.mem.startsWith(u8, precipitation_shader, wgsl.prefix));
    try expectStruct(CloudUniforms, cloud_shader, "SwClouds");
    try expectStruct(PrecipitationUniforms, precipitation_shader, "SwPrecip");
    try testing.expectEqual(@as(u32, 1), pass_group);
}

/// Each member of `T` is a `[4]f32`, and the WGSL struct `name` has the
/// same members as `vec4<f32>` in the same sequence.
fn expectStruct(comptime T: type, text: []const u8, name: []const u8) !void {
    var head_buf: [64]u8 = undefined;
    const head = try std.fmt.bufPrint(&head_buf, "struct {s} {{\n", .{name});
    const start = std.mem.indexOf(u8, text, head).? + head.len;
    const end = std.mem.indexOfPos(u8, text, start, "}").?;
    var lines = std.mem.tokenizeScalar(u8, text[start..end], '\n');
    const fields = @typeInfo(T).@"struct".field_names;
    var i: usize = 0;
    while (lines.next()) |raw| : (i += 1) {
        const line = std.mem.trim(u8, raw, " ,");
        var want_buf: [64]u8 = undefined;
        try testing.expect(i < fields.len);
        const want = try std.fmt.bufPrint(&want_buf, "{s}: vec4<f32>", .{fields[i]});
        try testing.expectEqualStrings(want, line);
    }
    try testing.expectEqual(fields.len, i);
    try testing.expectEqual(fields.len * 16, @sizeOf(T));
}
