// The gun models: `assets/guns.bin`, the Quaternius "Ultimate Gun Pack"
// (CC0, `assets/guns-LICENSE.md`). The file and this reader come from
// Sean's own game code (seanorepo apps/action/game/src/weapon.zig). This
// reader keeps only the model part: no classes, no stats.
//
// Model space: the muzzle points to -Z, Y is up, the units are metres, and
// the origin is the grip.
//
// guns.bin layout (little endian):
//   "GUN1", u16 palette count P, u16 model count M
//   P x f32[3]      the albedo of each material
//   M x header:     u8[20] name, u16 V, u16 F, u16 R, u16 T, u8 has_mag,
//                   u8 0, f32[3] muzzle, f32 sight, f32[3] magazine pivot
//   for each model: V x i16[3] position * 8192, F x (u8 n, n x u16)
//                   faces, R x (u16 count, u8 material, u8 part) runs
const std = @import("std");
const mesh = @import("demo_common").mesh;

const guns_bin = @embedFile("assets/guns.bin");

pub const Model = struct {
    name: []const u8,
    /// The triangles of the model, with flat normals.
    vertices: []mesh.Vertex,
    muzzle: [3]f32,
    /// The y of the top of the sights.
    sight: f32,
    min: [3]f32,
    max: [3]f32,
};

fn rd(comptime T: type, b: []const u8, at: usize) T {
    return std.mem.readInt(T, b[at..][0..@sizeOf(T)], .little);
}

fn rf(b: []const u8, at: usize) f32 {
    return @bitCast(rd(u32, b, at));
}

fn rv(b: []const u8, at: usize) [3]f32 {
    return .{ rf(b, at), rf(b, at + 4), rf(b, at + 8) };
}

fn corner(p: []const u8, k: u16) [3]f32 {
    const o = @as(usize, k) * 6;
    return .{
        @as(f32, @floatFromInt(rd(i16, p, o))) / 8192,
        @as(f32, @floatFromInt(rd(i16, p, o + 2))) / 8192,
        @as(f32, @floatFromInt(rd(i16, p, o + 4))) / 8192,
    };
}

fn sub(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

fn cross(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

fn norm(a: [3]f32) [3]f32 {
    const l = @sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]);
    return if (l > 1e-9) .{ a[0] / l, a[1] / l, a[2] / l } else a;
}

/// Read the model with the name `name` from guns.bin. The caller frees
/// `vertices`.
pub fn load(allocator: std.mem.Allocator, name: []const u8) !Model {
    const b: []const u8 = guns_bin;
    if (!std.mem.eql(u8, b[0..4], "GUN1")) return error.BadGunFile;
    const np = rd(u16, b, 4);
    const nm = rd(u16, b, 6);
    const palette_at: usize = 8;
    const header_len = 20 + 8 + 2 + 28;
    const headers = palette_at + @as(usize, np) * 12;
    var at = headers + @as(usize, nm) * header_len;
    for (0..nm) |i| {
        const h = headers + i * header_len;
        const model_name = std.mem.sliceTo(b[h .. h + 20], 0);
        const nv = rd(u16, b, h + 20);
        const nf = rd(u16, b, h + 22);
        const nr = rd(u16, b, h + 24);
        const nt = rd(u16, b, h + 26);
        const pos = b[at .. at + @as(usize, nv) * 6];
        at += pos.len;
        // The faces come first, then the runs that give their materials.
        var runs = at;
        for (0..nf) |_| runs += 1 + 2 * @as(usize, b[runs]);
        const runs_end = runs + @as(usize, nr) * 4;
        if (!std.mem.eql(u8, model_name, name)) {
            at = runs_end;
            continue;
        }
        var m: Model = .{
            .name = model_name,
            .vertices = try allocator.alloc(mesh.Vertex, @as(usize, nt) * 3),
            .muzzle = rv(b, h + 30),
            .sight = rf(b, h + 42),
            .min = @splat(1e9),
            .max = @splat(-1e9),
        };
        errdefer allocator.free(m.vertices);
        var face = at;
        var out: usize = 0;
        for (0..nr) |r| {
            const count = rd(u16, b, runs + r * 4);
            const at_col = palette_at + @as(usize, b[runs + r * 4 + 2]) * 12;
            const col = rv(b, at_col);
            for (0..count) |_| {
                const n = b[face];
                const idx = b[face + 1 .. face + 1 + 2 * @as(usize, n)];
                face += 1 + 2 * @as(usize, n);
                const p0 = corner(pos, rd(u16, idx, 0));
                for (1..n - 1) |k| {
                    const p1 = corner(pos, rd(u16, idx, k * 2));
                    const p2 = corner(pos, rd(u16, idx, k * 2 + 2));
                    const nrm = norm(cross(sub(p1, p0), sub(p2, p0)));
                    for ([3][3]f32{ p0, p1, p2 }) |p| {
                        if (out >= m.vertices.len) return error.BadGunFile;
                        m.vertices[out] = .{ .pos = p, .normal = nrm, .color = col };
                        out += 1;
                        for (0..3) |j| {
                            m.min[j] = @min(m.min[j], p[j]);
                            m.max[j] = @max(m.max[j], p[j]);
                        }
                    }
                }
            }
        }
        if (face != runs or out != m.vertices.len) return error.BadGunFile;
        return m;
    }
    return error.NoSuchGun;
}

test "guns: the rifle model reads, and its muzzle is at -Z" {
    const m = try load(std.testing.allocator, "AssaultRifle_1");
    defer std.testing.allocator.free(m.vertices);
    try std.testing.expect(m.vertices.len > 100);
    try std.testing.expect(m.muzzle[2] < -0.2);
    try std.testing.expectError(error.NoSuchGun, load(std.testing.allocator, "Cannon"));
}
