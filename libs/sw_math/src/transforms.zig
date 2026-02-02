const std = @import("std");
const Mat4 = @import("mat4.zig").Mat4;
const Vec3 = @import("vec3.zig").Vec3;

/// Create perspective projection matrix (WebGPU: right-handed, Z from 0 to 1)
/// fov: vertical field of view in radians
/// aspect: width / height
/// near: near clipping plane distance
/// far: far clipping plane distance
pub fn perspective(fov: f32, aspect: f32, near: f32, far: f32) Mat4 {
    const f = 1.0 / @tan(fov / 2.0);
    const nf = 1.0 / (near - far);

    // WebGPU/Vulkan-style: RH coords, [0,1] depth, column-major
    return .{ .data = [_]f32{
        f / aspect, 0,  0,           0,
        0,          f,  0,           0,
        0,          0,  far * nf,    -1,
        0,          0,  near * far * nf, 0,
    } };
}

/// Create look-at view matrix (right-handed)
/// eye: camera position
/// target: point camera is looking at
/// up: up direction (typically 0, 1, 0)
pub fn lookAt(eye: Vec3, target: Vec3, up: Vec3) Mat4 {
    const forward = target.sub(eye).normalize();
    const right = forward.cross(up).normalize();
    const up_actual = right.cross(forward);

    return .{ .data = [_]f32{
        right.x,                  up_actual.x,                  -forward.x,                  0,
        right.y,                  up_actual.y,                  -forward.y,                  0,
        right.z,                  up_actual.z,                  -forward.z,                  0,
        -right.dot(eye),          -up_actual.dot(eye),          forward.dot(eye),            1,
    } };
}

test "perspective matrix" {
    const proj = perspective(std.math.pi / 2.0, 16.0 / 9.0, 0.1, 100.0);
    // Basic sanity checks
    try std.testing.expect(proj.get(0, 0) > 0);
    try std.testing.expect(proj.get(1, 1) > 0);
    try std.testing.expect(proj.get(2, 2) < 0);
}

test "lookAt matrix" {
    const eye = Vec3.init(0, 0, 5);
    const target = Vec3.init(0, 0, 0);
    const up = Vec3.init(0, 1, 0);
    const view = lookAt(eye, target, up);

    // Should be identity-ish when looking down -Z from +Z
    try std.testing.expectApproxEqAbs(@as(f32, 1), view.get(0, 0), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), view.get(1, 1), 0.0001);
}
