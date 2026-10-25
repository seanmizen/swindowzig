//! Tests of the chunk stages in pipeline/stages.zig (C2, C3, P3).
//!
//! The root of this test is here, next to world.zig, because a module can
//! import only files under the directory of its root. The tests compare the
//! stages with World, so they import world.zig.
//!
//!   equivalence    generate, light and mesh give the blocks, the light and
//!                  the quads of World for seed 0.
//!   install order  a shuffled arrival order gives the same light and quads.
//!   edits          random edits while jobs run, with versions (C3), give
//!                  the same result as a recompute from scratch.
//!   pure           a stage gives the same bytes from an allocator that
//!                  fills each allocation with junk.
const std = @import("std");
const stages = @import("pipeline/stages.zig");
const world_mod = @import("world.zig");
const chunk_mod = @import("chunk.zig");
const world_gen = @import("world_gen.zig");
const mesher_mod = @import("mesher.zig");

const PalettedBlocks = chunk_mod.PalettedBlocks;
const LightGrid = chunk_mod.LightGrid;
const BlockType = chunk_mod.BlockType;
const CHUNK_W = chunk_mod.CHUNK_W;
const CHUNK_H = chunk_mod.CHUNK_H;
const BLOCKS_PER_CHUNK = chunk_mod.BLOCKS_PER_CHUNK;
const Version = stages.Version;

const config = world_gen.presetConfig(.hilly);
const SEED: u64 = 0;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// A square of chunks -half..half on each axis, with the blocks of each
/// chunk from `stages.generate`.
const Region = struct {
    allocator: std.mem.Allocator,
    half: i32,
    blocks: []PalettedBlocks,

    fn side(self: *const Region) usize {
        return @intCast(2 * self.half + 1);
    }

    fn at(self: *const Region, cx: i32, cz: i32) usize {
        std.debug.assert(@abs(cx) <= self.half and @abs(cz) <= self.half);
        return @as(usize, @intCast(cx + self.half)) * self.side() + @as(usize, @intCast(cz + self.half));
    }

    fn coordOf(self: *const Region, i: usize) struct { i32, i32 } {
        return .{ @as(i32, @intCast(i / self.side())) - self.half, @as(i32, @intCast(i % self.side())) - self.half };
    }

    fn init(a: std.mem.Allocator, half: i32) !Region {
        return initSeed(a, half, SEED);
    }

    fn initSeed(a: std.mem.Allocator, half: i32, seed: u64) !Region {
        const n: usize = @intCast((2 * half + 1) * (2 * half + 1));
        var r: Region = .{ .allocator = a, .half = half, .blocks = try a.alloc(PalettedBlocks, n) };
        for (r.blocks, 0..) |*b, i| {
            const cx, const cz = r.coordOf(i);
            b.* = try stages.generate(a, seed, config, cx, cz);
        }
        return r;
    }

    fn deinit(self: *Region) void {
        for (self.blocks) |*b| b.deinit(self.allocator);
        self.allocator.free(self.blocks);
    }

    fn window(self: *const Region, cx: i32, cz: i32) stages.Window {
        var w: stages.Window = undefined;
        for (0..stages.SLOTS) |s| {
            const dcx, const dcz = stages.offsetOf(s);
            w[s] = &self.blocks[self.at(cx + dcx, cz + dcz)];
        }
        return w;
    }

    /// Set the block at world (wx, wy, wz).
    fn setBlock(self: *Region, wx: i32, wy: i32, wz: i32, b: BlockType) !void {
        const cx = @divFloor(wx, CHUNK_W);
        const cz = @divFloor(wz, CHUNK_W);
        const idx = chunk_mod.blockLinearIdx(wx - cx * CHUNK_W, wy, wz - cz * CHUNK_W);
        try self.blocks[self.at(cx, cz)].set(self.allocator, idx, b);
    }
};

/// The light of every chunk with |cx|, |cz| <= reach in a Region.
const Lights = struct {
    allocator: std.mem.Allocator,
    region: *const Region,
    reach: i32,
    light: []?stages.ChunkLight,

    fn init(a: std.mem.Allocator, region: *const Region, reach: i32) !Lights {
        const light = try a.alloc(?stages.ChunkLight, region.blocks.len);
        @memset(light, null);
        return .{ .allocator = a, .region = region, .reach = reach, .light = light };
    }

    fn computeAll(self: *Lights) !void {
        var cx: i32 = -self.reach;
        while (cx <= self.reach) : (cx += 1) {
            var cz: i32 = -self.reach;
            while (cz <= self.reach) : (cz += 1) try self.compute(cx, cz);
        }
    }

    fn compute(self: *Lights, cx: i32, cz: i32) !void {
        const i = self.region.at(cx, cz);
        if (self.light[i]) |*l| l.deinit(self.allocator);
        const w = self.region.window(cx, cz);
        self.light[i] = try stages.light(self.allocator, &w);
    }

    fn data(self: *const Lights, cx: i32, cz: i32) stages.ChunkData {
        const i = self.region.at(cx, cz);
        return .{ .blocks = &self.region.blocks[i], .light = &self.light[i].? };
    }

    fn mesh(self: *const Lights, a: std.mem.Allocator, cx: i32, cz: i32, ao: stages.AOStrategy, lighting: stages.LightingMode) !stages.MeshResult {
        var hood: stages.Neighbourhood = undefined;
        for (0..stages.SLOTS) |s| {
            const dcx, const dcz = stages.offsetOf(s);
            hood[s] = self.data(cx + dcx, cz + dcz);
        }
        return stages.mesh(a, &hood, ao, lighting);
    }

    fn deinit(self: *Lights) void {
        for (self.light) |*l| {
            if (l.*) |*x| x.deinit(self.allocator);
        }
        self.allocator.free(self.light);
    }
};

/// The number of cells where two light grids differ.
fn lightDiff(a: *const LightGrid, b: *const LightGrid) usize {
    var n: usize = 0;
    for (0..CHUNK_W) |x| for (0..CHUNK_H) |y| for (0..CHUNK_W) |z| {
        if (a.get(x, y, z) != b.get(x, y, z)) n += 1;
    };
    return n;
}

fn expectSameLight(a: *const stages.ChunkLight, b: *const stages.ChunkLight) !void {
    try std.testing.expectEqual(@as(usize, 0), lightDiff(&a.sky, &b.sky));
    try std.testing.expectEqual(@as(usize, 0), lightDiff(&a.block, &b.block));
}

fn expectSameMesh(a: *const stages.MeshResult, b: *const stages.MeshResult) !void {
    try std.testing.expectEqual(a.quads.len, b.quads.len);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(a.quads), std.mem.sliceAsBytes(b.quads));
    try std.testing.expectEqual(a.y_min, b.y_min);
    try std.testing.expectEqual(a.y_max, b.y_max);
}

/// Load the chunks with |cx|, |cz| <= half into `world`, in `order` (indices
/// into the square, row-major by cx then cz).
fn loadWorld(world: *world_mod.World, half: i32, order: []const usize) !void {
    const side: usize = @intCast(2 * half + 1);
    for (order) |i| {
        const cx = @as(i32, @intCast(i / side)) - half;
        const cz = @as(i32, @intCast(i % side)) - half;
        _ = try world.generateChunk(cx, cz);
    }
}

fn identityOrder(a: std.mem.Allocator, n: usize) ![]usize {
    const order = try a.alloc(usize, n);
    for (order, 0..) |*o, i| o.* = i;
    return order;
}

/// An allocator that fills each new allocation with a different junk byte.
/// A stage that reads memory it did not write gives different results from
/// one call to the next.
const JunkAllocator = struct {
    child: std.mem.Allocator,
    junk: u8,

    fn allocator(self: *JunkAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *JunkAllocator = @ptrCast(@alignCast(ctx));
        const p = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.junk +%= 0x5b;
        @memset(p[0..len], self.junk);
        return p;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *JunkAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *JunkAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

// ---------------------------------------------------------------------------
// Equivalence
// ---------------------------------------------------------------------------

test "stages: generate gives the blocks of World.generateChunk for seed 0" {
    const a = std.testing.allocator;
    var world = try world_mod.World.init(a, .hilly, 4);
    defer world.deinit();
    var cx: i32 = -2;
    while (cx <= 2) : (cx += 1) {
        var cz: i32 = -2;
        while (cz <= 2) : (cz += 1) {
            _ = try world.generateChunk(cx, cz);
            var b = try stages.generate(a, SEED, world.gen_config, cx, cz);
            defer b.deinit(a);
            const want = &world.chunks.get(.{ .cx = cx, .cz = cz }).?.chunk.blocks;
            for (0..BLOCKS_PER_CHUNK) |i| try std.testing.expectEqual(want.get(i), b.get(i));
        }
    }
}

/// The number of cells where the light of the inner 3×3 chunks of a 5×5
/// World, loaded in `order`, differs from `lights`.
fn worldLightDiff(world: *const world_mod.World, region: *const Region, lights: *const Lights) struct { sky: usize, block: usize } {
    var sky: usize = 0;
    var block: usize = 0;
    var cx: i32 = -(region.half - 1);
    while (cx <= region.half - 1) : (cx += 1) {
        var cz: i32 = -(region.half - 1);
        while (cz <= region.half - 1) : (cz += 1) {
            const want = &world.chunks.get(.{ .cx = cx, .cz = cz }).?.chunk;
            const got = &lights.light[region.at(cx, cz)].?;
            const sd = lightDiff(&want.skylight, &got.sky);
            const bd = lightDiff(&want.block_light, &got.block);
            if (sd != 0 or bd != 0) {
                std.debug.print("chunk ({d},{d}): skylight differs in {d} cells, block light in {d}\n", .{ cx, cz, sd, bd });
            }
            sky += sd;
            block += bd;
        }
    }
    return .{ .sky = sky, .block = block };
}

/// The light test for one seed. Returns two cell counts (skylight, block
/// light). A counted cell has light that crosses a border: the chunk on
/// its own gives other light there.
fn checkLightAgainstWorld(a: std.mem.Allocator, seed: u64) !struct { usize, usize } {
    // A 5×5 World: each of the inner 3×3 chunks has its 3×3 neighbourhood.
    // Three load orders: row by row, spiral from the middle, and shuffled.
    const half: i32 = 2;
    var region = try Region.initSeed(a, half, seed);
    defer region.deinit();
    var lights = try Lights.init(a, &region, half - 1);
    defer lights.deinit();
    try lights.computeAll();

    const n = region.blocks.len;
    const row = try identityOrder(a, n);
    defer a.free(row);
    const spiral = try identityOrder(a, n);
    defer a.free(spiral);
    std.mem.sort(usize, spiral, &region, struct {
        fn lt(r: *const Region, x: usize, y: usize) bool {
            const ax, const az = r.coordOf(x);
            const bx, const bz = r.coordOf(y);
            return ax * ax + az * az < bx * bx + bz * bz;
        }
    }.lt);
    const shuffled = try identityOrder(a, n);
    defer a.free(shuffled);
    var prng = std.Random.DefaultPrng.init(0x11647 +% seed);
    prng.random().shuffle(usize, shuffled);

    for ([_][]const usize{ row, spiral, shuffled }) |order| {
        var world = try world_mod.World.init(a, .hilly, 4);
        defer world.deinit();
        world.gen_config.seed = seed;
        try loadWorld(&world, half, order);
        const d = worldLightDiff(&world, &region, &lights);
        try std.testing.expectEqual(@as(usize, 0), d.sky);
        try std.testing.expectEqual(@as(usize, 0), d.block);
    }

    // The light that crosses a border: the chunk alone gives other light.
    var sky_cross: usize = 0;
    var block_cross: usize = 0;
    var cx: i32 = -(half - 1);
    while (cx <= half - 1) : (cx += 1) {
        var cz: i32 = -(half - 1);
        while (cz <= half - 1) : (cz += 1) {
            var cfg = config;
            cfg.seed = seed;
            var own = chunk_mod.Chunk.init(a);
            defer own.deinit();
            try own.generateTerrain(cx, cz, cfg);
            const got = &lights.light[region.at(cx, cz)].?;
            sky_cross += lightDiff(&own.skylight, &got.sky);
            block_cross += lightDiff(&own.block_light, &got.block);
        }
    }
    return .{ sky_cross, block_cross };
}

test "stages: light gives the light of World after the 3x3 neighbours load" {
    // Seed 0 is the terrain of today. In its 5×5 area, only block light
    // crosses a border. Seed 3 has caves open to the sky at the borders,
    // so skylight crosses a border too.
    const a = std.testing.allocator;
    const s0 = try checkLightAgainstWorld(a, 0);
    try std.testing.expect(s0[1] > 0);
    const s3 = try checkLightAgainstWorld(a, 3);
    try std.testing.expect(s3[0] > 0);
}

test "stages: light gives the light of World.setBlock after edits" {
    // World relights the edited chunk and spreads the change to its
    // neighbours. The window light of the edited blocks must be the same.
    const a = std.testing.allocator;
    const half: i32 = 2;
    var region = try Region.init(a, half);
    defer region.deinit();
    var world = try world_mod.World.init(a, .hilly, 4);
    defer world.deinit();
    const order = try identityOrder(a, region.blocks.len);
    defer a.free(order);
    try loadWorld(&world, half, order);
    var prng = std.Random.DefaultPrng.init(0x5e7b1);
    const r = prng.random();
    for (0..24) |_| {
        var e = randomEdit(r);
        // Keep the edits in the inner 3×3 chunks, and away from the border
        // of the 5×5 area, where World has no neighbour to relight.
        e.wx = std.math.clamp(e.wx, -CHUNK_W, 2 * CHUNK_W - 1);
        e.wz = std.math.clamp(e.wz, -CHUNK_W, 2 * CHUNK_W - 1);
        _ = try world.setBlock(e.wx, e.wy, e.wz, e.block);
        try region.setBlock(e.wx, e.wy, e.wz, e.block);
    }
    // Glowstone high in the open sky, next to a border: the light stage
    // computes the rows up to 15 cells above the highest emitter.
    const sky_edits = [_]Edit{
        .{ .wx = 15, .wy = 200, .wz = 3, .block = .glowstone },
        .{ .wx = -1, .wy = 240, .wz = 16, .block = .glowstone },
        .{ .wx = 0, .wy = 241, .wz = 16, .block = .stone },
    };
    for (sky_edits) |e| {
        _ = try world.setBlock(e.wx, e.wy, e.wz, e.block);
        try region.setBlock(e.wx, e.wy, e.wz, e.block);
    }
    var lights = try Lights.init(a, &region, half - 1);
    defer lights.deinit();
    try lights.computeAll();
    const d = worldLightDiff(&world, &region, &lights);
    try std.testing.expectEqual(@as(usize, 0), d.sky);
    try std.testing.expectEqual(@as(usize, 0), d.block);
}

test "stages: mesh gives the quads of the greedy mesher through the World getter" {
    // A 7×7 World: the inner 5×5 chunks have their final light, so the
    // inner 3×3 chunks read final light across each border.
    const a = std.testing.allocator;
    const half: i32 = 3;
    var world = try world_mod.World.init(a, .hilly, 4);
    defer world.deinit();
    const n: usize = @intCast((2 * half + 1) * (2 * half + 1));
    const order = try identityOrder(a, n);
    defer a.free(order);
    try loadWorld(&world, half, order);

    var region = try Region.init(a, half);
    defer region.deinit();
    var lights = try Lights.init(a, &region, half - 1);
    defer lights.deinit();
    try lights.computeAll();

    const modes = [_]struct { stages.AOStrategy, stages.LightingMode }{
        .{ .moore, .skylight },
        .{ .classic, .skylight },
        // Propagated AO reads 3 cells across the border: all of BORDER.
        .{ .propagated, .skylight },
        .{ .none, .none },
    };
    for (modes) |mode| {
        var cx: i32 = -(half - 2);
        while (cx <= half - 2) : (cx += 1) {
            var cz: i32 = -(half - 2);
            while (cz <= half - 2) : (cz += 1) {
                const lc = world.chunks.get(.{ .cx = cx, .cz = cz }).?;
                var want_mesh = mesher_mod.Mesh.init(a);
                defer want_mesh.deinit();
                try mesher_mod.generateMesh(&lc.chunk, &want_mesh, lc.worldX(), lc.worldZ(), world.asBlockGetter(), mode[0], mode[1]);
                var got = try lights.mesh(a, cx, cz, mode[0], mode[1]);
                defer got.deinit(a);
                const want: stages.MeshResult = .{ .quads = want_mesh.quads.items, .y_min = want_mesh.y_min, .y_max = want_mesh.y_max };
                try expectSameMesh(&want, &got);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Install order
// ---------------------------------------------------------------------------

/// Chunks arrive one at a time in `order`. When the 3×3 neighbourhood of a
/// chunk is complete, its light runs. When the 3×3 lights of a chunk are
/// complete, its mesh runs. This is what a scheduler does with results
/// that arrive in any order.
const Arrivals = struct {
    region: *const Region,
    lights: Lights,
    arrived: []bool,
    meshes: []?stages.MeshResult,

    fn run(a: std.mem.Allocator, region: *const Region, order: []const usize) !Arrivals {
        var self: Arrivals = .{
            .region = region,
            .lights = try Lights.init(a, region, region.half - 1),
            .arrived = try a.alloc(bool, region.blocks.len),
            .meshes = try a.alloc(?stages.MeshResult, region.blocks.len),
        };
        @memset(self.arrived, false);
        @memset(self.meshes, null);
        const h = region.half;
        for (order) |i| {
            self.arrived[i] = true;
            const cx, const cz = region.coordOf(i);
            // The light of each chunk next to the new one can be ready now.
            for (0..stages.SLOTS) |s| {
                const dcx, const dcz = stages.offsetOf(s);
                const lx = cx + dcx;
                const lz = cz + dcz;
                if (@abs(lx) > h - 1 or @abs(lz) > h - 1) continue;
                if (self.lights.light[region.at(lx, lz)] != null) continue;
                if (!self.allAround(lx, lz, .arrived)) continue;
                try self.lights.compute(lx, lz);
                // The mesh of each chunk next to the new light can be ready now.
                for (0..stages.SLOTS) |t| {
                    const ex, const ez = stages.offsetOf(t);
                    const mx = lx + ex;
                    const mz = lz + ez;
                    if (@abs(mx) > h - 2 or @abs(mz) > h - 2) continue;
                    if (self.meshes[region.at(mx, mz)] != null) continue;
                    if (!self.allAround(mx, mz, .lit)) continue;
                    self.meshes[region.at(mx, mz)] = try self.lights.mesh(a, mx, mz, .moore, .skylight);
                }
            }
        }
        return self;
    }

    fn allAround(self: *const Arrivals, cx: i32, cz: i32, what: enum { arrived, lit }) bool {
        for (0..stages.SLOTS) |s| {
            const dcx, const dcz = stages.offsetOf(s);
            const i = self.region.at(cx + dcx, cz + dcz);
            const ok = switch (what) {
                .arrived => self.arrived[i],
                .lit => self.lights.light[i] != null,
            };
            if (!ok) return false;
        }
        return true;
    }

    fn deinit(self: *Arrivals, a: std.mem.Allocator) void {
        self.lights.deinit();
        a.free(self.arrived);
        for (self.meshes) |*m| {
            if (m.*) |*x| x.deinit(a);
        }
        a.free(self.meshes);
    }
};

test "stages: a shuffled install order gives the same light and quads" {
    const a = std.testing.allocator;
    var region = try Region.init(a, 3);
    defer region.deinit();
    const order = try identityOrder(a, region.blocks.len);
    defer a.free(order);
    var reference = try Arrivals.run(a, &region, order);
    defer reference.deinit(a);

    var prng = std.Random.DefaultPrng.init(0x0bde5);
    for (0..3) |_| {
        prng.random().shuffle(usize, order);
        var got = try Arrivals.run(a, &region, order);
        defer got.deinit(a);
        for (reference.lights.light, got.lights.light) |*want, *have| {
            try std.testing.expectEqual(want.* == null, have.* == null);
            if (want.*) |*w| try expectSameLight(w, &have.*.?);
        }
        var meshes: usize = 0;
        for (reference.meshes, got.meshes) |*want, *have| {
            try std.testing.expectEqual(want.* == null, have.* == null);
            if (want.*) |*w| {
                try expectSameMesh(w, &have.*.?);
                meshes += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 9), meshes);
    }
}

// ---------------------------------------------------------------------------
// Edits and versions (C3)
// ---------------------------------------------------------------------------

const Edit = struct { wx: i32, wy: i32, wz: i32, block: BlockType };

/// The installed state of a region, with versions. Jobs read the state when
/// they start and install their result later, so edits can happen while a
/// job runs. A result installs only when its input versions are current.
const Store = struct {
    a: std.mem.Allocator,
    region: Region,
    /// Lights for |cx|, |cz| <= LIGHT_REACH, meshes for <= LIGHT_REACH - 1.
    lights: Lights,
    meshes: []?stages.MeshResult,
    block_ver: []Version,
    light_ver: []Version,
    light_inputs: []stages.Inputs,
    mesh_inputs: []stages.Inputs,

    const HALF: i32 = 3;
    const LIGHT_REACH: i32 = HALF - 1;
    const MESH_REACH: i32 = HALF - 2;

    const Job = struct {
        inputs: stages.Inputs,
        result: union(enum) { light: stages.ChunkLight, mesh: stages.MeshResult },

        fn deinit(self: *Job, a: std.mem.Allocator) void {
            switch (self.result) {
                .light => |*l| l.deinit(a),
                .mesh => |*m| m.deinit(a),
            }
        }
    };

    fn init(a: std.mem.Allocator) !*Store {
        const self = try a.create(Store);
        self.a = a;
        self.region = try Region.init(a, HALF);
        const n = self.region.blocks.len;
        self.lights = try Lights.init(a, &self.region, LIGHT_REACH);
        self.meshes = try a.alloc(?stages.MeshResult, n);
        @memset(self.meshes, null);
        self.block_ver = try a.alloc(Version, n);
        @memset(self.block_ver, 0);
        self.light_ver = try a.alloc(Version, n);
        @memset(self.light_ver, 0);
        self.light_inputs = try a.alloc(stages.Inputs, n);
        self.mesh_inputs = try a.alloc(stages.Inputs, n);
        return self;
    }

    fn deinit(self: *Store) void {
        const a = self.a;
        for (self.meshes) |*m| {
            if (m.*) |*x| x.deinit(a);
        }
        a.free(self.meshes);
        self.lights.deinit();
        self.region.deinit();
        a.free(self.block_ver);
        a.free(self.light_ver);
        a.free(self.light_inputs);
        a.free(self.mesh_inputs);
        a.destroy(self);
    }

    fn current(self: *const Store, stage: stages.Stage, cx: i32, cz: i32) stages.Inputs {
        var in: stages.Inputs = .{ .stage = stage, .cx = cx, .cz = cz };
        for (0..stages.SLOTS) |s| {
            const dcx, const dcz = stages.offsetOf(s);
            const i = self.region.at(cx + dcx, cz + dcz);
            in.blocks[s] = self.block_ver[i];
            if (stage == .mesh) in.light[s] = self.light_ver[i];
        }
        return in;
    }

    fn lightStale(self: *const Store, cx: i32, cz: i32) bool {
        const i = self.region.at(cx, cz);
        if (self.lights.light[i] == null) return true;
        return !self.light_inputs[i].isCurrent(self.current(.light, cx, cz));
    }

    /// A mesh can start when the 3×3 lights exist and are current.
    fn meshReady(self: *const Store, cx: i32, cz: i32) bool {
        for (0..stages.SLOTS) |s| {
            const dcx, const dcz = stages.offsetOf(s);
            if (self.lightStale(cx + dcx, cz + dcz)) return false;
        }
        return true;
    }

    fn meshStale(self: *const Store, cx: i32, cz: i32) bool {
        const i = self.region.at(cx, cz);
        if (self.meshes[i] == null) return true;
        return !self.mesh_inputs[i].isCurrent(self.current(.mesh, cx, cz));
    }

    fn edit(self: *Store, e: Edit) !void {
        try self.region.setBlock(e.wx, e.wy, e.wz, e.block);
        self.block_ver[self.region.at(@divFloor(e.wx, CHUNK_W), @divFloor(e.wz, CHUNK_W))] += 1;
    }

    /// Start a job: read the inputs now, as a worker gets a copy of them.
    fn start(self: *Store, stage: stages.Stage, cx: i32, cz: i32) !Job {
        const inputs = self.current(stage, cx, cz);
        return switch (stage) {
            .light => blk: {
                const w = self.region.window(cx, cz);
                break :blk .{ .inputs = inputs, .result = .{ .light = try stages.light(self.a, &w) } };
            },
            .mesh => .{ .inputs = inputs, .result = .{ .mesh = try self.lights.mesh(self.a, cx, cz, .moore, .skylight) } },
            .generate => unreachable,
        };
    }

    /// Install the result of `job` if its inputs are current, else discard
    /// it. Returns true when it installed.
    fn finish(self: *Store, job: *Job) bool {
        const cx = job.inputs.cx;
        const cz = job.inputs.cz;
        const i = self.region.at(cx, cz);
        if (!job.inputs.isCurrent(self.current(job.inputs.stage, cx, cz))) {
            job.deinit(self.a);
            return false;
        }
        switch (job.result) {
            .light => |l| {
                if (self.lights.light[i]) |*old| old.deinit(self.a);
                self.lights.light[i] = l;
                self.light_inputs[i] = job.inputs;
                self.light_ver[i] += 1;
            },
            .mesh => |m| {
                if (self.meshes[i]) |*old| old.deinit(self.a);
                self.meshes[i] = m;
                self.mesh_inputs[i] = job.inputs;
            },
        }
        return true;
    }

    /// The stale jobs that can start now.
    fn staleJobs(self: *const Store, out: *std.ArrayList(stages.Inputs)) !void {
        out.clearRetainingCapacity();
        var cx: i32 = -LIGHT_REACH;
        while (cx <= LIGHT_REACH) : (cx += 1) {
            var cz: i32 = -LIGHT_REACH;
            while (cz <= LIGHT_REACH) : (cz += 1) {
                if (self.lightStale(cx, cz)) try out.append(self.a, .{ .stage = .light, .cx = cx, .cz = cz });
                if (@abs(cx) <= MESH_REACH and @abs(cz) <= MESH_REACH and self.meshStale(cx, cz) and self.meshReady(cx, cz))
                    try out.append(self.a, .{ .stage = .mesh, .cx = cx, .cz = cz });
            }
        }
    }
};

fn randomEdit(r: std.Random) Edit {
    // Near the borders of the inner chunks, in the cave layer and at the
    // surface, so that light crosses borders.
    const near = [_]i32{ -18, -17, -16, -15, -14, -2, -1, 0, 1, 2, 14, 15, 16, 17, 18 };
    const blocks = [_]BlockType{ .air, .air, .air, .stone, .glowstone };
    return .{
        .wx = near[r.uintLessThan(usize, near.len)] + r.intRangeLessThan(i32, -1, 2),
        .wy = r.intRangeLessThan(i32, 30, 90),
        .wz = near[r.uintLessThan(usize, near.len)] + r.intRangeLessThan(i32, -1, 2),
        .block = blocks[r.uintLessThan(usize, blocks.len)],
    };
}

test "stages: random edits while jobs run give the result of a recompute from scratch" {
    const a = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xed175);
    const r = prng.random();

    const store = try Store.init(a);
    defer store.deinit();
    var log: std.ArrayList(Edit) = .empty;
    defer log.deinit(a);
    var in_flight: std.ArrayList(Store.Job) = .empty;
    defer {
        for (in_flight.items) |*j| j.deinit(a);
        in_flight.deinit(a);
    }
    var stale: std.ArrayList(stages.Inputs) = .empty;
    defer stale.deinit(a);

    // Phase 1: edits, job starts and job ends in a random order.
    var discarded: usize = 0;
    var installed: usize = 0;
    var steps: usize = 0;
    while (steps < 160) : (steps += 1) {
        switch (r.uintLessThan(u8, 10)) {
            0...2 => if (log.items.len < 40) {
                const e = randomEdit(r);
                try log.append(a, e);
                try store.edit(e);
            },
            3...6 => {
                try store.staleJobs(&stale);
                if (stale.items.len > 0 and in_flight.items.len < 6) {
                    const j = stale.items[r.uintLessThan(usize, stale.items.len)];
                    try in_flight.append(a, try store.start(j.stage, j.cx, j.cz));
                }
            },
            else => if (in_flight.items.len > 0) {
                var job = in_flight.swapRemove(r.uintLessThan(usize, in_flight.items.len));
                if (store.finish(&job)) installed += 1 else discarded += 1;
            },
        }
    }
    // Phase 2: no more edits. Run jobs until nothing is stale.
    while (true) {
        try store.staleJobs(&stale);
        if (stale.items.len == 0 and in_flight.items.len == 0) break;
        for (stale.items) |j| try in_flight.append(a, try store.start(j.stage, j.cx, j.cz));
        r.shuffle(Store.Job, in_flight.items);
        for (in_flight.items) |*job| {
            if (store.finish(job)) installed += 1 else discarded += 1;
        }
        in_flight.clearRetainingCapacity();
    }
    // The test must exercise both paths of the version check.
    try std.testing.expect(log.items.len >= 10);
    try std.testing.expect(discarded > 0);
    try std.testing.expect(installed > 0);

    // From scratch: generate, replay the edit log, light, mesh.
    var fresh = try Region.init(a, Store.HALF);
    defer fresh.deinit();
    for (log.items) |e| try fresh.setBlock(e.wx, e.wy, e.wz, e.block);
    for (fresh.blocks, store.region.blocks) |*want, *have| {
        for (0..BLOCKS_PER_CHUNK) |i| try std.testing.expectEqual(want.get(i), have.get(i));
    }
    var lights = try Lights.init(a, &fresh, Store.LIGHT_REACH);
    defer lights.deinit();
    try lights.computeAll();
    var cx: i32 = -Store.LIGHT_REACH;
    while (cx <= Store.LIGHT_REACH) : (cx += 1) {
        var cz: i32 = -Store.LIGHT_REACH;
        while (cz <= Store.LIGHT_REACH) : (cz += 1) {
            const i = fresh.at(cx, cz);
            try expectSameLight(&lights.light[i].?, &store.lights.light[i].?);
            if (@abs(cx) <= Store.MESH_REACH and @abs(cz) <= Store.MESH_REACH) {
                var want = try lights.mesh(a, cx, cz, .moore, .skylight);
                defer want.deinit(a);
                try expectSameMesh(&want, &store.meshes[i].?);
            }
        }
    }
}

test "stages: Inputs.isCurrent compares the versions that the stage reads" {
    var light: stages.Inputs = .{ .stage = .light, .cx = 1, .cz = 2 };
    var now = light;
    try std.testing.expect(light.isCurrent(now));
    // A light reads the blocks of all 9 chunks, and no light versions.
    now.light[0] = 7;
    try std.testing.expect(light.isCurrent(now));
    now.blocks[8] = 1;
    try std.testing.expect(!light.isCurrent(now));
    // A mesh reads the blocks and the light of all 9 chunks.
    light.stage = .mesh;
    var mesh_now = light;
    mesh_now.light[stages.CENTER] = 3;
    try std.testing.expect(!light.isCurrent(mesh_now));
}

// ---------------------------------------------------------------------------
// Pure
// ---------------------------------------------------------------------------

test "stages: the stages give the same bytes from an allocator full of junk" {
    var junk: JunkAllocator = .{ .child = std.testing.allocator, .junk = 0 };
    const j = junk.allocator();
    const a = std.testing.allocator;

    var region = try Region.init(a, 2);
    defer region.deinit();
    var b = try stages.generate(j, SEED, config, 1, -1);
    defer b.deinit(j);
    for (0..BLOCKS_PER_CHUNK) |i| try std.testing.expectEqual(region.blocks[region.at(1, -1)].get(i), b.get(i));

    var lights = try Lights.init(a, &region, 1);
    defer lights.deinit();
    try lights.computeAll();
    var junk_lights = try Lights.init(j, &region, 1);
    defer junk_lights.deinit();
    // Two times, so that the second call gets other junk.
    try junk_lights.computeAll();
    try junk_lights.computeAll();
    for (lights.light, junk_lights.light) |*want, *have| {
        if (want.*) |*w| try expectSameLight(w, &have.*.?);
    }
    // One scratch for several windows, first full of junk: each result is
    // the result of a fresh call.
    const scratch = try a.create(stages.LightScratch);
    defer a.destroy(scratch);
    @memset(std.mem.asBytes(scratch), 0xA5);
    for ([_][2]i32{ .{ 0, 0 }, .{ 1, -1 }, .{ 0, 0 }, .{ -1, 1 } }) |c| {
        const w = region.window(c[0], c[1]);
        var l = try stages.lightScratch(a, &w, scratch);
        defer l.deinit(a);
        try expectSameLight(&lights.light[region.at(c[0], c[1])].?, &l);
    }

    var want = try lights.mesh(a, 0, 0, .moore, .skylight);
    defer want.deinit(a);
    for (0..2) |_| {
        var got = try junk_lights.mesh(j, 0, 0, .moore, .skylight);
        defer got.deinit(j);
        try expectSameMesh(&want, &got);
    }
}

test "stages: the slot helpers agree" {
    for (0..stages.SLOTS) |s| {
        const dcx, const dcz = stages.offsetOf(s);
        try std.testing.expectEqual(s, stages.slot(dcx, dcz));
    }
    try std.testing.expectEqual(stages.CENTER, stages.slot(0, 0));
    try std.testing.expectEqual(@as(usize, 44), stages.WINDOW_W);
}
