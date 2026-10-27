//! Region files: the saved blocks of a square of chunks (REQ-VOXEL-011).
//!
//! A region holds SIZE × SIZE chunks. Region (rx, rz) holds the chunks
//! cx = rx × SIZE to rx × SIZE + SIZE - 1, and the same for z. Each chunk
//! is compressed on its own (zlib, `std.compress.flate`), so a damaged
//! chunk fails alone (REQ-VOXEL-013) and the other chunks still load.
//!
//! The file stores the blocks only. It stores the palette and the packed
//! indices of each section as they are in memory (`section.zig`). It does
//! not store the light. The light of a chunk depends on its neighbours, and
//! the chunk stages compute it from the blocks, so a loaded chunk gets its
//! light again from the light stage. A file without light is smaller, and
//! it cannot hold light that does not agree with the blocks.
//!
//! The format is the format of this engine. It is not the format of a game.
//! All numbers are little-endian. Format version 1:
//!
//!   offset  size  field
//!   ------  ----  -----------------------------------------------------
//!        0     4  magic "SWVR"
//!        4     2  format version (u16): 1
//!        6     2  chunks on each edge of the region (u16): SIZE
//!        8     4  rx (i32)
//!       12     4  rz (i32)
//!       16     4  min_y of the world (i32)
//!       20     4  height of the world (u32)
//!       24     4  reserved: 0
//!       28     4  CRC-32 of bytes 0 to 27 and of the offset table
//!       32  4096  offset table: SIZE × SIZE entries of 16 bytes, in the
//!                 order index = (cz - rz × SIZE) × SIZE + (cx - rx × SIZE)
//!     4128     -  the compressed chunks
//!
//!   A table entry: offset (u32, from the start of the file), compressed
//!   length (u32), length before compression (u32), CRC-32 of the
//!   compressed bytes (u32). An entry with length 0 has no chunk.
//!
//!   A chunk before compression: the number of sections (u16), then for
//!   each section from local y 0 upward: the palette length n (u16, 1 to
//!   256), n block IDs (u8), and `Section.indexWords(bits)` index words
//!   (u64) with bits = `Section.bitsFor(n)`.
//!
//! A version number lets a later format read old files: `decode` reads
//! each version that it knows, and the test "a version 1 file stays
//! readable" keeps a committed version 1 file readable (REQ-VOXEL-012).
//!
//! A region file is one value of a storage, for example `sw_assets.cache`
//! (a folder on native, OPFS on the web). A save writes the full region
//! again. `Store` gives the save and the load through a storage with the
//! API of `sw_assets.cache`.
//!
//! The block IDs are the IDs of the content (`content.Block`). When the
//! content changes the ID of a block, the old files hold the old IDs. The
//! game must change them.
const std = @import("std");
const chunk_mod = @import("chunk.zig");
const section_mod = @import("section.zig");
const flate = std.compress.flate;

const PalettedBlocks = chunk_mod.PalettedBlocks;
const Section = section_mod.Section;
const BlockType = chunk_mod.BlockType;

/// Chunks on each edge of a region.
pub const SIZE = 16;
/// Chunks in a region.
pub const CHUNKS = SIZE * SIZE;
/// The format version that `encode` writes.
pub const VERSION: u16 = 1;
/// The first 4 bytes of a region file.
pub const MAGIC = "SWVR";

const HEADER_LEN = 32;
const ENTRY_LEN = 16;
const TABLE_LEN = CHUNKS * ENTRY_LEN;
/// The offset of the first compressed chunk.
const DATA_START = HEADER_LEN + TABLE_LEN;

/// The largest chunk before compression: each section with 256 palette
/// entries and 8-bit indices. A table entry with a larger length is
/// damaged. Decompression stops at this length.
pub const MAX_RAW_LEN = 2 + chunk_mod.SECTION_COUNT * (2 + 256 + section_mod.CELLS);

pub const DecodeError = error{
    /// The file does not start with the magic.
    NotRegionFile,
    /// The format version is 0, or later than `VERSION`.
    UnsupportedVersion,
    /// The header or the offset table is damaged or too short.
    CorruptHeader,
    /// The file is from a world with another `min_y` or `height`.
    WrongWorldHeight,
    OutOfMemory,
};

pub const ChunkError = error{
    /// The bytes of the chunk are damaged. The other chunks are not
    /// affected.
    CorruptChunk,
    OutOfMemory,
};

/// The region that holds chunk column `c` (a cx or a cz).
pub fn regionCoord(c: i32) i32 {
    return @divFloor(c, SIZE);
}

/// One stored chunk.
pub const Slot = union(enum) {
    /// The region has no chunk here.
    empty,
    /// The compressed bytes, and the length before compression.
    stored: struct { data: []u8, raw_len: u32 },
    /// The file had a chunk here, but its bytes are damaged.
    corrupt,
};

/// The chunks of one region, compressed, in memory. `put` compresses a
/// chunk, `get` decompresses it. `encode` and `decode` give the bytes of
/// the file.
pub const Region = struct {
    allocator: std.mem.Allocator,
    rx: i32,
    rz: i32,
    slots: [CHUNKS]Slot = @splat(.empty),

    pub fn init(allocator: std.mem.Allocator, rx: i32, rz: i32) Region {
        return .{ .allocator = allocator, .rx = rx, .rz = rz };
    }

    pub fn deinit(self: *Region) void {
        for (&self.slots) |*s| self.clearSlot(s);
    }

    fn clearSlot(self: *Region, s: *Slot) void {
        if (s.* == .stored) self.allocator.free(s.stored.data);
        s.* = .empty;
    }

    /// True when chunk (cx, cz) is in this region.
    pub fn contains(self: *const Region, cx: i32, cz: i32) bool {
        return regionCoord(cx) == self.rx and regionCoord(cz) == self.rz;
    }

    /// The table index of chunk (cx, cz). The chunk must be in the region.
    pub fn slotIndex(self: *const Region, cx: i32, cz: i32) usize {
        std.debug.assert(self.contains(cx, cz));
        const lx: usize = @intCast(cx - self.rx * SIZE);
        const lz: usize = @intCast(cz - self.rz * SIZE);
        return lz * SIZE + lx;
    }

    /// The slot of chunk (cx, cz). The chunk must be in the region.
    pub fn slot(self: *const Region, cx: i32, cz: i32) Slot {
        return self.slots[self.slotIndex(cx, cz)];
    }

    /// The number of chunks with bytes (stored or corrupt).
    pub fn count(self: *const Region) usize {
        var n: usize = 0;
        for (self.slots) |s| n += @intFromBool(s != .empty);
        return n;
    }

    /// Compress the blocks of chunk (cx, cz) into the region. A chunk that
    /// is in the region already is replaced. The chunk must be in the
    /// region.
    pub fn put(self: *Region, cx: i32, cz: i32, blocks: *const PalettedBlocks) !void {
        const i = self.slotIndex(cx, cz);
        const data = try compressBlocks(self.allocator, blocks);
        self.clearSlot(&self.slots[i]);
        self.slots[i] = .{ .stored = .{ .data = data, .raw_len = @intCast(rawLen(blocks)) } };
    }

    /// Remove chunk (cx, cz). The chunk must be in the region.
    pub fn remove(self: *Region, cx: i32, cz: i32) void {
        self.clearSlot(&self.slots[self.slotIndex(cx, cz)]);
    }

    /// The blocks of chunk (cx, cz), or null when the region has no chunk
    /// there. The caller owns the result: free it with
    /// `PalettedBlocks.deinit(allocator)`. The chunk has no light: the light
    /// stage gives it again. The chunk must be in the region.
    pub fn get(self: *const Region, allocator: std.mem.Allocator, cx: i32, cz: i32) ChunkError!?PalettedBlocks {
        return switch (self.slot(cx, cz)) {
            .empty => null,
            .corrupt => error.CorruptChunk,
            .stored => |s| try decompressBlocks(allocator, s.data, s.raw_len),
        };
    }

    /// The bytes of the region file, in format `VERSION`. The caller owns
    /// them. A corrupt slot is written as an empty slot.
    pub fn encode(self: *const Region, allocator: std.mem.Allocator) ![]u8 {
        var total: usize = DATA_START;
        for (self.slots) |s| {
            if (s == .stored) total += s.stored.data.len;
        }
        if (total > std.math.maxInt(u32)) return error.RegionTooLarge;
        const out = try allocator.alloc(u8, total);
        @memset(out[0..DATA_START], 0);
        @memcpy(out[0..4], MAGIC);
        writeInt(u16, out, 4, VERSION);
        writeInt(u16, out, 6, SIZE);
        writeInt(i32, out, 8, self.rx);
        writeInt(i32, out, 12, self.rz);
        writeInt(i32, out, 16, chunk_mod.MIN_Y);
        writeInt(u32, out, 20, chunk_mod.CHUNK_H);
        var at: usize = DATA_START;
        for (self.slots, 0..) |s, i| {
            if (s != .stored) continue;
            const e = HEADER_LEN + i * ENTRY_LEN;
            const data = s.stored.data;
            writeInt(u32, out, e, @intCast(at));
            writeInt(u32, out, e + 4, @intCast(data.len));
            writeInt(u32, out, e + 8, s.stored.raw_len);
            writeInt(u32, out, e + 12, std.hash.Crc32.hash(data));
            @memcpy(out[at..][0..data.len], data);
            at += data.len;
        }
        writeInt(u32, out, 28, headerCrc(out));
        return out;
    }

    /// Read the bytes of a region file of format version 1 to `VERSION`.
    /// The region copies the compressed chunks, so the caller can free
    /// `bytes`. A chunk with damaged bytes, or with bytes after the end of
    /// the file, becomes a `.corrupt` slot: `get` then fails for that
    /// chunk alone.
    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) DecodeError!Region {
        if (bytes.len < 6 or !std.mem.eql(u8, bytes[0..4], MAGIC)) return error.NotRegionFile;
        const version = readInt(u16, bytes, 4);
        return switch (version) {
            1 => decodeV1(allocator, bytes),
            else => error.UnsupportedVersion,
        };
    }

    fn decodeV1(allocator: std.mem.Allocator, bytes: []const u8) DecodeError!Region {
        if (bytes.len < DATA_START) return error.CorruptHeader;
        if (readInt(u32, bytes, 28) != headerCrc(bytes)) return error.CorruptHeader;
        if (readInt(u16, bytes, 6) != SIZE) return error.CorruptHeader;
        if (readInt(i32, bytes, 16) != chunk_mod.MIN_Y or readInt(u32, bytes, 20) != chunk_mod.CHUNK_H)
            return error.WrongWorldHeight;
        var region = Region.init(allocator, readInt(i32, bytes, 8), readInt(i32, bytes, 12));
        errdefer region.deinit();
        for (&region.slots, 0..) |*s, i| {
            const e = HEADER_LEN + i * ENTRY_LEN;
            const offset: usize = readInt(u32, bytes, e);
            const len: usize = readInt(u32, bytes, e + 4);
            const raw_len = readInt(u32, bytes, e + 8);
            if (len == 0) continue;
            if (offset < DATA_START or offset > bytes.len or len > bytes.len - offset or
                raw_len > MAX_RAW_LEN or
                std.hash.Crc32.hash(bytes[offset..][0..len]) != readInt(u32, bytes, e + 12))
            {
                s.* = .corrupt;
                continue;
            }
            s.* = .{ .stored = .{ .data = try allocator.dupe(u8, bytes[offset..][0..len]), .raw_len = raw_len } };
        }
        return region;
    }
};

/// The CRC-32 of the header (without its CRC field) and the offset table.
fn headerCrc(bytes: []const u8) u32 {
    var crc = std.hash.Crc32.init();
    crc.update(bytes[0..28]);
    crc.update(bytes[HEADER_LEN..DATA_START]);
    return crc.final();
}

fn writeInt(comptime T: type, out: []u8, at: usize, v: T) void {
    std.mem.writeInt(T, out[at..][0..@sizeOf(T)], v, .little);
}

fn readInt(comptime T: type, bytes: []const u8, at: usize) T {
    return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .little);
}

/// The length of the chunk bytes before compression.
fn rawLen(blocks: *const PalettedBlocks) usize {
    var n: usize = 2;
    for (&blocks.sections) |*sec| n += 2 + sec.len + 8 * Section.indexWords(sec.bits);
    return n;
}

/// Write the chunk bytes (format version 1) to `w`.
fn writeBlocks(w: *std.Io.Writer, blocks: *const PalettedBlocks) std.Io.Writer.Error!void {
    try w.writeInt(u16, chunk_mod.SECTION_COUNT, .little);
    for (&blocks.sections) |*sec| {
        try w.writeInt(u16, sec.len, .little);
        for (sec.palette()) |b| try w.writeByte(@backingInt(b));
        for (sec.indices()) |word| try w.writeInt(u64, word, .little);
    }
}

/// The compressed bytes of `blocks`. The caller owns them.
fn compressBlocks(allocator: std.mem.Allocator, blocks: *const PalettedBlocks) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, 4096);
    defer out.deinit();
    const window = try allocator.alloc(u8, flate.max_window_len);
    defer allocator.free(window);
    const c = try allocator.create(flate.Compress);
    defer allocator.destroy(c);
    c.* = flate.Compress.init(&out.writer, window, .zlib, .default) catch return error.OutOfMemory;
    writeBlocks(&c.writer, blocks) catch return error.OutOfMemory;
    c.finish() catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// The blocks of compressed chunk bytes, with `raw_len` bytes before
/// compression.
fn decompressBlocks(allocator: std.mem.Allocator, data: []const u8, raw_len: u32) ChunkError!PalettedBlocks {
    if (raw_len > MAX_RAW_LEN) return error.CorruptChunk;
    const raw = try allocator.alloc(u8, raw_len);
    defer allocator.free(raw);
    var in: std.Io.Reader = .fixed(data);
    var d: flate.Decompress = .init(&in, .zlib, &.{});
    var w: std.Io.Writer = .fixed(raw);
    // A stream that is longer than `raw_len` fails the write. The read to
    // the end of the stream checks the zlib checksum.
    const n = d.reader.streamRemaining(&w) catch return error.CorruptChunk;
    if (n != raw_len) return error.CorruptChunk;
    return parseBlocks(allocator, raw) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.CorruptChunk,
    };
}

/// The blocks of chunk bytes before compression (format version 1).
fn parseBlocks(allocator: std.mem.Allocator, raw: []const u8) !PalettedBlocks {
    var at: usize = 0;
    const take = struct {
        fn f(bytes: []const u8, pos: *usize, n: usize) ![]const u8 {
            if (n > bytes.len - pos.*) return error.Truncated;
            defer pos.* += n;
            return bytes[pos.*..][0..n];
        }
    }.f;
    const sections = std.mem.readInt(u16, (try take(raw, &at, 2))[0..2], .little);
    if (sections != chunk_mod.SECTION_COUNT) return error.WrongSectionCount;
    var out: PalettedBlocks = .{};
    errdefer out.deinit(allocator);
    var palette: [256]BlockType = undefined;
    var words: [section_mod.CELLS * 8 / 64]u64 = undefined;
    for (&out.sections) |*sec| {
        const n = std.mem.readInt(u16, (try take(raw, &at, 2))[0..2], .little);
        if (n < 1 or n > 256) return error.InvalidSection;
        for ((try take(raw, &at, n)), 0..) |id, k| {
            palette[k] = std.enums.fromInt(BlockType, id) orelse return error.UnknownBlock;
        }
        const nw = Section.indexWords(Section.bitsFor(n));
        const packed_bytes = try take(raw, &at, nw * 8);
        for (words[0..nw], 0..) |*word, k| word.* = std.mem.readInt(u64, packed_bytes[k * 8 ..][0..8], .little);
        sec.* = try Section.fromPacked(allocator, palette[0..n], words[0..nw]);
    }
    if (at != raw.len) return error.TrailingBytes;
    return out;
}

/// The name of the file of region (rx, rz) in a storage:
/// "<prefix>.r.<rx>.<rz>". It uses only the characters that
/// `sw_assets.cache` accepts when `prefix` does too.
pub fn fileName(buf: []u8, prefix: []const u8, rx: i32, rz: i32) ![]u8 {
    return std.fmt.bufPrint(buf, "{s}.r.{d}.{d}", .{ prefix, rx, rz });
}

/// The longest name that `fileName` gives for a prefix of `prefix_len`
/// bytes.
pub fn fileNameLen(prefix_len: usize) usize {
    return prefix_len + ".r.-2147483648.-2147483648".len;
}

/// Save and load regions through a storage with the API of
/// `sw_assets.cache`: `write(name, bytes)` gives a request with
/// `poll() -> .pending | .done | .failed`, and `read(allocator, name)`
/// gives a request with `poll() -> .pending | .bytes | .missing |
/// .failed` and `cancel()`. On native, the cache is a folder. On the web,
/// it is OPFS.
///
///   const store = sw_voxel.region.Store(sw_assets.cache){ .prefix = "world1" };
///   var w = try store.save(allocator, &region);   // poll w each frame
///   var r = try store.load(allocator, rx, rz);    // poll r each frame
pub fn Store(comptime Cache: type) type {
    return struct {
        const Self = @This();
        /// The first part of each file name. Use the characters a-z, 0-9,
        /// '.', '_' and '-', at most 100 bytes.
        prefix: []const u8,

        pub const max_prefix_len = 100;

        fn name(self: Self, buf: *[fileNameLen(max_prefix_len)]u8, rx: i32, rz: i32) ![]u8 {
            if (self.prefix.len > max_prefix_len) return error.PrefixTooLong;
            return fileName(buf, self.prefix, rx, rz);
        }

        /// Start to write `region` to its file. The storage copies the
        /// bytes, so the caller can change or free `region` at once.
        pub fn save(self: Self, allocator: std.mem.Allocator, region: *const Region) !Cache.WriteRequest {
            var buf: [fileNameLen(max_prefix_len)]u8 = undefined;
            const n = try self.name(&buf, region.rx, region.rz);
            const bytes = try region.encode(allocator);
            defer allocator.free(bytes);
            return Cache.write(n, bytes);
        }

        /// Start to read the file of region (rx, rz). Poll the result.
        pub fn load(self: Self, allocator: std.mem.Allocator, rx: i32, rz: i32) !LoadRequest {
            var buf: [fileNameLen(max_prefix_len)]u8 = undefined;
            const n = try self.name(&buf, rx, rz);
            return .{ .allocator = allocator, .rx = rx, .rz = rz, .read = Cache.read(allocator, n) };
        }

        pub const LoadResult = union(enum) {
            pending,
            /// The region. The caller owns it: call `deinit`.
            region: Region,
            /// The storage has no file for this region.
            missing,
            /// A storage error, or a `DecodeError`. A file of another
            /// region gives `error.CorruptHeader`.
            failed: anyerror,
        };

        pub const LoadRequest = struct {
            allocator: std.mem.Allocator,
            rx: i32,
            rz: i32,
            read: Cache.ReadRequest,

            /// Poll until the result is not `.pending`.
            pub fn poll(self: *LoadRequest) LoadResult {
                switch (self.read.poll()) {
                    .pending => return .pending,
                    .missing => return .missing,
                    .failed => |err| return .{ .failed = err },
                    .bytes => |data| {
                        defer self.allocator.free(data);
                        var region = Region.decode(self.allocator, data) catch |err| return .{ .failed = err };
                        if (region.rx != self.rx or region.rz != self.rz) {
                            region.deinit();
                            return .{ .failed = error.CorruptHeader };
                        }
                        return .{ .region = region };
                    },
                }
            }

            /// Stop a load that you do not poll to the end.
            pub fn cancel(self: *LoadRequest) void {
                self.read.cancel();
            }
        };
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const World = @import("world.zig").World;

/// The block types of the content.
const all_blocks = std.enums.values(BlockType);

fn expectSameBlocks(want: *const PalettedBlocks, got: *const PalettedBlocks) !void {
    for (&want.sections, &got.sections) |*a, *b| {
        // The section is stored as it is: the same width and palette.
        try testing.expectEqual(a.bits, b.bits);
        try testing.expectEqualSlices(BlockType, a.palette(), b.palette());
        try testing.expectEqualSlices(u64, a.indices(), b.indices());
    }
    for (0..chunk_mod.CHUNK_W) |x| for (0..chunk_mod.CHUNK_H) |y| for (0..chunk_mod.CHUNK_W) |z| {
        try testing.expectEqual(want.getAt(x, y, z), got.getAt(x, y, z));
    };
}

test "a generated world gives the same blocks after a save and a load (REQ-VOXEL-011)" {
    const a = testing.allocator;
    var world = try World.init(a, .{}, 4);
    defer world.deinit();
    // Chunks on the two sides of the region borders at 0 and at SIZE.
    const coords = [_]i32{ -1, 0, 1, SIZE - 1, SIZE };
    for (coords) |cx| for (coords) |cz| {
        _ = try world.generateChunk(cx, cz);
    };

    // Save: put each chunk in its region, then encode each region.
    var regions: std.AutoHashMapUnmanaged([2]i32, Region) = .empty;
    defer {
        var it = regions.valueIterator();
        while (it.next()) |r| r.deinit();
        regions.deinit(a);
    }
    var cit = world.chunks.valueIterator();
    while (cit.next()) |lc_ptr| {
        const lc = lc_ptr.*;
        const key = [2]i32{ regionCoord(lc.cx), regionCoord(lc.cz) };
        const gop = try regions.getOrPut(a, key);
        if (!gop.found_existing) gop.value_ptr.* = .init(a, key[0], key[1]);
        try gop.value_ptr.put(lc.cx, lc.cz, &lc.chunk.blocks);
    }
    // Regions -1, 0 and 1 on each axis.
    try testing.expectEqual(@as(usize, 9), regions.count());
    var files: std.ArrayList([]u8) = .empty;
    defer {
        for (files.items) |f| a.free(f);
        files.deinit(a);
    }
    var rit = regions.valueIterator();
    while (rit.next()) |r| try files.append(a, try r.encode(a));

    // Load into a new world, then compare each cell of each chunk.
    var loaded = try World.init(a, .{}, 4);
    defer loaded.deinit();
    for (files.items) |bytes| {
        var region = try Region.decode(a, bytes);
        defer region.deinit();
        for (0..CHUNKS) |i| {
            const cx = region.rx * SIZE + @as(i32, @intCast(i % SIZE));
            const cz = region.rz * SIZE + @as(i32, @intCast(i / SIZE));
            const blocks = try region.get(a, cx, cz) orelse continue;
            _ = try loaded.installBlocks(cx, cz, blocks);
        }
    }
    try testing.expectEqual(world.chunks.count(), loaded.chunks.count());
    var it = world.chunks.valueIterator();
    while (it.next()) |lc_ptr| {
        const lc = lc_ptr.*;
        const got = loaded.get(lc.cx, lc.cz) orelse return error.TestMissingChunk;
        try expectSameBlocks(&lc.chunk.blocks, &got.chunk.blocks);
    }
}

test "an empty and a full section, and each index width (REQ-VOXEL-011)" {
    const a = testing.allocator;
    var blocks: PalettedBlocks = .{};
    defer blocks.deinit(a);
    // Section 0 is empty (air). Section 1 is full of one block. Section 2
    // to 6 have palettes of 2, 3, 5, 17 and all block types: widths 1, 2,
    // 4 and 8. Section 7 has a palette entry that no cell uses after an
    // edit. The other sections are air.
    for (&blocks.sections) |*s| s.* = .uniform(.air);
    blocks.sections[1] = .uniform(all_blocks[1]);
    const sizes = [_]usize{ 2, 3, 5, 17, all_blocks.len };
    for (sizes, 2..) |n, s| {
        var cells: [section_mod.CELLS]BlockType = undefined;
        for (&cells, 0..) |*c, i| c.* = all_blocks[(i * 7 + i / 13) % n];
        blocks.sections[s] = try Section.fromCells(a, &cells);
    }
    try blocks.sections[7].set(a, 5, all_blocks[2]);
    try blocks.sections[7].set(a, 9, all_blocks[3]);
    try blocks.sections[7].set(a, 9, .air);
    try testing.expectEqual(@as(u16, 3), blocks.sections[7].len);

    var region = Region.init(a, -1, 2);
    defer region.deinit();
    try region.put(-SIZE, 2 * SIZE + SIZE - 1, &blocks);
    try testing.expectEqual(@as(usize, 1), region.count());
    const bytes = try region.encode(a);
    defer a.free(bytes);
    var back = try Region.decode(a, bytes);
    defer back.deinit();
    try testing.expectEqual(@as(i32, -1), back.rx);
    try testing.expectEqual(@as(i32, 2), back.rz);
    try testing.expect(try back.get(a, -SIZE + 1, 2 * SIZE) == null);
    var got = (try back.get(a, -SIZE, 2 * SIZE + SIZE - 1)).?;
    defer got.deinit(a);
    try expectSameBlocks(&blocks, &got);
    try testing.expect(got.sections[0].isUniform());
    try testing.expectEqual(@as(usize, 0), got.sections[1].heapBytes());
    try testing.expectEqual(@as(u8, 8), got.sections[6].bits);
    try testing.expectEqual(@as(u16, 3), got.sections[7].len);

    // An empty region has the header and the table only.
    var empty = Region.init(a, 0, 0);
    defer empty.deinit();
    const empty_bytes = try empty.encode(a);
    defer a.free(empty_bytes);
    try testing.expectEqual(@as(usize, DATA_START), empty_bytes.len);
    var empty_back = try Region.decode(a, empty_bytes);
    defer empty_back.deinit();
    try testing.expectEqual(@as(usize, 0), empty_back.count());
}

/// A region with three chunks of a fixed pattern, for the corrupt and the
/// version tests.
fn patternChunk(a: std.mem.Allocator, seed: usize) !PalettedBlocks {
    var dense: chunk_mod.DenseBlocks = undefined;
    for (0..chunk_mod.CHUNK_W) |x| for (0..chunk_mod.CHUNK_H) |y| for (0..chunk_mod.CHUNK_W) |z| {
        // Section s uses 1 + (s % 6) × 4 block types, so the widths vary.
        const n = @min(all_blocks.len, 1 + ((y / 16 + seed) % 6) * 4);
        const k = (x * 31 + y * 7 + z * 13 + seed) % n;
        dense[chunk_mod.blockLinearIdx(@intCast(x), @intCast(y), @intCast(z))] = all_blocks[k];
    };
    return PalettedBlocks.fromDense(a, &dense);
}

test "a damaged chunk fails alone (REQ-VOXEL-013)" {
    const a = testing.allocator;
    var region = Region.init(a, 0, 0);
    defer region.deinit();
    var chunks: [3]PalettedBlocks = undefined;
    for (&chunks, 0..) |*c, i| c.* = try patternChunk(a, i);
    defer for (&chunks) |*c| c.deinit(a);
    for (&chunks, 0..) |*c, i| try region.put(@intCast(i), 0, c);
    const bytes = try region.encode(a);
    defer a.free(bytes);

    // Change one byte in the middle of chunk 1.
    const e = HEADER_LEN + 1 * ENTRY_LEN;
    const off = readInt(u32, bytes, e);
    const len = readInt(u32, bytes, e + 4);
    bytes[off + len / 2] ^= 0x5A;
    var bad = try Region.decode(a, bytes);
    defer bad.deinit();
    try testing.expectError(error.CorruptChunk, bad.get(a, 1, 0));
    for ([_]usize{ 0, 2 }) |i| {
        var got = (try bad.get(a, @intCast(i), 0)).?;
        defer got.deinit(a);
        try expectSameBlocks(&chunks[i], &got);
    }

    // A file that ends inside chunk 2: chunk 2 fails, 0 and 1 load.
    bytes[off + len / 2] ^= 0x5A;
    const e2 = HEADER_LEN + 2 * ENTRY_LEN;
    const short = bytes[0 .. readInt(u32, bytes, e2) + 10];
    var cut = try Region.decode(a, short);
    defer cut.deinit();
    try testing.expectError(error.CorruptChunk, cut.get(a, 2, 0));
    var c1 = (try cut.get(a, 1, 0)).?;
    defer c1.deinit(a);
    try expectSameBlocks(&chunks[1], &c1);

    // Compressed bytes that are valid zlib but not valid chunk bytes.
    var zr = Region.init(a, 0, 0);
    defer zr.deinit();
    var aw: std.Io.Writer.Allocating = try .initCapacity(a, 64);
    defer aw.deinit();
    const window = try a.alloc(u8, flate.max_window_len);
    defer a.free(window);
    var comp = try flate.Compress.init(&aw.writer, window, .zlib, .default);
    try comp.writer.writeAll("not a chunk");
    try comp.finish();
    zr.slots[0] = .{ .stored = .{ .data = try a.dupe(u8, aw.written()), .raw_len = 11 } };
    try testing.expectError(error.CorruptChunk, zr.get(a, 0, 0));
    // A wrong length before compression.
    zr.slots[0].stored.raw_len = 10;
    try testing.expectError(error.CorruptChunk, zr.get(a, 0, 0));

    // A damaged header or table fails the full file.
    bytes[HEADER_LEN + 3] ^= 1;
    try testing.expectError(error.CorruptHeader, Region.decode(a, bytes));
    bytes[HEADER_LEN + 3] ^= 1;
    try testing.expectError(error.CorruptHeader, Region.decode(a, bytes[0 .. DATA_START - 1]));
    try testing.expectError(error.NotRegionFile, Region.decode(a, "PK\x03\x04 not a region"));
    const later = try a.dupe(u8, bytes);
    defer a.free(later);
    writeInt(u16, later, 4, VERSION + 1);
    try testing.expectError(error.UnsupportedVersion, Region.decode(a, later));
    writeInt(u16, later, 4, VERSION);
    writeInt(u32, later, 20, chunk_mod.CHUNK_H + 16);
    writeInt(u32, later, 28, headerCrc(later));
    try testing.expectError(error.WrongWorldHeight, Region.decode(a, later));
}

/// The committed version 1 file of the test content. The build gives the
/// file for the world height of the test run (`build.zig`).
const fixture_v1 = @embedFile("region_v1_fixture");

test "a version 1 file stays readable (REQ-VOXEL-012)" {
    // libs/sw_voxel/testing/region_v1_*.bin: region (-1, 0) of the test
    // content, made by `encode` of version 1. The chunks (-16, 0), (-15, 0)
    // and (-1, 15) hold `patternChunk` 0, 1 and 2. Do not make the files
    // again: a later format must read them as they are.
    const a = testing.allocator;
    var region = try Region.decode(a, fixture_v1);
    defer region.deinit();
    try testing.expectEqual(@as(i32, -1), region.rx);
    try testing.expectEqual(@as(i32, 0), region.rz);
    try testing.expectEqual(@as(usize, 3), region.count());
    const at = [_][2]i32{ .{ -16, 0 }, .{ -15, 0 }, .{ -1, 15 } };
    for (at, 0..) |c, i| {
        var want = try patternChunk(a, i);
        defer want.deinit(a);
        var got = (try region.get(a, c[0], c[1])).?;
        defer got.deinit(a);
        try expectSameBlocks(&want, &got);
    }
}

/// A storage in memory with the API of `sw_assets.cache`, for the tests of
/// `Store`. A request finishes on its second poll.
const MemCache = struct {
    var files: std.StringHashMapUnmanaged([]u8) = .empty;
    const alloc = testing.allocator;

    fn reset() void {
        var it = files.iterator();
        while (it.next()) |kv| {
            alloc.free(kv.key_ptr.*);
            alloc.free(kv.value_ptr.*);
        }
        files.deinit(alloc);
        files = .empty;
    }

    const WriteRequest = struct {
        polls: u8 = 0,
        pub fn poll(self: *WriteRequest) union(enum) { pending, done, failed: anyerror } {
            self.polls += 1;
            return if (self.polls < 2) .pending else .done;
        }
    };

    const ReadRequest = struct {
        allocator: std.mem.Allocator,
        data: ?[]u8,
        polls: u8 = 0,
        pub fn poll(self: *ReadRequest) union(enum) { pending, bytes: []u8, missing, failed: anyerror } {
            self.polls += 1;
            if (self.polls < 2) return .pending;
            const d = self.data orelse return .missing;
            self.data = null;
            return .{ .bytes = d };
        }
        pub fn cancel(self: *ReadRequest) void {
            if (self.data) |d| self.allocator.free(d);
            self.data = null;
        }
    };

    pub fn write(name: []const u8, bytes: []const u8) WriteRequest {
        const gop = files.getOrPut(alloc, name) catch unreachable;
        if (gop.found_existing) {
            alloc.free(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = alloc.dupe(u8, name) catch unreachable;
        }
        gop.value_ptr.* = alloc.dupe(u8, bytes) catch unreachable;
        return .{};
    }

    pub fn read(allocator: std.mem.Allocator, name: []const u8) ReadRequest {
        const d = files.get(name) orelse return .{ .allocator = allocator, .data = null };
        return .{ .allocator = allocator, .data = allocator.dupe(u8, d) catch unreachable };
    }
};

test "Store saves and loads a region through a storage (REQ-VOXEL-011)" {
    const a = testing.allocator;
    defer MemCache.reset();
    const store: Store(MemCache) = .{ .prefix = "world-1" };
    var region = Region.init(a, -3, 7);
    defer region.deinit();
    var blocks = try patternChunk(a, 4);
    defer blocks.deinit(a);
    try region.put(-3 * SIZE + 2, 7 * SIZE + 9, &blocks);

    var w = try store.save(a, &region);
    try testing.expect(w.poll() == .pending);
    try testing.expect(w.poll() == .done);
    try testing.expect(MemCache.files.contains("world-1.r.-3.7"));

    var r = try store.load(a, -3, 7);
    try testing.expect(r.poll() == .pending);
    var result = r.poll();
    try testing.expect(result == .region);
    defer result.region.deinit();
    var got = (try result.region.get(a, -3 * SIZE + 2, 7 * SIZE + 9)).?;
    defer got.deinit(a);
    try expectSameBlocks(&blocks, &got);

    var none = try store.load(a, 0, 0);
    _ = none.poll();
    try testing.expect(none.poll() == .missing);

    // The file of another region under this name fails.
    _ = MemCache.write("world-1.r.0.0", MemCache.files.get("world-1.r.-3.7").?);
    var wrong = try store.load(a, 0, 0);
    _ = wrong.poll();
    try testing.expectEqual(error.CorruptHeader, wrong.poll().failed);

    var stopped = try store.load(a, -3, 7);
    stopped.cancel();
}

test "regionCoord and fileName" {
    try testing.expectEqual(@as(i32, 0), regionCoord(0));
    try testing.expectEqual(@as(i32, 0), regionCoord(SIZE - 1));
    try testing.expectEqual(@as(i32, 1), regionCoord(SIZE));
    try testing.expectEqual(@as(i32, -1), regionCoord(-1));
    try testing.expectEqual(@as(i32, -1), regionCoord(-SIZE));
    try testing.expectEqual(@as(i32, -2), regionCoord(-SIZE - 1));
    var buf: [fileNameLen(4)]u8 = undefined;
    try testing.expectEqualStrings("save.r.-2147483648.-2147483648", try fileName(&buf, "save", std.math.minInt(i32), std.math.minInt(i32)));
}
