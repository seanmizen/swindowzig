//! The chunk stages: pure functions of a bounded neighbourhood (C2, P3).
//!
//!   generate(seed, config, cx, cz)  the blocks of one chunk, no light.
//!   light(window)                   the light of the middle chunk of a 3×3
//!                                   block window.
//!   mesh(neighbourhood)             the PackedQuad list and the y range of
//!                                   a chunk. It reads the blocks and the
//!                                   light of the chunk, and BORDER cells
//!                                   across each border.
//!
//! Each stage reads only its arguments. It has no World, no globals and no
//! state that stays between calls. It allocates its scratch memory from the
//! allocator argument and frees it before it returns. The caller owns the
//! result. So a stage gives the same bytes on the main thread, on a thread
//! pool and in a Web Worker, in any install order.
//!
//! Versions (C3): each chunk has a content version, and an edit increments
//! it. A job records the versions of its inputs (`Inputs`). The result can
//! be installed only when those versions are still current.
//!
//! The scheduler that uses these stages is not here (C1, C8).
const std = @import("std");
const chunk_mod = @import("../chunk.zig");
const mesher_mod = @import("../mesher.zig");
const world_gen = @import("../world_gen.zig");

const BlockType = chunk_mod.BlockType;
const PalettedBlocks = chunk_mod.PalettedBlocks;
const LightGrid = chunk_mod.LightGrid;
const DenseLight = chunk_mod.DenseLight;
const CHUNK_W = chunk_mod.CHUNK_W;
const CHUNK_H = chunk_mod.CHUNK_H;
const MAX_SKYLIGHT = chunk_mod.MAX_SKYLIGHT;
pub const PackedQuad = mesher_mod.PackedQuad;
pub const AOStrategy = mesher_mod.AOStrategy;
pub const LightingMode = mesher_mod.LightingMode;

// ---------------------------------------------------------------------------
// The 3×3 neighbourhood
// ---------------------------------------------------------------------------

/// Number of chunks in a 3×3 neighbourhood.
pub const SLOTS = 9;
/// Slot of the middle chunk.
pub const CENTER: usize = 4;

/// Slot of the chunk at offset (dcx, dcz) from the middle chunk, with dcx
/// and dcz in -1..1. Row-major: (dcz + 1) * 3 + (dcx + 1).
pub fn slot(dcx: i32, dcz: i32) usize {
    std.debug.assert(dcx >= -1 and dcx <= 1 and dcz >= -1 and dcz <= 1);
    return @intCast((dcz + 1) * 3 + (dcx + 1));
}

/// The (dcx, dcz) offset of slot `s`.
pub fn offsetOf(s: usize) struct { i32, i32 } {
    return .{ @as(i32, @intCast(s % 3)) - 1, @as(i32, @intCast(s / 3)) - 1 };
}

// ---------------------------------------------------------------------------
// Versions (C3)
// ---------------------------------------------------------------------------

/// A content version. Generation gives version 0. Each edit of the blocks of
/// a chunk increments its block version. Each install of a new light result
/// increments its light version.
pub const Version = u32;

pub const Stage = enum { generate, light, mesh };

/// The versions of the inputs of a job, by slot.
///
/// - generate: no versions. Its inputs are the seed, the config and (cx, cz).
/// - light: `blocks` holds the block versions of the 3×3 window.
/// - mesh: `blocks` holds the block versions of the 3×3 chunks, and `light`
///   holds their light versions.
pub const Inputs = struct {
    stage: Stage,
    cx: i32,
    cz: i32,
    blocks: [SLOTS]Version = @splat(0),
    light: [SLOTS]Version = @splat(0),

    /// True when the caller can install the result of the job with these
    /// inputs: each version that the job read is still the current version.
    /// `current` holds the current versions of the same chunks.
    pub fn isCurrent(self: Inputs, current: Inputs) bool {
        std.debug.assert(self.stage == current.stage and self.cx == current.cx and self.cz == current.cz);
        return switch (self.stage) {
            .generate => true,
            .light => std.mem.eql(Version, &self.blocks, &current.blocks),
            .mesh => std.mem.eql(Version, &self.blocks, &current.blocks) and
                std.mem.eql(Version, &self.light, &current.light),
        };
    }
};

// ---------------------------------------------------------------------------
// generate
// ---------------------------------------------------------------------------

/// The blocks of chunk (cx, cz) for `seed`, with no light. `seed` replaces
/// `config.seed`. The caller owns the result (deinit with `allocator`).
pub fn generate(
    allocator: std.mem.Allocator,
    seed: u64,
    config: world_gen.WorldGenConfig,
    cx: i32,
    cz: i32,
) !PalettedBlocks {
    var cfg = config;
    cfg.seed = seed;
    const dense = try allocator.create(chunk_mod.DenseBlocks);
    defer allocator.destroy(dense);
    chunk_mod.fillTerrain(dense, cx, cz, cfg);
    return PalettedBlocks.fromDense(allocator, dense);
}

// ---------------------------------------------------------------------------
// light
// ---------------------------------------------------------------------------

/// The light grids of one chunk. The caller owns them.
pub const ChunkLight = struct {
    sky: LightGrid = .{},
    block: LightGrid = .{},

    pub fn deinit(self: *ChunkLight, allocator: std.mem.Allocator) void {
        self.sky.deinit(allocator);
        self.block.deinit(allocator);
    }
};

/// The blocks of a 3×3 chunk neighbourhood, by `slot`. The input of `light`.
pub const Window = [SLOTS]*const PalettedBlocks;

/// How far light can travel: MAX_SKYLIGHT - 1 = 14 steps. A source further
/// away gives level 0 or less (P3).
pub const MARGIN: usize = MAX_SKYLIGHT - 1;
/// Width of the light window: 16 + 2 × 14 = 44 cells (C2).
pub const WINDOW_W: usize = CHUNK_W + 2 * MARGIN;
const WINDOW_CELLS: usize = WINDOW_W * WINDOW_W * CHUNK_H;
/// Index steps between window cells, in [x][y][z] order (z is contiguous).
const STEP_Y: usize = WINDOW_W;
const STEP_X: usize = WINDOW_W * CHUNK_H;

/// Index of window cell (x, y, z).
inline fn windowIdx(x: usize, y: usize, z: usize) u32 {
    return @intCast(x * STEP_X + y * STEP_Y + z);
}

/// The skylight and block light of the middle chunk of `window`.
///
/// It lights a window of 44 × 256 × 44 cells: the middle chunk and 14 cells
/// of each neighbour. The rules are the rules of `Chunk.computeSkylight` and
/// `Chunk.computeBlockLight`, on the whole window:
///
/// - Skylight: a cell with no solid block above it in its column is 15. A
///   solid cell is 0. Light spreads through air, 1 level less for each step.
/// - Block light: an emissive block has its emission level. Light spreads
///   through air, 1 level less for each step.
///
/// Light starts at 15 or less and loses 1 for each step. So the light that
/// reaches the middle chunk comes from a cell at most 14 steps away. A path
/// that leaves the window is at least 15 steps long. So the middle 16 cells
/// get the light of an unbounded world with the same 3×3 chunks (P3). Vertical light stays in its column.
///
/// It allocates about 4 MB of scratch memory and frees it before it returns.
/// `lightScratch` lets a caller keep the scratch memory between calls.
pub fn light(allocator: std.mem.Allocator, window: *const Window) !ChunkLight {
    const scratch = try allocator.create(LightScratch);
    defer allocator.destroy(scratch);
    return lightScratch(allocator, window, scratch);
}

/// `light`, with scratch memory from the caller. The result does not depend
/// on the contents of `scratch`: each call writes every scratch value that
/// it reads. A test checks this with scratch memory full of junk.
pub fn lightScratch(allocator: std.mem.Allocator, window: *const Window, scratch: *LightScratch) !ChunkLight {
    scratch.load(window);
    scratch.spread(&scratch.bl, scratch.emitters);
    scratch.spreadSkylight();

    var out: ChunkLight = .{};
    errdefer out.deinit(allocator);
    const dense = try allocator.create(DenseLight);
    defer allocator.destroy(dense);
    scratch.extract(&scratch.bl, 0, dense);
    try out.block.store(allocator, dense);
    scratch.extract(&scratch.sky, MAX_SKYLIGHT, dense);
    try out.sky.store(allocator, dense);
    return out;
}

/// The memory that one `light` call uses.
///
/// `light` computes only the rows below `y_hi`. At and above `y_hi`, no cell
/// of the window is solid, and each cell is more than 14 cells above every
/// emitter. So the skylight there is 15 and the block light is 0. The
/// breadth-first spread never changes a cell there.
pub const LightScratch = struct {
    /// The decoded cells of the 9 chunks, by slot, in `blockLinearIdx`
    /// order: SOLID and EMIT bits.
    flags: [SLOTS][chunk_mod.BLOCKS_PER_CHUNK]u8,
    /// Window cells, [x][y][z]: SOLID and EMIT bits.
    cells: [WINDOW_CELLS]u8,
    sky: [WINDOW_CELLS]u8,
    bl: [WINDOW_CELLS]u8,
    /// The y above the highest solid cell of each window column (x, z).
    top: [WINDOW_W * WINDOW_W]u16,
    /// Breadth-first queue. All the seeds of one channel have the same
    /// level. So the queue is in order of level, and a cell goes in at most
    /// one time for each channel.
    queue: [WINDOW_CELLS]u32,
    /// Number of block light seeds at the start of `queue`.
    emitters: usize,
    /// `light` computes the rows below this y.
    y_hi: usize,

    const SOLID: u8 = 1;
    const EMIT: u8 = 2;

    const flag_of = blk: {
        var t: [256]u8 = @splat(SOLID);
        t[@backingInt(BlockType.air)] = 0;
        for (std.enums.values(BlockType)) |b| {
            if (chunk_mod.emissionLevel(b) > 0) t[@backingInt(b)] |= EMIT;
        }
        break :blk t;
    };

    /// The window range of chunk offset `d` (-1, 0 or 1) on one axis, and
    /// the local coordinate of its first cell.
    fn axisRange(d: i32) struct { lo: usize, hi: usize, local0: usize } {
        return switch (d) {
            -1 => .{ .lo = 0, .hi = MARGIN, .local0 = CHUNK_W - MARGIN },
            0 => .{ .lo = MARGIN, .hi = MARGIN + CHUNK_W, .local0 = 0 },
            else => .{ .lo = MARGIN + CHUNK_W, .hi = WINDOW_W, .local0 = 0 },
        };
    }

    /// Decode the 9 chunks, find the column tops, `y_hi` and the emitters,
    /// and fill `cells` and `bl` below `y_hi`.
    fn load(self: *LightScratch, window: *const Window) void {
        var max_top: usize = 0;
        var max_emit: ?usize = null;
        self.emitters = 0;
        for (window, 0..) |pb, s| {
            const f = &self.flags[s];
            pb.decode(&flag_of, f);
            const dcx, const dcz = offsetOf(s);
            const rx = axisRange(dcx);
            const rz = axisRange(dcz);
            // Column tops: scan rows of 16 cells down from the top of the
            // chunk, until each column has a solid cell or y is 0.
            for (rx.lo..rx.hi) |wx| {
                const lx = rx.local0 + wx - rx.lo;
                var tops: [CHUNK_W]u16 = @splat(0);
                var found: u16 = 0;
                var y: usize = CHUNK_H;
                while (y > 0 and found != 0xFFFF) {
                    y -= 1;
                    const row = f[lx * CHUNK_H * CHUNK_W + y * CHUNK_W ..][0..CHUNK_W];
                    var new = rowMask(row, SOLID) & ~found;
                    found |= new;
                    while (new != 0) : (new &= new - 1) tops[@ctz(new)] = @intCast(y + 1);
                }
                for (rz.lo..rz.hi) |wz| {
                    const t = tops[rz.local0 + wz - rz.lo];
                    self.top[wx * WINDOW_W + wz] = t;
                    max_top = @max(max_top, t);
                }
            }
            // Emitters, only for a chunk with an emissive block in its palette.
            var any = false;
            for (pb.palette[0..pb.palette_len]) |b| any = any or chunk_mod.emissionLevel(b) > 0;
            if (!any) continue;
            for (rx.lo..rx.hi) |wx| {
                const lx = rx.local0 + wx - rx.lo;
                for (0..CHUNK_H) |y| {
                    const row = f[lx * CHUNK_H * CHUNK_W + y * CHUNK_W ..][0..CHUNK_W];
                    var emit = rowMask(row, EMIT);
                    while (emit != 0) : (emit &= emit - 1) {
                        const lz = @ctz(emit);
                        if (lz < rz.local0 or lz >= rz.local0 + (rz.hi - rz.lo)) continue;
                        self.queue[self.emitters] = windowIdx(wx, y, rz.lo + lz - rz.local0);
                        self.emitters += 1;
                        max_emit = @max(max_emit orelse 0, y);
                    }
                }
            }
        }
        self.y_hi = @min(CHUNK_H, @max(max_top + 1, if (max_emit) |e| e + MAX_SKYLIGHT + 1 else 0));

        // Window cells and block light below y_hi.
        for (window, 0..) |_, s| {
            const f = &self.flags[s];
            const dcx, const dcz = offsetOf(s);
            const rx = axisRange(dcx);
            const rz = axisRange(dcz);
            const len = rz.hi - rz.lo;
            for (rx.lo..rx.hi) |wx| {
                const lx = rx.local0 + wx - rx.lo;
                for (0..self.y_hi) |y| {
                    const src = f[lx * CHUNK_H * CHUNK_W + y * CHUNK_W + rz.local0 ..][0..len];
                    @memcpy(self.cells[windowIdx(wx, y, rz.lo)..][0..len], src);
                }
            }
        }
        for (0..WINDOW_W) |x| @memset(self.bl[x * STEP_X ..][0 .. self.y_hi * STEP_Y], 0);
        for (self.queue[0..self.emitters]) |i| {
            // All emitters have one level (see the comptime check below).
            self.bl[i] = chunk_mod.MAX_BLOCK_LIGHT;
        }
    }

    /// A mask with bit z set when `row[z]` has the bit `flag` (SOLID or EMIT).
    fn rowMask(row: *const [CHUNK_W]u8, flag: u8) u16 {
        const lo = std.mem.readInt(u64, row[0..8], .little);
        const hi = std.mem.readInt(u64, row[8..16], .little);
        const ones: u64 = 0x0101010101010101;
        const sel = ones * flag;
        if ((lo | hi) & sel == 0) return 0;
        // Move the flag bit of each byte to bit 0. The multiply then puts
        // bit 0 of byte i at bit 56 + i, with no carries.
        const shift: u6 = @ctz(flag);
        const gather: u64 = 0x0102040810204080;
        const m_lo = (((lo & sel) >> shift) *% gather) >> 56;
        const m_hi = (((hi & sel) >> shift) *% gather) >> 56;
        return @as(u16, @intCast(m_lo)) | (@as(u16, @intCast(m_hi)) << 8);
    }

    /// Spread from the first `start_tail` cells of the queue through air.
    fn spread(self: *LightScratch, grid: *[WINDOW_CELLS]u8, start_tail: usize) void {
        var head: usize = 0;
        var tail = start_tail;
        const y_hi = self.y_hi;
        while (head < tail) {
            const v: usize = self.queue[head];
            head += 1;
            const level = grid[v];
            if (level < 2) continue;
            const target = level - 1;
            const x = v / STEP_X;
            const y = (v / STEP_Y) % CHUNK_H;
            const z = v % WINDOW_W;
            var nb: [6]usize = undefined;
            var n: usize = 0;
            if (x > 0) {
                nb[n] = v - STEP_X;
                n += 1;
            }
            if (x + 1 < WINDOW_W) {
                nb[n] = v + STEP_X;
                n += 1;
            }
            if (z > 0) {
                nb[n] = v - 1;
                n += 1;
            }
            if (z + 1 < WINDOW_W) {
                nb[n] = v + 1;
                n += 1;
            }
            if (y > 0) {
                nb[n] = v - STEP_Y;
                n += 1;
            }
            if (y + 1 < y_hi) {
                nb[n] = v + STEP_Y;
                n += 1;
            }
            for (nb[0..n]) |i| {
                if (self.cells[i] & SOLID != 0) continue;
                if (grid[i] >= target) continue;
                grid[i] = target;
                self.queue[tail] = @intCast(i);
                tail += 1;
            }
        }
        std.debug.assert(tail <= WINDOW_CELLS);
    }

    fn spreadSkylight(self: *LightScratch) void {
        // Column seed: 15 at and above the top of the column, else 0.
        for (0..WINDOW_W) |x| for (0..self.y_hi) |y| {
            const row = self.sky[x * STEP_X + y * STEP_Y ..][0..WINDOW_W];
            const tops = self.top[x * WINDOW_W ..][0..WINDOW_W];
            for (row, tops) |*cell, t| cell.* = if (y >= t) MAX_SKYLIGHT else 0;
        };
        // Seeds: sky cells next to a column with a higher top. Only those
        // can have a shadowed air neighbour (see Chunk.computeSkylight).
        var tail: usize = 0;
        for (0..WINDOW_W) |x| for (0..WINDOW_W) |z| {
            const col = x * WINDOW_W + z;
            const t: usize = self.top[col];
            if (t >= CHUNK_H) continue;
            var hi: usize = t;
            if (x > 0) hi = @max(hi, self.top[col - WINDOW_W]);
            if (x + 1 < WINDOW_W) hi = @max(hi, self.top[col + WINDOW_W]);
            if (z > 0) hi = @max(hi, self.top[col - 1]);
            if (z + 1 < WINDOW_W) hi = @max(hi, self.top[col + 1]);
            for (t..@min(hi, CHUNK_H)) |y| {
                self.queue[tail] = windowIdx(x, y, z);
                tail += 1;
            }
        };
        self.spread(&self.sky, tail);
    }

    /// Copy the middle 16 × 256 × 16 cells of `grid` into `out`. Rows at and
    /// above `y_hi` get `above`.
    fn extract(self: *const LightScratch, grid: *const [WINDOW_CELLS]u8, above: u8, out: *DenseLight) void {
        for (0..CHUNK_W) |x| {
            for (0..self.y_hi) |y| out[x][y] = grid[windowIdx(x + MARGIN, y, MARGIN)..][0..CHUNK_W].*;
            for (self.y_hi..CHUNK_H) |y| out[x][y] = @splat(above);
        }
    }
};

comptime {
    // All emitters have one level, so the block light queue is in order.
    for (std.enums.values(BlockType)) |b| {
        const e = chunk_mod.emissionLevel(b);
        std.debug.assert(e == 0 or e == chunk_mod.MAX_BLOCK_LIGHT);
    }
}

// ---------------------------------------------------------------------------
// mesh
// ---------------------------------------------------------------------------

/// How far into a neighbour chunk the mesher reads: propagated AO samples
/// 3 cells outward from a face. A read further than this stops debug builds.
pub const BORDER: i32 = 3;

/// The blocks and the light of one chunk.
pub const ChunkData = struct {
    blocks: *const PalettedBlocks,
    light: *const ChunkLight,
};

/// A chunk and its 8 neighbours, by `slot`. The input of `mesh`. The mesh
/// reads the middle chunk, and only the cells of a neighbour that are
/// within BORDER cells of the middle chunk.
pub const Neighbourhood = [SLOTS]ChunkData;

/// The output of `mesh`. The caller owns `quads`.
pub const MeshResult = struct {
    quads: []PackedQuad,
    /// The y range of the quads. With no quads, y_min is CHUNK_H and y_max is 0.
    y_min: f32,
    y_max: f32,

    pub fn deinit(self: *MeshResult, allocator: std.mem.Allocator) void {
        allocator.free(self.quads);
        self.quads = &.{};
    }
};

/// The greedy mesh of the middle chunk of `hood`. The quads are relative to
/// the chunk origin, so the chunk coordinates are not an input.
pub fn mesh(
    allocator: std.mem.Allocator,
    hood: *const Neighbourhood,
    ao: AOStrategy,
    lighting: LightingMode,
) !MeshResult {
    const center = hood[CENTER];
    // A read-only Chunk value over the inputs. It owns nothing.
    const view: chunk_mod.Chunk = .{
        .allocator = allocator,
        .blocks = center.blocks.*,
        .skylight = center.light.sky,
        .block_light = center.light.block,
    };
    const getter: HoodGetter = .{ .view = &view, .hood = hood };
    var m = mesher_mod.Mesh.init(allocator);
    defer m.deinit();
    try mesher_mod.generateMesh(&view, &m, 0, 0, getter.asBlockGetter(), ao, lighting);
    return .{
        .quads = try m.quads.toOwnedSlice(allocator),
        .y_min = m.y_min,
        .y_max = m.y_max,
    };
}

/// A BlockGetter in the local coordinates of the middle chunk, backed by
/// the neighbourhood. Outside the world (y < 0 or y >= CHUNK_H) it gives
/// the values of World.
const HoodGetter = struct {
    view: *const chunk_mod.Chunk,
    hood: *const Neighbourhood,

    const Loc = union(enum) {
        center,
        cell: struct { data: *const ChunkData, x: i32, z: i32 },
        /// Past BORDER: the mesher reads further than the stage allows.
        outside,
    };

    fn locate(self: *const HoodGetter, x: i32, z: i32) Loc {
        const dcx = @divFloor(x, CHUNK_W);
        const dcz = @divFloor(z, CHUNK_W);
        if (dcx == 0 and dcz == 0) return .center;
        // The cell must be within BORDER cells of the middle chunk.
        if (x < -BORDER or x >= CHUNK_W + BORDER or z < -BORDER or z >= CHUNK_W + BORDER) return outside();
        return .{ .cell = .{ .data = &self.hood[slot(dcx, dcz)], .x = x - dcx * CHUNK_W, .z = z - dcz * CHUNK_W } };
    }

    /// Debug builds stop. Release builds read the cell as a missing chunk.
    fn outside() Loc {
        std.debug.assert(false);
        return .outside;
    }

    fn getBlock(ctx: *const anyopaque, x: i32, y: i32, z: i32) BlockType {
        const self: *const HoodGetter = @ptrCast(@alignCast(ctx));
        if (y < 0 or y >= CHUNK_H) return .air;
        return switch (self.locate(x, z)) {
            .center => self.view.resolveBlockRaw(x, y, z),
            .cell => |c| c.data.blocks.get(chunk_mod.blockLinearIdx(c.x, y, c.z)),
            .outside => chunk_mod.MISSING_BLOCK,
        };
    }

    fn getSkylight(ctx: *const anyopaque, x: i32, y: i32, z: i32) u8 {
        const self: *const HoodGetter = @ptrCast(@alignCast(ctx));
        if (y >= CHUNK_H) return MAX_SKYLIGHT;
        if (y < 0) return 0;
        return switch (self.locate(x, z)) {
            .center => self.view.getSkylight(x, y, z),
            .cell => |c| c.data.light.sky.get(@intCast(c.x), @intCast(y), @intCast(c.z)),
            .outside => chunk_mod.MISSING_SKYLIGHT,
        };
    }

    fn getBlockLight(ctx: *const anyopaque, x: i32, y: i32, z: i32) u8 {
        const self: *const HoodGetter = @ptrCast(@alignCast(ctx));
        if (y < 0 or y >= CHUNK_H) return 0;
        return switch (self.locate(x, z)) {
            .center => self.view.getBlockLight(x, y, z),
            .cell => |c| c.data.light.block.get(@intCast(c.x), @intCast(y), @intCast(c.z)),
            .outside => chunk_mod.MISSING_BLOCK_LIGHT,
        };
    }

    fn asBlockGetter(self: *const HoodGetter) chunk_mod.BlockGetter {
        return .{
            .ctx = self,
            .getFn = getBlock,
            .getSkylightFn = getSkylight,
            .getBlockLightFn = getBlockLight,
        };
    }
};
