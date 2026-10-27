const std = @import("std");
const clock = @import("clock.zig");
const content = @import("content.zig");
const section_mod = @import("section.zig");
pub const Section = section_mod.Section;

/// Horizontal (X/Z) edge length of a chunk, in blocks. Compile-time constant;
/// all chunk-sized allocations, index math, AABB extents, and the mesher's
/// inner loops reduce to this value plus `CHUNK_H` via constant folding, so
/// flipping it is a full rebuild but not a refactor.
///
/// History — this was 48 from the first commit (paired with `CHUNK_H = 256`,
/// giving 589 824 blocks per column). Sean asked "is 16×16 the right answer
/// instead?" on the voxel/chunk-size-perf branch — the investigation doc at
/// `examples/voxel/docs/chunk-size-investigation.md` walks through the
/// experiment that answered it. Change this one line, rebuild, rerun
/// `tests/flatland_forward.tas` with `--profile-csv` and the CSV reflects
/// the new size.
pub const CHUNK_W = 16;
/// Y dimension: the number of cells in a column. The content sets it
/// (`content.height`, default 256). A column is CHUNK_H / 16 sections.
pub const CHUNK_H: comptime_int = content.height;
/// The world y of local y 0. The content sets it (`content.min_y`, default
/// 0). Chunk, PalettedBlocks, LightGrid and the mesh cells use local y
/// (0 to CHUNK_H - 1). World, BlockGetter, the scheduler edits and the
/// mesh y range use world y: world y = local y + MIN_Y.
pub const MIN_Y: comptime_int = content.min_y;
/// Number of 16-cell sections in a column.
pub const SECTION_COUNT = CHUNK_H / section_mod.SIZE;
/// Number of u64 words in a bit column over y (`solidColumns`).
pub const COL_WORDS = (CHUNK_H + 63) / 64;
/// A bit column over y: bit y in word y / 64.
pub const Col = [COL_WORDS]u64;

comptime {
    std.debug.assert(CHUNK_W == section_mod.SIZE);
}

/// The block types of the game (`content.zig`). Value 0 is `.air`.
pub const BlockType = content.Block;

/// Maximum skylight level: a 4-bit (0..15) range. We store
/// it in a u8 right now because the engine doesn't yet care about packing
/// multiple light channels. See `examples/voxel/docs/lighting.md` for the
/// full reasoning.
pub const MAX_SKYLIGHT: u8 = 15;

/// What a BlockGetter returns for a cell in a chunk that is not loaded (or
/// not in a job's 3×3 grid). Every getter uses these, so a chunk meshes the
/// same through World (sync) and through SnapshotGetter (async). An unknown
/// neighbour is open air: full skylight, no block light, the same as the
/// space above the world.
pub const MISSING_BLOCK: BlockType = .air;
pub const MISSING_SKYLIGHT: u8 = MAX_SKYLIGHT;
pub const MISSING_BLOCK_LIGHT: u8 = 0;

/// Maximum block-light level. Same [0, 15] range as skylight; phase-3 block
/// light uses a parallel storage nibble and an independent BFS. See
/// `examples/voxel/docs/lighting.md` § phase 3 for the design.
pub const MAX_BLOCK_LIGHT: u8 = 15;

/// The emission level of a block, from the content (`content.emission`).
/// Blocks that give no light return 0. The BFS seed pass writes this value
/// into the `block_light` slot of each emissive cell before the light
/// spreads.
pub fn emissionLevel(block: BlockType) u8 {
    return content.emission(block);
}

/// Total blocks in a column.
pub const BLOCKS_PER_CHUNK: usize = CHUNK_W * CHUNK_H * CHUNK_W;

/// Flat linear index for a block position within a chunk: the index of
/// `DenseBlocks` and `PalettedBlocks.get`. y is local.
pub inline fn blockLinearIdx(x: i32, y: i32, z: i32) usize {
    return @as(usize, @intCast(x)) * (CHUNK_H * CHUNK_W) +
        @as(usize, @intCast(y)) * CHUNK_W +
        @as(usize, @intCast(z));
}

/// A cell of a chunk as one integer: its `blockLinearIdx`. The light queues
/// hold cells in this type (u16 for a 256-high column).
const CellId = std.math.IntFittingRange(0, BLOCKS_PER_CHUNK - 1);

inline fn cellId(x: usize, y: usize, z: usize) CellId {
    return @intCast(x * (CHUNK_H * CHUNK_W) + y * CHUNK_W + z);
}

inline fn cellXyz(v: CellId) [3]usize {
    const i: usize = v;
    return .{ i / (CHUNK_H * CHUNK_W), (i / CHUNK_W) % CHUNK_H, i % CHUNK_W };
}

/// The blocks of a chunk: a column of SECTION_COUNT paletted sections
/// (`section.zig`), from local y 0 upward. Section s holds local y 16 × s
/// to 16 × s + 15. Each section has its own palette and index width, so
/// open air above the terrain and solid rock below it are sections with
/// no index array.
///
/// The cell index of `get` and `set` is `blockLinearIdx`. `getAt` and
/// `setAt` take the local cell coordinates.
pub const PalettedBlocks = struct {
    sections: [SECTION_COUNT]Section = @splat(.{}),

    pub fn deinit(self: *PalettedBlocks, allocator: std.mem.Allocator) void {
        for (&self.sections) |*sec| sec.deinit(allocator);
    }

    /// Bytes of the block storage: the section structs and their heap
    /// arrays.
    pub fn sizeBytes(self: *const PalettedBlocks) usize {
        var n: usize = @sizeOf(PalettedBlocks);
        for (&self.sections) |*sec| n += sec.heapBytes();
        return n;
    }

    /// The largest palette of the sections.
    pub fn paletteLen(self: *const PalettedBlocks) usize {
        var n: usize = 0;
        for (&self.sections) |*sec| n = @max(n, sec.len);
        return n;
    }

    /// The largest index width of the sections.
    pub fn maxBits(self: *const PalettedBlocks) u8 {
        var n: u8 = 0;
        for (&self.sections) |*sec| n = @max(n, sec.bits);
        return n;
    }

    /// The block at local cell (x, y, z). The caller makes sure that the
    /// cell is in the chunk.
    pub inline fn getAt(self: *const PalettedBlocks, x: usize, y: usize, z: usize) BlockType {
        return self.sections[y >> 4].get(section_mod.cellIndex(x, y & 15, z));
    }

    /// The block at linear index `idx` (see `blockLinearIdx`).
    pub inline fn get(self: *const PalettedBlocks, idx: usize) BlockType {
        const x = idx / (CHUNK_H * CHUNK_W);
        const y = (idx / CHUNK_W) % CHUNK_H;
        return self.getAt(x, y, idx % CHUNK_W);
    }

    /// Set local cell (x, y, z). The section palette grows when the block
    /// type is new in the section, and then it can allocate.
    pub fn setAt(self: *PalettedBlocks, allocator: std.mem.Allocator, x: usize, y: usize, z: usize, block: BlockType) !void {
        try self.sections[y >> 4].set(allocator, section_mod.cellIndex(x, y & 15, z), block);
    }

    /// Set the block at linear index `idx` (see `blockLinearIdx`).
    pub fn set(self: *PalettedBlocks, allocator: std.mem.Allocator, idx: usize, block: BlockType) !void {
        const x = idx / (CHUNK_H * CHUNK_W);
        const y = (idx / CHUNK_W) % CHUNK_H;
        try self.setAt(allocator, x, y, idx % CHUNK_W, block);
    }

    /// Write `table[block]` for each cell into `out`, in `blockLinearIdx`
    /// order. The light stage (pipeline/stages.zig) reads its cells this
    /// way. Each section decodes in 16 runs of 256 cells.
    pub fn decode(self: *const PalettedBlocks, table: *const [256]u8, out: *[BLOCKS_PER_CHUNK]u8) void {
        for (&self.sections, 0..) |*sec, s| {
            sec.decodeRuns(table, out[s * section_mod.RUN ..].ptr, CHUNK_H * CHUNK_W);
        }
    }

    /// Pack a dense block buffer into sections, one pass for each section.
    /// `get` gives back each value of `dense`.
    pub fn fromDense(allocator: std.mem.Allocator, dense: *const DenseBlocks) !PalettedBlocks {
        var out: PalettedBlocks = .{};
        errdefer out.deinit(allocator);
        var cells: [section_mod.CELLS]BlockType = undefined;
        for (&out.sections, 0..) |*sec, s| {
            for (0..CHUNK_W) |x| {
                const src = dense[x * CHUNK_H * CHUNK_W + s * section_mod.RUN ..][0..section_mod.RUN];
                @memcpy(cells[x * section_mod.RUN ..][0..section_mod.RUN], src);
            }
            sec.* = try Section.fromCells(allocator, &cells);
        }
        return out;
    }
};

/// A dense block buffer for one chunk, indexed by `blockLinearIdx`.
/// `generateTerrain` writes into it, then packs it one time.
pub const DenseBlocks = [BLOCKS_PER_CHUNK]BlockType;

/// A dense light grid, [x][y][z]: what the light passes compute into.
pub const DenseLight = [CHUNK_W][CHUNK_H][CHUNK_W]u8;

/// True when bit y of column (x, z) of `cols` is set (see `solidColumns`).
inline fn isSolid(cols: *const [CHUNK_W][CHUNK_W]Col, x: usize, y: usize, z: usize) bool {
    return (cols[x][z][y >> 6] >> @intCast(y & 63)) & 1 != 0;
}

/// Pass 3 of `Chunk.computeSkylightWithNeighbors`: seed our edge cells from
/// the neighbours (order -X, +X, -Z, +Z), then spread. The seeds have mixed
/// levels, so the queue is not in level order. A cell can go in the queue
/// again when its light increases, and a bit set keeps each cell in the
/// queue at most once, so a ring of one entry per cell is enough.
fn seedSkylightFromNeighbours(
    sky: *DenseLight,
    solid: *const [CHUNK_W][CHUNK_W]Col,
    queue: *[BLOCKS_PER_CHUNK]CellId,
    nbs: [4]?*const Chunk,
) void {
    const N = BLOCKS_PER_CHUNK;
    const Ring = struct {
        queue: *[N]CellId,
        in_queue: [N / 64]u64 = @splat(0),
        head: usize = 0,
        count: usize = 0,

        fn push(r: *@This(), x: usize, y: usize, z: usize) void {
            const v = cellId(x, y, z);
            const bit = @as(u64, 1) << @intCast(v & 63);
            if (r.in_queue[v >> 6] & bit != 0) return;
            r.in_queue[v >> 6] |= bit;
            r.queue[(r.head + r.count) % N] = v;
            r.count += 1;
        }
        fn pop(r: *@This()) CellId {
            const v = r.queue[r.head];
            r.head = (r.head + 1) % N;
            r.count -= 1;
            r.in_queue[v >> 6] &= ~(@as(u64, 1) << @intCast(v & 63));
            return v;
        }
    };
    var ring = Ring{ .queue = queue };
    const W = CHUNK_W;
    for (nbs, 0..) |maybe_nb, side| {
        const nb = maybe_nb orelse continue;
        for (0..CHUNK_H) |y| for (0..W) |i| {
            // Our edge cell and the neighbour's cell across the border.
            const ours: [2]usize, const theirs: [2]usize = switch (side) {
                0 => .{ .{ 0, i }, .{ W - 1, i } },
                1 => .{ .{ W - 1, i }, .{ 0, i } },
                2 => .{ .{ i, 0 }, .{ i, W - 1 } },
                else => .{ .{ i, W - 1 }, .{ i, 0 } },
            };
            if (isSolid(solid, ours[0], y, ours[1])) continue;
            const nv = nb.skylight.get(theirs[0], y, theirs[1]);
            if (nv < 2 or sky[ours[0]][y][ours[1]] >= nv - 1) continue;
            sky[ours[0]][y][ours[1]] = nv - 1;
            ring.push(ours[0], y, ours[1]);
        };
    }

    while (ring.count > 0) {
        const x, const y, const z = cellXyz(ring.pop());
        const level = sky[x][y][z];
        if (level < 2) continue;
        const target = level - 1;
        const dirs = [6][3]i32{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 } };
        for (dirs) |d| {
            const nx = @as(i32, @intCast(x)) + d[0];
            const ny = @as(i32, @intCast(y)) + d[1];
            const nz = @as(i32, @intCast(z)) + d[2];
            if (nx < 0 or nx >= CHUNK_W or ny < 0 or ny >= CHUNK_H or nz < 0 or nz >= CHUNK_W) continue;
            const nxu: usize = @intCast(nx);
            const nyu: usize = @intCast(ny);
            const nzu: usize = @intCast(nz);
            if (isSolid(solid, nxu, nyu, nzu)) continue;
            if (sky[nxu][nyu][nzu] >= target) continue;
            sky[nxu][nyu][nzu] = target;
            ring.push(nxu, nyu, nzu);
        }
    }
}

/// Light values of a chunk, stored per 16-high section. A section where
/// every cell has the same value (open sky above the terrain, or no block
/// light) has no array, only that value. Most of a chunk is like that:
/// on hilly demo terrain 11 of 16 skylight sections, and all block light
/// when there is no emissive block. Values are the same as a dense grid: store a dense
/// grid, then get gives back each value.
pub const LightGrid = struct {
    pub const SECTION_H = 16;
    pub const SECTIONS = CHUNK_H / SECTION_H;
    const Cells = [CHUNK_W][SECTION_H][CHUNK_W]u8;

    /// Per section: the array, or null when every cell is `fill`.
    arrays: [SECTIONS]?*Cells = @splat(null),
    fill: [SECTIONS]u8 = @splat(0),

    pub inline fn get(self: *const LightGrid, x: usize, y: usize, z: usize) u8 {
        const s = y / SECTION_H;
        const arr = self.arrays[s] orelse return self.fill[s];
        return arr[x][y % SECTION_H][z];
    }

    /// Replace the values with `dense`. A section keeps its array when it
    /// still needs one, so a recompute does not allocate again.
    pub fn store(self: *LightGrid, allocator: std.mem.Allocator, dense: *const DenseLight) !void {
        for (0..SECTIONS) |s| {
            const y0 = s * SECTION_H;
            const v = dense[0][y0][0];
            var uniform = true;
            check: for (0..CHUNK_W) |x| for (y0..y0 + SECTION_H) |y| for (0..CHUNK_W) |z| {
                if (dense[x][y][z] != v) {
                    uniform = false;
                    break :check;
                }
            };
            if (uniform) {
                if (self.arrays[s]) |arr| allocator.destroy(arr);
                self.arrays[s] = null;
                self.fill[s] = v;
                continue;
            }
            const arr = self.arrays[s] orelse try allocator.create(Cells);
            self.arrays[s] = arr;
            for (0..CHUNK_W) |x| {
                @memcpy(std.mem.asBytes(&arr[x]), std.mem.asBytes(dense[x][y0..][0..SECTION_H]));
            }
        }
    }

    /// Write every value into `dense`.
    pub fn expand(self: *const LightGrid, dense: *DenseLight) void {
        for (0..SECTIONS) |s| {
            const y0 = s * SECTION_H;
            for (0..CHUNK_W) |x| {
                if (self.arrays[s]) |arr| {
                    @memcpy(std.mem.asBytes(dense[x][y0..][0..SECTION_H]), std.mem.asBytes(&arr[x]));
                } else {
                    @memset(std.mem.asBytes(dense[x][y0..][0..SECTION_H]), self.fill[s]);
                }
            }
        }
    }

    pub fn deinit(self: *LightGrid, allocator: std.mem.Allocator) void {
        for (&self.arrays) |*a| {
            if (a.*) |arr| allocator.destroy(arr);
            a.* = null;
        }
    }

    /// True when the two grids have the same value in each cell. `store`
    /// keeps an array only for a section that is not uniform, so a section
    /// with an array never equals a section without one.
    pub fn eql(a: *const LightGrid, b: *const LightGrid) bool {
        for (0..SECTIONS) |s| {
            const x = a.arrays[s];
            const y = b.arrays[s];
            if (x == null and y == null) {
                if (a.fill[s] != b.fill[s]) return false;
                continue;
            }
            if (x == null or y == null) return false;
            if (!std.mem.eql(u8, std.mem.asBytes(x.?), std.mem.asBytes(y.?))) return false;
        }
        return true;
    }

    /// A copy that owns its own arrays.
    pub fn clone(self: *const LightGrid, allocator: std.mem.Allocator) !LightGrid {
        var out: LightGrid = .{ .fill = self.fill };
        errdefer out.deinit(allocator);
        for (self.arrays, 0..) |a, s| {
            if (a) |arr| {
                const copy = try allocator.create(Cells);
                copy.* = arr.*;
                out.arrays[s] = copy;
            }
        }
        return out;
    }

    /// Heap bytes held by the section arrays.
    pub fn bytes(self: *const LightGrid) usize {
        var n: usize = 0;
        for (self.arrays) |a| {
            if (a != null) n += @sizeOf(Cells);
        }
        return n;
    }
};

pub const Chunk = struct {
    /// Allocator used for the paletted block data. Stored here so `setBlock`
    /// and `deinit` don't need to plumb one through every call site. The
    /// pointer overhead (~16 bytes) is trivial compared to what palette
    /// compression saves on the block storage.
    allocator: std.mem.Allocator,
    /// Palette-compressed block storage. Opaque — every caller must go
    /// through `getBlock`/`setBlock`/`resolveBlockRaw`.
    blocks: PalettedBlocks,
    /// Per-block skylight value, range [0, MAX_SKYLIGHT]. Computed by
    /// `computeSkylight()` after `generateTerrain()`. Solid blocks always
    /// store 0. Air blocks store the brightness of sunlight that reaches them
    /// after BFS propagation through air. `computeSkylight` lights the chunk
    /// on its own. `computeSkylightWithNeighbors` (called from `World`) adds
    /// the light that comes across the chunk borders.
    ///
    /// Stored per 16-high section (LightGrid): a section with one value,
    /// such as open sky, has no array.
    skylight: LightGrid,
    /// Per-block block-light value, range [0, MAX_BLOCK_LIGHT]. Computed by
    /// `computeBlockLight()` after `generateTerrain()` and again whenever a
    /// block is placed or removed. Unlike skylight, emissive blocks
    /// store their OWN emission level in this slot even though
    /// they are solid — this is what lets the mesher read a bright value for
    /// an emissive block's own face without the sample escaping to a dim outward
    /// air cell. Non-emissive solids and unlit air stay at 0.
    ///
    /// Phase-3 scope: per-chunk BFS only. An emissive block placed near a chunk
    /// edge will NOT push light into the neighbour chunk. The seam is small
    /// in practice because block light decays to 0 within 15 cells and
    /// emissive blocks are explicitly placed, but it is a documented limitation.
    block_light: LightGrid,

    pub fn init(allocator: std.mem.Allocator) Chunk {
        return .{
            .allocator = allocator,
            .blocks = PalettedBlocks{},
            .skylight = .{},
            .block_light = .{},
        };
    }

    pub fn deinit(self: *Chunk) void {
        self.blocks.deinit(self.allocator);
        self.skylight.deinit(self.allocator);
        self.block_light.deinit(self.allocator);
    }

    /// RAM used by this chunk's block storage (palette + packed data).
    /// Does NOT include the skylight grid — that's reported separately by
    /// `skylightBytes` because it's on a different optimization track.
    pub fn blockDataBytes(self: *const Chunk) usize {
        return self.blocks.sizeBytes();
    }

    /// RAM of the skylight and block-light section arrays (see LightGrid).
    pub fn skylightBytes(self: *const Chunk) usize {
        return self.skylight.bytes() + self.block_light.bytes();
    }

    /// Sum of block-data + skylight bytes. Roughly comparable to the
    /// pre-palette-compression 576 KB per-chunk figure in `docs/memory.md`,
    /// which counted only the raw `[W][H][W]BlockType` array. For an apples-
    /// to-apples comparison use `blockDataBytes` (ignoring the palette table
    /// overhead, which is a flat 256 bytes regardless of contents).
    pub fn totalBytes(self: *const Chunk) usize {
        return self.blockDataBytes() + self.skylightBytes();
    }

    /// The largest palette of the sections of this chunk. The per-chunk
    /// size log line reads it.
    pub fn paletteLen(self: *const Chunk) usize {
        return self.blocks.paletteLen();
    }

    /// The largest index width of the sections of this chunk.
    pub fn bitsPerEntry(self: *const Chunk) u8 {
        return self.blocks.maxBits();
    }

    /// The block at local cell (x, y, z), or `.air` outside the chunk.
    pub fn getBlock(self: *const Chunk, x: i32, y: i32, z: i32) BlockType {
        if (x < 0 or x >= CHUNK_W or y < 0 or y >= CHUNK_H or z < 0 or z >= CHUNK_W) {
            return .air;
        }
        return self.resolveBlockRaw(x, y, z);
    }

    /// Bounds-free block read. Caller MUST guarantee `0 <= x < CHUNK_W`,
    /// `0 <= y < CHUNK_H`, `0 <= z < CHUNK_W`. This is the fast path used
    /// by the mesher's in-chunk face-culling and AO sampling loops — the
    /// old code read `chunk.blocks[x][y][z]` directly there, so callers
    /// already have the bounds check inlined one level up. Marked `inline`
    /// so the compiler can fold it into the mesher's hot loops without an
    /// extra call.
    pub inline fn resolveBlockRaw(self: *const Chunk, x: i32, y: i32, z: i32) BlockType {
        return self.blocks.getAt(@intCast(x), @intCast(y), @intCast(z));
    }

    /// For each column (x, z), a bit mask over local y: bit y is set when
    /// the block is not air. It reads each section once in storage order,
    /// with no division per block, so it is much faster than a getBlock
    /// call for each cell. A section with one block type sets 16 bits of
    /// each column at a time.
    pub fn solidColumns(self: *const Chunk, out: *[CHUNK_W][CHUNK_W]Col) void {
        for (out) |*row| for (row) |*col| {
            col.* = @splat(0);
        };
        for (&self.blocks.sections, 0..) |*sec, s| {
            const y0 = s * section_mod.SIZE;
            const word = y0 >> 6;
            const shift: u6 = @intCast(y0 & 63);
            if (sec.bits == 0) {
                if (sec.single == .air) continue;
                for (out) |*row| for (row) |*col| {
                    col[word] |= @as(u64, 0xFFFF) << shift;
                };
                continue;
            }
            var solid: [256]bool = @splat(false);
            for (sec.palette(), 0..) |b, i| solid[i] = b != .air;
            switch (sec.bits) {
                inline 1, 2, 4, 8 => |bits| solidSectionBits(bits, sec, &solid, out, word, shift),
                else => unreachable,
            }
        }
    }

    fn solidSectionBits(
        comptime bits: u8,
        sec: *const Section,
        solid: *const [256]bool,
        out: *[CHUNK_W][CHUNK_W]Col,
        word: usize,
        shift: u6,
    ) void {
        const epw: usize = 64 / @as(usize, bits);
        const mask: u64 = (@as(u64, 1) << bits) - 1;
        for (sec.indices(), 0..) |packed_word, wi| {
            var w = packed_word;
            inline for (0..epw) |k| {
                if (solid[@intCast(w & mask)]) {
                    // Cell index = x * 256 + y * 16 + z (section.cellIndex).
                    const i = wi * epw + k;
                    out[i >> 8][i & 15][word] |= @as(u64, 1) << @intCast(shift + ((i >> 4) & 15));
                }
                w >>= bits;
            }
        }
    }

    pub fn setBlock(self: *Chunk, x: i32, y: i32, z: i32, block: BlockType) !void {
        if (x < 0 or x >= CHUNK_W or y < 0 or y >= CHUNK_H or z < 0 or z >= CHUNK_W) {
            return;
        }
        try self.blocks.setAt(self.allocator, @intCast(x), @intCast(y), @intCast(z), block);
    }

    /// Read the skylight at (x, y, z) using local chunk coordinates.
    /// Returns MAX_SKYLIGHT for any coordinate above the chunk top (so faces
    /// looking at the open sky stay bright) and 0 elsewhere out of bounds.
    /// The "bright above, dark elsewhere" asymmetry is what makes faces at
    /// the top of the world look right without a heightmap.
    pub fn getSkylight(self: *const Chunk, x: i32, y: i32, z: i32) u8 {
        if (y >= CHUNK_H) return MAX_SKYLIGHT; // above world top = open sky
        if (x < 0 or x >= CHUNK_W or y < 0 or z < 0 or z >= CHUNK_W) return 0;
        return self.skylight.get(@intCast(x), @intCast(y), @intCast(z));
    }

    /// Read the block-light at (x, y, z) using local chunk coordinates.
    /// Out-of-bounds returns 0 (no "above world" bright-side asymmetry — block
    /// light has no global seed like the sun). Light from a neighbour chunk
    /// is in this grid after `computeBlockLightWithNeighbors`.
    pub fn getBlockLight(self: *const Chunk, x: i32, y: i32, z: i32) u8 {
        if (x < 0 or x >= CHUNK_W or y < 0 or y >= CHUNK_H or z < 0 or z >= CHUNK_W) return 0;
        return self.block_light.get(@intCast(x), @intCast(y), @intCast(z));
    }

    /// Recompute skylight for the entire chunk from the current `blocks` array.
    /// Two-pass algorithm:
    ///
    ///   Pass 1 (column seed):
    ///     For each (x, z) column, walk downward from y=CHUNK_H-1. Every air
    ///     block sets skylight = MAX_SKYLIGHT until the first solid block.
    ///     Below that solid, every air block starts at skylight = 0.
    ///     Solid blocks always store 0.
    ///
    ///   Pass 2 (bucket-sort BFS, levels MAX_SKYLIGHT down to 2):
    ///     For each level L from MAX_SKYLIGHT down to 2, sweep the chunk and
    ///     for each air cell with skylight == L, propagate (L - 1) into any
    ///     air neighbour with a strictly lower current skylight. This is
    ///     equivalent to a level-bucketed BFS but needs no queue allocation:
    ///     each cell is visited at most once per level transition because the
    ///     check `current < L - 1` short-circuits stale propagation.
    ///
    /// O(MAX_SKYLIGHT × N) where N = CHUNK_W² × CHUNK_H. For our 48×256×48
    /// chunks that's ~9M neighbour checks per chunk — single-digit
    /// milliseconds on a modern desktop, run once per chunk at generate time.
    /// Allocator-free by design so it can be called from `generateTerrain`
    /// without changing the existing call sites.
    pub fn computeSkylight(self: *Chunk) !void {
        return self.computeSkylightWithNeighbors(null, null, null, null);
    }

    /// `computeSkylight`, then light from the four horizontal neighbour
    /// chunks. An air cell on our edge gets (neighbour - 1) when the
    /// neighbour's cell across the border has skylight 2 or more and the
    /// seed is brighter. That light then spreads through our air. Without
    /// this pass, skylight that enters a cave in one chunk stops at the
    /// chunk border. Only the edge cells of each neighbour are read.
    pub fn computeSkylightWithNeighbors(
        self: *Chunk,
        nx_neg: ?*const Chunk, // chunk at cx-1: their x=CHUNK_W-1 is our x=0 border
        nx_pos: ?*const Chunk, // chunk at cx+1: their x=0 is our x=CHUNK_W-1 border
        nz_neg: ?*const Chunk, // chunk at cz-1: their z=CHUNK_W-1 is our z=0 border
        nz_pos: ?*const Chunk, // chunk at cz+1: their z=0 is our z=CHUNK_W-1 border
    ) !void {
        var sky: DenseLight = undefined;
        // The same result as the bucket passes in computeSkylightReference
        // (a test checks it), from one breadth-first pass:
        // 1. A cell is MAX_SKYLIGHT when no solid block is above it in its
        //    column, else 0. Solid blocks are 0.
        // 2. Light spreads from the MAX_SKYLIGHT cells through air, one level
        //    less per step, to a minimum of 1. The queue is in order of
        //    level, so a cell gets its final value when it is first set.
        // Only sky cells next to an air cell at 0 can give light, so only
        // they go in the queue first. Solidity comes from bit masks.
        var solid: [CHUNK_W][CHUNK_W]Col = undefined;
        self.solidColumns(&solid);

        // Pass 1: column seed. top[x][z] = the y above the highest solid block.
        var top: [CHUNK_W][CHUNK_W]u16 = undefined;
        for (0..CHUNK_W) |x| for (0..CHUNK_W) |z| {
            const c = solid[x][z];
            var t: u16 = 0;
            var w: usize = COL_WORDS;
            while (w > 0) {
                w -= 1;
                if (c[w] != 0) {
                    t = @intCast(w * 64 + 64 - @clz(c[w]));
                    break;
                }
            }
            top[x][z] = t;
            for (0..CHUNK_H) |y| sky[x][y][z] = if (y >= t) MAX_SKYLIGHT else 0;
        };

        // Queue of cells (`cellId`). A cell enters at most once, so
        // BLOCKS_PER_CHUNK entries are enough.
        var queue: [BLOCKS_PER_CHUNK]CellId = undefined;
        var head: usize = 0;
        var tail: usize = 0;

        // Seeds: sky cells with an air neighbour at 0. Inside a column the
        // cell below the lowest sky cell is solid (or y = -1), so only the
        // four sides can be shadowed air. A neighbour column with a higher
        // top has shadowed air next to every sky cell of this column under
        // that top.
        for (0..CHUNK_W) |x| for (0..CHUNK_W) |z| {
            const t: usize = top[x][z];
            if (t >= CHUNK_H) continue;
            var hi: usize = t;
            if (x > 0) hi = @max(hi, top[x - 1][z]);
            if (x + 1 < CHUNK_W) hi = @max(hi, top[x + 1][z]);
            if (z > 0) hi = @max(hi, top[x][z - 1]);
            if (z + 1 < CHUNK_W) hi = @max(hi, top[x][z + 1]);
            for (t..@min(hi, CHUNK_H)) |y| {
                queue[tail] = cellId(x, y, z);
                tail += 1;
            }
        };

        // Pass 2: breadth-first spread.
        while (head < tail) {
            const x, const y, const z = cellXyz(queue[head]);
            head += 1;
            const level = sky[x][y][z];
            if (level < 2) continue;
            const target = level - 1;
            const nbs = [6][3]i32{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 } };
            for (nbs) |d| {
                const nx = @as(i32, @intCast(x)) + d[0];
                const ny = @as(i32, @intCast(y)) + d[1];
                const nz = @as(i32, @intCast(z)) + d[2];
                if (nx < 0 or nx >= CHUNK_W or ny < 0 or ny >= CHUNK_H or nz < 0 or nz >= CHUNK_W) continue;
                const nxu: usize = @intCast(nx);
                const nyu: usize = @intCast(ny);
                const nzu: usize = @intCast(nz);
                if (isSolid(&solid, nxu, nyu, nzu)) continue;
                if (sky[nxu][nyu][nzu] >= target) continue;
                sky[nxu][nyu][nzu] = target;
                queue[tail] = cellId(nxu, nyu, nzu);
                tail += 1;
            }
        }
        seedSkylightFromNeighbours(&sky, &solid, &queue, .{ nx_neg, nx_pos, nz_neg, nz_pos });
        try self.skylight.store(self.allocator, &sky);
    }

    /// The bucket-pass skylight that computeSkylight replaced. Tests only:
    /// the reference for the fast version.
    fn computeSkylightReference(self: *Chunk) !void {
        var sky: DenseLight = undefined;
        // Pass 1 — top-down column seed.
        var x: i32 = 0;
        while (x < CHUNK_W) : (x += 1) {
            var z: i32 = 0;
            while (z < CHUNK_W) : (z += 1) {
                var seen_solid = false;
                var y: i32 = CHUNK_H - 1;
                while (y >= 0) : (y -= 1) {
                    const xu: usize = @intCast(x);
                    const yu: usize = @intCast(y);
                    const zu: usize = @intCast(z);
                    if (self.resolveBlockRaw(x, y, z) != .air) {
                        seen_solid = true;
                        sky[xu][yu][zu] = 0;
                    } else if (!seen_solid) {
                        sky[xu][yu][zu] = MAX_SKYLIGHT;
                    } else {
                        sky[xu][yu][zu] = 0;
                    }
                }
            }
        }

        // Pass 2 — bucket-sort BFS, level MAX_SKYLIGHT down to 2.
        // Cells at level 1 have nothing to give (1 - 1 = 0), so we can stop
        // before that pass. Iteration order is x → y → z so the innermost
        // loop is stride-1 in the [x][y][z] array — keeps cache lines hot.
        var level: u8 = MAX_SKYLIGHT;
        while (level >= 2) : (level -= 1) {
            const target: u8 = level - 1;
            var ix: i32 = 0;
            while (ix < CHUNK_W) : (ix += 1) {
                var iy: i32 = 0;
                while (iy < CHUNK_H) : (iy += 1) {
                    var iz: i32 = 0;
                    while (iz < CHUNK_W) : (iz += 1) {
                        const xu: usize = @intCast(ix);
                        const yu: usize = @intCast(iy);
                        const zu: usize = @intCast(iz);
                        if (sky[xu][yu][zu] != level) continue;
                        // Six axis-aligned neighbours.
                        const neighbours = [_][3]i32{
                            .{ ix + 1, iy, iz },
                            .{ ix - 1, iy, iz },
                            .{ ix, iy + 1, iz },
                            .{ ix, iy - 1, iz },
                            .{ ix, iy, iz + 1 },
                            .{ ix, iy, iz - 1 },
                        };
                        for (neighbours) |n| {
                            const nx = n[0];
                            const ny = n[1];
                            const nz = n[2];
                            if (nx < 0 or nx >= CHUNK_W or ny < 0 or ny >= CHUNK_H or nz < 0 or nz >= CHUNK_W) continue;
                            const nxu: usize = @intCast(nx);
                            const nyu: usize = @intCast(ny);
                            const nzu: usize = @intCast(nz);
                            if (self.resolveBlockRaw(nx, ny, nz) != .air) continue;
                            if (sky[nxu][nyu][nzu] >= target) continue;
                            sky[nxu][nyu][nzu] = target;
                        }
                    }
                }
            }
        }
        try self.skylight.store(self.allocator, &sky);
    }

    /// Recompute block-light for the entire chunk from the current `blocks`
    /// array. Same shape as `computeSkylight`, seeded differently:
    ///
    ///   Pass 1 (emission seed):
    ///     Walk every cell. Air cells and non-emissive solids get 0.
    ///     Emissive blocks (see `emissionLevel`) get their emission level
    ///     stored directly in `block_light[x][y][z]`, even though the cell
    ///     is solid — this is what makes an emissive block's own face read bright
    ///     when the mesher later samples with `max(outward_mean, owner_bl)`.
    ///
    ///   Pass 2 (bucket-sort BFS, levels MAX_BLOCK_LIGHT down to 2):
    ///     For each level L, sweep the chunk and for each cell (emissive
    ///     solid OR air) with block_light == L, propagate (L - 1) into any
    ///     AIR neighbour whose current value is strictly lower. Solid
    ///     neighbours (including other emissive blocks) are skipped — light
    ///     cannot travel through an emissive block the same way skylight cannot
    ///     travel through a solid block.
    ///
    /// O(MAX_BLOCK_LIGHT × N). In practice the sweep is dominated by
    /// cells with value 0 that short-circuit on the first check, so this is
    /// a small fraction of the skylight pass on chunks with no emitters
    /// (early-out: if pass 1 finds no emitters, pass 2 is a no-op).
    /// Allocator-free by design so it can be called from `generateTerrain`
    /// and `World.setBlock` without touching call sites.
    ///
    /// This pass lights the chunk on its own. `World.relightSeams` and
    /// `World.setBlock` then call `computeBlockLightWithNeighbors` so light
    /// crosses the chunk borders.
    pub fn computeBlockLight(self: *Chunk) !void {
        var bl: DenseLight = undefined;
        // Pass 1 — seed emissive cells, zero everything else.
        var any_emitter = false;
        var x: i32 = 0;
        while (x < CHUNK_W) : (x += 1) {
            var y: i32 = 0;
            while (y < CHUNK_H) : (y += 1) {
                var z: i32 = 0;
                while (z < CHUNK_W) : (z += 1) {
                    const xu: usize = @intCast(x);
                    const yu: usize = @intCast(y);
                    const zu: usize = @intCast(z);
                    const emit = emissionLevel(self.resolveBlockRaw(x, y, z));
                    bl[xu][yu][zu] = emit;
                    if (emit > 0) any_emitter = true;
                }
            }
        }

        // Fast path: no emitters, nothing to propagate.
        if (!any_emitter) return self.block_light.store(self.allocator, &bl);

        // Pass 2 — bucket-sort BFS, level MAX_BLOCK_LIGHT down to 2.
        var level: u8 = MAX_BLOCK_LIGHT;
        while (level >= 2) : (level -= 1) {
            const target: u8 = level - 1;
            var ix: i32 = 0;
            while (ix < CHUNK_W) : (ix += 1) {
                var iy: i32 = 0;
                while (iy < CHUNK_H) : (iy += 1) {
                    var iz: i32 = 0;
                    while (iz < CHUNK_W) : (iz += 1) {
                        const xu: usize = @intCast(ix);
                        const yu: usize = @intCast(iy);
                        const zu: usize = @intCast(iz);
                        if (bl[xu][yu][zu] != level) continue;
                        // Six axis-aligned neighbours.
                        const neighbours = [_][3]i32{
                            .{ ix + 1, iy, iz },
                            .{ ix - 1, iy, iz },
                            .{ ix, iy + 1, iz },
                            .{ ix, iy - 1, iz },
                            .{ ix, iy, iz + 1 },
                            .{ ix, iy, iz - 1 },
                        };
                        for (neighbours) |n| {
                            const nx = n[0];
                            const ny = n[1];
                            const nz = n[2];
                            if (nx < 0 or nx >= CHUNK_W or ny < 0 or ny >= CHUNK_H or nz < 0 or nz >= CHUNK_W) continue;
                            const nxu: usize = @intCast(nx);
                            const nyu: usize = @intCast(ny);
                            const nzu: usize = @intCast(nz);
                            // Solid neighbours block propagation — including
                            // other emissive solids. Their seed value is
                            // already set in pass 1 and they will propagate
                            // from THEIR own cell on their own sweep tick.
                            if (self.resolveBlockRaw(nx, ny, nz) != .air) continue;
                            if (bl[nxu][nyu][nzu] >= target) continue;
                            bl[nxu][nyu][nzu] = target;
                        }
                    }
                }
            }
        }
        try self.block_light.store(self.allocator, &bl);
    }

    /// Recompute block-light for this chunk, seeding additional light from
    /// the four horizontal neighbour chunks.  Call this instead of
    /// `computeBlockLight` when a block mutation may push light across a
    /// chunk boundary (i.e. whenever `World.setBlock` runs).
    ///
    /// Algorithm:
    ///   Pass 1 — same as `computeBlockLight`: seed own emitters, zero the rest.
    ///   Pass 1b — for each of the four edges that has a live neighbour chunk,
    ///             walk the shared border row.  If the neighbour's adjacent cell
    ///             has block_light >= 2, seed our border cell with (neighbour - 1)
    ///             when our cell is air and the seed would raise its value.
    ///             This is a one-hop hand-off; the BFS in pass 2 propagates the
    ///             seeded values inward, so light travelling from the neighbour
    ///             fills as many of our cells as the remaining budget allows.
    ///   Pass 2 — standard bucket-sort BFS, same as `computeBlockLight`.
    ///
    /// Cross-chunk propagation notes:
    ///   - Only the four horizontal neighbours (±X, ±Z) are considered.
    ///     Vertical light does not cross chunks (chunks span all 256 Y levels).
    ///   - Light originating in a neighbour that was itself seeded from a
    ///     further-away chunk is NOT re-propagated here (we only look at the
    ///     neighbour's already-computed values, not its neighbours).  This is
    ///     correct for the common case: an emissive block is at most CHUNK_W-1 = 15
    ///     cells from an edge, and MAX_BLOCK_LIGHT = 15, so the light budget
    ///     reaching the far side of the adjacent chunk would already be ≤ 1
    ///     and therefore zero after our one-hop decay.
    pub fn computeBlockLightWithNeighbors(
        self: *Chunk,
        nx_neg: ?*const Chunk, // chunk at cx-1: their x=CHUNK_W-1 is our x=0 border
        nx_pos: ?*const Chunk, // chunk at cx+1: their x=0 is our x=CHUNK_W-1 border
        nz_neg: ?*const Chunk, // chunk at cz-1: their z=CHUNK_W-1 is our z=0 border
        nz_pos: ?*const Chunk, // chunk at cz+1: their z=0 is our z=CHUNK_W-1 border
    ) !void {
        var bl: DenseLight = undefined;
        // Pass 1 — seed own emitters, zero everything else (same as computeBlockLight).
        var any_emitter = false;
        var x: i32 = 0;
        while (x < CHUNK_W) : (x += 1) {
            var y: i32 = 0;
            while (y < CHUNK_H) : (y += 1) {
                var z: i32 = 0;
                while (z < CHUNK_W) : (z += 1) {
                    const xu: usize = @intCast(x);
                    const yu: usize = @intCast(y);
                    const zu: usize = @intCast(z);
                    const emit = emissionLevel(self.resolveBlockRaw(x, y, z));
                    bl[xu][yu][zu] = emit;
                    if (emit > 0) any_emitter = true;
                }
            }
        }

        // Pass 1b — seed border cells from each live neighbour's adjacent edge.
        // nx_neg is the chunk to our left (-X); their rightmost column
        // (x = CHUNK_W-1) is adjacent to our leftmost column (x = 0).
        if (nx_neg) |nb| {
            var yy: usize = 0;
            while (yy < CHUNK_H) : (yy += 1) {
                var zz: usize = 0;
                while (zz < CHUNK_W) : (zz += 1) {
                    const nv = nb.block_light.get(CHUNK_W - 1, yy, zz);
                    if (nv >= 2 and self.resolveBlockRaw(0, @intCast(yy), @intCast(zz)) == .air) {
                        const seed: u8 = nv - 1;
                        if (seed > bl[0][yy][zz]) {
                            bl[0][yy][zz] = seed;
                            any_emitter = true;
                        }
                    }
                }
            }
        }
        if (nx_pos) |nb| {
            var yy: usize = 0;
            while (yy < CHUNK_H) : (yy += 1) {
                var zz: usize = 0;
                while (zz < CHUNK_W) : (zz += 1) {
                    const nv = nb.block_light.get(0, yy, zz);
                    if (nv >= 2 and self.resolveBlockRaw(CHUNK_W - 1, @intCast(yy), @intCast(zz)) == .air) {
                        const seed: u8 = nv - 1;
                        if (seed > bl[CHUNK_W - 1][yy][zz]) {
                            bl[CHUNK_W - 1][yy][zz] = seed;
                            any_emitter = true;
                        }
                    }
                }
            }
        }
        if (nz_neg) |nb| {
            var xx: usize = 0;
            while (xx < CHUNK_W) : (xx += 1) {
                var yy: usize = 0;
                while (yy < CHUNK_H) : (yy += 1) {
                    const nv = nb.block_light.get(xx, yy, CHUNK_W - 1);
                    if (nv >= 2 and self.resolveBlockRaw(@intCast(xx), @intCast(yy), 0) == .air) {
                        const seed: u8 = nv - 1;
                        if (seed > bl[xx][yy][0]) {
                            bl[xx][yy][0] = seed;
                            any_emitter = true;
                        }
                    }
                }
            }
        }
        if (nz_pos) |nb| {
            var xx: usize = 0;
            while (xx < CHUNK_W) : (xx += 1) {
                var yy: usize = 0;
                while (yy < CHUNK_H) : (yy += 1) {
                    const nv = nb.block_light.get(xx, yy, 0);
                    if (nv >= 2 and self.resolveBlockRaw(@intCast(xx), @intCast(yy), CHUNK_W - 1) == .air) {
                        const seed: u8 = nv - 1;
                        if (seed > bl[xx][yy][CHUNK_W - 1]) {
                            bl[xx][yy][CHUNK_W - 1] = seed;
                            any_emitter = true;
                        }
                    }
                }
            }
        }

        // Fast path: no emitters or neighbour seeds, nothing to propagate.
        if (!any_emitter) return self.block_light.store(self.allocator, &bl);

        // Pass 2 — bucket-sort BFS, identical to computeBlockLight.
        var level: u8 = MAX_BLOCK_LIGHT;
        while (level >= 2) : (level -= 1) {
            const target: u8 = level - 1;
            var ix: i32 = 0;
            while (ix < CHUNK_W) : (ix += 1) {
                var iy: i32 = 0;
                while (iy < CHUNK_H) : (iy += 1) {
                    var iz: i32 = 0;
                    while (iz < CHUNK_W) : (iz += 1) {
                        const xu: usize = @intCast(ix);
                        const yu: usize = @intCast(iy);
                        const zu: usize = @intCast(iz);
                        if (bl[xu][yu][zu] != level) continue;
                        const neighbours = [_][3]i32{
                            .{ ix + 1, iy, iz },
                            .{ ix - 1, iy, iz },
                            .{ ix, iy + 1, iz },
                            .{ ix, iy - 1, iz },
                            .{ ix, iy, iz + 1 },
                            .{ ix, iy, iz - 1 },
                        };
                        for (neighbours) |n| {
                            const nx2 = n[0];
                            const ny = n[1];
                            const nz = n[2];
                            if (nx2 < 0 or nx2 >= CHUNK_W or ny < 0 or ny >= CHUNK_H or nz < 0 or nz >= CHUNK_W) continue;
                            const nxu: usize = @intCast(nx2);
                            const nyu: usize = @intCast(ny);
                            const nzu: usize = @intCast(nz);
                            if (self.resolveBlockRaw(nx2, ny, nz) != .air) continue;
                            if (bl[nxu][nyu][nzu] >= target) continue;
                            bl[nxu][nyu][nzu] = target;
                        }
                    }
                }
            }
        }
        try self.block_light.store(self.allocator, &bl);
    }

    /// Generate the blocks of this chunk at chunk grid position (cx, cz)
    /// with the generator of the content (`content.generate`), then compute
    /// the skylight and the block light.
    ///
    /// The generator writes into a dense block buffer (`DenseBlocks`), and
    /// the buffer goes into the paletted store one time at the end. A write
    /// through `setBlock` searches the palette and packs bits for each
    /// block, which is slow. The result replaces the old blocks of the chunk.
    ///
    /// Returns `!void` because the dense buffer and the paletted store
    /// allocate (out-of-memory is the only realistic failure mode).
    pub fn generateTerrain(self: *Chunk, cx: i32, cz: i32, config: content.GenConfig) !void {
        const t_fill_start = clock.nowNs();
        const dense = try self.allocator.create(DenseBlocks);
        defer self.allocator.destroy(dense);
        content.generate(dense, cx, cz, config);
        const t_fill_us = @divTrunc(clock.nowNs() - t_fill_start, 1000);

        // Pack the dense buffer into the paletted store, one time.
        const blocks = try PalettedBlocks.fromDense(self.allocator, dense);
        self.blocks.deinit(self.allocator);
        self.blocks = blocks;

        // Skylight: must run after the blocks array is fully populated, since
        // the BFS reads `blocks` to know which cells block propagation.
        const t_sky_start = clock.nowNs();
        try self.computeSkylight();
        const t_sky_us = @divTrunc(clock.nowNs() - t_sky_start, 1000);
        // Block light: seeds from the emissive blocks of the generator. The
        // BFS spreads their light through nearby air cells.
        try self.computeBlockLight();

        std.log.info("[GEN] chunk ({},{}) fill={}us sky={}us total={}us", .{
            cx, cz, t_fill_us, t_sky_us, t_fill_us + t_sky_us,
        });
    }
};

/// Type-erased block source. Allows player physics, raycasting, and the
/// mesher to work with either a single Chunk (local coords) or a World
/// (world coords). The mesher additionally uses `getSkylight` to look up
/// per-block sky values across chunk boundaries — without it, faces on a
/// chunk's edge would sample OOB and have to fall back to a default,
/// producing visible bright/dark seams.
pub const BlockGetter = struct {
    ctx: *const anyopaque,
    getFn: *const fn (ctx: *const anyopaque, x: i32, y: i32, z: i32) BlockType,
    getSkylightFn: *const fn (ctx: *const anyopaque, x: i32, y: i32, z: i32) u8,
    getBlockLightFn: *const fn (ctx: *const anyopaque, x: i32, y: i32, z: i32) u8,

    pub fn getBlock(self: BlockGetter, x: i32, y: i32, z: i32) BlockType {
        return self.getFn(self.ctx, x, y, z);
    }

    pub fn getSkylight(self: BlockGetter, x: i32, y: i32, z: i32) u8 {
        return self.getSkylightFn(self.ctx, x, y, z);
    }

    pub fn getBlockLight(self: BlockGetter, x: i32, y: i32, z: i32) u8 {
        return self.getBlockLightFn(self.ctx, x, y, z);
    }
};

test "computeSkylight gives the same values as the bucket-pass reference" {
    const a = std.testing.allocator;
    const config: content.GenConfig = .{};
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const r = prng.random();
    var case: usize = 0;
    while (case < 24) : (case += 1) {
        var ch = Chunk.init(a);
        defer ch.deinit();
        const cx: i32 = @as(i32, @intCast(case % 6)) - 3;
        const cz: i32 = @as(i32, @intCast(case / 6)) - 2;
        try ch.generateTerrain(cx, cz, config);
        // Caves, overhangs and holes: random solid boxes and air boxes.
        if (case >= 8) {
            var k: usize = 0;
            while (k < 40) : (k += 1) {
                const x0 = r.intRangeLessThan(i32, 0, CHUNK_W);
                const y0 = r.intRangeLessThan(i32, 20, 120);
                const z0 = r.intRangeLessThan(i32, 0, CHUNK_W);
                const block: BlockType = if (r.boolean()) .air else .solid;
                var x = x0;
                while (x < @min(CHUNK_W, x0 + 5)) : (x += 1) {
                    var y = y0;
                    while (y < y0 + 4) : (y += 1) {
                        var z = z0;
                        while (z < @min(CHUNK_W, z0 + 5)) : (z += 1) try ch.setBlock(x, y, z, block);
                    }
                }
            }
        }
        try ch.computeSkylight();
        var fast: DenseLight = undefined;
        ch.skylight.expand(&fast);
        try ch.computeSkylightReference();
        var reference: DenseLight = undefined;
        ch.skylight.expand(&reference);
        try std.testing.expectEqualSlices(u8, std.mem.asBytes(&reference), std.mem.asBytes(&fast));
    }
}

test "fromDense packs the same blocks as setBlock" {
    const a = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xb10c);
    const r = prng.random();
    const kinds = [_]BlockType{ .solid, .b3, .b4, .b5, .emitter, .b6, .b7, .b8 };
    // 0 kinds (all air), then 1 to 8 kinds: every palette width.
    for (0..kinds.len + 1) |n_kinds| {
        const dense = try a.create(DenseBlocks);
        defer a.destroy(dense);
        @memset(dense, .air);
        var ch = Chunk.init(a);
        defer ch.deinit();
        if (n_kinds > 0) for (0..4000) |_| {
            const idx = r.uintLessThan(usize, BLOCKS_PER_CHUNK);
            const b = kinds[r.uintLessThan(usize, n_kinds)];
            dense[idx] = b;
            const x: i32 = @intCast(idx / (CHUNK_H * CHUNK_W));
            const y: i32 = @intCast((idx / CHUNK_W) % CHUNK_H);
            const z: i32 = @intCast(idx % CHUNK_W);
            try ch.setBlock(x, y, z, b);
        };
        var p = try PalettedBlocks.fromDense(a, dense);
        defer p.deinit(a);
        for (0..BLOCKS_PER_CHUNK) |idx| {
            try std.testing.expectEqual(dense[idx], p.get(idx));
            try std.testing.expectEqual(ch.blocks.get(idx), p.get(idx));
        }
    }
}

test "decode gives the value of get for each cell" {
    const a = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xdec0de);
    const r = prng.random();
    const kinds = comptime std.enums.values(BlockType);
    var table: [256]u8 = undefined;
    for (&table, 0..) |*t, i| t.* = @truncate(i *% 37 +% 5);
    const out = try a.create([BLOCKS_PER_CHUNK]u8);
    defer a.destroy(out);
    // 0 kinds (uniform air), then 1 kind and more: every bit width that
    // the block types can make.
    for (0..kinds.len + 1) |n_kinds| {
        const dense = try a.create(DenseBlocks);
        defer a.destroy(dense);
        @memset(dense, .air);
        if (n_kinds > 0) for (0..4000) |_| {
            const idx = r.uintLessThan(usize, BLOCKS_PER_CHUNK);
            dense[idx] = kinds[r.uintLessThan(usize, n_kinds)];
        };
        var p = try PalettedBlocks.fromDense(a, dense);
        defer p.deinit(a);
        p.decode(&table, out);
        for (0..BLOCKS_PER_CHUNK) |idx| {
            try std.testing.expectEqual(table[@backingInt(p.get(idx))], out[idx]);
        }
    }
}
