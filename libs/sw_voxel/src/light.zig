//! The light rules of sw_voxel, and the incremental light update
//! (REQ-VOXEL-003, REQ-VOXEL-004, REQ-VOXEL-005).
//!
//! Each cell has two light channels, 0 to 15:
//!
//! - Sky light. A cell is a sky source, at 15, when no cell at or above it
//!   in its column has an opacity more than 0. So sky light goes straight
//!   down with no loss until it gets to a cell that stops some light.
//! - Block light. A cell has at least the emission of its block.
//!
//! Light at level L in a cell goes into each of the 6 face neighbours at
//! L - max(1, opacity of the neighbour). The light of a cell is the largest
//! of its source value and the values that its neighbours give. So light
//! loses 1 level for each step through air, and a cell with opacity 15
//! gets no light from its neighbours. Light does not go above or below the
//! world.
//!
//! The content gives the opacity and the emission of each block ID
//! (`content.opacity`, `content.emission`). This file makes tables of them
//! at comptime.
//!
//! `update` changes the light of a store after block edits. It does not
//! light the store again from the start. It removes the light that can
//! come from the edited cells, then fills the removed cells again from
//! their sources and from the light around them. The result is the same
//! as a full recompute (a test checks this).
const std = @import("std");
const content = @import("content.zig");
const chunk_mod = @import("chunk.zig");

const Block = content.Block;
const block_values = @typeInfo(Block).@"enum".field_values;

/// The largest light level of a channel.
pub const MAX_LIGHT: u8 = 15;

/// The number of cells in a column.
const H: i32 = @intCast(content.height);

/// A light channel.
pub const Channel = enum { sky, block };

/// The light of one cell. The mesher reads the light of each cell with
/// `Chunk.lightAt` or `BlockGetter.lightAt`.
pub const CellLight = struct {
    /// Sky light, 0 to 15.
    sky: u8 = 0,
    /// Block light, 0 to 15.
    block: u8 = 0,
};

/// The opacity of each block ID, 0 to 15 (`content.opacity`).
pub const opacity_table: [256]u8 = blk: {
    @setEvalBranchQuota(100_000);
    var t: [256]u8 = @splat(MAX_LIGHT);
    for (block_values) |v| t[v] = content.opacity(@fromBackingInt(v));
    break :blk t;
};

/// The emission of each block ID, 0 to 15 (`content.emission`).
pub const emission_table: [256]u8 = blk: {
    @setEvalBranchQuota(100_000);
    var t: [256]u8 = @splat(0);
    for (block_values) |v| t[v] = content.emission(@fromBackingInt(v));
    break :blk t;
};

/// The light that a cell of `b` stops, 0 to 15.
pub inline fn opacity(b: Block) u8 {
    return opacity_table[@backingInt(b)];
}

/// The block light that `b` gives, 0 to 15.
pub inline fn emission(b: Block) u8 {
    return emission_table[@backingInt(b)];
}

/// The levels that light loses when it goes into a cell of `b`:
/// max(1, opacity). 15 or more stops all light.
pub inline fn loss(b: Block) u8 {
    return @max(1, opacity(b));
}

/// True when a cell of `b` stops sky light from going straight down with
/// no loss: its opacity is more than 0.
pub fn stopsSky(b: Block) bool {
    return opacity(b) != 0;
}

/// True when each channel spreads in order of level. That is so when each
/// opacity is 0 or 15 and each emission more than 0 has the same level.
/// Then a breadth-first queue sets each cell one time, at its last value.
/// If not, a cell can get brighter after it leaves the queue, and the fill
/// must put the cell in the queue again.
pub const ordered: bool = blk: {
    @setEvalBranchQuota(100_000);
    var level: u8 = 0;
    for (block_values) |v| {
        const o = opacity_table[v];
        if (o != 0 and o != MAX_LIGHT) break :blk false;
        const e = emission_table[v];
        if (e == 0) continue;
        if (level != 0 and e != level) break :blk false;
        level = e;
    }
    break :blk true;
};

// ---------------------------------------------------------------------------
// Incremental update
// ---------------------------------------------------------------------------

/// A cell. y is local: 0 is the lowest cell of the column (`content.min_y`).
/// x and z are in the coordinates of the store.
pub const Pos = struct { x: i32, y: i32, z: i32 };

/// The 6 face neighbours. Index 0 is down: sky light goes down with no loss.
const dirs = [6][3]i32{ .{ 0, -1, 0 }, .{ 0, 1, 0 }, .{ -1, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 0, -1 }, .{ 0, 0, 1 } };
const DOWN = 0;

/// Update the light of a store after the blocks at `edits` changed. The
/// light of the store must be the light of its old blocks. After the call,
/// it is the light of its new blocks.
///
/// `access` is a pointer to a store with these functions (y is local):
///
///   fn block(self, x: i32, y: i32, z: i32) ?Block
///       The block of the cell, or null when the cell is not in the store.
///       Light does not go into a cell that is not in the store.
///   fn get(self, ch: Channel, x: i32, y: i32, z: i32) u8
///       The light of a cell in the store.
///   fn set(self, ch: Channel, x: i32, y: i32, z: i32, value: u8) !void
///       Set the light of a cell in the store.
///
/// A change of light goes at most 14 cells to the side from an edit, and
/// the update reads at most 15 cells to the side. Thus a store that holds
/// the 3 × 3 chunks around the chunk of the edits is sufficient.
pub fn update(allocator: std.mem.Allocator, access: anytype, edits: []const Pos) !void {
    var r: Relight(@TypeOf(access)) = .{ .a = allocator, .access = access };
    defer r.deinit();
    try r.channel(.block, edits);

    // Sky: the edited cells, and each cell of an edited column whose source
    // state can be different now. Those are the cells at or above the new
    // lowest source that are not at 15, and the old sources below it.
    var seeds: std.ArrayList(Pos) = .empty;
    defer seeds.deinit(allocator);
    try seeds.appendSlice(allocator, edits);
    for (edits, 0..) |e, i| {
        const seen = for (edits[0..i]) |o| {
            if (o.x == e.x and o.z == e.z) break true;
        } else false;
        if (seen) continue;
        const low = try r.lowestSource(e.x, e.z);
        var y = low;
        while (y < H) : (y += 1) {
            if (access.get(.sky, e.x, y, e.z) != MAX_LIGHT) try seeds.append(allocator, .{ .x = e.x, .y = y, .z = e.z });
        }
        y = low - 1;
        while (y >= 0 and access.get(.sky, e.x, y, e.z) == MAX_LIGHT) : (y -= 1) {
            try seeds.append(allocator, .{ .x = e.x, .y = y, .z = e.z });
        }
    }
    try r.channel(.sky, seeds.items);
}

fn Relight(comptime Access: type) type {
    return struct {
        const Self = @This();
        const Dec = struct { p: Pos, from: u8 };

        a: std.mem.Allocator,
        access: Access,
        dec: std.ArrayList(Dec) = .empty,
        cleared: std.ArrayList(Pos) = .empty,
        inc: std.ArrayList(Pos) = .empty,
        /// The lowest sky source of each column that the update read.
        sources: std.AutoHashMapUnmanaged([2]i32, i32) = .empty,

        fn deinit(self: *Self) void {
            self.dec.deinit(self.a);
            self.cleared.deinit(self.a);
            self.inc.deinit(self.a);
            self.sources.deinit(self.a);
        }

        /// The lowest y of the sky sources of column (x, z): one above the
        /// highest cell that stops sky light, or 0. `H` when the column is
        /// not in the store.
        fn lowestSource(self: *Self, x: i32, z: i32) !i32 {
            const gop = try self.sources.getOrPut(self.a, .{ x, z });
            if (gop.found_existing) return gop.value_ptr.*;
            var y: i32 = H - 1;
            const low: i32 = while (y >= 0) : (y -= 1) {
                const b = self.access.block(x, y, z) orelse break H;
                if (stopsSky(b)) break y + 1;
            } else 0;
            gop.value_ptr.* = low;
            return low;
        }

        /// Remove the light that can come from `seeds`, then fill the
        /// removed cells again.
        fn channel(self: *Self, ch: Channel, seeds: []const Pos) !void {
            const acc = self.access;
            self.dec.clearRetainingCapacity();
            self.cleared.clearRetainingCapacity();
            self.inc.clearRetainingCapacity();

            // 1. Remove. A neighbour with less light than the cell that it
            // touches can have its light from that cell, so it goes too.
            // A neighbour with the same light or more is a border: its
            // light comes from somewhere else, and the fill starts there.
            for (seeds) |p| {
                if (acc.block(p.x, p.y, p.z) == null) continue;
                const old = acc.get(ch, p.x, p.y, p.z);
                if (old > 0) try acc.set(ch, p.x, p.y, p.z, 0);
                try self.cleared.append(self.a, p);
                try self.dec.append(self.a, .{ .p = p, .from = old });
            }
            var i: usize = 0;
            while (i < self.dec.items.len) : (i += 1) {
                const d = self.dec.items[i];
                for (dirs, 0..) |o, k| {
                    const q: Pos = .{ .x = d.p.x + o[0], .y = d.p.y + o[1], .z = d.p.z + o[2] };
                    if (q.y < 0 or q.y >= H) continue;
                    if (acc.block(q.x, q.y, q.z) == null) continue;
                    const l = acc.get(ch, q.x, q.y, q.z);
                    if (l == 0) continue;
                    // Sky light goes down with no loss, so a 15 under a
                    // removed 15 can have its light from it.
                    const below_source = ch == .sky and k == DOWN and l == MAX_LIGHT and d.from == MAX_LIGHT;
                    if (l < d.from or below_source) {
                        try acc.set(ch, q.x, q.y, q.z, 0);
                        try self.cleared.append(self.a, q);
                        try self.dec.append(self.a, .{ .p = q, .from = l });
                    } else {
                        try self.inc.append(self.a, q);
                    }
                }
            }

            // 2. The sources in the removed cells light again.
            for (self.cleared.items) |p| {
                const b = acc.block(p.x, p.y, p.z).?;
                const seed: u8 = switch (ch) {
                    .sky => if (p.y >= try self.lowestSource(p.x, p.z)) MAX_LIGHT else 0,
                    .block => emission(b),
                };
                if (seed > acc.get(ch, p.x, p.y, p.z)) {
                    try acc.set(ch, p.x, p.y, p.z, seed);
                    try self.inc.append(self.a, p);
                }
            }

            // 3. Fill from the sources and the border cells.
            i = 0;
            while (i < self.inc.items.len) : (i += 1) {
                const p = self.inc.items[i];
                const l = acc.get(ch, p.x, p.y, p.z);
                if (l <= 1) continue;
                for (dirs) |o| {
                    const q: Pos = .{ .x = p.x + o[0], .y = p.y + o[1], .z = p.z + o[2] };
                    if (q.y < 0 or q.y >= H) continue;
                    const b = acc.block(q.x, q.y, q.z) orelse continue;
                    const next = l -| loss(b);
                    if (next > acc.get(ch, q.x, q.y, q.z)) {
                        try acc.set(ch, q.x, q.y, q.z, next);
                        try self.inc.append(self.a, q);
                    }
                }
            }
        }
    };
}

// ---------------------------------------------------------------------------
// The 3 × 3 chunks around an edit
// ---------------------------------------------------------------------------

/// A store for `update`: the blocks and the light of the 3 × 3 chunks
/// around one chunk. x and z are local to the middle chunk, so the store
/// holds x and z from -16 to 31. y is local. A chunk that is not in the
/// store stops light, as the edge of the loaded world does.
pub const Region = struct {
    allocator: std.mem.Allocator,
    /// By slot (dcz + 1) * 3 + (dcx + 1): the chunk at offset (dcx, dcz)
    /// from the middle chunk, or null.
    parts: [9]?Part = @splat(null),

    /// The blocks and the light grids of one chunk.
    pub const Part = struct {
        blocks: *const chunk_mod.PalettedBlocks,
        sky: *chunk_mod.LightGrid,
        block: *chunk_mod.LightGrid,
    };

    const W = chunk_mod.CHUNK_W;
    const Loc = struct { part: Part, x: usize, z: usize };

    /// The slot of the chunk at offset (dcx, dcz), each -1 to 1.
    pub fn slot(dcx: i32, dcz: i32) usize {
        std.debug.assert(dcx >= -1 and dcx <= 1 and dcz >= -1 and dcz <= 1);
        return @intCast((dcz + 1) * 3 + (dcx + 1));
    }

    inline fn locate(self: *const Region, x: i32, z: i32) ?Loc {
        if (x < -W or x >= 2 * W or z < -W or z >= 2 * W) return null;
        const dcx = @divFloor(x, W);
        const dcz = @divFloor(z, W);
        const part = self.parts[slot(dcx, dcz)] orelse return null;
        return .{ .part = part, .x = @intCast(x - dcx * W), .z = @intCast(z - dcz * W) };
    }

    pub fn block(self: *const Region, x: i32, y: i32, z: i32) ?Block {
        const l = self.locate(x, z) orelse return null;
        return l.part.blocks.getAt(l.x, @intCast(y), l.z);
    }

    pub fn get(self: *const Region, ch: Channel, x: i32, y: i32, z: i32) u8 {
        const l = self.locate(x, z) orelse return 0;
        const g = if (ch == .sky) l.part.sky else l.part.block;
        return g.get(l.x, @intCast(y), l.z);
    }

    pub fn set(self: *const Region, ch: Channel, x: i32, y: i32, z: i32, value: u8) !void {
        const l = self.locate(x, z).?;
        const g = if (ch == .sky) l.part.sky else l.part.block;
        try g.set(self.allocator, l.x, @intCast(y), l.z, value);
    }

    /// `update` for edits in the middle chunk (x and z 0 to 15), then
    /// `LightGrid.compact` on each grid, so that each light value has one
    /// form for `LightGrid.eql` and the light hash.
    pub fn update(self: *const Region, edits: []const Pos) !void {
        defer for (self.parts) |maybe| {
            const part = maybe orelse continue;
            part.sky.compact(self.allocator);
            part.block.compact(self.allocator);
        };
        for (edits) |e| std.debug.assert(e.x >= 0 and e.x < W and e.z >= 0 and e.z < W);
        try light_update(self.allocator, self, edits);
    }
};

const light_update = update;

// ---------------------------------------------------------------------------
// Tests. They use the test content: b17 has opacity 3, b18 gives light 9
// and has opacity 0, and the model blocks b19 and b20 have opacity 0.
// ---------------------------------------------------------------------------

const testing = std.testing;
const CHUNK_W = chunk_mod.CHUNK_W;
const CHUNK_H = chunk_mod.CHUNK_H;

/// The light of `ch` on its own (no light from outside the chunk), from
/// the rules in the file comment: sources, then sweeps until no value
/// changes. Slow and simple: the reference for the fast passes.
fn referenceLight(ch: *const chunk_mod.Chunk, which: Channel, out: *chunk_mod.DenseLight) void {
    for (0..CHUNK_W) |x| for (0..CHUNK_W) |z| {
        var source = true;
        var y: usize = CHUNK_H;
        while (y > 0) {
            y -= 1;
            const b = ch.blocks.getAt(x, y, z);
            if (stopsSky(b)) source = false;
            out[x][y][z] = switch (which) {
                .sky => if (source) MAX_LIGHT else 0,
                .block => emission(b),
            };
        }
    };
    var changed = true;
    while (changed) {
        changed = false;
        for (0..CHUNK_W) |x| for (0..CHUNK_H) |y| for (0..CHUNK_W) |z| {
            const l = loss(ch.blocks.getAt(x, y, z));
            for (dirs) |d| {
                const nx = @as(i32, @intCast(x)) + d[0];
                const ny = @as(i32, @intCast(y)) + d[1];
                const nz = @as(i32, @intCast(z)) + d[2];
                if (nx < 0 or nx >= CHUNK_W or ny < 0 or ny >= CHUNK_H or nz < 0 or nz >= CHUNK_W) continue;
                const v = out[@intCast(nx)][@intCast(ny)][@intCast(nz)] -| l;
                if (v > out[x][y][z]) {
                    out[x][y][z] = v;
                    changed = true;
                }
            }
        };
    }
}

test "computeSkylight and computeBlockLight follow the light rules with mixed opacity (REQ-VOXEL-003)" {
    const a = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x11647);
    const r = prng.random();
    const kinds = [_]Block{ .air, .solid, .b17, .b18, .b19, .emitter };
    const want = try a.create(chunk_mod.DenseLight);
    defer a.destroy(want);
    const got = try a.create(chunk_mod.DenseLight);
    defer a.destroy(got);
    for (0..3) |case| {
        var ch = chunk_mod.Chunk.init(a);
        defer ch.deinit();
        try ch.generateTerrain(@intCast(case), -1, .{});
        for (0..60) |_| {
            const x0 = r.uintLessThan(usize, CHUNK_W);
            const y0 = r.intRangeAtMost(usize, 30, 110);
            const z0 = r.uintLessThan(usize, CHUNK_W);
            const b = kinds[r.uintLessThan(usize, kinds.len)];
            for (x0..@min(CHUNK_W, x0 + 4)) |x| for (y0..y0 + 3) |y| for (z0..@min(CHUNK_W, z0 + 4)) |z| {
                try ch.setBlock(@intCast(x), @intCast(y), @intCast(z), b);
            };
        }
        try ch.computeSkylight();
        try ch.computeBlockLight();
        referenceLight(&ch, .sky, want);
        ch.skylight.expand(got);
        try testing.expectEqualSlices(u8, std.mem.asBytes(want), std.mem.asBytes(got));
        referenceLight(&ch, .block, want);
        ch.block_light.expand(got);
        try testing.expectEqualSlices(u8, std.mem.asBytes(want), std.mem.asBytes(got));
    }
}

test "sky light falls straight down without loss and spreads to the sides with a loss of 1 (REQ-VOXEL-004)" {
    const a = testing.allocator;
    var ch = chunk_mod.Chunk.init(a);
    defer ch.deinit();
    // Ground at y 0 to 9, and a roof at y 40 over x 0 to 7.
    for (0..CHUNK_W) |x| for (0..CHUNK_W) |z| {
        for (0..10) |y| try ch.setBlock(@intCast(x), @intCast(y), @intCast(z), .solid);
        if (x < 8) try ch.setBlock(@intCast(x), 40, @intCast(z), .solid);
    };
    // A half block (opacity 0) and a cube with opacity 3 in the open sky.
    try ch.setBlock(12, 30, 5, .b19);
    try ch.setBlock(14, 30, 5, .b17);
    try ch.computeSkylight();
    // Open sky: 15 down to the ground, also under the half block.
    for (10..CHUNK_H) |y| try testing.expectEqual(MAX_LIGHT, ch.lightAt(12, @intCast(y), 5).sky);
    // Under the roof: 1 less for each step from the open column at x 8.
    for (0..8) |x| try testing.expectEqual(@as(u8, @intCast(7 + x)), ch.lightAt(@intCast(x), 20, 5).sky);
    // The cube with opacity 3 takes 3 levels, and it stops the straight
    // fall: the cell under it gets 14 from the sides.
    try testing.expectEqual(@as(u8, 12), ch.lightAt(14, 30, 5).sky);
    try testing.expectEqual(@as(u8, 14), ch.lightAt(14, 29, 5).sky);
    // The ground stops all light.
    try testing.expectEqual(@as(u8, 0), ch.lightAt(12, 9, 5).sky);
}

/// Expect that the light of each inner chunk (|cx|, |cz| <= 1) of `world`
/// is the light of a full recompute of the light stage.
fn expectStageLight(world: *const @import("world.zig").World) !void {
    const stages = @import("pipeline/stages.zig");
    const a = testing.allocator;
    var cx: i32 = -1;
    while (cx <= 1) : (cx += 1) {
        var cz: i32 = -1;
        while (cz <= 1) : (cz += 1) {
            var w: stages.Window = undefined;
            for (0..stages.SLOTS) |s| {
                const dcx, const dcz = stages.offsetOf(s);
                w[s] = &world.get(cx + dcx, cz + dcz).?.chunk.blocks;
            }
            var full = try stages.light(a, &w);
            defer full.deinit(a);
            const lc = world.get(cx, cz).?;
            try testing.expect(full.sky.eql(&lc.chunk.skylight));
            try testing.expect(full.block.eql(&lc.chunk.block_light));
        }
    }
}

test "an edit updates the light incrementally to the light of a full recompute (REQ-VOXEL-005)" {
    const World = @import("world.zig").World;
    const a = testing.allocator;
    var world = try World.init(a, .{}, 4);
    defer world.deinit();
    var cx: i32 = -2;
    while (cx <= 2) : (cx += 1) {
        var cz: i32 = -2;
        while (cz <= 2) : (cz += 1) _ = try world.generateChunk(cx, cz);
    }
    try expectStageLight(&world);
    var prng = std.Random.DefaultPrng.init(0x1ec7);
    const r = prng.random();
    const kinds = [_]Block{ .air, .air, .solid, .b17, .b18, .b19, .emitter };
    for (0..160) |i| {
        // Edits in the inner 3×3 chunks: in the terrain, at the surface,
        // and high in the open sky.
        const wx = r.intRangeAtMost(i32, -CHUNK_W, 2 * CHUNK_W - 1);
        const wz = r.intRangeAtMost(i32, -CHUNK_W, 2 * CHUNK_W - 1);
        const ly: i32 = switch (i % 4) {
            0 => r.intRangeAtMost(i32, 90, 140),
            else => r.intRangeAtMost(i32, 40, 100),
        };
        _ = try world.setBlock(wx, ly + chunk_mod.MIN_Y, wz, kinds[r.uintLessThan(usize, kinds.len)]);
        if (i % 40 == 39) try expectStageLight(&world);
    }
    // Open a shaft from the sky to the bottom of a hill, then close it.
    var y: i32 = 120;
    while (y > 20) : (y -= 1) _ = try world.setBlock(5, y + chunk_mod.MIN_Y, 7, .air);
    try expectStageLight(&world);
    // A cube with opacity 3 in the shaft, under the sky sources, with
    // walls of terrain at its sides: it takes its light from above.
    _ = try world.setBlock(5, 50 + chunk_mod.MIN_Y, 7, .b17);
    try expectStageLight(&world);
    try testing.expectEqual(@as(u8, 12), world.get(0, 0).?.chunk.lightAt(5, 50, 7).sky);
    _ = try world.setBlock(5, 119 + chunk_mod.MIN_Y, 7, .solid);
    try expectStageLight(&world);
}

test "a chunk worker updates its cached light on an edit (REQ-VOXEL-005)" {
    const stages = @import("pipeline/stages.zig");
    const protocol = @import("pipeline/protocol.zig");
    const WorkerWorld = @import("pipeline/worker_world.zig").WorkerWorld;
    const a = testing.allocator;
    var ww = WorkerWorld.init(a);
    defer ww.deinit();
    ww.setWorld(.{}, 1 << 40);
    for (0..stages.SLOTS) |s| {
        const dcx, const dcz = stages.offsetOf(s);
        _ = try ww.lightOf(dcx, dcz);
    }
    const lit = ww.stats.lit;
    var prng = std.Random.DefaultPrng.init(0x3017);
    const r = prng.random();
    const kinds = [_]Block{ .air, .solid, .b17, .b18, .b19, .emitter };
    for (0..30) |i| {
        try ww.applyEdit(.{
            .cx = 0,
            .cz = 0,
            .version = @intCast(i + 1),
            .x = r.uintLessThan(u8, CHUNK_W),
            .y = r.intRangeAtMost(u16, 40, 120),
            .z = r.uintLessThan(u8, CHUNK_W),
            .block = kinds[r.uintLessThan(usize, kinds.len)],
        });
    }
    try testing.expectEqual(@as(u64, 30), ww.stats.relit);
    for (0..stages.SLOTS) |s| {
        const dcx, const dcz = stages.offsetOf(s);
        const e = try ww.lightOf(dcx, dcz);
        var w: stages.Window = undefined;
        for (0..stages.SLOTS) |t| {
            const tx, const tz = stages.offsetOf(t);
            w[t] = &(try ww.blocksOf(dcx + tx, dcz + tz)).blocks;
        }
        var full = try stages.light(a, &w);
        defer full.deinit(a);
        try testing.expect(full.sky.eql(&e.light.?.sky));
        try testing.expect(full.block.eql(&e.light.?.block));
        try testing.expectEqual(protocol.lightHash(&full), e.light_hash);
    }
    // The cached light was current: no full recompute.
    try testing.expectEqual(lit, ww.stats.lit);
}
