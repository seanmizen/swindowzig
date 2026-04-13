const std = @import("std");
const world_gen = @import("world_gen.zig");

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
pub const CHUNK_H = 256; // Y dimension (matches classic Minecraft build height)

pub const BlockType = enum(u8) {
    air = 0,
    grass = 1,
    dirt = 2,
    stone = 3,
    bedrock = 4,
    /// Minecraft-style glowstone: solid (blocks propagation, culls faces) but
    /// emits `MAX_BLOCK_LIGHT` from its own cell. Seeded during
    /// `computeBlockLight` and propagated outward through adjacent air.
    glowstone = 5,
    /// Oak log / tree trunk. Brown block placed during tree generation.
    /// Solid and opaque — no special light properties.
    wood = 6,
    /// Oak leaf block. Dark green, placed in the spherical canopy around tree tops.
    /// Solid for face-culling purposes (keeps mesh generation simple).
    leaves = 7,
    debug_marker = 99,
};

/// Maximum skylight level. Matches Minecraft's 4-bit (0..15) range — we store
/// it in a u8 right now because the engine doesn't yet care about packing
/// multiple light channels. See `examples/voxel/docs/lighting.md` for the
/// full reasoning.
pub const MAX_SKYLIGHT: u8 = 15;

/// Maximum block-light level. Same [0, 15] range as skylight; phase-3 block
/// light uses a parallel storage nibble and an independent BFS. See
/// `examples/voxel/docs/lighting.md` § phase 3 for the design.
pub const MAX_BLOCK_LIGHT: u8 = 15;

/// Emission level for each block type. Non-emissive blocks return 0; the BFS
/// seed pass writes this value into every emissive cell's `block_light` slot
/// before any propagation runs. Phase-3 only ships glowstone (level 15);
/// torches and lava can be added later by extending this switch — no other
/// code path needs to change.
pub fn emissionLevel(block: BlockType) u8 {
    return switch (block) {
        .glowstone => MAX_BLOCK_LIGHT,
        else => 0,
    };
}

/// Total blocks in a column.
pub const BLOCKS_PER_CHUNK: usize = CHUNK_W * CHUNK_H * CHUNK_W;

/// Flat linear index for a block position within a chunk. Matches the
/// `packBlockIdx` layout used by `mesher.zig` so a mesher-computed index
/// can be reused verbatim when the mesher wants to look up the block type.
pub inline fn blockLinearIdx(x: i32, y: i32, z: i32) usize {
    return @as(usize, @intCast(x)) * (CHUNK_H * CHUNK_W) +
        @as(usize, @intCast(y)) * CHUNK_W +
        @as(usize, @intCast(z));
}

/// Minecraft-style palette-compressed block storage for a single chunk.
///
/// A paletted chunk tracks which `BlockType`s actually appear in the column
/// and stores per-block indices into that palette in a packed `[]u64` bit
/// array. Bit width is chosen from palette size:
///
///   palette size | bits_per_entry | raw block_bytes (48×256×48)
///   ------------ | -------------- | ---------------------------
///      1         |   0 (uniform)  |      0   (single-constant, no data)
///      2         |   1            |  73 728
///      3–4       |   2            | 147 456
///      5–8       |   3            | 221 184  (aligned-pack: 21 entries/u64)
///      9–16      |   4            | 294 912
///     17–32      |   5            | 368 640  (12 entries/u64)
///     33–64      |   6            | 442 368  (10 entries/u64)
///     65–128     |   7            | 516 096  (9 entries/u64)
///    129–256     |   8            | 589 824  (8 entries/u64)
///
/// "Aligned packing" means each `u64` holds `floor(64 / bits)` entries side
/// by side with no entry crossing a word boundary. A handful of bits are
/// wasted per word for widths 3/5/6/7 — we trade that for trivial get/set.
///
/// Palette entries are append-only in insertion order. The engine never
/// shrinks the palette: once a block type has been seen in a chunk it stays
/// in the table, and growing past a power-of-two boundary triggers a single
/// full re-pack into a wider `data` array. (Shrink/compact is explicitly
/// out of scope for this pass — see `docs/memory.md` for the ranking.)
///
/// Invariants:
///   - `palette_len >= 1` always (slot 0 is `.air` after `init`).
///   - `bits_per_entry == 0` iff `palette_len == 1` iff `data.len == 0`.
///     All reads in that state return `palette[0]` without touching `data`.
pub const PalettedBlocks = struct {
    /// Up to 256 distinct block types — matches `BlockType`'s `u8` width so
    /// the palette can never overflow. Unused slots hold `.air` as a
    /// harmless sentinel. Fixed-size so palette growth never allocates; the
    /// only heap path is growing `data` when `bits_per_entry` increases.
    palette: [256]BlockType = [_]BlockType{.air} ** 256,
    palette_len: u16 = 1,
    bits_per_entry: u8 = 0,
    data: []u64 = &[_]u64{},

    /// Return min bits needed to index a palette of `palette_size` entries.
    /// A uniform chunk (size 1) needs zero bits — we don't even allocate.
    fn minBitsFor(palette_size: usize) u8 {
        if (palette_size <= 1) return 0;
        var b: u8 = 1;
        var cap: usize = 2;
        while (cap < palette_size) : (b += 1) cap *= 2;
        return b;
    }

    /// Entries per u64 for aligned-pack layout. Only valid when bits > 0.
    inline fn entriesPerWord(bits: u8) usize {
        return 64 / @as(usize, bits);
    }

    /// Number of u64 words needed to hold BLOCKS_PER_CHUNK entries at the
    /// given bit width. Only valid when bits > 0.
    inline fn wordCountFor(bits: u8) usize {
        const epw = entriesPerWord(bits);
        return (BLOCKS_PER_CHUNK + epw - 1) / epw;
    }

    pub fn deinit(self: *PalettedBlocks, allocator: std.mem.Allocator) void {
        if (self.data.len > 0) allocator.free(self.data);
        self.* = .{};
    }

    /// Total RAM footprint of this paletted block array, in bytes. Counts
    /// the u64 backing store plus the fixed-size palette (256 BlockType
    /// slots = 256 bytes) so the number is comparable across chunks.
    pub fn sizeBytes(self: *const PalettedBlocks) usize {
        return @sizeOf([256]BlockType) + self.data.len * @sizeOf(u64);
    }

    /// Look up a block by linear index (see `blockLinearIdx`). Caller is
    /// responsible for bounds; OOB is UB in the sense that it will happily
    /// read past the end of `data` if the index is wrong.
    pub inline fn get(self: *const PalettedBlocks, idx: usize) BlockType {
        // Uniform fast path — every cell resolves to the single palette entry.
        if (self.bits_per_entry == 0) return self.palette[0];
        const bits: usize = self.bits_per_entry;
        const epw: usize = 64 / bits;
        const word = idx / epw;
        const slot = idx % epw;
        const bit_off: u6 = @intCast(slot * bits);
        const mask: u64 = (@as(u64, 1) << @intCast(bits)) - 1;
        const pi: usize = @intCast((self.data[word] >> bit_off) & mask);
        return self.palette[pi];
    }

    /// Write a block by linear index. Grows the palette and re-packs `data`
    /// if needed. Allocation only happens when `bits_per_entry` increases
    /// (at most `ceil(log2(256)) = 8` times over the lifetime of a chunk).
    pub fn set(
        self: *PalettedBlocks,
        allocator: std.mem.Allocator,
        idx: usize,
        block: BlockType,
    ) !void {
        // Find the block in the palette; append if new.
        var pi: usize = self.palette_len; // sentinel "not found"
        for (self.palette[0..self.palette_len], 0..) |b, i| {
            if (b == block) {
                pi = i;
                break;
            }
        }
        if (pi == self.palette_len) {
            // New entry — palette is a fixed-size array, so append is
            // just a write + length bump. Bit width might need to grow.
            self.palette[self.palette_len] = block;
            self.palette_len += 1;
            const required = minBitsFor(self.palette_len);
            if (required > self.bits_per_entry) {
                try self.grow(allocator, required);
            }
        }

        // Uniform chunk: still palette_len == 1, pi must be 0, nothing to write.
        if (self.bits_per_entry == 0) return;

        const bits: usize = self.bits_per_entry;
        const epw: usize = 64 / bits;
        const word = idx / epw;
        const slot = idx % epw;
        const bit_off: u6 = @intCast(slot * bits);
        const mask: u64 = (@as(u64, 1) << @intCast(bits)) - 1;
        const old_word = self.data[word];
        const cleared = old_word & ~(mask << bit_off);
        self.data[word] = cleared | ((@as(u64, @intCast(pi)) & mask) << bit_off);
    }

    /// Allocate a wider `data` array and re-pack every entry from the
    /// current layout into it. Called only from `set` on palette overflow.
    /// When growing from bits=0 (uniform) the new array is all-zeros, which
    /// correctly re-maps every block to palette[0] == the previous uniform
    /// value (slot 0 never moves).
    fn grow(self: *PalettedBlocks, allocator: std.mem.Allocator, new_bits: u8) !void {
        const new_word_count = wordCountFor(new_bits);
        const new_data = try allocator.alloc(u64, new_word_count);
        @memset(new_data, 0);

        const old_bits = self.bits_per_entry;
        if (old_bits > 0) {
            const old_epw: usize = 64 / @as(usize, old_bits);
            const new_epw: usize = 64 / @as(usize, new_bits);
            const old_mask: u64 = (@as(u64, 1) << @intCast(old_bits)) - 1;
            var i: usize = 0;
            while (i < BLOCKS_PER_CHUNK) : (i += 1) {
                const ow = i / old_epw;
                const os = i % old_epw;
                const o_off: u6 = @intCast(os * @as(usize, old_bits));
                const val = (self.data[ow] >> o_off) & old_mask;

                const nw = i / new_epw;
                const ns = i % new_epw;
                const n_off: u6 = @intCast(ns * @as(usize, new_bits));
                new_data[nw] |= val << n_off;
            }
        }

        if (self.data.len > 0) allocator.free(self.data);
        self.data = new_data;
        self.bits_per_entry = new_bits;
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
    /// after BFS propagation through air. Phase 1: per-chunk only — light
    /// does not cross chunk boundaries, so wide horizontal caves spanning
    /// two chunks will show a brightness seam at the join.
    ///
    /// Kept flat (one u8 per cell) on purpose. Skylight values are almost
    /// always unique per-cell in an air column, so palette compression on
    /// this grid would bloat rather than shrink it. See `docs/memory.md`
    /// §2 for the reasoning.
    skylight: [CHUNK_W][CHUNK_H][CHUNK_W]u8,
    /// Per-block block-light value, range [0, MAX_BLOCK_LIGHT]. Computed by
    /// `computeBlockLight()` after `generateTerrain()` and again whenever a
    /// block is placed or removed. Unlike skylight, emissive blocks (e.g.
    /// glowstone) store their OWN emission level in this slot even though
    /// they are solid — this is what lets the mesher read a bright value for
    /// a glowstone's own face without the sample escaping to a dim outward
    /// air cell. Non-emissive solids and unlit air stay at 0.
    ///
    /// Phase-3 scope: per-chunk BFS only. A glowstone placed near a chunk
    /// edge will NOT push light into the neighbour chunk. The seam is small
    /// in practice because block light decays to 0 within 15 cells and
    /// glowstones are explicitly placed, but it is a documented limitation.
    block_light: [CHUNK_W][CHUNK_H][CHUNK_W]u8,

    pub fn init(allocator: std.mem.Allocator) Chunk {
        return .{
            .allocator = allocator,
            .blocks = PalettedBlocks{},
            .skylight = std.mem.zeroes([CHUNK_W][CHUNK_H][CHUNK_W]u8),
            .block_light = std.mem.zeroes([CHUNK_W][CHUNK_H][CHUNK_W]u8),
        };
    }

    pub fn deinit(self: *Chunk) void {
        self.blocks.deinit(self.allocator);
    }

    /// RAM used by this chunk's block storage (palette + packed data).
    /// Does NOT include the skylight grid — that's reported separately by
    /// `skylightBytes` because it's on a different optimization track.
    pub fn blockDataBytes(self: *const Chunk) usize {
        return self.blocks.sizeBytes();
    }

    pub fn skylightBytes(_: *const Chunk) usize {
        return @sizeOf([CHUNK_W][CHUNK_H][CHUNK_W]u8);
    }

    /// Sum of block-data + skylight bytes. Roughly comparable to the
    /// pre-palette-compression 576 KB per-chunk figure in `docs/memory.md`,
    /// which counted only the raw `[W][H][W]BlockType` array. For an apples-
    /// to-apples comparison use `blockDataBytes` (ignoring the palette table
    /// overhead, which is a flat 256 bytes regardless of contents).
    pub fn totalBytes(self: *const Chunk) usize {
        return self.blockDataBytes() + self.skylightBytes();
    }

    /// Current number of distinct block types present in this chunk.
    /// Useful for the per-chunk size log line and for tests that want to
    /// assert palette-fit behaviour.
    pub fn paletteLen(self: *const Chunk) usize {
        return self.blocks.palette_len;
    }

    pub fn bitsPerEntry(self: *const Chunk) u8 {
        return self.blocks.bits_per_entry;
    }

    pub fn getBlock(self: *const Chunk, x: i32, y: i32, z: i32) BlockType {
        if (x < 0 or x >= CHUNK_W or y < 0 or y >= CHUNK_H or z < 0 or z >= CHUNK_W) {
            return .air;
        }
        return self.blocks.get(blockLinearIdx(x, y, z));
    }

    /// Bounds-free block read. Caller MUST guarantee `0 <= x < CHUNK_W`,
    /// `0 <= y < CHUNK_H`, `0 <= z < CHUNK_W`. This is the fast path used
    /// by the mesher's in-chunk face-culling and AO sampling loops — the
    /// old code read `chunk.blocks[x][y][z]` directly there, so callers
    /// already have the bounds check inlined one level up. Marked `inline`
    /// so the compiler can fold it into the mesher's hot loops without an
    /// extra call.
    pub inline fn resolveBlockRaw(self: *const Chunk, x: i32, y: i32, z: i32) BlockType {
        return self.blocks.get(blockLinearIdx(x, y, z));
    }

    pub fn setBlock(self: *Chunk, x: i32, y: i32, z: i32, block: BlockType) !void {
        if (x < 0 or x >= CHUNK_W or y < 0 or y >= CHUNK_H or z < 0 or z >= CHUNK_W) {
            return;
        }
        try self.blocks.set(self.allocator, blockLinearIdx(x, y, z), block);
    }

    /// Read the skylight at (x, y, z) using local chunk coordinates.
    /// Returns MAX_SKYLIGHT for any coordinate above the chunk top (so faces
    /// looking at the open sky stay bright) and 0 elsewhere out of bounds.
    /// The "bright above, dark elsewhere" asymmetry is what makes faces at
    /// the top of the world look right without a heightmap.
    pub fn getSkylight(self: *const Chunk, x: i32, y: i32, z: i32) u8 {
        if (y >= CHUNK_H) return MAX_SKYLIGHT; // above world top = open sky
        if (x < 0 or x >= CHUNK_W or y < 0 or z < 0 or z >= CHUNK_W) return 0;
        return self.skylight[@intCast(x)][@intCast(y)][@intCast(z)];
    }

    /// Read the block-light at (x, y, z) using local chunk coordinates.
    /// Out-of-bounds returns 0 (no "above world" bright-side asymmetry — block
    /// light has no global seed like the sun). Phase-3 cross-chunk propagation
    /// is out of scope; that means a glowstone placed near a chunk edge lights
    /// only its own chunk.
    pub fn getBlockLight(self: *const Chunk, x: i32, y: i32, z: i32) u8 {
        if (x < 0 or x >= CHUNK_W or y < 0 or y >= CHUNK_H or z < 0 or z >= CHUNK_W) return 0;
        return self.block_light[@intCast(x)][@intCast(y)][@intCast(z)];
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
    pub fn computeSkylight(self: *Chunk) void {
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
                        self.skylight[xu][yu][zu] = 0;
                    } else if (!seen_solid) {
                        self.skylight[xu][yu][zu] = MAX_SKYLIGHT;
                    } else {
                        self.skylight[xu][yu][zu] = 0;
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
                        if (self.skylight[xu][yu][zu] != level) continue;
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
                            if (self.skylight[nxu][nyu][nzu] >= target) continue;
                            self.skylight[nxu][nyu][nzu] = target;
                        }
                    }
                }
            }
        }
    }

    /// Recompute block-light for the entire chunk from the current `blocks`
    /// array. Same shape as `computeSkylight`, seeded differently:
    ///
    ///   Pass 1 (emission seed):
    ///     Walk every cell. Air cells and non-emissive solids get 0.
    ///     Emissive blocks (see `emissionLevel`) get their emission level
    ///     stored directly in `block_light[x][y][z]`, even though the cell
    ///     is solid — this is what makes a glowstone's own face read bright
    ///     when the mesher later samples with `max(outward_mean, owner_bl)`.
    ///
    ///   Pass 2 (bucket-sort BFS, levels MAX_BLOCK_LIGHT down to 2):
    ///     For each level L, sweep the chunk and for each cell (emissive
    ///     solid OR air) with block_light == L, propagate (L - 1) into any
    ///     AIR neighbour whose current value is strictly lower. Solid
    ///     neighbours (including other emissive blocks) are skipped — light
    ///     cannot travel through glowstone the same way skylight cannot
    ///     travel through stone.
    ///
    /// O(MAX_BLOCK_LIGHT × N). In practice the sweep is dominated by
    /// cells with value 0 that short-circuit on the first check, so this is
    /// a small fraction of the skylight pass on chunks with no emitters
    /// (early-out: if pass 1 finds no emitters, pass 2 is a no-op).
    /// Allocator-free by design so it can be called from `generateTerrain`
    /// and `World.setBlock` without touching call sites.
    ///
    /// Cross-chunk propagation is out of scope in phase 3. The BFS never
    /// pushes light into a neighbouring chunk's array; a glowstone placed
    /// right at a chunk edge will light only its own chunk. Phase 4 should
    /// mirror the planned cross-chunk skylight fix.
    pub fn computeBlockLight(self: *Chunk) void {
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
                    self.block_light[xu][yu][zu] = emit;
                    if (emit > 0) any_emitter = true;
                }
            }
        }

        // Fast path: no emitters, nothing to propagate.
        if (!any_emitter) return;

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
                        if (self.block_light[xu][yu][zu] != level) continue;
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
                            if (self.block_light[nxu][nyu][nzu] >= target) continue;
                            self.block_light[nxu][nyu][nzu] = target;
                        }
                    }
                }
            }
        }
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
    ///     correct for the common case: glowstone is at most CHUNK_W-1 = 15
    ///     cells from an edge, and MAX_BLOCK_LIGHT = 15, so the light budget
    ///     reaching the far side of the adjacent chunk would already be ≤ 1
    ///     and therefore zero after our one-hop decay.
    pub fn computeBlockLightWithNeighbors(
        self: *Chunk,
        nx_neg: ?*const Chunk, // chunk at cx-1: their x=CHUNK_W-1 is our x=0 border
        nx_pos: ?*const Chunk, // chunk at cx+1: their x=0 is our x=CHUNK_W-1 border
        nz_neg: ?*const Chunk, // chunk at cz-1: their z=CHUNK_W-1 is our z=0 border
        nz_pos: ?*const Chunk, // chunk at cz+1: their z=0 is our z=CHUNK_W-1 border
    ) void {
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
                    self.block_light[xu][yu][zu] = emit;
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
                    const nv = nb.block_light[CHUNK_W - 1][yy][zz];
                    if (nv >= 2 and self.resolveBlockRaw(0, @intCast(yy), @intCast(zz)) == .air) {
                        const seed: u8 = nv - 1;
                        if (seed > self.block_light[0][yy][zz]) {
                            self.block_light[0][yy][zz] = seed;
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
                    const nv = nb.block_light[0][yy][zz];
                    if (nv >= 2 and self.resolveBlockRaw(CHUNK_W - 1, @intCast(yy), @intCast(zz)) == .air) {
                        const seed: u8 = nv - 1;
                        if (seed > self.block_light[CHUNK_W - 1][yy][zz]) {
                            self.block_light[CHUNK_W - 1][yy][zz] = seed;
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
                    const nv = nb.block_light[xx][yy][CHUNK_W - 1];
                    if (nv >= 2 and self.resolveBlockRaw(@intCast(xx), @intCast(yy), 0) == .air) {
                        const seed: u8 = nv - 1;
                        if (seed > self.block_light[xx][yy][0]) {
                            self.block_light[xx][yy][0] = seed;
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
                    const nv = nb.block_light[xx][yy][0];
                    if (nv >= 2 and self.resolveBlockRaw(@intCast(xx), @intCast(yy), CHUNK_W - 1) == .air) {
                        const seed: u8 = nv - 1;
                        if (seed > self.block_light[xx][yy][CHUNK_W - 1]) {
                            self.block_light[xx][yy][CHUNK_W - 1] = seed;
                            any_emitter = true;
                        }
                    }
                }
            }
        }

        // Fast path: no emitters or neighbour seeds, nothing to propagate.
        if (!any_emitter) return;

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
                        if (self.block_light[xu][yu][zu] != level) continue;
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
                            if (self.block_light[nxu][nyu][nzu] >= target) continue;
                            self.block_light[nxu][nyu][nzu] = target;
                        }
                    }
                }
            }
        }
    }

    /// Generate terrain for this chunk at chunk grid position (cx, cz).
    ///
    /// Layout per column (surface = noise-sampled height):
    ///   Y=0             bedrock
    ///   Y=1..(surface-4) stone
    ///   Y=(surface-3)..(surface-1) dirt (3 layers)
    ///   Y=surface       grass
    ///
    /// For the flatland preset (noise_octaves=0), surface is always
    /// terrain_height_min=63, reproducing the original Minecraft superflat layout.
    ///
    /// Returns `!void` because `setBlock` on the paletted store allocates
    /// when the palette grows past a power-of-two boundary (out-of-memory
    /// is the only realistic failure mode — on typical hardware this path
    /// never trips).
    pub fn generateTerrain(self: *Chunk, cx: i32, cz: i32, config: world_gen.WorldGenConfig) !void {
        const t_fill_start = if (@import("builtin").cpu.arch == .wasm32) @as(i128, 0) else std.time.nanoTimestamp();
        var x: i32 = 0;
        while (x < CHUNK_W) : (x += 1) {
            var z: i32 = 0;
            while (z < CHUNK_W) : (z += 1) {
                const wx = cx * CHUNK_W + x;
                const wz = cz * CHUNK_W + z;
                const surface = world_gen.sampleHeight(wx, wz, config);

                try self.setBlock(x, 0, z, .bedrock);

                // Stone fills from Y=1 up to (but not including) the 3-dirt band.
                var y: i32 = 1;
                while (y < surface - 3) : (y += 1) {
                    try self.setBlock(x, y, z, .stone);
                }

                // Three dirt layers immediately below the surface.
                y = @max(1, surface - 3);
                while (y < surface) : (y += 1) {
                    try self.setBlock(x, y, z, .dirt);
                }

                // Grass cap.
                if (surface >= 1 and surface < CHUNK_H) {
                    try self.setBlock(x, surface, z, .grass);
                }

                // Scatter glowstone in the stone layer below Y=40 with
                // ~0.2% probability per block. Uses a splitmix-style hash
                // seeded from (wx, wz, y) for deterministic placement.
                const glow_ceil: i32 = @min(40, surface - 4);
                var gy: i32 = 2; // skip bedrock at Y=0, start above
                while (gy < glow_ceil) : (gy += 1) {
                    const seed = @as(u32, @bitCast(wx)) *% 374761393 +%
                        @as(u32, @bitCast(wz)) *% 668265263 +%
                        @as(u32, @bitCast(gy)) *% 2654435761;
                    const h = (seed ^ (seed >> 16)) *% 0x45d9f3b;
                    if ((h & 0x1FF) == 0) { // ~1/512 chance
                        try self.setBlock(x, gy, z, .glowstone);
                    }
                }
            }
        }
        const t_fill_us = if (@import("builtin").cpu.arch == .wasm32) @as(i128, 0) else @divTrunc(std.time.nanoTimestamp() - t_fill_start, 1000);

        // Cave carver: run after terrain fill so we only carve into solid blocks.
        // Only active for non-flat terrain (noise_octaves > 0).
        if (config.noise_octaves > 0) {
            var cx_idx: i32 = 0;
            while (cx_idx < CHUNK_W) : (cx_idx += 1) {
                var cz_idx: i32 = 0;
                while (cz_idx < CHUNK_W) : (cz_idx += 1) {
                    const wx = cx * CHUNK_W + cx_idx;
                    const wz = cz * CHUNK_W + cz_idx;
                    const surface = world_gen.sampleHeight(wx, wz, config);
                    // Carve from Y=4 (above bedrock zone) to surface-5 (preserve topsoil).
                    var wy: i32 = 4;
                    while (wy < surface - 4) : (wy += 1) {
                        if (world_gen.shouldCarve(wx, wy, wz)) {
                            try self.setBlock(cx_idx, wy, cz_idx, .air);
                        }
                    }
                }
            }
        }

        // Tree planter: place oak trees seeded from world coordinates.
        // Searches a halo around the chunk so canopy from trees in adjacent
        // chunks is correctly placed here as well.
        // Only active for non-flat terrain.
        if (config.noise_octaves > 0) {
            const TREE_SEARCH: i32 = 11; // max trunk_height + canopy_radius
            var tree_wx: i32 = cx * CHUNK_W - TREE_SEARCH;
            while (tree_wx < cx * CHUNK_W + CHUNK_W + TREE_SEARCH) : (tree_wx += 1) {
                var tree_wz: i32 = cz * CHUNK_W - TREE_SEARCH;
                while (tree_wz < cz * CHUNK_W + CHUNK_W + TREE_SEARCH) : (tree_wz += 1) {
                    if (!world_gen.isTreeCenter(tree_wx, tree_wz)) continue;

                    const tree_surface = world_gen.sampleHeight(tree_wx, tree_wz, config);
                    const trunk_h = world_gen.treeHeight(tree_wx, tree_wz);
                    const trunk_base = tree_surface + 1;
                    const trunk_top = tree_surface + trunk_h;

                    // Place trunk — setBlock ignores out-of-chunk coords silently.
                    var ty: i32 = trunk_base;
                    while (ty <= trunk_top) : (ty += 1) {
                        const lx = tree_wx - cx * CHUNK_W;
                        const lz = tree_wz - cz * CHUNK_W;
                        if (self.getBlock(lx, ty, lz) == .air) {
                            try self.setBlock(lx, ty, lz, .wood);
                        }
                    }

                    // Place spherical leaf canopy (radius ~3) around trunk top.
                    const CANOPY_R: i32 = 3;
                    var dy: i32 = -CANOPY_R;
                    while (dy <= CANOPY_R) : (dy += 1) {
                        var dx: i32 = -CANOPY_R;
                        while (dx <= CANOPY_R) : (dx += 1) {
                            var dz: i32 = -CANOPY_R;
                            while (dz <= CANOPY_R) : (dz += 1) {
                                if (dx * dx + dy * dy + dz * dz > CANOPY_R * CANOPY_R) continue;
                                // Don't overwrite trunk column blocks.
                                if (dx == 0 and dz == 0 and dy <= 0) continue;
                                const lx = tree_wx + dx - cx * CHUNK_W;
                                const ly = trunk_top + dy;
                                const lz = tree_wz + dz - cz * CHUNK_W;
                                if (ly < 1 or ly >= CHUNK_H) continue;
                                if (self.getBlock(lx, ly, lz) == .air) {
                                    try self.setBlock(lx, ly, lz, .leaves);
                                }
                            }
                        }
                    }
                }
            }
        }

        // Skylight: must run after the blocks array is fully populated, since
        // the BFS reads `blocks` to know which cells block propagation.
        const t_sky_start = if (@import("builtin").cpu.arch == .wasm32) @as(i128, 0) else std.time.nanoTimestamp();
        self.computeSkylight();
        const t_sky_us = if (@import("builtin").cpu.arch == .wasm32) @as(i128, 0) else @divTrunc(std.time.nanoTimestamp() - t_sky_start, 1000);
        // Block light: now seeds from glowstone emitters scattered during
        // generation. The BFS propagates their light through nearby air cells.
        self.computeBlockLight();

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
