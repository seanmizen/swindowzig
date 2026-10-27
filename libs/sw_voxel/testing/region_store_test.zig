//! Region files through `sw_assets.cache` on native: a folder
//! (REQ-VOXEL-011). `zig build test` runs it with the test content.
//! `backends/wasm/files.test.ts` tests the web path (OPFS).
const std = @import("std");
const sw_voxel = @import("sw_voxel");
const sw_assets = @import("sw_assets");

const region = sw_voxel.region;
const World = sw_voxel.world.World;

test "a world saves to a cache folder and loads with the same blocks (REQ-VOXEL-011)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    sw_assets.cache.useDirectory(tmp.dir, io);

    var world = try World.init(a, .{}, 2);
    defer world.deinit();
    // Two regions: x -1 and x 0.
    for ([_]i32{ -2, -1, 0, 1 }) |cx| for ([_]i32{ 0, 1 }) |cz| {
        _ = try world.generateChunk(cx, cz);
    };

    const store: region.Store(sw_assets.cache) = .{ .prefix = "test-world" };
    for ([_]i32{ -1, 0 }) |rx| {
        var r = region.Region.init(a, rx, 0);
        defer r.deinit();
        var it = world.chunks.valueIterator();
        while (it.next()) |lc_ptr| {
            const lc = lc_ptr.*;
            if (r.contains(lc.cx, lc.cz)) try r.put(lc.cx, lc.cz, &lc.chunk.blocks);
        }
        var w = try store.save(a, &r);
        while (true) switch (w.poll()) {
            .pending => {},
            .done => break,
            .failed => |err| return err,
        };
    }

    var loaded = try World.init(a, .{}, 2);
    defer loaded.deinit();
    for ([_]i32{ -1, 0 }) |rx| {
        var req = try store.load(a, rx, 0);
        var result = while (true) switch (req.poll()) {
            .pending => {},
            .region => |r| break r,
            .missing => return error.TestMissingRegion,
            .failed => |err| return err,
        };
        defer result.deinit();
        for (0..region.CHUNKS) |i| {
            const cx = rx * region.SIZE + @as(i32, @intCast(i % region.SIZE));
            const cz = @as(i32, @intCast(i / region.SIZE));
            const blocks = try result.get(a, cx, cz) orelse continue;
            _ = try loaded.installBlocks(cx, cz, blocks);
        }
    }
    try std.testing.expectEqual(world.chunks.count(), loaded.chunks.count());
    var it = world.chunks.valueIterator();
    while (it.next()) |lc_ptr| {
        const lc = lc_ptr.*;
        const got = loaded.get(lc.cx, lc.cz) orelse return error.TestMissingChunk;
        for (0..16) |x| for (0..World.height) |y| for (0..16) |z| {
            try std.testing.expectEqual(lc.chunk.blocks.getAt(x, y, z), got.chunk.blocks.getAt(x, y, z));
        };
    }

    // A region with no file is missing.
    var none = try store.load(a, 5, 5);
    try std.testing.expect(none.poll() == .missing);
}
