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
//!   samples the depth map of the cascade with a 3 x 3 PCF filter.
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
    /// The receiver moves along its normal by this number of texels before
    /// the depth compare. This stops a surface from shadowing itself.
    normal_bias: f32 = 2.0,
    /// The receiver moves toward the light by this number of texels.
    depth_bias: f32 = 1.0,
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
    /// x: 1 / map size. y: the normal bias in texels. z: the depth bias in
    /// texels. w: the strength.
    params: [4]f32 = .{ 1, 0, 0, 1 },
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
    \\// 1 in light, 0 in full shadow. `normal` is the unit surface normal.
    \\// A 3 x 3 PCF filter of linear compares softens the edge.
    \\fn sw_shadow(world_pos: vec3<f32>, normal: vec3<f32>) -> f32 {
    \\    let l = sw_lighting.light_dir;
    \\    if (l.w == 0.0) {
    \\        return 1.0;
    \\    }
    \\    let c = sw_shadow_cascade(world_pos);
    \\    if (c >= sw_lighting.counts.x) {
    \\        return 1.0;
    \\    }
    \\    let t = sw_lighting.texel[c];
    \\    let q = world_pos + normal * (t * sw_lighting.params.y) + l.xyz * (t * sw_lighting.params.z);
    \\    let p = sw_lighting.cascades[c] * vec4<f32>(q, 1.0);
    \\    let uv = vec2<f32>(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
    \\    if (p.z > 1.0 || uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) {
    \\        return 1.0;
    \\    }
    \\    let s = sw_lighting.params.x;
    \\    var sum = 0.0;
    \\    for (var y = -1; y <= 1; y += 1) {
    \\        for (var x = -1; x <= 1; x += 1) {
    \\            sum += sw_shadow_tap(c, uv + vec2<f32>(f32(x), f32(y)) * s, p.z);
    \\        }
    \\    }
    \\    return mix(1.0, sum / 9.0, sw_lighting.params.w);
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
    var d0 = near;
    for (out, splits[0..out.len]) |*c, d1| {
        const corners = sliceCorners(view, proj, d0, d1);
        const fit = fitCascade(&corners, light_dir, map_size, settings.caster_distance);
        c.* = .{ .view_proj = fit.view_proj, .split = d1, .texel = fit.texel };
        d0 = d1;
    }
}

/// The lighting uniforms of a frame.
pub fn uniforms(cascades: []const Cascade, light_dir: [3]f32, settings: ShadowSettings, map_size: u32, points: []const PointLight) Error!LightingUniforms {
    if (cascades.len > max_cascades) return error.BadCascadeCount;
    if (points.len > max_point_lights) return error.TooManyPointLights;
    const l = normalize3(light_dir);
    var u: LightingUniforms = .{
        .light_dir = .{ l[0], l[1], l[2], if (settings.enabled) 1 else 0 },
        .params = .{ 1 / @as(f32, @floatFromInt(map_size)), settings.normal_bias, settings.depth_bias, std.math.clamp(settings.strength, 0, 1) },
        .counts = .{ @intCast(cascades.len), @intCast(points.len), 0, 0 },
    };
    for (cascades, 0..) |c, i| {
        u.cascades[i] = c.view_proj.data;
        u.splits[i] = c.split;
        u.texel[i] = c.texel;
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

/// The CPU reference of `sw_shadow` for cascade `cascade`, with the CPU
/// depth map of that cascade.
pub fn shadow(u: LightingUniforms, cascade: u32, map: DepthMap, world_pos: [3]f32, normal: [3]f32) f32 {
    if (u.light_dir[3] == 0) return 1;
    if (cascade >= u.counts[0]) return 1;
    const t = u.texel[cascade];
    var q: [3]f32 = undefined;
    for (0..3) |i| q[i] = world_pos[i] + normal[i] * (t * u.params[1]) + u.light_dir[i] * (t * u.params[2]);
    const p = (Mat4{ .data = u.cascades[cascade] }).mulVec4(.{ .x = q[0], .y = q[1], .z = q[2], .w = 1 });
    const uv: [2]f32 = .{ p.x * 0.5 + 0.5, 0.5 - p.y * 0.5 };
    if (p.z > 1 or uv[0] < 0 or uv[1] < 0 or uv[0] > 1 or uv[1] > 1) return 1;
    const s = u.params[0];
    var sum: f32 = 0;
    var y: i32 = -1;
    while (y <= 1) : (y += 1) {
        var x: i32 = -1;
        while (x <= 1) : (x += 1) {
            sum += map.compare(.{ uv[0] + @as(f32, @floatFromInt(x)) * s, uv[1] + @as(f32, @floatFromInt(y)) * s }, p.z);
        }
    }
    return 1 + (sum / 9 - 1) * u.params[3];
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
    var vp = Mat4.identity();
    vp.data[0] = 2;
    vp.data[12] = -1;
    vp.data[5] = 0;
    vp.data[9] = -2;
    vp.data[13] = 1;
    vp.data[10] = 0;
    vp.data[6] = -1;
    vp.data[14] = 1;
    var u: LightingUniforms = .{
        .light_dir = .{ 0, 1, 0, 1 },
        .params = .{ 1.0 / @as(f32, size), 0, 0, 1 },
        .counts = .{ 1, 0, 0, 0 },
    };
    u.cascades[0] = vp.data;
    u.splits[0] = 100;
    u.texel[0] = 1.0 / @as(f32, size);
    const up: [3]f32 = .{ 0, 1, 0 };
    // The receiver at y = 0.5 has depth 0.5.
    try testing.expectApproxEqAbs(@as(f32, 0.5), transform(vp, .{ 0.2, 0.5, 0.5 })[2], 1e-6);
    try testing.expectEqual(@as(f32, 0), shadow(u, 0, map, .{ 0.2, 0.5, 0.5 }, up));
    try testing.expectEqual(@as(f32, 1), shadow(u, 0, map, .{ 0.8, 0.5, 0.5 }, up));
    const edge = shadow(u, 0, map, .{ 0.5, 0.5, 0.5 }, up);
    try testing.expect(edge > 0.2 and edge < 0.8);
    // A receiver in front of the occluder is in light.
    try testing.expectEqual(@as(f32, 1), shadow(u, 0, map, .{ 0.2, 0.8, 0.5 }, up));
    // Half strength gives half shadow.
    u.params[3] = 0.5;
    try testing.expectEqual(@as(f32, 0.5), shadow(u, 0, map, .{ 0.2, 0.5, 0.5 }, up));
}

test "lighting: with the shadows off, a shadowed point gets the full light (REQ-GPU-018)" {
    const size = 4;
    const depth: [size * size]f32 = @splat(0);
    const map: DepthMap = .{ .size = size, .depth = &depth };
    var c: [1]Cascade = .{.{ .view_proj = Mat4.identity(), .split = 100, .texel = 0.1 }};
    var u = try uniforms(&c, .{ 0, 1, 0 }, .{}, size, &.{});
    try testing.expectEqual(@as(f32, 0), shadow(u, 0, map, .{ 0, 0, 0.5 }, .{ 0, 1, 0 }));
    u = try uniforms(&c, .{ 0, 1, 0 }, .{ .enabled = false }, size, &.{});
    try testing.expectEqual(@as(f32, 0), u.light_dir[3]);
    try testing.expectEqual(@as(f32, 1), shadow(u, 0, map, .{ 0, 0, 0.5 }, .{ 0, 1, 0 }));
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
        .{ "cascades", 0 }, .{ "splits", 256 }, .{ "texel", 272 },  .{ "light_dir", 288 },
        .{ "params", 304 }, .{ "counts", 320 }, .{ "points", 336 },
    };
    inline for (offsets) |o| try testing.expectEqual(o[1], @offsetOf(LightingUniforms, o[0]));
    try testing.expectEqual(@as(usize, 336 + 32 * max_point_lights), @sizeOf(LightingUniforms));
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
