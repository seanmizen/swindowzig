//! The light shafts with no GPU code (REQ-GPU-033): the settings, the
//! uniforms, the sun position on the screen, the WGSL of the post effect
//! and its CPU reference.
//!
//! The effect is a radial blur toward the sun. For each pixel, it takes
//! samples on the line from the pixel to the sun on the screen. A sample
//! with no geometry (depth 1) adds its HDR colour above `threshold`, so
//! the bright sky near the sun makes rays, and the geometry between makes
//! the gaps. Each sample has `decay` times the weight of the sample
//! before it. When the sun is behind the camera, the effect does nothing.
//!
//! The technique is the screen-space light scattering of GPU Gems 3,
//! chapter 13 (Mitchell). No code of that chapter is in this file.

const std = @import("std");
const wgsl = @import("wgsl.zig");
const post_plan = @import("post_plan.zig");

pub const Vec3 = [3]f32;

pub const ShaftSettings = struct {
    /// The brightness of the shafts.
    strength: f32 = 0.6,
    /// The samples on the line to the sun, for each pixel. More samples
    /// give smooth shafts and cost more.
    samples: u32 = 48,
    /// The part of the line to the sun that the samples cover, 0 to 1.
    density: f32 = 0.9,
    /// The weight of each sample, as a fraction of the sample before it.
    decay: f32 = 0.96,
    /// Only the HDR colour above this level makes shafts.
    threshold: f32 = 1.0,
};

/// The most samples for each pixel.
pub const max_samples: u32 = 128;

/// The uniforms of the effect, with the memory layout of `SwShafts`.
pub const ShaftUniforms = extern struct {
    /// x: strength, y: samples, z: density, w: decay.
    params: [4]f32 = .{ 0.6, 48, 0.9, 0.96 },
    /// x: threshold. yzw: not used.
    extra: [4]f32 = .{ 1, 0, 0, 0 },

    pub fn of(s: ShaftSettings) ShaftUniforms {
        const n: f32 = @floatFromInt(std.math.clamp(s.samples, 1, max_samples));
        return .{
            .params = .{ @max(s.strength, 0), n, std.math.clamp(s.density, 0, 1), std.math.clamp(s.decay, 0, 1) },
            .extra = .{ s.threshold, 0, 0, 0 },
        };
    }
};

/// `sw_shaft_sun`: the sun on the screen, as a texture coordinate (0 at
/// the top left, 1 at the bottom right). Null when the sun is behind the
/// camera. `view_proj` is column-major, and `sun_dir` is the unit vector
/// to the sun.
pub fn sunScreen(view_proj: [16]f32, sun_dir: Vec3) ?[2]f32 {
    const m = view_proj;
    const x = m[0] * sun_dir[0] + m[4] * sun_dir[1] + m[8] * sun_dir[2];
    const y = m[1] * sun_dir[0] + m[5] * sun_dir[1] + m[9] * sun_dir[2];
    const w = m[3] * sun_dir[0] + m[7] * sun_dir[1] + m[11] * sun_dir[2];
    if (w <= 1e-6) return null;
    return .{ x / w * 0.5 + 0.5, 0.5 - y / w * 0.5 };
}

/// One sample of the input image for the CPU reference.
pub const Sample = struct {
    color: Vec3,
    /// True when the pixel has no geometry (depth 1).
    sky: bool,
};

/// The CPU reference of the effect at the texture coordinate `uv` with
/// the colour `c`. `fetch(ctx, uv)` gives the input at a texture
/// coordinate in 0 to 1.
pub fn shaftColor(u: ShaftUniforms, sun: ?[2]f32, uv: [2]f32, c: Vec3, ctx: anytype, comptime fetch: fn (@TypeOf(ctx), [2]f32) Sample) Vec3 {
    const s = sun orelse return c;
    const n: u32 = @intFromFloat(u.params[1]);
    const nf: f32 = @floatFromInt(n);
    const step: [2]f32 = .{ (s[0] - uv[0]) * u.params[2] / nf, (s[1] - uv[1]) * u.params[2] / nf };
    var p = uv;
    var weight: f32 = 1;
    var acc: Vec3 = .{ 0, 0, 0 };
    for (0..n) |_| {
        p = .{ p[0] + step[0], p[1] + step[1] };
        if (p[0] < 0 or p[0] > 1 or p[1] < 0 or p[1] > 1) break;
        const q = fetch(ctx, p);
        if (q.sky) {
            for (0..3) |i| acc[i] += @max(q.color[i] - u.extra[0], 0) * weight;
        }
        weight *= u.params[3];
    }
    var out: Vec3 = undefined;
    for (0..3) |i| out[i] = c[i] + acc[i] * u.params[0] / nf;
    return out;
}

/// The effect: an HDR post effect that reads the depth target. Group 2
/// has `SwShafts`.
pub const shader = post_plan.depthShader(
    \\struct SwShafts {
    \\    params: vec4<f32>,
    \\    extra: vec4<f32>,
    \\}
    \\@group(2) @binding(0) var<uniform> sw_shafts: SwShafts;
    \\
    \\// xy: the sun on the screen. z: 1 when the sun is in front of the
    \\// camera, else 0.
    \\fn sw_shaft_sun() -> vec3<f32> {
    \\    let clip = sw_frame.view_proj * vec4<f32>(sw_frame.sky.sun_dir.xyz, 0.0);
    \\    if (clip.w <= 1e-6) {
    \\        return vec3<f32>(0.0);
    \\    }
    \\    return vec3<f32>(clip.x / clip.w * 0.5 + 0.5, 0.5 - clip.y / clip.w * 0.5, 1.0);
    \\}
    \\
    \\@fragment fn fs_main(in: SwPostOut) -> @location(0) vec4<f32> {
    \\    let c = textureSample(sw_input, sw_input_sampler, in.uv);
    \\    let sun = sw_shaft_sun();
    \\    if (sun.z < 0.5) {
    \\        return c;
    \\    }
    \\    let n = u32(sw_shafts.params.y);
    \\    let nf = f32(n);
    \\    let step = (sun.xy - in.uv) * sw_shafts.params.z / nf;
    \\    let size = vec2<f32>(textureDimensions(sw_depth));
    \\    var p = in.uv;
    \\    var weight = 1.0;
    \\    var acc = vec3<f32>(0.0);
    \\    for (var i = 0u; i < n; i++) {
    \\        p = p + step;
    \\        if (p.x < 0.0 || p.x > 1.0 || p.y < 0.0 || p.y > 1.0) {
    \\            break;
    \\        }
    \\        let texel = min(vec2<i32>(p * size), vec2<i32>(size) - vec2<i32>(1));
    \\        if (textureLoad(sw_depth, texel, 0) >= 1.0) {
    \\            let s = textureSampleLevel(sw_input, sw_input_sampler, p, 0.0).rgb;
    \\            acc = acc + max(s - vec3<f32>(sw_shafts.extra.x), vec3<f32>(0.0)) * weight;
    \\        }
    \\        weight = weight * sw_shafts.params.w;
    \\    }
    \\    return vec4<f32>(c.rgb + acc * sw_shafts.params.x / nf, c.a);
    \\}
    \\
);

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

/// A test image: bright sky above the middle, dark ground below, and a
/// dark column (geometry) from x 0.45 to 0.55.
const TestImage = struct {
    fn fetch(_: void, p: [2]f32) Sample {
        if (p[0] > 0.45 and p[0] < 0.55) return .{ .color = .{ 0.1, 0.1, 0.1 }, .sky = false };
        if (p[1] < 0.5) return .{ .color = .{ 4, 4, 3 }, .sky = true };
        return .{ .color = .{ 0.2, 0.3, 0.1 }, .sky = false };
    }
};

test "shafts: the sun on the screen, and no sun behind the camera (REQ-GPU-033)" {
    const math = @import("sw_math");
    const proj = math.perspective(std.math.pi / 2.0, 1, 0.1, 100);
    const view = math.lookAt(.{ .x = 0, .y = 0, .z = 0 }, .{ .x = 0, .y = 0, .z = -1 }, .{ .x = 0, .y = 1, .z = 0 });
    const vp = proj.mul(view).data;
    const ahead = sunScreen(vp, .{ 0, 0, -1 }).?;
    try testing.expectApproxEqAbs(@as(f32, 0.5), ahead[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.5), ahead[1], 1e-5);
    // 45 degrees up is the top edge of a 90 degree view.
    const up = sunScreen(vp, .{ 0, std.math.sqrt1_2, -std.math.sqrt1_2 }).?;
    try testing.expectApproxEqAbs(@as(f32, 0), up[1], 1e-5);
    try testing.expectEqual(@as(?[2]f32, null), sunScreen(vp, .{ 0, 0.3, 0.95 }));
}

test "shafts: a pixel under the sun gets brighter, and the geometry makes a gap (REQ-GPU-033)" {
    const u = ShaftUniforms.of(.{});
    const sun: [2]f32 = .{ 0.3, 0.2 };
    const ground: Vec3 = .{ 0.2, 0.3, 0.1 };
    // Under the sun: the line to the sun crosses the bright sky.
    const lit = shaftColor(u, sun, .{ 0.3, 0.7 }, ground, {}, TestImage.fetch);
    for (0..3) |i| try testing.expect(lit[i] > ground[i]);
    // A pixel in the shadow of the column: its line to the sun stays in
    // the column, and gets less light.
    const gap = shaftColor(u, .{ 0.5, 0.2 }, .{ 0.5, 0.7 }, ground, {}, TestImage.fetch);
    try testing.expectEqual(ground, gap);
    // No sun: no change.
    try testing.expectEqual(ground, shaftColor(u, null, .{ 0.3, 0.7 }, ground, {}, TestImage.fetch));
    // A strength of 0: no change.
    const off = ShaftUniforms.of(.{ .strength = 0 });
    try testing.expectEqual(ground, shaftColor(off, sun, .{ 0.3, 0.7 }, ground, {}, TestImage.fetch));
}

test "shafts: more strength gives more light, and the sample count has a limit (REQ-GPU-033)" {
    const sun: [2]f32 = .{ 0.3, 0.2 };
    const ground: Vec3 = .{ 0.2, 0.3, 0.1 };
    const a = shaftColor(ShaftUniforms.of(.{ .strength = 0.3 }), sun, .{ 0.3, 0.7 }, ground, {}, TestImage.fetch);
    const b = shaftColor(ShaftUniforms.of(.{ .strength = 0.6 }), sun, .{ 0.3, 0.7 }, ground, {}, TestImage.fetch);
    try testing.expectApproxEqAbs(b[0] - ground[0], 2 * (a[0] - ground[0]), 1e-5);
    try testing.expectEqual(@as(f32, max_samples), ShaftUniforms.of(.{ .samples = 100000 }).params[1]);
    try testing.expectEqual(@as(f32, 1), ShaftUniforms.of(.{ .samples = 0 }).params[1]);
}

test "shafts: the shader starts with the depth prefix" {
    try testing.expect(std.mem.startsWith(u8, shader, wgsl.prefix ++ post_plan.post_prefix ++ post_plan.depth_prefix));
    try testing.expectEqual(@as(usize, 32), @sizeOf(ShaftUniforms));
}
