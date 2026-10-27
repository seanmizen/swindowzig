//! A wasm program that saves region files to the OPFS cache of sw_assets
//! and loads them again (REQ-VOXEL-011). `zig build test` builds it for
//! wasm32-freestanding. `backends/wasm/files.test.ts` builds it with
//! `zig build region-check-wasm` and runs it with a fake OPFS.
//!
//! It generates 2 × 2 chunks of the demo content around chunk (0, 0), so
//! the chunks are in 4 regions.
const std = @import("std");
const sw_voxel = @import("sw_voxel");
const sw_assets = @import("sw_assets");
const content = @import("voxel_content");

const region = sw_voxel.region;
const World = sw_voxel.world.World;
const alloc = std.heap.wasm_allocator;

/// No log: the program has no log import.
pub const std_options: std.Options = .{ .logFn = noLog };

fn noLog(comptime _: std.log.Level, comptime _: @TypeOf(.enum_literal), comptime _: []const u8, _: anytype) void {}

const coords = [_][2]i32{ .{ -1, -1 }, .{ -1, 0 }, .{ 0, -1 }, .{ 0, 0 } };
const store: region.Store(sw_assets.cache) = .{ .prefix = "check" };

var world: ?World = null;
var writes: [coords.len]?sw_assets.cache.WriteRequest = @splat(null);
var loads: [coords.len]?region.Store(sw_assets.cache).LoadRequest = @splat(null);

/// The name of the last error.
var out: []const u8 = &.{};

export fn check_out_ptr() [*]const u8 {
    return out.ptr;
}

export fn check_out_len() usize {
    return out.len;
}

fn fail(err: anyerror) i32 {
    out = @errorName(err);
    return -1;
}

fn generated() !*World {
    if (world == null) {
        world = try World.init(alloc, content.world_gen.presetConfig(.hilly), 2);
        for (coords) |c| _ = try world.?.generateChunk(c[0], c[1]);
    }
    return &world.?;
}

/// Start to save one region for each chunk. 0, or -1 on an error.
export fn check_region_save() i32 {
    const w = generated() catch |err| return fail(err);
    for (coords, &writes) |c, *req| {
        var r = region.Region.init(alloc, region.regionCoord(c[0]), region.regionCoord(c[1]));
        defer r.deinit();
        r.put(c[0], c[1], &w.get(c[0], c[1]).?.chunk.blocks) catch |err| return fail(err);
        req.* = store.save(alloc, &r) catch |err| return fail(err);
    }
    return 0;
}

/// 1 pending, 2 done, -1 failed.
export fn check_region_save_poll() i32 {
    var done: usize = 0;
    for (&writes) |*slot| {
        const req = &(slot.* orelse {
            done += 1;
            continue;
        });
        switch (req.poll()) {
            .pending => {},
            .done => slot.* = null,
            .failed => |err| {
                slot.* = null;
                return fail(err);
            },
        }
    }
    return if (done == writes.len) 2 else 1;
}

/// Start to load the regions. 0, or -1 on an error.
export fn check_region_load() i32 {
    for (coords, &loads) |c, *req| {
        req.* = store.load(alloc, region.regionCoord(c[0]), region.regionCoord(c[1])) catch |err| return fail(err);
    }
    return 0;
}

var loaded: usize = 0;

/// 1 pending, 2 each region loaded with the same blocks, 3 a region is
/// missing, 4 the blocks are not the same, -1 failed.
export fn check_region_load_poll() i32 {
    const w = generated() catch |err| return fail(err);
    for (coords, &loads) |c, *slot| {
        const req = &(slot.* orelse continue);
        switch (req.poll()) {
            .pending => {},
            .missing => {
                slot.* = null;
                return 3;
            },
            .failed => |err| {
                slot.* = null;
                return fail(err);
            },
            .region => |res| {
                slot.* = null;
                var r = res;
                defer r.deinit();
                var got = (r.get(alloc, c[0], c[1]) catch |err| return fail(err)) orelse return 3;
                defer got.deinit(alloc);
                const want = &w.get(c[0], c[1]).?.chunk.blocks;
                for (0..sw_voxel.chunk.BLOCKS_PER_CHUNK) |i| {
                    if (want.get(i) != got.get(i)) return 4;
                }
                loaded += 1;
            },
        }
    }
    if (loaded == coords.len) {
        loaded = 0;
        return 2;
    }
    return 1;
}
