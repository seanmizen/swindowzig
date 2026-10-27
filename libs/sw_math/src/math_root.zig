/// sw_math - Math library for 3D graphics
/// Provides vectors, matrices, quaternions, boxes, rays, planes, and camera
/// projection/view transforms, and a camera controller
pub const Vec2 = @import("vec2.zig").Vec2;
pub const Vec3 = @import("vec3.zig").Vec3;
pub const Vec4 = @import("vec4.zig").Vec4;
pub const Mat4 = @import("mat4.zig").Mat4;
pub const Quat = @import("quat.zig").Quat;
pub const Aabb = @import("aabb.zig").Aabb;
pub const Ray = @import("ray.zig").Ray;
pub const Plane = @import("plane.zig").Plane;
pub const perspective = @import("transforms.zig").perspective;
pub const lookAt = @import("transforms.zig").lookAt;
/// Camera controller: `camera.Controller`, `camera.Settings`, `camera.Input`.
pub const camera = @import("camera.zig");
pub const CameraController = camera.Controller;

test {
    @import("std").testing.refAllDecls(@This());
}

// The games call these functions. A change to one of these types breaks
// them, so this test stops the build.
test "existing public API keeps its signatures" {
    const expectEqual = @import("std").testing.expectEqual;
    try expectEqual(fn (f32, f32, f32) Vec3, @TypeOf(Vec3.init));
    try expectEqual(fn () Vec3, @TypeOf(Vec3.zero));
    try expectEqual(fn () Vec3, @TypeOf(Vec3.one));
    try expectEqual(fn (Vec3, Vec3) Vec3, @TypeOf(Vec3.add));
    try expectEqual(fn (Vec3, Vec3) Vec3, @TypeOf(Vec3.sub));
    try expectEqual(fn (Vec3, f32) Vec3, @TypeOf(Vec3.scale));
    try expectEqual(fn (Vec3, Vec3) f32, @TypeOf(Vec3.dot));
    try expectEqual(fn (Vec3, Vec3) Vec3, @TypeOf(Vec3.cross));
    try expectEqual(fn (Vec3) f32, @TypeOf(Vec3.length));
    try expectEqual(fn (Vec3) f32, @TypeOf(Vec3.lengthSq));
    try expectEqual(fn (Vec3) Vec3, @TypeOf(Vec3.normalize));
    try expectEqual(fn (Vec3) Vec3, @TypeOf(Vec3.negate));

    try expectEqual(fn () Mat4, @TypeOf(Mat4.identity));
    try expectEqual(fn () Mat4, @TypeOf(Mat4.zero));
    try expectEqual(fn (*const Mat4, usize, usize) f32, @TypeOf(Mat4.get));
    try expectEqual(fn (*Mat4, usize, usize, f32) void, @TypeOf(Mat4.set));
    try expectEqual(fn (Mat4, Mat4) Mat4, @TypeOf(Mat4.mul));
    try expectEqual(fn (Mat4) Mat4, @TypeOf(Mat4.transpose));
    try expectEqual(fn (f32, f32, f32) Mat4, @TypeOf(Mat4.translation));
    try expectEqual(fn (f32) Mat4, @TypeOf(Mat4.scaling));
    try expectEqual(fn (f32) Mat4, @TypeOf(Mat4.rotationX));
    try expectEqual(fn (f32) Mat4, @TypeOf(Mat4.rotationY));
    try expectEqual(fn (f32) Mat4, @TypeOf(Mat4.rotationZ));

    try expectEqual(fn (f32, f32, f32, f32) Mat4, @TypeOf(perspective));
    try expectEqual(fn (Vec3, Vec3, Vec3) Mat4, @TypeOf(lookAt));
}
