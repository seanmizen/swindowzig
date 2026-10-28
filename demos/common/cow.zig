//! The cow: an original voxel model, and two meshers with ambient
//! occlusion.
//!
//! The cow is a grid of voxels. Each voxel has a colour index: white or
//! black hide (the patches come from a few fixed spheres), a pink nose and
//! udder, dark hooves, cream horns and dark eyes. Its head looks to +X.
//!
//! - `meshNaive` gives one quad for each visible voxel face.
//! - `meshGreedy` merges the visible faces of each slice into rectangles
//!   with the same colour and the same AO, so it gives far fewer quads.
//!
//! Both meshers give the AO of each quad corner from the three voxels
//! next to the corner, outside the face. This file has no GPU code.
const std = @import("std");

pub const size_x = 28;
pub const size_y = 20;
pub const size_z = 12;
/// The edge of one voxel, in metres.
pub const voxel: f32 = 0.1;

pub const Color = enum(u8) { empty, white, black, pink, hoof, horn, eye };
pub const color_count = 7;

pub const Grid = [size_x][size_y][size_z]Color;

/// A palette gives the linear RGB of each colour index.
pub const Palette = [color_count][3]f32;

pub const palettes = [_]Palette{
    // The black and white hide.
    .{ .{ 0, 0, 0 }, .{ 0.62, 0.62, 0.60 }, .{ 0.035, 0.035, 0.04 }, .{ 0.85, 0.42, 0.45 }, .{ 0.08, 0.07, 0.06 }, .{ 0.80, 0.74, 0.55 }, .{ 0.02, 0.02, 0.02 } },
    // A brown and cream hide.
    .{ .{ 0, 0, 0 }, .{ 0.80, 0.68, 0.48 }, .{ 0.25, 0.10, 0.04 }, .{ 0.80, 0.45, 0.38 }, .{ 0.10, 0.06, 0.03 }, .{ 0.90, 0.88, 0.80 }, .{ 0.02, 0.02, 0.02 } },
    // A blue and orange test hide.
    .{ .{ 0, 0, 0 }, .{ 0.15, 0.35, 0.85 }, .{ 0.90, 0.45, 0.05 }, .{ 0.95, 0.90, 0.20 }, .{ 0.05, 0.05, 0.10 }, .{ 0.95, 0.95, 0.95 }, .{ 0.0, 0.0, 0.0 } },
};
pub const palette_names = [_][]const u8{ "black and white", "brown and cream", "blue and orange" };

fn inBox(x: i32, y: i32, z: i32, lo: [3]i32, hi: [3]i32) bool {
    return x >= lo[0] and x <= hi[0] and y >= lo[1] and y <= hi[1] and z >= lo[2] and z <= hi[2];
}

/// The black patches: voxels in one of these spheres (centre, radius
/// squared) have black hide.
const patches = [_]struct { [3]i32, i32 }{
    .{ .{ 7, 12, 0 }, 10 },
    .{ .{ 15, 9, 12 }, 12 },
    .{ .{ 18, 14, 3 }, 9 },
    .{ .{ 11, 8, 6 }, 6 },
    .{ .{ 5, 9, 11 }, 7 },
    .{ .{ 25, 16, 2 }, 5 },
    .{ .{ 20, 7, 0 }, 6 },
    .{ .{ 6, 3, 9 }, 4 },
};

fn hide(x: i32, y: i32, z: i32) Color {
    for (patches) |p| {
        const dx = x - p[0][0];
        const dy = y - p[0][1];
        const dz = z - p[0][2];
        if (dx * dx + dy * dy + dz * dz <= p[1]) return .black;
    }
    return .white;
}

/// The colour of the voxel at (x, y, z).
pub fn voxelAt(x: i32, y: i32, z: i32) Color {
    // The legs, with the hooves at the bottom.
    for ([_]i32{ 5, 18 }) |lx| {
        for ([_]i32{ 2, 8 }) |lz| {
            if (inBox(x, y, z, .{ lx, 0, lz }, .{ lx + 2, 6, lz + 1 })) return if (y <= 1) .hoof else hide(x, y, z);
        }
    }
    // The udder and the teats.
    if (inBox(x, y, z, .{ 9, 5, 4 }, .{ 12, 5, 7 })) return .pink;
    if (y == 4 and (x == 9 or x == 12) and (z == 4 or z == 7)) return .pink;
    // The body, with chamfered long edges.
    if (inBox(x, y, z, .{ 3, 6, 1 }, .{ 22, 14, 10 })) {
        const edge_y = y == 6 or y == 14;
        const edge_z = z == 1 or z == 10;
        if (edge_y and edge_z) return .empty;
        return hide(x, y, z);
    }
    // The tail and its dark tuft.
    if (x == 2 and z >= 5 and z <= 6) {
        if (y >= 8 and y <= 13) return .white;
        if (y >= 6 and y <= 7) return .black;
    }
    // The head.
    if (inBox(x, y, z, .{ 23, 10, 3 }, .{ 26, 17, 8 })) {
        if (x == 26 and y == 15 and (z == 3 or z == 8)) return .eye;
        if (x == 26 and y >= 16 and (z == 3 or z == 8)) return .empty;
        return hide(x, y, z);
    }
    // The nose, with two dark nostrils.
    if (inBox(x, y, z, .{ 27, 10, 3 }, .{ 27, 13, 8 })) {
        if (y == 12 and (z == 4 or z == 7)) return .eye;
        return .pink;
    }
    // The ears and the horns.
    if (y == 16 and x >= 23 and x <= 24 and (z == 1 or z == 2 or z == 9 or z == 10)) return hide(x, y, z);
    if (x == 24 and (z == 3 or z == 8) and y >= 18 and y <= 19) return .horn;
    return .empty;
}

/// Make the voxel grid of the cow.
pub fn build() Grid {
    var g: Grid = undefined;
    for (0..size_x) |x| for (0..size_y) |y| for (0..size_z) |z| {
        g[x][y][z] = voxelAt(@intCast(x), @intCast(y), @intCast(z));
    };
    return g;
}

fn solid(g: *const Grid, p: [3]i32) bool {
    if (p[0] < 0 or p[1] < 0 or p[2] < 0) return false;
    if (p[0] >= size_x or p[1] >= size_y or p[2] >= size_z) return false;
    return g[@intCast(p[0])][@intCast(p[1])][@intCast(p[2])] != .empty;
}

fn colorOf(g: *const Grid, p: [3]i32) Color {
    if (!solid(g, p)) return .empty;
    return g[@intCast(p[0])][@intCast(p[1])][@intCast(p[2])];
}

/// One quad of the mesh, in voxel units. The corners are counter-clockwise
/// from the front.
pub const Quad = struct {
    corners: [4][3]f32,
    normal: [3]f32,
    color: Color,
    /// The AO level of each corner: 0 (most occluded) to 3 (open).
    ao: [4]u2,
};

const dims = [3]i32{ size_x, size_y, size_z };

/// The axes of a face direction `d` (0 to 5): the normal axis, its sign,
/// and the two axes of the face plane.
fn faceAxes(d: usize) struct { axis: usize, sign: i32, u: usize, v: usize } {
    const axis = d / 2;
    return .{ .axis = axis, .sign = if (d % 2 == 0) 1 else -1, .u = (axis + 1) % 3, .v = (axis + 2) % 3 };
}

/// The corner signs (du, dv) in quad order.
const corner_signs = [4][2]i32{ .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 }, .{ -1, 1 } };

/// The AO of the four corners of the face of voxel `p` in direction `d`.
fn faceAo(g: *const Grid, p: [3]i32, d: usize) [4]u2 {
    const f = faceAxes(d);
    var out: [4]u2 = undefined;
    for (corner_signs, 0..) |cs, i| {
        var a = p;
        a[f.axis] += f.sign;
        var s1 = a;
        s1[f.u] += cs[0];
        var s2 = a;
        s2[f.v] += cs[1];
        var c = a;
        c[f.u] += cs[0];
        c[f.v] += cs[1];
        const b1 = solid(g, s1);
        const b2 = solid(g, s2);
        out[i] = if (b1 and b2) 0 else @intCast(3 - @as(u32, @intFromBool(b1)) - @intFromBool(b2) - @intFromBool(solid(g, c)));
    }
    return out;
}

/// The quad of a rectangle of faces in direction `d`: the slice `slice`
/// along the normal axis, from (ua, va) to (ub, vb) in voxel units.
fn makeQuad(d: usize, slice: i32, ua: i32, va: i32, ub: i32, vb: i32, color: Color, ao: [4]u2) Quad {
    const f = faceAxes(d);
    const plane: f32 = @floatFromInt(if (f.sign > 0) slice + 1 else slice);
    const uv = [4][2]i32{ .{ ua, va }, .{ ub, va }, .{ ub, vb }, .{ ua, vb } };
    var q: Quad = .{ .corners = undefined, .normal = .{ 0, 0, 0 }, .color = color, .ao = ao };
    q.normal[f.axis] = @floatFromInt(f.sign);
    for (0..4) |i| {
        // A negative face goes the other way round, so it faces out.
        const k = if (f.sign > 0) i else 3 - i;
        var c: [3]f32 = undefined;
        c[f.axis] = plane;
        c[f.u] = @floatFromInt(uv[k][0]);
        c[f.v] = @floatFromInt(uv[k][1]);
        q.corners[i] = c;
    }
    if (f.sign < 0) q.ao = .{ ao[3], ao[2], ao[1], ao[0] };
    return q;
}

/// One quad for each voxel face that has no solid voxel in front of it.
/// With `ao` false, each corner has the AO level 3.
pub fn meshNaive(allocator: std.mem.Allocator, g: *const Grid, ao: bool) !std.ArrayList(Quad) {
    var out: std.ArrayList(Quad) = .empty;
    errdefer out.deinit(allocator);
    for (0..size_x) |x| for (0..size_y) |y| for (0..size_z) |z| {
        const p: [3]i32 = .{ @intCast(x), @intCast(y), @intCast(z) };
        const c = colorOf(g, p);
        if (c == .empty) continue;
        for (0..6) |d| {
            const f = faceAxes(d);
            var n = p;
            n[f.axis] += f.sign;
            if (solid(g, n)) continue;
            const a = if (ao) faceAo(g, p, d) else [4]u2{ 3, 3, 3, 3 };
            try out.append(allocator, makeQuad(d, p[f.axis], p[f.u], p[f.v], p[f.u] + 1, p[f.v] + 1, c, a));
        }
    };
    return out;
}

/// The visible faces of each slice merged into rectangles of one colour
/// and one AO (the greedy mesher). With `ao` false, only the colour must
/// be the same, so the rectangles are larger.
pub fn meshGreedy(allocator: std.mem.Allocator, g: *const Grid, ao: bool) !std.ArrayList(Quad) {
    var out: std.ArrayList(Quad) = .empty;
    errdefer out.deinit(allocator);
    const max_dim = 32;
    for (0..6) |d| {
        const f = faceAxes(d);
        const nu: usize = @intCast(dims[f.u]);
        const nv: usize = @intCast(dims[f.v]);
        var slice: i32 = 0;
        while (slice < dims[f.axis]) : (slice += 1) {
            // The key of each face in the slice: 0 for no face, else the
            // colour and the AO of the four corners.
            var mask: [max_dim][max_dim]u32 = @splat(@splat(0));
            for (0..nu) |u| for (0..nv) |v| {
                var p: [3]i32 = undefined;
                p[f.axis] = slice;
                p[f.u] = @intCast(u);
                p[f.v] = @intCast(v);
                const c = colorOf(g, p);
                if (c == .empty) continue;
                var n = p;
                n[f.axis] += f.sign;
                if (solid(g, n)) continue;
                const a = if (ao) faceAo(g, p, d) else [4]u2{ 3, 3, 3, 3 };
                mask[u][v] = 1 + @as(u32, @backingInt(c)) | @as(u32, a[0]) << 8 | @as(u32, a[1]) << 10 | @as(u32, a[2]) << 12 | @as(u32, a[3]) << 14;
            };
            // Grow each rectangle along u, then along v.
            for (0..nv) |v| {
                var u: usize = 0;
                while (u < nu) {
                    const key = mask[u][v];
                    if (key == 0) {
                        u += 1;
                        continue;
                    }
                    var w: usize = 1;
                    while (u + w < nu and mask[u + w][v] == key) w += 1;
                    var h: usize = 1;
                    grow: while (v + h < nv) : (h += 1) {
                        for (0..w) |k| if (mask[u + k][v + h] != key) break :grow;
                    }
                    for (0..w) |k| for (0..h) |j| {
                        mask[u + k][v + j] = 0;
                    };
                    const c: Color = @fromBackingInt(@intCast(@as(u8, @intCast((key & 0xFF) - 1))));
                    const a: [4]u2 = .{ @intCast((key >> 8) & 3), @intCast((key >> 10) & 3), @intCast((key >> 12) & 3), @intCast((key >> 14) & 3) };
                    try out.append(allocator, makeQuad(d, slice, @intCast(u), @intCast(v), @intCast(u + w), @intCast(v + h), c, a));
                    u += w;
                }
            }
        }
    }
    return out;
}

/// The vertex AO factor of an AO level.
pub fn aoFactor(level: u2) f32 {
    return switch (level) {
        0 => 0.45,
        1 => 0.65,
        2 => 0.82,
        3 => 1.0,
    };
}

/// The point in metres of a corner in voxel units: the cow stands on y = 0,
/// with its middle on the Y axis.
pub fn toMetres(c: [3]f32) [3]f32 {
    return .{
        (c[0] - size_x / 2.0) * voxel,
        c[1] * voxel,
        (c[2] - size_z / 2.0) * voxel,
    };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn area(q: Quad) f32 {
    var a: f32 = 1;
    for (0..3) |i| {
        var lo: f32 = 1e9;
        var hi: f32 = -1e9;
        for (q.corners) |c| {
            lo = @min(lo, c[i]);
            hi = @max(hi, c[i]);
        }
        if (hi > lo) a *= hi - lo;
    }
    return a;
}

test "cow: the greedy mesh covers the same faces as the naive mesh with fewer quads" {
    const g = build();
    for ([_]bool{ false, true }) |ao| {
        var naive = try meshNaive(testing.allocator, &g, ao);
        defer naive.deinit(testing.allocator);
        var greedy = try meshGreedy(testing.allocator, &g, ao);
        defer greedy.deinit(testing.allocator);
        var naive_area: f32 = 0;
        for (naive.items) |q| naive_area += area(q);
        var greedy_area: f32 = 0;
        for (greedy.items) |q| greedy_area += area(q);
        try testing.expectApproxEqAbs(naive_area, greedy_area, 1e-3);
        try testing.expect(naive.items.len > 1000);
        try testing.expect(greedy.items.len * 2 < naive.items.len);
    }
}

test "cow: each quad faces out, and a face in a corner has AO" {
    const g = build();
    var naive = try meshNaive(testing.allocator, &g, true);
    defer naive.deinit(testing.allocator);
    var occluded: usize = 0;
    for (naive.items) |q| {
        const a = q.corners[0];
        const b = q.corners[1];
        const c = q.corners[2];
        const e1: [3]f32 = .{ b[0] - a[0], b[1] - a[1], b[2] - a[2] };
        const e2: [3]f32 = .{ c[0] - a[0], c[1] - a[1], c[2] - a[2] };
        const n: [3]f32 = .{ e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0] };
        try testing.expect(n[0] * q.normal[0] + n[1] * q.normal[1] + n[2] * q.normal[2] > 0);
        for (q.ao) |l| {
            if (l < 3) occluded += 1;
        }
    }
    try testing.expect(occluded > 0);
}

test "cow: the model has legs, a head and two horns" {
    try testing.expectEqual(Color.hoof, voxelAt(5, 0, 2));
    try testing.expectEqual(Color.horn, voxelAt(24, 19, 3));
    try testing.expectEqual(Color.pink, voxelAt(27, 10, 5));
    try testing.expectEqual(Color.empty, voxelAt(0, 0, 0));
}
