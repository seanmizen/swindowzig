/// sw_math - Math library for 3D graphics
/// Provides Vec3, Mat4, and camera projection/view transforms

pub const Vec3 = @import("vec3.zig").Vec3;
pub const Mat4 = @import("mat4.zig").Mat4;
pub const perspective = @import("transforms.zig").perspective;
pub const lookAt = @import("transforms.zig").lookAt;

test {
    @import("std").testing.refAllDecls(@This());
}
