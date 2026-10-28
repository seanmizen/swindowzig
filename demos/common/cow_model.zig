//! The cow of the demos: an original voxel model (REQ-DEMO-005).
//!
//! The model is made in code. The cow stands on a round turntable, and the
//! turntable sits on a round pedestal. One voxel is 1/16 of a model unit.
//! The coat is white with black patches. The patches are fixed ellipsoids,
//! so the model is the same on each run. The palette gives the colours, so
//! a palette swap changes no voxel.

const std = @import("std");
const voxel_mesh = @import("voxel_mesh.zig");

const Grid = voxel_mesh.Grid;

/// The size of one voxel in model units.
pub const voxel_size: f32 = 1.0 / 16.0;

/// The palette indices of the model.
pub const Color = struct {
    pub const coat: u8 = 1;
    pub const patch: u8 = 2;
    pub const pink: u8 = 3;
    pub const hoof: u8 = 4;
    pub const horn: u8 = 5;
    pub const eye: u8 = 6;
    pub const turntable: u8 = 7;
    pub const pedestal: u8 = 8;
    pub const ground: u8 = 9;
    pub const nostril: u8 = 10;
    pub const trim: u8 = 11;
};

pub const palette_size = 16;
pub const Palette = [palette_size][3]f32;

pub const PaletteId = enum { classic, highland, neon };

fn rgb(r: u8, g: u8, b: u8) [3]f32 {
    // sRGB to linear, with the 2.2 power curve.
    return .{
        std.math.pow(f32, @as(f32, @floatFromInt(r)) / 255.0, 2.2),
        std.math.pow(f32, @as(f32, @floatFromInt(g)) / 255.0, 2.2),
        std.math.pow(f32, @as(f32, @floatFromInt(b)) / 255.0, 2.2),
    };
}

/// The linear colours of a palette.
pub fn palette(id: PaletteId) Palette {
    var p: Palette = @splat(.{ 1, 0, 1 });
    p[0] = .{ 0, 0, 0 };
    switch (id) {
        .classic => {
            p[Color.coat] = rgb(236, 232, 224);
            p[Color.patch] = rgb(34, 32, 34);
            p[Color.pink] = rgb(226, 150, 160);
            p[Color.hoof] = rgb(70, 60, 52);
            p[Color.horn] = rgb(222, 206, 170);
            p[Color.eye] = rgb(20, 20, 24);
            p[Color.nostril] = rgb(120, 60, 70);
        },
        .highland => {
            p[Color.coat] = rgb(196, 112, 52);
            p[Color.patch] = rgb(238, 214, 168);
            p[Color.pink] = rgb(170, 110, 96);
            p[Color.hoof] = rgb(46, 36, 30);
            p[Color.horn] = rgb(240, 230, 200);
            p[Color.eye] = rgb(16, 12, 10);
            p[Color.nostril] = rgb(70, 40, 36);
        },
        .neon => {
            p[Color.coat] = rgb(60, 230, 210);
            p[Color.patch] = rgb(150, 40, 220);
            p[Color.pink] = rgb(255, 90, 170);
            p[Color.hoof] = rgb(250, 230, 60);
            p[Color.horn] = rgb(255, 255, 255);
            p[Color.eye] = rgb(10, 10, 30);
            p[Color.nostril] = rgb(40, 20, 80);
        },
    }
    p[Color.turntable] = rgb(150, 104, 66);
    p[Color.trim] = rgb(90, 62, 40);
    p[Color.pedestal] = rgb(132, 132, 140);
    p[Color.ground] = rgb(92, 128, 70);
    return p;
}

/// The size of the turning grid: the cow on its turntable.
pub const turning_size: [3]u32 = .{ 37, 30, 37 };
/// The height of the turntable, in voxels.
pub const turntable_height: i32 = 2;
/// The size of the pedestal grid.
pub const pedestal_size: [3]u32 = .{ 33, 8, 33 };
/// The top of the pedestal in model units: the turntable stands on it.
pub const pedestal_top: f32 = @as(f32, @floatFromInt(pedestal_size[1])) * voxel_size;

/// A patch of the coat: an ellipsoid in cow voxel space.
const Blob = struct { c: [3]f32, r: [3]f32 };

const patches = [_]Blob{
    .{ .c = .{ 7, 14, 1 }, .r = .{ 4.5, 3.5, 3 } },
    .{ .c = .{ 17, 11, 12 }, .r = .{ 5, 4, 3 } },
    .{ .c = .{ 13, 17, 6 }, .r = .{ 3, 2, 4 } },
    .{ .c = .{ 21, 15, 2 }, .r = .{ 2.5, 3, 2 } },
    .{ .c = .{ 4, 10, 11 }, .r = .{ 3, 3, 3 } },
    .{ .c = .{ 26, 19, 3 }, .r = .{ 3, 3, 2.5 } },
    .{ .c = .{ 20, 5, 10 }, .r = .{ 2, 3, 2 } },
};

fn inPatch(x: i32, y: i32, z: i32) bool {
    const p = [3]f32{ @floatFromInt(x), @floatFromInt(y), @floatFromInt(z) };
    for (patches) |b| {
        var s: f32 = 0;
        for (0..3) |i| {
            const d = (p[i] + 0.5 - b.c[i]) / b.r[i];
            s += d * d;
        }
        if (s <= 1) return true;
    }
    return false;
}

/// The cow in its own voxel space: x from the tail (0) to the nose (30),
/// y up from the hooves (0), z across (0 to 13). `ox`, `oy`, `oz` move it.
fn addCow(g: *Grid, ox: i32, oy: i32, oz: i32) void {
    const Box = struct { min: [3]i32, max: [3]i32, color: u8 };
    const parts = [_]Box{
        // The legs, with hooves.
        .{ .min = .{ 5, 2, 2 }, .max = .{ 8, 9, 5 }, .color = Color.coat },
        .{ .min = .{ 5, 2, 9 }, .max = .{ 8, 9, 12 }, .color = Color.coat },
        .{ .min = .{ 19, 2, 2 }, .max = .{ 22, 9, 5 }, .color = Color.coat },
        .{ .min = .{ 19, 2, 9 }, .max = .{ 22, 9, 12 }, .color = Color.coat },
        .{ .min = .{ 5, 0, 2 }, .max = .{ 8, 2, 5 }, .color = Color.hoof },
        .{ .min = .{ 5, 0, 9 }, .max = .{ 8, 2, 12 }, .color = Color.hoof },
        .{ .min = .{ 19, 0, 2 }, .max = .{ 22, 2, 5 }, .color = Color.hoof },
        .{ .min = .{ 19, 0, 9 }, .max = .{ 22, 2, 12 }, .color = Color.hoof },
        // The body.
        .{ .min = .{ 3, 8, 1 }, .max = .{ 24, 17, 13 }, .color = Color.coat },
        // The neck and the head.
        .{ .min = .{ 22, 12, 4 }, .max = .{ 25, 18, 10 }, .color = Color.coat },
        .{ .min = .{ 24, 13, 3 }, .max = .{ 29, 21, 11 }, .color = Color.coat },
        // The muzzle.
        .{ .min = .{ 29, 13, 4 }, .max = .{ 31, 17, 10 }, .color = Color.pink },
        // The udder and four teats.
        .{ .min = .{ 9, 6, 5 }, .max = .{ 13, 8, 9 }, .color = Color.pink },
        // The tail, and its tuft.
        .{ .min = .{ 2, 9, 6 }, .max = .{ 3, 16, 7 }, .color = Color.coat },
        .{ .min = .{ 1, 6, 5 }, .max = .{ 3, 9, 8 }, .color = Color.patch },
        // The ears.
        .{ .min = .{ 25, 18, 1 }, .max = .{ 27, 19, 3 }, .color = Color.coat },
        .{ .min = .{ 25, 18, 11 }, .max = .{ 27, 19, 13 }, .color = Color.coat },
        // The horns: up, then out.
        .{ .min = .{ 26, 21, 4 }, .max = .{ 27, 23, 5 }, .color = Color.horn },
        .{ .min = .{ 26, 21, 9 }, .max = .{ 27, 23, 10 }, .color = Color.horn },
        .{ .min = .{ 26, 22, 3 }, .max = .{ 27, 23, 4 }, .color = Color.horn },
        .{ .min = .{ 26, 22, 10 }, .max = .{ 27, 23, 11 }, .color = Color.horn },
    };
    for (parts) |b| {
        g.fill(.{ b.min[0] + ox, b.min[1] + oy, b.min[2] + oz }, .{ b.max[0] + ox, b.max[1] + oy, b.max[2] + oz }, b.color);
    }
    // Round the long edges of the body.
    for ([_]i32{ 3, 23 }) |x| {
        for ([_][2]i32{ .{ 8, 1 }, .{ 8, 12 }, .{ 16, 1 }, .{ 16, 12 } }) |yz| {
            g.set(x + ox, yz[0] + oy, yz[1] + oz, 0);
        }
    }
    var x: i32 = 3;
    while (x < 24) : (x += 1) {
        g.set(x + ox, 16 + oy, 1 + oz, 0);
        g.set(x + ox, 16 + oy, 12 + oz, 0);
    }
    // Teats under the udder.
    for ([_][2]i32{ .{ 9, 5 }, .{ 12, 5 }, .{ 9, 8 }, .{ 12, 8 } }) |xz| {
        g.set(xz[0] + ox, 5 + oy, xz[1] + oz, Color.pink);
    }
    // The patches of the coat.
    var z: i32 = 0;
    while (z < 14) : (z += 1) {
        var y: i32 = 0;
        while (y < 24) : (y += 1) {
            x = 0;
            while (x < 31) : (x += 1) {
                const p = [3]i32{ x + ox, y + oy, z + oz };
                if (g.get(p) == Color.coat and inPatch(x, y, z)) g.set(p[0], p[1], p[2], Color.patch);
            }
        }
    }
    // The eyes and the nostrils.
    g.set(28 + ox, 18 + oy, 3 + oz, Color.eye);
    g.set(28 + ox, 18 + oy, 10 + oz, Color.eye);
    g.set(30 + ox, 15 + oy, 5 + oz, Color.nostril);
    g.set(30 + ox, 15 + oy, 8 + oz, Color.nostril);
}

/// Fill a disc of radius `r` voxels round the grid centre in x and z.
fn disc(g: *Grid, y0: i32, y1: i32, r: f32, color: u8, rim: u8) void {
    const cx = @as(f32, @floatFromInt(g.size[0])) / 2.0;
    const cz = @as(f32, @floatFromInt(g.size[2])) / 2.0;
    var z: i32 = 0;
    while (z < g.size[2]) : (z += 1) {
        var x: i32 = 0;
        while (x < g.size[0]) : (x += 1) {
            const dx = @as(f32, @floatFromInt(x)) + 0.5 - cx;
            const dz = @as(f32, @floatFromInt(z)) + 0.5 - cz;
            const d = @sqrt(dx * dx + dz * dz);
            if (d > r) continue;
            const c = if (d > r - 1.2) rim else color;
            var y = y0;
            while (y < y1) : (y += 1) g.set(x, y, z, c);
        }
    }
}

/// The turning model: the turntable and the cow on it. The model origin is
/// the centre of the turntable base.
pub fn turning(allocator: std.mem.Allocator) !Grid {
    var g = try Grid.init(allocator, turning_size);
    errdefer g.deinit(allocator);
    disc(&g, 0, turntable_height, 18, Color.turntable, Color.trim);
    // The cow is 31 by 14 voxels: put its middle on the turntable centre.
    addCow(&g, 3, turntable_height, 12);
    return g;
}

pub const turning_origin: [3]f32 = .{ 18.5, 0, 18.5 };

/// The pedestal under the turntable. The model origin is the centre of its
/// base.
pub fn pedestal(allocator: std.mem.Allocator) !Grid {
    var g = try Grid.init(allocator, pedestal_size);
    errdefer g.deinit(allocator);
    disc(&g, 0, 1, 16.5, Color.trim, Color.trim);
    disc(&g, 1, @intCast(pedestal_size[1]), 15, Color.pedestal, Color.pedestal);
    return g;
}

pub const pedestal_origin: [3]f32 = .{ 16.5, 0, 16.5 };

const testing = std.testing;

test "cow model: the same voxels on each build, with each colour (REQ-DEMO-005)" {
    var a = try turning(testing.allocator);
    defer a.deinit(testing.allocator);
    var b = try turning(testing.allocator);
    defer b.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, a.cells, b.cells);
    var seen: [palette_size]bool = @splat(false);
    for (a.cells) |c| seen[c] = true;
    for ([_]u8{ Color.coat, Color.patch, Color.pink, Color.hoof, Color.horn, Color.eye, Color.turntable, Color.nostril, Color.trim }) |c| {
        try testing.expect(seen[c]);
    }
    var p = try pedestal(testing.allocator);
    defer p.deinit(testing.allocator);
    try testing.expect(p.count() > 0);
}

test "cow model: greedy meshing gives fewer quads than naive meshing (REQ-DEMO-006)" {
    var g = try turning(testing.allocator);
    defer g.deinit(testing.allocator);
    var naive = try voxel_mesh.build(testing.allocator, g, .{ .mode = .naive });
    defer naive.deinit(testing.allocator);
    var greedy = try voxel_mesh.build(testing.allocator, g, .{ .mode = .greedy });
    defer greedy.deinit(testing.allocator);
    try testing.expect(greedy.quads * 2 < naive.quads);
}
