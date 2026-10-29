//! A small mesher for one voxel model in a dense grid (REQ-DEMO-006).
//!
//! The grid holds a palette index for each voxel (0: empty). The mesher
//! makes one quad for each voxel face that touches an empty voxel. Two
//! modes:
//!
//! - `naive`: one quad for each visible face.
//! - `greedy`: faces in one plane with the same colour and the same
//!   ambient occlusion merge into rectangles.
//!
//! The ambient occlusion of a corner comes from the three voxels next to
//! the corner, in front of the face (0: dark, 3: open). A greedy quad merges
//! only faces whose four corners have one value, so the merge does not
//! change the shading.
//!
//! Each quad has four vertices, two triangles and four edges (the line
//! list of the wireframe). No GPU code: the scene uploads the arrays.

const std = @import("std");

pub const Mode = enum { naive, greedy };

pub const Grid = struct {
    size: [3]u32,
    cells: []u8,

    pub fn init(allocator: std.mem.Allocator, size: [3]u32) !Grid {
        const cells = try allocator.alloc(u8, size[0] * size[1] * size[2]);
        @memset(cells, 0);
        return .{ .size = size, .cells = cells };
    }

    pub fn deinit(self: *Grid, allocator: std.mem.Allocator) void {
        allocator.free(self.cells);
        self.* = undefined;
    }

    fn index(self: Grid, x: u32, y: u32, z: u32) usize {
        return x + self.size[0] * (y + self.size[1] * z);
    }

    /// The voxel at a position. Out of the grid: 0.
    pub fn get(self: Grid, p: [3]i32) u8 {
        for (0..3) |a| {
            if (p[a] < 0 or p[a] >= @as(i32, @intCast(self.size[a]))) return 0;
        }
        return self.cells[self.index(@intCast(p[0]), @intCast(p[1]), @intCast(p[2]))];
    }

    pub fn set(self: *Grid, x: i32, y: i32, z: i32, v: u8) void {
        if (x < 0 or y < 0 or z < 0) return;
        const ux: u32 = @intCast(x);
        const uy: u32 = @intCast(y);
        const uz: u32 = @intCast(z);
        if (ux >= self.size[0] or uy >= self.size[1] or uz >= self.size[2]) return;
        self.cells[self.index(ux, uy, uz)] = v;
    }

    /// Fill the box from `min` to `max` (not included) with `v`.
    pub fn fill(self: *Grid, min: [3]i32, max: [3]i32, v: u8) void {
        var z = min[2];
        while (z < max[2]) : (z += 1) {
            var y = min[1];
            while (y < max[1]) : (y += 1) {
                var x = min[0];
                while (x < max[0]) : (x += 1) self.set(x, y, z, v);
            }
        }
    }

    /// The number of voxels that are not empty.
    pub fn count(self: Grid) usize {
        var n: usize = 0;
        for (self.cells) |c| n += @intFromBool(c != 0);
        return n;
    }
};

/// One vertex: `CowVertex` in the scene WGSL.
pub const Vertex = extern struct {
    pos: [3]f32,
    normal: [3]f32,
    /// 0 (dark) to 1 (open).
    ao: f32,
    /// The palette index.
    color: u32,
};

pub const Options = struct {
    mode: Mode = .greedy,
    /// False: each corner is open (no ambient occlusion).
    ao: bool = true,
    /// The size of one voxel in model units.
    scale: f32 = 1,
    /// The voxel position that becomes the model origin.
    origin: [3]f32 = .{ 0, 0, 0 },
};

pub const Mesh = struct {
    vertices: std.ArrayList(Vertex) = .empty,
    /// Triangle list: 6 indices for each quad.
    triangles: std.ArrayList(u32) = .empty,
    /// Line list: 8 indices for each quad (its four edges).
    lines: std.ArrayList(u32) = .empty,
    quads: u32 = 0,

    pub fn deinit(self: *Mesh, allocator: std.mem.Allocator) void {
        self.vertices.deinit(allocator);
        self.triangles.deinit(allocator);
        self.lines.deinit(allocator);
        self.* = undefined;
    }

    /// Add a quad. `corners` go counter-clockwise, seen from the side that
    /// `normal` points to.
    pub fn addQuad(self: *Mesh, allocator: std.mem.Allocator, corners: [4][3]f32, ao: [4]u2, normal: [3]f32, color: u32) !void {
        const base: u32 = @intCast(self.vertices.items.len);
        for (corners, ao) |c, a| {
            try self.vertices.append(allocator, .{
                .pos = c,
                .normal = normal,
                .ao = @as(f32, @floatFromInt(a)) / 3.0,
                .color = color,
            });
        }
        // Cut the quad along the diagonal with the brighter ends, so the
        // occlusion does not show a seam the wrong way.
        const tri: [6]u32 = if (@as(u32, ao[0]) + ao[2] < @as(u32, ao[1]) + ao[3])
            .{ 1, 2, 3, 1, 3, 0 }
        else
            .{ 0, 1, 2, 0, 2, 3 };
        for (tri) |t| try self.triangles.append(allocator, base + t);
        for ([_]u32{ 0, 1, 1, 2, 2, 3, 3, 0 }) |t| try self.lines.append(allocator, base + t);
        self.quads += 1;
    }
};

fn add(p: [3]i32, q: [3]i32) [3]i32 {
    return .{ p[0] + q[0], p[1] + q[1], p[2] + q[2] };
}

fn unit(axis: usize, s: i32) [3]i32 {
    var v: [3]i32 = .{ 0, 0, 0 };
    v[axis] = s;
    return v;
}

/// The occlusion of one corner from the two side voxels and the corner
/// voxel.
fn cornerAo(s1: bool, s2: bool, c: bool) u2 {
    if (s1 and s2) return 0;
    return @intCast(3 - @as(u32, @intFromBool(s1)) - @intFromBool(s2) - @intFromBool(c));
}

/// The key of one face in a slice mask: 0 for no face. Bits 0-7: the
/// colour. Bits 8-15: the four corner occlusions. Bit 16: a face.
fn faceKey(color: u8, ao: [4]u2) u32 {
    var k: u32 = color;
    for (ao, 0..) |a, i| k |= @as(u32, a) << @intCast(8 + 2 * i);
    return k | (1 << 16);
}

fn keyAo(k: u32) [4]u2 {
    var ao: [4]u2 = undefined;
    for (0..4) |i| ao[i] = @truncate(k >> @intCast(8 + 2 * i));
    return ao;
}

fn uniformAo(k: u32) bool {
    const ao = keyAo(k);
    return ao[0] == ao[1] and ao[1] == ao[2] and ao[2] == ao[3];
}

/// Mesh the grid.
pub fn build(allocator: std.mem.Allocator, grid: Grid, options: Options) !Mesh {
    var mesh: Mesh = .{};
    errdefer mesh.deinit(allocator);
    const max_side = @max(grid.size[0], @max(grid.size[1], grid.size[2]));
    const mask = try allocator.alloc(u32, max_side * max_side);
    defer allocator.free(mask);

    for (0..6) |d| {
        const a = d / 2;
        const sign: i32 = if (d % 2 == 0) 1 else -1;
        const u = (a + 1) % 3;
        const v = (a + 2) % 3;
        const nu = grid.size[u];
        const nv = grid.size[v];
        const n = unit(a, sign);
        var normal: [3]f32 = .{ 0, 0, 0 };
        normal[a] = @floatFromInt(sign);

        for (0..grid.size[a]) |slice| {
            // The mask of the faces in this slice that point along `n`.
            for (0..nv) |j| {
                for (0..nu) |i| {
                    var p: [3]i32 = undefined;
                    p[a] = @intCast(slice);
                    p[u] = @intCast(i);
                    p[v] = @intCast(j);
                    const c = grid.get(p);
                    const front = add(p, n);
                    if (c == 0 or grid.get(front) != 0) {
                        mask[j * nu + i] = 0;
                        continue;
                    }
                    // Corners: 0 (-u,-v), 1 (+u,-v), 2 (+u,+v), 3 (-u,+v).
                    var ao: [4]u2 = @splat(3);
                    if (options.ao) {
                        const du = [4]i32{ -1, 1, 1, -1 };
                        const dv = [4]i32{ -1, -1, 1, 1 };
                        for (0..4) |k| {
                            const su = add(front, unit(u, du[k]));
                            const sv = add(front, unit(v, dv[k]));
                            const sc = add(su, unit(v, dv[k]));
                            ao[k] = cornerAo(grid.get(su) != 0, grid.get(sv) != 0, grid.get(sc) != 0);
                        }
                    }
                    mask[j * nu + i] = faceKey(c, ao);
                }
            }
            // Make the quads of the mask.
            for (0..nv) |j| {
                var i: usize = 0;
                while (i < nu) {
                    const k = mask[j * nu + i];
                    if (k == 0) {
                        i += 1;
                        continue;
                    }
                    var w: usize = 1;
                    var h: usize = 1;
                    if (options.mode == .greedy and uniformAo(k)) {
                        while (i + w < nu and mask[j * nu + i + w] == k) w += 1;
                        grow: while (j + h < nv) {
                            for (0..w) |x| {
                                if (mask[(j + h) * nu + i + x] != k) break :grow;
                            }
                            h += 1;
                        }
                    }
                    for (0..h) |y| @memset(mask[(j + y) * nu + i ..][0..w], 0);
                    try emit(allocator, &mesh, options, .{ a, u, v }, sign, slice, i, j, w, h, k, normal);
                    i += w;
                }
            }
        }
    }
    return mesh;
}

fn emit(
    allocator: std.mem.Allocator,
    mesh: *Mesh,
    options: Options,
    axes: [3]usize,
    sign: i32,
    slice: usize,
    i: usize,
    j: usize,
    w: usize,
    h: usize,
    key: u32,
    normal: [3]f32,
) !void {
    const a, const u, const v = axes;
    const plane: f32 = @floatFromInt(slice + @intFromBool(sign > 0));
    const uv = [4][2]usize{ .{ i, j }, .{ i + w, j }, .{ i + w, j + h }, .{ i, j + h } };
    const ao = keyAo(key);
    var corners: [4][3]f32 = undefined;
    for (uv, 0..) |c, k| {
        var p: [3]f32 = undefined;
        p[a] = plane;
        p[u] = @floatFromInt(c[0]);
        p[v] = @floatFromInt(c[1]);
        for (0..3) |x| corners[k][x] = (p[x] - options.origin[x]) * options.scale;
    }
    // e_u x e_v = e_a: the order 0, 1, 2, 3 faces +a. Reverse it for -a.
    if (sign > 0) {
        try mesh.addQuad(allocator, corners, ao, normal, key & 0xff);
    } else {
        try mesh.addQuad(allocator, .{ corners[0], corners[3], corners[2], corners[1] }, .{ ao[0], ao[3], ao[2], ao[1] }, normal, key & 0xff);
    }
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn meshOf(grid: Grid, mode: Mode, ao: bool) !Mesh {
    return build(testing.allocator, grid, .{ .mode = mode, .ao = ao });
}

test "voxel mesh: one voxel has six quads in each mode (REQ-DEMO-006)" {
    var g = try Grid.init(testing.allocator, .{ 3, 3, 3 });
    defer g.deinit(testing.allocator);
    g.set(1, 1, 1, 5);
    inline for (.{ Mode.naive, Mode.greedy }) |m| {
        var mesh = try meshOf(g, m, true);
        defer mesh.deinit(testing.allocator);
        try testing.expectEqual(@as(u32, 6), mesh.quads);
        try testing.expectEqual(@as(usize, 24), mesh.vertices.items.len);
        try testing.expectEqual(@as(usize, 36), mesh.triangles.items.len);
        try testing.expectEqual(@as(usize, 48), mesh.lines.items.len);
        try testing.expectEqual(@as(u32, 5), mesh.vertices.items[0].color);
    }
}

test "voxel mesh: greedy merges a cube of one colour into six quads (REQ-DEMO-006)" {
    var g = try Grid.init(testing.allocator, .{ 4, 4, 4 });
    defer g.deinit(testing.allocator);
    g.fill(.{ 0, 0, 0 }, .{ 4, 4, 4 }, 1);
    var naive = try meshOf(g, .naive, true);
    defer naive.deinit(testing.allocator);
    var greedy = try meshOf(g, .greedy, true);
    defer greedy.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 96), naive.quads);
    try testing.expectEqual(@as(u32, 6), greedy.quads);
    // Two colours do not merge.
    g.set(0, 0, 0, 2);
    var two = try meshOf(g, .greedy, true);
    defer two.deinit(testing.allocator);
    try testing.expect(two.quads > 6);
}

test "voxel mesh: each triangle faces along the normal of its quad (REQ-DEMO-006)" {
    var g = try Grid.init(testing.allocator, .{ 5, 5, 5 });
    defer g.deinit(testing.allocator);
    g.fill(.{ 1, 1, 1 }, .{ 4, 2, 4 }, 1);
    g.set(2, 2, 2, 3);
    var mesh = try meshOf(g, .greedy, true);
    defer mesh.deinit(testing.allocator);
    const t = mesh.triangles.items;
    var i: usize = 0;
    while (i < t.len) : (i += 3) {
        const p0 = mesh.vertices.items[t[i]].pos;
        const p1 = mesh.vertices.items[t[i + 1]].pos;
        const p2 = mesh.vertices.items[t[i + 2]].pos;
        const e1 = [3]f32{ p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2] };
        const e2 = [3]f32{ p2[0] - p0[0], p2[1] - p0[1], p2[2] - p0[2] };
        const c = [3]f32{ e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0] };
        const nrm = mesh.vertices.items[t[i]].normal;
        try testing.expect(c[0] * nrm[0] + c[1] * nrm[1] + c[2] * nrm[2] > 0);
    }
}

test "voxel mesh: a voxel on a floor darkens the floor corners next to it (REQ-DEMO-006)" {
    var g = try Grid.init(testing.allocator, .{ 3, 2, 3 });
    defer g.deinit(testing.allocator);
    g.fill(.{ 0, 0, 0 }, .{ 3, 1, 3 }, 1);
    g.set(1, 1, 1, 1);
    var lit = try meshOf(g, .naive, true);
    defer lit.deinit(testing.allocator);
    var open = try meshOf(g, .naive, false);
    defer open.deinit(testing.allocator);
    var dark: usize = 0;
    for (lit.vertices.items) |vx| dark += @intFromBool(vx.ao < 1);
    try testing.expect(dark > 0);
    for (open.vertices.items) |vx| try testing.expectEqual(@as(f32, 1), vx.ao);
    // With no occlusion, greedy merges more faces.
    var greedy_lit = try meshOf(g, .greedy, true);
    defer greedy_lit.deinit(testing.allocator);
    var greedy_open = try meshOf(g, .greedy, false);
    defer greedy_open.deinit(testing.allocator);
    try testing.expect(greedy_open.quads < greedy_lit.quads);
}
