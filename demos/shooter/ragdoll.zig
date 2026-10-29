// A simple ragdoll for the bots of the shooter demo, from the action game
// (seanorepo apps/action): a dead bot falls, tumbles and lies on the snow.
// bots.zig starts one when a bot dies, steps it in each tick, and draws it
// with the box model of npc.zig.
//
// - One point for each joint of the NPC model (npc.Joint), with Verlet
//   steps and gravity.
// - Rigid parts: a stick of fixed length between the two joints of each
//   limb. The hips and the chest are one rigid body (sticks between the
//   pelvis, the neck, the shoulders and the hip joints).
// - Joint limits: a smallest and a largest distance across each elbow, each
//   knee and the neck. The knees bend only to the front and the elbows only
//   to the back.
// - Collision: each point is a ball. It does not go into a solid box of the
//   map (the ground, the kerbs, the walls), and it slides on it with
//   friction.
// - A body that stops moving sleeps: no more steps.
//
// The steps use only the start state and the arena, so a replay gives the
// same body from the same start (REQ-DEMO-021).
const std = @import("std");
const vec = @import("vec.zig");
const map = @import("arena.zig");
const npc = @import("npc.zig");
const V3 = vec.V3;
const v3 = vec.v3;
const J = npc.Joint;

const gravity: f32 = 19.0;
/// The constraint passes in each step.
const passes = 8;
/// The speed kept in each step in the air (1 = no drag).
const air_keep: f32 = 0.999;
/// The part of the speed along a surface kept in each step of contact.
const slide_keep: f32 = 0.82;
/// A body sleeps after `sleep_after` s with each point slower than
/// `sleep_speed`.
const sleep_speed: f32 = 0.08;
const sleep_after: f32 = 0.6;
/// The most boxes near a body.
const max_near = 48;

/// The ball radius of each joint point, in the order of npc.Joint.
const radius = [npc.joint_count]f32{ 0.13, 0.12, 0.1, 0.1, 0.07, 0.06, 0.1, 0.07, 0.06, 0.09, 0.08, 0.07, 0.09, 0.08, 0.07 };

const Stick = struct { a: J, b: J };
/// The rigid sticks: the torso, the head and the limbs.
const sticks = [_]Stick{
    .{ .a = .pelvis, .b = .neck },        .{ .a = .pelvis, .b = .shoulder_l },  .{ .a = .pelvis, .b = .shoulder_r },
    .{ .a = .neck, .b = .shoulder_l },    .{ .a = .neck, .b = .shoulder_r },    .{ .a = .shoulder_l, .b = .shoulder_r },
    .{ .a = .pelvis, .b = .hip_l },       .{ .a = .pelvis, .b = .hip_r },       .{ .a = .hip_l, .b = .hip_r },
    .{ .a = .hip_l, .b = .shoulder_l },   .{ .a = .hip_r, .b = .shoulder_r },   .{ .a = .hip_l, .b = .shoulder_r },
    .{ .a = .hip_r, .b = .shoulder_l },   .{ .a = .neck, .b = .hip_l },         .{ .a = .neck, .b = .hip_r },
    .{ .a = .neck, .b = .head_top },      .{ .a = .shoulder_l, .b = .elbow_l }, .{ .a = .elbow_l, .b = .hand_l },
    .{ .a = .shoulder_r, .b = .elbow_r }, .{ .a = .elbow_r, .b = .hand_r },     .{ .a = .hip_l, .b = .knee_l },
    .{ .a = .knee_l, .b = .foot_l },      .{ .a = .hip_r, .b = .knee_r },       .{ .a = .knee_r, .b = .foot_r },
};

const Limit = struct { a: J, b: J, min: f32, max: f32 };
/// The joint limits: the distance across a joint stays in min..max.
const limits = [_]Limit{
    // The elbows and the knees: not folded flat, not past straight.
    .{ .a = .shoulder_l, .b = .hand_l, .min = 0.22, .max = 0.6 },
    .{ .a = .shoulder_r, .b = .hand_r, .min = 0.22, .max = 0.6 },
    .{ .a = .hip_l, .b = .foot_l, .min = 0.32, .max = 0.86 },
    .{ .a = .hip_r, .b = .foot_r, .min = 0.32, .max = 0.86 },
    // The neck: the head does not fold onto a shoulder.
    .{ .a = .head_top, .b = .shoulder_l, .min = 0.34, .max = 0.48 },
    .{ .a = .head_top, .b = .shoulder_r, .min = 0.34, .max = 0.48 },
    .{ .a = .head_top, .b = .pelvis, .min = 0.78, .max = 0.9 },
    // The hips: a thigh does not go into the chest or far behind it.
    .{ .a = .knee_l, .b = .neck, .min = 0.5, .max = 1.1 },
    .{ .a = .knee_r, .b = .neck, .min = 0.5, .max = 1.1 },
    // The shoulders: an elbow does not go into the chest.
    .{ .a = .elbow_l, .b = .hip_r, .min = 0.35, .max = 1.0 },
    .{ .a = .elbow_r, .b = .hip_l, .min = 0.35, .max = 1.0 },
};

/// The rest length of each stick: from a standing NPC.
const rest = blk: {
    @setEvalBranchQuota(200000);
    const j = npc.joints(npc.skeleton(.{ .pos = v3(0, 0, 0), .yaw = 0 }));
    var r: [sticks.len]f32 = undefined;
    for (sticks, 0..) |s, i| r[i] = vec.len(j[@backingInt(s.a)] - j[@backingInt(s.b)]);
    break :blk r;
};

pub const Body = struct {
    on: bool = false,
    p: npc.Joints = undefined,
    /// The points at the last step: the speed is p - prev.
    prev: npc.Joints = undefined,
    asleep: bool = false,
    still: f32 = 0,

    /// A new ragdoll from a skeleton, all its points at velocity `vel`.
    /// `push` adds to the speed of the chest and the head (a shot), so the
    /// body turns as it falls.
    pub fn start(sk: npc.Skeleton, vel: V3, push: V3) Body {
        var b: Body = .{ .on = true };
        b.p = npc.joints(sk);
        for (b.p, 0..) |q, i| {
            const k: f32 = switch (@as(J, @fromBackingInt(@intCast(i)))) {
                .neck, .head_top, .shoulder_l, .shoulder_r => 1,
                .elbow_l, .elbow_r, .hand_l, .hand_r => 0.6,
                .pelvis => 0.3,
                else => 0,
            };
            b.prev[i] = q - (vel + push * vec.s(k)) * vec.s(dt_ref);
        }
        return b;
    }

    /// The frames of the parts.
    pub fn skeleton(self: *const Body) npc.Skeleton {
        return npc.fromJoints(self.p);
    }

    /// The pelvis: where the body lies.
    pub fn centre(self: *const Body) V3 {
        return self.p[@backingInt(J.pelvis)];
    }

    /// One step of dt (the tick of the demo, 1/60 s).
    pub fn step(self: *Body, dt: f32) void {
        if (!self.on or self.asleep) return;
        // The boxes near the body, once a step.
        var lo = v3(1e9, 1e9, 1e9);
        var hi = v3(-1e9, -1e9, -1e9);
        for (self.p) |q| {
            lo = @min(lo, q);
            hi = @max(hi, q);
        }
        var near: [max_near]usize = undefined;
        var n: usize = 0;
        lo -= vec.s(0.6);
        hi += vec.s(0.6);
        for (map.boxes[0..map.box_count], 0..) |bx, i| {
            if (!bx.solid or n == near.len) continue;
            if (lo[0] < bx.max[0] and hi[0] > bx.min[0] and lo[1] < bx.max[1] and hi[1] > bx.min[1] and lo[2] < bx.max[2] and hi[2] > bx.min[2]) {
                near[n] = i;
                n += 1;
            }
        }
        // Verlet: the speed of the last step, and gravity.
        var fastest: f32 = 0;
        for (&self.p, &self.prev) |*q, *pv| {
            const vel = (q.* - pv.*) * vec.s(air_keep);
            pv.* = q.*;
            q.* += vel + v3(0, -gravity * dt * dt, 0);
        }
        var touch: [npc.joint_count]?V3 = @splat(null);
        for (0..passes) |_| {
            for (sticks, 0..) |s, i| self.keep(s.a, s.b, rest[i], rest[i]);
            for (limits) |l| self.keep(l.a, l.b, l.min, l.max);
            self.hinges();
            for (&self.p, 0..) |*q, i| {
                if (collide(q, radius[i], near[0..n])) |nrm| touch[i] = nrm;
            }
        }
        // Friction: a point on a surface loses most of its speed along it,
        // and all of its speed into it.
        for (&self.p, &self.prev, touch) |q, *pv, t| {
            var vel = q - pv.*;
            if (t) |nrm| {
                const into = vec.dot(vel, nrm);
                const along = vel - nrm * vec.s(into);
                vel = along * vec.s(slide_keep) + nrm * vec.s(@max(0, into));
                pv.* = q - vel;
            }
            fastest = @max(fastest, vec.len(vel) / dt);
        }
        self.still = if (fastest < sleep_speed) self.still + dt else 0;
        if (self.still > sleep_after) self.asleep = true;
        // Out of the arena: it sleeps there.
        if (self.centre()[1] < map.kill_y) self.asleep = true;
    }

    /// Move two points along the line between them, half each, so their
    /// distance is in lo..hi.
    fn keep(self: *Body, a: J, b: J, lo: f32, hi: f32) void {
        const pa = &self.p[@backingInt(a)];
        const pb = &self.p[@backingInt(b)];
        const d = pb.* - pa.*;
        const l = vec.len(d);
        if (l < 1e-5) return;
        const want = std.math.clamp(l, lo, hi);
        if (want == l) return;
        const fix = d * vec.s((l - want) / l * 0.5);
        pa.* += fix;
        pb.* -= fix;
    }

    /// The hinge limits: each knee to the front of its leg, each elbow to
    /// the back of its arm. A point on the wrong side goes back onto the
    /// plane of the limb.
    fn hinges(self: *Body) void {
        const pelvis = self.p[@backingInt(J.pelvis)];
        const up = vec.norm(self.p[@backingInt(J.neck)] - pelvis);
        const right = vec.norm(self.p[@backingInt(J.shoulder_r)] - self.p[@backingInt(J.shoulder_l)]);
        // The front of the body: -Z of the model (npc.zig).
        const front = vec.norm(vec.cross(up, right));
        const Hinge = struct { a: J, mid: J, b: J, side: f32 };
        const hs = [_]Hinge{
            .{ .a = .hip_l, .mid = .knee_l, .b = .foot_l, .side = 1 },
            .{ .a = .hip_r, .mid = .knee_r, .b = .foot_r, .side = 1 },
            .{ .a = .shoulder_l, .mid = .elbow_l, .b = .hand_l, .side = -1 },
            .{ .a = .shoulder_r, .mid = .elbow_r, .b = .hand_r, .side = -1 },
        };
        for (hs) |h| {
            const m = &self.p[@backingInt(h.mid)];
            const c = (self.p[@backingInt(h.a)] + self.p[@backingInt(h.b)]) * vec.s(0.5);
            const off = vec.dot(m.* - c, front) * h.side;
            if (off < 0) m.* -= front * vec.s(off * h.side);
        }
    }
};

/// The speed of a new body is per tick of this length.
const dt_ref: f32 = 1.0 / 120.0;

/// Push a ball out of the boxes. Returns the normal of the last contact,
/// or null.
fn collide(q: *V3, r: f32, near: []const usize) ?V3 {
    var hit: ?V3 = null;
    for (near) |bi| {
        const b = map.boxes[bi];
        const c = @min(@max(q.*, b.min), b.max);
        const d = q.* - c;
        const l = vec.len(d);
        if (l >= r) continue;
        if (l > 1e-5) {
            const nrm = d / vec.s(l);
            q.* = c + nrm * vec.s(r);
            hit = nrm;
        } else {
            // The centre is in the box: out through the nearest face.
            var best: f32 = 1e9;
            var nrm = v3(0, 1, 0);
            inline for (0..3) |a| {
                const lo_d = q.*[a] - b.min[a];
                const hi_d = b.max[a] - q.*[a];
                if (lo_d < best) {
                    best = lo_d;
                    nrm = v3(0, 0, 0);
                    nrm[a] = -1;
                }
                if (hi_d < best) {
                    best = hi_d;
                    nrm = v3(0, 0, 0);
                    nrm[a] = 1;
                }
            }
            q.* += nrm * vec.s(best + r);
            hit = nrm;
        }
    }
    return hit;
}
