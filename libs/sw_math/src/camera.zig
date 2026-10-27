//! Camera controller: first-person and third-person modes, look smoothing
//! and a field-of-view change.
//!
//! The controller is pure (REQ-CAMERA-002). It reads no platform input and
//! no clock. The game gives the look and move values and dt to `update`, and
//! gets the view and projection matrices back. A game can feed it from
//! `sw_core` `ActionMap` and `MouseSettings.look`.
//!
//! Axes: right-handed, +y is up. With yaw 0 and pitch 0 the camera looks
//! along -z, the same as `lookAt` and `perspective`. A positive yaw turns
//! the camera to the left (the right-hand rule around +y). A positive pitch
//! turns it up. All angles are in radians.
//!
//! The smoothing is exponential, so the result does not depend on the frame
//! rate (REQ-CAMERA-001).
const std = @import("std");
const Vec2 = @import("vec2.zig").Vec2;
const Vec3 = @import("vec3.zig").Vec3;
const Mat4 = @import("mat4.zig").Mat4;
const Quat = @import("quat.zig").Quat;
const Ray = @import("ray.zig").Ray;
const transforms = @import("transforms.zig");

const deg = std.math.pi / 180.0;
const two_pi: f32 = 2.0 * std.math.pi;

pub const Mode = enum {
    /// The eye is at the target point.
    first_person,
    /// The eye is behind the target point, on the line of view. A ray test
    /// from the game stops it at walls.
    third_person,
};

pub const Settings = struct {
    mode: Mode = .first_person,

    /// Radians of turn for one unit of look input. One unit is one pixel of
    /// mouse movement when the game gives `MouseSettings.look`.
    look_scale: f32 = 0.0025,
    /// The pitch limits. Keep them inside (-pi/2, pi/2): at a pitch of
    /// +-pi/2 the yaw has no effect on the view.
    min_pitch: f32 = -89.0 * deg,
    max_pitch: f32 = 89.0 * deg,
    /// Time constant of the look smoothing, in seconds. After this time the
    /// camera turned 63% of the remaining angle. 0 turns smoothing off.
    look_smoothing: f32 = 0,

    /// Speed of the move input, in world units per second.
    move_speed: f32 = 5.0,

    /// The vertical field of view without a boost.
    fov: f32 = 70.0 * deg,
    /// The field of view that `Input.fov_boost = 1` adds. A game can set
    /// the boost from the speed of the player.
    fov_boost: f32 = 10.0 * deg,
    /// Time constant of the field-of-view change, in seconds. 0 turns
    /// smoothing off.
    fov_smoothing: f32 = 0.1,
    /// Limits of the field of view after the boost.
    min_fov: f32 = 1.0 * deg,
    max_fov: f32 = 170.0 * deg,

    /// The distance from the target point to the eye in third person.
    distance: f32 = 4.0,
    /// Half the size of the cube of probe rays round the target point. The
    /// controller sends a ray from each corner, so the eye stays this far
    /// from a wall. 0 sends one ray from the target point.
    probe_radius: f32 = 0.1,
    /// Time constant of the move away from the target after a wall stops
    /// the eye, in seconds. The move to the target is immediate, so the eye
    /// does not go through a wall. 0 turns smoothing off.
    distance_smoothing: f32 = 0.2,

    near: f32 = 0.05,
    far: f32 = 1000.0,
};

/// The input of one update. The game makes it from its actions.
pub const Input = struct {
    /// Look movement, with the same signs as a mouse movement on the
    /// screen: x > 0 turns right, y > 0 turns down. `Settings.look_scale`
    /// changes it to radians.
    look: Vec2 = .{ .x = 0, .y = 0 },
    /// Move direction in camera axes: x is right, y is world up, z is
    /// forward. Each component is usually from -1 to 1. Forward and right
    /// stay horizontal.
    move: Vec3 = .{ .x = 0, .y = 0, .z = 0 },
    /// 0 gives `Settings.fov`. 1 adds all of `Settings.fov_boost`.
    fov_boost: f32 = 0,
    /// Width / height of the view.
    aspect: f32 = 1,
};

/// A ray test that the game gives, for example a voxel ray cast. `hitFn`
/// gives the distance along the ray to the first solid surface, or null
/// when no surface is nearer than `max_distance`. The direction of the ray
/// is a unit vector.
pub const RayTest = struct {
    context: ?*anyopaque = null,
    hitFn: *const fn (context: ?*anyopaque, ray: Ray, max_distance: f32) ?f32,

    pub fn hit(self: RayTest, ray: Ray, max_distance: f32) ?f32 {
        return self.hitFn(self.context, ray, max_distance);
    }
};

pub const Output = struct {
    view: Mat4,
    projection: Mat4,
    /// projection * view.
    view_projection: Mat4,
    /// The position of the eye in the world.
    eye: Vec3,
    /// Unit vector in the direction of view.
    forward: Vec3,
    /// The camera rotation (camera axes to world axes).
    rotation: Quat,
    /// The vertical field of view of `projection`.
    fov: f32,
};

/// 1 - exp(-dt / time_constant): the part of the remaining distance that
/// exponential smoothing moves in dt. Two steps of dt / 2 move the same
/// part as one step of dt.
pub fn smoothFactor(dt: f32, time_constant: f32) f32 {
    if (!(dt > 0)) return 0;
    if (!(time_constant > 0)) return 1;
    return 1.0 - @exp(-dt / time_constant);
}

pub const Controller = struct {
    settings: Settings,
    /// The point that the camera follows: the eye in first person, the
    /// centre of the orbit in third person. The move input changes it. A
    /// game that moves its own player sets it each frame.
    target: Vec3 = Vec3.zero(),
    /// The rotation that the camera shows now.
    yaw: f32 = 0,
    pitch: f32 = 0,
    /// The rotation that the smoothing goes to.
    goal_yaw: f32 = 0,
    goal_pitch: f32 = 0,
    /// The field of view that the camera shows now.
    fov: f32,
    /// The third-person distance that the camera shows now. It is 0 in
    /// first person, so a change to third person moves the eye out with
    /// the smoothing.
    distance: f32 = 0,

    pub fn init(settings: Settings) Controller {
        return .{
            .settings = settings,
            .fov = settings.fov,
            .distance = if (settings.mode == .third_person) @max(settings.distance, 0) else 0,
        };
    }

    /// Set the rotation with no smoothing. The pitch limits clamp the pitch.
    pub fn setRotation(self: *Controller, yaw: f32, pitch: f32) void {
        self.goal_yaw = yaw;
        self.goal_pitch = std.math.clamp(pitch, self.settings.min_pitch, self.settings.max_pitch);
        self.wrapYaw();
        self.yaw = self.goal_yaw;
        self.pitch = self.goal_pitch;
    }

    /// Set the point that the camera follows.
    pub fn setTarget(self: *Controller, target: Vec3) void {
        self.target = target;
    }

    /// The camera rotation for a yaw and a pitch.
    pub fn rotationOf(yaw: f32, pitch: f32) Quat {
        const q_yaw = Quat.fromAxisAngle(Vec3.init(0, 1, 0), yaw);
        const q_pitch = Quat.fromAxisAngle(Vec3.init(1, 0, 0), pitch);
        return q_yaw.mul(q_pitch);
    }

    /// The unit vector of view for a yaw and a pitch.
    pub fn forwardOf(yaw: f32, pitch: f32) Vec3 {
        const cp = @cos(pitch);
        return Vec3.init(-@sin(yaw) * cp, @sin(pitch), -@cos(yaw) * cp);
    }

    /// The world vector of a move input in camera axes (see `Input.move`),
    /// for the yaw that the camera shows now. A game that moves its own
    /// player can use it for its physics.
    pub fn moveDirection(self: *const Controller, move: Vec3) Vec3 {
        const s = @sin(self.yaw);
        const c = @cos(self.yaw);
        const right = Vec3.init(c, 0, -s);
        const flat_forward = Vec3.init(-s, 0, -c);
        return right.scale(move.x).add(Vec3.init(0, move.y, 0)).add(flat_forward.scale(move.z));
    }

    /// Apply the input of dt seconds and give the matrices. `ray_test` is
    /// used only in third person. Without it, nothing stops the eye.
    pub fn update(self: *Controller, input: Input, dt_in: f32, ray_test: ?RayTest) Output {
        const s = self.settings;
        const dt: f32 = if (dt_in > 0 and std.math.isFinite(dt_in)) dt_in else 0;

        // Look: the input changes the goal, then the smoothing follows it.
        self.goal_yaw -= input.look.x * s.look_scale;
        self.goal_pitch = std.math.clamp(self.goal_pitch - input.look.y * s.look_scale, s.min_pitch, s.max_pitch);
        self.wrapYaw();
        const k_look = smoothFactor(dt, s.look_smoothing);
        self.yaw += (self.goal_yaw - self.yaw) * k_look;
        self.pitch += (self.goal_pitch - self.pitch) * k_look;

        self.target = self.target.add(self.moveDirection(input.move).scale(s.move_speed * dt));

        const goal_fov = std.math.clamp(s.fov + input.fov_boost * s.fov_boost, s.min_fov, s.max_fov);
        self.fov += (goal_fov - self.fov) * smoothFactor(dt, s.fov_smoothing);
        self.fov = std.math.clamp(self.fov, s.min_fov, s.max_fov);

        const forward = forwardOf(self.yaw, self.pitch);
        var eye = self.target;
        switch (s.mode) {
            .first_person => self.distance = 0,
            .third_person => {
                const allowed = self.maxDistance(forward, ray_test);
                if (allowed < self.distance) {
                    self.distance = allowed;
                } else {
                    self.distance += (allowed - self.distance) * smoothFactor(dt, s.distance_smoothing);
                }
                eye = self.target.sub(forward.scale(self.distance));
            },
        }

        const view = viewMatrix(eye, self.yaw, self.pitch);
        const aspect: f32 = if (input.aspect > 0 and std.math.isFinite(input.aspect)) input.aspect else 1;
        const projection = transforms.perspective(self.fov, aspect, s.near, s.far);
        return .{
            .view = view,
            .projection = projection,
            .view_projection = projection.mul(view),
            .eye = eye,
            .forward = forward,
            .rotation = rotationOf(self.yaw, self.pitch),
            .fov = self.fov,
        };
    }

    /// The largest third-person distance that the ray test allows. The rays
    /// go from the corners of the probe cube, against the line of view.
    fn maxDistance(self: *const Controller, forward: Vec3, ray_test: ?RayTest) f32 {
        const s = self.settings;
        var dist = @max(s.distance, 0);
        const rt = ray_test orelse return dist;
        const back = forward.negate();
        const r = @max(s.probe_radius, 0);
        const count: usize = if (r == 0) 1 else 8;
        for (0..count) |i| {
            const offset = if (r == 0) Vec3.zero() else Vec3.init(
                if (i & 1 == 0) -r else r,
                if (i & 2 == 0) -r else r,
                if (i & 4 == 0) -r else r,
            );
            const ray = Ray.init(self.target.add(offset), back);
            if (rt.hit(ray, dist)) |t| {
                if (t < dist) dist = @max(t, 0);
            }
        }
        return dist;
    }

    /// Keep the goal yaw in [-pi, pi]. The yaw that the camera shows moves
    /// by the same amount, so the smoothing does not turn the long way.
    fn wrapYaw(self: *Controller) void {
        if (!std.math.isFinite(self.goal_yaw)) {
            self.goal_yaw = 0;
            self.yaw = 0;
            return;
        }
        if (self.goal_yaw >= -std.math.pi and self.goal_yaw <= std.math.pi) return;
        const turns = @round(self.goal_yaw / two_pi);
        self.goal_yaw -= turns * two_pi;
        self.yaw -= turns * two_pi;
    }
};

/// The view matrix of a camera at `eye` with a yaw and a pitch. It is the
/// inverse of translation(eye) * rotationY(yaw) * rotationX(pitch). Unlike
/// `lookAt`, it has no problem when the camera looks straight up or down.
pub fn viewMatrix(eye: Vec3, yaw: f32, pitch: f32) Mat4 {
    return Mat4.rotationX(-pitch)
        .mul(Mat4.rotationY(-yaw))
        .mul(Mat4.translation(-eye.x, -eye.y, -eye.z));
}

const eps: f32 = 0.0001;

fn expectVec3Approx(expected: Vec3, actual: Vec3, tolerance: f32) !void {
    try std.testing.expectApproxEqAbs(expected.x, actual.x, tolerance);
    try std.testing.expectApproxEqAbs(expected.y, actual.y, tolerance);
    try std.testing.expectApproxEqAbs(expected.z, actual.z, tolerance);
}

fn expectMat4Approx(expected: Mat4, actual: Mat4) !void {
    for (expected.data, actual.data) |e, a| {
        try std.testing.expectApproxEqAbs(e, a, eps);
    }
}

test "first person: look input turns yaw and pitch" {
    var cam = Controller.init(.{ .look_scale = 0.01 });
    const out = cam.update(.{ .look = .{ .x = 10, .y = -20 } }, 1.0 / 60.0, null);
    // x > 0 turns right (negative yaw). y < 0 turns up.
    try std.testing.expectApproxEqAbs(@as(f32, -0.1), cam.yaw, eps);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), cam.pitch, eps);
    try expectVec3Approx(Controller.forwardOf(-0.1, 0.2), out.forward, eps);
    try std.testing.expect(out.forward.x > 0);
    try std.testing.expect(out.forward.y > 0);
    // The eye is at the target in first person.
    try expectVec3Approx(Vec3.zero(), out.eye, eps);
}

test "first person: the pitch is clamped" {
    var cam = Controller.init(.{ .look_scale = 0.01, .min_pitch = -1.0, .max_pitch = 1.2 });
    _ = cam.update(.{ .look = .{ .x = 0, .y = -1000 } }, 0.016, null);
    try std.testing.expectEqual(@as(f32, 1.2), cam.pitch);
    _ = cam.update(.{ .look = .{ .x = 0, .y = 5000 } }, 0.016, null);
    try std.testing.expectEqual(@as(f32, -1.0), cam.pitch);
    cam.setRotation(0, 3.0);
    try std.testing.expectEqual(@as(f32, 1.2), cam.pitch);
}

test "the yaw stays in range and does not turn the long way" {
    var cam = Controller.init(.{ .look_scale = 1.0, .look_smoothing = 0.1 });
    cam.setRotation(3.0, 0);
    _ = cam.update(.{ .look = .{ .x = -0.4, .y = 0 } }, 0.05, null);
    try std.testing.expect(cam.goal_yaw <= std.math.pi and cam.goal_yaw >= -std.math.pi);
    // The goal is 3.4 rad. The camera went from 3.0 to the goal by the
    // short way, so it is between 3.0 and 3.4 (minus a full turn).
    const shown = cam.yaw + two_pi;
    try std.testing.expect(shown > 3.0 and shown < 3.4);
}

test "the view matrix agrees with lookAt and the rotation" {
    const eye = Vec3.init(1, 2, 3);
    const yaw: f32 = 0.7;
    const pitch: f32 = -0.3;
    const f = Controller.forwardOf(yaw, pitch);
    try expectMat4Approx(transforms.lookAt(eye, eye.add(f), Vec3.init(0, 1, 0)), viewMatrix(eye, yaw, pitch));
    try expectVec3Approx(f, Controller.rotationOf(yaw, pitch).rotate(Vec3.init(0, 0, -1)), eps);
}

test "the view matrix is valid when the camera looks straight up" {
    const v = viewMatrix(Vec3.zero(), 0.5, std.math.pi / 2.0);
    for (v.data) |x| try std.testing.expect(std.math.isFinite(x));
}

test "move input is relative to the yaw" {
    var cam = Controller.init(.{ .move_speed = 2.0 });
    cam.setRotation(std.math.pi / 2.0, 0.5);
    // Yaw +90 degrees looks along -x. Forward stays horizontal.
    _ = cam.update(.{ .move = Vec3.init(0, 0, 1) }, 0.5, null);
    try expectVec3Approx(Vec3.init(-1, 0, 0), cam.target, eps);
    _ = cam.update(.{ .move = Vec3.init(1, 1, 0) }, 0.5, null);
    try expectVec3Approx(Vec3.init(-1, 1, -1), cam.target, eps);
}

const Wall = struct {
    box: @import("aabb.zig").Aabb,
    calls: usize = 0,

    fn hit(context: ?*anyopaque, ray: Ray, max_distance: f32) ?f32 {
        const self: *Wall = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        const h = ray.intersectAabb(self.box) orelse return null;
        if (h.t_enter > max_distance) return null;
        return h.t_enter;
    }

    fn rayTest(self: *Wall) RayTest {
        return .{ .context = self, .hitFn = hit };
    }
};

test "third person: the eye is behind the target" {
    var cam = Controller.init(.{ .mode = .third_person, .distance = 4, .distance_smoothing = 0 });
    cam.setTarget(Vec3.init(0, 1, 0));
    const out = cam.update(.{}, 0.016, null);
    try expectVec3Approx(Vec3.init(0, 1, 4), out.eye, eps);
    try expectVec3Approx(Vec3.init(0, 0, -1), out.forward, eps);
}

test "third person: a wall stops the eye" {
    const Aabb = @import("aabb.zig").Aabb;
    var wall = Wall{ .box = Aabb.init(Vec3.init(-10, -10, 2), Vec3.init(10, 10, 3)) };
    var cam = Controller.init(.{ .mode = .third_person, .distance = 4, .probe_radius = 0.1, .distance_smoothing = 0.2 });
    const out = cam.update(.{}, 0.016, wall.rayTest());
    try std.testing.expectEqual(@as(usize, 8), wall.calls);
    // The probe corners at z = +0.1 hit the wall at t = 1.9.
    try std.testing.expectApproxEqAbs(@as(f32, 1.9), out.eye.z, eps);
    try std.testing.expect(out.eye.z < 2.0);

    // The wall goes away: the eye moves back out with the smoothing, and
    // does not jump.
    const near = cam.update(.{}, 0.016, null);
    try std.testing.expect(near.eye.z > 1.9 and near.eye.z < 4.0);
    for (0..200) |_| _ = cam.update(.{}, 0.016, null);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), cam.distance, 0.001);

    // The wall comes back: the eye moves in at once, with no smoothing.
    const back = cam.update(.{}, 0.016, wall.rayTest());
    try std.testing.expectApproxEqAbs(@as(f32, 1.9), back.eye.z, eps);
}

test "third person: one ray when the probe radius is 0" {
    const Aabb = @import("aabb.zig").Aabb;
    var wall = Wall{ .box = Aabb.init(Vec3.init(-10, -10, 2), Vec3.init(10, 10, 3)) };
    var cam = Controller.init(.{ .mode = .third_person, .probe_radius = 0 });
    const out = cam.update(.{}, 0.016, wall.rayTest());
    try std.testing.expectEqual(@as(usize, 1), wall.calls);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), out.eye.z, eps);
}

test "look smoothing converges to the goal" {
    var cam = Controller.init(.{ .look_scale = 0.01, .look_smoothing = 0.05 });
    _ = cam.update(.{ .look = .{ .x = -50, .y = -30 } }, 1.0 / 60.0, null);
    try std.testing.expect(cam.yaw > 0 and cam.yaw < 0.5);
    for (0..120) |_| _ = cam.update(.{}, 1.0 / 60.0, null);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), cam.yaw, eps);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), cam.pitch, eps);
}

test "smoothing does not depend on the frame rate" {
    const settings = Settings{
        .look_scale = 0.01,
        .look_smoothing = 0.05,
        .fov_smoothing = 0.1,
        .mode = .third_person,
        .distance_smoothing = 0.2,
    };
    const dt: f32 = 1.0 / 30.0;
    const in = Input{ .look = .{ .x = 40, .y = 25 }, .fov_boost = 1 };

    var one = Controller.init(settings);
    const a = one.update(in, dt, null);

    var two = Controller.init(settings);
    _ = two.update(in, dt / 2.0, null);
    const b = two.update(.{ .fov_boost = 1 }, dt / 2.0, null);

    try std.testing.expectApproxEqAbs(one.yaw, two.yaw, 1e-5);
    try std.testing.expectApproxEqAbs(one.pitch, two.pitch, 1e-5);
    try std.testing.expectApproxEqAbs(one.fov, two.fov, 1e-5);
    try std.testing.expectApproxEqAbs(one.distance, two.distance, 1e-5);
    try expectVec3Approx(a.eye, b.eye, 1e-4);
    try expectMat4Approx(a.view_projection, b.view_projection);
}

test "smoothFactor" {
    try std.testing.expectEqual(@as(f32, 0), smoothFactor(0, 0.1));
    try std.testing.expectEqual(@as(f32, 0), smoothFactor(-1, 0.1));
    try std.testing.expectEqual(@as(f32, 1), smoothFactor(0.1, 0));
    const half = smoothFactor(0.05, 0.1);
    const full = smoothFactor(0.1, 0.1);
    try std.testing.expectApproxEqAbs(full, 1 - (1 - half) * (1 - half), 1e-6);
}

test "the field of view changes with the boost" {
    var cam = Controller.init(.{ .fov = 70 * deg, .fov_boost = 10 * deg, .fov_smoothing = 0.1 });
    const base = cam.update(.{ .aspect = 2 }, 0.016, null);
    try std.testing.expectApproxEqAbs(@as(f32, 70 * deg), base.fov, eps);
    try expectMat4Approx(transforms.perspective(70 * deg, 2, 0.05, 1000), base.projection);

    const first = cam.update(.{ .fov_boost = 1, .aspect = 2 }, 0.016, null);
    try std.testing.expect(first.fov > 70 * deg and first.fov < 80 * deg);
    for (0..200) |_| _ = cam.update(.{ .fov_boost = 1 }, 0.016, null);
    try std.testing.expectApproxEqAbs(@as(f32, 80 * deg), cam.fov, eps);

    // A wider field of view gives a smaller projection scale.
    const wide = cam.update(.{ .fov_boost = 1, .aspect = 2 }, 0.016, null);
    try std.testing.expect(wide.projection.get(1, 1) < base.projection.get(1, 1));

    // No smoothing: the change is immediate. The limits clamp the result.
    var instant = Controller.init(.{ .fov_smoothing = 0, .max_fov = 100 * deg, .fov_boost = 90 * deg });
    try std.testing.expectApproxEqAbs(@as(f32, 100 * deg), instant.update(.{ .fov_boost = 1 }, 0.016, null).fov, eps);
}

test "bad dt and aspect values do not give NaN" {
    var cam = Controller.init(.{ .look_smoothing = 0.1 });
    const out = cam.update(.{ .look = .{ .x = 5, .y = 5 }, .aspect = 0 }, std.math.nan(f32), null);
    for (out.view_projection.data) |x| try std.testing.expect(std.math.isFinite(x));
}
