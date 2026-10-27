//! A paletted block section: the blocks of a 16 × 16 × 16 cube of cells.
//!
//! A section keeps a palette: the list of the block types that it holds.
//! Each cell holds an index into the palette, and the indices are packed
//! into u64 words. A section with one block type has no index array, only
//! that block type.
//!
//! Packing. The index width is 0, 1, 2, 4 or 8 bits: the smallest power of
//! two that can index the palette.
//!
//!   palette entries | index bits | index bytes
//!   --------------- | ---------- | -----------
//!         1         |     0      |     0
//!         2         |     1      |   512
//!        3-4        |     2      |  1024
//!        5-16       |     4      |  2048
//!       17-256      |     8      |  4096
//!
//! A power-of-two width divides 64, so an index never crosses a word, and
//! the word and the bit offset of cell i come from shifts: bit position
//! i × bits, word = position / 64, offset = position % 64. No division and
//! no lookup table is necessary. The cost is some unused bits for palettes
//! of 5 to 8 entries (4 bits, not 3) and of 17 to 128 entries (8 bits, not
//! 5 to 7). The bit width grows when the palette grows past the capacity
//! of the width. Then the indices are packed again into a wider array.
//!
//! Cell order: index = x × 256 + y × 16 + z (`cellIndex`). The 256 cells of
//! one x are contiguous, in the same y, z order as the dense buffer of a
//! chunk (`chunk.blockLinearIdx`). So a section decodes to a dense chunk
//! buffer in 16 runs of 256 cells.
//!
//! Memory. The indices and the palette are in one heap array (`buf`): the
//! index words first, then the palette, with 1 << bits slots. A section
//! with one block type has no heap memory.
const std = @import("std");
const content = @import("content.zig");

/// The block types of the game. Value 0 is `.air`.
pub const BlockType = content.Block;

/// Edge length of a section, in cells.
pub const SIZE = 16;
/// Number of cells in a section.
pub const CELLS = SIZE * SIZE * SIZE;
/// Number of cells of one x in a section: one run of `decodeRuns`.
pub const RUN = SIZE * SIZE;

/// Index of cell (x, y, z) of a section. Each value must be less than SIZE.
pub inline fn cellIndex(x: usize, y: usize, z: usize) usize {
    return (x << 8) | (y << 4) | z;
}

pub const Section = struct {
    /// Bits of each index: 0, 1, 2, 4 or 8.
    bits: u8 = 0,
    /// Number of palette entries. 1 when `bits` is 0.
    len: u16 = 1,
    /// The block type of each cell when `bits` is 0.
    single: BlockType = .air,
    /// When `bits` > 0: `indexWords(bits)` index words, then the palette
    /// (1 << bits slots of one byte). Empty when `bits` is 0.
    buf: []u64 = &.{},

    /// A section with one block type in each cell.
    pub fn uniform(block: BlockType) Section {
        return .{ .single = block };
    }

    /// The index width for a palette of `n` entries (1 to 256).
    pub fn bitsFor(n: usize) u8 {
        std.debug.assert(n >= 1 and n <= 256);
        if (n <= 1) return 0;
        if (n <= 2) return 1;
        if (n <= 4) return 2;
        if (n <= 16) return 4;
        return 8;
    }

    /// Number of u64 index words at width `bits`.
    pub fn indexWords(bits: u8) usize {
        return CELLS * @as(usize, bits) / 64;
    }

    /// Number of u64 words that hold the palette at width `bits` (> 0).
    pub fn paletteWords(bits: u8) usize {
        return ((@as(usize, 1) << @intCast(bits)) + 7) / 8;
    }

    pub fn deinit(self: *Section, allocator: std.mem.Allocator) void {
        if (self.buf.len > 0) allocator.free(self.buf);
        self.* = .{};
    }

    /// Heap bytes of the section.
    pub fn heapBytes(self: *const Section) usize {
        return self.buf.len * @sizeOf(u64);
    }

    /// The palette entries, in the order that they were added.
    pub fn palette(self: *const Section) []const BlockType {
        if (self.bits == 0) return @as(*const [1]BlockType, &self.single);
        return slots(self.buf, self.bits)[0..self.len];
    }

    /// The packed index words. Empty when `bits` is 0.
    pub fn indices(self: *const Section) []const u64 {
        return self.buf[0..indexWords(self.bits)];
    }

    /// True when each cell has the same block type and there is no index
    /// array.
    pub fn isUniform(self: *const Section) bool {
        return self.bits == 0;
    }

    /// The palette slots of `buf` at width `bits` (> 0): 1 << bits entries.
    fn slots(buf: []u64, bits: u8) []BlockType {
        const bytes = std.mem.sliceAsBytes(buf[indexWords(bits)..]);
        return std.mem.bytesAsSlice(BlockType, bytes[0 .. @as(usize, 1) << @intCast(bits)]);
    }

    /// The palette index of cell `i`. `bits` must be > 0.
    inline fn indexOf(self: *const Section, i: usize) usize {
        const pos = i * self.bits;
        const mask = (@as(u64, 1) << @intCast(self.bits)) - 1;
        return @intCast((self.buf[pos >> 6] >> @intCast(pos & 63)) & mask);
    }

    /// The block type of cell `i` (see `cellIndex`).
    pub inline fn get(self: *const Section, i: usize) BlockType {
        if (self.bits == 0) return self.single;
        const pal: [*]const BlockType = @ptrCast(self.buf.ptr + indexWords(self.bits));
        return pal[self.indexOf(i)];
    }

    /// Set cell `i` to `block`. A new block type goes into the palette. The
    /// index array is allocated or made wider when the palette is full.
    pub fn set(self: *Section, allocator: std.mem.Allocator, i: usize, block: BlockType) !void {
        const pi = self.find(block) orelse try self.add(allocator, block);
        if (self.bits == 0) return;
        const pos = i * self.bits;
        const off: u6 = @intCast(pos & 63);
        const mask = (@as(u64, 1) << @intCast(self.bits)) - 1;
        const w = &self.buf[pos >> 6];
        w.* = (w.* & ~(mask << off)) | (@as(u64, @intCast(pi)) << off);
    }

    /// The palette index of `block`, or null.
    fn find(self: *const Section, block: BlockType) ?usize {
        for (self.palette(), 0..) |b, k| {
            if (b == block) return k;
        }
        return null;
    }

    /// Add `block` to the palette and return its index. The indices get
    /// wider when the palette is full.
    fn add(self: *Section, allocator: std.mem.Allocator, block: BlockType) !usize {
        const n: usize = self.len;
        const want = bitsFor(n + 1);
        if (want != self.bits) try self.widen(allocator, want);
        slots(self.buf, self.bits)[n] = block;
        self.len = @intCast(n + 1);
        return n;
    }

    /// Pack the indices again at the width `new_bits`. The palette indices
    /// do not change. From width 0, each cell gets index 0, the old block.
    fn widen(self: *Section, allocator: std.mem.Allocator, new_bits: u8) !void {
        const buf = try allocator.alloc(u64, indexWords(new_bits) + paletteWords(new_bits));
        @memset(buf, 0);
        const new_slots = slots(buf, new_bits);
        if (self.bits == 0) {
            new_slots[0] = self.single;
        } else {
            @memcpy(new_slots[0..self.len], self.palette());
            const nb: usize = new_bits;
            for (0..CELLS) |i| {
                const pos = i * nb;
                buf[pos >> 6] |= @as(u64, @intCast(self.indexOf(i))) << @intCast(pos & 63);
            }
            allocator.free(self.buf);
        }
        self.buf = buf;
        self.bits = new_bits;
        self.single = .air;
    }

    /// A section with the block types of `cells` (in `cellIndex` order).
    /// The palette has the block types in the order of their first cell,
    /// and the index width is the smallest for that palette.
    pub fn fromCells(allocator: std.mem.Allocator, cells: *const [CELLS]BlockType) !Section {
        const none: u16 = 0xFFFF;
        var index_of: [256]u16 = @splat(none);
        var pal: [256]BlockType = undefined;
        var n: usize = 0;
        for (cells) |b| {
            if (index_of[@backingInt(b)] != none) continue;
            index_of[@backingInt(b)] = @intCast(n);
            pal[n] = b;
            n += 1;
        }
        if (n == 1) return uniform(pal[0]);

        const bits = bitsFor(n);
        const buf = try allocator.alloc(u64, indexWords(bits) + paletteWords(bits));
        @memset(buf, 0);
        @memcpy(slots(buf, bits)[0..n], pal[0..n]);
        const epw: usize = 64 / @as(usize, bits);
        const shift: u6 = @intCast(bits);
        for (buf[0..indexWords(bits)], 0..) |*word, wi| {
            // Pack the last entry of the word first, so that each entry
            // goes in at its slot × bits offset.
            var w: u64 = 0;
            var k = epw;
            while (k > 0) {
                k -= 1;
                w = (w << shift) | index_of[@backingInt(cells[wi * epw + k])];
            }
            word.* = w;
        }
        return .{ .bits = bits, .len = @intCast(n), .buf = buf };
    }

    /// Write the block type of each cell into `out`, in `cellIndex` order.
    pub fn toCells(self: *const Section, out: *[CELLS]BlockType) void {
        if (self.bits == 0) return @memset(out, self.single);
        for (out, 0..) |*c, i| c.* = self.get(i);
    }

    /// Make the palette hold only the block types that the cells use, with
    /// the smallest index width. An edit can leave a palette entry that no
    /// cell uses. `set` never removes an entry. A section with one block type
    /// then has no index array.
    pub fn compact(self: *Section, allocator: std.mem.Allocator) !void {
        if (self.bits == 0) return;
        var cells: [CELLS]BlockType = undefined;
        self.toCells(&cells);
        const out = try fromCells(allocator, &cells);
        self.deinit(allocator);
        self.* = out;
    }

    /// Write `value[block]` for each cell. The 256 cells of one x (in y, z
    /// order) are one run: run x goes to `out[x * stride ..][0..RUN]`.
    pub fn decodeRuns(self: *const Section, value: *const [256]u8, out: [*]u8, stride: usize) void {
        if (self.bits == 0) {
            const v = value[@backingInt(self.single)];
            for (0..SIZE) |x| @memset(out[x * stride ..][0..RUN], v);
            return;
        }
        // The value of each palette index.
        var map: [256]u8 = @splat(0);
        for (self.palette(), 0..) |b, k| map[k] = value[@backingInt(b)];
        switch (self.bits) {
            inline 1, 2, 4, 8 => |bits| self.decodeBits(bits, &map, out, stride),
            else => unreachable,
        }
    }

    fn decodeBits(self: *const Section, comptime bits: u8, map: *const [256]u8, out: [*]u8, stride: usize) void {
        const epw: usize = 64 / @as(usize, bits);
        const mask: u64 = (@as(u64, 1) << bits) - 1;
        const words_per_run = RUN / epw;
        for (0..SIZE) |x| {
            const dst = out + x * stride;
            const words = self.buf[x * words_per_run ..][0..words_per_run];
            var idx: usize = 0;
            for (words) |word| {
                var w = word;
                inline for (0..epw) |k| {
                    dst[idx + k] = map[@intCast(w & mask)];
                    w >>= bits;
                }
                idx += epw;
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// The first `n` block types of the content, after air.
fn kinds(n: usize) []const BlockType {
    const all = comptime std.enums.values(BlockType);
    return all[1..][0..n];
}

test "a section with one block type has no index array" {
    const a = testing.allocator;
    var s: Section = .{};
    defer s.deinit(a);
    try testing.expect(s.isUniform());
    try testing.expectEqual(@as(usize, 0), s.heapBytes());
    // Setting the same block type again does not allocate.
    try s.set(a, cellIndex(3, 4, 5), .air);
    try testing.expect(s.isUniform());
    try testing.expectEqual(@as(usize, 0), s.heapBytes());

    var cells: [CELLS]BlockType = @splat(kinds(1)[0]);
    var f = try Section.fromCells(a, &cells);
    defer f.deinit(a);
    try testing.expect(f.isUniform());
    try testing.expectEqual(@as(usize, 0), f.heapBytes());
    try testing.expectEqual(kinds(1)[0], f.get(CELLS - 1));
}

test "the bit width grows when the palette grows" {
    const a = testing.allocator;
    const n_kinds = comptime std.enums.values(BlockType).len;
    var s: Section = .{};
    defer s.deinit(a);
    var want: [CELLS]BlockType = @splat(.air);
    var prng = std.Random.DefaultPrng.init(0x5ec7);
    const r = prng.random();
    // Add block types one at a time. After each new type, the width is the
    // smallest power of two for the palette, and each cell is still right.
    for (kinds(n_kinds - 1), 2..) |b, n| {
        for (0..97) |_| {
            const i = r.uintLessThan(usize, CELLS);
            want[i] = b;
            try s.set(a, i, b);
        }
        try testing.expectEqual(@as(u16, @intCast(n)), s.len);
        try testing.expectEqual(Section.bitsFor(n), s.bits);
        try testing.expectEqual(Section.indexWords(s.bits) + Section.paletteWords(s.bits), s.buf.len);
        for (want, 0..) |w, i| try testing.expectEqual(w, s.get(i));
    }
    // The widths for each palette size.
    try testing.expectEqual(@as(u8, 0), Section.bitsFor(1));
    try testing.expectEqual(@as(u8, 1), Section.bitsFor(2));
    try testing.expectEqual(@as(u8, 2), Section.bitsFor(3));
    try testing.expectEqual(@as(u8, 2), Section.bitsFor(4));
    try testing.expectEqual(@as(u8, 4), Section.bitsFor(5));
    try testing.expectEqual(@as(u8, 4), Section.bitsFor(16));
    try testing.expectEqual(@as(u8, 8), Section.bitsFor(17));
    try testing.expectEqual(@as(u8, 8), Section.bitsFor(256));
}

test "a full section: each cell set, every width" {
    const a = testing.allocator;
    const n_kinds = comptime std.enums.values(BlockType).len;
    // 2, 3, ... block types in a pattern over all 4096 cells, by set and by
    // fromCells. Both give each cell back.
    for (2..n_kinds + 1) |n| {
        const all = comptime std.enums.values(BlockType);
        var cells: [CELLS]BlockType = undefined;
        for (&cells, 0..) |*c, i| c.* = all[(i * 7 + i / 13) % n];
        var by_set: Section = .{};
        defer by_set.deinit(a);
        for (cells, 0..) |b, i| try by_set.set(a, i, b);
        var packed_cells = try Section.fromCells(a, &cells);
        defer packed_cells.deinit(a);
        try testing.expectEqual(Section.bitsFor(n), packed_cells.bits);
        try testing.expectEqual(@as(u16, @intCast(n)), packed_cells.len);
        var back: [CELLS]BlockType = undefined;
        packed_cells.toCells(&back);
        try testing.expectEqualSlices(BlockType, &cells, &back);
        for (cells, 0..) |b, i| try testing.expectEqual(b, by_set.get(i));
    }
}

test "get and set at the section edges" {
    const a = testing.allocator;
    var s: Section = .{};
    defer s.deinit(a);
    const b = kinds(2);
    // The block type of cell (x, y, z): b[0] at the 8 corners, b[1] on the
    // other cells of the 12 edges, else air.
    const pattern = struct {
        fn at(bb: []const BlockType, x: usize, y: usize, z: usize) BlockType {
            const on = @as(u8, @intFromBool(x == 0 or x == SIZE - 1)) +
                @as(u8, @intFromBool(y == 0 or y == SIZE - 1)) +
                @as(u8, @intFromBool(z == 0 or z == SIZE - 1));
            return switch (on) {
                3 => bb[0],
                2 => bb[1],
                else => .air,
            };
        }
    }.at;
    for (0..SIZE) |x| for (0..SIZE) |y| for (0..SIZE) |z| {
        const want = pattern(b, x, y, z);
        if (want != .air) try s.set(a, cellIndex(x, y, z), want);
    };
    for (0..SIZE) |x| for (0..SIZE) |y| for (0..SIZE) |z| {
        try testing.expectEqual(pattern(b, x, y, z), s.get(cellIndex(x, y, z)));
    };
    // The first and the last cell are in the first and the last index word.
    try testing.expectEqual(b[0], s.get(0));
    try testing.expectEqual(b[0], s.get(CELLS - 1));
}

test "compact removes unused palette entries" {
    const a = testing.allocator;
    var s: Section = .{};
    defer s.deinit(a);
    const b = kinds(3);
    try s.set(a, 10, b[0]);
    try s.set(a, 20, b[1]);
    try s.set(a, 30, b[2]);
    try testing.expectEqual(@as(u8, 2), s.bits);
    try s.set(a, 10, .air);
    try s.set(a, 30, .air);
    try s.compact(a);
    try testing.expectEqual(@as(u16, 2), s.len);
    try testing.expectEqual(@as(u8, 1), s.bits);
    try testing.expectEqual(b[1], s.get(20));
    try testing.expectEqual(BlockType.air, s.get(10));
    try s.set(a, 20, .air);
    try s.compact(a);
    try testing.expect(s.isUniform());
    try testing.expectEqual(@as(usize, 0), s.heapBytes());
}

test "decodeRuns writes each run at its stride" {
    const a = testing.allocator;
    var table: [256]u8 = undefined;
    for (&table, 0..) |*t, i| t.* = @truncate(i *% 37 +% 5);
    const n_kinds = comptime std.enums.values(BlockType).len;
    var prng = std.Random.DefaultPrng.init(0xdec0);
    const r = prng.random();
    const stride = RUN * 3;
    for (1..n_kinds + 1) |n| {
        const all = comptime std.enums.values(BlockType);
        var cells: [CELLS]BlockType = undefined;
        for (&cells) |*c| c.* = all[r.uintLessThan(usize, n)];
        var s = try Section.fromCells(a, &cells);
        defer s.deinit(a);
        var out: [SIZE * stride]u8 = @splat(0xEE);
        s.decodeRuns(&table, &out, stride);
        for (0..SIZE) |x| {
            for (0..RUN) |k| try testing.expectEqual(table[@backingInt(cells[x * RUN + k])], out[x * stride + k]);
            // The bytes between the runs do not change.
            for (RUN..stride) |k| try testing.expectEqual(@as(u8, 0xEE), out[x * stride + k]);
        }
    }
}
