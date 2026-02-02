const std = @import("std");

pub fn Camera(comptime Vec3Type: type, comptime Mat4Type: type, comptime math_funcs: anytype) type {
    return struct {
        const Self = @This();
        const Vec3 = Vec3Type;
        const Mat4 = Mat4Type;

        position: Vec3,
        yaw: f32, // Rotation around Y axis (radians)
        pitch: f32, // Rotation around X axis (radians)
        fov: f32, // Field of view (radians)
        aspect: f32, // Width / height
        near: f32,
        far: f32,

        pub fn init(position: Vec3, aspect: f32) Self {
            return .{
                .position = position,
                .yaw = 0,
                .pitch = 0,
                .fov = std.math.pi / 3.0, // 60 degrees
                .aspect = aspect,
                .near = 0.1,
                .far = 100.0,
            };
        }

        /// Get forward direction vector
        pub fn forward(self: *const Self) Vec3 {
            const cy = @cos(self.yaw);
            const sy = @sin(self.yaw);
            const cp = @cos(self.pitch);
            const sp = @sin(self.pitch);

            return Vec3.init(
                cy * cp,
                sp,
                sy * cp,
            );
        }

        /// Get right direction vector
        pub fn right(self: *const Self) Vec3 {
            const forward_vec = self.forward();
            const world_up = Vec3.init(0, 1, 0);
            return forward_vec.cross(world_up).normalize();
        }

        /// Get up direction vector
        pub fn up(self: *const Self) Vec3 {
            const forward_vec = self.forward();
            const right_vec = self.right();
            return right_vec.cross(forward_vec).normalize();
        }

        /// Move camera (WASD controls)
        pub fn move(self: *Self, forward_amount: f32, right_amount: f32, up_amount: f32, dt: f32) void {
            const speed = 5.0 * dt; // 5 units per second

            if (forward_amount != 0) {
                const fwd = self.forward().scale(forward_amount * speed);
                self.position = self.position.add(fwd);
            }

            if (right_amount != 0) {
                const rgt = self.right().scale(right_amount * speed);
                self.position = self.position.add(rgt);
            }

            if (up_amount != 0) {
                self.position.y += up_amount * speed;
            }
        }

        /// Rotate camera (mouse look)
        pub fn rotate(self: *Self, delta_yaw: f32, delta_pitch: f32) void {
            const sensitivity = 0.002;
            self.yaw += delta_yaw * sensitivity;
            self.pitch += delta_pitch * sensitivity;

            // Clamp pitch to prevent flipping
            const max_pitch = std.math.pi / 2.0 - 0.01;
            self.pitch = std.math.clamp(self.pitch, -max_pitch, max_pitch);
        }

        /// Get view matrix
        pub fn getViewMatrix(self: *const Self) Mat4 {
            const target = self.position.add(self.forward());
            const up_vec = Vec3.init(0, 1, 0);
            return math_funcs.lookAt(self.position, target, up_vec);
        }

        /// Get projection matrix
        pub fn getProjectionMatrix(self: *const Self) Mat4 {
            return math_funcs.perspective(self.fov, self.aspect, self.near, self.far);
        }

        /// Get combined view-projection matrix
        pub fn getViewProjectionMatrix(self: *const Self) Mat4 {
            const proj = self.getProjectionMatrix();
            const view = self.getViewMatrix();
            return proj.mul(view);
        }
    };
}
