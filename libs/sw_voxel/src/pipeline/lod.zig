//! Far terrain level of detail (REQ-VOXEL-021, REQ-VOXEL-022): the mesh of
//! a chunk at a lower resolution, as a pure stage (C2, P3).
//!
//! Level n has cells of 2^n blocks on each axis: level 1 is 2 × 2 × 2,
//! level 2 is 4 × 4 × 4 and level 3 is 8 × 8 × 8. Level 0 is the full mesh
//! (`stages.meshWith`).
//!
//! `coarsen` makes the blocks of a level. A coarse cell is a full cube when
//! one or more of its blocks is a full cube (`models.isCube`). It gets the
//! block of its highest full cube, so a grass surface stays grass. Each
//! block of the coarse cell gets that block. The greedy mesher then meshes
//! the coarse blocks as usual: each face is on the border of a coarse cell,
//! and a quad is 2^n blocks or more on each side. The quads have the
//! PackedQuad format, so the upload and the shader do not change.
//!
//! The border between two levels has no gap. The proof:
//!
//!   - The coarse blocks hold each full cube of the real blocks. So a coarse
//!     cell that is open is open in the real blocks too.
//!   - Each mesh reads the real blocks of its neighbours across the chunk
//!     border, at each level. It draws its border face when its own cell
//!     is a cube and the real cell across the border is open.
//!
//! Take a point of the border plane between chunk A and chunk B, each at
//! any level. When the two sides are both cubes or both open, no face is
//! necessary. When A is a cube and B is open (at the level of B), the
//! cell of B is open in the real blocks too, so A draws its face. The same
//! is true from B. A test checks this on the quads of two chunks, for each
//! pair of levels.
//!
//! A coarse surface can be above the real surface of the neighbour. Then
//! the coarse chunk draws the step between them as a skirt on its border.
//!
//! The light of a face is the light of the real cell in front of it. That
//! cell is open at the level of the mesh, so it is open in the real blocks,
//! and its light is correct.
const std = @import("std");
const chunk_mod = @import("../chunk.zig");
const models = @import("../models.zig");
const mesher_mod = @import("../mesher.zig");
const stages = @import("stages.zig");

const BlockType = chunk_mod.BlockType;
const PalettedBlocks = chunk_mod.PalettedBlocks;
const CHUNK_W = chunk_mod.CHUNK_W;
const CHUNK_H = chunk_mod.CHUNK_H;

/// The coarsest level: cells of 8 blocks.
pub const MAX_LEVEL: u8 = 3;

/// The merge cap of a coarse mesh. A coarse mesh has no AO and flat light,
/// so the greedy mesher can merge more faces. The cap of the full mesh is 6
/// (`mesher.MeshOptions.max_merge`).
pub const MAX_MERGE: i32 = 16;

/// The width of a cell of level `level`, in blocks.
pub fn cellWidth(level: u8) usize {
    std.debug.assert(level <= MAX_LEVEL);
    return @as(usize, 1) << @intCast(level);
}

/// The blocks of `blocks` at level `level`, into `out`. Level 0 copies the
/// blocks.
pub fn coarsen(blocks: *const PalettedBlocks, level: u8, out: *chunk_mod.DenseBlocks) void {
    const f = cellWidth(level);
    var x0: usize = 0;
    while (x0 < CHUNK_W) : (x0 += f) {
        var z0: usize = 0;
        while (z0 < CHUNK_W) : (z0 += f) {
            var y0: usize = 0;
            while (y0 < CHUNK_H) : (y0 += f) {
                const b = cellBlock(blocks, x0, y0, z0, f);
                for (x0..x0 + f) |x| for (y0..y0 + f) |y| for (z0..z0 + f) |z| {
                    out[x * (CHUNK_H * CHUNK_W) + y * CHUNK_W + z] = if (f == 1) blocks.getAt(x, y, z) else b;
                };
            }
        }
    }
}

/// The block of the coarse cell at (x0, y0, z0) of width f: the highest
/// full cube, or air. In a row, the lowest x and then the lowest z wins.
fn cellBlock(blocks: *const PalettedBlocks, x0: usize, y0: usize, z0: usize, f: usize) BlockType {
    var y = y0 + f;
    while (y > y0) {
        y -= 1;
        for (x0..x0 + f) |x| for (z0..z0 + f) |z| {
            const b = blocks.getAt(x, y, z);
            if (models.isCube(b)) return b;
        };
    }
    return .air;
}

/// The mesh of chunk (cx, cz), the middle chunk of `hood`, at level
/// `level`. Level 0 gives `stages.meshWith`. Above level 0, the middle chunk
/// has its coarse blocks, and the neighbours keep their real blocks. The
/// section connections are the connections of the real blocks
/// (REQ-VOXEL-019).
pub fn mesh(
    allocator: std.mem.Allocator,
    hood: *const stages.Neighbourhood,
    cx: i32,
    cz: i32,
    level: u8,
    options: stages.MeshOptions,
) !stages.MeshResult {
    if (level == 0) return stages.meshWith(allocator, hood, cx, cz, options);
    const dense = try allocator.create(chunk_mod.DenseBlocks);
    defer allocator.destroy(dense);
    coarsen(hood[stages.CENTER].blocks, level, dense);
    var coarse = try PalettedBlocks.fromDense(allocator, dense);
    defer coarse.deinit(allocator);
    var opts = options;
    opts.ao = .none;
    opts.smooth_light = false;
    opts.max_merge = MAX_MERGE;
    return stages.meshBlocks(allocator, hood, &coarse, cx, cz, opts);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

/// Two full cubes with no light emission, for the test terrain.
fn testCubes() [2]BlockType {
    var out: [2]BlockType = undefined;
    var n: usize = 0;
    for (std.enums.values(BlockType)) |b| {
        if (!models.isCube(b) or chunk_mod.emissionLevel(b) != 0) continue;
        out[n] = b;
        n += 1;
        if (n == 2) return out;
    }
    unreachable;
}

/// Uneven test terrain at chunk (cx, cz): a height field, with a cave under
/// it. The top block is cube 0, the blocks below are cube 1.
fn terrain(allocator: std.mem.Allocator, cx: i32, cz: i32) !PalettedBlocks {
    const cubes = testCubes();
    const dense = try allocator.create(chunk_mod.DenseBlocks);
    defer allocator.destroy(dense);
    @memset(dense, .air);
    for (0..CHUNK_W) |x| for (0..CHUNK_W) |z| {
        const wx = cx * CHUNK_W + @as(i32, @intCast(x));
        const wz = cz * CHUNK_W + @as(i32, @intCast(z));
        const h: usize = @intCast(40 + @mod(wx * wx * 3 + wz * 7 + wx * wz, 23));
        for (0..h) |y| {
            const cave = y > 20 and y < 26 and @mod(wx + wz, 9) < 4;
            if (!cave) dense[x * (CHUNK_H * CHUNK_W) + y * CHUNK_W + z] = if (y + 1 == h) cubes[0] else cubes[1];
        }
    };
    return PalettedBlocks.fromDense(allocator, dense);
}

/// The 3 × 3 chunks of the test terrain around (cx, cz), with light.
const TestHood = struct {
    blocks: [stages.SLOTS]PalettedBlocks,
    light: [stages.SLOTS]stages.ChunkLight,
    hood: stages.Neighbourhood,

    fn init(self: *TestHood, allocator: std.mem.Allocator, cx: i32, cz: i32) !void {
        // Each chunk of the hood needs its own 3 × 3 window for its light.
        // The test reads only the light of the middle chunk, and the mesh
        // reads at most stages.BORDER cells of a neighbour, so the
        // neighbours get the light of a window of the same terrain.
        for (0..stages.SLOTS) |s| {
            const dx, const dz = stages.offsetOf(s);
            self.blocks[s] = try terrain(allocator, cx + dx, cz + dz);
        }
        for (0..stages.SLOTS) |s| {
            const dx, const dz = stages.offsetOf(s);
            var around: [stages.SLOTS]PalettedBlocks = undefined;
            var window: stages.Window = undefined;
            for (0..stages.SLOTS) |t| {
                const ex, const ez = stages.offsetOf(t);
                around[t] = try terrain(allocator, cx + dx + ex, cz + dz + ez);
                window[t] = &around[t];
            }
            defer for (&around) |*b| b.deinit(allocator);
            self.light[s] = try stages.light(allocator, &window);
        }
        for (0..stages.SLOTS) |s| self.hood[s] = .{ .blocks = &self.blocks[s], .light = &self.light[s] };
    }

    fn deinit(self: *TestHood, allocator: std.mem.Allocator) void {
        for (&self.blocks) |*b| b.deinit(allocator);
        for (&self.light) |*l| l.deinit(allocator);
    }
};

test "lod: level 0 is the full mesh, and each level has fewer quads (REQ-VOXEL-021)" {
    const a = testing.allocator;
    var th: TestHood = undefined;
    try th.init(a, 0, 0);
    defer th.deinit(a);
    const options: stages.MeshOptions = .{ .ao = .none, .lighting = .skylight };
    var full = try stages.meshWith(a, &th.hood, 0, 0, options);
    defer full.deinit(a);
    var l0 = try mesh(a, &th.hood, 0, 0, 0, options);
    defer l0.deinit(a);
    try testing.expectEqualSlices(PackedQuad, full.quads, l0.quads);
    var last = full.quads.len;
    for (1..MAX_LEVEL + 1) |level| {
        var m = try mesh(a, &th.hood, 0, 0, @intCast(level), options);
        defer m.deinit(a);
        try testing.expect(m.quads.len > 0);
        try testing.expect(m.quads.len < last);
        last = m.quads.len;
        // Each quad of level n is on the border of a cell of level n.
        const f: u32 = @intCast(cellWidth(@intCast(level)));
        for (m.quads) |q| {
            if (mesher_mod.isTintRecord(q) or mesher_mod.isModelRecord(q)) continue;
            const face = (q[0] >> 16) & 7;
            const cell = [3]u32{ q[0] & 0xF, mesher_mod.cellY(q), (q[0] >> 12) & 0xF };
            const normal_axis: usize = face / 2;
            const positive = face % 2 == 0;
            const plane = cell[normal_axis] + @intFromBool(positive);
            try testing.expectEqual(@as(u32, 0), plane % f);
        }
    }
    // The coarse cell keeps the block of its highest cube: the top block.
    const dense = try a.create(chunk_mod.DenseBlocks);
    defer a.destroy(dense);
    coarsen(&th.blocks[stages.CENTER], 2, dense);
    var top_blocks: usize = 0;
    for (dense) |b| {
        if (b == testCubes()[0]) top_blocks += 1;
    }
    try testing.expect(top_blocks > 0);
}

const PackedQuad = stages.PackedQuad;

/// The cells of the plane x = 16 of chunk (0, 0) (x = 0 of chunk (1, 0))
/// that the quads of `m` cover with a face of direction `face`. The quads
/// of chunk (1, 0) have their x less 16.
fn coverX(m: []const PackedQuad, face: u32, cell_x: u32, out: *[CHUNK_H][CHUNK_W]bool) void {
    for (m) |q| {
        if (mesher_mod.isTintRecord(q) or mesher_mod.isModelRecord(q)) continue;
        if ((q[0] >> 16) & 7 != face or (q[0] & 0xF) != cell_x) continue;
        // px and nx: i is z (W), j is y (H).
        const w = ((q[0] >> 19) & 0xF) + 1;
        const h = ((q[0] >> 23) & 0xFF) + 1;
        const y0 = mesher_mod.cellY(q);
        const z0 = (q[0] >> 12) & 0xF;
        for (y0..y0 + h) |y| for (z0..z0 + w) |z| {
            out[y][z] = true;
        };
    }
}

/// True when the cube sides of the plane between chunk (0, 0) at
/// `level_a` and chunk (1, 0) at `level_b` have a face at each cell where
/// one side is a cube and the other side is open.
fn borderClosed(a: std.mem.Allocator, hood_a: *const TestHood, hood_b: *const TestHood, level_a: u8, level_b: u8) !bool {
    const options: stages.MeshOptions = .{ .ao = .none, .lighting = .skylight };
    var ma = try mesh(a, &hood_a.hood, 0, 0, level_a, options);
    defer ma.deinit(a);
    var mb = try mesh(a, &hood_b.hood, 1, 0, level_b, options);
    defer mb.deinit(a);
    // Face 0 is px, face 1 is nx (mesher face_layouts).
    var cover_a: [CHUNK_H][CHUNK_W]bool = @splat(@splat(false));
    var cover_b: [CHUNK_H][CHUNK_W]bool = @splat(@splat(false));
    coverX(ma.quads, 0, CHUNK_W - 1, &cover_a);
    coverX(mb.quads, 1, 0, &cover_b);
    const da = try a.create(chunk_mod.DenseBlocks);
    defer a.destroy(da);
    const db = try a.create(chunk_mod.DenseBlocks);
    defer a.destroy(db);
    coarsen(&hood_a.blocks[stages.CENTER], level_a, da);
    coarsen(&hood_b.blocks[stages.CENTER], level_b, db);
    for (0..CHUNK_H) |y| for (0..CHUNK_W) |z| {
        const cube_a = models.isCube(da[(CHUNK_W - 1) * (CHUNK_H * CHUNK_W) + y * CHUNK_W + z]);
        const cube_b = models.isCube(db[y * CHUNK_W + z]);
        if (cube_a and !cube_b and !cover_a[y][z]) return false;
        if (cube_b and !cube_a and !cover_b[y][z]) return false;
    };
    return true;
}

test "lod: no gap at the border between two levels (REQ-VOXEL-022)" {
    const a = testing.allocator;
    var hood_a: TestHood = undefined;
    try hood_a.init(a, 0, 0);
    defer hood_a.deinit(a);
    var hood_b: TestHood = undefined;
    try hood_b.init(a, 1, 0);
    defer hood_b.deinit(a);
    for (0..MAX_LEVEL + 1) |la| for (0..MAX_LEVEL + 1) |lb| {
        if (!try borderClosed(a, &hood_a, &hood_b, @intCast(la), @intCast(lb))) {
            std.debug.print("gap at the border of level {} and level {}\n", .{ la, lb });
            return error.TestUnexpectedResult;
        }
    };
}
