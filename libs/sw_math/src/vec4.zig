const std = @import("std");
const Vec3 = @import("vec3.zig").Vec3;

/// 4D vector with f32 components. Use w = 1 for a point and w = 0 for a
/// direction.
pub const Vec4 = struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,

    pub fn init(x: f32, y: f32, z: f32, w: f32) Vec4 {
        return .{ .x = x, .y = y, .z = z, .w = w };
    }

    pub fn zero() Vec4 {
        return .{ .x = 0, .y = 0, .z = 0, .w = 0 };
    }

    pub fn one() Vec4 {
        return .{ .x = 1, .y = 1, .z = 1, .w = 1 };
    }

    /// Vec4 from a Vec3 and a w component.
    pub fn fromVec3(v: Vec3, w: f32) Vec4 {
        return .{ .x = v.x, .y = v.y, .z = v.z, .w = w };
    }

    /// The x, y and z components. This does not divide by w.
    pub fn xyz(v: Vec4) Vec3 {
        return Vec3.init(v.x, v.y, v.z);
    }

    pub fn add(a: Vec4, b: Vec4) Vec4 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z, .w = a.w + b.w };
    }

    pub fn sub(a: Vec4, b: Vec4) Vec4 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z, .w = a.w - b.w };
    }

    pub fn scale(v: Vec4, s: f32) Vec4 {
        return .{ .x = v.x * s, .y = v.y * s, .z = v.z * s, .w = v.w * s };
    }

    pub fn dot(a: Vec4, b: Vec4) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
    }

    pub fn length(v: Vec4) f32 {
        return @sqrt(v.dot(v));
    }

    pub fn lengthSq(v: Vec4) f32 {
        return v.dot(v);
    }

    /// The unit vector of v. A vector shorter than 0.0001 gives zero.
    pub fn normalize(v: Vec4) Vec4 {
        const len = v.length();
        if (len < 0.0001) return Vec4.zero();
        return v.scale(1.0 / len);
    }

    pub fn negate(v: Vec4) Vec4 {
        return .{ .x = -v.x, .y = -v.y, .z = -v.z, .w = -v.w };
    }

    /// Linear interpolation: a at t = 0, b at t = 1.
    pub fn lerp(a: Vec4, b: Vec4, t: f32) Vec4 {
        return a.add(b.sub(a).scale(t));
    }
};

test "vec4 basic operations" {
    const a = Vec4.init(1, 2, 3, 4);
    const b = Vec4.init(5, 6, 7, 8);

    try std.testing.expectEqual(Vec4.init(6, 8, 10, 12), a.add(b));
    try std.testing.expectEqual(Vec4.init(4, 4, 4, 4), b.sub(a));
    try std.testing.expectEqual(Vec4.init(2, 4, 6, 8), a.scale(2));
    try std.testing.expectEqual(Vec4.init(-1, -2, -3, -4), a.negate());
    try std.testing.expectEqual(@as(f32, 70), a.dot(b)); // 5 + 12 + 21 + 32
    try std.testing.expectEqual(@as(f32, 30), a.lengthSq());
}

test "vec4 to and from vec3" {
    const p = Vec4.fromVec3(Vec3.init(1, 2, 3), 1);
    try std.testing.expectEqual(Vec4.init(1, 2, 3, 1), p);
    try std.testing.expectEqual(Vec3.init(1, 2, 3), p.xyz());
}

test "vec4 normalize" {
    const n = Vec4.init(2, 0, 0, 0).normalize();
    try std.testing.expectEqual(Vec4.init(1, 0, 0, 0), n);
    try std.testing.expectApproxEqAbs(@as(f32, 1), Vec4.init(1, 2, 3, 4).normalize().length(), 0.0001);
}

test "vec4 normalize of zero length gives zero" {
    const n = Vec4.zero().normalize();
    try std.testing.expectEqual(Vec4.zero(), n);
}

test "vec4 lerp" {
    const a = Vec4.zero();
    const b = Vec4.init(2, 4, 6, 8);
    try std.testing.expectEqual(Vec4.init(1, 2, 3, 4), a.lerp(b, 0.5));
    try std.testing.expectEqual(b, a.lerp(b, 1));
}
