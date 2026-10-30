// The bot body as an `sw_render` box model (REQ-DEMO-022). The outfit is
// the outfit of npc.zig `buildOutfit`, box for box, so one draw call of
// `BoxModels` draws all the bots, and the bodies cast shadows.
//
// npc.zig gives the pose as a world frame for each part (a Skeleton). A
// box model wants one rotation for each part, about a pivot in the rest
// pose, with the parent before the child. `pose` changes a skeleton to
// the instance transform and the rotations. A skeleton from a ragdoll
// works too: each part turns as its frame, and the joints stay at the
// places of the rest pose.
const std = @import("std");
const sw_math = @import("sw_math");
const sw_render = @import("sw_render");
const vec = @import("vec.zig");
const npc = @import("npc.zig");
const V3 = vec.V3;
const v3 = vec.v3;
const Mat4 = vec.Mat4;
const Quat = sw_math.Quat;
const Part = npc.Part;

/// The parent of each part, in the order of npc.Part.
pub const parents = [npc.part_count]?u8{ null, 0, 1, 1, 3, 1, 5, 0, 7, 0, 9 };

/// The height of the hips over the feet in the rest pose.
const rest_hip: f32 = npc.leg_len - 0.01;

/// The joint of each part, in its parent frame (the hips: over the feet).
fn jointOf(p: Part) V3 {
    return switch (p) {
        .hips => v3(0, rest_hip, 0),
        .chest => npc.waist,
        .head => npc.neck,
        .upper_arm_l => v3(-npc.shoulder_x, npc.shoulder_y, 0),
        .upper_arm_r => v3(npc.shoulder_x, npc.shoulder_y, 0),
        .fore_arm_l, .fore_arm_r => v3(0, npc.elbow_y, 0),
        .thigh_l => v3(-npc.hip_x, npc.hip_y, 0),
        .thigh_r => v3(npc.hip_x, npc.hip_y, 0),
        .shin_l, .shin_r => v3(0, npc.knee_y, 0),
    };
}

/// The pivot of each part in model space (the rest pose, feet at 0).
pub const pivots: [npc.part_count]V3 = blk: {
    var out: [npc.part_count]V3 = undefined;
    for (0..npc.part_count) |i| {
        const p: Part = @fromBackingInt(i);
        out[i] = jointOf(p) + if (parents[i]) |pi| out[pi] else v3(0, 0, 0);
    }
    break :blk out;
};

const B = sw_render.BoxModelBox;

fn box(mn: V3, mx: V3, c: V3) B {
    return .{ .min = .{ mn[0], mn[1], mn[2] }, .max = .{ mx[0], mx[1], mx[2] }, .color = .{ c[0], c[1], c[2] } };
}

fn ex(p: Part) [2]V3 {
    return npc.extents[@backingInt(p)];
}

/// A ring of quilting round a part (npc.zig `ring`).
fn ring(e: [2]V3, y: f32, h: f32, out: f32, c: V3) B {
    return box(v3(e[0][0] - out, y - h / 2, e[0][2] - out), v3(e[1][0] + out, y + h / 2, e[1][2] + out), c);
}

/// The boxes of one part in the frame of the part.
fn partBoxes(comptime p: Part) []const B {
    const e = ex(p);
    return switch (p) {
        .hips, .thigh_l, .thigh_r => &.{box(e[0], e[1], npc.trousers)},
        .shin_l, .shin_r => &.{
            box(v3(-0.065, -0.4, -0.07), v3(0.065, 0.03, 0.07), npc.trousers),
            box(v3(-0.072, -0.4, -0.077), v3(0.072, -0.34, 0.077), npc.trousers),
            box(v3(-0.058, -0.49, -0.19), v3(0.058, -0.38, 0.075), npc.trainer),
            box(v3(-0.062, -0.5, -0.2), v3(0.062, -0.47, 0.085), npc.sole),
        },
        .chest => &.{
            box(e[0], e[1], npc.jacket),
            ring(e, -0.1, 0.05, 0.016, npc.quilt),
            ring(e, 0.06, 0.05, 0.016, npc.quilt),
            ring(e, 0.22, 0.05, 0.016, npc.quilt),
            ring(e, 0.38, 0.05, 0.016, npc.quilt),
            box(v3(-0.15, 0.5, -0.13), v3(0.15, 0.66, 0.13), npc.jacket),
            box(v3(-0.17, 0.46, 0.06), v3(0.17, 0.68, 0.23), npc.quilt),
        },
        .upper_arm_l, .upper_arm_r => &.{
            box(e[0], e[1], npc.jacket),
            ring(e, -0.13, 0.05, 0.012, npc.quilt),
        },
        .fore_arm_l, .fore_arm_r => &.{
            box(e[0], e[1], npc.jacket),
            ring(e, -0.2, 0.05, 0.01, npc.quilt),
            box(v3(-0.045, -0.37, -0.05), v3(0.045, -0.25, 0.05), npc.glove),
        },
        .head => &.{
            box(e[0], e[1], npc.balaclava),
            box(v3(-0.07, 0.14, -0.13), v3(0.07, 0.18, -0.1), npc.skin),
            box(v3(-0.05, 0.15, -0.14), v3(-0.025, 0.17, -0.12), npc.eye_c),
            box(v3(0.025, 0.15, -0.14), v3(0.05, 0.17, -0.12), npc.eye_c),
        },
    };
}

/// The boxes of each part, moved to model space by the pivot.
const model_boxes = blk: {
    var out: [npc.part_count][]const B = undefined;
    for (0..npc.part_count) |i| {
        const p: Part = @fromBackingInt(i);
        const src = partBoxes(p);
        var moved: [src.len]B = undefined;
        const o = pivots[i];
        for (src, 0..) |b, k| {
            moved[k] = .{
                .min = .{ b.min[0] + o[0], b.min[1] + o[1], b.min[2] + o[2] },
                .max = .{ b.max[0] + o[0], b.max[1] + o[1], b.max[2] + o[2] },
                .color = b.color,
            };
        }
        const final = moved;
        out[i] = &final;
    }
    break :blk out;
};

/// The parts of the box model, in the order of npc.Part.
pub const parts: [npc.part_count]sw_render.BoxModelPart = blk: {
    var out: [npc.part_count]sw_render.BoxModelPart = undefined;
    for (0..npc.part_count) |i| {
        out[i] = .{
            .parent = parents[i],
            .pivot = .{ pivots[i][0], pivots[i][1], pivots[i][2] },
            .boxes = model_boxes[i],
        };
    }
    break :blk out;
};

/// The unit quaternion of the rotation part of a rigid matrix.
pub fn quatOf(m: Mat4) Quat {
    const d = m.data;
    // r(row, col) = d[col * 4 + row].
    const r00 = d[0];
    const r11 = d[5];
    const r22 = d[10];
    const r21 = d[6];
    const r12 = d[9];
    const r02 = d[8];
    const r20 = d[2];
    const r10 = d[1];
    const r01 = d[4];
    const tr = r00 + r11 + r22;
    var q: Quat = undefined;
    if (tr > 0) {
        const s = @sqrt(tr + 1) * 2;
        q = .{ .w = 0.25 * s, .x = (r21 - r12) / s, .y = (r02 - r20) / s, .z = (r10 - r01) / s };
    } else if (r00 > r11 and r00 > r22) {
        const s = @sqrt(1 + r00 - r11 - r22) * 2;
        q = .{ .w = (r21 - r12) / s, .x = 0.25 * s, .y = (r01 + r10) / s, .z = (r02 + r20) / s };
    } else if (r11 > r22) {
        const s = @sqrt(1 + r11 - r00 - r22) * 2;
        q = .{ .w = (r02 - r20) / s, .x = (r01 + r10) / s, .y = 0.25 * s, .z = (r12 + r21) / s };
    } else {
        const s = @sqrt(1 + r22 - r00 - r11) * 2;
        q = .{ .w = (r10 - r01) / s, .x = (r02 + r20) / s, .y = (r12 + r21) / s, .z = 0.25 * s };
    }
    return q.normalize();
}

/// The inverse of a rigid matrix (a rotation and a translation).
pub fn rigidInverse(m: Mat4) Mat4 {
    const d = m.data;
    var out: Mat4 = .{ .data = .{
        d[0], d[4], d[8],  0,
        d[1], d[5], d[9],  0,
        d[2], d[6], d[10], 0,
        0,    0,    0,     1,
    } };
    const t = v3(d[12], d[13], d[14]);
    const it = -vec.xdir(out, t);
    out.data[12] = it[0];
    out.data[13] = it[1];
    out.data[14] = it[2];
    return out;
}

pub const Posed = struct {
    transform: Mat4,
    rotations: [npc.part_count]Quat,
};

/// The box model instance of a skeleton.
pub fn pose(sk: npc.Skeleton) Posed {
    var out: Posed = undefined;
    // The hips frame is the instance transform at the pivot of the hips.
    const hp = pivots[0];
    out.transform = sk[0].mul(vec.translate(-hp));
    out.rotations[0] = Quat.identity();
    for (1..npc.part_count) |i| {
        const pi = parents[i].?;
        out.rotations[i] = quatOf(rigidInverse(sk[pi]).mul(sk[i]));
    }
    return out;
}

test "body model: the posed boxes follow the skeleton of npc.zig (REQ-DEMO-022)" {
    const pose_in = npc.Pose{ .pos = v3(2, 0, -3), .yaw = 0.8, .action = .run, .stride = 0.9 };
    const sk = npc.skeleton(pose_in);
    const p = pose(sk);
    var mats: [npc.part_count]Mat4 = undefined;
    try sw_render.box_model.pose(&parts, p.transform, &p.rotations, &mats);
    // A point of each part in its own frame lands on the same world point.
    for (0..npc.part_count) |i| {
        const local = v3(0.03, -0.1, 0.02);
        const want = vec.xform(sk[i], local);
        const got = vec.xform(mats[i], local + pivots[i]);
        try std.testing.expect(vec.len(want - got) < 0.002);
    }
}
