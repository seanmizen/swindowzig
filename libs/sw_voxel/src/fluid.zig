//! The fluid surface mesher (REQ-VOXEL-014, REQ-VOXEL-015, REQ-VOXEL-016).
//!
//! The content gives a fluid and a level for each block ID that is a fluid
//! (`content.fluid`). The mesher makes the faces of the fluid cells of a
//! chunk as quads of 4 `Vertex` values:
//!
//! - The top surface has a height at each corner. A corner height is the
//!   mean height of the 4 cells that touch the corner. A full cell has more
//!   weight, so the surface stays high next to a source. A cell with the
//!   same fluid above it has height 1, and then each corner that it touches
//!   has height 1.
//! - Two cells of the same fluid have no face between them. A full cube
//!   hides a face of a fluid cell.
//! - The texture of the top surface follows the flow. The flow goes from a
//!   high cell to a lower cell or to an open cell. The UVs turn so that the
//!   texture v axis points along the flow. A cell with no flow uses the
//!   still texture and the UVs of the cell.
//!
//! The greedy mesher does not mesh a fluid block: `models.isCube` is false
//! for it. The game draws the fluid quads in a separate pass, usually the
//! translucent pass, with no back-face cull: the player can see the top
//! surface from below. Each quad is two triangles (`quad_indices`), with
//! the corners counter-clockwise seen from the side that the face points
//! to.
//!
//! The technique follows the fluid mesher of horizon (MIT). No code of
//! horizon is in this file.
const std = @import("std");
const chunk_mod = @import("chunk.zig");
const content = @import("content.zig");
const model_mod = @import("model.zig");

const Chunk = chunk_mod.Chunk;
const BlockType = chunk_mod.BlockType;
const BlockGetter = chunk_mod.BlockGetter;
const CellLight = chunk_mod.CellLight;
const CHUNK_W = chunk_mod.CHUNK_W;
const CHUNK_H = chunk_mod.CHUNK_H;
const MIN_Y = chunk_mod.MIN_Y;
pub const Face = model_mod.Face;

/// The fluid of one block ID.
pub const Level = struct {
    /// The fluid, 1 to 255. Cells of the same fluid have no face between
    /// them, and their heights join.
    fluid: u8,
    /// The amount of fluid in the cell, 1 to `MAX_LEVEL`. `MAX_LEVEL` is a
    /// full cell, for example a source.
    level: u8,
};

/// The level of a full cell.
pub const MAX_LEVEL: u8 = 8;
/// The height of the surface of a full cell with no fluid above it. It is
/// less than 1, so the surface is below the top of a full cube next to it.
pub const SURFACE_HEIGHT: f32 = 0.875;
/// A cell height at or above this has 10 times the weight in a corner mean.
const HEAVY_HEIGHT: f32 = 0.8;

/// The fluid of each block ID, from the content. Null for a block that is
/// not a fluid.
const table: [256]?Level = blk: {
    @setEvalBranchQuota(100_000);
    var t: [256]?Level = @splat(null);
    for (@typeInfo(BlockType).@"enum".field_values) |v| {
        const block: BlockType = @fromBackingInt(v);
        if (content.fluid(block)) |l| {
            if (block == .air) @compileError("sw_voxel_content.fluid(.air) must be null");
            if (l.fluid == 0) @compileError("sw_voxel_content.fluid: the fluid must be 1 to 255");
            if (l.level == 0 or l.level > MAX_LEVEL) @compileError("sw_voxel_content.fluid: the level must be 1 to 8");
            t[v] = l;
        }
    }
    break :blk t;
};

/// True when the content gives one or more fluid blocks.
pub const any: bool = blk: {
    for (table) |l| if (l != null) break :blk true;
    break :blk false;
};

/// The fluid of `block`, or null.
pub inline fn levelOf(block: BlockType) ?Level {
    if (!any) return null;
    return table[@backingInt(block)];
}

/// True when `block` is a fluid.
pub inline fn isFluid(block: BlockType) bool {
    return levelOf(block) != null;
}

/// One corner of a fluid quad. 24 bytes.
pub const Vertex = extern struct {
    /// x and z in the chunk (0 to CHUNK_W), y in the world.
    pos: [3]f32,
    /// The texture position. 0 to 1 over the cell for the still texture.
    uv: [2]f32,
    /// Bits 0-7: the fluid. Bits 8-10: the face (`Face`). Bit 11: set when
    /// the quad uses the flow texture. Bits 16-19: the sky light, 0 to 15.
    /// Bits 20-23: the block light, 0 to 15.
    info: u32,

    pub fn fluid(v: Vertex) u8 {
        return @truncate(v.info);
    }
    pub fn face(v: Vertex) Face {
        return @fromBackingInt(@intCast(@as(u3, @truncate(v.info >> 8))));
    }
    pub fn flowing(v: Vertex) bool {
        return v.info >> 11 & 1 != 0;
    }
    pub fn sky(v: Vertex) u4 {
        return @truncate(v.info >> 16);
    }
    pub fn blockLight(v: Vertex) u4 {
        return @truncate(v.info >> 20);
    }
};

/// The indices of the two triangles of a quad, from its first vertex.
pub const quad_indices = [6]u16{ 0, 1, 2, 0, 2, 3 };

/// The fluid quads of one chunk: 4 vertices for each quad.
pub const Mesh = struct {
    allocator: std.mem.Allocator,
    vertices: std.ArrayList(Vertex) = .empty,

    pub fn init(allocator: std.mem.Allocator) Mesh {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Mesh) void {
        self.vertices.deinit(self.allocator);
    }

    pub fn quadCount(self: *const Mesh) usize {
        return self.vertices.items.len / 4;
    }

    /// The 4 vertices of quad `i`.
    pub fn quad(self: *const Mesh, i: usize) *const [4]Vertex {
        return self.vertices.items[i * 4 ..][0..4];
    }
};

/// The cells around one fluid cell. Out of the world (y) is air.
const Reader = struct {
    chunk: *const Chunk,
    getter: BlockGetter,
    world_ox: i32,
    world_oz: i32,

    fn block(r: Reader, lx: i32, ly: i32, lz: i32) BlockType {
        if (ly < 0 or ly >= CHUNK_H) return .air;
        if (lx >= 0 and lx < CHUNK_W and lz >= 0 and lz < CHUNK_W) return r.chunk.resolveBlockRaw(lx, ly, lz);
        return r.getter.getBlock(r.world_ox + lx, ly + MIN_Y, r.world_oz + lz);
    }

    fn light(r: Reader, lx: i32, ly: i32, lz: i32) CellLight {
        if (ly < 0) return .{ .sky = 0, .block = 0 };
        if (ly >= CHUNK_H) return .{ .sky = chunk_mod.MAX_SKYLIGHT, .block = 0 };
        if (lx >= 0 and lx < CHUNK_W and lz >= 0 and lz < CHUNK_W) {
            const x: u32 = @intCast(lx);
            const y: u32 = @intCast(ly);
            const z: u32 = @intCast(lz);
            return .{ .sky = r.chunk.skylight.get(x, y, z), .block = r.chunk.block_light.get(x, y, z) };
        }
        return r.getter.lightAt(r.world_ox + lx, ly + MIN_Y, r.world_oz + lz);
    }
};

/// True when `block` is a full cube: it hides a face of a fluid cell, and
/// it adds no height to a corner.
fn isCubeBlock(block: BlockType) bool {
    return @import("models.zig").isCube(block);
}

/// The height of the fluid `f` in a cell, for the corner heights:
/// 1 when the cell and the cell above have the fluid, the surface height
/// for the fluid alone, 0 for a cell with no fluid that is not a full cube,
/// and null for a full cube or another fluid (no part of the mean).
fn cellHeight(r: Reader, f: u8, lx: i32, ly: i32, lz: i32) ?f32 {
    const b = r.block(lx, ly, lz);
    if (levelOf(b)) |l| {
        if (l.fluid != f) return null;
        if (sameFluid(r.block(lx, ly + 1, lz), f)) return 1;
        return levelHeight(l.level);
    }
    if (isCubeBlock(b)) return null;
    return 0;
}

/// The surface height of a cell with `level`, with no fluid above it.
pub fn levelHeight(level: u8) f32 {
    return SURFACE_HEIGHT * @as(f32, @floatFromInt(level)) / @as(f32, @floatFromInt(MAX_LEVEL));
}

fn sameFluid(block: BlockType, f: u8) bool {
    const l = levelOf(block) orelse return false;
    return l.fluid == f;
}

/// The height of one corner of the top surface. `own` is the height of
/// the cell, `a` and `b` the heights of the two side cells at the corner,
/// and `diag` reads the diagonal cell. The diagonal counts only when one
/// side cell is open, so fluid does not leak around a wall corner.
fn cornerHeight(own: f32, a: ?f32, b: ?f32, diag: anytype) f32 {
    if ((a orelse 0) >= 1 or (b orelse 0) >= 1) return 1;
    var sum: f32 = 0;
    var weight: f32 = 0;
    const add = struct {
        fn f(s: *f32, w: *f32, h: ?f32) void {
            const v = h orelse return;
            const k: f32 = if (v >= HEAVY_HEIGHT) 10 else 1;
            s.* += v * k;
            w.* += k;
        }
    }.f;
    if (a != null or b != null) {
        const d = diag.get();
        if ((d orelse 0) >= 1) return 1;
        add(&sum, &weight, d);
    }
    add(&sum, &weight, own);
    add(&sum, &weight, a);
    add(&sum, &weight, b);
    return sum / weight;
}

/// The flow direction of a fluid cell in x and z, not normalized: the sum
/// of the drop to each side cell. A side cell with the same fluid gives
/// the difference of the heights. An open side cell gives the full height
/// of the cell. A full cube or another fluid gives nothing.
fn flowOf(r: Reader, f: u8, own: f32, lx: i32, ly: i32, lz: i32) [2]f32 {
    const sides = [4][2]i32{ .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 }, .{ 0, -1 } };
    var flow: [2]f32 = .{ 0, 0 };
    for (sides) |d| {
        const h = cellHeight(r, f, lx + d[0], ly, lz + d[1]) orelse continue;
        const drop = own - h;
        flow[0] += drop * @as(f32, @floatFromInt(d[0]));
        flow[1] += drop * @as(f32, @floatFromInt(d[1]));
    }
    return flow;
}

/// The UVs of the 4 corners of the top surface, in the corner order of the
/// top quad: (x, z), (x, z + 1), (x + 1, z + 1), (x + 1, z). With no flow,
/// the UVs of the still texture. With a flow, the cell UVs turned about the
/// centre so that the texture v axis points along the flow, at half scale
/// (the flow texture has the double size).
pub fn topUvs(flow: [2]f32) struct { uv: [4][2]f32, flowing: bool } {
    const corners = [4][2]f32{ .{ 0, 0 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 } };
    const len = @sqrt(flow[0] * flow[0] + flow[1] * flow[1]);
    if (len < 1e-4) return .{ .uv = corners, .flowing = false };
    // The unit flow is (c, s) in (x, z). A world offset (dx, dz) from the
    // centre maps to u = dx·s - dz·c (across the flow) and v = dx·c + dz·s
    // (along the flow), so v grows in the flow direction.
    const c = flow[0] / len;
    const s = flow[1] / len;
    var out: [4][2]f32 = undefined;
    for (corners, 0..) |p, i| {
        const dx = p[0] - 0.5;
        const dz = p[1] - 0.5;
        out[i] = .{ 0.5 + 0.5 * (dx * s - dz * c), 0.5 + 0.5 * (dx * c + dz * s) };
    }
    return .{ .uv = out, .flowing = true };
}

fn packInfo(f: u8, face: Face, flowing: bool, light: CellLight) u32 {
    return @as(u32, f) | @as(u32, @backingInt(face)) << 8 | @as(u32, @intFromBool(flowing)) << 11 |
        @as(u32, @min(light.sky, 15)) << 16 | @as(u32, @min(light.block, 15)) << 20;
}

fn maxLight(a: CellLight, b: CellLight) CellLight {
    return .{ .sky = @max(a.sky, b.sky), .block = @max(a.block, b.block) };
}

/// Mesh the fluid cells of `chunk`. `world_ox` and `world_oz` are the x and
/// z of local cell (0, 0) in the coordinates of `getter`, as for
/// `mesher.generateMeshWith`. The mesh reads at most 1 cell of each
/// neighbour chunk.
pub fn generate(chunk: *const Chunk, mesh: *Mesh, world_ox: i32, world_oz: i32, getter: BlockGetter) !void {
    mesh.vertices.clearRetainingCapacity();
    if (!any) return;
    const r: Reader = .{ .chunk = chunk, .getter = getter, .world_ox = world_ox, .world_oz = world_oz };
    for (&chunk.blocks.sections, 0..) |*sec, s| {
        const has = for (sec.palette()) |b| {
            if (isFluid(b)) break true;
        } else false;
        if (!has) continue;
        const y0: i32 = @intCast(s * 16);
        var y: i32 = y0;
        while (y < y0 + 16) : (y += 1) {
            var x: i32 = 0;
            while (x < CHUNK_W) : (x += 1) {
                var z: i32 = 0;
                while (z < CHUNK_W) : (z += 1) {
                    const l = levelOf(chunk.resolveBlockRaw(x, y, z)) orelse continue;
                    try meshCell(r, mesh, l.fluid, x, y, z);
                }
            }
        }
    }
}

/// The faces of the fluid cell at local (x, y, z).
fn meshCell(r: Reader, mesh: *Mesh, f: u8, x: i32, y: i32, z: i32) !void {
    const own = cellHeight(r, f, x, y, z).?;
    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(y + MIN_Y);
    const fz: f32 = @floatFromInt(z);

    // Corner heights: nw (x, z), sw (x, z + 1), se (x + 1, z + 1),
    // ne (x + 1, z). A cell under the same fluid is full.
    var h: [4]f32 = @splat(1);
    if (own < 1) {
        const n = cellHeight(r, f, x, y, z - 1);
        const so = cellHeight(r, f, x, y, z + 1);
        const e = cellHeight(r, f, x + 1, y, z);
        const w = cellHeight(r, f, x - 1, y, z);
        const Diag = struct {
            r: Reader,
            f: u8,
            x: i32,
            y: i32,
            z: i32,
            fn get(d: @This()) ?f32 {
                return cellHeight(d.r, d.f, d.x, d.y, d.z);
            }
        };
        h[0] = cornerHeight(own, n, w, Diag{ .r = r, .f = f, .x = x - 1, .y = y, .z = z - 1 });
        h[1] = cornerHeight(own, so, w, Diag{ .r = r, .f = f, .x = x - 1, .y = y, .z = z + 1 });
        h[2] = cornerHeight(own, so, e, Diag{ .r = r, .f = f, .x = x + 1, .y = y, .z = z + 1 });
        h[3] = cornerHeight(own, n, e, Diag{ .r = r, .f = f, .x = x + 1, .y = y, .z = z - 1 });
    }
    const light = maxLight(r.light(x, y, z), r.light(x, y + 1, z));

    // Top: no face under the same fluid, or under a full cube when the
    // surface reaches the top of the cell.
    const above = r.block(x, y + 1, z);
    if (!sameFluid(above, f) and !(isCubeBlock(above) and @min(@min(h[0], h[1]), @min(h[2], h[3])) >= 1)) {
        const t = topUvs(flowOf(r, f, own, x, y, z));
        const info = packInfo(f, .py, t.flowing, light);
        try mesh.vertices.appendSlice(mesh.allocator, &.{
            .{ .pos = .{ fx, fy + h[0], fz }, .uv = t.uv[0], .info = info },
            .{ .pos = .{ fx, fy + h[1], fz + 1 }, .uv = t.uv[1], .info = info },
            .{ .pos = .{ fx + 1, fy + h[2], fz + 1 }, .uv = t.uv[2], .info = info },
            .{ .pos = .{ fx + 1, fy + h[3], fz }, .uv = t.uv[3], .info = info },
        });
    }

    // Bottom.
    const below = r.block(x, y - 1, z);
    if (!sameFluid(below, f) and !isCubeBlock(below)) {
        const info = packInfo(f, .ny, false, r.light(x, y - 1, z));
        try mesh.vertices.appendSlice(mesh.allocator, &.{
            .{ .pos = .{ fx, fy, fz }, .uv = .{ 0, 0 }, .info = info },
            .{ .pos = .{ fx + 1, fy, fz }, .uv = .{ 1, 0 }, .info = info },
            .{ .pos = .{ fx + 1, fy, fz + 1 }, .uv = .{ 1, 1 }, .info = info },
            .{ .pos = .{ fx, fy, fz + 1 }, .uv = .{ 0, 1 }, .info = info },
        });
    }

    // Sides: from the bottom of the cell to the two corner heights of the
    // edge. Corners a and b are counter-clockwise seen from outside.
    const Side = struct { face: Face, d: [2]i32, a: [2]f32, b: [2]f32, ha: usize, hb: usize };
    const sides = [4]Side{
        .{ .face = .nz, .d = .{ 0, -1 }, .a = .{ 1, 0 }, .b = .{ 0, 0 }, .ha = 3, .hb = 0 },
        .{ .face = .pz, .d = .{ 0, 1 }, .a = .{ 0, 1 }, .b = .{ 1, 1 }, .ha = 1, .hb = 2 },
        .{ .face = .nx, .d = .{ -1, 0 }, .a = .{ 0, 0 }, .b = .{ 0, 1 }, .ha = 0, .hb = 1 },
        .{ .face = .px, .d = .{ 1, 0 }, .a = .{ 1, 1 }, .b = .{ 1, 0 }, .ha = 2, .hb = 3 },
    };
    for (sides) |sd| {
        const nb = r.block(x + sd.d[0], y, z + sd.d[1]);
        if (sameFluid(nb, f) or isCubeBlock(nb)) continue;
        const info = packInfo(f, sd.face, false, light);
        const ha = h[sd.ha];
        const hb = h[sd.hb];
        try mesh.vertices.appendSlice(mesh.allocator, &.{
            .{ .pos = .{ fx + sd.a[0], fy, fz + sd.a[1] }, .uv = .{ 0, 1 }, .info = info },
            .{ .pos = .{ fx + sd.b[0], fy, fz + sd.b[1] }, .uv = .{ 1, 1 }, .info = info },
            .{ .pos = .{ fx + sd.b[0], fy + hb, fz + sd.b[1] }, .uv = .{ 1, 1 - hb }, .info = info },
            .{ .pos = .{ fx + sd.a[0], fy + ha, fz + sd.a[1] }, .uv = .{ 0, 1 - ha }, .info = info },
        });
    }
}

// ---------------------------------------------------------------------------
// Tests. The test content has the fluids b21 (fluid 1, full), b22 (fluid 1,
// level 4), b23 (fluid 1, level 1) and b24 (fluid 2, full).
// ---------------------------------------------------------------------------

const testing = std.testing;
/// The world y of local y 70, the y of the test cells.
const Y70: f32 = 70 + MIN_Y;

/// Outside the chunk is air in full skylight.
const TestGetter = struct {
    fn block(_: *const anyopaque, _: i32, _: i32, _: i32) BlockType {
        return .air;
    }
    fn sky(_: *const anyopaque, _: i32, _: i32, _: i32) u8 {
        return chunk_mod.MAX_SKYLIGHT;
    }
    fn blockLight(_: *const anyopaque, _: i32, _: i32, _: i32) u8 {
        return 0;
    }
    const getter: BlockGetter = .{ .ctx = undefined, .getFn = block, .getSkylightFn = sky, .getBlockLightFn = blockLight };
};

fn blockNamed(comptime name: []const u8) BlockType {
    return @field(BlockType, name);
}

fn meshOf(chunk: *const Chunk) !Mesh {
    var mesh = Mesh.init(testing.allocator);
    errdefer mesh.deinit();
    try generate(chunk, &mesh, 0, 0, TestGetter.getter);
    return mesh;
}

fn countFace(mesh: *const Mesh, face: Face) usize {
    var n: usize = 0;
    for (0..mesh.quadCount()) |i| {
        if (mesh.quad(i)[0].face() == face) n += 1;
    }
    return n;
}

/// The normal of the quad from its first 3 corners: (b - a) × (c - a).
fn quadNormal(q: *const [4]Vertex) [3]f32 {
    const a = q[0].pos;
    const b = q[1].pos;
    const c = q[2].pos;
    const u = [3]f32{ b[0] - a[0], b[1] - a[1], b[2] - a[2] };
    const v = [3]f32{ c[0] - a[0], c[1] - a[1], c[2] - a[2] };
    return .{ u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0] };
}

const face_dirs = [6][3]f32{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 } };

test "the content gives a fluid and a level for each fluid block (REQ-VOXEL-014)" {
    try testing.expect(any);
    try testing.expectEqual(Level{ .fluid = 1, .level = 8 }, levelOf(blockNamed("b21")).?);
    try testing.expectEqual(Level{ .fluid = 1, .level = 4 }, levelOf(blockNamed("b22")).?);
    try testing.expectEqual(@as(?Level, null), levelOf(.air));
    try testing.expectEqual(@as(?Level, null), levelOf(blockNamed("solid")));
    // The greedy mesher does not mesh a fluid block, and a fluid does not
    // hide the face of a full cube.
    try testing.expect(!isCubeBlock(blockNamed("b21")));
}

test "one full fluid cell has 6 faces, and its top surface is at the surface height (REQ-VOXEL-014)" {
    var chunk = Chunk.init(testing.allocator);
    defer chunk.deinit();
    try chunk.setBlock(5, 70, 5, blockNamed("b21"));
    var mesh = try meshOf(&chunk);
    defer mesh.deinit();
    try testing.expectEqual(@as(usize, 6), mesh.quadCount());
    for (0..mesh.quadCount()) |i| {
        const q = mesh.quad(i);
        // Each quad faces the side of its face (counter-clockwise).
        const n = quadNormal(q);
        const d = face_dirs[@backingInt(q[0].face())];
        try testing.expect(n[0] * d[0] + n[1] * d[1] + n[2] * d[2] > 0);
        if (q[0].face() == .py) {
            // A lone cell: each corner is the mean of the cell (weight 10)
            // and 2 or 3 open cells (height 0).
            for (q) |v| try testing.expect(v.pos[1] > Y70 and v.pos[1] < Y70 + SURFACE_HEIGHT);
        }
    }
}

test "two cells of one fluid have no face between them, two fluids do (REQ-VOXEL-015)" {
    var chunk = Chunk.init(testing.allocator);
    defer chunk.deinit();
    try chunk.setBlock(5, 70, 5, blockNamed("b21"));
    try chunk.setBlock(6, 70, 5, blockNamed("b22"));
    var mesh = try meshOf(&chunk);
    defer mesh.deinit();
    // 2 cells: 12 faces minus the 2 faces between them.
    try testing.expectEqual(@as(usize, 10), mesh.quadCount());
    for (0..mesh.quadCount()) |i| {
        const q = mesh.quad(i);
        if (q[0].face() == .px) try testing.expect(q[0].pos[0] == 7);
        if (q[0].face() == .nx) try testing.expect(q[0].pos[0] == 5);
    }

    // Another fluid next to it: each cell keeps the face between them.
    try chunk.setBlock(6, 70, 5, blockNamed("b24"));
    var mesh2 = try meshOf(&chunk);
    defer mesh2.deinit();
    try testing.expectEqual(@as(usize, 12), mesh2.quadCount());

    // A column of one fluid: no face between the two cells, and the lower
    // cell has no top surface.
    try chunk.setBlock(6, 70, 5, .air);
    try chunk.setBlock(5, 71, 5, blockNamed("b21"));
    var mesh3 = try meshOf(&chunk);
    defer mesh3.deinit();
    try testing.expectEqual(@as(usize, 10), mesh3.quadCount());
    try testing.expectEqual(@as(usize, 1), countFace(&mesh3, .py));
    try testing.expectEqual(@as(usize, 1), countFace(&mesh3, .ny));
}

test "a full cube hides the faces of a fluid cell" {
    var chunk = Chunk.init(testing.allocator);
    defer chunk.deinit();
    try chunk.setBlock(5, 70, 5, blockNamed("b21"));
    for ([_][3]i32{ .{ 4, 70, 5 }, .{ 6, 70, 5 }, .{ 5, 70, 4 }, .{ 5, 70, 6 }, .{ 5, 69, 5 } }) |p| {
        try chunk.setBlock(p[0], p[1], p[2], .solid);
    }
    var mesh = try meshOf(&chunk);
    defer mesh.deinit();
    // A pool of one cell: only the top surface. The walls add no height,
    // so the surface is flat at the surface height.
    try testing.expectEqual(@as(usize, 1), mesh.quadCount());
    for (mesh.quad(0)) |v| try testing.expectApproxEqAbs(Y70 + SURFACE_HEIGHT, v.pos[1], 1e-5);
    try testing.expect(!mesh.quad(0)[0].flowing());
}

test "the corner heights go down from a full cell to a low cell (REQ-VOXEL-014)" {
    var chunk = Chunk.init(testing.allocator);
    defer chunk.deinit();
    // A channel in x with walls on both sides and a floor: full, level 4,
    // level 1.
    for (4..9) |x| {
        const xi: i32 = @intCast(x);
        try chunk.setBlock(xi, 69, 5, .solid);
        try chunk.setBlock(xi, 70, 4, .solid);
        try chunk.setBlock(xi, 70, 6, .solid);
    }
    try chunk.setBlock(4, 70, 5, .solid);
    try chunk.setBlock(8, 70, 5, .solid);
    try chunk.setBlock(5, 70, 5, blockNamed("b21"));
    try chunk.setBlock(6, 70, 5, blockNamed("b22"));
    try chunk.setBlock(7, 70, 5, blockNamed("b23"));
    var mesh = try meshOf(&chunk);
    defer mesh.deinit();
    try testing.expectEqual(@as(usize, 3), mesh.quadCount());
    var tops: [3]*const [4]Vertex = undefined;
    for (0..3) |i| {
        const q = mesh.quad(i);
        try testing.expectEqual(Face.py, q[0].face());
        tops[@intFromFloat(q[0].pos[0] - 5)] = q;
    }
    // The shared edge of two cells has the same height on both cells, so
    // no gap shows.
    try testing.expectEqual(tops[0][2].pos[1], tops[1][1].pos[1]);
    try testing.expectEqual(tops[0][3].pos[1], tops[1][0].pos[1]);
    // Each cell is lower at its +x edge than at its -x edge.
    for (tops) |q| try testing.expect(q[3].pos[1] < q[0].pos[1]);
    // The full cell keeps its -x edge at the surface height.
    try testing.expectApproxEqAbs(Y70 + SURFACE_HEIGHT, tops[0][0].pos[1], 1e-5);
}

test "a cell under the same fluid has a full top at its corners" {
    var chunk = Chunk.init(testing.allocator);
    defer chunk.deinit();
    // A low cell next to a column of fluid: its corners at the column are
    // at the top of the cell.
    try chunk.setBlock(5, 70, 5, blockNamed("b21"));
    try chunk.setBlock(5, 71, 5, blockNamed("b21"));
    try chunk.setBlock(6, 70, 5, blockNamed("b23"));
    var mesh = try meshOf(&chunk);
    defer mesh.deinit();
    for (0..mesh.quadCount()) |i| {
        const q = mesh.quad(i);
        if (q[0].face() != .py or q[0].pos[0] != 6) continue;
        try testing.expectEqual(Y70 + 1, q[0].pos[1]);
        try testing.expectEqual(Y70 + 1, q[1].pos[1]);
    }
}

test "the top UVs follow the flow direction (REQ-VOXEL-016)" {
    // No flow: the UVs of the cell.
    const still = topUvs(.{ 0, 0 });
    try testing.expect(!still.flowing);
    try testing.expectEqual([2]f32{ 0, 1 }, still.uv[1]);
    // For each flow direction, v grows along the flow: the corner that is
    // furthest along the flow has the largest v.
    const corners = [4][2]f32{ .{ 0, 0 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 } };
    for ([_][2]f32{ .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 }, .{ 0, -1 }, .{ 0.6, 0.8 } }) |flow| {
        const t = topUvs(flow);
        try testing.expect(t.flowing);
        for (0..4) |i| for (0..4) |j| {
            const di = corners[i][0] * flow[0] + corners[i][1] * flow[1];
            const dj = corners[j][0] * flow[0] + corners[j][1] * flow[1];
            if (di > dj + 1e-4) try testing.expect(t.uv[i][1] > t.uv[j][1]);
        };
        // The UVs stay a square of side 0.5 about the centre.
        const du = t.uv[1][0] - t.uv[0][0];
        const dv = t.uv[1][1] - t.uv[0][1];
        try testing.expectApproxEqAbs(@as(f32, 0.25), du * du + dv * dv, 1e-5);
    }
}

test "a cell next to a lower cell has a flowing top in the direction of the drop (REQ-VOXEL-016)" {
    var chunk = Chunk.init(testing.allocator);
    defer chunk.deinit();
    for (4..8) |x| {
        const xi: i32 = @intCast(x);
        try chunk.setBlock(xi, 69, 5, .solid);
        try chunk.setBlock(xi, 70, 4, .solid);
        try chunk.setBlock(xi, 70, 6, .solid);
    }
    try chunk.setBlock(4, 70, 5, .solid);
    try chunk.setBlock(7, 70, 5, .solid);
    try chunk.setBlock(5, 70, 5, blockNamed("b21"));
    try chunk.setBlock(6, 70, 5, blockNamed("b22"));
    var mesh = try meshOf(&chunk);
    defer mesh.deinit();
    for (0..mesh.quadCount()) |i| {
        const q = mesh.quad(i);
        if (q[0].pos[0] != 5) continue;
        try testing.expect(q[0].flowing());
        // The flow is +x: the +x corners (2, 3) have a larger v.
        try testing.expect(q[3].uv[1] > q[0].uv[1]);
        try testing.expect(q[2].uv[1] > q[1].uv[1]);
    }
}

test "the fluid light is the larger light of the cell and the cell above" {
    var chunk = Chunk.init(testing.allocator);
    defer chunk.deinit();
    try chunk.setBlock(5, 70, 5, blockNamed("b21"));
    try chunk.computeSkylight();
    var mesh = try meshOf(&chunk);
    defer mesh.deinit();
    for (0..mesh.quadCount()) |i| {
        const q = mesh.quad(i);
        if (q[0].face() == .py) try testing.expectEqual(@as(u4, 15), q[0].sky());
        try testing.expectEqual(@as(u8, 1), q[0].fluid());
    }
}
