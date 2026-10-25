//! Tests of the chunk protocol (pipeline/protocol.zig, P6).
//!
//! The root of this test is here, next to chunk.zig, because a module can
//! import only files under the directory of its root.
//!
//!   round trip   each message kind gives the same fields after encode and
//!                decode, and the same bytes after a second encode.
//!   layout       the fields are at the offsets of the documented layout.
//!   header       a bad magic, version, kind or length gives an error.
//!   fuzz         random and changed messages never crash the decoder or a
//!                worker. A message that decodes encodes to the same bytes.
const std = @import("std");
const protocol = @import("pipeline/protocol.zig");
const stages = @import("pipeline/stages.zig");
const worker_world = @import("pipeline/worker_world.zig");
const chunk_mod = @import("chunk.zig");
const world_gen = @import("world_gen.zig");

const PalettedBlocks = chunk_mod.PalettedBlocks;
const PackedQuad = protocol.PackedQuad;

fn hilly(seed: u64) world_gen.WorldGenConfig {
    var c = world_gen.presetConfig(.hilly);
    c.seed = seed;
    return c;
}

/// Encode the decoded message `d` again.
fn reencode(a: std.mem.Allocator, d: protocol.Decoded) ![]u8 {
    return switch (d.msg) {
        .hello => |h| protocol.encodeHello(a, h),
        .edit => |e| protocol.encodeEdit(a, e),
        .job => |j| protocol.encodeJob(a, d.id, j),
        .err => |e| protocol.encodeError(a, d.id, e),
        .result => |r| blk: {
            switch (r.head.stage) {
                .mesh => {
                    const q = try a.alloc(PackedQuad, r.quadCount());
                    defer a.free(q);
                    r.copyQuads(q);
                    break :blk protocol.encodeResult(a, d.id, r.head, .{ .quads = q });
                },
                .generate => if (r.has_blocks) {
                    var pb = try protocol.decodeBlocks(a, r);
                    defer pb.deinit(a);
                    // Each packed index reads a valid block.
                    for (0..chunk_mod.BLOCKS_PER_CHUNK) |i| _ = pb.get(i);
                    break :blk protocol.encodeResult(a, d.id, r.head, .{ .blocks = &pb });
                } else break :blk protocol.encodeResult(a, d.id, r.head, .none),
                .light => break :blk protocol.encodeResult(a, d.id, r.head, .none),
            }
        },
    };
}

/// decode(bytes), then encode, must give `bytes` again.
fn expectRoundTrip(a: std.mem.Allocator, bytes: []const u8) !protocol.Decoded {
    const d = try protocol.decode(bytes);
    const again = try reencode(a, d);
    defer a.free(again);
    try std.testing.expectEqualSlices(u8, bytes, again);
    return d;
}

test "protocol: Hello, Edit and Job round trip" {
    const a = std.testing.allocator;
    for ([_]world_gen.Preset{ .flatland, .hilly }) |preset| {
        var c = world_gen.presetConfig(preset);
        c.seed = 0xDEAD_BEEF_0123_4567;
        const bytes = try protocol.encodeHello(a, .{ .cache_limit = 64 << 20, .config = c });
        defer a.free(bytes);
        try std.testing.expectEqual(@as(usize, protocol.HEADER_LEN + protocol.HELLO_LEN), bytes.len);
        const d = try expectRoundTrip(a, bytes);
        const h = d.msg.hello;
        try std.testing.expectEqual(protocol.BUILD_HASH, h.build_hash);
        try std.testing.expectEqual(@as(u64, 64 << 20), h.cache_limit);
        try std.testing.expectEqualDeep(c, h.config);
    }

    const edit: protocol.Edit = .{ .cx = -7, .cz = 123456, .version = 42, .x = 15, .y = 255, .z = 0, .block = .glowstone };
    const eb = try protocol.encodeEdit(a, edit);
    defer a.free(eb);
    try std.testing.expectEqual(@as(usize, 32), eb.len);
    try std.testing.expectEqualDeep(edit, (try expectRoundTrip(a, eb)).msg.edit);

    var job: protocol.Job = .{ .stage = .mesh, .cx = -3, .cz = 9, .ao = .moore, .lighting = .skylight };
    for (&job.blocks, &job.light, 0..) |*b, *l, i| {
        b.* = @intCast(i * 3);
        l.* = @intCast(1000 + i);
    }
    const jb = try protocol.encodeJob(a, 77, job);
    defer a.free(jb);
    try std.testing.expectEqual(@as(usize, 104), jb.len);
    const jd = try expectRoundTrip(a, jb);
    try std.testing.expectEqual(@as(u32, 77), jd.id);
    try std.testing.expectEqualDeep(job, jd.msg.job);

    const gen: protocol.Job = .{ .stage = .generate, .cx = 1, .cz = 2, .want_blocks = true };
    const gb = try protocol.encodeJob(a, 1, gen);
    defer a.free(gb);
    try std.testing.expectEqualDeep(gen, (try expectRoundTrip(a, gb)).msg.job);
}

test "protocol: Result and Error round trip, with the payload bytes ready for upload" {
    const a = std.testing.allocator;
    // Blocks: a generated chunk, a chunk with edits, and a uniform chunk.
    var gen = try stages.generate(a, 0, hilly(0), 2, -1);
    defer gen.deinit(a);
    var edited = try stages.generate(a, 0, hilly(0), 0, 0);
    defer edited.deinit(a);
    try edited.set(a, chunk_mod.blockLinearIdx(3, 70, 4), .glowstone);
    try edited.set(a, chunk_mod.blockLinearIdx(15, 0, 15), .air);
    var uniform: PalettedBlocks = .{};
    for ([_]*const PalettedBlocks{ &gen, &edited, &uniform }) |pb| {
        const head: protocol.ResultHead = .{ .stage = .generate, .cx = 2, .cz = -1, .block_ver = 5, .job_us = 1234 };
        const bytes = try protocol.encodeResult(a, 9, head, .{ .blocks = pb });
        defer a.free(bytes);
        try std.testing.expectEqual(protocol.PAYLOAD_OFFSET + protocol.blocksLen(pb), bytes.len);
        const d = try expectRoundTrip(a, bytes);
        const r = d.msg.result;
        try std.testing.expect(r.has_blocks);
        try std.testing.expectEqualDeep(head, r.head);
        var back = try protocol.decodeBlocks(a, r);
        defer back.deinit(a);
        for (0..chunk_mod.BLOCKS_PER_CHUNK) |i| try std.testing.expectEqual(pb.get(i), back.get(i));
    }

    // A generate result with no blocks.
    const plain = try protocol.encodeResult(a, 3, .{ .stage = .generate, .cx = 0, .cz = 0, .block_ver = 2 }, .none);
    defer a.free(plain);
    try std.testing.expectEqual(@as(usize, protocol.PAYLOAD_OFFSET), plain.len);
    try std.testing.expect(!(try expectRoundTrip(a, plain)).msg.result.has_blocks);

    // Light: the hash only.
    const lh: protocol.ResultHead = .{ .stage = .light, .cx = -1, .cz = 4, .block_ver = 1, .light_hash = 0x0123_4567_89AB_CDEF };
    const lb = try protocol.encodeResult(a, 4, lh, .none);
    defer a.free(lb);
    try std.testing.expectEqualDeep(lh, (try expectRoundTrip(a, lb)).msg.result.head);

    // Mesh: real quads. The payload is the PackedQuad bytes, at a 16-byte
    // aligned offset (C5).
    var empty: stages.ChunkLight = .{};
    var hood: stages.Neighbourhood = undefined;
    for (&hood) |*h| h.* = .{ .blocks = &gen, .light = &empty };
    var m = try stages.mesh(a, &hood, .moore, .skylight);
    defer m.deinit(a);
    try std.testing.expect(m.quads.len > 0);
    const mh: protocol.ResultHead = .{ .stage = .mesh, .cx = 2, .cz = -1, .block_ver = 0, .y_min = m.y_min, .y_max = m.y_max, .job_us = 99 };
    const mb = try protocol.encodeResult(a, 5, mh, .{ .quads = m.quads });
    defer a.free(mb);
    try std.testing.expectEqual(protocol.PAYLOAD_OFFSET + 16 * m.quads.len, mb.len);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(m.quads), mb[protocol.PAYLOAD_OFFSET..]);
    const md = try expectRoundTrip(a, mb);
    // The encoder adds the hash of the quads (C5).
    var mh_hashed = mh;
    mh_hashed.mesh_hash = protocol.meshHash(std.mem.sliceAsBytes(m.quads));
    try std.testing.expectEqualDeep(mh_hashed, md.msg.result.head);
    try std.testing.expectEqual(m.quads.len, md.msg.result.quadCount());

    // decodeResultHead reads only the first PAYLOAD_OFFSET bytes: main
    // decodes a mesh Result that JS holds from them (C5).
    const info = (try protocol.decodeResultHead(mb[0..protocol.PAYLOAD_OFFSET], mb.len)).?;
    try std.testing.expectEqual(@as(u32, 5), info.id);
    try std.testing.expectEqualDeep(mh_hashed, info.head);
    try std.testing.expectEqual(@as(u32, @intCast(m.quads.len)), info.quad_count);
    try std.testing.expectEqual(mb.len - protocol.PAYLOAD_OFFSET, info.payload_len);
    // The length must be the length of the header.
    try std.testing.expectError(error.Truncated, protocol.decodeResultHead(mb[0..protocol.PAYLOAD_OFFSET], mb.len - 16));
    try std.testing.expectError(error.Truncated, protocol.decodeResultHead(mb[0..20], mb.len));
    // Another kind gives null. A changed quad gives a hash error in decode.
    const edit = try protocol.encodeEdit(a, .{ .cx = 0, .cz = 0, .version = 1, .x = 1, .y = 2, .z = 3, .block = .stone });
    defer a.free(edit);
    try std.testing.expect(try protocol.decodeResultHead(edit, edit.len) == null);
    const changed = try a.dupe(u8, mb);
    defer a.free(changed);
    changed[protocol.PAYLOAD_OFFSET] ^= 1;
    try std.testing.expectError(error.BadField, protocol.decode(changed));

    // Error, with a text.
    const eb = try protocol.encodeError(a, 6, .{ .code = .stale_input, .stage = .light, .cx = 8, .cz = -8, .text = "versions" });
    defer a.free(eb);
    const ed = try expectRoundTrip(a, eb);
    try std.testing.expectEqual(protocol.ErrorCode.stale_input, ed.msg.err.code);
    try std.testing.expectEqualStrings("versions", ed.msg.err.text);
}

test "protocol: the fields are at the documented offsets, little-endian" {
    const a = std.testing.allocator;
    const job: protocol.Job = .{ .stage = .light, .cx = -2, .cz = 0x01020304, .want_blocks = true, .blocks = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9 } };
    const b = try protocol.encodeJob(a, 0xAABBCCDD, job);
    defer a.free(b);
    // Header.
    try std.testing.expectEqualSlices(u8, "VXCP", b[0..4]);
    try std.testing.expectEqual(protocol.VERSION, std.mem.readInt(u16, b[4..6], .little));
    try std.testing.expectEqual(@as(u8, 3), b[6]);
    try std.testing.expectEqual(@as(u32, protocol.JOB_LEN), std.mem.readInt(u32, b[8..12], .little));
    try std.testing.expectEqualSlices(u8, &.{ 0xDD, 0xCC, 0xBB, 0xAA }, b[12..16]);
    // Body.
    const body = b[16..];
    try std.testing.expectEqual(@as(u8, 1), body[0]);
    try std.testing.expectEqual(@as(u8, 1), body[3]);
    try std.testing.expectEqual(@as(i32, -2), std.mem.readInt(i32, body[4..8], .little));
    try std.testing.expectEqualSlices(u8, &.{ 4, 3, 2, 1 }, body[8..12]);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, body[16..20], .little));
    try std.testing.expectEqual(@as(u32, 9), std.mem.readInt(u32, body[48..52], .little));

    const r = try protocol.encodeResult(a, 1, .{ .stage = .mesh, .cx = 0, .cz = 0, .y_min = 1.5, .y_max = 70, .job_us = 7 }, .{ .quads = &.{.{ 1, 2, 3, 4 }} });
    defer a.free(r);
    try std.testing.expectEqual(@as(u32, @bitCast(@as(f32, 1.5))), std.mem.readInt(u32, r[32..36], .little));
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, r[40..44], .little));
    try std.testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, r[44..48], .little));
    try std.testing.expectEqual(protocol.meshHash(r[64..80]), std.mem.readInt(u64, r[48..56], .little));
    try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, r[56..64], .little));
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, r[64..68], .little));
    try std.testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, r[76..80], .little));
}

test "protocol: a bad header gives an error" {
    const a = std.testing.allocator;
    const good = try protocol.encodeEdit(a, .{ .cx = 0, .cz = 0, .version = 1, .x = 1, .y = 2, .z = 3, .block = .stone });
    defer a.free(good);
    var b: [32]u8 = undefined;

    try std.testing.expectError(error.Truncated, protocol.decode(good[0..10]));
    try std.testing.expectError(error.Truncated, protocol.decode(good[0..31]));
    @memcpy(&b, good);
    b[0] ^= 1;
    try std.testing.expectError(error.BadMagic, protocol.decode(&b));
    @memcpy(&b, good);
    b[4] +%= 1;
    try std.testing.expectError(error.BadVersion, protocol.decode(&b));
    @memcpy(&b, good);
    b[6] = 99;
    try std.testing.expectError(error.BadKind, protocol.decode(&b));
    @memcpy(&b, good);
    b[6] = @backingInt(protocol.Kind.job);
    try std.testing.expectError(error.BadLength, protocol.decode(&b));
    @memcpy(&b, good);
    b[16 + 12] = 16; // x past the chunk
    try std.testing.expectError(error.BadField, protocol.decode(&b));
    @memcpy(&b, good);
    b[16 + 15] = 200; // no such block
    try std.testing.expectError(error.BadField, protocol.decode(&b));
}

/// Valid messages of each kind, for the fuzz test.
fn corpus(a: std.mem.Allocator, list: *std.ArrayList([]u8)) !void {
    try list.append(a, try protocol.encodeHello(a, .{ .cache_limit = 1 << 20, .config = hilly(3) }));
    try list.append(a, try protocol.encodeEdit(a, .{ .cx = 1, .cz = -1, .version = 3, .x = 4, .y = 5, .z = 6, .block = .sand }));
    try list.append(a, try protocol.encodeJob(a, 2, .{ .stage = .mesh, .cx = 0, .cz = 0, .ao = .classic, .lighting = .skylight }));
    var pb: PalettedBlocks = .{};
    defer pb.deinit(a);
    try pb.set(a, 7, .stone);
    try pb.set(a, 9000, .glowstone);
    try pb.set(a, 65535, .wood);
    try list.append(a, try protocol.encodeResult(a, 3, .{ .stage = .generate, .cx = 0, .cz = 0 }, .{ .blocks = &pb }));
    try list.append(a, try protocol.encodeResult(a, 4, .{ .stage = .light, .cx = 0, .cz = 0, .light_hash = 5 }, .none));
    try list.append(a, try protocol.encodeResult(a, 5, .{ .stage = .mesh, .cx = 0, .cz = 0 }, .{ .quads = &.{ .{ 1, 2, 3, 4 }, .{ 5, 6, 7, 8 } } }));
    try list.append(a, try protocol.encodeError(a, 6, .{ .code = .bad_message, .text = "x" }));
}

/// Decode `bytes`. A message that decodes must encode to the same bytes.
/// Returns true when it decodes.
fn fuzzOne(a: std.mem.Allocator, bytes: []const u8) !bool {
    const d = protocol.decode(bytes) catch return false;
    const again = try reencode(a, d);
    defer a.free(again);
    try std.testing.expectEqualSlices(u8, bytes, again);
    return true;
}

test "protocol: fuzz: random and changed messages never crash the decoder" {
    const a = std.testing.allocator;
    var list: std.ArrayList([]u8) = .empty;
    defer {
        for (list.items) |m| a.free(m);
        list.deinit(a);
    }
    try corpus(a, &list);
    var prng = std.Random.DefaultPrng.init(0x5EED_708);
    const rand = prng.random();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    var decoded: usize = 0;
    var rejected: usize = 0;
    for (0..20_000) |iter| {
        const base = list.items[iter % list.items.len];
        buf.clearRetainingCapacity();
        try buf.appendSlice(a, base);
        switch (rand.uintLessThan(u8, 5)) {
            // Flip 1 to 4 bits.
            0 => for (0..rand.intRangeAtMost(usize, 1, 4)) |_| {
                const i = rand.uintLessThan(usize, buf.items.len);
                buf.items[i] ^= @as(u8, 1) << rand.int(u3);
            },
            // Set a random byte in the header or the fixed body.
            1 => buf.items[rand.uintLessThan(usize, @min(buf.items.len, protocol.PAYLOAD_OFFSET))] = rand.int(u8),
            // Cut the message.
            2 => buf.shrinkRetainingCapacity(rand.uintLessThan(usize, buf.items.len)),
            // Add bytes at the end, and maybe fix the body length.
            3 => {
                for (0..rand.intRangeAtMost(usize, 1, 40)) |_| try buf.append(a, rand.int(u8));
                if (rand.boolean()) std.mem.writeInt(u32, buf.items[8..12], @intCast(buf.items.len - 16), .little);
            },
            // Random bytes with a valid header.
            else => {
                const n = rand.uintLessThan(usize, 200);
                try buf.resize(a, 16 + n);
                rand.bytes(buf.items[16..]);
                buf.items[6] = rand.intRangeAtMost(u8, 1, 5);
                std.mem.writeInt(u32, buf.items[8..12], @intCast(n), .little);
            },
        }
        if (try fuzzOne(a, buf.items)) decoded += 1 else rejected += 1;
    }
    // The fuzz must reach both paths.
    try std.testing.expect(decoded > 100);
    try std.testing.expect(rejected > 100);
}

test "protocol: fuzz: a worker answers each message with a valid message" {
    const a = std.testing.allocator;
    var list: std.ArrayList([]u8) = .empty;
    defer {
        for (list.items) |m| a.free(m);
        list.deinit(a);
    }
    try corpus(a, &list);
    var prng = std.Random.DefaultPrng.init(0xF00D);
    const rand = prng.random();
    // A worker with no Hello: a job gets an Error (no_world), so the fuzz
    // runs no stage.
    var w: worker_world.WorkerWorld = .init(a);
    defer w.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    for (0..5_000) |iter| {
        const base = list.items[iter % list.items.len];
        buf.clearRetainingCapacity();
        try buf.appendSlice(a, base);
        for (0..rand.intRangeAtMost(usize, 0, 3)) |_| {
            const i = rand.uintLessThan(usize, buf.items.len);
            buf.items[i] ^= @as(u8, 1) << rand.int(u3);
        }
        // Skip a Hello: it would start a world.
        if (protocol.decode(buf.items)) |d| if (d.msg == .hello) continue else {} else |_| {}
        const reply = try w.handle(buf.items) orelse continue;
        defer a.free(reply);
        const d = try protocol.decode(reply);
        try std.testing.expect(d.msg == .err or d.msg == .hello);
    }
}

test "protocol: lightHash is the same for equal light, and differs for other light" {
    const a = std.testing.allocator;
    var blocks = try stages.generate(a, 0, hilly(0), 0, 0);
    defer blocks.deinit(a);
    var window: stages.Window = undefined;
    for (&window) |*w| w.* = &blocks;
    var l1 = try stages.light(a, &window);
    defer l1.deinit(a);
    var l2 = try stages.light(a, &window);
    defer l2.deinit(a);
    try std.testing.expectEqual(protocol.lightHash(&l1), protocol.lightHash(&l2));
    try blocks.set(a, chunk_mod.blockLinearIdx(8, 200, 8), .glowstone);
    var l3 = try stages.light(a, &window);
    defer l3.deinit(a);
    try std.testing.expect(protocol.lightHash(&l1) != protocol.lightHash(&l3));
}
