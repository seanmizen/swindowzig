// Vertex lists and shape builders. Every shape is a triangle list in world
// space. The renderer uploads the lists as they are (no index buffer).
const std = @import("std");
const vec = @import("vec.zig");
const V3 = vec.V3;
const v3 = vec.v3;
const Mat4 = vec.Mat4;

pub const Vertex = extern struct {
    pos: [3]f32,
    nrm: [3]f32,
    col: [3]f32,
    mat: f32,
};

pub const Mesh = struct {
    verts: std.ArrayList(Vertex) = .empty,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Mesh {
        return .{ .alloc = alloc };
    }

    pub fn clear(self: *Mesh) void {
        self.verts.clearRetainingCapacity();
    }

    pub fn push(self: *Mesh, p: V3, n: V3, c: V3, mat: f32) void {
        self.verts.append(self.alloc, .{
            .pos = .{ p[0], p[1], p[2] },
            .nrm = .{ n[0], n[1], n[2] },
            .col = .{ c[0], c[1], c[2] },
            .mat = mat,
        }) catch {};
    }

    pub fn quad(self: *Mesh, a: V3, b: V3, c: V3, d: V3, n: V3, col: V3, mat: f32) void {
        self.push(a, n, col, mat);
        self.push(b, n, col, mat);
        self.push(c, n, col, mat);
        self.push(a, n, col, mat);
        self.push(c, n, col, mat);
        self.push(d, n, col, mat);
    }

    /// An axis-aligned box.
    pub fn box(self: *Mesh, mn: V3, mx: V3, col: V3, mat: f32) void {
        self.orientedBox(Mat4.identity(), mn, mx, col, mat);
    }

    /// A box from local min and max, transformed by `m`. `m` can shear the
    /// box (a sloped bar: map.slab): each face normal is at a right angle
    /// to the face, and points out of the box.
    pub fn orientedBox(self: *Mesh, m: Mat4, mn: V3, mx: V3, col: V3, mat: f32) void {
        var c: [8]V3 = undefined;
        for (0..8) |i| {
            const p = v3(
                if (i & 1 != 0) mx[0] else mn[0],
                if (i & 2 != 0) mx[1] else mn[1],
                if (i & 4 != 0) mx[2] else mn[2],
            );
            c[i] = vec.xform(m, p);
        }
        const ex = vec.xdir(m, v3(1, 0, 0));
        const ey = vec.xdir(m, v3(0, 1, 0));
        const ez = vec.xdir(m, v3(0, 0, 1));
        const nx = faceNormal(vec.cross(ey, ez), ex);
        const ny = faceNormal(vec.cross(ez, ex), ey);
        const nz = faceNormal(vec.cross(ex, ey), ez);
        self.quad(c[1], c[3], c[7], c[5], nx, col, mat);
        self.quad(c[0], c[4], c[6], c[2], -nx, col, mat);
        self.quad(c[2], c[6], c[7], c[3], ny, col, mat);
        self.quad(c[0], c[1], c[5], c[4], -ny, col, mat);
        self.quad(c[4], c[5], c[7], c[6], nz, col, mat);
        self.quad(c[0], c[2], c[3], c[1], -nz, col, mat);
    }

    /// A disc (a flat cylinder) along local Z, of radius r and thickness t,
    /// about the origin. A long thin disc is a cylinder segment: a rod, a
    /// round handrail, a post (map.rod). A disc of radius less than 0.1 m
    /// has 10 sides, a larger disc 20.
    pub fn disc(self: *Mesh, m: Mat4, r: f32, t: f32, col: V3, mat: f32) void {
        const seg: usize = if (r < 0.1) 10 else 20;
        const seg_f: f32 = @floatFromInt(seg);
        const nz = vec.norm(vec.xdir(m, v3(0, 0, 1)));
        for (0..seg) |i| {
            const a0 = @as(f32, @floatFromInt(i)) / seg_f * std.math.tau;
            const a1 = @as(f32, @floatFromInt(i + 1)) / seg_f * std.math.tau;
            const p0 = v3(@cos(a0) * r, @sin(a0) * r, 0);
            const p1 = v3(@cos(a1) * r, @sin(a1) * r, 0);
            const f = v3(0, 0, t / 2);
            self.push(vec.xform(m, f), nz, col, mat);
            self.push(vec.xform(m, p0 + f), nz, col, mat);
            self.push(vec.xform(m, p1 + f), nz, col, mat);
            self.push(vec.xform(m, -f), -nz, col, mat);
            self.push(vec.xform(m, p1 - f), -nz, col, mat);
            self.push(vec.xform(m, p0 - f), -nz, col, mat);
            const side = vec.norm(vec.xdir(m, v3(@cos((a0 + a1) / 2), @sin((a0 + a1) / 2), 0)));
            self.quad(vec.xform(m, p0 + f), vec.xform(m, p0 - f), vec.xform(m, p1 - f), vec.xform(m, p1 + f), side, col, mat);
        }
    }

    /// The unit normal along `n`, turned to the side of `out`.
    fn faceNormal(n: V3, out: V3) V3 {
        const u = vec.norm(n);
        return if (vec.dot(u, out) < 0) -u else u;
    }

    /// Copy vertices from a model, transformed by `m`. `filter` picks the
    /// part (rifle.bin part numbers), or null for all.
    pub fn model(self: *Mesh, src: []const Vertex, m: Mat4, filter: ?f32, mat_add: f32) void {
        for (src) |v| {
            if (filter) |f| if (v.mat != f) continue;
            const p = vec.xform(m, v3(v.pos[0], v.pos[1], v.pos[2]));
            const n = vec.xdir(m, v3(v.nrm[0], v.nrm[1], v.nrm[2]));
            self.push(p, n, v3(v.col[0], v.col[1], v.col[2]), mat_add);
        }
    }
};
