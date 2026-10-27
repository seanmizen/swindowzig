//! Collision against the voxel world: the collision boxes of each block
//! ID, a box that moves one axis at a time with a step-up
//! (REQ-VOXEL-006), and a voxel ray cast (REQ-VOXEL-007).
//!
//! The content module gives the collision boxes of each block ID
//! (`content.zig`, `collision`). With no declaration, air has no box and
//! every other block is a full cube. A box is in the cell of its block:
//! [0, 1] on each axis. The collision is generic. It knows no game and no
//! game physics. The game gives the velocity, the gravity and the size of
//! its boxes.
//!
//! The functions read the world through `blocks`: a value with the method
//! `getBlock(x: i32, y: i32, z: i32) Block`, in world coordinates. A
//! `chunk.BlockGetter`, a `*const world.World` and a test grid all work.
const std = @import("std");
const math = @import("sw_math");
const content = @import("content.zig");
const model = @import("model.zig");
const chunk = @import("chunk.zig");

const Vec3 = math.Vec3;
const Aabb = math.Aabb;
const Ray = math.Ray;
const Block = content.Block;

/// One collision box of a block, in block units. The cell of the block is
/// [0, 1] on each axis, and the box must be in the cell.
pub const CellBox = struct {
    min: [3]f32,
    max: [3]f32,

    /// The box in world coordinates, for the block in cell (x, y, z).
    pub fn aabb(self: CellBox, x: i32, y: i32, z: i32) Aabb {
        const o = Vec3.init(@floatFromInt(x), @floatFromInt(y), @floatFromInt(z));
        return .{
            .min = o.add(Vec3.init(self.min[0], self.min[1], self.min[2])),
            .max = o.add(Vec3.init(self.max[0], self.max[1], self.max[2])),
        };
    }
};

/// The box of a full cube.
pub const full_cube = [1]CellBox{.{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 1 } }};

const block_values = @typeInfo(Block).@"enum".field_values;

const box_table: [256][]const CellBox = blk: {
    @setEvalBranchQuota(100_000);
    var t: [256][]const CellBox = @splat(&.{});
    for (block_values) |v| {
        const block: Block = @fromBackingInt(v);
        const list: []const CellBox = content.collision(block) orelse
            if (block == .air) &.{} else &full_cube;
        if (block == .air and list.len != 0)
            @compileError("sw_voxel_content.collision(.air) must give no box");
        for (list) |b| for (0..3) |i| {
            if (!(b.min[i] >= 0 and b.min[i] <= b.max[i] and b.max[i] <= 1))
                @compileError("sw_voxel_content.collision: each box must be in the cell, with min <= max");
        };
        t[v] = list;
    }
    break :blk t;
};

/// The collision boxes of `block`, in block units. Air gives none.
pub fn boxes(block: Block) []const CellBox {
    return box_table[@backingInt(block)];
}

/// True when `block` has one collision box or more.
pub fn isSolid(block: Block) bool {
    return boxes(block).len > 0;
}

// ---------------------------------------------------------------------------
// Moving boxes (REQ-VOXEL-006)
// ---------------------------------------------------------------------------

/// The settings of one move.
pub const MoveOptions = struct {
    /// The highest step that the box climbs, in blocks. 0 gives no
    /// step-up.
    step_height: f32 = 0,
    /// True when the box stands on a block at the start of the move. The
    /// box can climb a step only when it stands on a block, or when a
    /// block stops its fall in this move.
    on_ground: bool = false,
};

/// The result of a move.
pub const MoveResult = struct {
    /// The movement after the collision. Add it to the position.
    delta: Vec3,
    /// True on each axis where a block stopped the movement.
    blocked_x: bool = false,
    blocked_y: bool = false,
    blocked_z: bool = false,
    /// True when a block stopped a downward movement. The box stands on
    /// that block at the end of the move.
    on_ground: bool = false,
    /// True when the box climbed a step.
    stepped: bool = false,
};

/// Move `box` by `delta` through the world, and stop it at the collision
/// boxes of the blocks. The box moves one axis at a time: y first, then
/// the horizontal axis with the larger movement, then the other. Each axis
/// reads all the cells on its path, so a high speed does not go through a
/// thin wall. A box that touches a block on a face is not in it.
///
/// With `options.step_height` > 0, a box that a block stops on x or z
/// tries the move again from `step_height` higher, then goes down onto
/// the step. The result with the longer horizontal movement wins.
pub fn moveBox(blocks: anytype, box: Aabb, delta: Vec3, options: MoveOptions) MoveResult {
    const start = Box.fromAabb(box);
    const d = [3]f32{ delta.x, delta.y, delta.z };
    const plain = moveAxes(blocks, start, d);
    if (options.step_height <= 0 or d[1] > 0) return plain;
    if (!plain.blocked_x and !plain.blocked_z) return plain;
    if (!options.on_ground and !plain.on_ground) return plain;

    // Go up, move on x and z at that height, then go down onto the step.
    const up = clipAxis(blocks, start, 1, options.step_height);
    var b = start.offset(1, up);
    const h = moveHorizontal(blocks, &b, d);
    const down_goal = -up + @min(d[1], 0);
    const down = clipAxis(blocks, b, 1, down_goal);
    const step_xz = h[0] * h[0] + h[2] * h[2];
    const plain_xz = plain.delta.x * plain.delta.x + plain.delta.z * plain.delta.z;
    if (step_xz <= plain_xz) return plain;
    return .{
        .delta = Vec3.init(h[0], up + down, h[2]),
        .blocked_x = h[0] != d[0],
        .blocked_y = down != down_goal,
        .blocked_z = h[2] != d[2],
        .on_ground = down != down_goal,
        .stepped = true,
    };
}

/// True when `box` is in a collision box of a block, by more than the
/// tolerance on each axis. A box that only touches a block is not in it.
pub fn collides(blocks: anytype, box: Aabb) bool {
    const b = Box.fromAabb(box);
    const lo = cellRange(b.min);
    const hi = cellRange(b.max);
    var x = lo[0];
    while (x <= hi[0]) : (x += 1) {
        var y = lo[1];
        while (y <= hi[1]) : (y += 1) {
            var z = lo[2];
            while (z <= hi[2]) : (z += 1) {
                for (boxes(blocks.getBlock(x, y, z))) |cb| {
                    const w = Box.fromCell(cb, x, y, z);
                    if (overlaps(b, w, 0) and overlaps(b, w, 1) and overlaps(b, w, 2)) return true;
                }
            }
        }
    }
    return false;
}

/// A box as arrays, so that the code can index the axes.
const Box = struct {
    min: [3]f32,
    max: [3]f32,

    fn fromAabb(a: Aabb) Box {
        return .{ .min = .{ a.min.x, a.min.y, a.min.z }, .max = .{ a.max.x, a.max.y, a.max.z } };
    }

    fn fromCell(cb: CellBox, x: i32, y: i32, z: i32) Box {
        const o = [3]f32{ @floatFromInt(x), @floatFromInt(y), @floatFromInt(z) };
        var r: Box = undefined;
        for (0..3) |i| {
            r.min[i] = o[i] + cb.min[i];
            r.max[i] = o[i] + cb.max[i];
        }
        return r;
    }

    fn offset(self: Box, axis: usize, amount: f32) Box {
        var r = self;
        r.min[axis] += amount;
        r.max[axis] += amount;
        return r;
    }
};

/// The smallest distance that counts as a gap or as an overlap. The
/// positions are f32, and the rounding of `position + delta` can put a box
/// a small distance into the block that stopped it. The tolerance grows
/// with the coordinate, so it stays larger than that rounding.
fn tolerance(v: f32) f32 {
    return @max(1e-5, @abs(v) * 0x1p-20);
}

/// True when a and b overlap on `axis` by more than the tolerance.
fn overlaps(a: Box, b: Box, axis: usize) bool {
    const t = tolerance(a.min[axis]) + tolerance(a.max[axis]);
    return a.max[axis] > b.min[axis] + t and a.min[axis] < b.max[axis] - t;
}

/// The cell of coordinate `v`. The clamp keeps a large or a bad value in
/// the i32 range.
fn cellOf(v: f32) i32 {
    if (std.math.isNan(v)) return 0;
    const limit: f32 = 0x1p30;
    return @intFromFloat(@floor(std.math.clamp(v, -limit, limit)));
}

fn cellRange(v: [3]f32) [3]i32 {
    return .{ cellOf(v[0]), cellOf(v[1]), cellOf(v[2]) };
}

/// The part of movement `d` on `axis` that the blocks allow for `box`.
fn clipAxis(blocks: anytype, box: Box, axis: usize, d: f32) f32 {
    if (d == 0 or std.math.isNan(d)) return 0;
    var region = box;
    if (d > 0) region.max[axis] += d else region.min[axis] += d;
    const lo = cellRange(region.min);
    const hi = cellRange(region.max);
    var out = d;
    var x = lo[0];
    while (x <= hi[0]) : (x += 1) {
        var y = lo[1];
        while (y <= hi[1]) : (y += 1) {
            var z = lo[2];
            while (z <= hi[2]) : (z += 1) {
                for (boxes(blocks.getBlock(x, y, z))) |cb| {
                    out = clipBox(box, Box.fromCell(cb, x, y, z), axis, out);
                }
            }
        }
    }
    return out;
}

/// Clip movement `d` of `box` on `axis` at the block box `b`. Only a box
/// that overlaps on the two other axes, and that is in front of `box`,
/// stops it. The result does not go back against `d`.
fn clipBox(box: Box, b: Box, axis: usize, d: f32) f32 {
    for (0..3) |i| {
        if (i != axis and !overlaps(box, b, i)) return d;
    }
    if (d > 0) {
        const t = tolerance(box.max[axis]);
        if (b.min[axis] >= box.max[axis] - t) return @min(d, @max(0, b.min[axis] - box.max[axis]));
    } else {
        const t = tolerance(box.min[axis]);
        if (b.max[axis] <= box.min[axis] + t) return @max(d, @min(0, b.max[axis] - box.min[axis]));
    }
    return d;
}

/// Move `box` on x and z, the larger movement first. Returns the movement
/// on each axis, with y at 0.
fn moveHorizontal(blocks: anytype, box: *Box, d: [3]f32) [3]f32 {
    var out = [3]f32{ 0, 0, 0 };
    const first: usize = if (@abs(d[0]) >= @abs(d[2])) 0 else 2;
    const second: usize = 2 - first;
    for ([2]usize{ first, second }) |axis| {
        out[axis] = clipAxis(blocks, box.*, axis, d[axis]);
        box.* = box.offset(axis, out[axis]);
    }
    return out;
}

fn moveAxes(blocks: anytype, start: Box, d: [3]f32) MoveResult {
    const dy = clipAxis(blocks, start, 1, d[1]);
    var b = start.offset(1, dy);
    const h = moveHorizontal(blocks, &b, d);
    return .{
        .delta = Vec3.init(h[0], dy, h[2]),
        .blocked_x = h[0] != d[0],
        .blocked_y = dy != d[1],
        .blocked_z = h[2] != d[2],
        .on_ground = d[1] < 0 and dy != d[1],
    };
}

// ---------------------------------------------------------------------------
// Voxel ray cast (REQ-VOXEL-007)
// ---------------------------------------------------------------------------

/// The first block that a ray hits.
pub const RayHit = struct {
    /// The cell of the block, in world coordinates.
    cell: [3]i32,
    block: Block,
    /// The face of the box where the ray goes in. Null when the ray starts
    /// in a collision box of the block. The cell in front of the face is
    /// `cell + model.face_offsets[face]`.
    face: ?model.Face,
    /// The distance along the ray, in units of the length of `ray.dir`.
    distance: f32,
};

/// Cast `ray` through the voxel grid (a DDA: one cell at a time, in the
/// order that the ray goes through them). Returns the first collision box
/// that the ray hits at a distance of `max_distance` or less, or null.
/// The ray tests each box of a block, so a block smaller than a cube stops
/// the ray only where it has a box. A ray that starts in a box hits it at
/// distance 0. A `max_distance` that is negative, infinite or NaN, or a
/// ray with an infinite or NaN component, gives null.
pub fn raycast(blocks: anytype, ray: Ray, max_distance: f32) ?RayHit {
    const o = [3]f32{ ray.origin.x, ray.origin.y, ray.origin.z };
    const d = [3]f32{ ray.dir.x, ray.dir.y, ray.dir.z };
    for (0..3) |i| {
        if (!std.math.isFinite(o[i]) or !std.math.isFinite(d[i])) return null;
    }
    if (!std.math.isFinite(max_distance) or max_distance < 0) return null;

    var cell = cellRange(o);
    var step: [3]i32 = .{ 0, 0, 0 };
    var t_max: [3]f32 = @splat(std.math.inf(f32));
    var t_delta: [3]f32 = @splat(std.math.inf(f32));
    // The ray goes through at most this number of cell faces. The limit
    // also stops the loop when a tiny step does not change t_max.
    var limit: f64 = 3;
    for (0..3) |i| {
        const c: f32 = @floatFromInt(cell[i]);
        if (d[i] > 0) {
            step[i] = 1;
            t_delta[i] = 1 / d[i];
            t_max[i] = (c + 1 - o[i]) / d[i];
        } else if (d[i] < 0) {
            step[i] = -1;
            t_delta[i] = -1 / d[i];
            t_max[i] = (c - o[i]) / d[i];
        }
        limit += @ceil(@as(f64, @abs(d[i])) * max_distance);
    }
    var steps: u32 = @intFromFloat(@min(limit, 1 << 24));

    while (true) {
        if (hitCell(blocks, ray, cell, max_distance)) |hit| return hit;
        var axis: usize = 0;
        if (t_max[1] < t_max[axis]) axis = 1;
        if (t_max[2] < t_max[axis]) axis = 2;
        if (t_max[axis] > max_distance or steps == 0) return null;
        steps -= 1;
        cell[axis] += step[axis];
        t_max[axis] += t_delta[axis];
    }
}

/// The nearest hit of `ray` on the boxes of the block in `cell`.
fn hitCell(blocks: anytype, ray: Ray, cell: [3]i32, max_distance: f32) ?RayHit {
    const block: Block = blocks.getBlock(cell[0], cell[1], cell[2]);
    var best: ?RayHit = null;
    for (boxes(block)) |cb| {
        const h = ray.intersectAabb(cb.aabb(cell[0], cell[1], cell[2])) orelse continue;
        if (h.t_enter > max_distance) continue;
        if (best) |b| if (h.t_enter >= b.distance) continue;
        best = .{ .cell = cell, .block = block, .face = faceOf(h.normal), .distance = h.t_enter };
    }
    return best;
}

fn faceOf(n: Vec3) ?model.Face {
    if (n.x > 0) return .px;
    if (n.x < 0) return .nx;
    if (n.y > 0) return .py;
    if (n.y < 0) return .ny;
    if (n.z > 0) return .pz;
    if (n.z < 0) return .nz;
    return null;
}

/// The voxel ray cast as the ray test of the camera controller
/// (`sw_math.camera.RayTest`), for the wall stop of the third-person
/// camera. The camera stops at the collision boxes of the blocks.
///
///   var walls = collision.CameraRayTest{ .blocks = world.asBlockGetter() };
///   const out = camera.update(input, dt, walls.rayTest());
pub const CameraRayTest = struct {
    blocks: chunk.BlockGetter,

    /// The ray test. It holds a pointer to `self`, so keep `self` alive
    /// while the camera uses the result.
    pub fn rayTest(self: *CameraRayTest) math.camera.RayTest {
        return .{ .context = self, .hitFn = hit };
    }

    fn hit(context: ?*anyopaque, ray: Ray, max_distance: f32) ?f32 {
        const self: *CameraRayTest = @ptrCast(@alignCast(context.?));
        const h = raycast(self.blocks, ray, max_distance) orelse return null;
        return h.distance;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A test world of 32 × 32 × 32 cells from (-16, -16, -16). All other
/// cells are air.
const Grid = struct {
    const N = 32;
    const O = 16;
    cells: [N][N][N]Block = @splat(@splat(@splat(.air))),

    fn index(v: i32) ?usize {
        const i = v + O;
        if (i < 0 or i >= N) return null;
        return @intCast(i);
    }

    pub fn getBlock(self: *const Grid, x: i32, y: i32, z: i32) Block {
        const ix = index(x) orelse return .air;
        const iy = index(y) orelse return .air;
        const iz = index(z) orelse return .air;
        return self.cells[ix][iy][iz];
    }

    fn set(self: *Grid, x: i32, y: i32, z: i32, block: Block) void {
        self.cells[index(x).?][index(y).?][index(z).?] = block;
    }

    fn fill(self: *Grid, from: [3]i32, to: [3]i32, block: Block) void {
        var x = from[0];
        while (x <= to[0]) : (x += 1) {
            var y = from[1];
            while (y <= to[1]) : (y += 1) {
                var z = from[2];
                while (z <= to[2]) : (z += 1) self.set(x, y, z, block);
            }
        }
    }

    fn getter(self: *const Grid) chunk.BlockGetter {
        return .{
            .ctx = self,
            .getFn = struct {
                fn get(ctx: *const anyopaque, x: i32, y: i32, z: i32) Block {
                    return @as(*const Grid, @ptrCast(@alignCast(ctx))).getBlock(x, y, z);
                }
            }.get,
            .getSkylightFn = struct {
                fn sky(_: *const anyopaque, _: i32, _: i32, _: i32) u8 {
                    return chunk.MAX_SKYLIGHT;
                }
            }.sky,
            .getBlockLightFn = struct {
                fn bl(_: *const anyopaque, _: i32, _: i32, _: i32) u8 {
                    return 0;
                }
            }.bl,
        };
    }
};

/// A box of 0.6 × 1.8 × 0.6 with its feet at `feet`.
fn body(feet: Vec3) Aabb {
    return Aabb.init(feet.add(Vec3.init(-0.3, 0, -0.3)), feet.add(Vec3.init(0.3, 1.8, 0.3)));
}

/// A grid with a floor of full cubes at y = -1 (top face at y 0).
fn floorGrid() Grid {
    var g = Grid{};
    g.fill(.{ -16, -1, -16 }, .{ 15, -1, 15 }, .solid);
    return g;
}

const eps = 1e-4;

fn expectVec(expected: Vec3, actual: Vec3) !void {
    try testing.expectApproxEqAbs(expected.x, actual.x, eps);
    try testing.expectApproxEqAbs(expected.y, actual.y, eps);
    try testing.expectApproxEqAbs(expected.z, actual.z, eps);
}

test "the content gives the collision boxes of each block (REQ-VOXEL-006)" {
    try testing.expectEqual(@as(usize, 0), boxes(.air).len);
    try testing.expect(!isSolid(.air));
    // A block with no declaration is a full cube.
    try testing.expectEqualSlices(CellBox, &full_cube, boxes(.solid));
    // The test content: b19 is a half block, b20 has no box, b16 has two
    // boxes, b18 is a thin post.
    try testing.expectEqual(@as(f32, 0.5), boxes(.b19)[0].max[1]);
    try testing.expect(!isSolid(.b20));
    try testing.expectEqual(@as(usize, 2), boxes(.b16).len);
    try testing.expectEqual(@as(f32, 0.375), boxes(.b18)[0].min[0]);
}

test "a falling box stops on the floor (REQ-VOXEL-006)" {
    const g = floorGrid();
    const r = moveBox(&g, body(Vec3.init(0.5, 2, 0.5)), Vec3.init(0, -3, 0), .{});
    try expectVec(Vec3.init(0, -2, 0), r.delta);
    try testing.expect(r.on_ground and r.blocked_y);
    try testing.expect(!r.blocked_x and !r.blocked_z);

    // On the floor, a horizontal move is free: the floor does not catch
    // the box.
    const feet = Vec3.init(0.5, 2, 0.5).add(r.delta);
    const walk = moveBox(&g, body(feet), Vec3.init(3, -0.08, -2), .{});
    try expectVec(Vec3.init(3, 0, -2), walk.delta);
    try testing.expect(walk.on_ground and !walk.blocked_x and !walk.blocked_z);
}

test "a wall stops one axis and the box slides on the other (REQ-VOXEL-006)" {
    var g = floorGrid();
    // A wall at x = 3 (its -x face at x 3).
    g.fill(.{ 3, 0, -16 }, .{ 3, 4, 15 }, .solid);
    const r = moveBox(&g, body(Vec3.init(1, 0, 0.5)), Vec3.init(4, 0, 1.5), .{});
    try expectVec(Vec3.init(1.7, 0, 1.5), r.delta);
    try testing.expect(r.blocked_x and !r.blocked_z);
    try testing.expect(!collides(&g, body(Vec3.init(1, 0, 0.5).add(r.delta))));
    // The box now touches the wall. A move along the wall is free, and a
    // move into the wall gives 0.
    const touch = body(Vec3.init(2.7, 0, 2));
    try expectVec(Vec3.init(0, 0, -3), moveBox(&g, touch, Vec3.init(0, 0, -3), .{}).delta);
    try expectVec(Vec3.init(0, 0, 0), moveBox(&g, touch, Vec3.init(0.5, 0, 0), .{}).delta);
}

test "corners: an outer corner and an inner corner (REQ-VOXEL-006)" {
    var g = floorGrid();
    // One column at cell x 2, z 2.
    g.fill(.{ 2, 0, 2 }, .{ 2, 2, 2 }, .solid);
    // The box goes diagonally at the corner of the column. x moves first
    // (the larger movement) and passes beside the column. Then z hits the
    // column.
    const start = Vec3.init(1.5, 0, 1.5);
    const r = moveBox(&g, body(start), Vec3.init(1.0, 0, 0.9), .{});
    try expectVec(Vec3.init(1.0, 0, 0.2), r.delta);
    try testing.expect(!r.blocked_x and r.blocked_z);
    try testing.expect(!collides(&g, body(start.add(r.delta))));

    // A box exactly at the corner, on both faces: it touches the column
    // only on an edge, so it can move away and along each face.
    const edge = body(Vec3.init(1.7, 0, 1.7));
    try testing.expect(!collides(&g, edge));
    try expectVec(Vec3.init(0, 0, -1), moveBox(&g, edge, Vec3.init(0, 0, -1), .{}).delta);

    // An inner corner: walls at x = 5 and z = 5. A diagonal move stops on
    // both axes.
    g.fill(.{ 5, 0, -16 }, .{ 5, 2, 15 }, .solid);
    g.fill(.{ -16, 0, 5 }, .{ 15, 2, 5 }, .solid);
    const in = moveBox(&g, body(Vec3.init(4, 0, 4)), Vec3.init(2, 0, 2), .{});
    try expectVec(Vec3.init(0.7, 0, 0.7), in.delta);
    try testing.expect(in.blocked_x and in.blocked_z);
}

test "a high speed does not go through a wall of one block (REQ-VOXEL-006)" {
    var g = floorGrid();
    g.fill(.{ 5, 0, -16 }, .{ 5, 3, 15 }, .solid);
    // 1000 blocks in one move: the wall still stops the box.
    const r = moveBox(&g, body(Vec3.init(0.5, 0, 0.5)), Vec3.init(1000, 0, 0), .{});
    try expectVec(Vec3.init(4.2, 0, 0), r.delta);
    try testing.expect(r.blocked_x);
    const back = moveBox(&g, body(Vec3.init(9.5, 0, 0.5)), Vec3.init(-1e6, 0, 0), .{});
    try expectVec(Vec3.init(-3.2, 0, 0), back.delta);

    // A fall of 500 blocks stops on the floor.
    const fall = moveBox(&g, body(Vec3.init(0.5, 10, 0.5)), Vec3.init(0, -500, 0), .{});
    try expectVec(Vec3.init(0, -10, 0), fall.delta);
    try testing.expect(fall.on_ground);

    // A small box at high speed does not go through a thin post: the +x
    // face of the post is at x -4.375.
    g.set(-5, 0, 0, .b18);
    const small = Aabb.init(Vec3.init(-1.1, 0.2, 0.4), Vec3.init(-1.0, 0.3, 0.6));
    const p = moveBox(&g, small, Vec3.init(-5000, 0, 0), .{});
    try testing.expectApproxEqAbs(@as(f32, -4.375 + 1.1), p.delta.x, eps);
}

test "step-up climbs a low block and not a high block (REQ-VOXEL-006)" {
    var g = floorGrid();
    // A half block at x 2, and a full cube at x 2 further on z.
    g.set(2, 0, 0, .b19);
    g.set(2, 0, 6, .solid);
    const opts: MoveOptions = .{ .step_height = 0.6, .on_ground = true };

    const r = moveBox(&g, body(Vec3.init(1.5, 0, 0.5)), Vec3.init(0.5, -0.08, 0), opts);
    try expectVec(Vec3.init(0.5, 0.5, 0), r.delta);
    try testing.expect(r.stepped and r.on_ground and !r.blocked_x);
    try testing.expect(!collides(&g, body(Vec3.init(1.5, 0, 0.5).add(r.delta))));

    // No step-up: the half block stops the box.
    const no = moveBox(&g, body(Vec3.init(1.5, 0, 0.5)), Vec3.init(0.5, -0.08, 0), .{});
    try expectVec(Vec3.init(0.2, 0, 0), no.delta);
    try testing.expect(no.blocked_x and !no.stepped);

    // The full cube is higher than the step.
    const high = moveBox(&g, body(Vec3.init(1.5, 0, 6.5)), Vec3.init(0.5, -0.08, 0), opts);
    try expectVec(Vec3.init(0.2, 0, 0), high.delta);
    try testing.expect(high.blocked_x and !high.stepped);

    // In the air (not on the ground, no landing), the box does not step.
    const air = moveBox(&g, body(Vec3.init(1.5, 0.2, 0.5)), Vec3.init(0.5, 0.0, 0), .{ .step_height = 0.6 });
    try testing.expect(!air.stepped);

    // A ceiling 2 blocks above the floor leaves no space to climb.
    g.fill(.{ -16, 2, -16 }, .{ 15, 2, 15 }, .solid);
    const low = moveBox(&g, body(Vec3.init(1.5, 0, 0.5)), Vec3.init(0.5, -0.08, 0), opts);
    try testing.expect(!low.stepped);
    try expectVec(Vec3.init(0.2, 0, 0), low.delta);
}

test "blocks smaller than a full cube (REQ-VOXEL-006)" {
    var g = floorGrid();
    // A box falls onto a half block and stands at y 0.5.
    g.set(0, 0, 0, .b19);
    const r = moveBox(&g, body(Vec3.init(0.5, 3, 0.5)), Vec3.init(0, -5, 0), .{});
    try expectVec(Vec3.init(0, -2.5, 0), r.delta);
    try testing.expect(r.on_ground);

    // A block with no box does not stop the box.
    g.set(3, 0, 0, .b20);
    const through = moveBox(&g, body(Vec3.init(1.5, 0, 0.5)), Vec3.init(4, 0, 0), .{});
    try expectVec(Vec3.init(4, 0, 0), through.delta);

    // A thin post (x -3.625 to -3.375): a box that passes beside it is
    // free, and a box that goes at it stops at its +x face.
    g.set(-4, 0, 0, .b18);
    const beside = Aabb.init(Vec3.init(-2, 0, 0.0), Vec3.init(-1.8, 1, 0.3));
    try expectVec(Vec3.init(-4, 0, 0), moveBox(&g, beside, Vec3.init(-4, 0, 0), .{}).delta);
    const at = Aabb.init(Vec3.init(-2, 0, 0.4), Vec3.init(-1.8, 1, 0.6));
    try expectVec(Vec3.init(-3.375 + 2, 0, 0), moveBox(&g, at, Vec3.init(-4, 0, 0), .{}).delta);

    // A block with two boxes (a stair: a bottom half and the top of the
    // -x half). A box on the low part walks into the high part.
    g.set(6, 0, 0, .b16);
    const stair = Aabb.init(Vec3.init(6.6, 0.5, 0.4), Vec3.init(6.9, 1.5, 0.6));
    const into = moveBox(&g, stair, Vec3.init(-1, 0, 0), .{});
    try expectVec(Vec3.init(-0.1, 0, 0), into.delta);
}

test "collides finds overlap and not contact (REQ-VOXEL-006)" {
    var g = Grid{};
    g.set(0, 0, 0, .solid);
    try testing.expect(collides(&g, Aabb.init(Vec3.init(0.5, 0.5, 0.5), Vec3.init(1.5, 1.5, 1.5))));
    try testing.expect(!collides(&g, Aabb.init(Vec3.init(1, 0, 0), Vec3.init(2, 1, 1))));
    try testing.expect(!collides(&g, Aabb.init(Vec3.init(0, 1, 0), Vec3.init(1, 2, 1))));
}

test "ray cast along each axis gives the face and the distance (REQ-VOXEL-007)" {
    var g = Grid{};
    g.set(0, 0, 0, .solid);
    const c = Vec3.init(0.5, 0.5, 0.5);
    const cases = [_]struct { origin: Vec3, dir: Vec3, face: model.Face }{
        .{ .origin = Vec3.init(-4.5, 0.5, 0.5), .dir = Vec3.init(1, 0, 0), .face = .nx },
        .{ .origin = Vec3.init(5.5, 0.5, 0.5), .dir = Vec3.init(-1, 0, 0), .face = .px },
        .{ .origin = Vec3.init(0.5, -4.5, 0.5), .dir = Vec3.init(0, 1, 0), .face = .ny },
        .{ .origin = Vec3.init(0.5, 5.5, 0.5), .dir = Vec3.init(0, -1, 0), .face = .py },
        .{ .origin = Vec3.init(0.5, 0.5, -4.5), .dir = Vec3.init(0, 0, 1), .face = .nz },
        .{ .origin = Vec3.init(0.5, 0.5, 5.5), .dir = Vec3.init(0, 0, -1), .face = .pz },
    };
    for (cases) |k| {
        const hit = raycast(&g, Ray.init(k.origin, k.dir), 10).?;
        try testing.expectEqual([3]i32{ 0, 0, 0 }, hit.cell);
        try testing.expectEqual(Block.solid, hit.block);
        try testing.expectEqual(k.face, hit.face.?);
        try testing.expectApproxEqAbs(@as(f32, 4.5), hit.distance, eps);
        // The face points back to the origin cell side.
        const off = model.face_offsets[@backingInt(k.face)];
        const back = Vec3.init(@floatFromInt(off[0]), @floatFromInt(off[1]), @floatFromInt(off[2]));
        try testing.expect(back.dot(k.origin.sub(c)) > 0);
    }
    // The distance is in units of the length of dir.
    const long = raycast(&g, Ray.init(Vec3.init(-4.5, 0.5, 0.5), Vec3.init(2, 0, 0)), 10).?;
    try testing.expectApproxEqAbs(@as(f32, 2.25), long.distance, eps);
}

test "ray cast stops at max distance (REQ-VOXEL-007)" {
    var g = Grid{};
    g.set(5, 0, 0, .solid);
    const ray = Ray.init(Vec3.init(0.5, 0.5, 0.5), Vec3.init(1, 0, 0));
    try testing.expect(raycast(&g, ray, 4.4) == null);
    try testing.expectApproxEqAbs(@as(f32, 4.5), raycast(&g, ray, 4.5).?.distance, eps);
    // Bad input gives null and does not loop.
    try testing.expect(raycast(&g, ray, std.math.inf(f32)) == null);
    try testing.expect(raycast(&g, ray, -1) == null);
    try testing.expect(raycast(&g, Ray.init(Vec3.init(std.math.nan(f32), 0, 0), Vec3.init(1, 0, 0)), 10) == null);
    // A zero direction tests only the cell of the origin.
    try testing.expect(raycast(&g, Ray.init(Vec3.init(0.5, 0.5, 0.5), Vec3.zero()), 10) == null);
    try testing.expectEqual(@as(f32, 0), raycast(&g, Ray.init(Vec3.init(5.5, 0.5, 0.5), Vec3.zero()), 10).?.distance);
}

test "a ray that starts in a block hits it at distance 0 (REQ-VOXEL-007)" {
    var g = Grid{};
    g.set(0, 0, 0, .solid);
    g.set(3, 0, 0, .b19);
    const in = raycast(&g, Ray.init(Vec3.init(0.5, 0.5, 0.5), Vec3.init(1, 0, 0)), 10).?;
    try testing.expectEqual([3]i32{ 0, 0, 0 }, in.cell);
    try testing.expectEqual(@as(f32, 0), in.distance);
    try testing.expect(in.face == null);

    // A ray that starts in the cell of the half block, above its box,
    // misses it, and a ray down hits its top.
    try testing.expect(raycast(&g, Ray.init(Vec3.init(3.5, 0.75, 0.5), Vec3.init(1, 0, 0)), 10) == null);
    const down = raycast(&g, Ray.init(Vec3.init(3.5, 0.75, 0.5), Vec3.init(0, -1, 0)), 10).?;
    try testing.expectEqual(model.Face.py, down.face.?);
    try testing.expectApproxEqAbs(@as(f32, 0.25), down.distance, eps);
}

test "ray cast on diagonals agrees with a test of each box (REQ-VOXEL-007)" {
    var g = Grid{};
    var prng = std.Random.DefaultPrng.init(51);
    const rand = prng.random();
    const kinds = [_]Block{ .solid, .b16, .b18, .b19, .b20 };
    for (0..1200) |_| {
        const x = rand.intRangeAtMost(i32, -10, 9);
        const y = rand.intRangeAtMost(i32, -10, 9);
        const z = rand.intRangeAtMost(i32, -10, 9);
        g.set(x, y, z, kinds[rand.uintLessThan(usize, kinds.len)]);
    }
    var hits: usize = 0;
    for (0..500) |_| {
        const origin = Vec3.init(
            rand.float(f32) * 24 - 12,
            rand.float(f32) * 24 - 12,
            rand.float(f32) * 24 - 12,
        );
        const dir = Vec3.init(rand.float(f32) * 2 - 1, rand.float(f32) * 2 - 1, rand.float(f32) * 2 - 1).normalize();
        const ray = Ray.init(origin, dir);
        const max: f32 = 30;
        // The reference: test every box of every cell.
        var best: ?f32 = null;
        var cx: i32 = -10;
        while (cx < 10) : (cx += 1) for (0..20) |iy| for (0..20) |iz| {
            const cy = @as(i32, @intCast(iy)) - 10;
            const cz = @as(i32, @intCast(iz)) - 10;
            for (boxes(g.getBlock(cx, cy, cz))) |cb| {
                const h = ray.intersectAabb(cb.aabb(cx, cy, cz)) orelse continue;
                if (h.t_enter > max) continue;
                if (best == null or h.t_enter < best.?) best = h.t_enter;
            }
        };
        const got = raycast(&g, ray, max);
        if (best) |b| {
            try testing.expect(got != null);
            try testing.expectApproxEqAbs(b, got.?.distance, eps);
            hits += 1;
        } else {
            try testing.expect(got == null);
        }
    }
    try testing.expect(hits > 100);

    // An exact diagonal through cell corners.
    var d = Grid{};
    d.set(4, 4, 4, .solid);
    const hit = raycast(&d, Ray.init(Vec3.init(0.5, 0.5, 0.5), Vec3.init(1, 1, 1)), 10).?;
    try testing.expectEqual([3]i32{ 4, 4, 4 }, hit.cell);
    try testing.expectApproxEqAbs(@as(f32, 3.5), hit.distance, eps);
}

test "the camera adapter stops the third-person eye at a wall of blocks (REQ-VOXEL-007)" {
    var g = Grid{};
    // A wall at z 3 behind the target (the camera looks along -z, so the
    // eye is at +z).
    g.fill(.{ -8, -8, 3 }, .{ 8, 8, 3 }, .solid);
    var walls = CameraRayTest{ .blocks = g.getter() };
    const rt = walls.rayTest();
    // The ray test itself.
    try testing.expectApproxEqAbs(@as(f32, 2.5), rt.hit(Ray.init(Vec3.init(0.5, 0.5, 0.5), Vec3.init(0, 0, 1)), 8).?, eps);
    try testing.expect(rt.hit(Ray.init(Vec3.init(0.5, 0.5, 0.5), Vec3.init(0, 0, -1)), 8) == null);

    var cam = math.camera.Controller.init(.{ .mode = .third_person, .distance = 4, .probe_radius = 0, .distance_smoothing = 0 });
    cam.setTarget(Vec3.init(0.5, 0.5, 0.5));
    const out = cam.update(.{}, 0.016, rt);
    try testing.expectApproxEqAbs(@as(f32, 3.0), out.eye.z, eps);
    // With no wall, the eye is at the full distance.
    const free = cam.update(.{}, 0.016, null);
    try testing.expect(free.eye.z > 3.0);
}

test "ray cast and move on a generated World (REQ-VOXEL-006, REQ-VOXEL-007)" {
    const world_mod = @import("world.zig");
    var world = try world_mod.World.init(testing.allocator, .{}, 2);
    defer world.deinit();
    _ = try world.generateChunk(0, 0);
    const getter = world.asBlockGetter();
    const top = world_mod.World.min_y + @as(i32, @intCast(world_mod.World.height)) - 1;
    var x: i32 = 0;
    while (x < 16) : (x += 5) {
        // The reference: the highest block with a box in the column.
        var y = top;
        while (y >= world_mod.World.min_y and !isSolid(world.getBlock(x, y, 3))) y -= 1;
        const start: f32 = @floatFromInt(top + 1);
        const fx: f32 = @floatFromInt(x);
        const ray = Ray.init(Vec3.init(fx + 0.5, start, 3.5), Vec3.init(0, -1, 0));
        const hit = raycast(getter, ray, 1000).?;
        try testing.expectEqual([3]i32{ x, y, 3 }, hit.cell);
        try testing.expectEqual(model.Face.py, hit.face.?);
        // A box that falls from the top stands on the same block.
        const feet = Vec3.init(fx + 0.5, start, 3.5);
        const small = Aabb.init(feet.add(Vec3.init(-0.2, 0, -0.2)), feet.add(Vec3.init(0.2, 1, 0.2)));
        const fall = moveBox(&world, small, Vec3.init(0, -1000, 0), .{});
        try testing.expect(fall.on_ground);
        try testing.expectApproxEqAbs(@as(f32, @floatFromInt(y + 1)), start + fall.delta.y, eps);
    }
}
