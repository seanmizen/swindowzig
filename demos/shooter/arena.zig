// The snowy arena of the shooter: a square yard with walls, wooden crates,
// concrete blocks and steel posts on snow. This file has the layout, the
// collision of a body with the boxes, the ray cast of a shot, the cover
// points of the bots and the height map that stops the snow.
const std = @import("std");
const sw_math = @import("sw_math");
const sw_render = @import("sw_render");

const Vec3 = sw_math.Vec3;
const Aabb = sw_math.Aabb;
const Ray = sw_math.Ray;

pub const Material = enum { snow, wood, concrete, metal, bot };

pub const Box = struct {
    min: [3]f32,
    max: [3]f32,
    material: Material,
};

/// The half size of the yard inside the walls.
pub const half: f32 = 22;
const wall_h: f32 = 3.2;
const wall_t: f32 = 0.6;

fn crate(x: f32, z: f32, s: f32, y: f32) Box {
    return .{ .min = .{ x - s / 2, y, z - s / 2 }, .max = .{ x + s / 2, y + s, z + s / 2 }, .material = .wood };
}

fn block(x: f32, z: f32, sx: f32, sz: f32, h: f32) Box {
    return .{ .min = .{ x - sx / 2, 0, z - sz / 2 }, .max = .{ x + sx / 2, h, z + sz / 2 }, .material = .concrete };
}

fn post(x: f32, z: f32) Box {
    return .{ .min = .{ x - 0.2, 0, z - 0.2 }, .max = .{ x + 0.2, 4.5, z + 0.2 }, .material = .metal };
}

pub const boxes = [_]Box{
    // The walls.
    .{ .min = .{ -half - wall_t, 0, -half - wall_t }, .max = .{ half + wall_t, wall_h, -half }, .material = .concrete },
    .{ .min = .{ -half - wall_t, 0, half }, .max = .{ half + wall_t, wall_h, half + wall_t }, .material = .concrete },
    .{ .min = .{ -half - wall_t, 0, -half }, .max = .{ -half, wall_h, half }, .material = .concrete },
    .{ .min = .{ half, 0, -half }, .max = .{ half + wall_t, wall_h, half }, .material = .concrete },
    // The cover near the player.
    crate(-3, 10, 1.2, 0),
    crate(4, 9, 1.2, 0),
    block(0, 6, 3.5, 0.6, 1.1),
    // The middle of the yard.
    crate(-7, 2, 1.4, 0),
    crate(-7, 2, 1.0, 1.4),
    crate(7, 1, 1.4, 0),
    block(-1, -2, 4, 0.6, 1.1),
    crate(2.5, -5, 1.2, 0),
    block(-10, -6, 0.6, 3.5, 1.1),
    block(10, -5, 0.6, 3.5, 1.1),
    // The far half, where the bots start.
    crate(-4, -10, 1.2, 0),
    crate(5, -11, 1.4, 0),
    crate(5, -11, 1.0, 1.4),
    block(0, -14, 5, 0.6, 1.2),
    crate(-12, -14, 1.2, 0),
    crate(13, -15, 1.2, 0),
    block(-6, -18, 0.6, 3, 1.1),
    block(7, -18, 0.6, 3, 1.1),
    // Steel posts.
    post(-14, 8),
    post(14, 8),
    post(-15, -9),
    post(15, -10),
};

pub fn aabb(b: Box) Aabb {
    return Aabb.init(v3(b.min), v3(b.max));
}

pub fn v3(a: [3]f32) Vec3 {
    return .{ .x = a[0], .y = a[1], .z = a[2] };
}

pub fn arr(v: Vec3) [3]f32 {
    return .{ v.x, v.y, v.z };
}

pub fn color(m: Material) [3]f32 {
    return switch (m) {
        .snow => .{ 0.82, 0.86, 0.92 },
        .wood => .{ 0.42, 0.27, 0.13 },
        .concrete => .{ 0.46, 0.47, 0.50 },
        .metal => .{ 0.20, 0.22, 0.26 },
        .bot => .{ 1, 0.5, 0.1 },
    };
}

/// A body: a box from `pos - (r, 0, r)` to `pos + (r, h, r)`.
pub const Body = struct {
    pos: [3]f32,
    vel: [3]f32 = .{ 0, 0, 0 },
    radius: f32 = 0.3,
    height: f32 = 1.75,
    on_ground: bool = true,

    fn boxAt(self: Body, p: [3]f32) Aabb {
        return Aabb.init(.{ .x = p[0] - self.radius, .y = p[1], .z = p[2] - self.radius }, .{ .x = p[0] + self.radius, .y = p[1] + self.height, .z = p[2] + self.radius });
    }

    /// Move by `vel * dt` with gravity, one axis at a time, and stop at
    /// each box and at the ground.
    pub fn step(self: *Body, dt: f32, gravity: f32) void {
        self.vel[1] -= gravity * dt;
        self.on_ground = false;
        for ([_]usize{ 0, 2, 1 }) |axis| {
            var p = self.pos;
            p[axis] += self.vel[axis] * dt;
            if (axis == 1 and p[1] < 0) {
                p[1] = 0;
                self.vel[1] = 0;
                self.on_ground = true;
            }
            const me = self.boxAt(p);
            for (boxes) |b| {
                const bb = aabb(b);
                if (!overlaps(me, bb)) continue;
                // Push out along this axis only.
                if (axis == 0) p[0] = if (self.vel[0] > 0) b.min[0] - self.radius - 1e-3 else b.max[0] + self.radius + 1e-3;
                if (axis == 2) p[2] = if (self.vel[2] > 0) b.min[2] - self.radius - 1e-3 else b.max[2] + self.radius + 1e-3;
                if (axis == 1) {
                    if (self.vel[1] <= 0) {
                        p[1] = b.max[1];
                        self.on_ground = true;
                    } else {
                        p[1] = b.min[1] - self.height - 1e-3;
                    }
                    self.vel[1] = 0;
                }
            }
            self.pos = p;
        }
    }
};

/// The two boxes overlap with a volume (a touch is not an overlap).
fn overlaps(a: Aabb, b: Aabb) bool {
    return a.min.x < b.max.x and a.max.x > b.min.x and a.min.y < b.max.y and a.max.y > b.min.y and a.min.z < b.max.z and a.max.z > b.min.z;
}

pub const Hit = struct {
    t: f32,
    point: [3]f32,
    normal: [3]f32,
    material: Material,
};

/// The first box or ground point on the ray, closer than `max`.
pub fn cast(origin: [3]f32, dir: [3]f32, max: f32) ?Hit {
    const ray = Ray.init(v3(origin), v3(dir));
    var best: ?Hit = null;
    for (boxes) |b| {
        const h = ray.intersectAabb(aabb(b)) orelse continue;
        if (h.t_enter <= 0 or h.t_enter > max) continue;
        if (best != null and h.t_enter >= best.?.t) continue;
        best = .{ .t = h.t_enter, .point = arr(ray.at(h.t_enter)), .normal = arr(h.normal), .material = b.material };
    }
    if (dir[1] < -1e-4) {
        const t = -origin[1] / dir[1];
        if (t > 0 and t <= max and (best == null or t < best.?.t)) {
            best = .{ .t = t, .point = .{ origin[0] + dir[0] * t, 0, origin[2] + dir[2] * t }, .normal = .{ 0, 1, 0 }, .material = .snow };
        }
    }
    return best;
}

/// True when nothing is between `a` and `b`.
pub fn clear(a: [3]f32, b: [3]f32) bool {
    const d: [3]f32 = .{ b[0] - a[0], b[1] - a[1], b[2] - a[2] };
    const l = @sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
    if (l < 1e-4) return true;
    const h = cast(a, .{ d[0] / l, d[1] / l, d[2] / l }, l) orelse return true;
    return h.t >= l - 0.05;
}

/// The cover points: next to each crate and block, on each side, at the
/// ground. The walls are not cover.
pub const cover_count = (boxes.len - 4) * 4;

pub fn coverPoint(i: usize) [3]f32 {
    const b = boxes[4 + i / 4];
    const c: [2]f32 = .{ (b.min[0] + b.max[0]) / 2, (b.min[2] + b.max[2]) / 2 };
    const hx = (b.max[0] - b.min[0]) / 2 + 0.55;
    const hz = (b.max[2] - b.min[2]) / 2 + 0.55;
    return switch (i % 4) {
        0 => .{ c[0] + hx, 0, c[1] },
        1 => .{ c[0] - hx, 0, c[1] },
        2 => .{ c[0], 0, c[1] + hz },
        else => .{ c[0], 0, c[1] - hz },
    };
}

/// The box of a cover point blocks the view from `from` to the point.
pub fn hidden(point: [3]f32, from: [3]f32) bool {
    return !clear(.{ point[0], 1.0, point[2] }, from);
}

pub fn inside(p: [3]f32) bool {
    if (@abs(p[0]) > half - 0.5 or @abs(p[2]) > half - 0.5) return false;
    for (boxes) |b| {
        if (p[0] > b.min[0] - 0.3 and p[0] < b.max[0] + 0.3 and p[2] > b.min[2] - 0.3 and p[2] < b.max[2] + 0.3) return false;
    }
    return true;
}

// =============================================================================
// The height map of the snow
// =============================================================================

pub const map_cells = 50;
pub const map_cell: f32 = 1.0;
pub var heights: [map_cells * map_cells]f32 = @splat(0);

pub fn buildHeightMap() void {
    for (0..map_cells) |z| for (0..map_cells) |x| {
        const wx = -25 + (@as(f32, @floatFromInt(x)) + 0.5) * map_cell;
        const wz = -25 + (@as(f32, @floatFromInt(z)) + 0.5) * map_cell;
        var h: f32 = 0;
        for (boxes) |b| {
            if (wx >= b.min[0] and wx <= b.max[0] and wz >= b.min[2] and wz <= b.max[2]) h = @max(h, b.max[1]);
        }
        heights[z * map_cells + x] = h;
    };
}

pub fn heightMap() sw_render.HeightMap {
    return .{ .origin = .{ -25, -25 }, .cell_size = map_cell, .width = map_cells, .depth = map_cells, .heights = &heights };
}

test "arena: a shot hits the first box, and the ground" {
    const h = cast(.{ 0, 0.5, 20 }, .{ 0, 0, -1 }, 100).?;
    try std.testing.expectEqual(Material.concrete, h.material);
    try std.testing.expectApproxEqAbs(@as(f32, 20 - 6.3), h.t, 1e-3);
    const g = cast(.{ 20, 2, 20 }, .{ 0, -1, 0 }, 100).?;
    try std.testing.expectEqual(Material.snow, g.material);
}

test "arena: a body stops at a crate and stands on the ground" {
    var b: Body = .{ .pos = .{ -3, 0, 12 }, .vel = .{ 0, 0, -4 } };
    for (0..120) |_| b.step(1.0 / 60.0, 20);
    try std.testing.expect(b.pos[2] >= 10.6 + 0.3 - 1e-3);
    try std.testing.expect(b.on_ground);
}
