const std = @import("std");

/// 2D vector with f32 components
pub const Vec2 = struct {
    x: f32,
    y: f32,

    pub fn init(x: f32, y: f32) Vec2 {
        return .{ .x = x, .y = y };
    }

    pub fn zero() Vec2 {
        return .{ .x = 0, .y = 0 };
    }

    pub fn one() Vec2 {
        return .{ .x = 1, .y = 1 };
    }

    pub fn add(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }

    pub fn sub(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }

    pub fn scale(v: Vec2, s: f32) Vec2 {
        return .{ .x = v.x * s, .y = v.y * s };
    }

    pub fn dot(a: Vec2, b: Vec2) f32 {
        return a.x * b.x + a.y * b.y;
    }

    /// The z component of the 3D cross product of (a, 0) and (b, 0).
    /// It is positive when b is counter-clockwise from a.
    pub fn cross(a: Vec2, b: Vec2) f32 {
        return a.x * b.y - a.y * b.x;
    }

    pub fn length(v: Vec2) f32 {
        return @sqrt(v.x * v.x + v.y * v.y);
    }

    pub fn lengthSq(v: Vec2) f32 {
        return v.x * v.x + v.y * v.y;
    }

    /// The unit vector of v. A vector shorter than 0.0001 gives zero.
    pub fn normalize(v: Vec2) Vec2 {
        const len = v.length();
        if (len < 0.0001) return Vec2.zero();
        return v.scale(1.0 / len);
    }

    pub fn negate(v: Vec2) Vec2 {
        return .{ .x = -v.x, .y = -v.y };
    }

    /// Linear interpolation: a at t = 0, b at t = 1.
    pub fn lerp(a: Vec2, b: Vec2, t: f32) Vec2 {
        return .{ .x = a.x + (b.x - a.x) * t, .y = a.y + (b.y - a.y) * t };
    }
};

test "vec2 basic operations" {
    const a = Vec2.init(1, 2);
    const b = Vec2.init(4, 6);

    const sum = a.add(b);
    try std.testing.expectEqual(@as(f32, 5), sum.x);
    try std.testing.expectEqual(@as(f32, 8), sum.y);

    const diff = b.sub(a);
    try std.testing.expectEqual(@as(f32, 3), diff.x);
    try std.testing.expectEqual(@as(f32, 4), diff.y);
    try std.testing.expectEqual(@as(f32, 5), diff.length());
    try std.testing.expectEqual(@as(f32, 25), diff.lengthSq());

    const scaled = a.scale(2);
    try std.testing.expectEqual(@as(f32, 2), scaled.x);
    try std.testing.expectEqual(@as(f32, 4), scaled.y);

    const neg = a.negate();
    try std.testing.expectEqual(@as(f32, -1), neg.x);
    try std.testing.expectEqual(@as(f32, -2), neg.y);
}

test "vec2 dot and cross" {
    const x = Vec2.init(1, 0);
    const y = Vec2.init(0, 1);
    try std.testing.expectEqual(@as(f32, 0), x.dot(y));
    try std.testing.expectEqual(@as(f32, 1), x.cross(y));
    try std.testing.expectEqual(@as(f32, -1), y.cross(x));
    // Parallel vectors: the cross product is zero.
    try std.testing.expectEqual(@as(f32, 0), x.cross(x.scale(3)));
    try std.testing.expectEqual(@as(f32, 11), Vec2.init(1, 2).dot(Vec2.init(3, 4)));
}

test "vec2 normalize" {
    const n = Vec2.init(3, 4).normalize();
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), n.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), n.y, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), n.length(), 0.0001);
}

test "vec2 normalize of zero length gives zero" {
    const n = Vec2.zero().normalize();
    try std.testing.expectEqual(@as(f32, 0), n.x);
    try std.testing.expectEqual(@as(f32, 0), n.y);
    try std.testing.expect(!std.math.isNan(n.x));
}

test "vec2 lerp" {
    const a = Vec2.init(0, 10);
    const b = Vec2.init(10, 20);
    try std.testing.expectEqual(a, a.lerp(b, 0));
    try std.testing.expectEqual(b, a.lerp(b, 1));
    const mid = a.lerp(b, 0.5);
    try std.testing.expectEqual(@as(f32, 5), mid.x);
    try std.testing.expectEqual(@as(f32, 15), mid.y);
}
