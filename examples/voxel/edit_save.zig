//! The saved edit log of the voxel demo (REQ-VOXEL-035, REQ-VOXEL-036).
//!
//! The world is the seed plus the edit log. The demo saves the log with
//! sw_platform storage (localStorage on the web, a file natively), under
//! one key for each preset and seed. The demo loads the log at start,
//! before the loading screen, and gives each edit to the World and to the
//! chunk workers.
//!
//! Why not region files (sw_voxel region.zig): a region file holds the
//! blocks of whole chunks, and it goes through sw_assets cache (OPFS). A
//! few edits then cost a full chunk each. The edit log is small, and the
//! generator makes the rest of each chunk again.
//!
//! The format (little endian):
//!
//!   0   4 bytes  magic "SWZE"
//!   4   u8       format version (1)
//!   5   u8       preset (world_gen.Preset)
//!   6   u64      seed
//!   14  u32      record count
//!   18  u32      CRC-32 of the records
//!   22  records, RECORD_LEN bytes each:
//!         i32 cx, i32 cz, u8 x, u16 y (local), u8 z, u8 block
//!
//! The records are compact: one record for each cell, the last edit of the
//! cell, in the order of those last edits. The file is at most MAX_BYTES.
//! When the log is larger, the save keeps the newest edits.
const std = @import("std");
const sw_voxel = @import("sw_voxel");

const chunk_mod = sw_voxel.chunk;
pub const Block = chunk_mod.BlockType;

pub const MAGIC = "SWZE";
pub const VERSION: u8 = 1;
pub const HEADER_LEN = 22;
pub const RECORD_LEN = 13;
/// The size limit of the saved data for one world (REQ-VOXEL-036).
pub const MAX_BYTES: usize = 1 << 20;
/// The most records that fit in MAX_BYTES.
pub const MAX_RECORDS: usize = (MAX_BYTES - HEADER_LEN) / RECORD_LEN;

/// One edit of the saved log: a cell in chunk-local coordinates (y is
/// local: world y is y + chunk.MIN_Y) and its new block.
pub const SavedEdit = struct {
    cx: i32,
    cz: i32,
    x: u8,
    y: u16,
    z: u8,
    block: Block,

    /// The edit of world cell (wx, wy, wz). Null when wy is out of the
    /// world.
    pub fn fromWorld(wx: i32, wy: i32, wz: i32, block: Block) ?SavedEdit {
        const ly = wy - chunk_mod.MIN_Y;
        if (ly < 0 or ly >= chunk_mod.CHUNK_H) return null;
        const cx = @divFloor(wx, chunk_mod.CHUNK_W);
        const cz = @divFloor(wz, chunk_mod.CHUNK_W);
        return .{
            .cx = cx,
            .cz = cz,
            .x = @intCast(wx - cx * chunk_mod.CHUNK_W),
            .y = @intCast(ly),
            .z = @intCast(wz - cz * chunk_mod.CHUNK_W),
            .block = block,
        };
    }

    fn cell(self: SavedEdit) Cell {
        return .{ .cx = self.cx, .cz = self.cz, .x = self.x, .y = self.y, .z = self.z };
    }
};

const Cell = struct { cx: i32, cz: i32, x: u8, y: u16, z: u8 };

/// The storage key of a world: "voxel-edits-<preset>-<seed>". `buf` holds
/// the text.
pub fn key(buf: *[64]u8, preset: []const u8, seed: u64) []const u8 {
    return std.fmt.bufPrint(buf, "voxel-edits-{s}-{d}", .{ preset, seed }) catch unreachable;
}

/// Keep the last edit of each cell, in the order of those last edits
/// (REQ-VOXEL-035). The list changes in place.
pub fn compact(allocator: std.mem.Allocator, list: *std.ArrayList(SavedEdit)) !void {
    var last: std.AutoHashMapUnmanaged(Cell, usize) = .empty;
    defer last.deinit(allocator);
    try last.ensureTotalCapacity(allocator, @intCast(list.items.len));
    for (list.items, 0..) |e, i| last.putAssumeCapacity(e.cell(), i);
    var out: usize = 0;
    for (list.items, 0..) |e, i| {
        if (last.get(e.cell()).? != i) continue;
        list.items[out] = e;
        out += 1;
    }
    list.shrinkRetainingCapacity(out);
}

/// The bytes of a compact log. When the log has more than MAX_RECORDS
/// edits, only the newest MAX_RECORDS go in, and `dropped` tells how many
/// did not.
pub const Encoded = struct {
    bytes: []u8,
    dropped: usize,
};

pub fn encode(allocator: std.mem.Allocator, preset: u8, seed: u64, edits: []const SavedEdit) !Encoded {
    const dropped = edits.len -| MAX_RECORDS;
    const kept = edits[dropped..];
    const bytes = try allocator.alloc(u8, HEADER_LEN + kept.len * RECORD_LEN);
    @memcpy(bytes[0..4], MAGIC);
    bytes[4] = VERSION;
    bytes[5] = preset;
    std.mem.writeInt(u64, bytes[6..14], seed, .little);
    std.mem.writeInt(u32, bytes[14..18], @intCast(kept.len), .little);
    for (kept, 0..) |e, i| {
        const r = bytes[HEADER_LEN + i * RECORD_LEN ..][0..RECORD_LEN];
        std.mem.writeInt(i32, r[0..4], e.cx, .little);
        std.mem.writeInt(i32, r[4..8], e.cz, .little);
        r[8] = e.x;
        std.mem.writeInt(u16, r[9..11], e.y, .little);
        r[11] = e.z;
        r[12] = @backingInt(e.block);
    }
    std.mem.writeInt(u32, bytes[18..22], std.hash.Crc32.hash(bytes[HEADER_LEN..]), .little);
    return .{ .bytes = bytes, .dropped = dropped };
}

pub const DecodeError = error{
    /// The data does not start with "SWZE".
    BadMagic,
    /// The format version is not one that this code reads.
    UnknownVersion,
    /// The data is shorter or longer than its record count.
    Truncated,
    /// The records do not have the CRC of the header.
    BadChecksum,
    /// A record has a cell outside its chunk or an unknown block.
    BadRecord,
    /// The data is for another preset or seed.
    OtherWorld,
    OutOfMemory,
};

/// The edits of saved data for the world (`preset`, `seed`). The caller
/// owns the list.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, preset: u8, seed: u64) DecodeError!std.ArrayList(SavedEdit) {
    if (bytes.len < HEADER_LEN) return if (bytes.len >= 4 and !std.mem.eql(u8, bytes[0..4], MAGIC)) error.BadMagic else error.Truncated;
    if (!std.mem.eql(u8, bytes[0..4], MAGIC)) return error.BadMagic;
    if (bytes[4] != VERSION) return error.UnknownVersion;
    const n = std.mem.readInt(u32, bytes[14..18], .little);
    if (bytes.len != HEADER_LEN + @as(u64, n) * RECORD_LEN) return error.Truncated;
    if (std.hash.Crc32.hash(bytes[HEADER_LEN..]) != std.mem.readInt(u32, bytes[18..22], .little)) return error.BadChecksum;
    if (bytes[5] != preset or std.mem.readInt(u64, bytes[6..14], .little) != seed) return error.OtherWorld;
    var list: std.ArrayList(SavedEdit) = .empty;
    errdefer list.deinit(allocator);
    try list.ensureTotalCapacity(allocator, n);
    for (0..n) |i| {
        const r = bytes[HEADER_LEN + i * RECORD_LEN ..][0..RECORD_LEN];
        const y = std.mem.readInt(u16, r[9..11], .little);
        if (r[8] >= chunk_mod.CHUNK_W or r[11] >= chunk_mod.CHUNK_W or y >= chunk_mod.CHUNK_H) return error.BadRecord;
        const block = std.enums.fromInt(Block, r[12]) orelse return error.BadRecord;
        list.appendAssumeCapacity(.{
            .cx = std.mem.readInt(i32, r[0..4], .little),
            .cz = std.mem.readInt(i32, r[4..8], .little),
            .x = r[8],
            .y = y,
            .z = r[11],
            .block = block,
        });
    }
    return list;
}

/// The storage functions of sw_platform (storageGet, storageSet,
/// storageDelete). The tests give a fake store.
pub fn Store(comptime S: type) type {
    return struct {
        /// Read the saved log of a world. A missing key gives an empty log.
        /// Unavailable storage or bad data gives an empty log and calls
        /// `warn` one time with the reason.
        pub fn load(allocator: std.mem.Allocator, k: []const u8, preset: u8, seed: u64, warn: *const fn ([]const u8, []const u8) void) !std.ArrayList(SavedEdit) {
            const bytes = S.storageGet(allocator, k) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    warn("storage is not available", @errorName(err));
                    return .empty;
                },
            } orelse return .empty;
            defer allocator.free(bytes);
            return decode(allocator, bytes, preset, seed) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    warn("the saved edits cannot be read", @errorName(err));
                    return .empty;
                },
            };
        }

        /// Compact `list`, encode it and write it to `k`. Returns the
        /// number of old edits that did not fit and went from `list`.
        pub fn save(allocator: std.mem.Allocator, k: []const u8, preset: u8, seed: u64, list: *std.ArrayList(SavedEdit)) !usize {
            try compact(allocator, list);
            const enc = try encode(allocator, preset, seed, list.items);
            defer allocator.free(enc.bytes);
            if (enc.dropped > 0) {
                std.mem.copyForwards(SavedEdit, list.items[0 .. list.items.len - enc.dropped], list.items[enc.dropped..]);
                list.shrinkRetainingCapacity(list.items.len - enc.dropped);
            }
            try S.storageSet(k, enc.bytes);
            return enc.dropped;
        }

        pub fn delete(k: []const u8) !void {
            try S.storageDelete(k);
        }
    };
}

// ---------------------------------------------------------------------------
// Tests. `zig build test` runs them (the filter "edit_save: ").
// ---------------------------------------------------------------------------

const testing = std.testing;

fn ed(cx: i32, x: u8, y: u16, block: Block) SavedEdit {
    return .{ .cx = cx, .cz = -cx, .x = x, .y = y, .z = 3, .block = block };
}

test "edit_save: compaction keeps the last edit of each cell, in order" {
    const a = testing.allocator;
    var list: std.ArrayList(SavedEdit) = .empty;
    defer list.deinit(a);
    try list.appendSlice(a, &.{
        ed(0, 1, 70, .stone),
        ed(0, 2, 70, .stone),
        ed(1, 1, 70, .dirt), // another chunk: another cell
        ed(0, 1, 70, .air), // the cell of the first edit again
        ed(0, 2, 70, .grass),
    });
    try compact(a, &list);
    try testing.expectEqualSlices(SavedEdit, &.{
        ed(1, 1, 70, .dirt),
        ed(0, 1, 70, .air),
        ed(0, 2, 70, .grass),
    }, list.items);
}

test "edit_save: encode and decode give the same edits" {
    const a = testing.allocator;
    const edits = [_]SavedEdit{
        ed(0, 0, 0, .stone),
        ed(-5, 15, @intCast(chunk_mod.CHUNK_H - 1), .glowstone),
        .{ .cx = std.math.maxInt(i32), .cz = std.math.minInt(i32), .x = 7, .y = 64, .z = 15, .block = .air },
    };
    const enc = try encode(a, 1, 0xdead_beef_0000_0001, &edits);
    defer a.free(enc.bytes);
    try testing.expectEqual(@as(usize, 0), enc.dropped);
    try testing.expectEqual(HEADER_LEN + edits.len * RECORD_LEN, enc.bytes.len);
    var got = try decode(a, enc.bytes, 1, 0xdead_beef_0000_0001);
    defer got.deinit(a);
    try testing.expectEqualSlices(SavedEdit, &edits, got.items);

    // An empty log is valid data.
    const empty = try encode(a, 0, 0, &.{});
    defer a.free(empty.bytes);
    var none = try decode(a, empty.bytes, 0, 0);
    defer none.deinit(a);
    try testing.expectEqual(@as(usize, 0), none.items.len);
}

test "edit_save: SavedEdit.fromWorld gives chunk-local cells" {
    const s = SavedEdit.fromWorld(-1, chunk_mod.MIN_Y + 5, 17, .stone).?;
    try testing.expectEqual(@as(i32, -1), s.cx);
    try testing.expectEqual(@as(i32, 1), s.cz);
    try testing.expectEqual(@as(u8, 15), s.x);
    try testing.expectEqual(@as(u16, 5), s.y);
    try testing.expectEqual(@as(u8, 1), s.z);
    try testing.expect(SavedEdit.fromWorld(0, chunk_mod.MIN_Y - 1, 0, .stone) == null);
    try testing.expect(SavedEdit.fromWorld(0, chunk_mod.MIN_Y + @as(i32, chunk_mod.CHUNK_H), 0, .stone) == null);
}

test "edit_save: corrupt or truncated data gives an error" {
    const a = testing.allocator;
    const edits = [_]SavedEdit{ ed(0, 1, 70, .stone), ed(0, 2, 70, .dirt) };
    const enc = try encode(a, 1, 7, &edits);
    defer a.free(enc.bytes);
    const b = enc.bytes;

    // Each shorter length is truncated data.
    for (0..b.len) |n| {
        try testing.expect(std.meta.isError(decode(a, b[0..n], 1, 7)));
    }
    try testing.expectError(error.Truncated, decode(a, b[0 .. b.len - 1], 1, 7));
    try testing.expectError(error.Truncated, decode(a, b[0..10], 1, 7));

    var bad = try a.dupe(u8, b);
    defer a.free(bad);
    bad[0] = 'X';
    try testing.expectError(error.BadMagic, decode(a, bad, 1, 7));
    @memcpy(bad, b);
    bad[4] = 2;
    try testing.expectError(error.UnknownVersion, decode(a, bad, 1, 7));
    @memcpy(bad, b);
    bad[HEADER_LEN + 12] ^= 1; // a block byte changes
    try testing.expectError(error.BadChecksum, decode(a, bad, 1, 7));
    try testing.expectError(error.OtherWorld, decode(a, b, 0, 7));
    try testing.expectError(error.OtherWorld, decode(a, b, 1, 8));

    // A record with a good CRC and a cell outside its chunk.
    var outside = [_]SavedEdit{ed(0, 1, 70, .stone)};
    outside[0].x = 16;
    const enc2 = try encode(a, 1, 7, &outside);
    defer a.free(enc2.bytes);
    try testing.expectError(error.BadRecord, decode(a, enc2.bytes, 1, 7));
    // An unknown block id.
    @memcpy(bad, b);
    bad[HEADER_LEN + 12] = 255;
    std.mem.writeInt(u32, bad[18..22], std.hash.Crc32.hash(bad[HEADER_LEN..]), .little);
    if (std.enums.fromInt(Block, @as(u8, 255)) == null) {
        try testing.expectError(error.BadRecord, decode(a, bad, 1, 7));
    }
}

test "edit_save: the save keeps the newest edits within the size limit" {
    const a = testing.allocator;
    var list: std.ArrayList(SavedEdit) = .empty;
    defer list.deinit(a);
    const total = MAX_RECORDS + 10;
    try list.ensureTotalCapacity(a, total);
    for (0..total) |i| {
        list.appendAssumeCapacity(.{ .cx = @intCast(i), .cz = 0, .x = 0, .y = 1, .z = 0, .block = .stone });
    }
    var fake: FakeStore = .{};
    defer fake.deinit();
    FakeStore.current = &fake;
    const S = Store(FakeStore);
    const dropped = try S.save(a, "k", 0, 0, &list);
    try testing.expectEqual(@as(usize, 10), dropped);
    try testing.expectEqual(MAX_RECORDS, list.items.len);
    try testing.expectEqual(@as(i32, 10), list.items[0].cx);
    const saved = fake.value.?;
    try testing.expect(saved.len <= MAX_BYTES);
    var got = try decode(a, saved, 0, 0);
    defer got.deinit(a);
    try testing.expectEqual(MAX_RECORDS, got.items.len);
    try testing.expectEqual(@as(i32, @intCast(total - 1)), got.items[got.items.len - 1].cx);
}

/// A store with one value, for the tests.
const FakeStore = struct {
    value: ?[]u8 = null,
    unavailable: bool = false,
    var current: *FakeStore = undefined;

    fn deinit(self: *FakeStore) void {
        if (self.value) |v| testing.allocator.free(v);
        self.value = null;
    }
    pub fn storageGet(allocator: std.mem.Allocator, _: []const u8) !?[]u8 {
        if (current.unavailable) return error.StorageUnavailable;
        const v = current.value orelse return null;
        return try allocator.dupe(u8, v);
    }
    pub fn storageSet(_: []const u8, bytes: []const u8) !void {
        if (current.unavailable) return error.StorageUnavailable;
        current.deinit();
        current.value = try testing.allocator.dupe(u8, bytes);
    }
    pub fn storageDelete(_: []const u8) !void {
        if (current.unavailable) return error.StorageUnavailable;
        current.deinit();
    }
};

var test_warnings: usize = 0;
fn countWarning(_: []const u8, _: []const u8) void {
    test_warnings += 1;
}

test "edit_save: load and save through a store, round trip" {
    const a = testing.allocator;
    var fake: FakeStore = .{};
    defer fake.deinit();
    FakeStore.current = &fake;
    const S = Store(FakeStore);
    test_warnings = 0;

    // No saved data: an empty log and no warning.
    var empty = try S.load(a, "k", 1, 5, &countWarning);
    defer empty.deinit(a);
    try testing.expectEqual(@as(usize, 0), empty.items.len);

    var list: std.ArrayList(SavedEdit) = .empty;
    defer list.deinit(a);
    try list.appendSlice(a, &.{ ed(0, 1, 70, .stone), ed(0, 1, 70, .dirt), ed(2, 4, 90, .glass) });
    _ = try S.save(a, "k", 1, 5, &list);
    var got = try S.load(a, "k", 1, 5, &countWarning);
    defer got.deinit(a);
    try testing.expectEqualSlices(SavedEdit, &.{ ed(0, 1, 70, .dirt), ed(2, 4, 90, .glass) }, got.items);
    try testing.expectEqual(@as(usize, 0), test_warnings);

    try S.delete("k");
    var gone = try S.load(a, "k", 1, 5, &countWarning);
    defer gone.deinit(a);
    try testing.expectEqual(@as(usize, 0), gone.items.len);
}

test "edit_save: corrupt data and unavailable storage give an empty log and one warning" {
    const a = testing.allocator;
    var fake: FakeStore = .{};
    defer fake.deinit();
    FakeStore.current = &fake;
    const S = Store(FakeStore);

    fake.value = try a.dupe(u8, "SWZE\x01garbage");
    test_warnings = 0;
    var l1 = try S.load(a, "k", 0, 0, &countWarning);
    defer l1.deinit(a);
    try testing.expectEqual(@as(usize, 0), l1.items.len);
    try testing.expectEqual(@as(usize, 1), test_warnings);

    fake.unavailable = true;
    test_warnings = 0;
    var l2 = try S.load(a, "k", 0, 0, &countWarning);
    defer l2.deinit(a);
    try testing.expectEqual(@as(usize, 0), l2.items.len);
    try testing.expectEqual(@as(usize, 1), test_warnings);
    var list: std.ArrayList(SavedEdit) = .empty;
    defer list.deinit(a);
    try list.append(a, ed(0, 1, 70, .stone));
    try testing.expectError(error.StorageUnavailable, S.save(a, "k", 0, 0, &list));
}
