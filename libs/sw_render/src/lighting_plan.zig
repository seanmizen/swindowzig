//! Shadows and point lights with no GPU code: the cascade fit, the light
//! direction from the sky, the uniform layout, the WGSL include and the
//! CPU reference of each WGSL helper (REQ-GPU-016, REQ-GPU-017,
//! REQ-GPU-018).
//!
//! One directional light casts shadows. The view frustum of the camera
//! goes into `cascades` slices, from the near plane to
//! `ShadowSettings.distance`. Each slice has its own depth map, seen from
//! the light with an orthographic projection. A sphere round the slice
//! gives the size of the projection, so the size does not change when the
//! camera turns. The projection moves in steps of one texel, so the edges
//! of a shadow do not move when the camera moves.
//!
//! A scene shader puts `include(group)` after the shared prefix and calls:
//!
//! - `sw_shadow(world_pos, normal)`: 1 in light, 0 in full shadow. It
//!   samples the depth map of the cascade with a PCF filter of 16 taps on
//!   a disk. Before a split, it blends the two cascades (REQ-GPU-042).
//! - `sw_point_lights(world_pos, normal)`: the sum of the point lights.
//!   Multiply it by the albedo.
//! - `sw_light_dir()`: the unit vector to the shadow light.
//!
//! `lighting.zig` makes the depth maps and the passes.

const std = @import("std");
const sw_math = @import("sw_math");
const wgsl = @import("wgsl.zig");

const Mat4 = sw_math.Mat4;
const Vec3 = sw_math.Vec3;

/// The most cascades. The WGSL include declares one depth map for each.
pub const max_cascades = 4;
/// The most point lights in one frame.
pub const max_point_lights = 16;
/// The bind group index of `include(default_group)`.
pub const default_group: u32 = 2;

/// One point light. The light has no shadow.
pub const PointLight = struct {
    /// The position in world space.
    position: [3]f32,
    /// Linear RGB.
    color: [3]f32 = .{ 1, 1, 1 },
    /// Multiplies `color`.
    intensity: f32 = 1,
    /// The light is 0 at this distance and farther.
    radius: f32 = 8,
};

pub const ShadowSettings = struct {
    /// False: `sw_shadow` gives 1 and the shadow passes do not run.
    enabled: bool = true,
    /// The distance from the camera where the shadows stop.
    distance: f32 = 60,
    /// The split of the cascades: 0 gives equal slices, 1 gives slices that
    /// grow by the same factor (more texels near the camera).
    split_lambda: f32 = 0.6,
    /// How far, in world units, a caster can be in front of a cascade
    /// toward the light and still cast into it.
    caster_distance: f32 = 50,
    /// Before the depth compare, the receiver moves along its normal by
    /// this number of texels of cascade 0, or by the PCF radius plus 1
    /// texel if that is more. The distance is times the sine of the angle
    /// between the normal and the light. This stops a surface from
    /// shadowing itself. The distance is the same in world units in each
    /// cascade, so the shadow edge is at the same place in each cascade
    /// (REQ-GPU-042).
    normal_bias: f32 = 2.0,
    /// The receiver moves toward the light by this number of texels of
    /// its cascade. In a cascade where the PCF disk plus 1 texel is more
    /// than the normal bias, the receiver also moves toward the light by
    /// the difference times the tangent of the angle between the normal
    /// and the light. This bias does not move the shadow edge.
    depth_bias: f32 = 1.0,
    /// The tangent in the slope depth bias stops at this value. A larger
    /// value stops more self-shadow on a surface at a steep angle to the
    /// light. A smaller value keeps more of the shadow in a corner.
    max_slope: f32 = 2.0,
    /// The radius of the PCF disk, in texels of cascade 0. The disk has
    /// the same world size in each cascade, but it is 1 texel of the
    /// cascade or more. A wider disk gives a softer edge with smaller
    /// texel steps (REQ-GPU-042).
    filter_radius: f32 = 2.5,
    /// The blend zone before each split, as a fraction of the depth range
    /// of the cascade. In the zone, the two cascades blend, so the shadow
    /// edge has no step at the split (REQ-GPU-042). 0: a hard change.
    blend: f32 = 0.25,
    /// 1: full shadow. 0: no shadow.
    strength: f32 = 1.0,
};

pub const Error = error{ BadCascadeCount, TooManyPointLights };

// =============================================================================
// GPU layouts
// =============================================================================

/// One point light in `LightingUniforms`: `SwPointLight` in the include.
pub const PointLightUniforms = extern struct {
    /// xyz: the position. w: the radius.
    pos_radius: [4]f32 = .{ 0, 0, 0, 1 },
    /// rgb: the colour. w: the intensity.
    color: [4]f32 = .{ 0, 0, 0, 0 },
};

/// The lighting of one frame: `SwLighting` in the include.
pub const LightingUniforms = extern struct {
    /// World space to the clip space of each cascade, column-major.
    cascades: [max_cascades][16]f32 = @splat(wgsl.identity),
    /// The far view depth of each cascade.
    splits: [4]f32 = @splat(0),
    /// The world size of one texel of each cascade.
    texel: [4]f32 = @splat(0),
    /// xyz: the unit vector to the light. w: 1 when the shadows are on.
    light_dir: [4]f32 = .{ 0, 1, 0, 0 },
    /// x: 1 / map size. y: the blend zone, a fraction of the depth range
    /// of a cascade. z: the depth bias in texels. w: the strength.
    params: [4]f32 = .{ 1, 0, 0, 1 },
    /// The world radius of the PCF disk of each cascade.
    radius: [4]f32 = @splat(0),
    /// The world depth bias of each cascade for each unit of the tangent
    /// of the angle between the normal and the light.
    slope: [4]f32 = @splat(0),
    /// x: the world distance of the normal bias, the same in each cascade.
    /// y: the largest tangent for `slope`. z, w: not used.
    bias: [4]f32 = .{ 0, 0, 0, 0 },
    /// x: the cascade count. y: the point light count.
    counts: [4]u32 = @splat(0),
    points: [max_point_lights]PointLightUniforms = @splat(.{}),
};

/// The WGSL of `SwPointLight` and `SwLighting`.
pub const structs =
    \\struct SwPointLight {
    \\    pos_radius: vec4<f32>,
    \\    color: vec4<f32>,
    \\}
    \\struct SwLighting {
    \\    cascades: array<mat4x4<f32>, 4>,
    \\    splits: vec4<f32>,
    \\    texel: vec4<f32>,
    \\    light_dir: vec4<f32>,
    \\    params: vec4<f32>,
    \\    radius: vec4<f32>,
    \\    slope: vec4<f32>,
    \\    bias: vec4<f32>,
    \\    counts: vec4<u32>,
    \\    points: array<SwPointLight, 16>,
    \\}
    \\
;

/// The WGSL helpers. They read `sw_frame` from the shared prefix.
pub const helpers =
    \\// The unit vector to the shadow light.
    \\fn sw_light_dir() -> vec3<f32> {
    \\    return sw_lighting.light_dir.xyz;
    \\}
    \\
    \\// The cascade of the world position. The cascade count: no shadow.
    \\fn sw_shadow_cascade(world_pos: vec3<f32>) -> u32 {
    \\    let depth = -(sw_frame.view * vec4<f32>(world_pos, 1.0)).z;
    \\    let n = sw_lighting.counts.x;
    \\    for (var i = 0u; i < n; i += 1u) {
    \\        if (depth < sw_lighting.splits[i]) {
    \\            return i;
    \\        }
    \\    }
    \\    return n;
    \\}
    \\
    \\// One filtered depth compare in the map of `cascade`.
    \\fn sw_shadow_tap(cascade: u32, uv: vec2<f32>, depth: f32) -> f32 {
    \\    switch cascade {
    \\        case 0u: { return textureSampleCompareLevel(sw_shadow_map_0, sw_shadow_sampler, uv, depth); }
    \\        case 1u: { return textureSampleCompareLevel(sw_shadow_map_1, sw_shadow_sampler, uv, depth); }
    \\        case 2u: { return textureSampleCompareLevel(sw_shadow_map_2, sw_shadow_sampler, uv, depth); }
    \\        default: { return textureSampleCompareLevel(sw_shadow_map_3, sw_shadow_sampler, uv, depth); }
    \\    }
    \\}
    \\
    \\// The PCF taps. They are on a golden-angle spiral, so they fill the
    \\// disk with no grid that lines up with the texels.
    \\const SW_SHADOW_TAPS = 16u;
    \\
    \\// The filtered shadow of cascade `c`: 1 in light. The normal bias has
    \\// the same world size in each cascade, so the shadow edge is at the
    \\// same place in each cascade. A cascade with larger texels gets more
    \\// depth bias. The depth bias does not move the shadow edge.
    \\fn sw_shadow_pcf(c: u32, world_pos: vec3<f32>, normal: vec3<f32>) -> f32 {
    \\    let l = sw_lighting.light_dir.xyz;
    \\    let n_dot_l = clamp(dot(normal, l), -1.0, 1.0);
    \\    let sine = sqrt(1.0 - n_dot_l * n_dot_l);
    \\    let tangent = min(sine / max(abs(n_dot_l), 1e-4), sw_lighting.bias.y);
    \\    let depth_bias = sw_lighting.texel[c] * sw_lighting.params.z + sw_lighting.slope[c] * tangent;
    \\    let q = world_pos + normal * (sw_lighting.bias.x * sine) + l * depth_bias;
    \\    let p = sw_lighting.cascades[c] * vec4<f32>(q, 1.0);
    \\    let uv = vec2<f32>(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
    \\    if (p.z > 1.0 || uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) {
    \\        return 1.0;
    \\    }
    \\    // Each tap turns by the golden angle.
    \\    let turn = mat2x2<f32>(-0.73736888, 0.67549029, -0.67549029, -0.73736888);
    \\    var dir = vec2<f32>(sw_lighting.radius[c] / sw_lighting.texel[c] * sw_lighting.params.x, 0.0);
    \\    var sum = 0.0;
    \\    for (var i = 0u; i < SW_SHADOW_TAPS; i += 1u) {
    \\        let k = sqrt((f32(i) + 0.5) / f32(SW_SHADOW_TAPS));
    \\        sum += sw_shadow_tap(c, uv + dir * k, p.z);
    \\        dir = turn * dir;
    \\    }
    \\    return sum / f32(SW_SHADOW_TAPS);
    \\}
    \\
    \\// The blend weight of the cascade after `c` at the view depth `depth`:
    \\// 0 before the blend zone at the end of cascade `c`, 1 at its split.
    \\// The last cascade gives 0.
    \\fn sw_shadow_blend(c: u32, depth: f32) -> f32 {
    \\    let zone = sw_lighting.params.y;
    \\    if (c + 1u >= sw_lighting.counts.x || zone <= 0.0) {
    \\        return 0.0;
    \\    }
    \\    let split = sw_lighting.splits[c];
    \\    let start = select(0.0, sw_lighting.splits[max(c, 1u) - 1u], c > 0u);
    \\    let f = (depth - start) / max(split - start, 1e-6);
    \\    return clamp((f - (1.0 - zone)) / zone, 0.0, 1.0);
    \\}
    \\
    \\// 1 in light, 0 in full shadow. `normal` is the unit surface normal.
    \\// In the blend zone before a split, the two cascades blend. Thus the
    \\// shadow edge has no step at the split.
    \\fn sw_shadow(world_pos: vec3<f32>, normal: vec3<f32>) -> f32 {
    \\    if (sw_lighting.light_dir.w == 0.0) {
    \\        return 1.0;
    \\    }
    \\    let c = sw_shadow_cascade(world_pos);
    \\    if (c >= sw_lighting.counts.x) {
    \\        return 1.0;
    \\    }
    \\    let depth = -(sw_frame.view * vec4<f32>(world_pos, 1.0)).z;
    \\    let b = sw_shadow_blend(c, depth);
    \\    var s = sw_shadow_pcf(c, world_pos, normal);
    \\    if (b > 0.0) {
    \\        s = mix(s, sw_shadow_pcf(c + 1u, world_pos, normal), b);
    \\    }
    \\    return mix(1.0, s, sw_lighting.params.w);
    \\}
    \\
    \\// The light of point light `i` on a surface. Multiply it by the albedo.
    \\fn sw_point_light(i: u32, world_pos: vec3<f32>, normal: vec3<f32>) -> vec3<f32> {
    \\    let pl = sw_lighting.points[i];
    \\    let d = pl.pos_radius.xyz - world_pos;
    \\    let dist2 = dot(d, d);
    \\    let r = max(pl.pos_radius.w, 1e-4);
    \\    let x = dist2 / (r * r);
    \\    let window = clamp(1.0 - x * x, 0.0, 1.0);
    \\    let falloff = window * window / (dist2 + 1.0);
    \\    let n_dot_l = max(dot(normal, d * inverseSqrt(max(dist2, 1e-8))), 0.0);
    \\    return pl.color.rgb * (pl.color.w * falloff * n_dot_l);
    \\}
    \\
    \\// The sum of the point lights on a surface. Multiply it by the albedo.
    \\fn sw_point_lights(world_pos: vec3<f32>, normal: vec3<f32>) -> vec3<f32> {
    \\    var c = vec3<f32>(0.0);
    \\    for (var i = 0u; i < sw_lighting.counts.y; i += 1u) {
    \\        c += sw_point_light(i, world_pos, normal);
    \\    }
    \\    return c;
    \\}
    \\
;

/// The binding of the lighting uniforms in the lighting group.
pub const uniforms_binding: u32 = 0;
/// The binding of the comparison sampler.
pub const sampler_binding: u32 = 1;
/// The binding of the depth map of cascade 0. Cascade `i` is at
/// `map_binding + i`.
pub const map_binding: u32 = 2;

/// The WGSL include for the bind group `group`. Put it after the shared
/// prefix (`wgsl.prefix`).
pub fn include(comptime group: u32) []const u8 {
    const g = std.fmt.comptimePrint("{d}", .{group});
    return structs ++
        "@group(" ++ g ++ ") @binding(0) var<uniform> sw_lighting: SwLighting;\n" ++
        "@group(" ++ g ++ ") @binding(1) var sw_shadow_sampler: sampler_comparison;\n" ++
        "@group(" ++ g ++ ") @binding(2) var sw_shadow_map_0: texture_depth_2d;\n" ++
        "@group(" ++ g ++ ") @binding(3) var sw_shadow_map_1: texture_depth_2d;\n" ++
        "@group(" ++ g ++ ") @binding(4) var sw_shadow_map_2: texture_depth_2d;\n" ++
        "@group(" ++ g ++ ") @binding(5) var sw_shadow_map_3: texture_depth_2d;\n\n" ++
        helpers;
}

/// The shared prefix, the include at `group`, then the shader `body`.
pub fn shader(comptime group: u32, comptime body: []const u8) []const u8 {
    return wgsl.prefix ++ include(group) ++ body;
}

// =============================================================================
// The light direction
// =============================================================================

fn len3(v: [3]f32) f32 {
    return @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
}

fn normalize3(v: [3]f32) [3]f32 {
    const l = len3(v);
    if (l == 0) return .{ 0, 1, 0 };
    return .{ v[0] / l, v[1] / l, v[2] / l };
}

fn dot3(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

/// The shadow light of a frame: the sun when it is above the horizon, else
/// the moon. The sky of `FrameUniforms.sky` gives both directions.
pub fn lightFromSky(sky: wgsl.SkyUniforms) [3]f32 {
    const sun: [3]f32 = .{ sky.sun_dir[0], sky.sun_dir[1], sky.sun_dir[2] };
    const moon: [3]f32 = .{ sky.moon_dir[0], sky.moon_dir[1], sky.moon_dir[2] };
    return normalize3(if (sun[1] >= moon[1]) sun else moon);
}

// =============================================================================
// The cascades
// =============================================================================

/// The cascade split distances from `near` to `far`: `out[i]` is the far
/// view depth of cascade `i`. The last one is `far`.
pub fn splitDistances(near: f32, far: f32, lambda: f32, out: []f32) void {
    const n: f32 = @floatFromInt(out.len);
    for (out, 1..) |*d, i| {
        const f = @as(f32, @floatFromInt(i)) / n;
        const uniform = near + (far - near) * f;
        // A near plane at 0 has no logarithmic split.
        const logarithmic = if (near > 0) near * std.math.pow(f32, far / near, f) else uniform;
        d.* = lambda * logarithmic + (1 - lambda) * uniform;
    }
    out[out.len - 1] = far;
}

/// The near and far view depths of a projection. Far is infinity for an
/// infinite perspective projection.
pub fn projectionRange(proj: [16]f32) [2]f32 {
    if (proj[11] == 0) {
        // Orthographic: depth = p10 * z + p14.
        return .{ proj[14] / proj[10], (proj[14] - 1) / proj[10] };
    }
    const near = proj[14] / proj[10];
    const far = if (proj[10] == -1) std.math.inf(f32) else proj[14] / (proj[10] + 1);
    return .{ near, far };
}

/// The point in view space at NDC `ndc` and view depth `depth`.
fn viewPoint(proj: [16]f32, ndc: [2]f32, depth: f32) [3]f32 {
    if (proj[11] == 0) {
        return .{ (ndc[0] - proj[12]) / proj[0], (ndc[1] - proj[13]) / proj[5], -depth };
    }
    return .{ depth * (ndc[0] + proj[8]) / proj[0], depth * (ndc[1] + proj[9]) / proj[5], -depth };
}

/// The world point of a view point, for a rigid `view`.
fn viewToWorld(view: [16]f32, p: [3]f32) [3]f32 {
    const u: [3]f32 = .{ p[0] - view[12], p[1] - view[13], p[2] - view[14] };
    // The rotation rows are (view[i], view[4 + i], view[8 + i]).
    var w: [3]f32 = undefined;
    for (0..3) |c| w[c] = view[c * 4 + 0] * u[0] + view[c * 4 + 1] * u[1] + view[c * 4 + 2] * u[2];
    return w;
}

/// The eight world corners of the view slice from depth `d0` to `d1`.
pub fn sliceCorners(view: [16]f32, proj: [16]f32, d0: f32, d1: f32) [8][3]f32 {
    var out: [8][3]f32 = undefined;
    var i: usize = 0;
    for ([_]f32{ d0, d1 }) |d| {
        for ([_]f32{ -1, 1 }) |y| {
            for ([_]f32{ -1, 1 }) |x| {
                out[i] = viewToWorld(view, viewPoint(proj, .{ x, y }, d));
                i += 1;
            }
        }
    }
    return out;
}

/// One fitted cascade.
pub const Cascade = struct {
    /// World space to the clip space of the cascade (x, y in -1 to 1,
    /// depth in 0 to 1).
    view_proj: Mat4,
    /// The far view depth of the cascade.
    split: f32,
    /// The world size of one texel.
    texel: f32,
};

/// An orthographic projection: x and y in -r to r, view depth 0 to `far`.
fn ortho(r: f32, far: f32) Mat4 {
    var m = Mat4.identity();
    m.data[0] = 1 / r;
    m.data[5] = 1 / r;
    m.data[10] = -1 / far;
    m.data[14] = 0;
    return m;
}

/// Fit one cascade round the world points `corners`, seen from the light
/// `light_dir` (unit vector to the light), on a map of `map_size` texels.
pub fn fitCascade(corners: []const [3]f32, light_dir: [3]f32, map_size: u32, caster_distance: f32) struct { view_proj: Mat4, texel: f32 } {
    var centre: [3]f32 = .{ 0, 0, 0 };
    for (corners) |c| {
        for (0..3) |a| centre[a] += c[a];
    }
    const n: f32 = @floatFromInt(corners.len);
    for (&centre) |*v| v.* /= n;
    var radius: f32 = 0;
    for (corners) |c| radius = @max(radius, len3(.{ c[0] - centre[0], c[1] - centre[1], c[2] - centre[2] }));
    // Round up to 1/16 of a unit: a value that does not change with noise
    // in the last bits.
    radius = @ceil(radius * 16) / 16;
    radius = @max(radius, 1.0 / 16.0);

    const l = normalize3(light_dir);
    const back = radius + caster_distance;
    const eye: Vec3 = .{ .x = centre[0] + l[0] * back, .y = centre[1] + l[1] * back, .z = centre[2] + l[2] * back };
    const up: Vec3 = if (@abs(l[1]) > 0.99) .{ .x = 0, .y = 0, .z = 1 } else .{ .x = 0, .y = 1, .z = 0 };
    const view = sw_math.lookAt(eye, .{ .x = centre[0], .y = centre[1], .z = centre[2] }, up);
    var vp = ortho(radius, 2 * radius + caster_distance).mul(view);

    // Move the projection in steps of one texel: the world origin goes to
    // a texel corner.
    const half: f32 = @as(f32, @floatFromInt(map_size)) * 0.5;
    const ox = vp.data[12] * half;
    const oy = vp.data[13] * half;
    vp.data[12] += (@round(ox) - ox) / half;
    vp.data[13] += (@round(oy) - oy) / half;
    return .{ .view_proj = vp, .texel = 2 * radius / @as(f32, @floatFromInt(map_size)) };
}

/// Fit `out.len` cascades for the camera `view` and `proj` (column-major,
/// a rigid view).
pub fn fitCascades(view: [16]f32, proj: [16]f32, light_dir: [3]f32, settings: ShadowSettings, map_size: u32, out: []Cascade) Error!void {
    if (out.len == 0 or out.len > max_cascades) return error.BadCascadeCount;
    const range = projectionRange(proj);
    const near = @max(range[0], 1e-3);
    const far = @max(@min(range[1], settings.distance), near * 1.001);
    var splits: [max_cascades]f32 = undefined;
    splitDistances(near, far, settings.split_lambda, splits[0..out.len]);
    // A cascade also holds the blend zone at the end of the cascade before
    // it (REQ-GPU-042). The zone of cascade 0 is a fraction of 0 to its
    // split, as in `sw_shadow_blend`.
    const zone = blendZone(settings);
    var d0: f32 = 0;
    var start = near;
    for (out, splits[0..out.len]) |*c, d1| {
        const corners = sliceCorners(view, proj, start, d1);
        const fit = fitCascade(&corners, light_dir, map_size, settings.caster_distance);
        c.* = .{ .view_proj = fit.view_proj, .split = d1, .texel = fit.texel };
        start = d1 - zone * (d1 - d0);
        d0 = d1;
    }
}

/// The blend zone of the settings, clamped to 0 to 1.
fn blendZone(settings: ShadowSettings) f32 {
    return std.math.clamp(settings.blend, 0, 1);
}

/// The bias of a cascade in world units (REQ-GPU-042).
pub const CascadeBias = struct {
    /// The radius of the PCF disk.
    radius: f32,
    /// The normal bias. It is the same in each cascade.
    normal: f32,
    /// The depth bias for each unit of the tangent of the angle between
    /// the normal and the light.
    slope: f32,
};

/// The bias of a cascade with texels of world size `texel`. `first` is
/// the texel of cascade 0.
///
/// A PCF tap at the distance `d` from the receiver, on the plane of the
/// receiver, is `d` times the tangent nearer to the light. The normal
/// bias times the sine covers `d` times the tangent when `d` is the
/// normal bias. A tap reads up to 1 texel more with the linear compare.
/// Thus the bias must cover the PCF radius plus 1 texel. A cascade with
/// larger texels gets the difference as depth bias, because a depth
/// bias does not move the shadow edge.
pub fn cascadeBias(settings: ShadowSettings, first: f32, texel: f32) CascadeBias {
    const want = @max(settings.filter_radius, 0);
    // The radius in texels of this cascade: the world radius of cascade 0,
    // but 1 texel or more (or `want`, if it is less than 1).
    const texels = if (texel > 0) @max(want * first / texel, @min(want, 1)) else want;
    const normal = @max(settings.normal_bias, want + 1) * first;
    return .{
        .radius = texels * texel,
        .normal = normal,
        .slope = @max((texels + 1) * texel - normal, 0),
    };
}

/// The lighting uniforms of a frame.
pub fn uniforms(cascades: []const Cascade, light_dir: [3]f32, settings: ShadowSettings, map_size: u32, points: []const PointLight) Error!LightingUniforms {
    if (cascades.len > max_cascades) return error.BadCascadeCount;
    if (points.len > max_point_lights) return error.TooManyPointLights;
    const l = normalize3(light_dir);
    var u: LightingUniforms = .{
        .light_dir = .{ l[0], l[1], l[2], if (settings.enabled) 1 else 0 },
        .params = .{ 1 / @as(f32, @floatFromInt(map_size)), blendZone(settings), settings.depth_bias, std.math.clamp(settings.strength, 0, 1) },
        .bias = .{ 0, @max(settings.max_slope, 0), 0, 0 },
        .counts = .{ @intCast(cascades.len), @intCast(points.len), 0, 0 },
    };
    for (cascades, 0..) |c, i| {
        u.cascades[i] = c.view_proj.data;
        u.splits[i] = c.split;
        u.texel[i] = c.texel;
        const b = cascadeBias(settings, cascades[0].texel, c.texel);
        u.radius[i] = b.radius;
        u.slope[i] = b.slope;
        u.bias[0] = b.normal;
    }
    for (points, 0..) |p, i| {
        u.points[i] = .{
            .pos_radius = .{ p.position[0], p.position[1], p.position[2], p.radius },
            .color = .{ p.color[0], p.color[1], p.color[2], p.intensity },
        };
    }
    return u;
}

// =============================================================================
// CPU reference of the WGSL helpers
// =============================================================================

/// The CPU reference of `sw_point_light`.
pub fn pointLight(p: PointLightUniforms, world_pos: [3]f32, normal: [3]f32) [3]f32 {
    const d: [3]f32 = .{ p.pos_radius[0] - world_pos[0], p.pos_radius[1] - world_pos[1], p.pos_radius[2] - world_pos[2] };
    const dist2 = dot3(d, d);
    const r = @max(p.pos_radius[3], 1e-4);
    const x = dist2 / (r * r);
    const window = std.math.clamp(1 - x * x, 0, 1);
    const falloff = window * window / (dist2 + 1);
    const inv = 1 / @sqrt(@max(dist2, 1e-8));
    const n_dot_l = @max(dot3(normal, .{ d[0] * inv, d[1] * inv, d[2] * inv }), 0);
    const k = p.color[3] * falloff * n_dot_l;
    return .{ p.color[0] * k, p.color[1] * k, p.color[2] * k };
}

/// The CPU reference of `sw_point_lights`.
pub fn pointLights(u: LightingUniforms, world_pos: [3]f32, normal: [3]f32) [3]f32 {
    var c: [3]f32 = .{ 0, 0, 0 };
    for (u.points[0..u.counts[1]]) |p| {
        const l = pointLight(p, world_pos, normal);
        for (0..3) |i| c[i] += l[i];
    }
    return c;
}

/// The CPU reference of `sw_shadow_cascade`.
pub fn cascadeOf(u: LightingUniforms, view: [16]f32, world_pos: [3]f32) u32 {
    const v = (Mat4{ .data = view }).mulVec4(.{ .x = world_pos[0], .y = world_pos[1], .z = world_pos[2], .w = 1 });
    const depth = -v.z;
    for (0..u.counts[0]) |i| {
        if (depth < u.splits[i]) return @intCast(i);
    }
    return u.counts[0];
}

/// A depth map on the CPU, row 0 at the top (v = 0).
pub const DepthMap = struct {
    size: u32,
    depth: []const f32,

    fn at(self: DepthMap, x: i32, y: i32) f32 {
        const m: i32 = @intCast(self.size - 1);
        const cx: usize = @intCast(std.math.clamp(x, 0, m));
        const cy: usize = @intCast(std.math.clamp(y, 0, m));
        return self.depth[cy * self.size + cx];
    }

    /// The CPU reference of `textureSampleCompareLevel` with a linear
    /// `less_equal` comparison sampler and clamp to edge: four compares,
    /// then the bilinear mix.
    pub fn compare(self: DepthMap, uv: [2]f32, ref: f32) f32 {
        const s: f32 = @floatFromInt(self.size);
        const tx = uv[0] * s - 0.5;
        const ty = uv[1] * s - 0.5;
        const x0: i32 = @intFromFloat(@floor(tx));
        const y0: i32 = @intFromFloat(@floor(ty));
        const fx = tx - @floor(tx);
        const fy = ty - @floor(ty);
        const c00: f32 = if (ref <= self.at(x0, y0)) 1 else 0;
        const c10: f32 = if (ref <= self.at(x0 + 1, y0)) 1 else 0;
        const c01: f32 = if (ref <= self.at(x0, y0 + 1)) 1 else 0;
        const c11: f32 = if (ref <= self.at(x0 + 1, y0 + 1)) 1 else 0;
        const top = c00 + (c10 - c00) * fx;
        const bottom = c01 + (c11 - c01) * fx;
        return top + (bottom - top) * fy;
    }
};

/// The number of PCF taps: `SW_SHADOW_TAPS` in the include.
pub const pcf_taps = 16;
/// The golden angle, as the cosine and the sine of the turn from one PCF
/// tap to the next.
const golden_turn: [2]f32 = .{ -0.73736888, 0.67549029 };

/// The offset of each PCF tap, in units of the PCF radius. Tap `i` is at
/// the distance `sqrt((i + 0.5) / pcf_taps)` from the centre, and turns
/// by the golden angle from the tap before it. The CPU reference of the
/// loop of `sw_shadow_pcf`.
pub fn pcfOffsets() [pcf_taps][2]f32 {
    var out: [pcf_taps][2]f32 = undefined;
    var dir: [2]f32 = .{ 1, 0 };
    for (&out, 0..) |*o, i| {
        const k = @sqrt((@as(f32, @floatFromInt(i)) + 0.5) / @as(f32, pcf_taps));
        o.* = .{ dir[0] * k, dir[1] * k };
        const x = golden_turn[0] * dir[0] - golden_turn[1] * dir[1];
        const y = golden_turn[1] * dir[0] + golden_turn[0] * dir[1];
        dir = .{ x, y };
    }
    return out;
}

/// The CPU reference of `sw_shadow_pcf`: the filtered shadow of cascade
/// `cascade` with its CPU depth map, 1 in light.
pub fn shadowPcf(u: LightingUniforms, cascade: u32, map: DepthMap, world_pos: [3]f32, normal: [3]f32) f32 {
    const l: [3]f32 = .{ u.light_dir[0], u.light_dir[1], u.light_dir[2] };
    const n_dot_l = std.math.clamp(dot3(normal, l), -1, 1);
    const sine = @sqrt(1 - n_dot_l * n_dot_l);
    const tangent = @min(sine / @max(@abs(n_dot_l), 1e-4), u.bias[1]);
    const depth_bias = u.texel[cascade] * u.params[2] + u.slope[cascade] * tangent;
    var q: [3]f32 = undefined;
    for (0..3) |i| q[i] = world_pos[i] + normal[i] * (u.bias[0] * sine) + l[i] * depth_bias;
    const p = (Mat4{ .data = u.cascades[cascade] }).mulVec4(.{ .x = q[0], .y = q[1], .z = q[2], .w = 1 });
    const uv: [2]f32 = .{ p.x * 0.5 + 0.5, 0.5 - p.y * 0.5 };
    if (p.z > 1 or uv[0] < 0 or uv[1] < 0 or uv[0] > 1 or uv[1] > 1) return 1;
    const r = u.radius[cascade] / u.texel[cascade] * u.params[0];
    var sum: f32 = 0;
    for (pcfOffsets()) |o| sum += map.compare(.{ uv[0] + o[0] * r, uv[1] + o[1] * r }, p.z);
    return sum / pcf_taps;
}

/// The CPU reference of `sw_shadow_blend`: the blend weight of the
/// cascade after `cascade` at the view depth `depth`. 0 before the blend
/// zone, 1 at the split.
pub fn blendWeight(u: LightingUniforms, cascade: u32, depth: f32) f32 {
    const zone = u.params[1];
    if (cascade + 1 >= u.counts[0] or zone <= 0) return 0;
    const split = u.splits[cascade];
    const start: f32 = if (cascade > 0) u.splits[cascade - 1] else 0;
    const f = (depth - start) / @max(split - start, 1e-6);
    return std.math.clamp((f - (1 - zone)) / zone, 0, 1);
}

/// The CPU reference of `sw_shadow`. `view` is the camera view of
/// `sw_frame`. `maps[i]` is the CPU depth map of cascade `i`.
pub fn shadow(u: LightingUniforms, view: [16]f32, maps: []const DepthMap, world_pos: [3]f32, normal: [3]f32) f32 {
    if (u.light_dir[3] == 0) return 1;
    const c = cascadeOf(u, view, world_pos);
    if (c >= u.counts[0]) return 1;
    const v = (Mat4{ .data = view }).mulVec4(.{ .x = world_pos[0], .y = world_pos[1], .z = world_pos[2], .w = 1 });
    const b = blendWeight(u, c, -v.z);
    var s = shadowPcf(u, c, maps[c], world_pos, normal);
    if (b > 0) s += (shadowPcf(u, c + 1, maps[c + 1], world_pos, normal) - s) * b;
    return 1 + (s - 1) * u.params[3];
}

/// True when the ray from `p` toward the light `light_dir` hits the box
/// from `min` to `max`. A test and an example use it to find a point in a
/// cast shadow.
pub fn rayHitsBox(p: [3]f32, light_dir: [3]f32, min: [3]f32, max: [3]f32) bool {
    var t0: f32 = 0;
    var t1: f32 = std.math.inf(f32);
    for (0..3) |a| {
        if (light_dir[a] == 0) {
            if (p[a] < min[a] or p[a] > max[a]) return false;
            continue;
        }
        const inv = 1 / light_dir[a];
        var ta = (min[a] - p[a]) * inv;
        var tb = (max[a] - p[a]) * inv;
        if (ta > tb) std.mem.swap(f32, &ta, &tb);
        t0 = @max(t0, ta);
        t1 = @min(t1, tb);
    }
    return t0 <= t1;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn transform(m: Mat4, p: [3]f32) [3]f32 {
    const v = m.mulVec4(.{ .x = p[0], .y = p[1], .z = p[2], .w = 1 });
    return .{ v.x / v.w, v.y / v.w, v.z / v.w };
}

const test_proj = sw_math.perspective(std.math.pi / 3.0, 4.0 / 3.0, 0.1, 1000.0);

fn testView(eye: [3]f32, yaw: f32) Mat4 {
    const target: Vec3 = .{ .x = eye[0] - @sin(yaw), .y = eye[1] - 0.2, .z = eye[2] - @cos(yaw) };
    return sw_math.lookAt(.{ .x = eye[0], .y = eye[1], .z = eye[2] }, target, .{ .x = 0, .y = 1, .z = 0 });
}

test "lighting: the split distances grow to the shadow distance (REQ-GPU-016)" {
    var d: [3]f32 = undefined;
    splitDistances(0.1, 60, 0.6, &d);
    try testing.expect(d[0] > 0.1 and d[0] < d[1] and d[1] < d[2]);
    try testing.expectEqual(@as(f32, 60), d[2]);
    // Lambda 0 gives equal slices.
    splitDistances(0, 30, 0, &d);
    try testing.expectApproxEqAbs(@as(f32, 10), d[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 20), d[1], 1e-4);

    const r = projectionRange(test_proj.data);
    try testing.expectApproxEqRel(@as(f32, 0.1), r[0], 1e-4);
    try testing.expectApproxEqRel(@as(f32, 1000), r[1], 1e-2);
}

test "lighting: each cascade holds its view slice, with depth in 0 to 1 (REQ-GPU-016)" {
    const light = normalize3(.{ 0.7, 0.66, 0.24 });
    for ([_]f32{ 0, 0.8, 2.5 }) |yaw| {
        const view = testView(.{ 3, 1.6, 6 }, yaw);
        var cascades: [3]Cascade = undefined;
        try fitCascades(view.data, test_proj.data, light, .{}, 2048, &cascades);
        var d0: f32 = 0.1;
        for (cascades) |c| {
            const corners = sliceCorners(view.data, test_proj.data, d0, c.split);
            for (corners) |w| {
                const p = transform(c.view_proj, w);
                try testing.expect(@abs(p[0]) <= 1.0001 and @abs(p[1]) <= 1.0001);
                try testing.expect(p[2] >= 0 and p[2] <= 1);
            }
            // A caster 40 units toward the light from a corner is still
            // in the depth range, and nearer to the light.
            const far_caster: [3]f32 = .{ corners[0][0] + light[0] * 40, corners[0][1] + light[1] * 40, corners[0][2] + light[2] * 40 };
            const pc = transform(c.view_proj, far_caster);
            try testing.expect(pc[2] >= 0 and pc[2] < transform(c.view_proj, corners[0])[2]);
            d0 = c.split;
        }
        // Later cascades cover more world: bigger texels.
        try testing.expect(cascades[0].texel < cascades[1].texel and cascades[1].texel < cascades[2].texel);
    }
}

test "lighting: the cascade moves in whole texels when the camera moves (REQ-GPU-016)" {
    const light = normalize3(.{ 0.3, 0.9, 0.2 });
    var last: ?Cascade = null;
    for (0..5) |i| {
        const step: f32 = @floatFromInt(i);
        const view = testView(.{ 1 + step * 0.013, 2, 4 - step * 0.007 }, 0.3);
        var c: [1]Cascade = undefined;
        try fitCascades(view.data, test_proj.data, light, .{ .distance = 20 }, 1024, &c);
        // The world origin is on a texel corner.
        const o = transform(c[0].view_proj, .{ 0, 0, 0 });
        const tx = o[0] * 512;
        const ty = o[1] * 512;
        try testing.expectApproxEqAbs(@round(tx), tx, 2e-3);
        try testing.expectApproxEqAbs(@round(ty), ty, 2e-3);
        // The size does not change when the camera moves.
        if (last) |l| try testing.expectEqual(l.texel, c[0].texel);
        last = c[0];
    }
    try testing.expectError(error.BadCascadeCount, fitCascades(wgsl.identity, test_proj.data, light, .{}, 1024, &[_]Cascade{}));
}

test "lighting: the shadow light follows the sun, and the moon at night (REQ-GPU-016)" {
    const sky_plan = @import("sky_plan.zig");
    const day = sky_plan.uniforms(sky_plan.state(0.375, .{}), .{}, null);
    const l = lightFromSky(day);
    try testing.expectApproxEqAbs(day.sun_dir[0], l[0], 1e-6);
    try testing.expectApproxEqAbs(day.sun_dir[1], l[1], 1e-6);
    try testing.expect(l[1] > 0);
    const night = sky_plan.uniforms(sky_plan.state(0.9, .{}), .{}, null);
    const m = lightFromSky(night);
    try testing.expectApproxEqAbs(night.moon_dir[1], m[1], 1e-6);
    try testing.expect(m[1] > 0);
    // The default sky (no sky) gives a light straight down.
    try testing.expectEqual([3]f32{ 0, 1, 0 }, lightFromSky(.{}));
}

/// A cascade for the tests that maps world x and z (0 to `side`) to the
/// map, with depth 1 - y.
fn flatCascade(side: f32) Mat4 {
    var vp = Mat4.identity();
    vp.data[0] = 2 / side;
    vp.data[12] = -1;
    vp.data[5] = 0;
    vp.data[9] = -2 / side;
    vp.data[13] = 1;
    vp.data[10] = 0;
    vp.data[6] = -1;
    vp.data[14] = 1;
    return vp;
}

test "lighting: the CPU PCF gives 0 in a cast shadow, 1 in light, and a soft edge (REQ-GPU-016)" {
    // A map of 16 x 16 texels. The left half has an occluder at depth 0.3.
    // The right half is empty (depth 1).
    const size = 16;
    var depth: [size * size]f32 = undefined;
    for (0..size) |y| {
        for (0..size) |x| depth[y * size + x] = if (x < size / 2) 0.3 else 1.0;
    }
    const map: DepthMap = .{ .size = size, .depth = &depth };
    // A cascade that maps world x and z (in 0 to 1) straight to the map.
    const vp = flatCascade(1);
    var u: LightingUniforms = .{
        .light_dir = .{ 0, 1, 0, 1 },
        .params = .{ 1.0 / @as(f32, size), 0, 0, 1 },
        .counts = .{ 1, 0, 0, 0 },
    };
    u.cascades[0] = vp.data;
    u.splits[0] = 100;
    u.texel[0] = 1.0 / @as(f32, size);
    u.radius[0] = 1.5 / @as(f32, size);
    const up: [3]f32 = .{ 0, 1, 0 };
    const maps = [_]DepthMap{map};
    const view = wgsl.identity;
    // The receiver at y = 0.5 has depth 0.5.
    try testing.expectApproxEqAbs(@as(f32, 0.5), transform(vp, .{ 0.2, 0.5, 0.5 })[2], 1e-6);
    try testing.expectEqual(@as(f32, 0), shadow(u, view, &maps, .{ 0.2, 0.5, 0.5 }, up));
    try testing.expectEqual(@as(f32, 1), shadow(u, view, &maps, .{ 0.8, 0.5, 0.5 }, up));
    const edge = shadow(u, view, &maps, .{ 0.5, 0.5, 0.5 }, up);
    try testing.expect(edge > 0.2 and edge < 0.8);
    // A receiver in front of the occluder is in light.
    try testing.expectEqual(@as(f32, 1), shadow(u, view, &maps, .{ 0.2, 0.8, 0.5 }, up));
    // Half strength gives half shadow.
    u.params[3] = 0.5;
    try testing.expectEqual(@as(f32, 0.5), shadow(u, view, &maps, .{ 0.2, 0.5, 0.5 }, up));
}

test "lighting: the PCF taps fill the disk round its centre (REQ-GPU-042)" {
    const taps = pcfOffsets();
    var mean: [2]f32 = .{ 0, 0 };
    for (taps, 0..) |o, i| {
        const r = @sqrt(o[0] * o[0] + o[1] * o[1]);
        try testing.expectApproxEqAbs(@sqrt((@as(f32, @floatFromInt(i)) + 0.5) / pcf_taps), r, 1e-5);
        mean[0] += o[0] / pcf_taps;
        mean[1] += o[1] / pcf_taps;
    }
    try testing.expect(@abs(mean[0]) < 0.05 and @abs(mean[1]) < 0.05);
    // The WGSL loop has the same count and the same turn.
    try testing.expect(std.mem.indexOf(u8, helpers, std.fmt.comptimePrint("const SW_SHADOW_TAPS = {d}u;", .{pcf_taps})) != null);
    try testing.expect(std.mem.indexOf(u8, helpers, "mat2x2<f32>(-0.73736888, 0.67549029, -0.67549029, -0.73736888)") != null);
}

/// The largest distance, in texels, of the 0.5 line of the shadow from
/// the true edge, on a map where the edge goes `slope` texels to the
/// side for each row: a stair of texels. `radius` is the PCF radius in
/// texels.
fn stairError(radius: f32, slope: f32) f32 {
    const size = 64;
    var depth: [size * size]f32 = undefined;
    for (0..size) |y| {
        for (0..size) |x| {
            const edge = 20 + slope * (@as(f32, @floatFromInt(y)) + 0.5);
            depth[y * size + x] = if (@as(f32, @floatFromInt(x)) + 0.5 < edge) 0.3 else 1.0;
        }
    }
    const map: DepthMap = .{ .size = size, .depth = &depth };
    var u: LightingUniforms = .{
        .light_dir = .{ 0, 1, 0, 1 },
        .params = .{ 1.0 / @as(f32, size), 0, 0, 1 },
        .counts = .{ 1, 0, 0, 0 },
    };
    u.cascades[0] = flatCascade(1).data;
    u.splits[0] = 100;
    u.texel[0] = 1.0 / @as(f32, size);
    u.radius[0] = radius / @as(f32, size);
    // In each row, find the x of the 0.5 line, and its offset from the
    // edge line.
    var offsets: [120]f32 = undefined;
    for (&offsets, 0..) |*o, i| {
        const ty = 20 + @as(f32, @floatFromInt(i)) * 0.2;
        const line = 20 + slope * ty;
        var lo: f32 = line - 8;
        var hi: f32 = line + 8;
        for (0..30) |_| {
            const mid = (lo + hi) / 2;
            const s = shadowPcf(u, 0, map, .{ mid / size, 0.5, ty / size }, .{ 0, 1, 0 });
            if (s < 0.5) lo = mid else hi = mid;
        }
        o.* = lo - line;
    }
    var mean: f32 = 0;
    for (offsets) |o| mean += o / offsets.len;
    var worst: f32 = 0;
    for (offsets) |o| worst = @max(worst, @abs(o - mean));
    return worst;
}

test "lighting: the PCF disk makes the texel steps of an edge small (REQ-GPU-042)" {
    const radius = (ShadowSettings{}).filter_radius;
    for ([_]f32{ 0.15, 0.22, 0.3, 0.4 }) |slope| {
        // One linear compare follows each texel step.
        const one_tap = stairError(0, slope);
        // The disk of the default radius follows the straight edge.
        const disk = stairError(radius, slope);
        try testing.expect(one_tap > 0.35);
        try testing.expect(disk < 0.2 and disk < 0.45 * one_tap);
    }
}

test "lighting: the PCF radius and the normal bias have one world size in each cascade (REQ-GPU-042)" {
    const s: ShadowSettings = .{};
    // Cascade 0: the radius of the settings in texels, and a normal bias
    // of 1 texel more than the radius. No slope bias.
    const b0 = cascadeBias(s, 0.03, 0.03);
    try testing.expectApproxEqAbs(s.filter_radius * 0.03, b0.radius, 1e-6);
    try testing.expectApproxEqAbs((s.filter_radius + 1) * 0.03, b0.normal, 1e-6);
    try testing.expectEqual(@as(f32, 0), b0.slope);
    // Texels 2 times larger: the same world radius and normal bias. The
    // slope bias covers the 1 texel of the linear compare that is larger.
    const b1 = cascadeBias(s, 0.03, 0.06);
    try testing.expectApproxEqAbs(b0.radius, b1.radius, 1e-6);
    try testing.expectEqual(b0.normal, b1.normal);
    try testing.expectApproxEqAbs(b0.radius + 0.06 - b0.normal, b1.slope, 1e-6);
    // Texels 5 times larger: a radius of 1 texel.
    const b2 = cascadeBias(s, 0.03, 0.15);
    try testing.expectApproxEqAbs(@as(f32, 0.15), b2.radius, 1e-6);
    try testing.expectEqual(b0.normal, b2.normal);
    try testing.expectApproxEqAbs(2 * 0.15 - b0.normal, b2.slope, 1e-6);
    // A normal bias in the settings that is more than the radius plus 1.
    try testing.expectApproxEqAbs(6 * 0.03, cascadeBias(.{ .normal_bias = 6 }, 0.03, 0.03).normal, 1e-6);

    const c: [3]Cascade = .{
        .{ .view_proj = Mat4.identity(), .split = 5, .texel = 0.03 },
        .{ .view_proj = Mat4.identity(), .split = 20, .texel = 0.06 },
        .{ .view_proj = Mat4.identity(), .split = 60, .texel = 0.15 },
    };
    const u = try uniforms(&c, .{ 0, 1, 0 }, s, 1024, &.{});
    try testing.expectEqual(b0.normal, u.bias[0]);
    try testing.expectEqual(s.max_slope, u.bias[1]);
    try testing.expectEqual([4]f32{ b0.radius, b1.radius, b2.radius, 0 }, u.radius);
    try testing.expectEqual([4]f32{ b0.slope, b1.slope, b2.slope, 0 }, u.slope);
    try testing.expectEqual(s.blend, u.params[1]);
    try testing.expectEqual(s.depth_bias, u.params[2]);
}

/// Two maps of 64 texels for the tests. Cascade 0 covers the world square
/// 0 to 1, and cascade 1 the square 0 to 4: its texels are 4 times
/// larger. The occluder covers x < 0.5 at the depth 0.3. The view depth
/// is 10 - z, and the split is at the depth 9.5 (z = 0.5).
const TwoCascades = struct {
    d0: [64 * 64]f32,
    d1: [64 * 64]f32,
    view: [16]f32,
    cascades: [2]Cascade,

    fn init(self: *TwoCascades) void {
        for (0..64 * 64) |i| self.d0[i] = if (i % 64 < 32) 0.3 else 1.0;
        for (0..64 * 64) |i| self.d1[i] = if (i % 64 < 8) 0.3 else 1.0;
        var view = Mat4.identity();
        view.data[14] = -10;
        self.view = view.data;
        self.cascades = .{
            .{ .view_proj = flatCascade(1), .split = 9.5, .texel = 1.0 / 64.0 },
            .{ .view_proj = flatCascade(4), .split = 100, .texel = 4.0 / 64.0 },
        };
    }

    fn maps(self: *const TwoCascades) [2]DepthMap {
        return .{ .{ .size = 64, .depth = &self.d0 }, .{ .size = 64, .depth = &self.d1 } };
    }
};

test "lighting: the shadow edge is at the same place in each cascade (REQ-GPU-042)" {
    var t: TwoCascades = undefined;
    t.init();
    const maps = t.maps();
    const u = try uniforms(&t.cascades, .{ 0, 1, 0 }, .{}, 64, &.{});
    // A sloped receiver: the normal bias moves its shadow edge.
    const n = normalize3(.{ -0.6, 0.8, 0 });
    var edges: [2]f32 = undefined;
    for (&edges, 0..) |*e, c| {
        var lo: f32 = 0.3;
        var hi: f32 = 0.9;
        for (0..30) |_| {
            const mid = (lo + hi) / 2;
            if (shadowPcf(u, @intCast(c), maps[c], .{ mid, 0.5, 0.25 }, n) < 0.5) lo = mid else hi = mid;
        }
        e.* = lo;
    }
    // The normal bias moves the edge away from the occluder.
    try testing.expect(edges[0] > 0.5 + 0.5 * u.bias[0] * 0.6);
    // The two edges are less than a quarter texel of cascade 1 apart.
    try testing.expectApproxEqAbs(edges[0], edges[1], 0.25 * t.cascades[1].texel);
}

test "lighting: the blend zone keeps the shadow with no step at the split (REQ-GPU-042)" {
    var t: TwoCascades = undefined;
    t.init();
    const maps = t.maps();
    const u = try uniforms(&t.cascades, .{ 0, 1, 0 }, .{ .blend = 0.05 }, 64, &.{});
    var hard = u;
    hard.params[1] = 0;
    const n = normalize3(.{ -0.6, 0.8, 0 });
    // A point in the soft edge, from z = 0 (cascade 1) to z = 1 (cascade
    // 0). Cascade 1 has the wider soft edge.
    var worst_blend: f32 = 0;
    var worst_hard: f32 = 0;
    var last_blend = shadow(u, t.view, &maps, .{ 0.56, 0.5, 0 }, n);
    var last_hard = shadow(hard, t.view, &maps, .{ 0.56, 0.5, 0 }, n);
    var z: f32 = 0.002;
    while (z < 1) : (z += 0.002) {
        const b = shadow(u, t.view, &maps, .{ 0.56, 0.5, z }, n);
        const h = shadow(hard, t.view, &maps, .{ 0.56, 0.5, z }, n);
        worst_blend = @max(worst_blend, @abs(b - last_blend));
        worst_hard = @max(worst_hard, @abs(h - last_hard));
        last_blend = b;
        last_hard = h;
    }
    // With no blend zone, the soft edge changes in one step at the split.
    try testing.expect(worst_hard > 0.1);
    try testing.expect(worst_blend < 0.01);
    // The blend weight goes from 0 to 1 in the last 5 % of the cascade.
    try testing.expectEqual(@as(f32, 0), blendWeight(u, 0, 9.0));
    try testing.expectApproxEqAbs(@as(f32, 0.5), blendWeight(u, 0, 0.975 * 9.5), 1e-4);
    try testing.expectEqual(@as(f32, 1), blendWeight(u, 0, 9.5));
    // The last cascade has no zone.
    try testing.expectEqual(@as(f32, 0), blendWeight(u, 1, 50));
    try testing.expectEqual(@as(f32, 0), blendWeight(hard, 0, 9.5));
}

test "lighting: a cascade holds the blend zone of the cascade before it (REQ-GPU-042)" {
    const light = normalize3(.{ 0.7, 0.66, 0.24 });
    const settings: ShadowSettings = .{ .distance = 45, .blend = 0.25 };
    for ([_]f32{ 0, 0.8, 2.5 }) |yaw| {
        const view = testView(.{ 3, 1.6, 6 }, yaw);
        var cascades: [3]Cascade = undefined;
        try fitCascades(view.data, test_proj.data, light, settings, 2048, &cascades);
        var prev: f32 = 0;
        for (cascades[0..2], cascades[1..]) |c, next| {
            const zone_start = c.split - settings.blend * (c.split - prev);
            for (sliceCorners(view.data, test_proj.data, zone_start, c.split)) |w| {
                const p = transform(next.view_proj, w);
                try testing.expect(@abs(p[0]) <= 1.0001 and @abs(p[1]) <= 1.0001);
                try testing.expect(p[2] >= 0 and p[2] <= 1);
            }
            prev = c.split;
        }
    }
}

test "lighting: with the shadows off, a shadowed point gets the full light (REQ-GPU-018)" {
    const size = 4;
    const depth: [size * size]f32 = @splat(0);
    const maps = [_]DepthMap{.{ .size = size, .depth = &depth }};
    var c: [1]Cascade = .{.{ .view_proj = Mat4.identity(), .split = 100, .texel = 0.1 }};
    var u = try uniforms(&c, .{ 0, 1, 0 }, .{}, size, &.{});
    try testing.expectEqual(@as(f32, 0), shadow(u, wgsl.identity, &maps, .{ 0, 0, 0.5 }, .{ 0, 1, 0 }));
    u = try uniforms(&c, .{ 0, 1, 0 }, .{ .enabled = false }, size, &.{});
    try testing.expectEqual(@as(f32, 0), u.light_dir[3]);
    try testing.expectEqual(@as(f32, 1), shadow(u, wgsl.identity, &maps, .{ 0, 0, 0.5 }, .{ 0, 1, 0 }));
    u.splits[0] = 1;
    try testing.expectEqual(@as(u32, 1), cascadeOf(u, wgsl.identity, .{ 0, 0, -5 }));
    try testing.expectEqual(@as(u32, 0), cascadeOf(u, wgsl.identity, .{ 0, 0, -0.5 }));
}

test "lighting: a point light is bright near, 0 at its radius, 0 behind the surface (REQ-GPU-017)" {
    const lights = [_]PointLight{.{ .position = .{ 0, 1, 0 }, .color = .{ 1, 0.5, 0.25 }, .intensity = 2, .radius = 4 }};
    var u = try uniforms(&.{}, .{ 0, 1, 0 }, .{}, 1024, &lights);
    try testing.expectEqual(@as(u32, 1), u.counts[1]);
    const up: [3]f32 = .{ 0, 1, 0 };
    // Straight under the light, 1 unit away: window ~1, falloff 1 / 2.
    const under = pointLights(u, .{ 0, 0, 0 }, up);
    const x: f32 = 1.0 / 16.0;
    const w = (1 - x * x) * (1 - x * x);
    try testing.expectApproxEqAbs(2 * w / 2, under[0], 1e-6);
    try testing.expectApproxEqAbs(0.5 * 2 * w / 2, under[1], 1e-6);
    // Less light farther away, and none at the radius.
    const side = pointLights(u, .{ 2, 0, 0 }, up);
    try testing.expect(side[0] > 0 and side[0] < under[0]);
    try testing.expectEqual(@as(f32, 0), pointLights(u, .{ 0, -3, 0 }, up)[0]);
    // A surface that turns away from the light gets none.
    try testing.expectEqual(@as(f32, 0), pointLights(u, .{ 0, 0, 0 }, .{ 0, -1, 0 })[0]);
    // Two lights add.
    const two = [_]PointLight{ lights[0], lights[0] };
    u = try uniforms(&.{}, .{ 0, 1, 0 }, .{}, 1024, &two);
    try testing.expectApproxEqAbs(2 * under[0], pointLights(u, .{ 0, 0, 0 }, up)[0], 1e-6);
    const many: [max_point_lights + 1]PointLight = @splat(lights[0]);
    try testing.expectError(error.TooManyPointLights, uniforms(&.{}, .{ 0, 1, 0 }, .{}, 1024, &many));
}

test "lighting: a ray to the light finds the box that casts the shadow (REQ-GPU-016)" {
    const min: [3]f32 = .{ -0.4, 1, -0.2 };
    const max: [3]f32 = .{ 0.4, 2.2, 0.2 };
    const l = normalize3(.{ 0.7, 0.66, 0.24 });
    const t = 1.6 / l[1];
    try testing.expect(rayHitsBox(.{ -l[0] * t, 0, -l[2] * t }, l, min, max));
    try testing.expect(!rayHitsBox(.{ -l[0] * t, 0, 1.5 }, l, min, max));
    try testing.expect(!rayHitsBox(.{ 0, 3, 0 }, .{ 0, 1, 0 }, min, max));
    try testing.expect(rayHitsBox(.{ 0, 0, 0 }, .{ 0, 1, 0 }, min, max));
}

test "lighting: SwLighting in the include has the layout of LightingUniforms (REQ-GPU-016)" {
    try testing.expectEqual(@as(usize, 32), @sizeOf(PointLightUniforms));
    const offsets = [_]struct { []const u8, usize }{
        .{ "cascades", 0 }, .{ "splits", 256 }, .{ "texel", 272 }, .{ "light_dir", 288 },
        .{ "params", 304 }, .{ "radius", 320 }, .{ "slope", 336 }, .{ "bias", 352 },
        .{ "counts", 368 }, .{ "points", 384 },
    };
    inline for (offsets) |o| try testing.expectEqual(o[1], @offsetOf(LightingUniforms, o[0]));
    try testing.expectEqual(@as(usize, 384 + 32 * max_point_lights), @sizeOf(LightingUniforms));
    try testing.expectEqual(@as(usize, 0), @sizeOf(LightingUniforms) % 16);
    // The WGSL members are in the same order, with the same counts.
    var at: usize = 0;
    inline for (offsets) |o| {
        const i = std.mem.indexOfPos(u8, structs, at, "    " ++ o[0] ++ ":").?;
        try testing.expect(i > at);
        at = i;
    }
    try testing.expect(std.mem.indexOf(u8, structs, "array<mat4x4<f32>, 4>") != null);
    try testing.expect(std.mem.indexOf(u8, structs, "array<SwPointLight, 16>") != null);
    try testing.expectEqual(@as(usize, 4), max_cascades);
    try testing.expectEqual(@as(usize, 16), max_point_lights);

    const text = comptime include(3);
    try testing.expect(std.mem.indexOf(u8, text, "@group(3) @binding(0) var<uniform> sw_lighting: SwLighting;") != null);
    try testing.expect(std.mem.indexOf(u8, text, "@group(3) @binding(5) var sw_shadow_map_3: texture_depth_2d;") != null);
    const full = comptime shader(2, "@fragment fn fs() {}\n");
    try testing.expect(std.mem.startsWith(u8, full, wgsl.prefix));
    try testing.expect(std.mem.indexOf(u8, full, "fn sw_shadow(world_pos: vec3<f32>, normal: vec3<f32>) -> f32") != null);
    try testing.expect(std.mem.indexOf(u8, full, "fn sw_point_lights(world_pos: vec3<f32>, normal: vec3<f32>) -> vec3<f32>") != null);
}
