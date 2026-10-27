const std = @import("std");
const Vec3 = @import("vec3.zig").Vec3;
const Aabb = @import("aabb.zig").Aabb;

/// Plane of the points p where normal · p + d = 0. The normal points to the
/// front side, where the signed distance is positive. Most functions expect
/// a unit normal. A plane with a zero normal is degenerate: every point has
/// the distance d.
pub const Plane = struct {
    normal: Vec3,
    d: f32,

    /// The side of a plane that a shape is on.
    pub const Side = enum { front, back, intersecting };

    /// Plane from its normal and its d term, with no change.
    pub fn init(normal: Vec3, d: f32) Plane {
        return .{ .normal = normal, .d = d };
    }

    /// Plane through `point`, with the unit vector of `normal`. A normal
    /// shorter than 0.0001 gives a degenerate plane (zero normal, d = 0).
    pub fn fromPointNormal(point: Vec3, normal: Vec3) Plane {
        const n = normal.normalize();
        return .{ .normal = n, .d = -n.dot(point) };
    }

    /// Plane through three points. The normal is (b - a) × (c - a): it
    /// points to the side from which a, b, c go counter-clockwise. Null when
    /// the points are on one line or two of them are the same.
    pub fn fromPoints(a: Vec3, b: Vec3, c: Vec3) ?Plane {
        const n = b.sub(a).cross(c.sub(a));
        const len = n.length();
        if (len < 1e-6) return null;
        const unit = n.scale(1.0 / len);
        return .{ .normal = unit, .d = -unit.dot(a) };
    }

    /// Plane from the coefficients of a·x + b·y + c·z + d = 0, normalized.
    /// Use it for planes from the rows of a view-projection matrix.
    pub fn fromCoefficients(a: f32, b: f32, c: f32, d: f32) Plane {
        return (Plane{ .normal = Vec3.init(a, b, c), .d = d }).normalize();
    }

    /// Divide the normal and d by the length of the normal. The points of
    /// the plane do not change. A zero normal gives the plane with no change.
    pub fn normalize(p: Plane) Plane {
        const len = p.normal.length();
        if (len == 0) return p;
        const inv = 1.0 / len;
        return .{ .normal = p.normal.scale(inv), .d = p.d * inv };
    }

    /// Distance from the plane to `point`: positive on the front side,
    /// negative on the back side. It is a true distance only for a unit
    /// normal.
    pub fn signedDistance(p: Plane, point: Vec3) f32 {
        return p.normal.dot(point) + p.d;
    }

    /// The point on the plane nearest to `point`. Expects a unit normal.
    pub fn project(p: Plane, point: Vec3) Vec3 {
        return point.sub(p.normal.scale(p.signedDistance(point)));
    }

    /// The same plane with the other side as the front.
    pub fn flip(p: Plane) Plane {
        return .{ .normal = p.normal.negate(), .d = -p.d };
    }

    /// The side of the plane that the box is on. A box that touches the
    /// plane is `intersecting`. Use it for frustum culling: a box that is
    /// `back` of one inward-facing plane is outside the frustum.
    pub fn classifyAabb(p: Plane, box: Aabb) Side {
        // The corners that are furthest along and against the normal.
        const far = Vec3.init(
            if (p.normal.x >= 0) box.max.x else box.min.x,
            if (p.normal.y >= 0) box.max.y else box.min.y,
            if (p.normal.z >= 0) box.max.z else box.min.z,
        );
        const near = Vec3.init(
            if (p.normal.x >= 0) box.min.x else box.max.x,
            if (p.normal.y >= 0) box.min.y else box.max.y,
            if (p.normal.z >= 0) box.min.z else box.max.z,
        );
        if (p.signedDistance(far) < 0) return .back;
        if (p.signedDistance(near) > 0) return .front;
        return .intersecting;
    }
};

test "plane from point and normal" {
    const p = Plane.fromPointNormal(Vec3.init(0, 2, 0), Vec3.init(0, 5, 0));
    try std.testing.expectEqual(Vec3.init(0, 1, 0), p.normal);
    try std.testing.expectEqual(@as(f32, -2), p.d);
    try std.testing.expectEqual(@as(f32, 3), p.signedDistance(Vec3.init(7, 5, -1)));
    try std.testing.expectEqual(@as(f32, -2), p.signedDistance(Vec3.zero()));
    try std.testing.expectEqual(Vec3.init(7, 2, -1), p.project(Vec3.init(7, 5, -1)));
}

test "plane from zero normal is degenerate" {
    const p = Plane.fromPointNormal(Vec3.init(1, 2, 3), Vec3.zero());
    try std.testing.expectEqual(Vec3.zero(), p.normal);
    try std.testing.expectEqual(@as(f32, 0), p.signedDistance(Vec3.init(9, 9, 9)));
    // normalize does not divide by zero.
    const q = Plane.init(Vec3.zero(), 4).normalize();
    try std.testing.expectEqual(@as(f32, 4), q.d);
}

test "plane from points" {
    // Counter-clockwise from above: the normal points up.
    const p = Plane.fromPoints(Vec3.init(0, 1, 0), Vec3.init(0, 1, 1), Vec3.init(1, 1, 0)).?;
    try std.testing.expectApproxEqAbs(@as(f32, 1), p.normal.y, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -1), p.d, 0.0001);
}

test "plane from collinear or equal points is null" {
    try std.testing.expectEqual(@as(?Plane, null), Plane.fromPoints(Vec3.zero(), Vec3.init(1, 1, 1), Vec3.init(2, 2, 2)));
    try std.testing.expectEqual(@as(?Plane, null), Plane.fromPoints(Vec3.one(), Vec3.one(), Vec3.zero()));
}

test "plane from coefficients is normalized" {
    const p = Plane.fromCoefficients(0, 0, 2, 4);
    try std.testing.expectEqual(Vec3.init(0, 0, 1), p.normal);
    try std.testing.expectEqual(@as(f32, 2), p.d);
}

test "plane flip" {
    const p = Plane.fromPointNormal(Vec3.init(0, 0, 1), Vec3.init(0, 0, 1));
    const q = p.flip();
    try std.testing.expectEqual(-p.signedDistance(Vec3.init(3, 4, 5)), q.signedDistance(Vec3.init(3, 4, 5)));
}

test "plane classify aabb" {
    const p = Plane.fromPointNormal(Vec3.zero(), Vec3.init(1, 0, 0));
    const front = Aabb.init(Vec3.init(1, 0, 0), Vec3.init(2, 1, 1));
    const back = Aabb.init(Vec3.init(-2, 0, 0), Vec3.init(-1, 1, 1));
    const across = Aabb.init(Vec3.init(-1, 0, 0), Vec3.init(1, 1, 1));
    const touching = Aabb.init(Vec3.init(0, 0, 0), Vec3.init(1, 1, 1));
    try std.testing.expectEqual(Plane.Side.front, p.classifyAabb(front));
    try std.testing.expectEqual(Plane.Side.back, p.classifyAabb(back));
    try std.testing.expectEqual(Plane.Side.intersecting, p.classifyAabb(across));
    try std.testing.expectEqual(Plane.Side.intersecting, p.classifyAabb(touching));

    // A tilted plane: x + y = 0.
    const t = Plane.fromCoefficients(1, 1, 0, 0);
    try std.testing.expectEqual(Plane.Side.back, t.classifyAabb(Aabb.init(Vec3.init(-3, -3, 0), Vec3.init(-2, -2, 1))));
    try std.testing.expectEqual(Plane.Side.intersecting, t.classifyAabb(Aabb.init(Vec3.init(-1, 0, 0), Vec3.init(0, 2, 1))));
}
