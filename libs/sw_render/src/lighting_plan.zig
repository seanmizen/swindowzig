//! Shadows and point lights with no GPU code: the cascade fit, the light
//! direction from the sky, the uniform layout, the WGSL include and the
//! CPU reference of each WGSL helper (REQ-GPU-016, REQ-GPU-017,
//! REQ-GPU-018, REQ-GPU-044).
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
//! - `sw_point_lights(world_pos, normal)`: the sum of the point lights,
//!   each one times its own shadow. Multiply it by the albedo.
//! - `sw_light_dir()`: the unit vector to the shadow light.
//!
//! A point light can also cast shadows (REQ-GPU-044). Its shadow map is a
//! cube of depth: one perspective render of 90 degrees for each face
//! (`pointFaceViewProj`). A face holds the perspective depth of its
//! camera. The shader gets the same depth from the major axis of the
//! vector from the light (`pointDepth`). Thus a caster draws with the
//! depth-only pipeline of the cascades. The bias and the PCF disk have the
//! design of the sun shadows (REQ-GPU-042), in texels of the cube face at
//! the receiver.
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
/// The most point lights with a shadow. The WGSL include declares one
/// cube map for each (REQ-GPU-044).
pub const max_point_shadows = 4;
/// The bind group index of `include(default_group)`.
pub const default_group: u32 = 2;

/// One point light.
pub const PointLight = struct {
    /// The position in world space.
    position: [3]f32,
    /// Linear RGB.
    color: [3]f32 = .{ 1, 1, 1 },
    /// Multiplies `color`.
    intensity: f32 = 1,
    /// The light is 0 at this distance and farther.
    radius: f32 = 8,
    /// True: the light casts shadows into a cube shadow map
    /// (REQ-GPU-044). The shadowed lights get the cube maps in the order
    /// of the list. Thus keep them in the same order in each frame. A
    /// shadowed light after the last cube map has no shadow.
    shadow: bool = false,
    /// True: draw the cube map of this light again in this frame. Set it
    /// when a caster near the light moved. A change of `position` or
    /// `radius` draws the cube map again with no mark.
    shadow_changed: bool = false,
};

/// The settings of the sun shadows. The point light shadows use the bias,
/// the PCF radius and the strength too, in texels of the cube face at the
/// receiver (REQ-GPU-044).
pub const ShadowSettings = struct {
    /// False: `sw_shadow` gives 1 and the cascade passes do not run. The
    /// point light shadows do not change.
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
    /// x: the cube map of the shadow, or -1 for no shadow. y: far / (far -
    /// near) of the cube faces. z: the near plane. w: not used. The far
    /// plane is the radius (REQ-GPU-044).
    shadow: [4]f32 = .{ -1, 0, 0, 0 },
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
    /// The point light shadows (REQ-GPU-044). x: 2 / the face size, the
    /// world size of one texel at the distance 1 on the major axis. y: the
    /// normal bias in texels. z: the depth bias in texels. w: the PCF
    /// radius in texels.
    point_shadow: [4]f32 = .{ 0, 0, 0, 0 },
    /// x: the cascade count. y: the point light count.
    counts: [4]u32 = @splat(0),
    points: [max_point_lights]PointLightUniforms = @splat(.{}),
};

/// The WGSL of `SwPointLight` and `SwLighting`.
pub const structs =
    \\struct SwPointLight {
    \\    pos_radius: vec4<f32>,
    \\    color: vec4<f32>,
    \\    shadow: vec4<f32>,
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
    \\    point_shadow: vec4<f32>,
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
    \\// One filtered depth compare in the cube map `slot`.
    \\fn sw_point_shadow_tap(slot: u32, dir: vec3<f32>, depth: f32) -> f32 {
    \\    switch slot {
    \\        case 0u: { return textureSampleCompareLevel(sw_point_shadow_map_0, sw_shadow_sampler, dir, depth); }
    \\        case 1u: { return textureSampleCompareLevel(sw_point_shadow_map_1, sw_shadow_sampler, dir, depth); }
    \\        case 2u: { return textureSampleCompareLevel(sw_point_shadow_map_2, sw_shadow_sampler, dir, depth); }
    \\        default: { return textureSampleCompareLevel(sw_point_shadow_map_3, sw_shadow_sampler, dir, depth); }
    \\    }
    \\}
    \\
    \\// The shadow of point light `i`: 1 in light, 0 in full shadow. A light
    \\// with no cube map gives 1. The bias has the design of
    \\// `sw_shadow_pcf`, in texels of the cube face at the receiver. The
    \\// depth is the perspective depth of the face: the major axis of the
    \\// vector from the light gives it (REQ-GPU-044).
    \\fn sw_point_shadow(i: u32, world_pos: vec3<f32>, normal: vec3<f32>) -> f32 {
    \\    let pl = sw_lighting.points[i];
    \\    if (pl.shadow.x < 0.0) {
    \\        return 1.0;
    \\    }
    \\    let to_light = pl.pos_radius.xyz - world_pos;
    \\    let l = to_light * inverseSqrt(max(dot(to_light, to_light), 1e-12));
    \\    let n_dot_l = clamp(dot(normal, l), -1.0, 1.0);
    \\    let sine = sqrt(max(1.0 - n_dot_l * n_dot_l, 0.0));
    \\    let a = abs(to_light);
    \\    let texel = max(a.x, max(a.y, a.z)) * sw_lighting.point_shadow.x;
    \\    let q = world_pos + normal * (sw_lighting.point_shadow.y * texel * sine) + l * (sw_lighting.point_shadow.z * texel);
    \\    let d = q - pl.pos_radius.xyz;
    \\    let ad = abs(d);
    \\    let m = max(ad.x, max(ad.y, ad.z));
    \\    if (m >= pl.pos_radius.w || m <= pl.shadow.z) {
    \\        return 1.0;
    \\    }
    \\    // The faces hold the directions with z turned (`pointLookup`).
    \\    let dir = vec3<f32>(d.x, d.y, -d.z);
    \\    let w = normalize(dir);
    \\    let other = select(vec3<f32>(0.0, 1.0, 0.0), vec3<f32>(1.0, 0.0, 0.0), abs(w.y) > 0.7);
    \\    let tu = normalize(cross(w, other));
    \\    let tv = cross(w, tu);
    \\    let turn = mat2x2<f32>(-0.73736888, 0.67549029, -0.67549029, -0.73736888);
    \\    var o = vec2<f32>(sw_lighting.point_shadow.w * texel, 0.0);
    \\    let slot = u32(pl.shadow.x);
    \\    var sum = 0.0;
    \\    for (var k = 0u; k < SW_SHADOW_TAPS; k += 1u) {
    \\        let r = sqrt((f32(k) + 0.5) / f32(SW_SHADOW_TAPS));
    \\        let s = dir + (tu * o.x + tv * o.y) * r;
    \\        // Each tap compares the depth of its own point on the disk. The
    \\        // depth of a face changes along its axis, not along the ray.
    \\        let sa = abs(s);
    \\        let depth = pl.shadow.y * (1.0 - pl.shadow.z / max(max(sa.x, max(sa.y, sa.z)), pl.shadow.z));
    \\        sum += sw_point_shadow_tap(slot, s, depth);
    \\        o = turn * o;
    \\    }
    \\    return mix(1.0, sum / f32(SW_SHADOW_TAPS), sw_lighting.params.w);
    \\}
    \\
    \\// The light of point light `i` on a surface, with no shadow. Multiply
    \\// it by the albedo.
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
    \\// The sum of the point lights on a surface, each one times its own
    \\// shadow (REQ-GPU-044). Multiply it by the albedo.
    \\fn sw_point_lights(world_pos: vec3<f32>, normal: vec3<f32>) -> vec3<f32> {
    \\    var c = vec3<f32>(0.0);
    \\    for (var i = 0u; i < sw_lighting.counts.y; i += 1u) {
    \\        let p = sw_point_light(i, world_pos, normal);
    \\        if (any(p > vec3<f32>(0.0))) {
    \\            c += p * sw_point_shadow(i, world_pos, normal);
    \\        }
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
/// The binding of the cube map of point shadow 0. Point shadow `i` is at
/// `point_map_binding + i` (REQ-GPU-044).
pub const point_map_binding: u32 = map_binding + max_cascades;

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
        "@group(" ++ g ++ ") @binding(5) var sw_shadow_map_3: texture_depth_2d;\n" ++
        "@group(" ++ g ++ ") @binding(6) var sw_point_shadow_map_0: texture_depth_cube;\n" ++
        "@group(" ++ g ++ ") @binding(7) var sw_point_shadow_map_1: texture_depth_cube;\n" ++
        "@group(" ++ g ++ ") @binding(8) var sw_point_shadow_map_2: texture_depth_cube;\n" ++
        "@group(" ++ g ++ ") @binding(9) var sw_point_shadow_map_3: texture_depth_cube;\n\n" ++
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
// Point light shadows (REQ-GPU-044)
// =============================================================================

/// The near plane of the cube faces of a light with the radius `radius`:
/// `near`, but not more than half the radius.
pub fn pointNear(radius: f32, near: f32) f32 {
    return @min(near, radius * 0.5);
}

/// True when a light with this radius can have a cube map: the far plane
/// (the radius) is farther than the near plane.
pub fn hasPointShadow(radius: f32, near: f32) bool {
    return radius > 0 and near > 0 and pointNear(radius, near) < radius;
}

/// Put the point shadows into `u`. `slots[i]` is the cube map of point
/// light `i`, or -1 for no shadow. `u.counts[1]` must be the point count.
pub fn setPointShadows(u: *LightingUniforms, settings: ShadowSettings, map_size: u32, near: f32, slots: []const i32) void {
    const radius = @max(settings.filter_radius, 0);
    u.point_shadow = .{
        2 / @as(f32, @floatFromInt(@max(map_size, 1))),
        @max(settings.normal_bias, radius + 1),
        settings.depth_bias,
        radius,
    };
    for (u.points[0..u.counts[1]], 0..) |*p, i| {
        const slot = if (i < slots.len) slots[i] else -1;
        const far = p.pos_radius[3];
        if (slot < 0 or !hasPointShadow(far, near)) {
            p.shadow = .{ -1, 0, 0, 0 };
            continue;
        }
        const n = pointNear(far, near);
        p.shadow = .{ @floatFromInt(slot), far / (far - n), n, 0 };
    }
}

/// The camera of one cube face: the direction it looks, and its up.
pub const CubeFace = struct {
    forward: [3]f32,
    up: [3]f32,
};

/// The camera of each layer of a cube map. A layer holds the directions
/// `d` where the cube lookup of `pointLookup(d)` selects that layer. The
/// WebGPU cube faces are a mirror image of a camera view. The lookup turns
/// z, and the two mirrors cancel. Thus each face has a usual right-handed
/// camera (`lookAt`), with the winding of the cascades.
pub const cube_faces = [6]CubeFace{
    .{ .forward = .{ 1, 0, 0 }, .up = .{ 0, 1, 0 } },
    .{ .forward = .{ -1, 0, 0 }, .up = .{ 0, 1, 0 } },
    .{ .forward = .{ 0, 1, 0 }, .up = .{ 0, 0, 1 } },
    .{ .forward = .{ 0, -1, 0 }, .up = .{ 0, 0, -1 } },
    .{ .forward = .{ 0, 0, -1 }, .up = .{ 0, 1, 0 } },
    .{ .forward = .{ 0, 0, 1 }, .up = .{ 0, 1, 0 } },
};

/// The lookup vector in the cube map of the vector `d` from the light.
pub fn pointLookup(d: [3]f32) [3]f32 {
    return .{ d[0], d[1], -d[2] };
}

/// World space to the clip space of cube face `face` of a light at
/// `position`: a perspective of 90 degrees from `near` to `far`.
pub fn pointFaceViewProj(position: [3]f32, near: f32, far: f32, face: u32) Mat4 {
    const f = cube_faces[face];
    const eye: Vec3 = .{ .x = position[0], .y = position[1], .z = position[2] };
    const target: Vec3 = .{ .x = position[0] + f.forward[0], .y = position[1] + f.forward[1], .z = position[2] + f.forward[2] };
    const up: Vec3 = .{ .x = f.up[0], .y = f.up[1], .z = f.up[2] };
    return sw_math.perspective(std.math.pi / 2.0, 1, near, far).mul(sw_math.lookAt(eye, target, up));
}

/// The depth that a cube face stores for a point at the distance `m` on
/// the major axis from the light. It is the perspective depth of
/// `pointFaceViewProj`.
pub fn pointDepth(near: f32, far: f32, m: f32) f32 {
    return far / (far - near) * (1 - near / m);
}

/// The layer and the texture coordinates of the WebGPU cube lookup of the
/// vector `dir`. Row 0 is at v = 0.
pub fn cubeLookup(dir: [3]f32) struct { layer: u32, uv: [2]f32 } {
    const ax = @abs(dir[0]);
    const ay = @abs(dir[1]);
    const az = @abs(dir[2]);
    var layer: u32 = undefined;
    var sc: f32 = undefined;
    var tc: f32 = undefined;
    var ma: f32 = undefined;
    if (ax >= ay and ax >= az) {
        ma = ax;
        layer = if (dir[0] >= 0) 0 else 1;
        sc = if (dir[0] >= 0) -dir[2] else dir[2];
        tc = -dir[1];
    } else if (ay >= az) {
        ma = ay;
        layer = if (dir[1] >= 0) 2 else 3;
        sc = dir[0];
        tc = if (dir[1] >= 0) dir[2] else -dir[2];
    } else {
        ma = az;
        layer = if (dir[2] >= 0) 4 else 5;
        sc = if (dir[2] >= 0) dir[0] else -dir[0];
        tc = -dir[1];
    }
    return .{ .layer = layer, .uv = .{ (sc / ma + 1) * 0.5, (tc / ma + 1) * 0.5 } };
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

/// A cube depth map on the CPU: 6 layers of `size` x `size` texels, in the
/// layer order of `cube_faces`, row 0 at the top (REQ-GPU-044).
pub const CubeDepthMap = struct {
    size: u32,
    depth: []const f32,

    /// The depth of texel (x, y) of `layer`. A texel one step outside the
    /// layer is the texel of the next layer in the same direction. The GPU
    /// also filters across the edge of a layer.
    fn at(self: CubeDepthMap, layer: u32, x: i32, y: i32) f32 {
        const s: i32 = @intCast(self.size);
        var l = layer;
        var cx = x;
        var cy = y;
        if (x < 0 or y < 0 or x >= s or y >= s) {
            const fs: f32 = @floatFromInt(self.size);
            const sc = (@as(f32, @floatFromInt(x)) + 0.5) / fs * 2 - 1;
            const tc = (@as(f32, @floatFromInt(y)) + 0.5) / fs * 2 - 1;
            const c = cubeLookup(cubeDirection(layer, sc, tc));
            l = c.layer;
            cx = std.math.clamp(@as(i32, @intFromFloat(@floor(c.uv[0] * fs))), 0, s - 1);
            cy = std.math.clamp(@as(i32, @intFromFloat(@floor(c.uv[1] * fs))), 0, s - 1);
        }
        return self.depth[l * self.size * self.size + @as(u32, @intCast(cy)) * self.size + @as(u32, @intCast(cx))];
    }

    /// The CPU reference of `textureSampleCompareLevel` on a cube with a
    /// linear `less_equal` comparison sampler: four compares, then the
    /// bilinear mix. A texel past the edge of a layer comes from the next
    /// layer.
    pub fn compare(self: CubeDepthMap, dir: [3]f32, ref: f32) f32 {
        const c = cubeLookup(dir);
        const s: f32 = @floatFromInt(self.size);
        const tx = c.uv[0] * s - 0.5;
        const ty = c.uv[1] * s - 0.5;
        const x0: i32 = @intFromFloat(@floor(tx));
        const y0: i32 = @intFromFloat(@floor(ty));
        const fx = tx - @floor(tx);
        const fy = ty - @floor(ty);
        const c00: f32 = if (ref <= self.at(c.layer, x0, y0)) 1 else 0;
        const c10: f32 = if (ref <= self.at(c.layer, x0 + 1, y0)) 1 else 0;
        const c01: f32 = if (ref <= self.at(c.layer, x0, y0 + 1)) 1 else 0;
        const c11: f32 = if (ref <= self.at(c.layer, x0 + 1, y0 + 1)) 1 else 0;
        const top = c00 + (c10 - c00) * fx;
        const bottom = c01 + (c11 - c01) * fx;
        return top + (bottom - top) * fy;
    }
};

/// The direction of the point (sc, tc) of `layer`, with sc and tc in -1
/// to 1 on the layer: the inverse of `cubeLookup`.
pub fn cubeDirection(layer: u32, sc: f32, tc: f32) [3]f32 {
    return switch (layer) {
        0 => .{ 1, -tc, -sc },
        1 => .{ -1, -tc, sc },
        2 => .{ sc, 1, tc },
        3 => .{ sc, -1, -tc },
        4 => .{ sc, -tc, 1 },
        else => .{ -sc, -tc, -1 },
    };
}

/// The CPU reference of `sw_point_shadow`: the shadow of point light `i`
/// with its CPU cube map, 1 in light.
pub fn pointShadow(u: LightingUniforms, i: u32, map: CubeDepthMap, world_pos: [3]f32, normal: [3]f32) f32 {
    const pl = u.points[i];
    if (pl.shadow[0] < 0) return 1;
    const pos: [3]f32 = .{ pl.pos_radius[0], pl.pos_radius[1], pl.pos_radius[2] };
    const to_light: [3]f32 = .{ pos[0] - world_pos[0], pos[1] - world_pos[1], pos[2] - world_pos[2] };
    const l = normalize3(to_light);
    const n_dot_l = std.math.clamp(dot3(normal, l), -1, 1);
    const sine = @sqrt(@max(1 - n_dot_l * n_dot_l, 0));
    const texel = majorAxis(to_light) * u.point_shadow[0];
    var d: [3]f32 = undefined;
    for (0..3) |a| d[a] = world_pos[a] + normal[a] * (u.point_shadow[1] * texel * sine) + l[a] * (u.point_shadow[2] * texel) - pos[a];
    const m = majorAxis(d);
    if (m >= pl.pos_radius[3] or m <= pl.shadow[2]) return 1;
    const dir = pointLookup(d);
    const w = normalize3(dir);
    const other: [3]f32 = if (@abs(w[1]) > 0.7) .{ 1, 0, 0 } else .{ 0, 1, 0 };
    const tu = normalize3(cross3(w, other));
    const tv = cross3(w, tu);
    const r = u.point_shadow[3] * texel;
    var sum: f32 = 0;
    for (pcfOffsets()) |o| {
        var s: [3]f32 = undefined;
        for (0..3) |a| s[a] = dir[a] + (tu[a] * o[0] + tv[a] * o[1]) * r;
        // Each tap compares the depth of its own point on the disk.
        const depth = pl.shadow[1] * (1 - pl.shadow[2] / @max(majorAxis(s), pl.shadow[2]));
        sum += map.compare(s, depth);
    }
    return 1 + (sum / pcf_taps - 1) * u.params[3];
}

/// The CPU reference of `sw_point_lights` with shadows. `maps[k]` is the
/// CPU cube map of shadow slot `k`.
pub fn pointLightsShadowed(u: LightingUniforms, maps: []const CubeDepthMap, world_pos: [3]f32, normal: [3]f32) [3]f32 {
    var c: [3]f32 = .{ 0, 0, 0 };
    for (u.points[0..u.counts[1]], 0..) |p, i| {
        const l = pointLight(p, world_pos, normal);
        if (l[0] <= 0 and l[1] <= 0 and l[2] <= 0) continue;
        const s = if (p.shadow[0] < 0) 1 else pointShadow(u, @intCast(i), maps[@intFromFloat(p.shadow[0])], world_pos, normal);
        for (0..3) |k| c[k] += l[k] * s;
    }
    return c;
}

/// The CPU reference of `sw_point_lights` when the game knows the shadow
/// of each light: `shadows[i]` is 1 where light `i` is not blocked, 0
/// where it is. An example check uses it for a point far from each shadow
/// edge.
pub fn pointLightsWith(u: LightingUniforms, world_pos: [3]f32, normal: [3]f32, shadows: []const f32) [3]f32 {
    var c: [3]f32 = .{ 0, 0, 0 };
    for (u.points[0..u.counts[1]], 0..) |p, i| {
        const l = pointLight(p, world_pos, normal);
        const s = if (p.shadow[0] < 0) 1 else 1 + (shadows[i] - 1) * u.params[3];
        for (0..3) |k| c[k] += l[k] * s;
    }
    return c;
}

fn majorAxis(v: [3]f32) f32 {
    return @max(@abs(v[0]), @max(@abs(v[1]), @abs(v[2])));
}

fn cross3(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

/// The distance along the ray from `p` in the direction `dir` to the box
/// from `min` to `max`, or null when the ray does not hit it.
pub fn rayBox(p: [3]f32, dir: [3]f32, min: [3]f32, max: [3]f32) ?f32 {
    var t0: f32 = 0;
    var t1: f32 = std.math.inf(f32);
    for (0..3) |a| {
        if (dir[a] == 0) {
            if (p[a] < min[a] or p[a] > max[a]) return null;
            continue;
        }
        const inv = 1 / dir[a];
        var ta = (min[a] - p[a]) * inv;
        var tb = (max[a] - p[a]) * inv;
        if (ta > tb) std.mem.swap(f32, &ta, &tb);
        t0 = @max(t0, ta);
        t1 = @min(t1, tb);
    }
    return if (t0 <= t1) t0 else null;
}

/// True when the segment from `p` to `q` goes through the box from `min`
/// to `max`. A check uses it to find a point in the shadow of a point
/// light.
pub fn segmentHitsBox(p: [3]f32, q: [3]f32, min: [3]f32, max: [3]f32) bool {
    const d: [3]f32 = .{ q[0] - p[0], q[1] - p[1], q[2] - p[2] };
    const t = rayBox(p, d, min, max) orelse return false;
    return t <= 1;
}

/// True when the ray from `p` toward the light `light_dir` hits the box
/// from `min` to `max`. A test and an example use it to find a point in a
/// cast shadow.
pub fn rayHitsBox(p: [3]f32, light_dir: [3]f32, min: [3]f32, max: [3]f32) bool {
    return rayBox(p, light_dir, min, max) != null;
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
    try testing.expectEqual(@as(usize, 48), @sizeOf(PointLightUniforms));
    const offsets = [_]struct { []const u8, usize }{
        .{ "cascades", 0 },       .{ "splits", 256 }, .{ "texel", 272 },  .{ "light_dir", 288 },
        .{ "params", 304 },       .{ "radius", 320 }, .{ "slope", 336 },  .{ "bias", 352 },
        .{ "point_shadow", 368 }, .{ "counts", 384 }, .{ "points", 400 },
    };
    inline for (offsets) |o| try testing.expectEqual(o[1], @offsetOf(LightingUniforms, o[0]));
    try testing.expectEqual(@as(usize, 400 + 48 * max_point_lights), @sizeOf(LightingUniforms));
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
    try testing.expect(std.mem.indexOf(u8, text, "@group(3) @binding(6) var sw_point_shadow_map_0: texture_depth_cube;") != null);
    try testing.expect(std.mem.indexOf(u8, text, "@group(3) @binding(9) var sw_point_shadow_map_3: texture_depth_cube;") != null);
    try testing.expectEqual(@as(u32, 6), point_map_binding);
    try testing.expectEqual(@as(usize, 4), max_point_shadows);
    // The struct member of the point shadows.
    try testing.expect(std.mem.indexOf(u8, structs, "    shadow: vec4<f32>,\n") != null);
    const full = comptime shader(2, "@fragment fn fs() {}\n");
    try testing.expect(std.mem.startsWith(u8, full, wgsl.prefix));
    try testing.expect(std.mem.indexOf(u8, full, "fn sw_shadow(world_pos: vec3<f32>, normal: vec3<f32>) -> f32") != null);
    try testing.expect(std.mem.indexOf(u8, full, "fn sw_point_lights(world_pos: vec3<f32>, normal: vec3<f32>) -> vec3<f32>") != null);
}

// =============================================================================
// Tests of the point light shadows (REQ-GPU-044)
// =============================================================================

test "lighting: each cube face draws the directions that the WebGPU cube lookup reads (REQ-GPU-044)" {
    const near: f32 = 0.05;
    const far: f32 = 10;
    const light: [3]f32 = .{ 1.5, -2, 0.25 };
    var prng = std.Random.DefaultPrng.init(44);
    const rand = prng.random();
    var seen: [6]bool = @splat(false);
    for (0..2000) |_| {
        var d: [3]f32 = undefined;
        for (&d) |*v| v.* = rand.float(f32) * 8 - 4;
        const m = majorAxis(d);
        if (m < 0.2) continue;
        const c = cubeLookup(pointLookup(d));
        seen[c.layer] = true;
        // The face camera of that layer puts the point at the same texture
        // coordinates, with the depth of `pointDepth`.
        const w: [3]f32 = .{ light[0] + d[0], light[1] + d[1], light[2] + d[2] };
        const p = pointFaceViewProj(light, near, far, c.layer).mulVec4(.{ .x = w[0], .y = w[1], .z = w[2], .w = 1 });
        try testing.expectApproxEqAbs(m, p.w, 1e-4);
        try testing.expectApproxEqAbs(c.uv[0], p.x / p.w * 0.5 + 0.5, 1e-4);
        try testing.expectApproxEqAbs(c.uv[1], 0.5 - p.y / p.w * 0.5, 1e-4);
        try testing.expectApproxEqAbs(pointDepth(near, far, m), p.z / p.w, 1e-5);
    }
    for (seen) |s| try testing.expect(s);
    // `cubeDirection` is the inverse of the lookup.
    for (0..6) |l| {
        for ([_][2]f32{ .{ 0.3, -0.6 }, .{ -0.9, 0.2 }, .{ 0.05, 0.95 } }) |st| {
            const c = cubeLookup(cubeDirection(@intCast(l), st[0], st[1]));
            try testing.expectEqual(@as(u32, @intCast(l)), c.layer);
            try testing.expectApproxEqAbs((st[0] + 1) * 0.5, c.uv[0], 1e-6);
            try testing.expectApproxEqAbs((st[1] + 1) * 0.5, c.uv[1], 1e-6);
        }
    }
    // The depth is 0 at the near plane and 1 at the far plane.
    try testing.expectApproxEqAbs(@as(f32, 0), pointDepth(near, far, near), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), pointDepth(near, far, far), 1e-6);
    // Each face has the winding of a usual camera: the same sign of the
    // determinant of the rows x, y and w as a `lookAt` camera.
    const usual = sw_math.perspective(1, 1, near, far).mul(sw_math.lookAt(.{ .x = 0, .y = 0, .z = 0 }, .{ .x = 0.3, .y = 0.2, .z = -1 }, .{ .x = 0, .y = 1, .z = 0 }));
    const want = std.math.sign(det3Rows(usual));
    for (0..6) |f| try testing.expectEqual(want, std.math.sign(det3Rows(pointFaceViewProj(light, near, far, @intCast(f)))));
}

/// The determinant of the 3 x 3 matrix of the rows x, y and w of the
/// linear part of `m`.
fn det3Rows(m: Mat4) f32 {
    const d = m.data;
    const r0: [3]f32 = .{ d[0], d[4], d[8] };
    const r1: [3]f32 = .{ d[1], d[5], d[9] };
    const r2: [3]f32 = .{ d[3], d[7], d[11] };
    return dot3(r0, cross3(r1, r2));
}

const TestBox = struct { min: [3]f32, max: [3]f32 };

/// Make a CPU cube map of the boxes from a light at `light`: the nearest
/// box on the ray through the centre of each texel, as the GPU draws it.
fn renderCube(allocator: std.mem.Allocator, light: [3]f32, near: f32, far: f32, size: u32, boxes: []const TestBox) ![]f32 {
    const n = size * size;
    const out = try allocator.alloc(f32, 6 * n);
    const s: f32 = @floatFromInt(size);
    for (cube_faces, 0..) |f, layer| {
        const r = normalize3(cross3(f.forward, f.up));
        const up = cross3(r, f.forward);
        for (0..size) |y| {
            for (0..size) |x| {
                const nx = (@as(f32, @floatFromInt(x)) + 0.5) / s * 2 - 1;
                const ny = 1 - (@as(f32, @floatFromInt(y)) + 0.5) / s * 2;
                var dir: [3]f32 = undefined;
                for (0..3) |a| dir[a] = f.forward[a] + r[a] * nx + up[a] * ny;
                // The view depth is t, because the forward part of `dir` is 1.
                var t: f32 = std.math.inf(f32);
                for (boxes) |b| {
                    if (rayBox(light, dir, b.min, b.max)) |h| t = @min(t, h);
                }
                out[layer * n + y * size + x] = if (t >= near and t <= far) pointDepth(near, far, t) else 1;
            }
        }
    }
    return out;
}

/// The uniforms of point lights that cast shadows, slot `i` for light `i`.
fn shadowedUniforms(lights: []const PointLight, settings: ShadowSettings, map_size: u32, near: f32) !LightingUniforms {
    var u = try uniforms(&.{}, .{ 0, 1, 0 }, settings, map_size, lights);
    var slots: [max_point_lights]i32 = undefined;
    for (slots[0..lights.len], 0..) |*s, i| s.* = @intCast(i);
    setPointShadows(&u, settings, map_size, near, slots[0..lights.len]);
    return u;
}

/// The room of the tests: a floor at y = 0, a wall at x = 3, and a crate.
const test_room = [_]TestBox{
    .{ .min = .{ -8, -1, -8 }, .max = .{ 8, 0, 8 } },
    .{ .min = .{ 3, 0, -8 }, .max = .{ 3.5, 4, 8 } },
    .{ .min = .{ 0.8, 0, -0.3 }, .max = .{ 1.4, 0.6, 0.3 } },
};
const test_crate = test_room[2];

/// 1 when no box of `boxes` is between `p` and `light`, at `p` and at
/// four points `margin` to the side. 0 when each one is blocked. Null
/// near an edge.
fn visibleFrom(p: [3]f32, light: [3]f32, boxes: []const TestBox, margin: f32, side: [2][3]f32) ?f32 {
    var lit: u32 = 0;
    var blocked: u32 = 0;
    const offsets = [_][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 }, .{ 0, -1 } };
    for (offsets) |o| {
        var q: [3]f32 = undefined;
        for (0..3) |a| q[a] = p[a] + (side[0][a] * o[0] + side[1][a] * o[1]) * margin;
        var hit = false;
        for (boxes) |b| {
            // Shrink the box a little: a point on its face is not behind it.
            const e: f32 = 1e-3;
            if (segmentHitsBox(q, light, .{ b.min[0] + e, b.min[1] + e, b.min[2] + e }, .{ b.max[0] - e, b.max[1] - e, b.max[2] - e })) hit = true;
        }
        if (hit) blocked += 1 else lit += 1;
    }
    if (lit == offsets.len) return 1;
    if (blocked == offsets.len) return 0;
    return null;
}

const Surface = struct {
    normal: [3]f32,
    side: [2][3]f32,
    /// The point at (0, 0) on the surface.
    origin: [3]f32,
    a_range: [2]f32,
    b_range: [2]f32,
};

/// The floor, the wall, and the top and the near side of the crate.
const test_surfaces = [_]Surface{
    .{ .normal = .{ 0, 1, 0 }, .side = .{ .{ 1, 0, 0 }, .{ 0, 0, 1 } }, .origin = .{ 0, 0, 0 }, .a_range = .{ -4, 2.95 }, .b_range = .{ -4, 4 } },
    .{ .normal = .{ -1, 0, 0 }, .side = .{ .{ 0, 1, 0 }, .{ 0, 0, 1 } }, .origin = .{ 3, 0, 0 }, .a_range = .{ 0.05, 3 }, .b_range = .{ -4, 4 } },
    .{ .normal = .{ 0, 1, 0 }, .side = .{ .{ 1, 0, 0 }, .{ 0, 0, 1 } }, .origin = .{ 0, 0.6, 0 }, .a_range = .{ 0.82, 1.38 }, .b_range = .{ -0.28, 0.28 } },
    .{ .normal = .{ -1, 0, 0 }, .side = .{ .{ 0, 1, 0 }, .{ 0, 0, 1 } }, .origin = .{ 0.8, 0, 0 }, .a_range = .{ 0.02, 0.58 }, .b_range = .{ -0.28, 0.28 } },
};

/// Check the CPU point shadow on each surface of the room: 1 where the
/// light reaches the point, 0 where the crate blocks it. Give the number
/// of points in light and in shadow.
fn checkRoom(light: [3]f32, size: u32) ![2]u32 {
    const near: f32 = 0.05;
    const lights = [_]PointLight{.{ .position = light, .radius = 7, .shadow = true }};
    const u = try shadowedUniforms(&lights, .{}, size, near);
    const depth = try renderCube(testing.allocator, light, pointNear(7, near), 7, size, &test_room);
    defer testing.allocator.free(depth);
    const map: CubeDepthMap = .{ .size = size, .depth = depth };
    var counts: [2]u32 = .{ 0, 0 };
    for (test_surfaces) |sf| {
        var a = sf.a_range[0];
        while (a <= sf.a_range[1]) : (a += 0.07) {
            var b = sf.b_range[0];
            while (b <= sf.b_range[1]) : (b += 0.07) {
                var p: [3]f32 = undefined;
                for (0..3) |k| p[k] = sf.origin[k] + sf.side[0][k] * a + sf.side[1][k] * b;
                // Skip the floor under the crate, and the points that do
                // not face the light.
                if (p[1] < 0.5 and rayHitsBox(p, .{ 0, 1, 0 }, test_crate.min, test_crate.max)) continue;
                const to: [3]f32 = .{ light[0] - p[0], light[1] - p[1], light[2] - p[2] };
                if (dot3(to, sf.normal) <= 0 or len3(to) > 6.5) continue;
                // The soft edge: the PCF disk, the bias and the linear
                // compare, in texels at the point, on the surface.
                const s: ShadowSettings = .{};
                const texel = majorAxis(to) * u.point_shadow[0];
                const n_dot_l = dot3(sf.normal, normalize3(to));
                const margin = (s.filter_radius + u.point_shadow[1] + 2) * texel / @max(n_dot_l, 0.1);
                const want = visibleFrom(p, light, &test_room, margin, sf.side) orelse continue;
                const got = pointShadow(u, 0, map, p, sf.normal);
                if (@abs(got - want) > 1e-3) {
                    std.debug.print("point shadow at {any} (normal {any}) is {d}, want {d}\n", .{ p, sf.normal, got, want });
                    return error.TestUnexpectedResult;
                }
                counts[if (want == 1) 0 else 1] += 1;
            }
        }
    }
    return counts;
}

test "lighting: a point shadow has no acne on a floor, a wall and a crate (REQ-GPU-044)" {
    // A light over the room, and a light near the floor: the floor far
    // from it is at a grazing angle.
    for ([_][3]f32{ .{ 0, 1.5, 0 }, .{ -0.5, 0.3, 0.4 } }) |light| {
        const counts = try checkRoom(light, 256);
        // Many points in light, and many in the shadow of the crate.
        try testing.expect(counts[0] > 1000);
        try testing.expect(counts[1] > 20);
    }
}

test "lighting: a point shadow starts at the foot of the crate, with no gap (REQ-GPU-044)" {
    const near: f32 = 0.05;
    const light: [3]f32 = .{ 0, 1.5, 0 };
    const lights = [_]PointLight{.{ .position = light, .radius = 7, .shadow = true }};
    for ([_]u32{ 256, 512 }) |size| {
        const u = try shadowedUniforms(&lights, .{}, size, near);
        const depth = try renderCube(testing.allocator, light, pointNear(7, near), 7, size, &test_room);
        defer testing.allocator.free(depth);
        const map: CubeDepthMap = .{ .size = size, .depth = depth };
        // The floor behind the crate, 1 cm and 3 cm from its far face.
        for ([_]f32{ -0.2, 0, 0.2 }) |z| {
            try testing.expect(pointShadow(u, 0, map, .{ 1.41, 0, z }, .{ 0, 1, 0 }) < 0.5);
            try testing.expect(pointShadow(u, 0, map, .{ 1.43, 0, z }, .{ 0, 1, 0 }) < 0.05);
        }
        // The floor in front of the crate, 8 cm from its near face, is in
        // light. Nearer, the soft edge of the PCF disk starts.
        try testing.expectEqual(@as(f32, 1), pointShadow(u, 0, map, .{ 0.72, 0, 0 }, .{ 0, 1, 0 }));
    }
}

test "lighting: two point lights give two shadows of one crate (REQ-GPU-044)" {
    const near: f32 = 0.05;
    const crate = [_]TestBox{
        .{ .min = .{ -8, -1, -8 }, .max = .{ 8, 0, 8 } },
        .{ .min = .{ -0.2, 0, -0.3 }, .max = .{ 0.2, 0.5, 0.3 } },
    };
    const lights = [_]PointLight{
        .{ .position = .{ -1, 0.8, 0 }, .color = .{ 1, 0.5, 0.2 }, .intensity = 2, .radius = 4, .shadow = true },
        .{ .position = .{ 1, 0.8, 0 }, .color = .{ 0.2, 0.4, 1 }, .intensity = 2, .radius = 4, .shadow = true },
    };
    const size = 256;
    const u = try shadowedUniforms(&lights, .{}, size, near);
    var maps: [2]CubeDepthMap = undefined;
    var depths: [2][]f32 = undefined;
    for (lights, 0..) |l, i| {
        depths[i] = try renderCube(testing.allocator, l.position, pointNear(l.radius, near), l.radius, size, &crate);
        maps[i] = .{ .size = size, .depth = depths[i] };
    }
    defer for (depths) |d| testing.allocator.free(d);
    const up: [3]f32 = .{ 0, 1, 0 };
    const plain = u.points[0..2];
    // Left of the crate: the crate blocks the right light, and the left
    // light still lights the floor.
    const left: [3]f32 = .{ -0.5, 0, 0 };
    const got_left = pointLightsShadowed(u, &maps, left, up);
    const only_left = pointLight(plain[0], left, up);
    for (0..3) |k| try testing.expectApproxEqAbs(only_left[k], got_left[k], 1e-6);
    try testing.expect(only_left[0] > 0.1 and pointLight(plain[1], left, up)[2] > 0.05);
    // Right of the crate: the other shadow.
    const right: [3]f32 = .{ 0.5, 0, 0 };
    const got_right = pointLightsShadowed(u, &maps, right, up);
    const only_right = pointLight(plain[1], right, up);
    for (0..3) |k| try testing.expectApproxEqAbs(only_right[k], got_right[k], 1e-6);
    // In front of the crate, both lights reach the floor.
    const front: [3]f32 = .{ 0, 0, 1.2 };
    const both = pointLights(u, front, up);
    const got_front = pointLightsShadowed(u, &maps, front, up);
    for (0..3) |k| try testing.expectApproxEqAbs(both[k], got_front[k], 1e-6);
    // The known shadows give the same values.
    for (0..3) |k| try testing.expectApproxEqAbs(got_left[k], pointLightsWith(u, left, up, &.{ 1, 0 })[k], 1e-6);
    // Half strength: half of the blocked light.
    const half = try shadowedUniforms(&lights, .{ .strength = 0.5 }, size, near);
    const got_half = pointLightsShadowed(half, &maps, left, up);
    const blocked = pointLight(plain[1], left, up);
    for (0..3) |k| try testing.expectApproxEqAbs(only_left[k] + 0.5 * blocked[k], got_half[k], 1e-5);
}

test "lighting: a light with no cube map has no shadow (REQ-GPU-044)" {
    const lights = [_]PointLight{
        .{ .position = .{ 0, 1, 0 }, .radius = 4, .shadow = true },
        .{ .position = .{ 0, 1, 0 }, .radius = 4 },
        .{ .position = .{ 0, 1, 0 }, .radius = 0.05, .shadow = true },
    };
    var u = try uniforms(&.{}, .{ 0, 1, 0 }, .{}, 512, &lights);
    setPointShadows(&u, .{}, 512, 0.05, &.{ 2, -1, 0 });
    const far: f32 = 4;
    const near: f32 = 0.05;
    try testing.expectEqual([4]f32{ 2, far / (far - near), near, 0 }, u.points[0].shadow);
    try testing.expectEqual(@as(f32, -1), u.points[1].shadow[0]);
    // A radius near the near plane: the near plane is half the radius.
    try testing.expectEqual(@as(f32, 0), u.points[2].shadow[0]);
    try testing.expectEqual(@as(f32, 0.025), u.points[2].shadow[2]);
    try testing.expect(!hasPointShadow(0, 0.05));
    // The texel and the bias of the settings.
    const s: ShadowSettings = .{};
    try testing.expectEqual([4]f32{ 2.0 / 512.0, s.filter_radius + 1, s.depth_bias, s.filter_radius }, u.point_shadow);
    // A light with no shadow gives 1, with any map.
    const empty: [6]f32 = @splat(0);
    try testing.expectEqual(@as(f32, 1), pointShadow(u, 1, .{ .size = 1, .depth = &empty }, .{ 1, 0, 0 }, .{ 0, 1, 0 }));
}
