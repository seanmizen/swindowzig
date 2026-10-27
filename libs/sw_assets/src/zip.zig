//! Read the entries of a zip archive that is in memory.
//!
//!   var archive = try zip.Archive.open(allocator, bytes, .{});
//!   defer archive.deinit(allocator);
//!   for (archive.entries) |*entry| log(entry.name);
//!   if (archive.find("data/a.txt")) |entry| {
//!       const data = try archive.read(allocator, entry);
//!       defer allocator.free(data);
//!   }
//!
//! `open` reads the central directory only. It does not decompress an entry
//! (REQ-ASSETS-001). `read` decompresses one entry when the game asks for
//! it. The archive does not copy `bytes`: keep them until `deinit`.
//!
//! Supported: stored (method 0) and deflate (method 8) entries, Zip64
//! sizes and offsets, data descriptors, and bytes before the archive (for
//! example a program stub). An entry name with `\` gets `/`. Folder entries
//! (names that end in `/`) are not in `entries`.
//!
//! Not supported: encryption, other methods, archives on more than one disk.
//! A bad entry fails alone: the other entries stay readable.
const std = @import("std");
const flate = std.compress.flate;

pub const Method = enum(u16) {
    stored = 0,
    deflate = 8,
    _,
};

pub const Entry = struct {
    /// The full path in the archive, with `/` between folders. It is UTF-8
    /// when the archive tool wrote UTF-8.
    name: []const u8,
    method: Method,
    /// The size of the data in the archive.
    compressed_size: u64,
    /// The size of the data after `read`.
    size: u64,
    crc32: u32,
    encrypted: bool,
    /// The position of the local header in the archive bytes.
    header_offset: u64,
};

pub const OpenError = error{
    /// No end-of-central-directory record: the bytes are not a zip archive.
    NotAZip,
    /// The central directory is not in the bytes, or a record is bad.
    Corrupt,
    OutOfMemory,
};

pub const ReadError = error{
    /// The entry uses a method that is not stored or deflate.
    UnsupportedMethod,
    /// The entry is encrypted.
    Encrypted,
    /// The entry data is not in the bytes, or it does not decompress to
    /// `Entry.size` bytes.
    Corrupt,
    /// The CRC-32 of the data is not `Entry.crc32`.
    ChecksumMismatch,
    /// `readInto`: the buffer length is not `Entry.size`.
    WrongBufferSize,
    OutOfMemory,
};

/// A sentence for a log line or a screen.
pub fn errorMessage(err: (OpenError || ReadError || error{NotFound})) []const u8 {
    return switch (err) {
        error.NotAZip => "The data is not a zip archive.",
        error.Corrupt => "The zip archive is damaged.",
        error.UnsupportedMethod => "The zip entry uses a compression method that is not supported. Use stored or deflate.",
        error.Encrypted => "The zip entry is encrypted. Encrypted entries are not supported.",
        error.ChecksumMismatch => "The zip entry is damaged: the CRC-32 is not correct.",
        error.WrongBufferSize => "The buffer length is not the entry size.",
        error.NotFound => "The zip archive has no entry with this name.",
        error.OutOfMemory => "Out of memory.",
    };
}

pub const Options = struct {
    /// When true, `read` compares the CRC-32 of the data with the CRC-32 in
    /// the central directory. Set it to false to read archives that have
    /// incorrect CRC-32 values (some tools write them).
    check_crc: bool = true,
};

pub const Archive = struct {
    /// The archive bytes. The archive does not own them.
    bytes: []const u8,
    /// The file entries, in central directory order. Folder entries are not
    /// included.
    entries: []Entry,
    options: Options,
    /// The name of each entry, one after the other.
    names: []u8,
    /// Name to index in `entries`.
    index: std.StringHashMapUnmanaged(u32),

    /// Read the central directory of the archive in `bytes`. The archive
    /// keeps a reference to `bytes`.
    pub fn open(allocator: std.mem.Allocator, bytes: []const u8, options: Options) OpenError!Archive {
        const dir = try findDirectory(bytes);

        // Pass 1: check each record, and count the entries and name bytes.
        var count: usize = 0;
        var name_bytes: usize = 0;
        {
            var it: RecordIterator = .{ .bytes = bytes, .pos = dir.start, .end = dir.end };
            while (try it.next()) |record| {
                if (isFolder(record.name)) continue;
                count += 1;
                name_bytes += record.name.len;
            }
        }
        if (count > std.math.maxInt(u32)) return error.Corrupt;

        const entries = try allocator.alloc(Entry, count);
        errdefer allocator.free(entries);
        const names = try allocator.alloc(u8, name_bytes);
        errdefer allocator.free(names);
        var index: std.StringHashMapUnmanaged(u32) = .empty;
        errdefer index.deinit(allocator);
        try index.ensureTotalCapacity(allocator, @intCast(count));

        // Pass 2: fill the entries.
        var it: RecordIterator = .{ .bytes = bytes, .pos = dir.start, .end = dir.end };
        var n: usize = 0;
        var name_pos: usize = 0;
        while (try it.next()) |record| {
            if (isFolder(record.name)) continue;
            const name = names[name_pos..][0..record.name.len];
            name_pos += name.len;
            for (name, record.name) |*dst, c| dst.* = if (c == '\\') '/' else c;
            const header_offset = std.math.add(u64, dir.base, record.header_offset) catch return error.Corrupt;
            entries[n] = .{
                .name = name,
                .method = @fromBackingInt(@intCast(record.method)),
                .compressed_size = record.compressed_size,
                .size = record.size,
                .crc32 = record.crc32,
                .encrypted = record.flags & 1 != 0,
                .header_offset = header_offset,
            };
            // A name that is in the archive two times gives the last entry.
            index.putAssumeCapacity(name, @intCast(n));
            n += 1;
        }

        return .{
            .bytes = bytes,
            .entries = entries,
            .options = options,
            .names = names,
            .index = index,
        };
    }

    pub fn deinit(self: *Archive, allocator: std.mem.Allocator) void {
        self.index.deinit(allocator);
        allocator.free(self.names);
        allocator.free(self.entries);
        self.* = undefined;
    }

    /// The entry with the full path `name`, or null.
    pub fn find(self: *const Archive, name: []const u8) ?*const Entry {
        const i = self.index.get(name) orelse return null;
        return &self.entries[i];
    }

    /// Decompress `entry`. The caller owns the returned slice.
    pub fn read(self: *const Archive, allocator: std.mem.Allocator, entry: *const Entry) ReadError![]u8 {
        if (entry.size > std.math.maxInt(usize)) return error.OutOfMemory;
        const out = try allocator.alloc(u8, @intCast(entry.size));
        errdefer allocator.free(out);
        try self.readInto(entry, out);
        return out;
    }

    /// Decompress the entry with the full path `name`.
    pub fn readName(self: *const Archive, allocator: std.mem.Allocator, name: []const u8) (ReadError || error{NotFound})![]u8 {
        const entry = self.find(name) orelse return error.NotFound;
        return self.read(allocator, entry);
    }

    /// Decompress `entry` into `out`. `out.len` must be `entry.size`.
    pub fn readInto(self: *const Archive, entry: *const Entry, out: []u8) ReadError!void {
        if (out.len != entry.size) return error.WrongBufferSize;
        if (entry.encrypted) return error.Encrypted;
        const data = try self.entryData(entry);
        switch (entry.method) {
            .stored => {
                if (data.len != out.len) return error.Corrupt;
                @memcpy(out, data);
            },
            .deflate => try inflate(data, out),
            _ => return error.UnsupportedMethod,
        }
        if (self.options.check_crc and std.hash.Crc32.hash(out) != entry.crc32) return error.ChecksumMismatch;
    }

    /// The compressed data of `entry`, after its local header.
    fn entryData(self: *const Archive, entry: *const Entry) ReadError![]const u8 {
        const bytes = self.bytes;
        if (entry.header_offset > bytes.len or bytes.len - entry.header_offset < local_header_len) return error.Corrupt;
        const at: usize = @intCast(entry.header_offset);
        if (readInt(u32, bytes, at) != local_header_sig) return error.Corrupt;
        const name_len = readInt(u16, bytes, at + 26);
        const extra_len = readInt(u16, bytes, at + 28);
        const start = at + local_header_len + name_len + extra_len;
        if (start > bytes.len or bytes.len - start < entry.compressed_size) return error.Corrupt;
        return bytes[start..][0..@intCast(entry.compressed_size)];
    }
};

/// Decompress raw deflate data into all of `out`.
fn inflate(data: []const u8, out: []u8) ReadError!void {
    var in: std.Io.Reader = .fixed(data);
    // No decompress buffer: `out` is the history window.
    var decompress: flate.Decompress = .init(&in, .raw, &.{});
    var writer: std.Io.Writer = .fixed(out);
    const n = decompress.reader.streamRemaining(&writer) catch |err| switch (err) {
        // More data than `out` can hold.
        error.WriteFailed => return error.Corrupt,
        error.ReadFailed => return error.Corrupt,
    };
    if (n != out.len) return error.Corrupt;
}

// ---------------------------------------------------------------------------
// Records
// ---------------------------------------------------------------------------

const local_header_sig = 0x04034b50;
const local_header_len = 30;
const central_sig = 0x02014b50;
const central_len = 46;
const end_sig = 0x06054b50;
const end_len = 22;
const zip64_locator_sig = 0x07064b50;
const zip64_locator_len = 20;
const zip64_end_sig = 0x06064b50;
const zip64_end_len = 56;
const zip64_extra_id = 0x0001;

fn readInt(comptime T: type, bytes: []const u8, at: usize) T {
    return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .little);
}

fn isFolder(name: []const u8) bool {
    return name.len == 0 or name[name.len - 1] == '/' or name[name.len - 1] == '\\';
}

const Directory = struct {
    /// The central directory is at bytes[start..end].
    start: usize,
    end: usize,
    /// Add this to each recorded offset to get a position in the bytes. It is
    /// not zero when there are bytes before the archive.
    base: u64,
};

/// Find the central directory. The directory ends where the end record (or
/// the Zip64 end record) starts, so its position comes from its size. The
/// recorded offset then gives the number of bytes before the archive. The
/// entry counts and disk numbers are not used: some tools write them
/// incorrectly.
fn findDirectory(bytes: []const u8) OpenError!Directory {
    if (bytes.len < end_len) return error.NotAZip;
    // The end record has a comment of 65535 bytes at most, so look back
    // from the end through that many bytes.
    const lowest = bytes.len -| (end_len + std.math.maxInt(u16));
    var pos = bytes.len - end_len;
    const end_pos: usize = while (true) : (pos -= 1) {
        if (readInt(u32, bytes, pos) == end_sig and
            pos + end_len + readInt(u16, bytes, pos + 20) <= bytes.len) break pos;
        if (pos == lowest) return error.NotAZip;
    };

    var dir_end: usize = end_pos;
    var dir_size: u64 = readInt(u32, bytes, end_pos + 12);
    var dir_offset: u64 = readInt(u32, bytes, end_pos + 16);

    if (end_pos >= zip64_locator_len and readInt(u32, bytes, end_pos - zip64_locator_len) == zip64_locator_sig) {
        const locator = end_pos - zip64_locator_len;
        // The Zip64 end record is usually immediately before the locator.
        // Else use the recorded offset (correct when no bytes are before
        // the archive).
        const z: usize = if (locator >= zip64_end_len and readInt(u32, bytes, locator - zip64_end_len) == zip64_end_sig)
            locator - zip64_end_len
        else blk: {
            const recorded = readInt(u64, bytes, locator + 8);
            if (recorded > locator or locator - recorded < zip64_end_len) return error.Corrupt;
            if (readInt(u32, bytes, @intCast(recorded)) != zip64_end_sig) return error.Corrupt;
            break :blk @intCast(recorded);
        };
        dir_end = z;
        dir_size = readInt(u64, bytes, z + 40);
        dir_offset = readInt(u64, bytes, z + 48);
    }

    if (dir_size > dir_end) return error.Corrupt;
    const dir_start = dir_end - @as(usize, @intCast(dir_size));
    if (dir_offset > dir_start) return error.Corrupt;
    return .{ .start = dir_start, .end = dir_end, .base = dir_start - dir_offset };
}

const Record = struct {
    name: []const u8,
    flags: u16,
    method: u16,
    crc32: u32,
    compressed_size: u64,
    size: u64,
    header_offset: u64,
};

const RecordIterator = struct {
    bytes: []const u8,
    pos: usize,
    end: usize,

    fn next(it: *RecordIterator) OpenError!?Record {
        if (it.pos == it.end) return null;
        const b = it.bytes;
        if (it.end - it.pos < central_len) return error.Corrupt;
        const p = it.pos;
        if (readInt(u32, b, p) != central_sig) return error.Corrupt;
        const name_len = readInt(u16, b, p + 28);
        const extra_len = readInt(u16, b, p + 30);
        const comment_len = readInt(u16, b, p + 32);
        const len = central_len + @as(usize, name_len) + extra_len + comment_len;
        if (it.end - p < len) return error.Corrupt;
        it.pos = p + len;

        var record: Record = .{
            .name = b[p + central_len ..][0..name_len],
            .flags = readInt(u16, b, p + 8),
            .method = readInt(u16, b, p + 10),
            .crc32 = readInt(u32, b, p + 16),
            .compressed_size = readInt(u32, b, p + 20),
            .size = readInt(u32, b, p + 24),
            .header_offset = readInt(u32, b, p + 42),
        };
        try applyZip64(&record, b[p + central_len + name_len ..][0..extra_len]);
        return record;
    }
};

/// A 32-bit field with the value 0xFFFFFFFF has its real value in the Zip64
/// extra field. The real values are in this order: size, compressed size,
/// header offset. Only the fields that are 0xFFFFFFFF are there.
fn applyZip64(record: *Record, extra: []const u8) OpenError!void {
    const max = std.math.maxInt(u32);
    if (record.size != max and record.compressed_size != max and record.header_offset != max) return;
    var pos: usize = 0;
    while (extra.len - pos >= 4) {
        const id = readInt(u16, extra, pos);
        const len = readInt(u16, extra, pos + 2);
        pos += 4;
        if (extra.len - pos < len) return error.Corrupt;
        const field = extra[pos..][0..len];
        pos += len;
        if (id != zip64_extra_id) continue;
        var at: usize = 0;
        for ([_]*u64{ &record.size, &record.compressed_size, &record.header_offset }) |value| {
            if (value.* != max) continue;
            if (field.len - at < 8) return error.Corrupt;
            value.* = readInt(u64, field, at);
            at += 8;
        }
        return;
    }
    return error.Corrupt;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// The fixtures were made with Info-ZIP `zip` 3.0 (macOS /usr/bin/zip):
//
//   mkdir -p pack/data
//   printf 'stored entry\n' > pack/info.txt
//   for i in $(seq 1 200); do printf 'line %04d\n' $i; done > pack/data/lines.txt
//   : > pack/empty.txt
//   head -c 4194304 /dev/zero > pack/data/zeros.bin
//   zip -X -0 standard.zip pack/ pack/data/ pack/info.txt pack/empty.txt
//   zip -X -9 standard.zip pack/data/lines.txt pack/data/zeros.bin
//
//   printf 'streamed entry\nstreamed entry\nstreamed entry\n' | zip -X -q - - > streamed.zip
//
// standard.zip has folder entries, stored entries and deflate entries.
// streamed.zip is written to a pipe: it has a Zip64 end record and a data
// descriptor, and its one entry is named "-".
const testing = std.testing;
const standard_zip = @embedFile("test_zip_standard");
const streamed_zip = @embedFile("test_zip_streamed");

fn expectedLines(allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (1..201) |i| try out.print(allocator, "line {d:0>4}\n", .{i});
    return out.toOwnedSlice(allocator);
}

test "zip: lists the entries of an archive made by zip, without folders" {
    var archive = try Archive.open(testing.allocator, standard_zip, .{});
    defer archive.deinit(testing.allocator);
    const want = [_][]const u8{ "pack/info.txt", "pack/empty.txt", "pack/data/lines.txt", "pack/data/zeros.bin" };
    try testing.expectEqual(want.len, archive.entries.len);
    for (want, archive.entries) |name, entry| try testing.expectEqualStrings(name, entry.name);
    try testing.expectEqual(Method.stored, archive.find("pack/info.txt").?.method);
    try testing.expectEqual(Method.deflate, archive.find("pack/data/lines.txt").?.method);
    try testing.expect(archive.find("pack/") == null);
    try testing.expect(archive.find("missing") == null);
}

test "zip: reads stored and deflate entries" {
    const a = testing.allocator;
    var archive = try Archive.open(a, standard_zip, .{});
    defer archive.deinit(a);

    const info = try archive.readName(a, "pack/info.txt");
    defer a.free(info);
    try testing.expectEqualStrings("stored entry\n", info);

    const empty = try archive.readName(a, "pack/empty.txt");
    defer a.free(empty);
    try testing.expectEqual(0, empty.len);

    const lines = try archive.readName(a, "pack/data/lines.txt");
    defer a.free(lines);
    const want = try expectedLines(a);
    defer a.free(want);
    try testing.expectEqualStrings(want, lines);

    const zeros = try archive.readName(a, "pack/data/zeros.bin");
    defer a.free(zeros);
    try testing.expectEqual(4 * 1024 * 1024, zeros.len);
    try testing.expect(std.mem.allEqual(u8, zeros, 0));

    try testing.expectError(error.NotFound, archive.readName(a, "pack/none.txt"));
}

test "zip: reads a streamed archive with a Zip64 end record" {
    const a = testing.allocator;
    var archive = try Archive.open(a, streamed_zip, .{});
    defer archive.deinit(a);
    try testing.expectEqual(1, archive.entries.len);
    const data = try archive.readName(a, "-");
    defer a.free(data);
    try testing.expectEqualStrings("streamed entry\nstreamed entry\nstreamed entry\n", data);
}

test "zip: open does not decompress entries (REQ-ASSETS-001)" {
    // zeros.bin is 4 MiB. Open must allocate much less than that.
    var counting: testing.FailingAllocator = .init(testing.allocator, .{});
    var archive = try Archive.open(counting.allocator(), standard_zip, .{});
    defer archive.deinit(counting.allocator());
    try testing.expect(counting.allocated_bytes < 4096);
}

test "zip: bytes before the archive" {
    const a = testing.allocator;
    const prefix = "#!/bin/sh\nexit 0\n";
    const bytes = try std.mem.concat(a, u8, &.{ prefix, standard_zip });
    defer a.free(bytes);
    var archive = try Archive.open(a, bytes, .{});
    defer archive.deinit(a);
    const info = try archive.readName(a, "pack/info.txt");
    defer a.free(info);
    try testing.expectEqualStrings("stored entry\n", info);
}

test "zip: a bad entry fails alone" {
    const a = testing.allocator;
    const bytes = try a.dupe(u8, standard_zip);
    defer a.free(bytes);
    var archive = try Archive.open(a, bytes, .{});
    defer archive.deinit(a);

    // Make the deflate stream of lines.txt a reserved block type.
    const entry = archive.find("pack/data/lines.txt").?;
    const data = try archive.entryData(entry);
    const start = @intFromPtr(data.ptr) - @intFromPtr(bytes.ptr);
    @memset(bytes[start..][0..data.len], 0xff);
    try testing.expectError(error.Corrupt, archive.readName(a, "pack/data/lines.txt"));

    // A change to stored data fails the CRC-32 check.
    const info = archive.find("pack/info.txt").?;
    const info_data = try archive.entryData(info);
    bytes[@intFromPtr(info_data.ptr) - @intFromPtr(bytes.ptr)] ^= 1;
    try testing.expectError(error.ChecksumMismatch, archive.readName(a, "pack/info.txt"));
    var lenient = archive;
    lenient.options.check_crc = false;
    const changed = try lenient.readName(a, "pack/info.txt");
    defer a.free(changed);
    try testing.expectEqualStrings("rtored entry\n", changed);

    // The other entries stay readable.
    const zeros = try archive.readName(a, "pack/data/zeros.bin");
    defer a.free(zeros);
    try testing.expectEqual(4 * 1024 * 1024, zeros.len);
}

test "zip: refuses data that is not an archive or is cut" {
    const a = testing.allocator;
    try testing.expectError(error.NotAZip, Archive.open(a, "", .{}));
    try testing.expectError(error.NotAZip, Archive.open(a, "not a zip archive, only some text here", .{}));
    // Without its first half, the central directory is not in the bytes.
    try testing.expectError(error.Corrupt, Archive.open(a, standard_zip[standard_zip.len / 2 ..], .{}));
    // Without the end record.
    try testing.expectError(error.NotAZip, Archive.open(a, standard_zip[0 .. standard_zip.len - 22], .{}));
}

test "zip: a backslash name gets a slash, and other methods fail" {
    // One stored entry, written here: "a\b.txt" with method 12 (bzip2).
    const a = testing.allocator;
    const name = "a\\b.txt";
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    var local: [local_header_len]u8 = @splat(0);
    std.mem.writeInt(u32, local[0..4], local_header_sig, .little);
    std.mem.writeInt(u16, local[8..10], 12, .little);
    std.mem.writeInt(u16, local[26..28], name.len, .little);
    try buf.appendSlice(a, &local);
    try buf.appendSlice(a, name);
    const dir_start = buf.items.len;
    var central: [central_len]u8 = @splat(0);
    std.mem.writeInt(u32, central[0..4], central_sig, .little);
    std.mem.writeInt(u16, central[10..12], 12, .little);
    std.mem.writeInt(u16, central[28..30], name.len, .little);
    try buf.appendSlice(a, &central);
    try buf.appendSlice(a, name);
    var end: [end_len]u8 = @splat(0);
    std.mem.writeInt(u32, end[0..4], end_sig, .little);
    std.mem.writeInt(u32, end[12..16], @intCast(buf.items.len - dir_start), .little);
    std.mem.writeInt(u32, end[16..20], @intCast(dir_start), .little);
    try buf.appendSlice(a, &end);

    var archive = try Archive.open(a, buf.items, .{});
    defer archive.deinit(a);
    try testing.expectEqualStrings("a/b.txt", archive.entries[0].name);
    try testing.expectError(error.UnsupportedMethod, archive.readName(a, "a/b.txt"));
}
