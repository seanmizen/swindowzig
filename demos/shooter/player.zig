// First-person movement: walk, jump, gravity, and box collision with a
// small step up and step down. Also the lean (Q and E) and the hit boxes,
// which move with the lean. From the action game (seanorepo apps/action),
// on the boxes of the snowy arena (arena.zig) in place of its maps. The
// bots use the same movement.
const std = @import("std");
const vec = @import("vec.zig");
const map = @import("arena.zig");
const V3 = vec.V3;
const v3 = vec.v3;

pub const radius: f32 = 0.32;
pub const height: f32 = 1.75;
pub const eye: f32 = 1.6;
/// The highest step that a player walks up, and the deepest step down that
/// keeps the feet on the ground.
const step_up: f32 = 0.45;
const gravity: f32 = 19.0;
const jump_speed: f32 = 6.2;
pub const walk_speed: f32 = 6.4;
const ground_accel: f32 = 70.0;
const air_accel: f32 = 14.0;

/// The lean: the upper body turns about the hips. At full lean the eye
/// moves `lean_reach` to the side and the camera rolls `lean_roll`.
pub const hip: f32 = 0.9;
pub const lean_reach: f32 = 0.34;
pub const lean_roll: f32 = 0.14;
/// Full lean in 1 / lean_speed seconds.
const lean_speed: f32 = 7.0;
/// The half size of the box around the eye that a wall stops.
const head_r: f32 = 0.16;

pub const Player = struct {
    pos: V3 = v3(0, 0, 0), // feet
    vel: V3 = v3(0, 0, 0),
    yaw: f32 = 0,
    pitch: f32 = 0,
    grounded: bool = false,
    /// The distance walked, for the view bob.
    stride: f32 = 0,
    /// The head bob amount: the speed on the ground over the walk speed
    /// (0 to 1.5), with a short lag. 0 in the air and when standing still.
    bob: f32 = 0,
    /// -1 full lean left, 0 upright, 1 full lean right.
    lean: f32 = 0,

    /// The eye, with the lean.
    pub fn eyePos(self: *const Player) V3 {
        return self.pos + v3(0, eye, 0) + leanOffset(self.yaw, self.lean, eye);
    }

    fn headBlocked(self: *const Player, lean: f32) bool {
        const e = self.pos + v3(0, eye, 0) + leanOffset(self.yaw, lean, eye);
        return map.overlaps(e - vec.s(head_r), e + v3(head_r, 0.1, head_r));
    }

    /// Move the lean toward `want` (-1, 0 or 1). A wall stops the lean
    /// before the head (and the camera) goes into it.
    pub fn updateLean(self: *Player, dt: f32, want: f32) void {
        const k = lean_speed * dt;
        self.lean += std.math.clamp(want - self.lean, -k, k);
        const mag = @abs(self.lean);
        if (mag < 1e-4) {
            self.lean = 0;
            return;
        }
        const dir: f32 = if (self.lean > 0) 1 else -1;
        // Samples 0.1 of a lean (3.4 cm) apart, smaller than the head box.
        const n: usize = @intFromFloat(@ceil(mag / 0.1));
        var free: f32 = 0;
        for (1..n + 1) |i| {
            const l = @min(mag, @as(f32, @floatFromInt(i)) * 0.1);
            if (self.headBlocked(dir * l)) break;
            free = l;
        }
        self.lean = dir * free;
    }

    fn boundsAt(p: V3) [2]V3 {
        return .{ p - v3(radius, 0, radius), p + v3(radius, height, radius) };
    }

    fn blocked(p: V3) bool {
        const b = boundsAt(p);
        return map.overlaps(b[0], b[1]);
    }

    /// The highest floor under feet at p, from `down` below them to `up`
    /// above them, or null.
    fn floorNear(p: V3, down: f32, up: f32) ?f32 {
        return map.floorTop(p - v3(radius, down, radius), p + v3(radius, up, radius));
    }

    /// Move along one axis. On a horizontal axis, step up onto a low box or
    /// a ramp.
    fn moveAxis(self: *Player, comptime axis: usize, amount: f32) bool {
        var next = self.pos;
        next[axis] += amount;
        if (!blocked(next)) {
            self.pos = next;
            return true;
        }
        if (axis != 1 and self.grounded) {
            // Put the feet on the top of the step, and check that the body
            // fits there and above the feet before the move.
            if (floorNear(next, 0, step_up)) |y| {
                const up = v3(next[0], y, next[2]);
                if (y > self.pos[1] and !blocked(up) and !blocked(v3(self.pos[0], y, self.pos[2]))) {
                    self.pos = up;
                    return true;
                }
            }
        }
        // Slide to the contact in small steps.
        const n: usize = 8;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            var p = self.pos;
            p[axis] += amount / @as(f32, @floatFromInt(n));
            if (blocked(p)) break;
            self.pos = p;
        }
        return false;
    }

    /// One fixed step. `wish` is the input direction in world XZ (length 0
    /// to 1).
    pub fn step(self: *Player, dt: f32, wish: V3, jump: bool, speed_scale: f32) void {
        const target = wish * vec.s(walk_speed * speed_scale);
        const accel = if (self.grounded) ground_accel else air_accel;
        inline for (.{ 0, 2 }) |a| {
            const diff = target[a] - self.vel[a];
            const max_d = accel * dt;
            self.vel[a] += std.math.clamp(diff, -max_d, max_d);
        }
        if (jump and self.grounded) {
            self.vel[1] = jump_speed;
            self.grounded = false;
        }
        const on_ground = self.grounded;
        self.vel[1] -= gravity * dt;

        const before = self.pos;
        if (!self.moveAxis(0, self.vel[0] * dt)) self.vel[0] = 0;
        if (!self.moveAxis(2, self.vel[2] * dt)) self.vel[2] = 0;
        const falling = self.vel[1] <= 0;
        if (!self.moveAxis(1, self.vel[1] * dt)) {
            self.grounded = falling;
            self.vel[1] = 0;
        } else {
            // Still on the ground when a small probe down hits.
            self.grounded = falling and blocked(self.pos - v3(0, 0.04, 0));
        }
        // Step down: a player on the ground stays on it when the floor goes
        // down by up to step_up (the top of a crate).
        if (on_ground and falling) {
            if (floorNear(self.pos, step_up, 0)) |y| {
                const p = v3(self.pos[0], y, self.pos[2]);
                if (!blocked(p)) {
                    self.pos = p;
                    self.vel[1] = 0;
                    self.grounded = true;
                }
            }
        }
        if (self.pos[1] < map.kill_y) {
            self.pos = map.player_spawn.pos;
            self.vel = v3(0, 0, 0);
        }
        const moved = self.pos - before;
        const dist = @sqrt(moved[0] * moved[0] + moved[2] * moved[2]);
        if (self.grounded) self.stride += dist;
        const bob_target: f32 = if (self.grounded) @min(1.5, dist / dt / walk_speed) else 0;
        self.bob += (bob_target - self.bob) * @min(1, dt * 12);
    }
};

/// The upper-body angle about the hips for a lean (-1 to 1). Positive
/// leans right.
pub fn leanAngle(lean: f32) f32 {
    return std.math.asin(std.math.clamp(lean * lean_reach / (eye - hip), -1, 1));
}

/// The move of a body point `h` above the feet for this lean. The upper
/// body turns about the hips, so a point below the hips does not move.
pub fn leanOffset(yaw: f32, lean: f32, h: f32) V3 {
    if (lean == 0) return v3(0, 0, 0);
    const above = @max(0, h - hip);
    const a = leanAngle(lean);
    const right = v3(@cos(yaw), 0, -@sin(yaw));
    return right * vec.s(@sin(a) * above) + v3(0, (@cos(a) - 1) * above, 0);
}

pub const HitBox = struct { min: V3, max: V3 };

/// The hit boxes of a player: the legs, the torso and the head (index 2).
/// The torso and the head move with the lean.
pub fn hitBoxes(feet: V3, yaw: f32, lean: f32) [3]HitBox {
    const torso = leanOffset(yaw, lean, (hip + 1.46) / 2);
    const head = feet + v3(0, 1.62, 0) + leanOffset(yaw, lean, 1.62);
    return .{
        .{ .min = feet - v3(0.3, 0, 0.3), .max = feet + v3(0.3, hip, 0.3) },
        .{ .min = feet + torso + v3(-0.3, hip, -0.3), .max = feet + torso + v3(0.3, 1.46, 0.3) },
        .{ .min = head - vec.s(0.16), .max = head + vec.s(0.16) },
    };
}

/// The three points that a blast checks: the legs, the chest and the head.
/// The chest and the head move with the lean.
pub fn blastPoints(feet: V3, yaw: f32, lean: f32) [3]V3 {
    return .{
        feet + v3(0, 0.3, 0),
        feet + v3(0, 1.2, 0) + leanOffset(yaw, lean, 1.2),
        feet + v3(0, 1.6, 0) + leanOffset(yaw, lean, 1.6),
    };
}
