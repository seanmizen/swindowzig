//! Occlusion query rules with no GPU code (REQ-GPU-039): the box format of
//! the box test, its 36 corners, and the screen test of a box.
//!
//! `occlusion.zig` draws each box in its own occlusion query. The vertex
//! shader reads the box from a storage buffer and the corner from
//! `box_corners`.
const std = @import("std");

/// One box of the box test, in world coordinates. The GPU layout: two
/// vec4<f32>, 32 bytes. The w values are not used.
pub const Box = extern struct {
    min: [4]f32,
    max: [4]f32,

    pub fn init(min: [3]f32, max: [3]f32) Box {
        return .{ .min = .{ min[0], min[1], min[2], 0 }, .max = .{ max[0], max[1], max[2], 0 } };
    }
};

/// The vertices of one box test draw.
pub const BOX_VERTICES: u32 = 36;

/// The corner of each of the 36 vertices of a box: bit 0 is max x, bit 1 is
/// max y, bit 2 is max z. Two triangles for each face. The box test does
/// not cull faces, so the winding does not matter.
pub const box_corners = [BOX_VERTICES]u32{
    0, 2, 6, 0, 6, 4, // -x
    1, 5, 7, 1, 7, 3, // +x
    0, 4, 5, 0, 5, 1, // -y
    2, 3, 7, 2, 7, 6, // +y
    0, 1, 3, 0, 3, 2, // -z
    4, 6, 7, 4, 7, 5, // +z
};

/// `box_corners` as a WGSL array, for the shader source.
pub const box_corners_wgsl: []const u8 = blk: {
    var text: []const u8 = "array<u32, 36>(";
    for (box_corners, 0..) |c, i| {
        // Each corner is one digit, 0 to 7.
        text = text ++ [_]u8{ '0' + @as(u8, @intCast(c)), 'u' };
        if (i + 1 < box_corners.len) text = text ++ ", ";
    }
    break :blk text ++ ")";
};

/// True when each corner of the box is in front of the camera and in the
/// screen. `view_proj` is column major (`sw_math.Mat4.data`). A box test
/// sees only the pixels of the screen: a box that is not on the screen in
/// full can have a part that the test did not see.
pub fn boxOnScreen(view_proj: [16]f32, min: [3]f32, max: [3]f32) bool {
    for (0..8) |c| {
        const p = [3]f32{
            if (c & 1 != 0) max[0] else min[0],
            if (c & 2 != 0) max[1] else min[1],
            if (c & 4 != 0) max[2] else min[2],
        };
        var clip: [4]f32 = undefined;
        for (0..4) |r| {
            clip[r] = view_proj[r] * p[0] + view_proj[4 + r] * p[1] + view_proj[8 + r] * p[2] + view_proj[12 + r];
        }
        const w = clip[3];
        if (!(w > 0)) return false;
        if (@abs(clip[0]) > w or @abs(clip[1]) > w) return false;
        if (clip[2] < 0 or clip[2] > w) return false;
    }
    return true;
}

test "occlusion: the 36 corners give each face of the box two triangles (REQ-GPU-039)" {
    // Each face (an axis and a side) has 6 vertices, all on that side.
    for (0..6) |f| {
        const axis: u5 = @intCast(f / 2);
        const side: u32 = @intCast(f % 2);
        var seen: [8]bool = @splat(false);
        for (box_corners[f * 6 ..][0..6]) |c| {
            try std.testing.expectEqual(side, (c >> axis) & 1);
            seen[c] = true;
        }
        // The two triangles use the 4 corners of the face.
        var n: usize = 0;
        for (seen) |s| n += @intFromBool(s);
        try std.testing.expectEqual(@as(usize, 4), n);
    }
    try std.testing.expect(std.mem.startsWith(u8, box_corners_wgsl, "array<u32, 36>(0u, 2u, 6u"));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(Box));
}

test "occlusion: a box is on the screen when each corner is in the clip volume (REQ-GPU-039)" {
    // The identity: the clip volume is x and y in [-1, 1], z in [0, 1].
    const id = [16]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    try std.testing.expect(boxOnScreen(id, .{ -0.5, -0.5, 0.1 }, .{ 0.5, 0.5, 0.9 }));
    // A corner out at the side, behind the camera, or past the far plane.
    try std.testing.expect(!boxOnScreen(id, .{ -0.5, -0.5, 0.1 }, .{ 1.5, 0.5, 0.9 }));
    try std.testing.expect(!boxOnScreen(id, .{ -0.5, -0.5, -0.1 }, .{ 0.5, 0.5, 0.9 }));
    try std.testing.expect(!boxOnScreen(id, .{ -0.5, -0.5, 0.1 }, .{ 0.5, 0.5, 1.5 }));
    // A w of 0 is not in front of the camera.
    var no_w = id;
    no_w[15] = 0;
    try std.testing.expect(!boxOnScreen(no_w, .{ 0, 0, 0 }, .{ 0, 0, 0 }));
}
