//! The demo shader decodes the packed quads of sw_voxel. This test checks
//! that the corner constants of voxel.wgsl match the mesher.
const std = @import("std");
const mesher = @import("sw_voxel").mesher;

fn wgslHexConst(src: []const u8, comptime name: []const u8) !u32 {
    const key = "const " ++ name ++ ": u32 = 0x";
    const start = (std.mem.indexOf(u8, src, key) orelse return error.MissingConstant) + key.len;
    var v: u32 = 0;
    for (src[start..]) |ch| {
        if (ch == '_') continue;
        const d = std.fmt.charToDigit(ch, 16) catch break;
        v = v * 16 + d;
    }
    return v;
}

test "shader: voxel.wgsl corner constants match face_layouts" {
    const src = @embedFile("voxel.wgsl");
    const pos = comptime mesher.cornerBits(.pos);
    const uv = comptime mesher.cornerBits(.uv);
    try std.testing.expectEqual(pos[0], try wgslHexConst(src, "FACE_POS_A"));
    try std.testing.expectEqual(pos[1], try wgslHexConst(src, "FACE_POS_B"));
    try std.testing.expectEqual(uv[0], try wgslHexConst(src, "FACE_UV_A"));
    try std.testing.expectEqual(uv[1], try wgslHexConst(src, "FACE_UV_B"));
}

test "shader: voxel.wgsl model record bit matches the mesher (REQ-VOXEL-001)" {
    const src = @embedFile("voxel.wgsl");
    try std.testing.expectEqual(mesher.MODEL_RECORD_BIT, try wgslHexConst(src, "MODEL_RECORD_BIT"));
}
