// The snowy arena of the shooter demo (REQ-DEMO-020): a square of snow
// with a wall round it, and cover in it. Code builds it, so there is no
// map file.
//
// The arena takes the place of `map.zig` of the action game for the
// harvested modules (player.zig, ragdoll.zig). It gives the same queries:
// `overlaps`, `floorTop`, `raycast` and `rayBox`. The box tests use
// `sw_math.Aabb` and `sw_math.Ray`.
//
// - The cover: crates (wood), concrete walls and barriers, and steel
//   containers. A box of `tall` cover hides a standing body.
// - The cover points: places beside the tall cover where a bot can hide
//   from the player or step out to fire (`cover_points`).
// - The snow: a white cap on the top of each box (not solid), and the
//   height map that stops the falling snow (`heightAt`).
const std = @import("std");
const sw_math = @import("sw_math");
const vec = @import("vec.zig");
const Surface = @import("audio/impact.zig").Material;
const V3 = vec.V3;
const v3 = vec.v3;

pub const Kind = enum { ground, wall, crate, barrier, block, container };

pub const Box = struct {
    min: V3,
    max: V3,
    color: V3,
    surface: Surface,
    kind: Kind,
    solid: bool = true,
    /// It hides a standing body: a bot can take cover behind it.
    tall: bool = false,
};

/// The half size of the square inside the wall.
pub const half: f32 = 24;
pub const wall_h: f32 = 3.2;
pub const kill_y: f32 = -5;
pub const snow_color = v3(0.86, 0.89, 0.94);

pub const Spawn = struct { pos: V3, yaw: f32 };
/// The player starts at the south and looks north (-Z).
pub const player_spawn: Spawn = .{ .pos = v3(0, 0, 19), .yaw = 0 };
/// The bots start at the north.
pub const bot_spawns = [_]V3{ v3(-9, 0, -19), v3(0.5, 0, -20.5), v3(10, 0, -18) };

pub const max_boxes = 64;
pub var boxes: [max_boxes]Box = undefined;
pub var box_count: usize = 0;

fn add(min: V3, max: V3, color: V3, surface: Surface, kind: Kind) void {
    const tall = max[1] - min[1] >= 1.9 and kind != .ground and kind != .wall;
    boxes[box_count] = .{ .min = min, .max = max, .color = color, .surface = surface, .kind = kind, .tall = tall };
    box_count += 1;
}

/// A box on the ground: its centre x, z, its size and its kind.
fn put(x: f32, z: f32, sx: f32, sy: f32, sz: f32, kind: Kind) void {
    const look: struct { V3, Surface } = switch (kind) {
        .crate => .{ v3(0.42, 0.29, 0.16), .wood },
        .barrier => .{ v3(0.55, 0.55, 0.53), .concrete },
        .block => .{ v3(0.5, 0.49, 0.47), .concrete },
        .container => .{ v3(0.52, 0.16, 0.12), .sheet_metal },
        .wall, .ground => .{ v3(0.45, 0.45, 0.45), .concrete },
    };
    add(v3(x - sx / 2, 0, z - sz / 2), v3(x + sx / 2, sy, z + sz / 2), look[0], look[1], kind);
}

/// Build the arena. Call it once before the other functions.
pub fn build() void {
    box_count = 0;
    // The ground: snow on earth.
    add(v3(-half - 2, -1, -half - 2), v3(half + 2, 0, half + 2), snow_color, .earth, .ground);
    // The outer wall.
    const t: f32 = 0.6;
    const wc = v3(0.4, 0.41, 0.43);
    add(v3(-half - t, 0, -half - t), v3(half + t, wall_h, -half), wc, .concrete, .wall);
    add(v3(-half - t, 0, half), v3(half + t, wall_h, half + t), wc, .concrete, .wall);
    add(v3(-half - t, 0, -half), v3(-half, wall_h, half), wc, .concrete, .wall);
    add(v3(half, 0, -half), v3(half + t, wall_h, half), wc, .concrete, .wall);
    // The cover near the player.
    put(0, 14, 3.0, 1.05, 0.5, .barrier);
    put(-6.5, 15, 1.2, 1.2, 1.2, .crate);
    put(-5.3, 15.2, 1.2, 1.2, 1.2, .crate);
    put(6, 13, 1.2, 2.4, 1.2, .crate);
    // The middle.
    put(-9, 3, 6.0, 2.6, 2.4, .container);
    put(10, -1, 2.4, 2.6, 6.0, .container);
    put(0, 1, 3.2, 2.4, 0.6, .block);
    put(3.5, 6, 1.2, 1.2, 1.2, .crate);
    put(-3.5, 7.5, 2.4, 1.05, 0.5, .barrier);
    // The north half, where the bots start.
    put(-5, -8, 0.6, 2.4, 3.2, .block);
    put(5, -9.5, 3.2, 2.4, 0.6, .block);
    put(-12, -12, 1.2, 2.4, 1.2, .crate);
    put(-10.8, -12, 1.2, 1.2, 1.2, .crate);
    put(13, -13, 1.2, 2.4, 1.2, .crate);
    put(0, -14, 2.4, 1.05, 0.5, .barrier);
    put(-15, 9, 1.2, 2.4, 1.2, .crate);
    put(16, 8, 3.0, 1.05, 0.5, .barrier);
    buildCoverPoints();
    buildHeights();
}

// ---- Queries ---------------------------------------------------------------

fn aabb(min: V3, max: V3) sw_math.Aabb {
    return sw_math.Aabb.init(.init(min[0], min[1], min[2]), .init(max[0], max[1], max[2]));
}

pub const Hit = struct { t: f32, normal: V3, box: usize };

/// Ray against one box. Returns the entry distance and normal.
pub fn rayBox(o: V3, d: V3, min: V3, max: V3) ?struct { t: f32, n: V3 } {
    const r = sw_math.Ray.init(.init(o[0], o[1], o[2]), .init(d[0], d[1], d[2]));
    const h = r.intersectAabb(aabb(min, max)) orelse return null;
    return .{ .t = h.t_enter, .n = v3(h.normal.x, h.normal.y, h.normal.z) };
}

/// The nearest solid box that the ray hits within max_t.
pub fn raycast(o: V3, d: V3, max_t: f32) ?Hit {
    var best: ?Hit = null;
    for (boxes[0..box_count], 0..) |b, i| {
        if (!b.solid) continue;
        if (rayBox(o, d, b.min, b.max)) |h| {
            if (h.t <= max_t and (best == null or h.t < best.?.t)) best = .{ .t = h.t, .normal = h.n, .box = i };
        }
    }
    return best;
}

/// True when nothing solid is on the line from a to b.
pub fn clear(a: V3, b: V3) bool {
    const d = b - a;
    const l = vec.len(d);
    if (l < 1e-4) return true;
    return raycast(a, d / vec.s(l), l) == null;
}

/// True when an AABB overlaps a solid box.
pub fn overlaps(min: V3, max: V3) bool {
    const q = aabb(min, max);
    for (boxes[0..box_count]) |b| {
        if (!b.solid) continue;
        // Touching faces do not overlap.
        if (min[0] < b.max[0] and max[0] > b.min[0] and min[1] < b.max[1] and max[1] > b.min[1] and min[2] < b.max[2] and max[2] > b.min[2]) {
            if (q.intersects(aabb(b.min, b.max))) return true;
        }
    }
    return false;
}

/// The highest floor under the AABB: the top of a solid box that is under
/// min..max in X and Z and from min[1] to max[1] in height. Null when
/// there is none.
pub fn floorTop(min: V3, max: V3) ?f32 {
    var best: ?f32 = null;
    for (boxes[0..box_count]) |b| {
        if (!b.solid) continue;
        if (min[0] < b.max[0] and max[0] > b.min[0] and min[2] < b.max[2] and max[2] > b.min[2] and b.max[1] >= min[1] and b.max[1] <= max[1]) {
            if (best == null or b.max[1] > best.?) best = b.max[1];
        }
    }
    return best;
}

/// The surface of box `bi`. The top of a box has snow on it.
pub fn surfaceAt(p: V3, bi: usize) Surface {
    const b = boxes[bi];
    if (p[1] >= b.max[1] - 0.02) return .earth;
    return b.surface;
}

/// True when a hit at p on box `bi` lands in snow: the ground, or the
/// snow cap on the top of a box.
pub fn snowAt(p: V3, bi: usize) bool {
    const b = boxes[bi];
    return b.kind == .ground or p[1] >= b.max[1] - 0.02;
}

// ---- The cover points ------------------------------------------------------

pub const CoverPoint = struct {
    pos: V3,
    /// The box that the point is beside.
    box: usize,
    /// The direction from the box face to the point (out of the face).
    out: V3,
};

pub const max_cover = 160;
pub var cover_points: [max_cover]CoverPoint = undefined;
pub var cover_count: usize = 0;
/// The gap from a box face to a cover point.
const cover_gap: f32 = 0.55;

fn addCover(p: V3, box: usize, out: V3) void {
    if (cover_count >= max_cover) return;
    if (@abs(p[0]) > half - 0.6 or @abs(p[2]) > half - 0.6) return;
    // The body must fit.
    const r: f32 = 0.34;
    if (overlaps(p - v3(r, -0.05, r), p + v3(r, 1.75, r))) return;
    cover_points[cover_count] = .{ .pos = p, .box = box, .out = out };
    cover_count += 1;
}

/// Points along each side of each tall box, and one past each end of the
/// side: there a bot steps out to fire.
fn buildCoverPoints() void {
    cover_count = 0;
    for (boxes[0..box_count], 0..) |b, i| {
        if (!b.tall) continue;
        const c: [3]f32 = (b.min + b.max) * vec.s(0.5);
        const hs: [3]f32 = (b.max - b.min) * vec.s(0.5);
        // The four sides: the normal axis and the sign.
        for ([_]struct { usize, f32 }{ .{ 0, -1 }, .{ 0, 1 }, .{ 2, -1 }, .{ 2, 1 } }) |side| {
            const ax = side[0];
            const along: usize = if (ax == 0) 2 else 0;
            var out_a: [3]f32 = .{ 0, 0, 0 };
            out_a[ax] = side[1];
            const out: V3 = out_a;
            const n_along: usize = if (hs[along] > 1.0) 3 else 1;
            for (0..n_along + 2) |k| {
                // k 0 and k n+1: past the ends of the side.
                const f: f32 = if (k == 0) -1.0 - 0.9 / hs[along] else if (k == n_along + 1) 1.0 + 0.9 / hs[along] else if (n_along == 1) 0 else -0.6 + 1.2 * @as(f32, @floatFromInt(k - 1)) / @as(f32, @floatFromInt(n_along - 1));
                var p = c;
                p[1] = 0;
                p[ax] += side[1] * (hs[ax] + cover_gap);
                p[along] += f * hs[along];
                addCover(p, i, out);
            }
        }
    }
}

// ---- The height map of the snow ---------------------------------------------

pub const map_cells: u32 = 104;
pub const map_cell: f32 = 0.5;
pub const map_origin: f32 = -26;
pub var heights: [map_cells * map_cells]f32 = undefined;

fn buildHeights() void {
    for (0..map_cells) |z| {
        for (0..map_cells) |x| {
            const wx = map_origin + (@as(f32, @floatFromInt(x)) + 0.5) * map_cell;
            const wz = map_origin + (@as(f32, @floatFromInt(z)) + 0.5) * map_cell;
            var h: f32 = 0;
            for (boxes[0..box_count]) |b| {
                if (b.kind == .ground) continue;
                if (wx >= b.min[0] and wx <= b.max[0] and wz >= b.min[2] and wz <= b.max[2]) h = @max(h, b.max[1]);
            }
            heights[z * map_cells + x] = h;
        }
    }
}

/// The height of the top of the arena at (x, z): the snow line.
pub fn heightAt(x: f32, z: f32) f32 {
    const fx = (x - map_origin) / map_cell;
    const fz = (z - map_origin) / map_cell;
    if (fx < 0 or fz < 0) return 0;
    const ix: u32 = @intFromFloat(fx);
    const iz: u32 = @intFromFloat(fz);
    if (ix >= map_cells or iz >= map_cells) return 0;
    return heights[iz * map_cells + ix];
}

test "arena: the spawns are free, and each cover point is beside a tall box (REQ-DEMO-020)" {
    build();
    const r: f32 = 0.34;
    const p = player_spawn.pos;
    try std.testing.expect(!overlaps(p - v3(r, -0.05, r), p + v3(r, 1.75, r)));
    for (bot_spawns) |s| try std.testing.expect(!overlaps(s - v3(r, -0.05, r), s + v3(r, 1.75, r)));
    try std.testing.expect(cover_count > 40);
    for (cover_points[0..cover_count]) |c| try std.testing.expect(boxes[c.box].tall);
    // The ground stops a ray down, at height 0.
    const h = raycast(v3(3, 5, 3), v3(0, -1, 0), 10).?;
    try std.testing.expectApproxEqAbs(@as(f32, 5), h.t, 1e-4);
    try std.testing.expectEqual(@as(?f32, 0), floorTop(v3(2.6, -0.4, 2.6), v3(3.4, 0.4, 3.4)));
}
