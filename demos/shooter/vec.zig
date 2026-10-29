// Small vector and matrix helpers on @Vector(3, f32), from the action game.
// sw_math.Mat4 is the matrix type (column major).
const std = @import("std");
const sw_math = @import("sw_math");

pub const V3 = @Vector(3, f32);
pub const Mat4 = sw_math.Mat4;

pub fn v3(x: f32, y: f32, z: f32) V3 {
    return .{ x, y, z };
}
pub fn s(k: f32) V3 {
    return @splat(k);
}
pub fn dot(a: V3, b: V3) f32 {
    return @reduce(.Add, a * b);
}
pub fn cross(a: V3, b: V3) V3 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}
pub fn len(a: V3) f32 {
    return @sqrt(dot(a, a));
}
pub fn norm(a: V3) V3 {
    const l = len(a);
    return if (l > 1e-6) a / s(l) else a;
}
pub fn lerp(a: V3, b: V3, t: f32) V3 {
    return a + (b - a) * s(t);
}
pub fn clamp01(x: f32) f32 {
    return std.math.clamp(x, 0, 1);
}
pub fn smooth(x: f32) f32 {
    const t = clamp01(x);
    return t * t * (3 - 2 * t);
}

/// The forward vector of a camera with this yaw and pitch. Yaw 0 looks to -Z.
pub fn forward(yaw: f32, pitch: f32) V3 {
    return .{ -@sin(yaw) * @cos(pitch), @sin(pitch), -@cos(yaw) * @cos(pitch) };
}

/// Transform a point by a column-major matrix.
pub fn xform(m: Mat4, p: V3) V3 {
    const d = m.data;
    return .{
        d[0] * p[0] + d[4] * p[1] + d[8] * p[2] + d[12],
        d[1] * p[0] + d[5] * p[1] + d[9] * p[2] + d[13],
        d[2] * p[0] + d[6] * p[1] + d[10] * p[2] + d[14],
    };
}

/// Transform a direction (no translation).
pub fn xdir(m: Mat4, p: V3) V3 {
    const d = m.data;
    return .{
        d[0] * p[0] + d[4] * p[1] + d[8] * p[2],
        d[1] * p[0] + d[5] * p[1] + d[9] * p[2],
        d[2] * p[0] + d[6] * p[1] + d[10] * p[2],
    };
}

pub fn translate(p: V3) Mat4 {
    return Mat4.translation(p[0], p[1], p[2]);
}

/// A world matrix from a position and yaw, pitch and roll (applied in that
/// order: roll first, then pitch, then yaw).
pub fn ypr(p: V3, yaw: f32, pitch: f32, roll: f32) Mat4 {
    return translate(p).mul(Mat4.rotationY(yaw).mul(Mat4.rotationX(pitch).mul(Mat4.rotationZ(roll))));
}

/// Deterministic hash noise in [0, 1).
pub fn hash(n: u32) f32 {
    var x = n *% 0x9E3779B1;
    x ^= x >> 15;
    x *%= 0x85EBCA77;
    x ^= x >> 13;
    return @as(f32, @floatFromInt(x & 0xFFFFFF)) / 16777216.0;
}
