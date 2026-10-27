const std = @import("std");
const Vec3 = @import("vec3.zig").Vec3;

/// Axis-aligned bounding box. The box is closed: a point on a face is in the
/// box, and two boxes that touch at a face intersect. A box with
/// min > max on an axis is empty (see `empty`).
pub const Aabb = struct {
    min: Vec3,
    max: Vec3,

    /// Box from two corners. Give the low corner first.
    pub fn init(min: Vec3, max: Vec3) Aabb {
        return .{ .min = min, .max = max };
    }

    /// Box from any two opposite corners, in any order.
    pub fn fromPoints(a: Vec3, b: Vec3) Aabb {
        return .{
            .min = Vec3.init(@min(a.x, b.x), @min(a.y, b.y), @min(a.z, b.z)),
            .max = Vec3.init(@max(a.x, b.x), @max(a.y, b.y), @max(a.z, b.z)),
        };
    }

    /// Box from a center and the half size on each axis.
    pub fn fromCenterHalfExtents(c: Vec3, half: Vec3) Aabb {
        return .{ .min = c.sub(half), .max = c.add(half) };
    }

    /// An empty box: min is +inf and max is -inf. The union of an empty box
    /// and a box b is b, so use it as the start value of a union loop.
    pub fn empty() Aabb {
        const inf = std.math.inf(f32);
        return .{ .min = Vec3.init(inf, inf, inf), .max = Vec3.init(-inf, -inf, -inf) };
    }

    /// True when min > max on one axis or more.
    pub fn isEmpty(a: Aabb) bool {
        return a.min.x > a.max.x or a.min.y > a.max.y or a.min.z > a.max.z;
    }

    pub fn center(a: Aabb) Vec3 {
        return a.min.add(a.max).scale(0.5);
    }

    pub fn size(a: Aabb) Vec3 {
        return a.max.sub(a.min);
    }

    pub fn halfExtents(a: Aabb) Vec3 {
        return a.size().scale(0.5);
    }

    /// The smallest box that holds a and b.
    pub fn @"union"(a: Aabb, b: Aabb) Aabb {
        return .{
            .min = Vec3.init(@min(a.min.x, b.min.x), @min(a.min.y, b.min.y), @min(a.min.z, b.min.z)),
            .max = Vec3.init(@max(a.max.x, b.max.x), @max(a.max.y, b.max.y), @max(a.max.z, b.max.z)),
        };
    }

    /// The region that is in a and in b. Null when the boxes do not
    /// intersect. Boxes that touch give a box with zero size on one axis.
    pub fn intersect(a: Aabb, b: Aabb) ?Aabb {
        const r = Aabb{
            .min = Vec3.init(@max(a.min.x, b.min.x), @max(a.min.y, b.min.y), @max(a.min.z, b.min.z)),
            .max = Vec3.init(@min(a.max.x, b.max.x), @min(a.max.y, b.max.y), @min(a.max.z, b.max.z)),
        };
        if (r.isEmpty()) return null;
        return r;
    }

    /// True when a and b have one point or more in common.
    pub fn intersects(a: Aabb, b: Aabb) bool {
        return a.min.x <= b.max.x and a.max.x >= b.min.x and
            a.min.y <= b.max.y and a.max.y >= b.min.y and
            a.min.z <= b.max.z and a.max.z >= b.min.z;
    }

    /// True when the point p is in the box or on its surface.
    pub fn contains(a: Aabb, p: Vec3) bool {
        return p.x >= a.min.x and p.x <= a.max.x and
            p.y >= a.min.y and p.y <= a.max.y and
            p.z >= a.min.z and p.z <= a.max.z;
    }

    /// True when all of b is in a. An empty b is in every box.
    pub fn containsAabb(a: Aabb, b: Aabb) bool {
        if (b.isEmpty()) return true;
        return b.min.x >= a.min.x and b.max.x <= a.max.x and
            b.min.y >= a.min.y and b.max.y <= a.max.y and
            b.min.z >= a.min.z and b.max.z <= a.max.z;
    }

    /// Grow the box by `amount` on each side of each axis. A negative amount
    /// makes the box smaller, and can make it empty.
    pub fn expand(a: Aabb, amount: Vec3) Aabb {
        return .{ .min = a.min.sub(amount), .max = a.max.add(amount) };
    }

    /// Grow the box on one side of each axis, in the direction of `delta`.
    /// The result holds the box at its start and at its start + delta. Use
    /// it for the region that a moving box sweeps.
    pub fn expandTowards(a: Aabb, delta: Vec3) Aabb {
        var r = a;
        if (delta.x < 0) r.min.x += delta.x else r.max.x += delta.x;
        if (delta.y < 0) r.min.y += delta.y else r.max.y += delta.y;
        if (delta.z < 0) r.min.z += delta.z else r.max.z += delta.z;
        return r;
    }

    /// The smallest box that holds a and the point p.
    pub fn includePoint(a: Aabb, p: Vec3) Aabb {
        return a.@"union"(.{ .min = p, .max = p });
    }

    /// Move the box by `offset`.
    pub fn translate(a: Aabb, offset: Vec3) Aabb {
        return .{ .min = a.min.add(offset), .max = a.max.add(offset) };
    }
};

fn box(x0: f32, y0: f32, z0: f32, x1: f32, y1: f32, z1: f32) Aabb {
    return Aabb.init(Vec3.init(x0, y0, z0), Vec3.init(x1, y1, z1));
}

test "aabb from points and center" {
    const a = Aabb.fromPoints(Vec3.init(2, 0, 5), Vec3.init(0, 3, 1));
    try std.testing.expectEqual(box(0, 0, 1, 2, 3, 5), a);
    try std.testing.expectEqual(Vec3.init(1, 1.5, 3), a.center());
    try std.testing.expectEqual(Vec3.init(2, 3, 4), a.size());
    try std.testing.expectEqual(Vec3.init(1, 1.5, 2), a.halfExtents());
    try std.testing.expectEqual(a, Aabb.fromCenterHalfExtents(a.center(), a.halfExtents()));
}

test "aabb union" {
    const a = box(0, 0, 0, 1, 1, 1);
    const b = box(2, -1, 0, 3, 0.5, 4);
    try std.testing.expectEqual(box(0, -1, 0, 3, 1, 4), a.@"union"(b));
    // The empty box is the identity of union.
    try std.testing.expectEqual(a, Aabb.empty().@"union"(a));
    try std.testing.expect(Aabb.empty().isEmpty());
    try std.testing.expect(!a.isEmpty());
}

test "aabb intersect" {
    const a = box(0, 0, 0, 2, 2, 2);
    const b = box(1, 1, 1, 3, 3, 3);
    try std.testing.expectEqual(box(1, 1, 1, 2, 2, 2), a.intersect(b).?);
    try std.testing.expect(a.intersects(b));

    // Disjoint boxes.
    const c = box(5, 5, 5, 6, 6, 6);
    try std.testing.expectEqual(@as(?Aabb, null), a.intersect(c));
    try std.testing.expect(!a.intersects(c));

    // Boxes that touch at a face give a box with zero width.
    const d = box(2, 0, 0, 3, 2, 2);
    const touch = a.intersect(d).?;
    try std.testing.expectEqual(@as(f32, 0), touch.size().x);
    try std.testing.expect(a.intersects(d));
}

test "aabb contains" {
    const a = box(0, 0, 0, 1, 1, 1);
    try std.testing.expect(a.contains(Vec3.init(0.5, 0.5, 0.5)));
    // Points on the surface are in the box.
    try std.testing.expect(a.contains(Vec3.init(0, 1, 0.5)));
    try std.testing.expect(!a.contains(Vec3.init(1.01, 0.5, 0.5)));
    try std.testing.expect(!Aabb.empty().contains(Vec3.zero()));

    try std.testing.expect(a.containsAabb(box(0.2, 0.2, 0.2, 0.8, 0.8, 0.8)));
    try std.testing.expect(a.containsAabb(a));
    try std.testing.expect(!a.containsAabb(box(0.5, 0.5, 0.5, 1.5, 0.8, 0.8)));
    try std.testing.expect(a.containsAabb(Aabb.empty()));
}

test "aabb expand" {
    const a = box(0, 0, 0, 1, 1, 1);
    try std.testing.expectEqual(box(-1, -2, 0, 2, 3, 1), a.expand(Vec3.init(1, 2, 0)));
    // A negative amount larger than the half size makes the box empty.
    try std.testing.expect(a.expand(Vec3.init(-1, 0, 0)).isEmpty());
}

test "aabb expand towards" {
    const a = box(0, 0, 0, 1, 1, 1);
    try std.testing.expectEqual(box(-2, 0, 0, 1, 4, 1), a.expandTowards(Vec3.init(-2, 3, 0)));
    // A zero delta does not change the box.
    try std.testing.expectEqual(a, a.expandTowards(Vec3.zero()));
}

test "aabb include point and translate" {
    const a = Aabb.empty().includePoint(Vec3.init(1, 2, 3));
    try std.testing.expectEqual(box(1, 2, 3, 1, 2, 3), a);
    try std.testing.expect(!a.isEmpty());
    try std.testing.expectEqual(box(1, 2, 3, 4, 2, 3), a.includePoint(Vec3.init(4, 2, 3)));
    try std.testing.expectEqual(box(2, 2, 2, 3, 3, 3), box(0, 0, 0, 1, 1, 1).translate(Vec3.init(2, 2, 2)));
}
