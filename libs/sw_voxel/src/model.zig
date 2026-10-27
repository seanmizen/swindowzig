//! Baked block models: the quads of a block that is not a full cube (REQ-VOXEL-001).
//!
//! The game bakes each model before it gives it to sw_voxel: it reads its
//! own model files, applies the rotation and resolves the texture
//! coordinates. sw_voxel knows no model file format. The content module
//! gives the model of each block ID (`content.zig`, `model`), and
//! `models.zig` makes the tables of the mesher and the GPU from it.
//!
//! A block with no model is a full cube, and the greedy mesher meshes it.
//! The model mesher (`mesher.zig`) makes one quad record for each visible
//! quad of a model block.
const std = @import("std");

/// The six directions of a block face: +X, -X, +Y, -Y, +Z, -Z. The order is
/// the face number of the packed quads of the mesher.
pub const Face = enum { px, nx, py, ny, pz, nz };

/// The cell offset of the neighbour in each face direction.
pub const face_offsets = [6][3]i32{
    .{ 1, 0, 0 },
    .{ -1, 0, 0 },
    .{ 0, 1, 0 },
    .{ 0, -1, 0 },
    .{ 0, 0, 1 },
    .{ 0, 0, -1 },
};

/// One quad of a baked model.
pub const BakedQuad = struct {
    /// The 4 corners in block units. The cell of the block is [0, 1] on
    /// each axis. Seen from the front, the corners go counter-clockwise.
    /// The back of the quad is not drawn: a quad that must show from both
    /// sides is two quads.
    pos: [4][3]f32,
    /// The texture coordinates of each corner. The engine gives them to the
    /// shader with no change (for example, atlas coordinates from
    /// `sw_render.Atlas.uv`).
    uv: [4][2]f32,
    /// The light direction. The mesher reads the light of the neighbour
    /// cell in this direction.
    face: Face,
    /// When set, the mesher does not draw the quad if the neighbour cell in
    /// this direction is a full cube.
    cull_face: ?Face = null,
    /// The tint index for the shader, or -1 for no tint.
    tint_index: i8 = -1,
    /// True: the shader applies the directional shade. False: the quad has
    /// the same brightness from all directions.
    shade: bool = true,
};

/// The quads of one block.
pub const BakedModel = struct {
    quads: []const BakedQuad,
};

/// The texture coordinates and the options of one face of a `box`.
pub const BoxFace = struct {
    /// u0, v0, u1, v1. Null: (0, 0) to the size of the face in block units.
    uv: ?[4]f32 = null,
    tint_index: i8 = -1,
    shade: bool = true,
};

/// The geometry of each face of a box: the normal axis, the in-plane axes
/// i and j, and for each corner the 0/1 step along i and j for the position
/// and for the texture coordinates. The corner order and the winding are
/// the same as the greedy quads of the mesher (`face_layouts` in
/// `mesher.zig`, and a test there compares them).
const BoxLayout = struct {
    normal_axis: u2,
    i_axis: u2,
    j_axis: u2,
    positive: bool,
    pos: [4][2]u1,
    uv: [4][2]u1,
};

const box_layouts = [6]BoxLayout{
    .{ .normal_axis = 0, .i_axis = 2, .j_axis = 1, .positive = true, .pos = .{ .{ 0, 0 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 } }, .uv = .{ .{ 0, 0 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 } } },
    .{ .normal_axis = 0, .i_axis = 2, .j_axis = 1, .positive = false, .pos = .{ .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 }, .{ 0, 0 } }, .uv = .{ .{ 0, 0 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 } } },
    .{ .normal_axis = 1, .i_axis = 0, .j_axis = 2, .positive = true, .pos = .{ .{ 0, 0 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 } }, .uv = .{ .{ 0, 0 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 } } },
    .{ .normal_axis = 1, .i_axis = 0, .j_axis = 2, .positive = false, .pos = .{ .{ 0, 1 }, .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 } }, .uv = .{ .{ 0, 0 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 } } },
    .{ .normal_axis = 2, .i_axis = 0, .j_axis = 1, .positive = true, .pos = .{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } }, .uv = .{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } } },
    .{ .normal_axis = 2, .i_axis = 0, .j_axis = 1, .positive = false, .pos = .{ .{ 1, 0 }, .{ 0, 0 }, .{ 0, 1 }, .{ 1, 1 } }, .uv = .{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } } },
};

fn countFaces(faces: [6]?BoxFace) usize {
    var n: usize = 0;
    for (faces) |f| n += @intFromBool(f != null);
    return n;
}

/// The quads of an axis-aligned box from `from` to `to` (block units), one
/// quad for each face that is not null in `faces` (order: px, nx, py, ny,
/// pz, nz). A face on the side of the cell gets that side as its cull face.
/// A face inside the cell has no cull face.
pub fn box(comptime from: [3]f32, comptime to: [3]f32, comptime faces: [6]?BoxFace) [countFaces(faces)]BakedQuad {
    var out: [countFaces(faces)]BakedQuad = undefined;
    var n: usize = 0;
    for (faces, 0..) |maybe, f| {
        const opts = maybe orelse continue;
        const l = box_layouts[f];
        const face: Face = @fromBackingInt(@as(u3, @intCast(f)));
        const plane = if (l.positive) to[l.normal_axis] else from[l.normal_axis];
        const on_side = if (l.positive) plane == 1.0 else plane == 0.0;
        const rect: [4]f32 = opts.uv orelse .{ 0, 0, to[l.i_axis] - from[l.i_axis], to[l.j_axis] - from[l.j_axis] };
        var q: BakedQuad = .{
            .pos = undefined,
            .uv = undefined,
            .face = face,
            .cull_face = if (on_side) face else null,
            .tint_index = opts.tint_index,
            .shade = opts.shade,
        };
        for (0..4) |c| {
            var p: [3]f32 = undefined;
            p[l.normal_axis] = plane;
            p[l.i_axis] = if (l.pos[c][0] == 1) to[l.i_axis] else from[l.i_axis];
            p[l.j_axis] = if (l.pos[c][1] == 1) to[l.j_axis] else from[l.j_axis];
            q.pos[c] = p;
            q.uv[c] = .{
                if (l.uv[c][0] == 1) rect[2] else rect[0],
                if (l.uv[c][1] == 1) rect[3] else rect[1],
            };
        }
        out[n] = q;
        n += 1;
    }
    return out;
}

/// Turn a quad about the vertical line through the cell centre by
/// `quarter_turns` × 90 degrees. One turn moves +X to +Z, +Z to -X, -X to
/// -Z and -Z to +X. The texture coordinates do not change.
pub fn rotateY(q: BakedQuad, quarter_turns: u2) BakedQuad {
    var out = q;
    for (0..quarter_turns) |_| {
        for (&out.pos) |*p| {
            const x = p[0];
            p[0] = 1.0 - p[2];
            p[2] = x;
        }
        out.face = turnFace(out.face);
        if (out.cull_face) |cf| out.cull_face = turnFace(cf);
    }
    return out;
}

fn turnFace(f: Face) Face {
    return switch (f) {
        .px => .pz,
        .pz => .nx,
        .nx => .nz,
        .nz => .px,
        .py, .ny => f,
    };
}

// ---------------------------------------------------------------------------
// The GPU format of a baked quad
// ---------------------------------------------------------------------------
//
// The game uploads the quads of all models once, as a storage buffer of
// GpuQuad (`models.gpu_table`). A model quad record of a chunk mesh holds an
// index into this table (`mesher.zig`). A GpuQuad is 6 vec4<u32>, 96 bytes:
//
//   vec4 0-3: corner 0-3. x, y, z are the f32 bits of the position. w of
//             corner 0 is the info word: face (bits 0-2), shade (bit 3),
//             tint index (bits 8-15, 0xFF = no tint). The other w are 0.
//   vec4 4:   u0, v0, u1, v1 (f32 bits)
//   vec4 5:   u2, v2, u3, v3 (f32 bits)

pub const GpuQuad = extern struct {
    words: [24]u32,
};

/// The info word of a GpuQuad: face, shade and tint index.
pub fn infoWord(q: BakedQuad) u32 {
    const tint: u32 = if (q.tint_index < 0) 0xFF else @intCast(q.tint_index);
    return @as(u32, @backingInt(q.face)) | (@as(u32, @intFromBool(q.shade)) << 3) | (tint << 8);
}

pub fn encodeGpu(q: BakedQuad) GpuQuad {
    var g: GpuQuad = .{ .words = @splat(0) };
    for (0..4) |c| {
        for (0..3) |a| g.words[c * 4 + a] = @bitCast(q.pos[c][a]);
        g.words[16 + c * 2] = @bitCast(q.uv[c][0]);
        g.words[16 + c * 2 + 1] = @bitCast(q.uv[c][1]);
    }
    g.words[3] = infoWord(q);
    return g;
}

test "a box face on the side of the cell culls on that side" {
    const quads = box(.{ 0, 0, 0 }, .{ 1, 0.5, 1 }, @splat(BoxFace{}));
    try std.testing.expectEqual(@as(usize, 6), quads.len);
    for (quads) |q| {
        if (q.face == .py) {
            // The top of a half box is inside the cell.
            try std.testing.expectEqual(@as(?Face, null), q.cull_face);
            for (q.pos) |p| try std.testing.expectEqual(@as(f32, 0.5), p[1]);
        } else {
            try std.testing.expectEqual(@as(?Face, q.face), q.cull_face);
        }
    }
    // A side face gets the default texture coordinates: 1 wide, 0.5 high.
    const side = quads[0];
    try std.testing.expectEqual(Face.px, side.face);
    var max_uv = [2]f32{ 0, 0 };
    for (side.uv) |uv| max_uv = .{ @max(max_uv[0], uv[0]), @max(max_uv[1], uv[1]) };
    try std.testing.expectEqual([2]f32{ 1, 0.5 }, max_uv);
}

test "box skips null faces and keeps the given texture rectangle" {
    const quads = box(.{ 0.25, 0, 0.25 }, .{ 0.75, 1, 0.75 }, .{ null, null, .{ .uv = .{ 0.5, 0.5, 0.75, 0.75 }, .tint_index = 2, .shade = false }, null, null, null });
    try std.testing.expectEqual(@as(usize, 1), quads.len);
    const top = quads[0];
    try std.testing.expectEqual(Face.py, top.face);
    try std.testing.expectEqual(@as(?Face, .py), top.cull_face);
    try std.testing.expectEqual(@as(i8, 2), top.tint_index);
    try std.testing.expect(!top.shade);
    for (top.uv) |uv| {
        try std.testing.expect(uv[0] == 0.5 or uv[0] == 0.75);
        try std.testing.expect(uv[1] == 0.5 or uv[1] == 0.75);
    }
}

test "rotateY turns the position, the face and the cull face" {
    const quads = box(.{ 0, 0, 0 }, .{ 0.5, 1, 1 }, .{ .{}, null, null, null, null, null });
    // The +X face of a box on the -X half of the cell is at x = 0.5.
    const q = quads[0];
    try std.testing.expectEqual(@as(?Face, null), q.cull_face);
    const r = rotateY(q, 1);
    try std.testing.expectEqual(Face.pz, r.face);
    for (r.pos) |p| try std.testing.expectEqual(@as(f32, 0.5), p[2]);
    const full = box(.{ 0, 0, 0 }, .{ 1, 1, 1 }, .{ null, null, null, null, null, .{} })[0];
    try std.testing.expectEqual(@as(?Face, .px), rotateY(full, 1).cull_face);
    try std.testing.expectEqual(@as(?Face, .nx), rotateY(full, 3).cull_face);
    // Four turns give the start quad.
    try std.testing.expectEqual(full, rotateY(rotateY(full, 2), 2));
}

test "encodeGpu keeps the bits of each field" {
    const q = box(.{ 0, 0, 0 }, .{ 1, 0.5, 1 }, .{ null, null, .{ .tint_index = 3, .shade = false }, null, null, null })[0];
    const g = encodeGpu(q);
    try std.testing.expectEqual(@as(u32, 2 | (3 << 8)), g.words[3]);
    for (0..4) |c| {
        try std.testing.expectEqual(q.pos[c][1], @as(f32, @bitCast(g.words[c * 4 + 1])));
        try std.testing.expectEqual(q.uv[c][0], @as(f32, @bitCast(g.words[16 + c * 2])));
    }
    const plain = box(.{ 0, 0, 0 }, .{ 1, 1, 1 }, .{ .{}, null, null, null, null, null })[0];
    try std.testing.expectEqual(@as(u32, 0 | (1 << 3) | (0xFF << 8)), encodeGpu(plain).words[3]);
}
