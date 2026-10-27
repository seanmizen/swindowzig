const std = @import("std");
const Vec3 = @import("vec3.zig").Vec3;
const Mat4 = @import("mat4.zig").Mat4;

/// Rotation quaternion: x, y, z is the vector part and w is the scalar part.
/// The rotations follow the right-hand rule, the same as Mat4.rotationX,
/// rotationY and rotationZ. Most functions expect a unit quaternion.
pub const Quat = struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,

    pub fn init(x: f32, y: f32, z: f32, w: f32) Quat {
        return .{ .x = x, .y = y, .z = z, .w = w };
    }

    /// The rotation that does not move a vector.
    pub fn identity() Quat {
        return .{ .x = 0, .y = 0, .z = 0, .w = 1 };
    }

    /// Rotation of `angle` radians around `axis`. The axis does not have to
    /// be a unit vector. An axis shorter than 0.0001 gives the identity.
    pub fn fromAxisAngle(axis: Vec3, angle: f32) Quat {
        const n = axis.normalize();
        if (n.lengthSq() == 0) return Quat.identity();
        const s = @sin(angle * 0.5);
        return .{ .x = n.x * s, .y = n.y * s, .z = n.z * s, .w = @cos(angle * 0.5) };
    }

    pub fn dot(a: Quat, b: Quat) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
    }

    pub fn length(q: Quat) f32 {
        return @sqrt(q.dot(q));
    }

    pub fn lengthSq(q: Quat) f32 {
        return q.dot(q);
    }

    /// The unit quaternion of q. A quaternion shorter than 0.0001 gives the
    /// identity, because a zero quaternion is not a rotation.
    pub fn normalize(q: Quat) Quat {
        const len = q.length();
        if (len < 0.0001) return Quat.identity();
        const inv = 1.0 / len;
        return .{ .x = q.x * inv, .y = q.y * inv, .z = q.z * inv, .w = q.w * inv };
    }

    /// The opposite rotation of a unit quaternion.
    pub fn conjugate(q: Quat) Quat {
        return .{ .x = -q.x, .y = -q.y, .z = -q.z, .w = q.w };
    }

    /// The inverse of q, for a quaternion of any length. A quaternion shorter
    /// than 0.0001 gives the identity.
    pub fn inverse(q: Quat) Quat {
        const len_sq = q.lengthSq();
        if (len_sq < 0.0001 * 0.0001) return Quat.identity();
        const inv = 1.0 / len_sq;
        return .{ .x = -q.x * inv, .y = -q.y * inv, .z = -q.z * inv, .w = q.w * inv };
    }

    /// Hamilton product a * b. The result applies b first, then a.
    pub fn mul(a: Quat, b: Quat) Quat {
        return .{
            .x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            .y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            .z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
            .w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
        };
    }

    /// Rotate the vector v with the unit quaternion q.
    pub fn rotate(q: Quat, v: Vec3) Vec3 {
        const u = Vec3.init(q.x, q.y, q.z);
        const t = u.cross(v).scale(2);
        return v.add(t.scale(q.w)).add(u.cross(t));
    }

    /// Spherical linear interpolation between unit quaternions: a at t = 0,
    /// b at t = 1. It takes the shorter arc. When a and b are almost
    /// parallel, it uses a normalized linear interpolation, because the
    /// spherical formula divides by a value near zero.
    pub fn slerp(a: Quat, b: Quat, t: f32) Quat {
        var end = b;
        var cos_theta = a.dot(b);
        // q and -q are the same rotation. Use the one nearer to a.
        if (cos_theta < 0) {
            end = .{ .x = -b.x, .y = -b.y, .z = -b.z, .w = -b.w };
            cos_theta = -cos_theta;
        }

        var wa: f32 = undefined;
        var wb: f32 = undefined;
        if (cos_theta > 0.9995) {
            wa = 1 - t;
            wb = t;
        } else {
            const theta = std.math.acos(cos_theta);
            const sin_theta = @sin(theta);
            wa = @sin((1 - t) * theta) / sin_theta;
            wb = @sin(t * theta) / sin_theta;
        }

        const r = Quat{
            .x = a.x * wa + end.x * wb,
            .y = a.y * wa + end.y * wb,
            .z = a.z * wa + end.z * wb,
            .w = a.w * wa + end.w * wb,
        };
        return r.normalize();
    }

    /// Rotation matrix of the unit quaternion q, column-major like Mat4.
    pub fn toMat4(q: Quat) Mat4 {
        const xx = q.x * q.x;
        const yy = q.y * q.y;
        const zz = q.z * q.z;
        const xy = q.x * q.y;
        const xz = q.x * q.z;
        const yz = q.y * q.z;
        const wx = q.w * q.x;
        const wy = q.w * q.y;
        const wz = q.w * q.z;
        return .{ .data = [_]f32{
            1 - 2 * (yy + zz), 2 * (xy + wz),     2 * (xz - wy),     0,
            2 * (xy - wz),     1 - 2 * (xx + zz), 2 * (yz + wx),     0,
            2 * (xz + wy),     2 * (yz - wx),     1 - 2 * (xx + yy), 0,
            0,                 0,                 0,                 1,
        } };
    }
};

const eps: f32 = 0.0001;

fn expectMat4Approx(expected: Mat4, actual: Mat4) !void {
    for (expected.data, actual.data) |e, a| {
        try std.testing.expectApproxEqAbs(e, a, eps);
    }
}

fn expectVec3Approx(expected: Vec3, actual: Vec3) !void {
    try std.testing.expectApproxEqAbs(expected.x, actual.x, eps);
    try std.testing.expectApproxEqAbs(expected.y, actual.y, eps);
    try std.testing.expectApproxEqAbs(expected.z, actual.z, eps);
}

fn expectQuatApprox(expected: Quat, actual: Quat) !void {
    try std.testing.expectApproxEqAbs(expected.x, actual.x, eps);
    try std.testing.expectApproxEqAbs(expected.y, actual.y, eps);
    try std.testing.expectApproxEqAbs(expected.z, actual.z, eps);
    try std.testing.expectApproxEqAbs(expected.w, actual.w, eps);
}

test "quat identity gives identity matrix" {
    try expectMat4Approx(Mat4.identity(), Quat.identity().toMat4());
}

test "quat from axis-angle matches the Mat4 rotations" {
    const angle: f32 = 0.7;
    try expectMat4Approx(Mat4.rotationX(angle), Quat.fromAxisAngle(Vec3.init(1, 0, 0), angle).toMat4());
    try expectMat4Approx(Mat4.rotationY(angle), Quat.fromAxisAngle(Vec3.init(0, 1, 0), angle).toMat4());
    try expectMat4Approx(Mat4.rotationZ(angle), Quat.fromAxisAngle(Vec3.init(0, 0, 1), angle).toMat4());
}

test "quat from axis-angle normalizes the axis" {
    const a = Quat.fromAxisAngle(Vec3.init(0, 5, 0), 1.0);
    const b = Quat.fromAxisAngle(Vec3.init(0, 1, 0), 1.0);
    try expectQuatApprox(b, a);
    try std.testing.expectApproxEqAbs(@as(f32, 1), a.length(), eps);
}

test "quat from zero-length axis gives identity" {
    try std.testing.expectEqual(Quat.identity(), Quat.fromAxisAngle(Vec3.zero(), 1.0));
}

test "quat rotate" {
    const q = Quat.fromAxisAngle(Vec3.init(0, 0, 1), std.math.pi / 2.0);
    try expectVec3Approx(Vec3.init(0, 1, 0), q.rotate(Vec3.init(1, 0, 0)));
    // The axis does not move.
    try expectVec3Approx(Vec3.init(0, 0, 3), q.rotate(Vec3.init(0, 0, 3)));
}

test "quat mul applies the right operand first" {
    const rx = Quat.fromAxisAngle(Vec3.init(1, 0, 0), 0.4);
    const ry = Quat.fromAxisAngle(Vec3.init(0, 1, 0), 1.1);
    const v = Vec3.init(1, 2, 3);
    try expectVec3Approx(ry.rotate(rx.rotate(v)), ry.mul(rx).rotate(v));
    try expectMat4Approx(ry.toMat4().mul(rx.toMat4()), ry.mul(rx).toMat4());
}

test "quat conjugate and inverse undo a rotation" {
    const q = Quat.fromAxisAngle(Vec3.init(1, 1, 0), 0.9);
    try expectQuatApprox(Quat.identity(), q.mul(q.conjugate()));
    try expectQuatApprox(Quat.identity(), q.mul(q.inverse()));
    const long = Quat.init(0, 0, 2, 0);
    try expectQuatApprox(Quat.identity(), long.mul(long.inverse()));
}

test "quat normalize and inverse of zero length give identity" {
    try std.testing.expectEqual(Quat.identity(), Quat.init(0, 0, 0, 0).normalize());
    try std.testing.expectEqual(Quat.identity(), Quat.init(0, 0, 0, 0).inverse());
}

test "quat slerp end points and midpoint" {
    const axis = Vec3.init(0, 1, 0);
    const a = Quat.fromAxisAngle(axis, 0);
    const b = Quat.fromAxisAngle(axis, 1.0);
    try expectQuatApprox(a, a.slerp(b, 0));
    try expectQuatApprox(b, a.slerp(b, 1));
    try expectQuatApprox(Quat.fromAxisAngle(axis, 0.5), a.slerp(b, 0.5));
}

test "quat slerp takes the shorter arc" {
    const axis = Vec3.init(0, 0, 1);
    const a = Quat.fromAxisAngle(axis, 0.2);
    const b = Quat.fromAxisAngle(axis, 0.6);
    const neg_b = Quat.init(-b.x, -b.y, -b.z, -b.w);
    const mid = a.slerp(neg_b, 0.5);
    try expectVec3Approx(Quat.fromAxisAngle(axis, 0.4).rotate(Vec3.init(1, 0, 0)), mid.rotate(Vec3.init(1, 0, 0)));
}

test "quat slerp of parallel quaternions" {
    const q = Quat.fromAxisAngle(Vec3.init(1, 0, 0), 0.3);
    const r = q.slerp(q, 0.5);
    try std.testing.expect(!std.math.isNan(r.w));
    try expectQuatApprox(q, r);
}
