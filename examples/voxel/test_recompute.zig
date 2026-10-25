//! A recompute from scratch, for the pipeline tests (P2, P3).
//!
//! It makes the blocks of each chunk with `stages.generate` and the edit
//! log of the World, then runs the light and the mesh stages. It shares no
//! code with the workers (worker_world.zig) except the stages. A test then
//! checks that each current result of the World is the recomputed result.
const std = @import("std");
const stages = @import("pipeline/stages.zig");
const protocol = @import("pipeline/protocol.zig");
const scheduler_mod = @import("pipeline/scheduler.zig");
const world_mod = @import("world.zig");
const chunk_mod = @import("chunk.zig");

const World = world_mod.World;
const Scheduler = scheduler_mod.Scheduler;
const PalettedBlocks = chunk_mod.PalettedBlocks;
const Key = struct { cx: i32, cz: i32 };

pub const Recompute = struct {
    a: std.mem.Allocator,
    world: *const World,
    blocks: std.AutoHashMapUnmanaged(Key, *PalettedBlocks) = .empty,
    lights: std.AutoHashMapUnmanaged(Key, *stages.ChunkLight) = .empty,

    pub fn init(a: std.mem.Allocator, world: *const World) Recompute {
        return .{ .a = a, .world = world };
    }

    pub fn deinit(self: *Recompute) void {
        var bi = self.blocks.valueIterator();
        while (bi.next()) |b| {
            b.*.deinit(self.a);
            self.a.destroy(b.*);
        }
        self.blocks.deinit(self.a);
        var li = self.lights.valueIterator();
        while (li.next()) |l| {
            l.*.deinit(self.a);
            self.a.destroy(l.*);
        }
        self.lights.deinit(self.a);
    }

    pub fn blocksOf(self: *Recompute, cx: i32, cz: i32) !*PalettedBlocks {
        const gop = try self.blocks.getOrPut(self.a, .{ .cx = cx, .cz = cz });
        if (gop.found_existing) return gop.value_ptr.*;
        const b = try self.a.create(PalettedBlocks);
        b.* = try stages.generate(self.a, self.world.gen_config.seed, self.world.gen_config, cx, cz);
        try self.world.applyEditLog(cx, cz, b);
        gop.value_ptr.* = b;
        return b;
    }

    pub fn lightOf(self: *Recompute, cx: i32, cz: i32) !*stages.ChunkLight {
        if (self.lights.get(.{ .cx = cx, .cz = cz })) |l| return l;
        var window: stages.Window = undefined;
        for (0..stages.SLOTS) |s| {
            const dcx, const dcz = stages.offsetOf(s);
            window[s] = try self.blocksOf(cx + dcx, cz + dcz);
        }
        const l = try self.a.create(stages.ChunkLight);
        l.* = try stages.light(self.a, &window);
        try self.lights.put(self.a, .{ .cx = cx, .cz = cz }, l);
        return l;
    }

    pub fn mesh(self: *Recompute, cx: i32, cz: i32, ao: stages.AOStrategy, lighting: stages.LightingMode) !stages.MeshResult {
        var hood: stages.Neighbourhood = undefined;
        for (0..stages.SLOTS) |s| {
            const dcx, const dcz = stages.offsetOf(s);
            hood[s] = .{ .blocks = try self.blocksOf(cx + dcx, cz + dcz), .light = try self.lightOf(cx + dcx, cz + dcz) };
        }
        return stages.mesh(self.a, &hood, ao, lighting);
    }
};

/// Each current light and mesh of the World must be the recomputed light
/// (by hash) and mesh. The blocks that main has must be the recomputed
/// blocks. Returns the number of meshes that it checked.
pub fn expectMatchesRecompute(a: std.mem.Allocator, sched: *const Scheduler, world: *const World) !usize {
    var rc = Recompute.init(a, world);
    defer rc.deinit();
    var meshes: usize = 0;
    var it = world.chunks.valueIterator();
    while (it.next()) |lc_ptr| {
        const lc = lc_ptr.*;
        try std.testing.expectEqual(world.editVersion(lc.cx, lc.cz), lc.block_ver);
        if (lc.has_blocks) {
            const want = try rc.blocksOf(lc.cx, lc.cz);
            for (0..chunk_mod.BLOCKS_PER_CHUNK) |i| try std.testing.expectEqual(want.get(i), lc.chunk.blocks.get(i));
        }
        if (Scheduler.lightCurrent(world, lc)) {
            try std.testing.expectEqual(protocol.lightHash(try rc.lightOf(lc.cx, lc.cz)), lc.light_hash);
        }
        if (!sched.meshCurrent(world, lc)) continue;
        var want = try rc.mesh(lc.cx, lc.cz, sched.ao, sched.lighting);
        defer want.deinit(a);
        // Main keeps the counts and the hash of the quads (C5).
        try std.testing.expectEqual(@as(u32, @intCast(want.quads.len)), lc.mesh.quad_count);
        try std.testing.expectEqual(protocol.meshHash(std.mem.sliceAsBytes(want.quads)), lc.mesh.hash);
        try std.testing.expectEqual(want.y_min, lc.mesh.y_min);
        try std.testing.expectEqual(want.y_max, lc.mesh.y_max);
        // With no upload, the quad bytes still wait. They are the quads.
        if (lc.upload != null) {
            const got = try uploadQuads(a, lc);
            defer a.free(got);
            try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(want.quads), std.mem.sliceAsBytes(got));
        }
        meshes += 1;
    }
    try std.testing.expect(meshes > 0);
    return meshes;
}

/// A copy of the quad bytes that wait for the upload of `lc`. The caller
/// frees it. Tests only: main does not copy the quads (C5).
pub fn uploadQuads(a: std.mem.Allocator, lc: *const world_mod.LoadedChunk) ![]stages.PackedQuad {
    const bytes = lc.upload orelse return error.NoUpload;
    const out = try a.alloc(stages.PackedQuad, bytes.quadBytesLen() / @sizeOf(stages.PackedQuad));
    bytes.copyQuads(out);
    return out;
}
