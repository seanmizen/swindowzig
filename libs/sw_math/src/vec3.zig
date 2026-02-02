const std = @import("std");

/// 3D vector with f32 components
pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,

    pub fn init(x: f32, y: f32, z: f32) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }

    pub fn zero() Vec3 {
        return .{ .x = 0, .y = 0, .z = 0 };
    }

    pub fn one() Vec3 {
        return .{ .x = 1, .y = 1, .z = 1 };
    }

    pub fn add(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }

    pub fn sub(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }

    pub fn scale(v: Vec3, s: f32) Vec3 {
        return .{ .x = v.x * s, .y = v.y * s, .z = v.z * s };
    }

    pub fn dot(a: Vec3, b: Vec3) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }

    pub fn cross(a: Vec3, b: Vec3) Vec3 {
        return .{
            .x = a.y * b.z - a.z * b.y,
            .y = a.z * b.x - a.x * b.z,
            .z = a.x * b.y - a.y * b.x,
        };
    }

    pub fn length(v: Vec3) f32 {
        return @sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
    }

    pub fn lengthSq(v: Vec3) f32 {
        return v.x * v.x + v.y * v.y + v.z * v.z;
    }

    pub fn normalize(v: Vec3) Vec3 {
        const len = v.length();
        if (len < 0.0001) return Vec3.zero();
        return v.scale(1.0 / len);
    }

    pub fn negate(v: Vec3) Vec3 {
        return .{ .x = -v.x, .y = -v.y, .z = -v.z };
    }
};

test "vec3 basic operations" {
    const a = Vec3.init(1, 2, 3);
    const b = Vec3.init(4, 5, 6);

    const sum = a.add(b);
    try std.testing.expectEqual(@as(f32, 5), sum.x);
    try std.testing.expectEqual(@as(f32, 7), sum.y);
    try std.testing.expectEqual(@as(f32, 9), sum.z);

    const diff = b.sub(a);
    try std.testing.expectEqual(@as(f32, 3), diff.x);
    try std.testing.expectEqual(@as(f32, 3), diff.y);
    try std.testing.expectEqual(@as(f32, 3), diff.z);

    const scaled = a.scale(2);
    try std.testing.expectEqual(@as(f32, 2), scaled.x);
    try std.testing.expectEqual(@as(f32, 4), scaled.y);
    try std.testing.expectEqual(@as(f32, 6), scaled.z);
}

test "vec3 dot product" {
    const a = Vec3.init(1, 0, 0);
    const b = Vec3.init(0, 1, 0);
    try std.testing.expectEqual(@as(f32, 0), a.dot(b));

    const c = Vec3.init(1, 2, 3);
    const d = Vec3.init(4, 5, 6);
    try std.testing.expectEqual(@as(f32, 32), c.dot(d)); // 4 + 10 + 18
}

test "vec3 cross product" {
    const x = Vec3.init(1, 0, 0);
    const y = Vec3.init(0, 1, 0);
    const z = x.cross(y);
    try std.testing.expectEqual(@as(f32, 0), z.x);
    try std.testing.expectEqual(@as(f32, 0), z.y);
    try std.testing.expectEqual(@as(f32, 1), z.z);
}

test "vec3 normalize" {
    const v = Vec3.init(3, 4, 0);
    const n = v.normalize();
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), n.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), n.y, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), n.z, 0.0001);
}
