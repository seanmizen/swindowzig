//! Frame hashes at the checkpoints of a demo script (REQ-DEMO-003).
//!
//! A hash file has one line for each checkpoint: `<name> <16 hex digits>`.
//! The committed file is `demos/<name>/hashes/lavapipe-<preset>.txt`. A
//! check run makes the same lines and compares them with the file.

const std = @import("std");

/// The hash of the pixels of one frame.
pub fn frameHash(pixels: []const u8) u64 {
    return std.hash.Wyhash.hash(0x5eed_de30, pixels);
}

pub const Record = struct {
    name: []const u8,
    hash: u64,
};

pub const ParseError = error{ BadLine, OutOfMemory };

/// Parse a hash file. The records keep slices into `text`.
pub fn parse(allocator: std.mem.Allocator, text: []const u8) ParseError![]Record {
    var out: std.ArrayList(Record) = .empty;
    errdefer out.deinit(allocator);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const space = std.mem.lastIndexOfScalar(u8, line, ' ') orelse return error.BadLine;
        const name = std.mem.trim(u8, line[0..space], " \t");
        const hash = std.fmt.parseInt(u64, line[space + 1 ..], 16) catch return error.BadLine;
        if (name.len == 0) return error.BadLine;
        try out.append(allocator, .{ .name = name, .hash = hash });
    }
    return out.toOwnedSlice(allocator);
}

/// Write the records in the hash file format.
pub fn format(records: []const Record, w: *std.Io.Writer) std.Io.Writer.Error!void {
    for (records) |r| try w.print("{s} {x:0>16}\n", .{ r.name, r.hash });
}

pub const Mismatch = struct {
    name: []const u8,
    want: ?u64,
    got: ?u64,
};

/// Compare the hashes of a run (`got`) with the committed hashes (`want`).
/// Write each difference to `out` and give the number of differences.
pub fn compare(want: []const Record, got: []const Record, out: []Mismatch) usize {
    var n: usize = 0;
    for (got) |g| {
        const w = find(want, g.name);
        if (w == null or w.? != g.hash) {
            if (n < out.len) out[n] = .{ .name = g.name, .want = w, .got = g.hash };
            n += 1;
        }
    }
    for (want) |w| {
        if (find(got, w.name) == null) {
            if (n < out.len) out[n] = .{ .name = w.name, .want = w.hash, .got = null };
            n += 1;
        }
    }
    return n;
}

fn find(records: []const Record, name: []const u8) ?u64 {
    for (records) |r| {
        if (std.mem.eql(u8, r.name, name)) return r.hash;
    }
    return null;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "hashes: a hash file round trip (REQ-DEMO-003)" {
    const records = [_]Record{ .{ .name = "aa_off", .hash = 0x0123456789abcdef }, .{ .name = "fxaa", .hash = 7 } };
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try format(&records, &w);
    try testing.expectEqualStrings("aa_off 0123456789abcdef\nfxaa 0000000000000007\n", w.buffered());
    const back = try parse(testing.allocator, w.buffered());
    defer testing.allocator.free(back);
    try testing.expectEqual(@as(usize, 2), back.len);
    try testing.expectEqualStrings("fxaa", back[1].name);
    try testing.expectEqual(@as(u64, 7), back[1].hash);
    try testing.expectError(error.BadLine, parse(testing.allocator, "nohash\n"));
}

test "hashes: compare finds a changed, a new and a lost checkpoint (REQ-DEMO-003)" {
    const want = [_]Record{ .{ .name = "a", .hash = 1 }, .{ .name = "b", .hash = 2 }, .{ .name = "c", .hash = 3 } };
    const got = [_]Record{ .{ .name = "a", .hash = 1 }, .{ .name = "b", .hash = 9 }, .{ .name = "d", .hash = 4 } };
    var out: [8]Mismatch = undefined;
    try testing.expectEqual(@as(usize, 0), compare(&want, &want, &out));
    const n = compare(&want, &got, &out);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("b", out[0].name);
    try testing.expectEqual(@as(?u64, null), out[1].want);
    try testing.expectEqual(@as(?u64, null), out[2].got);
}

test "hashes: one changed byte changes the frame hash (REQ-DEMO-003)" {
    var a: [64]u8 = @splat(10);
    const h = frameHash(&a);
    try testing.expectEqual(h, frameHash(&a));
    a[63] = 11;
    try testing.expect(h != frameHash(&a));
}
