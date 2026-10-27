const std = @import("std");
const Vec3 = @import("vec3.zig").Vec3;
const Aabb = @import("aabb.zig").Aabb;
const Plane = @import("plane.zig").Plane;

/// Half-line from `origin` in the direction `dir`. The functions do not
/// normalize `dir`: a distance t is in units of the length of `dir`, and the
/// point at t is origin + dir * t.
pub const Ray = struct {
    origin: Vec3,
    dir: Vec3,

    /// Where a ray goes into and out of a box.
    pub const AabbHit = struct {
        /// Distance to the entry point. It is 0 when the origin is in the box.
        t_enter: f32,
        /// Distance to the exit point. It is +inf when the ray does not move
        /// on the axes where it is in the box.
        t_exit: f32,
        /// Unit normal of the face where the ray goes in. It points against
        /// the ray. It is zero when the origin is in the box.
        normal: Vec3,
    };

    pub fn init(origin: Vec3, dir: Vec3) Ray {
        return .{ .origin = origin, .dir = dir };
    }

    /// The point origin + dir * t.
    pub fn at(r: Ray, t: f32) Vec3 {
        return r.origin.add(r.dir.scale(t));
    }

    /// Where the ray hits the box, with the slab method. Null when it does
    /// not hit, when the box is fully behind the origin, or when the box is
    /// empty. A ray that touches an edge or a face hits. A direction
    /// component of zero is parallel to the two faces on that axis: the ray
    /// hits only when its origin is between them, faces included.
    pub fn intersectAabb(r: Ray, box: Aabb) ?AabbHit {
        if (box.isEmpty()) return null;

        const o = [3]f32{ r.origin.x, r.origin.y, r.origin.z };
        const d = [3]f32{ r.dir.x, r.dir.y, r.dir.z };
        const lo = [3]f32{ box.min.x, box.min.y, box.min.z };
        const hi = [3]f32{ box.max.x, box.max.y, box.max.z };

        var t_enter = -std.math.inf(f32);
        var t_exit = std.math.inf(f32);
        var enter_axis: ?usize = null;

        for (0..3) |i| {
            if (d[i] == 0) {
                // Parallel to this slab. A division here can give 0 * inf.
                if (o[i] < lo[i] or o[i] > hi[i]) return null;
                continue;
            }
            const inv = 1.0 / d[i];
            const t1 = (lo[i] - o[i]) * inv;
            const t2 = (hi[i] - o[i]) * inv;
            const near = @min(t1, t2);
            const far = @max(t1, t2);
            if (near > t_enter) {
                t_enter = near;
                enter_axis = i;
            }
            t_exit = @min(t_exit, far);
            if (t_enter > t_exit) return null;
        }

        if (t_exit < 0) return null;

        if (t_enter <= 0) {
            // The origin is in the box.
            return .{ .t_enter = 0, .t_exit = t_exit, .normal = Vec3.zero() };
        }

        // t_enter > -inf, so a slab set enter_axis.
        const axis = enter_axis.?;
        const sign: f32 = if (d[axis] > 0) -1 else 1;
        const normal = switch (axis) {
            0 => Vec3.init(sign, 0, 0),
            1 => Vec3.init(0, sign, 0),
            else => Vec3.init(0, 0, sign),
        };
        return .{ .t_enter = t_enter, .t_exit = t_exit, .normal = normal };
    }

    /// Distance t where the ray hits the plane. Null when the ray is
    /// parallel to the plane (in the plane too), or when the plane is
    /// behind the origin.
    pub fn intersectPlane(r: Ray, plane: Plane) ?f32 {
        const denom = plane.normal.dot(r.dir);
        if (@abs(denom) < 1e-6) return null;
        const t = -plane.signedDistance(r.origin) / denom;
        if (t < 0) return null;
        return t;
    }
};

const unit_box = Aabb.init(Vec3.zero(), Vec3.one());

test "ray at" {
    const r = Ray.init(Vec3.init(1, 0, 0), Vec3.init(0, 2, 0));
    try std.testing.expectEqual(Vec3.init(1, 3, 0), r.at(1.5));
}

test "ray hits aabb from outside" {
    const r = Ray.init(Vec3.init(-2, 0.5, 0.5), Vec3.init(1, 0, 0));
    const hit = r.intersectAabb(unit_box).?;
    try std.testing.expectEqual(@as(f32, 2), hit.t_enter);
    try std.testing.expectEqual(@as(f32, 3), hit.t_exit);
    try std.testing.expectEqual(Vec3.init(-1, 0, 0), hit.normal);

    // From above, going down: the normal of the top face.
    const down = Ray.init(Vec3.init(0.5, 5, 0.5), Vec3.init(0, -1, 0));
    const top = down.intersectAabb(unit_box).?;
    try std.testing.expectEqual(@as(f32, 4), top.t_enter);
    try std.testing.expectEqual(Vec3.init(0, 1, 0), top.normal);
}

test "ray hits aabb on a diagonal" {
    const r = Ray.init(Vec3.init(-1, -1, -1), Vec3.init(1, 1, 1));
    const hit = r.intersectAabb(unit_box).?;
    try std.testing.expectEqual(@as(f32, 1), hit.t_enter);
    try std.testing.expectEqual(@as(f32, 2), hit.t_exit);
}

test "ray misses aabb" {
    const r = Ray.init(Vec3.init(-2, 2, 0.5), Vec3.init(1, 0.1, 0));
    try std.testing.expectEqual(@as(?Ray.AabbHit, null), r.intersectAabb(unit_box));
}

test "ray with box behind the origin" {
    const r = Ray.init(Vec3.init(3, 0.5, 0.5), Vec3.init(1, 0, 0));
    try std.testing.expectEqual(@as(?Ray.AabbHit, null), r.intersectAabb(unit_box));
}

test "ray from inside aabb" {
    const r = Ray.init(Vec3.init(0.5, 0.5, 0.5), Vec3.init(0, 0, 1));
    const hit = r.intersectAabb(unit_box).?;
    try std.testing.expectEqual(@as(f32, 0), hit.t_enter);
    try std.testing.expectEqual(@as(f32, 0.5), hit.t_exit);
    try std.testing.expectEqual(Vec3.zero(), hit.normal);
}

test "ray parallel to aabb faces" {
    // Parallel to the x faces and between them: hits.
    const in_slab = Ray.init(Vec3.init(0.5, -1, 0.5), Vec3.init(0, 1, 0));
    try std.testing.expectEqual(@as(f32, 1), in_slab.intersectAabb(unit_box).?.t_enter);
    // Parallel and outside the slab: misses, with no NaN.
    const out_slab = Ray.init(Vec3.init(2, -1, 0.5), Vec3.init(0, 1, 0));
    try std.testing.expectEqual(@as(?Ray.AabbHit, null), out_slab.intersectAabb(unit_box));
    // Parallel and on a face: the face is part of the box.
    const on_face = Ray.init(Vec3.init(0, -1, 0.5), Vec3.init(0, 1, 0));
    try std.testing.expect(on_face.intersectAabb(unit_box) != null);
}

test "ray with zero direction" {
    const inside = Ray.init(Vec3.init(0.5, 0.5, 0.5), Vec3.zero());
    const hit = inside.intersectAabb(unit_box).?;
    try std.testing.expectEqual(@as(f32, 0), hit.t_enter);
    try std.testing.expect(std.math.isInf(hit.t_exit));
    const outside = Ray.init(Vec3.init(5, 5, 5), Vec3.zero());
    try std.testing.expectEqual(@as(?Ray.AabbHit, null), outside.intersectAabb(unit_box));
    try std.testing.expectEqual(@as(?f32, null), outside.intersectPlane(Plane.fromPointNormal(Vec3.zero(), Vec3.init(0, 1, 0))));
}

test "ray against empty aabb" {
    const r = Ray.init(Vec3.init(-1, 0, 0), Vec3.init(1, 0, 0));
    try std.testing.expectEqual(@as(?Ray.AabbHit, null), r.intersectAabb(Aabb.empty()));
}

test "ray hits plane" {
    const ground = Plane.fromPointNormal(Vec3.zero(), Vec3.init(0, 1, 0));
    const r = Ray.init(Vec3.init(1, 4, 1), Vec3.init(0, -2, 0));
    const t = r.intersectPlane(ground).?;
    try std.testing.expectEqual(@as(f32, 2), t);
    try std.testing.expectEqual(Vec3.init(1, 0, 1), r.at(t));
    // The ray goes away from the plane.
    const up = Ray.init(Vec3.init(1, 4, 1), Vec3.init(0, 1, 0));
    try std.testing.expectEqual(@as(?f32, null), up.intersectPlane(ground));
}

test "ray parallel to plane" {
    const ground = Plane.fromPointNormal(Vec3.zero(), Vec3.init(0, 1, 0));
    const above = Ray.init(Vec3.init(0, 1, 0), Vec3.init(1, 0, 0));
    try std.testing.expectEqual(@as(?f32, null), above.intersectPlane(ground));
    const in_plane = Ray.init(Vec3.zero(), Vec3.init(1, 0, 0));
    try std.testing.expectEqual(@as(?f32, null), in_plane.intersectPlane(ground));
}
