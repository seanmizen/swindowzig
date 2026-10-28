const std = @import("std");
const clock = @import("clock.zig");
const content = @import("content.zig");
const models = @import("models.zig");
const light = @import("light.zig");
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
    return light.emission(block);
}

/// The light of one cell: sky light and block light, 0 to 15 each
/// (`light.zig`).
pub const CellLight = light.CellLight;

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
inline fn isSet(cols: *const [CHUNK_W][CHUNK_W]Col, x: usize, y: usize, z: usize) bool {
    return (cols[x][z][y >> 6] >> @intCast(y & 63)) & 1 != 0;
}

/// The loss of light into each cell of a chunk: max(1, opacity) of its
/// block (light.zig). With `light.ordered`, each opacity is 0 or 15, so the
/// bit columns of the cells that stop sky light give it.
const LossMap = struct {
    /// The columns of the cells with opacity more than 0.
    stop: *const [CHUNK_W][CHUNK_W]Col,
    blocks: *const PalettedBlocks,

    inline fn at(self: LossMap, x: usize, y: usize, z: usize) u8 {
        if (comptime light.ordered) return if (isSet(self.stop, x, y, z)) light.MAX_LIGHT else 1;
        return light.loss(self.blocks.getAt(x, y, z));
    }
};

/// A queue of chunk cells for a spread with mixed levels. A cell can go
/// in the queue again when its light increases, and a bit set keeps each
/// cell in the queue at most once, so a ring of one entry per cell is
/// enough.
const Ring = struct {
    const N = BLOCKS_PER_CHUNK;
    queue: *[N]CellId,
    in_queue: [N / 64]u64 = @splat(0),
    head: usize = 0,
    count: usize = 0,

    fn push(r: *Ring, x: usize, y: usize, z: usize) void {
        const v = cellId(x, y, z);
        const bit = @as(u64, 1) << @intCast(v & 63);
        if (r.in_queue[v >> 6] & bit != 0) return;
        r.in_queue[v >> 6] |= bit;
        r.queue[(r.head + r.count) % N] = v;
        r.count += 1;
    }

    fn pop(r: *Ring) CellId {
        const v = r.queue[r.head];
        r.head = (r.head + 1) % N;
        r.count -= 1;
        r.in_queue[v >> 6] &= ~(@as(u64, 1) << @intCast(v & 63));
        return v;
    }
};

const face_dirs = [6][3]i32{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 } };

/// Spread the light of `grid` from the cells in `ring` (light.zig rules):
/// a neighbour gets level - loss when that is more than its light.
fn spreadRing(grid: *DenseLight, lm: LossMap, ring: *Ring) void {
    while (ring.count > 0) {
        const x, const y, const z = cellXyz(ring.pop());
        const level = grid[x][y][z];
        if (level < 2) continue;
        for (face_dirs) |d| {
            const nx = @as(i32, @intCast(x)) + d[0];
            const ny = @as(i32, @intCast(y)) + d[1];
            const nz = @as(i32, @intCast(z)) + d[2];
            if (nx < 0 or nx >= CHUNK_W or ny < 0 or ny >= CHUNK_H or nz < 0 or nz >= CHUNK_W) continue;
            const nxu: usize = @intCast(nx);
            const nyu: usize = @intCast(ny);
            const nzu: usize = @intCast(nz);
            const target = level -| lm.at(nxu, nyu, nzu);
            if (target == 0 or grid[nxu][nyu][nzu] >= target) continue;
            grid[nxu][nyu][nzu] = target;
            ring.push(nxu, nyu, nzu);
        }
    }
}

/// Seed the edge cells of `grid` from the light of the neighbours (order
/// -X, +X, -Z, +Z) in channel `ch`, then spread. An edge cell gets the
/// light of the neighbour cell across the border, less the loss into the
/// edge cell, when that is brighter. The ring can hold seeds already.
fn seedFromNeighbours(
    grid: *DenseLight,
    lm: LossMap,
    ring: *Ring,
    nbs: [4]?*const Chunk,
    comptime ch: light.Channel,
) void {
    const W = CHUNK_W;
    for (nbs, 0..) |maybe_nb, side| {
        const nb = maybe_nb orelse continue;
        const g = switch (ch) {
            .sky => &nb.skylight,
            .block => &nb.block_light,
        };
        for (0..CHUNK_H) |y| for (0..W) |i| {
            // Our edge cell and the neighbour's cell across the border.
            const ours: [2]usize, const theirs: [2]usize = switch (side) {
                0 => .{ .{ 0, i }, .{ W - 1, i } },
                1 => .{ .{ W - 1, i }, .{ 0, i } },
                2 => .{ .{ i, 0 }, .{ i, W - 1 } },
                else => .{ .{ i, W - 1 }, .{ i, 0 } },
            };
            const target = g.get(theirs[0], y, theirs[1]) -| lm.at(ours[0], y, ours[1]);
            if (target == 0 or grid[ours[0]][y][ours[1]] >= target) continue;
            grid[ours[0]][y][ours[1]] = target;
            ring.push(ours[0], y, ours[1]);
        };
    }
    spreadRing(grid, lm, ring);
}

/// Light values of a chunk, 0 to 15, stored per 16-high section
/// (REQ-VOXEL-003). A section holds two cells in each byte. A section where
/// every cell has the same value (open sky above the terrain, or no block
/// light) has no array, only that value. Most of a chunk is like that: on
/// hilly demo terrain 11 of 16 skylight sections, and all block light when
/// there is no emissive block. Values are the same as a dense grid: store
/// a dense grid, then get gives back each value.
///
/// `store` keeps an array only for a section that is not uniform. `set`
/// can leave a uniform section with an array. `compact` frees those
/// arrays, so that `eql` and the light hash see one form for each value.
pub const LightGrid = struct {
    pub const SECTION_H = 16;
    pub const SECTIONS = CHUNK_H / SECTION_H;
    const SECTION_CELLS = CHUNK_W * SECTION_H * CHUNK_W;
    /// Cell i (x * 256 + y * 16 + z in the section) is the low 4 bits of
    /// byte i / 2 when i is even, else the high 4 bits.
    const Cells = [SECTION_CELLS / 2]u8;

    /// Per section: the array, or null when every cell is `fill`.
    arrays: [SECTIONS]?*Cells = @splat(null),
    fill: [SECTIONS]u8 = @splat(0),

    inline fn cellIndex(x: usize, y: usize, z: usize) usize {
        return x * (SECTION_H * CHUNK_W) + (y % SECTION_H) * CHUNK_W + z;
    }

    pub inline fn get(self: *const LightGrid, x: usize, y: usize, z: usize) u8 {
        const s = y / SECTION_H;
        const arr = self.arrays[s] orelse return self.fill[s];
        const i = cellIndex(x, y, z);
        return (arr[i >> 1] >> @intCast((i & 1) * 4)) & 0xF;
    }

    /// Set the value of one cell, 0 to 15. A uniform section gets an array
    /// when the value is new in it.
    pub fn set(self: *LightGrid, allocator: std.mem.Allocator, x: usize, y: usize, z: usize, value: u8) !void {
        std.debug.assert(value <= 0xF);
        const s = y / SECTION_H;
        const arr = self.arrays[s] orelse blk: {
            if (self.fill[s] == value) return;
            const arr = try allocator.create(Cells);
            @memset(arr, self.fill[s] * 0x11);
            self.arrays[s] = arr;
            break :blk arr;
        };
        const i = cellIndex(x, y, z);
        const shift: u3 = @intCast((i & 1) * 4);
        arr[i >> 1] = (arr[i >> 1] & ~(@as(u8, 0xF) << shift)) | (value << shift);
    }

    /// Free the array of each section where every cell has the same value.
    pub fn compact(self: *LightGrid, allocator: std.mem.Allocator) void {
        for (&self.arrays, &self.fill) |*a, *fill| {
            const arr = a.* orelse continue;
            const b = arr[0];
            if (b & 0xF != b >> 4) continue;
            const uniform = for (arr) |x| {
                if (x != b) break false;
            } else true;
            if (!uniform) continue;
            allocator.destroy(arr);
            a.* = null;
            fill.* = b & 0xF;
        }
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
            for (0..CHUNK_W) |x| for (0..SECTION_H) |y| {
                const row = &dense[x][y0 + y];
                const out = arr[cellIndex(x, y, 0) / 2 ..][0 .. CHUNK_W / 2];
                for (out, 0..) |*b, k| b.* = row[2 * k] | (row[2 * k + 1] << 4);
            };
        }
    }

    /// Write every value into `dense`.
    pub fn expand(self: *const LightGrid, dense: *DenseLight) void {
        for (0..SECTIONS) |s| {
            const y0 = s * SECTION_H;
            for (0..CHUNK_W) |x| {
                if (self.arrays[s]) |arr| {
                    for (0..SECTION_H) |y| {
                        const row = &dense[x][y0 + y];
                        const in = arr[cellIndex(x, y, 0) / 2 ..][0 .. CHUNK_W / 2];
                        for (in, 0..) |b, k| {
                            row[2 * k] = b & 0xF;
                            row[2 * k + 1] = b >> 4;
                        }
                    }
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
    /// with an array never equals a section without one. After `set`, call
    /// `compact` first.
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
    /// `computeSkylight()` after `generateTerrain()`. A block with opacity
    /// 15 stores 0. Other cells store the sunlight that reaches them
    /// (light.zig gives the rules). `computeSkylight` lights the chunk
    /// on its own. `computeSkylightWithNeighbors` (called from `World`) adds
    /// the light that comes across the chunk borders.
    ///
    /// Stored per 16-high section (LightGrid): a section with one value,
    /// such as open sky, has no array.
    skylight: LightGrid,
    /// Per-block block-light value, range [0, MAX_BLOCK_LIGHT]. Computed by
    /// `computeBlockLight()` after `generateTerrain()`. An emissive block
    /// stores at least its own emission level, also when its opacity is 15.
    /// Thus the mesher reads a bright value for the face of an emissive
    /// block. `computeBlockLightWithNeighbors` adds the light from the
    /// neighbour chunks.
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
        self.columnsWhere(out, notAir);
    }

    /// The same as `solidColumns`, but the mask has bit y only when the block is
    /// a full cube: not air and with no model (`models.isCube`). With no
    /// models in the content, the result is the same as `solidColumns`.
    pub fn cubeColumns(self: *const Chunk, out: *[CHUNK_W][CHUNK_W]Col) void {
        if (!models.any and !@import("fluid.zig").any) return self.solidColumns(out);
        self.columnsWhere(out, models.isCube);
    }

    fn notAir(b: BlockType) bool {
        return b != .air;
    }

    fn columnsWhere(self: *const Chunk, out: *[CHUNK_W][CHUNK_W]Col, comptime set: fn (BlockType) bool) void {
        for (out) |*row| for (row) |*col| {
            col.* = @splat(0);
        };
        for (&self.blocks.sections, 0..) |*sec, s| {
            const y0 = s * section_mod.SIZE;
            const word = y0 >> 6;
            const shift: u6 = @intCast(y0 & 63);
            if (sec.bits == 0) {
                if (!set(sec.single)) continue;
                for (out) |*row| for (row) |*col| {
                    col[word] |= @as(u64, 0xFFFF) << shift;
                };
                continue;
            }
            var solid: [256]bool = @splat(false);
            for (sec.palette(), 0..) |b, i| solid[i] = set(b);
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

    /// The sky light and the block light of local cell (x, y, z), with the
    /// out-of-bounds values of `getSkylight` and `getBlockLight`. The mesher
    /// reads the light of a cell with this function.
    pub fn lightAt(self: *const Chunk, x: i32, y: i32, z: i32) CellLight {
        return .{ .sky = self.getSkylight(x, y, z), .block = self.getBlockLight(x, y, z) };
    }

    /// Read the block-light at (x, y, z) using local chunk coordinates.
    /// Out-of-bounds returns 0 (no "above world" bright-side asymmetry — block
    /// light has no global seed like the sun). Light from a neighbour chunk
    /// is in this grid after `computeBlockLightWithNeighbors`.
    pub fn getBlockLight(self: *const Chunk, x: i32, y: i32, z: i32) u8 {
        if (x < 0 or x >= CHUNK_W or y < 0 or y >= CHUNK_H or z < 0 or z >= CHUNK_W) return 0;
        return self.block_light.get(@intCast(x), @intCast(y), @intCast(z));
    }

    /// Recompute skylight for the entire chunk from the current `blocks` array,
    /// with the rules of light.zig:
    ///
    ///   Pass 1 (column seed):
    ///     For each (x, z) column, every cell above the highest cell with
    ///     opacity more than 0 is a sky source, at MAX_SKYLIGHT. Every other
    ///     cell starts at 0.
    ///
    ///   Pass 2 (breadth-first spread):
    ///     Light goes from a cell into each neighbour, less max(1, opacity)
    ///     of the neighbour, when that is brighter.
    ///
    /// Allocator-free by design so it can be called from `generateTerrain`
    /// without changing the existing call sites.
    pub fn computeSkylight(self: *Chunk) !void {
        return self.computeSkylightWithNeighbors(null, null, null, null);
    }

    /// `computeSkylight`, then light from the four horizontal neighbour
    /// chunks. An edge cell gets (neighbour - loss) when that is brighter
    /// (see `seedFromNeighbours`). That light then spreads through our
    /// cells. Without this pass, skylight that enters a cave in one chunk
    /// stops at the chunk border. Only the edge cells of each neighbour are
    /// read.
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
        // 1. A cell is MAX_SKYLIGHT when no cell above it in its column
        //    stops sky light, else 0.
        // 2. Light spreads from the MAX_SKYLIGHT cells, less the loss of
        //    each cell, to a minimum of 1. With `light.ordered`, the queue
        //    is in order of level, so a cell gets its final value when it
        //    is first set. Else a ring takes a cell again when it gets
        //    brighter.
        // Only sky cells next to a cell at 0 can give light, so only they
        // go in the queue first. The cells that stop sky light come from
        // bit masks.
        var stop: [CHUNK_W][CHUNK_W]Col = undefined;
        self.columnsWhere(&stop, light.stopsSky);
        const lm: LossMap = .{ .stop = &stop, .blocks = &self.blocks };

        // Pass 1: column seed. top[x][z] = the y above the highest stop cell.
        var top: [CHUNK_W][CHUNK_W]u16 = undefined;
        for (0..CHUNK_W) |x| for (0..CHUNK_W) |z| {
            const c = stop[x][z];
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

        // Queue of cells (`cellId`). With `light.ordered`, a cell enters at
        // most once, so BLOCKS_PER_CHUNK entries are enough.
        var queue: [BLOCKS_PER_CHUNK]CellId = undefined;
        var tail: usize = 0;

        // Seeds: sky cells next to a cell that is not a source. Inside a
        // column the cell below the lowest sky cell stops sky light (or
        // y = -1). A neighbour column with a higher top has shadowed cells
        // next to every sky cell of this column under that top.
        for (0..CHUNK_W) |x| for (0..CHUNK_W) |z| {
            const t: usize = top[x][z];
            if (t >= CHUNK_H) continue;
            var hi: usize = t;
            if (x > 0) hi = @max(hi, top[x - 1][z]);
            if (x + 1 < CHUNK_W) hi = @max(hi, top[x + 1][z]);
            if (z > 0) hi = @max(hi, top[x][z - 1]);
            if (z + 1 < CHUNK_W) hi = @max(hi, top[x][z + 1]);
            // A cell with opacity 1 to 14 under the lowest sky cell takes
            // light from it. With `light.ordered`, that cell stops all light.
            if (!light.ordered and t > 0) hi = @max(hi, t + 1);
            for (t..@min(hi, CHUNK_H)) |y| {
                queue[tail] = cellId(x, y, z);
                tail += 1;
            }
        };

        if (comptime light.ordered) {
            // Pass 2: breadth-first spread in order of level.
            var head: usize = 0;
            while (head < tail) {
                const x, const y, const z = cellXyz(queue[head]);
                head += 1;
                const level = sky[x][y][z];
                if (level < 2) continue;
                for (face_dirs) |d| {
                    const nx = @as(i32, @intCast(x)) + d[0];
                    const ny = @as(i32, @intCast(y)) + d[1];
                    const nz = @as(i32, @intCast(z)) + d[2];
                    if (nx < 0 or nx >= CHUNK_W or ny < 0 or ny >= CHUNK_H or nz < 0 or nz >= CHUNK_W) continue;
                    const nxu: usize = @intCast(nx);
                    const nyu: usize = @intCast(ny);
                    const nzu: usize = @intCast(nz);
                    const target = level -| lm.at(nxu, nyu, nzu);
                    if (target == 0 or sky[nxu][nyu][nzu] >= target) continue;
                    sky[nxu][nyu][nzu] = target;
                    queue[tail] = cellId(nxu, nyu, nzu);
                    tail += 1;
                }
            }
            var ring = Ring{ .queue = &queue };
            seedFromNeighbours(&sky, lm, &ring, .{ nx_neg, nx_pos, nz_neg, nz_pos }, .sky);
        } else {
            // Pass 2 with a ring on the same memory. Push i writes entry
            // i or an entry before it, after the read of entry i.
            var ring = Ring{ .queue = &queue };
            for (0..tail) |i| {
                const x, const y, const z = cellXyz(queue[i]);
                ring.push(x, y, z);
            }
            seedFromNeighbours(&sky, lm, &ring, .{ nx_neg, nx_pos, nz_neg, nz_pos }, .sky);
        }
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
    /// array, with the rules of light.zig. Each emissive cell starts at its
    /// emission level, also when its opacity is 15. The mesher reads that
    /// value for the face of an emissive block. The light then spreads:
    /// a neighbour gets level - max(1, opacity), when that is brighter.
    ///
    /// This pass lights the chunk on its own. `World.relightSeams` then
    /// calls `computeBlockLightWithNeighbors` so light crosses the chunk
    /// borders.
    pub fn computeBlockLight(self: *Chunk) !void {
        return self.computeBlockLightWithNeighbors(null, null, null, null);
    }

    /// `computeBlockLight`, with more seeds from the four horizontal
    /// neighbour chunks: an edge cell gets (neighbour - loss) when that is
    /// brighter (see `seedFromNeighbours`). The breadth-first spread then
    /// carries the seeded values inward.
    ///
    /// Only the four horizontal neighbours (±X, ±Z) are read. Vertical
    /// light does not cross chunks, because chunks are full columns.
    pub fn computeBlockLightWithNeighbors(
        self: *Chunk,
        nx_neg: ?*const Chunk, // chunk at cx-1: their x=CHUNK_W-1 is our x=0 border
        nx_pos: ?*const Chunk, // chunk at cx+1: their x=0 is our x=CHUNK_W-1 border
        nz_neg: ?*const Chunk, // chunk at cz-1: their z=CHUNK_W-1 is our z=0 border
        nz_pos: ?*const Chunk, // chunk at cz+1: their z=0 is our z=CHUNK_W-1 border
    ) !void {
        var bl: DenseLight = undefined;
        @memset(std.mem.asBytes(&bl), 0);
        var stop: [CHUNK_W][CHUNK_W]Col = undefined;
        self.columnsWhere(&stop, light.stopsSky);
        const lm: LossMap = .{ .stop = &stop, .blocks = &self.blocks };
        var queue: [BLOCKS_PER_CHUNK]CellId = undefined;
        var ring = Ring{ .queue = &queue };

        // Seed the emitters, only in a section with an emissive block in
        // its palette.
        for (&self.blocks.sections, 0..) |*sec, s| {
            const any = for (sec.palette()) |b| {
                if (light.emission(b) > 0) break true;
            } else false;
            if (!any) continue;
            for (0..CHUNK_W) |x| for (0..section_mod.SIZE) |yy| for (0..CHUNK_W) |z| {
                const e = light.emission(sec.get(section_mod.cellIndex(x, yy, z)));
                if (e == 0) continue;
                const y = s * section_mod.SIZE + yy;
                bl[x][y][z] = e;
                ring.push(x, y, z);
            };
        }
        seedFromNeighbours(&bl, lm, &ring, .{ nx_neg, nx_pos, nz_neg, nz_pos }, .block);
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

    /// The sky light and the block light of cell (x, y, z). The mesher
    /// reads the light of a cell with this function.
    pub fn lightAt(self: BlockGetter, x: i32, y: i32, z: i32) CellLight {
        return .{ .sky = self.getSkylight(x, y, z), .block = self.getBlockLight(x, y, z) };
    }

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
