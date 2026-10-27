//! The plan of the sky, with no GPU code: the time of day, the sky colours,
//! the fog, and the CPU reference of the WGSL sky helpers.
//!
//! `sky.zig` makes the sky pass. This file holds only the rules, so the
//! tests run with no GPU (REQ-GPU-010, REQ-GPU-011).
//!
//! The time of day is a value from 0 to 1. 0 is midnight, 0.25 is sunrise
//! (the sun at the horizon in +X), 0.5 is noon, and 0.75 is sunset (the sun
//! at the horizon in -X). `Settings.tilt` turns the path of the sun toward
//! +Z. The moon is opposite the sun. The stars turn with the sun.

const std = @import("std");
const wgsl = @import("wgsl.zig");

pub const SkyUniforms = wgsl.SkyUniforms;
pub const Vec3 = [3]f32;

/// The sky colours, in linear RGB. The game can change them.
pub const Palette = struct {
    day_zenith: Vec3 = .{ 0.10, 0.28, 0.75 },
    day_horizon: Vec3 = .{ 0.55, 0.70, 0.90 },
    night_zenith: Vec3 = .{ 0.002, 0.004, 0.012 },
    night_horizon: Vec3 = .{ 0.010, 0.015, 0.035 },
    /// The horizon colour and the glow near sunrise and sunset.
    twilight: Vec3 = .{ 0.90, 0.40, 0.15 },
    /// The colour of the sun at noon, before `Settings.sun_intensity`.
    sun: Vec3 = .{ 1.0, 0.95, 0.85 },
    /// The colour of the sun at the horizon, before `Settings.sun_intensity`.
    low_sun: Vec3 = .{ 1.0, 0.55, 0.25 },
    moon: Vec3 = .{ 0.75, 0.80, 0.90 },
};

pub const Stars = struct {
    /// Grid cells for each unit of direction. More cells give smaller and
    /// more stars.
    density: f32 = 60.0,
    /// The star radius, in cells. 0.25 at most.
    radius: f32 = 0.25,
    /// The part of the cells that have a star, 0 to 1.
    fraction: f32 = 0.35,
    /// The HDR brightness of a star at night.
    brightness: f32 = 6.0,
};

pub const Settings = struct {
    palette: Palette = .{},
    stars: Stars = .{},
    /// The angle in radians between the path of the sun and the vertical
    /// plane through east and west.
    tilt: f32 = 0.35,
    /// The angular radius of the sun disc, in radians.
    sun_radius: f32 = 0.03,
    /// The angular radius of the moon disc, in radians.
    moon_radius: f32 = 0.025,
    /// The HDR brightness of the sun disc.
    sun_intensity: f32 = 30.0,
    /// The HDR brightness of the moon disc.
    moon_intensity: f32 = 2.5,
    /// The gradient exponent. Less than 1 gives a narrow horizon band.
    gradient_exponent: f32 = 0.5,
    /// The ground colour is the horizon colour times this value.
    ground_factor: f32 = 0.4,
    /// How fast the horizon colour changes to the ground colour below the
    /// horizon.
    ground_sharpness: f32 = 8.0,
    /// The glow exponent. A larger value gives a smaller glow.
    glow_exponent: f32 = 8.0,
    /// The glow brightness at sunrise and sunset.
    glow_strength: f32 = 1.5,
};

/// Linear distance fog. The game sets the start and the end.
pub const Fog = struct {
    /// The distance from the camera where the fog starts.
    start: f32 = 64.0,
    /// The distance from the camera of full fog.
    end: f32 = 128.0,
    /// The fog colour. Null: the horizon colour of the sky (REQ-GPU-011).
    color: ?Vec3 = null,
    /// The most fog, 0 to 1.
    max: f32 = 1.0,
};

/// The sky at one time of day.
pub const State = struct {
    /// The time of day, 0 to 1.
    time: f32,
    /// The unit vector to the sun.
    sun_dir: Vec3,
    /// The unit vector to the moon.
    moon_dir: Vec3,
    /// 0 at night, 1 in the day.
    daylight: f32,
    /// 1 at sunrise and sunset, 0 when the sun is far from the horizon.
    twilight: f32,
    zenith: Vec3,
    horizon: Vec3,
    ground: Vec3,
    /// The HDR colour of the sun disc. Black below the horizon.
    sun_color: Vec3,
    moon_color: Vec3,
    glow: Vec3,
    /// The HDR brightness of the stars. 0 in the day.
    star_brightness: f32,
};

/// Put `t` in the range 0 to 1 (1.25 gives 0.25, -0.25 gives 0.75).
pub fn wrapTime(t: f32) f32 {
    const w = t - @floor(t);
    return if (w >= 1.0) 0.0 else w;
}

/// The angle of the sun on its path: 0 at sunrise, pi / 2 at noon.
pub fn sunAngle(time: f32) f32 {
    return std.math.tau * (wrapTime(time) - 0.25);
}

/// The unit vector to the sun at `time`.
pub fn sunDirection(time: f32, tilt: f32) Vec3 {
    const a = sunAngle(time);
    const s = @sin(a);
    return .{ @cos(a), s * @cos(tilt), s * @sin(tilt) };
}

pub fn smoothstep(e0: f32, e1: f32, x: f32) f32 {
    const t = std.math.clamp((x - e0) / (e1 - e0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

pub fn mix(a: Vec3, b: Vec3, t: f32) Vec3 {
    return .{ a[0] * (1.0 - t) + b[0] * t, a[1] * (1.0 - t) + b[1] * t, a[2] * (1.0 - t) + b[2] * t };
}

fn scale(a: Vec3, k: f32) Vec3 {
    return .{ a[0] * k, a[1] * k, a[2] * k };
}

fn add(a: Vec3, b: Vec3) Vec3 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}

pub fn dot(a: Vec3, b: Vec3) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

pub fn normalize(a: Vec3) Vec3 {
    return scale(a, 1.0 / @sqrt(dot(a, a)));
}

/// The sky at `time` (REQ-GPU-010).
pub fn state(time: f32, settings: Settings) State {
    const p = settings.palette;
    const t = wrapTime(time);
    const sun = sunDirection(t, settings.tilt);
    const moon: Vec3 = .{ -sun[0], -sun[1], -sun[2] };
    const h = sun[1];
    const day = smoothstep(-0.12, 0.18, h);
    const tw = smoothstep(0.0, 1.0, std.math.clamp(1.0 - @abs(h) / 0.3, 0.0, 1.0));
    const horizon = mix(mix(p.night_horizon, p.day_horizon, day), p.twilight, tw * 0.6);
    const zenith = mix(mix(p.night_zenith, p.day_zenith, day), p.twilight, tw * 0.08);
    const sun_tint = mix(p.sun, p.low_sun, smoothstep(0.35, 0.0, h));
    const night = 1.0 - day;
    return .{
        .time = t,
        .sun_dir = sun,
        .moon_dir = moon,
        .daylight = day,
        .twilight = tw,
        .zenith = zenith,
        .horizon = horizon,
        .ground = scale(horizon, settings.ground_factor),
        .sun_color = scale(sun_tint, settings.sun_intensity * smoothstep(-0.05, 0.05, h)),
        .moon_color = scale(p.moon, settings.moon_intensity * smoothstep(-0.05, 0.05, moon[1])),
        .glow = scale(p.twilight, settings.glow_strength * tw),
        // The stars show when the day is more than half gone.
        .star_brightness = settings.stars.brightness * smoothstep(0.5, 1.0, night),
    };
}

/// The sky part of the frame uniforms (`FrameUniforms.sky`). Null `fog`:
/// no fog.
pub fn uniforms(s: State, settings: Settings, fog: ?Fog) SkyUniforms {
    var u: SkyUniforms = .{
        .sun_dir = .{ s.sun_dir[0], s.sun_dir[1], s.sun_dir[2], s.time },
        .moon_dir = .{ s.moon_dir[0], s.moon_dir[1], s.moon_dir[2], 0 },
        .zenith = .{ s.zenith[0], s.zenith[1], s.zenith[2], 0 },
        .horizon = .{ s.horizon[0], s.horizon[1], s.horizon[2], settings.gradient_exponent },
        .ground = .{ s.ground[0], s.ground[1], s.ground[2], settings.ground_sharpness },
        .sun_color = .{ s.sun_color[0], s.sun_color[1], s.sun_color[2], @cos(settings.sun_radius) },
        .moon_color = .{ s.moon_color[0], s.moon_color[1], s.moon_color[2], @cos(settings.moon_radius) },
        .glow = .{ s.glow[0], s.glow[1], s.glow[2], settings.glow_exponent },
    };
    if (fog) |f| {
        const c = f.color orelse s.horizon;
        u.fog_color = .{ c[0], c[1], c[2], std.math.clamp(f.max, 0.0, 1.0) };
        u.fog = .{ f.start, f.end, 0, 0 };
    }
    return u;
}

// =============================================================================
// The CPU reference of the WGSL helpers in `wgsl.sky_helpers`
// =============================================================================

fn rgb(v: [4]f32) Vec3 {
    return .{ v[0], v[1], v[2] };
}

/// The normalized device coordinates of the centre of the pixel (x, y) of a
/// target `width` by `height`.
pub fn pixelNdc(x: u32, y: u32, width: u32, height: u32) [2]f32 {
    const fx = @as(f32, @floatFromInt(x)) + 0.5;
    const fy = @as(f32, @floatFromInt(y)) + 0.5;
    return .{ fx / @as(f32, @floatFromInt(width)) * 2.0 - 1.0, 1.0 - fy / @as(f32, @floatFromInt(height)) * 2.0 };
}

/// `sw_view_ray`: the unit view ray in world space at `ndc`. `view` and
/// `proj` are column-major, as in `FrameUniforms`.
pub fn viewRay(view: [16]f32, proj: [16]f32, ndc: [2]f32) Vec3 {
    const v: Vec3 = .{ (ndc[0] + proj[8]) / proj[0], (ndc[1] + proj[9]) / proj[5], -1.0 };
    return normalize(.{
        dot(.{ view[0], view[1], view[2] }, v),
        dot(.{ view[4], view[5], view[6] }, v),
        dot(.{ view[8], view[9], view[10] }, v),
    });
}

/// `sw_sky_disc`.
pub fn disc(d: f32, cos_r: f32) f32 {
    const w = @max((1.0 - cos_r) * 0.25, 1e-6);
    return smoothstep(cos_r - w, cos_r + w, d);
}

/// `sw_sky_gradient`.
pub fn gradient(u: SkyUniforms, dir: Vec3) Vec3 {
    if (dir[1] >= 0.0) {
        return mix(rgb(u.horizon), rgb(u.zenith), std.math.pow(f32, @max(dir[1], 1e-12), u.horizon[3]));
    }
    return mix(rgb(u.horizon), rgb(u.ground), @min(-dir[1] * u.ground[3], 1.0));
}

/// `sw_sky_lights`.
pub fn lights(u: SkyUniforms, dir: Vec3) Vec3 {
    const above = smoothstep(-0.02, 0.02, dir[1]);
    const ds = dot(dir, rgb(u.sun_dir));
    const dm = dot(dir, rgb(u.moon_dir));
    var c = scale(rgb(u.glow), std.math.pow(f32, @max(ds, 1e-6), u.glow[3]));
    c = add(c, scale(rgb(u.sun_color), disc(ds, u.sun_color[3]) * above));
    c = add(c, scale(rgb(u.moon_color), disc(dm, u.moon_color[3]) * above));
    return c;
}

/// `sw_sky_color`: the sky colour along `dir`, with no stars.
pub fn color(u: SkyUniforms, dir: Vec3) Vec3 {
    return add(gradient(u, dir), lights(u, dir));
}

/// `sw_fog_amount`.
pub fn fogAmount(u: SkyUniforms, dist: f32) f32 {
    const t = std.math.clamp((dist - u.fog[0]) / @max(u.fog[1] - u.fog[0], 1e-4), 0.0, 1.0);
    return t * u.fog_color[3];
}

/// `sw_fog`, with the distance from the camera.
pub fn applyFog(u: SkyUniforms, c: Vec3, dist: f32) Vec3 {
    return mix(c, rgb(u.fog_color), fogAmount(u, dist));
}

/// The distance from the camera of the point at a pixel, from its depth
/// (REQ-GPU-030). `ndc` is the pixel centre in normalised device
/// coordinates (x right, y up, -1 to 1). `depth` is the value of the depth
/// target (0 to 1). `proj` is the column-major projection matrix: a
/// perspective or an orthographic projection with no rotation. It is the
/// CPU reference of `sw_view_distance` in `post.depth_fog_shader`.
pub fn depthDistance(proj: [16]f32, ndc: [2]f32, depth: f32) f32 {
    const z = (proj[14] - depth * proj[15]) / (depth * proj[11] - proj[10]);
    const w = proj[11] * z + proj[15];
    const x = (ndc[0] * w - proj[8] * z - proj[12]) / proj[0];
    const y = (ndc[1] * w - proj[9] * z - proj[13]) / proj[5];
    return @sqrt(x * x + y * y + z * z);
}

/// The colour of the fog post effect for a pixel (REQ-GPU-030): `c` with
/// `sw_fog` at the distance of `depthDistance`. A pixel with no geometry
/// (depth 1) keeps its colour.
pub fn depthFog(u: SkyUniforms, proj: [16]f32, c: Vec3, ndc: [2]f32, depth: f32) Vec3 {
    if (depth >= 1.0) return c;
    return applyFog(u, c, depthDistance(proj, ndc, depth));
}

// =============================================================================
// The sky pass
// =============================================================================

/// The uniforms of the sky pass, with the memory layout of `SwSkyPass` in
/// `shader`.
pub const PassUniforms = extern struct {
    /// World direction to star space. The stars turn with the sun.
    star_rotation: [16]f32 = wgsl.identity,
    /// x: density, y: radius, z: fraction, w: brightness (`Stars`).
    stars: [4]f32 = .{ 60, 0.25, 0, 0 },
    /// rgb: the multiplier of the cube-map colour. w: 1 when the cube map
    /// is on.
    cube: [4]f32 = .{ 1, 1, 1, 0 },
};

/// The sky pass uniforms at the time of `s`. `cube_tint` null: no cube map.
pub fn passUniforms(s: State, settings: Settings, cube_tint: ?Vec3) PassUniforms {
    // Star space: turn the world back by the tilt, then by the sun angle.
    // The sun is then at +X at each time.
    const a = -sunAngle(s.time);
    const t = -settings.tilt;
    const ca = @cos(a);
    const sa = @sin(a);
    const ct = @cos(t);
    const st = @sin(t);
    // Rz(a) * Rx(t), as rows.
    const r = [3]Vec3{
        .{ ca, -sa * ct, sa * st },
        .{ sa, ca * ct, -ca * st },
        .{ 0, st, ct },
    };
    var m = wgsl.identity;
    for (0..3) |col| {
        for (0..3) |row| m[col * 4 + row] = r[row][col];
    }
    const tint = cube_tint orelse Vec3{ 1, 1, 1 };
    return .{
        .star_rotation = m,
        .stars = .{ settings.stars.density, @min(settings.stars.radius, 0.25), settings.stars.fraction, s.star_brightness },
        .cube = .{ tint[0], tint[1], tint[2], if (cube_tint != null) 1 else 0 },
    };
}

/// `sw_star_hash`: an integer hash of one star cell.
pub fn starHash(cell: [3]i32) u32 {
    var h: u32 = (@as(u32, @bitCast(cell[0])) *% 73856093) ^
        (@as(u32, @bitCast(cell[1])) *% 19349663) ^
        (@as(u32, @bitCast(cell[2])) *% 83492791);
    h = (h ^ (h >> 16)) *% 0x7feb352d;
    h = (h ^ (h >> 15)) *% 0x846ca68b;
    return h ^ (h >> 16);
}

/// `sw_stars`: the star light along `dir`, before the brightness and the
/// horizon fade, 0 to 1.
pub fn stars(p: PassUniforms, dir: Vec3) f32 {
    const m = p.star_rotation;
    const q: Vec3 = .{
        (m[0] * dir[0] + m[4] * dir[1] + m[8] * dir[2]) * p.stars[0],
        (m[1] * dir[0] + m[5] * dir[1] + m[9] * dir[2]) * p.stars[0],
        (m[2] * dir[0] + m[6] * dir[1] + m[10] * dir[2]) * p.stars[0],
    };
    const cell: Vec3 = .{ @floor(q[0]), @floor(q[1]), @floor(q[2]) };
    const h = starHash(.{ @intFromFloat(cell[0]), @intFromFloat(cell[1]), @intFromFloat(cell[2]) });
    if (@as(f32, @floatFromInt(h & 0xffff)) >= p.stars[2] * 65536.0) return 0.0;
    const jitter: Vec3 = .{
        @floatFromInt((h >> 16) & 0xff),
        @floatFromInt((h >> 24) & 0xff),
        @floatFromInt((h >> 8) & 0xff),
    };
    const centre = add(add(cell, scale(jitter, 0.5 / 255.0)), .{ 0.25, 0.25, 0.25 });
    const d: Vec3 = .{ q[0] - centre[0], q[1] - centre[1], q[2] - centre[2] };
    const shade = 0.4 + 0.6 * @as(f32, @floatFromInt(h >> 28)) / 15.0;
    return (1.0 - smoothstep(0.0, p.stars[1], @sqrt(dot(d, d)))) * shade;
}

/// The CPU reference of the sky pass `fs_main` along `dir`. `cube` is the
/// cube-map colour along `dir` (any value when the cube map is off).
pub fn passColor(u: SkyUniforms, p: PassUniforms, dir: Vec3, cube: Vec3) Vec3 {
    const base = if (p.cube[3] > 0.5) Vec3{ cube[0] * p.cube[0], cube[1] * p.cube[1], cube[2] * p.cube[2] } else gradient(u, dir);
    const star = stars(p, dir) * p.stars[3] * smoothstep(0.0, 0.1, dir[1]);
    return add(add(base, lights(u, dir)), .{ star, star, star });
}

/// The cube-map face that `dir` reads: 0 +X, 1 -X, 2 +Y, 3 -Y, 4 +Z, 5 -Z.
/// It is also the array layer of the face in the texture.
pub fn cubeFace(dir: Vec3) u3 {
    const ax = @abs(dir[0]);
    const ay = @abs(dir[1]);
    const az = @abs(dir[2]);
    if (ax >= ay and ax >= az) return if (dir[0] >= 0) 0 else 1;
    if (ay >= az) return if (dir[1] >= 0) 2 else 3;
    return if (dir[2] >= 0) 4 else 5;
}

/// The sky pass: one triangle over the target. Group 0 has the frame
/// uniforms, group 1 the pass uniforms, the cube map and its sampler.
pub const shader = wgsl.shader(
    \\struct SwSkyPass {
    \\    star_rotation: mat4x4<f32>,
    \\    stars: vec4<f32>,
    \\    cube: vec4<f32>,
    \\}
    \\@group(1) @binding(0) var<uniform> sw_sky_pass: SwSkyPass;
    \\@group(1) @binding(1) var sw_sky_cube: texture_cube<f32>;
    \\@group(1) @binding(2) var sw_sky_sampler: sampler;
    \\
    \\@vertex fn vs_main(@builtin(vertex_index) vi: u32) -> @builtin(position) vec4<f32> {
    \\    let x = select(-1.0, 3.0, vi == 1u);
    \\    let y = select(-1.0, 3.0, vi == 2u);
    \\    return vec4<f32>(x, y, 0.0, 1.0);
    \\}
    \\
    \\fn sw_star_hash(c: vec3<i32>) -> u32 {
    \\    var h = (bitcast<u32>(c.x) * 73856093u) ^ (bitcast<u32>(c.y) * 19349663u) ^ (bitcast<u32>(c.z) * 83492791u);
    \\    h = (h ^ (h >> 16u)) * 0x7feb352du;
    \\    h = (h ^ (h >> 15u)) * 0x846ca68bu;
    \\    return h ^ (h >> 16u);
    \\}
    \\
    \\fn sw_stars(dir: vec3<f32>) -> f32 {
    \\    let st = sw_sky_pass.stars;
    \\    let q = (sw_sky_pass.star_rotation * vec4<f32>(dir, 0.0)).xyz * st.x;
    \\    let cell = floor(q);
    \\    let h = sw_star_hash(vec3<i32>(cell));
    \\    if (f32(h & 0xffffu) >= st.z * 65536.0) {
    \\        return 0.0;
    \\    }
    \\    let jitter = vec3<f32>(f32((h >> 16u) & 0xffu), f32((h >> 24u) & 0xffu), f32((h >> 8u) & 0xffu));
    \\    let centre = cell + jitter * (0.5 / 255.0) + vec3<f32>(0.25);
    \\    let shade = 0.4 + 0.6 * f32(h >> 28u) / 15.0;
    \\    return (1.0 - smoothstep(0.0, st.y, length(q - centre))) * shade;
    \\}
    \\
    \\@fragment fn fs_main(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    \\    let dir = sw_view_ray(pos.xy);
    \\    let cube = textureSampleLevel(sw_sky_cube, sw_sky_sampler, dir, 0.0).rgb * sw_sky_pass.cube.rgb;
    \\    var c = select(sw_sky_gradient(dir), cube, sw_sky_pass.cube.w > 0.5);
    \\    c += sw_sky_lights(dir);
    \\    c += vec3<f32>(sw_stars(dir) * sw_sky_pass.stars.w * smoothstep(0.0, 0.1, dir.y));
    \\    return vec4<f32>(c, 1.0);
    \\}
    \\
);

/// The bind group of the sky pass.
pub const pass_group: u32 = 1;

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn expectVec(want: Vec3, got: Vec3, tol: f32) !void {
    for (0..3) |i| try testing.expectApproxEqAbs(want[i], got[i], tol);
}

fn luminance(c: Vec3) f32 {
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
}

test "sky: the time of day moves the sun and the moon (REQ-GPU-010)" {
    try testing.expectApproxEqAbs(@as(f32, 0.25), wrapTime(1.25), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.75), wrapTime(-0.25), 1e-6);
    try testing.expectEqual(@as(f32, 0.0), wrapTime(3.0));

    const set: Settings = .{};
    // Sunrise: the sun at the horizon in +X. Noon: high. Sunset: -X.
    // Midnight: below the horizon.
    try expectVec(.{ 1, 0, 0 }, sunDirection(0.25, set.tilt), 1e-5);
    try expectVec(.{ -1, 0, 0 }, sunDirection(0.75, set.tilt), 1e-5);
    try expectVec(.{ 0, @cos(set.tilt), @sin(set.tilt) }, sunDirection(0.5, set.tilt), 1e-5);
    try expectVec(.{ 0, -@cos(set.tilt), -@sin(set.tilt) }, sunDirection(0.0, set.tilt), 1e-5);
    var t: f32 = 0;
    while (t < 1.0) : (t += 0.03125) {
        const s = state(t, set);
        try testing.expectApproxEqAbs(@as(f32, 1.0), dot(s.sun_dir, s.sun_dir), 1e-5);
        // The moon is opposite the sun.
        try expectVec(.{ -s.sun_dir[0], -s.sun_dir[1], -s.sun_dir[2] }, s.moon_dir, 1e-6);
    }
}

test "sky: the colours follow the sun, and the stars show at night only (REQ-GPU-010)" {
    const set: Settings = .{};
    const noon = state(0.5, set);
    const night = state(0.0, set);
    const dusk = state(0.75, set);
    try testing.expectApproxEqAbs(@as(f32, 1.0), noon.daylight, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), night.daylight, 1e-6);
    // The day sky is brighter than the night sky.
    try testing.expect(luminance(noon.zenith) > 10.0 * luminance(night.zenith));
    try testing.expect(luminance(noon.horizon) > 10.0 * luminance(night.horizon));
    // At sunset the horizon is more red than at noon, and the sun glows.
    try testing.expect(dusk.horizon[0] / dusk.horizon[2] > noon.horizon[0] / noon.horizon[2]);
    try testing.expect(dusk.twilight > 0.99 and noon.twilight == 0.0 and night.twilight == 0.0);
    try testing.expect(luminance(dusk.glow) > 0.0 and luminance(noon.glow) == 0.0);
    // The stars: none in the day, full at night.
    try testing.expectEqual(@as(f32, 0.0), noon.star_brightness);
    try testing.expectEqual(@as(f32, 0.0), state(0.27, set).star_brightness);
    try testing.expect(dusk.star_brightness > 0.0 and dusk.star_brightness < night.star_brightness);
    try testing.expectApproxEqAbs(set.stars.brightness, night.star_brightness, 1e-5);
    // No sun light at night, no moon light at noon.
    try testing.expectEqual(@as(f32, 0.0), luminance(night.sun_color));
    try testing.expectEqual(@as(f32, 0.0), luminance(noon.moon_color));
    try testing.expect(luminance(noon.sun_color) > 10.0);
    // The colours change with no jump over the day.
    var prev = state(0.0, set);
    var t: f32 = 1.0 / 512.0;
    while (t < 1.0) : (t += 1.0 / 512.0) {
        const s = state(t, set);
        for (0..3) |i| {
            try testing.expect(@abs(s.horizon[i] - prev.horizon[i]) < 0.05);
            try testing.expect(@abs(s.zenith[i] - prev.zenith[i]) < 0.05);
        }
        prev = s;
    }
}

test "sky: the gradient goes from the horizon to the zenith, and the sun is a disc (REQ-GPU-010)" {
    const set: Settings = .{};
    const s = state(0.5, set);
    const u = uniforms(s, set, null);
    try expectVec(s.horizon, gradient(u, .{ 1, 0, 0 }), 1e-5);
    try expectVec(s.zenith, gradient(u, .{ 0, 1, 0 }), 1e-5);
    try expectVec(s.ground, gradient(u, .{ 0, -1, 0 }), 1e-5);
    // Half way up, the colour is between the two.
    const mid = gradient(u, normalize(.{ 1, 1, 0 }));
    for (0..3) |i| {
        try testing.expect(mid[i] >= @min(s.horizon[i], s.zenith[i]) - 1e-6);
        try testing.expect(mid[i] <= @max(s.horizon[i], s.zenith[i]) + 1e-6);
    }
    // The centre of the sun has the sun colour. Out of the disc, no sun.
    const centre = lights(u, s.sun_dir);
    try testing.expect(centre[0] >= s.sun_color[0]);
    const away = normalize(.{ s.sun_dir[0] + 0.2, s.sun_dir[1], s.sun_dir[2] });
    try testing.expect(lights(u, away)[0] < 0.01);
    try testing.expectApproxEqAbs(@as(f32, 1.0), disc(1.0, @cos(set.sun_radius)), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), disc(@cos(set.sun_radius * 2.0), @cos(set.sun_radius)), 1e-6);
}

test "sky: the fog uses the horizon colour, from the start to the end (REQ-GPU-011)" {
    const set: Settings = .{};
    const s = state(0.3, set);
    const u = uniforms(s, set, .{ .start = 10, .end = 50 });
    try testing.expectEqual(@as(f32, 0.0), fogAmount(u, 5));
    try testing.expectEqual(@as(f32, 0.0), fogAmount(u, 10));
    try testing.expectApproxEqAbs(@as(f32, 0.5), fogAmount(u, 30), 1e-6);
    try testing.expectEqual(@as(f32, 1.0), fogAmount(u, 50));
    try testing.expectEqual(@as(f32, 1.0), fogAmount(u, 500));
    // Full fog has the colour of the sky at the horizon.
    const red: Vec3 = .{ 1, 0, 0 };
    try expectVec(gradient(u, .{ 1, 0, 0 }), applyFog(u, red, 100), 1e-6);
    try expectVec(s.horizon, applyFog(u, red, 100), 1e-6);
    try expectVec(red, applyFog(u, red, 1), 1e-6);
    // The game can give the colour and the most fog.
    const v = uniforms(s, set, .{ .start = 0, .end = 10, .color = .{ 0.2, 0.3, 0.4 }, .max = 0.5 });
    try expectVec(.{ 0.6, 0.15, 0.2 }, applyFog(v, red, 20), 1e-6);
    // No fog: the colour does not change.
    const none = uniforms(s, set, null);
    try expectVec(red, applyFog(none, red, 1e6), 1e-6);
    const default: SkyUniforms = .{};
    try testing.expectEqual(@as(f32, 0.0), fogAmount(default, 1e6));
}

test "sky: the depth gives the camera distance, and the fog post effect gives the sw_fog colour (REQ-GPU-030)" {
    const math = @import("sw_math");
    const proj = math.perspective(std.math.pi / 3.0, 4.0 / 3.0, 0.1, 5000.0);
    const set: Settings = .{};
    const u = uniforms(state(0.5, set), set, .{ .start = 25, .end = 70 });
    const points = [_][3]f32{ .{ 0, 0, -30 }, .{ 5, -2, -48 }, .{ -20, 3, -10 }, .{ 1, 1, -0.5 }, .{ -100, -40, -900 } };
    for (points) |p| {
        const clip = proj.mulVec4(.{ .x = p[0], .y = p[1], .z = p[2], .w = 1 });
        const ndc: [2]f32 = .{ clip.x / clip.w, clip.y / clip.w };
        const depth = clip.z / clip.w;
        const want = @sqrt(p[0] * p[0] + p[1] * p[1] + p[2] * p[2]);
        try testing.expectApproxEqRel(want, depthDistance(proj.data, ndc, depth), 1e-3);
        const c: Vec3 = .{ 0.1, 0.2, 0.3 };
        const got = depthFog(u, proj.data, c, ndc, depth);
        const ref = applyFog(u, c, want);
        for (0..3) |i| try testing.expectApproxEqAbs(ref[i], got[i], 1e-3);
    }
    // An orthographic projection.
    const n: f32 = 0.1;
    const f: f32 = 100;
    const ortho: math.Mat4 = .{ .data = .{ 0.1, 0, 0, 0, 0, 0.1, 0, 0, 0, 0, 1 / (n - f), 0, 0, 0, n / (n - f), 1 } };
    const clip = ortho.mulVec4(.{ .x = 3, .y = -4, .z = -12, .w = 1 });
    try testing.expectApproxEqRel(@as(f32, 13), depthDistance(ortho.data, .{ clip.x, clip.y }, clip.z), 1e-4);
    // No geometry: no fog.
    try testing.expectEqual(Vec3{ 0.1, 0.2, 0.3 }, depthFog(u, proj.data, .{ 0.1, 0.2, 0.3 }, .{ 0, 0 }, 1.0));
}

test "sky: the view ray goes through the pixel" {
    // A camera at the origin that looks down -Z: the centre ray is -Z.
    const proj = [16]f32{ 1.5, 0, 0, 0, 0, 2, 0, 0, 0, 0, -1, -1, 0, 0, -0.1, 0 };
    const ray = viewRay(wgsl.identity, proj, .{ 0, 0 });
    try expectVec(.{ 0, 0, -1 }, ray, 1e-6);
    // The right edge: x / z = 1 / 1.5.
    const r = viewRay(wgsl.identity, proj, .{ 1, 0 });
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 1.5), -r[0] / r[2], 1e-6);
    // A view turned 90 degrees about Y (it looks down -X in the world).
    const c = @cos(@as(f32, std.math.pi / 2.0));
    const view = [16]f32{ c, 0, 1, 0, 0, 1, 0, 0, -1, 0, c, 0, 0, 0, 0, 1 };
    try expectVec(.{ -1, 0, 0 }, viewRay(view, proj, .{ 0, 0 }), 1e-6);
    // The pixel centres.
    const ndc = pixelNdc(0, 0, 4, 2);
    try testing.expectApproxEqAbs(@as(f32, -0.75), ndc[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), ndc[1], 1e-6);
}

test "sky: the stars turn with the sun, and a part of the cells have a star (REQ-GPU-010)" {
    const set: Settings = .{};
    // In star space the sun is at +X at each time.
    var t: f32 = 0;
    while (t < 1.0) : (t += 0.0625) {
        const s = state(t, set);
        const p = passUniforms(s, set, null);
        const m = p.star_rotation;
        const d = s.sun_dir;
        const q: Vec3 = .{
            m[0] * d[0] + m[4] * d[1] + m[8] * d[2],
            m[1] * d[0] + m[5] * d[1] + m[9] * d[2],
            m[2] * d[0] + m[6] * d[1] + m[10] * d[2],
        };
        try expectVec(.{ 1, 0, 0 }, q, 1e-5);
    }
    // The hash is the same each time, and about `fraction` of the cells
    // have a star.
    try testing.expectEqual(starHash(.{ 3, -7, 11 }), starHash(.{ 3, -7, 11 }));
    try testing.expect(starHash(.{ 3, -7, 11 }) != starHash(.{ 3, -7, 12 }));
    var with_star: u32 = 0;
    var x: i32 = -20;
    while (x < 20) : (x += 1) {
        var y: i32 = -20;
        while (y < 20) : (y += 1) {
            if (@as(f32, @floatFromInt(starHash(.{ x, y, 5 }) & 0xffff)) < set.stars.fraction * 65536.0) with_star += 1;
        }
    }
    const part = @as(f32, @floatFromInt(with_star)) / 1600.0;
    try testing.expect(@abs(part - set.stars.fraction) < 0.05);
    // Some directions have a star, and a star is at most 1.
    const p = passUniforms(state(0.0, set), set, null);
    var lit: u32 = 0;
    var i: u32 = 0;
    while (i < 4000) : (i += 1) {
        const a = @as(f32, @floatFromInt(i)) * 0.0137;
        const b = @as(f32, @floatFromInt(i)) * 0.0011;
        const v = stars(p, .{ @cos(a) * @cos(b), @sin(b), @sin(a) * @cos(b) });
        try testing.expect(v >= 0.0 and v <= 1.0);
        if (v > 0.1) lit += 1;
    }
    try testing.expect(lit > 0 and lit < 4000);
}

test "sky: the cube-map face of a direction" {
    try testing.expectEqual(@as(u3, 0), cubeFace(.{ 1, 0.2, -0.3 }));
    try testing.expectEqual(@as(u3, 1), cubeFace(.{ -1, 0.2, -0.3 }));
    try testing.expectEqual(@as(u3, 2), cubeFace(.{ 0.1, 0.9, -0.3 }));
    try testing.expectEqual(@as(u3, 3), cubeFace(.{ 0.1, -0.9, -0.3 }));
    try testing.expectEqual(@as(u3, 4), cubeFace(.{ 0.1, 0.2, 0.7 }));
    try testing.expectEqual(@as(u3, 5), cubeFace(.{ 0.1, 0.2, -0.7 }));
    // The cube map is on only with a tint.
    const s = state(0.5, .{});
    try testing.expectEqual(@as(f32, 0), passUniforms(s, .{}, null).cube[3]);
    try testing.expectEqual(@as(f32, 1), passUniforms(s, .{}, .{ 0.5, 0.5, 0.5 }).cube[3]);
}

test "sky: SwSkyPass in the sky shader has the layout of PassUniforms" {
    try testing.expect(std.mem.startsWith(u8, shader, wgsl.prefix));
    try testing.expectEqual(@as(usize, 0), @offsetOf(PassUniforms, "star_rotation"));
    try testing.expectEqual(@as(usize, 64), @offsetOf(PassUniforms, "stars"));
    try testing.expectEqual(@as(usize, 80), @offsetOf(PassUniforms, "cube"));
    try testing.expectEqual(@as(usize, 96), @sizeOf(PassUniforms));
    try testing.expect(std.mem.indexOf(u8, shader, "star_rotation: mat4x4<f32>,\n    stars: vec4<f32>,\n    cube: vec4<f32>,") != null);
    try testing.expect(std.mem.indexOf(u8, shader, "@group(1) @binding(0) var<uniform> sw_sky_pass") != null);
    try testing.expectEqual(@as(u32, 1), pass_group);
}
