//! The translucent block mesher (REQ-VOXEL-029).
//!
//! The content gives a colour with alpha for each block ID that is
//! translucent (`content.translucent`). The mesher makes the faces of the
//! translucent cells of a chunk as quads of 4 `Vertex` values, and the
//! centre of each quad:
//!
//! - Two cells of the same translucent block have no face between them.
//!   A full cube hides a face. Any other neighbour (air, a fluid, a model
//!   block, another translucent block) shows the face.
//! - The colour of a face is the block colour times the face shade and the
//!   light of the cell in front of the face. The alpha is the alpha of the
//!   block.
//! - The positions are in world space: x and z have the chunk origin
//!   added. The centre of each quad is in world space too. The game sorts
//!   the quads far to near by their centres (sw_render `Translucent`,
//!   REQ-GPU-023) and draws them after the opaque pass with the depth
//!   write off.
//!
//! `Vertex` has the layout of the vertex of sw_render `Translucent`
//! (`TranslucentVertex`): a position and a straight-alpha colour. sw_voxel
//! does not import sw_render. A game test checks the two layouts.
//!
//! The greedy mesher does not mesh a translucent block: `models.isCube` is
//! false for it.
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

/// The colour of each block ID, from the content. Null for a block that is
/// not translucent.
const table: [256]?[4]u8 = blk: {
    @setEvalBranchQuota(100_000);
    var t: [256]?[4]u8 = @splat(null);
    for (@typeInfo(BlockType).@"enum".field_values) |v| {
        const block: BlockType = @fromBackingInt(v);
        if (content.translucent(block)) |c| {
            if (block == .air) @compileError("sw_voxel_content.translucent(.air) must be null");
            if (content.fluid(block) != null) @compileError("sw_voxel_content: a translucent block must not be a fluid");
            t[v] = c;
        }
    }
    break :blk t;
};

/// True when the content gives one or more translucent blocks.
pub const any: bool = blk: {
    for (table) |c| if (c != null) break :blk true;
    break :blk false;
};

/// The colour of `block`, or null.
pub inline fn colorOf(block: BlockType) ?[4]u8 {
    if (!any) return null;
    return table[@backingInt(block)];
}

/// True when `block` is translucent.
pub inline fn isTranslucent(block: BlockType) bool {
    return colorOf(block) != null;
}

/// One corner of a translucent quad. 28 bytes: the layout of the vertex of
/// sw_render `Translucent`.
pub const Vertex = extern struct {
    /// The position in world space.
    pos: [3]f32,
    /// Straight alpha: the colour is not multiplied by the alpha.
    color: [4]f32,
};

/// The translucent quads of one chunk: 4 vertices and one centre for each
/// quad.
pub const Mesh = struct {
    allocator: std.mem.Allocator,
    vertices: std.ArrayList(Vertex) = .empty,
    centers: std.ArrayList([3]f32) = .empty,

    pub fn init(allocator: std.mem.Allocator) Mesh {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Mesh) void {
        self.vertices.deinit(self.allocator);
        self.centers.deinit(self.allocator);
    }

    pub fn quadCount(self: *const Mesh) usize {
        return self.centers.items.len;
    }

    /// The 4 vertices of quad `i`.
    pub fn quad(self: *const Mesh, i: usize) *const [4]Vertex {
        return self.vertices.items[i * 4 ..][0..4];
    }
};

/// The brightness of each face: the top is the brightest, the bottom the
/// darkest. The order is `Face`: px, nx, py, ny, pz, nz.
const face_shade = [6]f32{ 0.8, 0.8, 1.0, 0.6, 0.9, 0.9 };

/// The step to the neighbour of each face.
const face_dirs = [6][3]i32{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 } };

/// The 4 corners of each face of a unit cell, counter-clockwise seen from
/// the side that the face points to.
const face_corners = [6][4][3]f32{
    .{ .{ 1, 0, 0 }, .{ 1, 1, 0 }, .{ 1, 1, 1 }, .{ 1, 0, 1 } },
    .{ .{ 0, 0, 0 }, .{ 0, 0, 1 }, .{ 0, 1, 1 }, .{ 0, 1, 0 } },
    .{ .{ 0, 1, 0 }, .{ 0, 1, 1 }, .{ 1, 1, 1 }, .{ 1, 1, 0 } },
    .{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 1, 0, 1 }, .{ 0, 0, 1 } },
    .{ .{ 0, 0, 1 }, .{ 1, 0, 1 }, .{ 1, 1, 1 }, .{ 0, 1, 1 } },
    .{ .{ 0, 0, 0 }, .{ 0, 1, 0 }, .{ 1, 1, 0 }, .{ 1, 0, 0 } },
};

/// The light factor of a cell: the larger of the sky light (with a floor
/// of 0.05) and the block light, 0 to 1. The same curve as the voxel demo
/// shader.
pub fn lightFactor(light: CellLight) f32 {
    const sky: f32 = @as(f32, @floatFromInt(@min(light.sky, 15))) / 15.0;
    const blk: f32 = @as(f32, @floatFromInt(@min(light.block, 15))) / 15.0;
    return @max(0.05 + sky * 0.95, blk);
}

fn isCubeBlock(block: BlockType) bool {
    return @import("models.zig").isCube(block);
}

/// The cells around one translucent cell. Out of the world (y) is air.
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

/// Mesh the translucent cells of `chunk`. `world_ox` and `world_oz` are the
/// x and z of local cell (0, 0) in the coordinates of `getter`, as for
/// `mesher.generateMeshWith`. `origin` is the world x and z of local cell
/// (0, 0): the positions and the centres are in world space. The mesh
/// reads at most 1 cell of each neighbour chunk.
pub fn generate(chunk: *const Chunk, mesh: *Mesh, world_ox: i32, world_oz: i32, getter: BlockGetter, origin: [2]i32) !void {
    mesh.vertices.clearRetainingCapacity();
    mesh.centers.clearRetainingCapacity();
    if (!any) return;
    const r: Reader = .{ .chunk = chunk, .getter = getter, .world_ox = world_ox, .world_oz = world_oz };
    const ox: f32 = @floatFromInt(origin[0]);
    const oz: f32 = @floatFromInt(origin[1]);
    for (&chunk.blocks.sections, 0..) |*sec, s| {
        const has = for (sec.palette()) |b| {
            if (isTranslucent(b)) break true;
        } else false;
        if (!has) continue;
        const y0: i32 = @intCast(s * 16);
        var y: i32 = y0;
        while (y < y0 + 16) : (y += 1) {
            var x: i32 = 0;
            while (x < CHUNK_W) : (x += 1) {
                var z: i32 = 0;
                while (z < CHUNK_W) : (z += 1) {
                    const b = chunk.resolveBlockRaw(x, y, z);
                    const color = colorOf(b) orelse continue;
                    const base: [3]f32 = .{ ox + @as(f32, @floatFromInt(x)), @floatFromInt(y + MIN_Y), oz + @as(f32, @floatFromInt(z)) };
                    for (face_dirs, 0..) |d, f| {
                        const nb = r.block(x + d[0], y + d[1], z + d[2]);
                        if (nb == b or isCubeBlock(nb)) continue;
                        const k = face_shade[f] * lightFactor(r.light(x + d[0], y + d[1], z + d[2]));
                        const c: [4]f32 = .{
                            @as(f32, @floatFromInt(color[0])) / 255.0 * k,
                            @as(f32, @floatFromInt(color[1])) / 255.0 * k,
                            @as(f32, @floatFromInt(color[2])) / 255.0 * k,
                            @as(f32, @floatFromInt(color[3])) / 255.0,
                        };
                        for (face_corners[f]) |p| {
                            try mesh.vertices.append(mesh.allocator, .{ .pos = .{ base[0] + p[0], base[1] + p[1], base[2] + p[2] }, .color = c });
                        }
                        const p0 = face_corners[f][0];
                        const p2 = face_corners[f][2];
                        try mesh.centers.append(mesh.allocator, .{
                            base[0] + (p0[0] + p2[0]) * 0.5,
                            base[1] + (p0[1] + p2[1]) * 0.5,
                            base[2] + (p0[2] + p2[2]) * 0.5,
                        });
                    }
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Tests. The test content has the translucent block b25 (red, alpha 128).
// ---------------------------------------------------------------------------

const testing = std.testing;

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

fn b25() BlockType {
    return @field(BlockType, "b25");
}

fn quadNormal(q: *const [4]Vertex) [3]f32 {
    const a = q[0].pos;
    const b = q[1].pos;
    const c = q[2].pos;
    const u = [3]f32{ b[0] - a[0], b[1] - a[1], b[2] - a[2] };
    const v = [3]f32{ c[0] - a[0], c[1] - a[1], c[2] - a[2] };
    return .{ u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0] };
}

test "a translucent cell has 6 faces in world space, with a centre for each face (REQ-VOXEL-029)" {
    try testing.expect(any);
    try testing.expect(!isCubeBlock(b25()));
    var chunk = Chunk.init(testing.allocator);
    defer chunk.deinit();
    try chunk.setBlock(5, 70, 6, b25());
    var mesh = Mesh.init(testing.allocator);
    defer mesh.deinit();
    try generate(&chunk, &mesh, 0, 0, TestGetter.getter, .{ 32, -16 });
    try testing.expectEqual(@as(usize, 6), mesh.quadCount());
    try testing.expectEqual(@as(usize, 24), mesh.vertices.items.len);
    const y: f32 = 70 + MIN_Y;
    for (0..6) |i| {
        const q = mesh.quad(i);
        // Each face points out of the cell (counter-clockwise).
        const n = quadNormal(q);
        const d = face_dirs[i];
        try testing.expect(n[0] * @as(f32, @floatFromInt(d[0])) + n[1] * @as(f32, @floatFromInt(d[1])) + n[2] * @as(f32, @floatFromInt(d[2])) > 0);
        // The centre is the centre of the face, in world space.
        const c = mesh.centers.items[i];
        try testing.expectApproxEqAbs(@as(f32, 37.5) + 0.5 * @as(f32, @floatFromInt(d[0])), c[0], 1e-5);
        try testing.expectApproxEqAbs(y + 0.5 + 0.5 * @as(f32, @floatFromInt(d[1])), c[1], 1e-5);
        try testing.expectApproxEqAbs(@as(f32, -9.5) + 0.5 * @as(f32, @floatFromInt(d[2])), c[2], 1e-5);
        // Red, the alpha of the block.
        try testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), q[0].color[3], 1e-6);
        try testing.expectEqual(@as(f32, 0), q[0].color[1]);
    }
}

test "two cells of one translucent block have no face between them, a full cube hides a face (REQ-VOXEL-029)" {
    var chunk = Chunk.init(testing.allocator);
    defer chunk.deinit();
    try chunk.setBlock(5, 70, 5, b25());
    try chunk.setBlock(6, 70, 5, b25());
    try chunk.setBlock(5, 69, 5, .solid);
    var mesh = Mesh.init(testing.allocator);
    defer mesh.deinit();
    try generate(&chunk, &mesh, 0, 0, TestGetter.getter, .{ 0, 0 });
    // 12 faces, less the 2 faces between the cells, less the bottom on
    // the full cube.
    try testing.expectEqual(@as(usize, 9), mesh.quadCount());
    // The faces of a full cube next to a translucent block show: the
    // translucent block is not a cube for the greedy mesher.
    try testing.expect(!isCubeBlock(b25()));
}

test "the face colour has the face shade and the light of the cell in front" {
    try testing.expectEqual(@as(f32, 1), lightFactor(.{ .sky = 15, .block = 0 }));
    try testing.expectApproxEqAbs(@as(f32, 0.05), lightFactor(.{ .sky = 0, .block = 0 }), 1e-6);
    try testing.expectEqual(@as(f32, 1), lightFactor(.{ .sky = 0, .block = 15 }));
    var chunk = Chunk.init(testing.allocator);
    defer chunk.deinit();
    try chunk.setBlock(5, 70, 5, b25());
    var mesh = Mesh.init(testing.allocator);
    defer mesh.deinit();
    // No light in the chunk: the floor of 0.05, times the top shade 1.
    try generate(&chunk, &mesh, 0, 0, TestGetter.getter, .{ 0, 0 });
    try testing.expectApproxEqAbs(@as(f32, 0.05), mesh.quad(2)[0].color[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.05 * 0.6), mesh.quad(3)[0].color[0], 1e-5);
}
