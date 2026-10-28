//! Cave culling (REQ-VOXEL-019, REQ-VOXEL-020): which sections of the world
//! the camera can see through open space.
//!
//! A section is a 16 × 16 × 16 cube of a chunk column. For each section,
//! the mesh stage records which pairs of its 6 faces connect through open
//! cells (`sectionConnectivity`). A cell is open when it is not a full cube
//! (`models.isCube`): the mesher draws the faces next to an open cell. Two
//! faces connect when one region of open cells touches both.
//!
//! `walk` starts at the section of the camera and goes from section to
//! section. It enters a neighbour through a face, and leaves the neighbour
//! only through a face that connects to the entry face. It never goes back
//! in a direction opposite to a direction of its path, so the path goes
//! away from the camera. A section that the walk does not reach can not be
//! seen: a line of sight to it goes through closed cells. The walk keeps a
//! section that it can not prove hidden, so the image does not change.
//!
//! `cullBoxes` tests a list of boxes (chunk meshes, entities) against the
//! frustum and the visible sections.
//!
//! The technique is the cave culling of horizon (MIT), and of other voxel
//! engines. No code of horizon is in this file.
const std = @import("std");
const math = @import("sw_math");
const chunk_mod = @import("chunk.zig");
const frustum_mod = @import("frustum.zig");

const CHUNK_W = chunk_mod.CHUNK_W;
const CHUNK_H = chunk_mod.CHUNK_H;
const MIN_Y = chunk_mod.MIN_Y;
pub const SECTION_COUNT = chunk_mod.SECTION_COUNT;
const S = 16;

/// A face of a section, and a direction of the walk.
pub const Face = enum(u3) {
    nx,
    px,
    ny,
    py,
    nz,
    pz,

    pub fn opposite(f: Face) Face {
        return @fromBackingInt(@intCast(@backingInt(f) ^ 1));
    }

    /// The step to the neighbour through this face: (dx, dy, dz).
    pub fn step(f: Face) [3]i32 {
        return switch (f) {
            .nx => .{ -1, 0, 0 },
            .px => .{ 1, 0, 0 },
            .ny => .{ 0, -1, 0 },
            .py => .{ 0, 1, 0 },
            .nz => .{ 0, 0, -1 },
            .pz => .{ 0, 0, 1 },
        };
    }
};

/// The face pairs of a section that connect through open cells: one bit
/// for each of the 15 pairs (`pairBit`).
pub const Connectivity = u16;
/// Each pair connects: a section with no closed cell, or a section that
/// the caller does not know.
pub const all: Connectivity = 0x7FFF;
/// No pair connects: a section with only closed cells.
pub const none: Connectivity = 0;

/// The bit of the pair (a, b). a and b are different.
pub fn pairBit(a: Face, b: Face) Connectivity {
    var i: u8 = @backingInt(a);
    var j: u8 = @backingInt(b);
    std.debug.assert(i != j);
    if (i > j) std.mem.swap(u8, &i, &j);
    // Pairs in order: (0,1)..(0,5), (1,2)..(1,5), ... The pairs before row
    // i are 5 + 4 + ... : i * (11 - i) / 2.
    const index: u4 = @intCast(i * (11 - i) / 2 + (j - i - 1));
    return @as(Connectivity, 1) << index;
}

/// True when faces a and b of a section connect. A face connects to itself.
pub fn connects(c: Connectivity, a: Face, b: Face) bool {
    if (a == b) return true;
    return c & pairBit(a, b) != 0;
}

/// The connectivity of section `sy` from the full-cube columns of a chunk
/// (`Chunk.cubeColumns`).
pub fn sectionConnectivity(cols: *const [CHUNK_W][CHUNK_W]chunk_mod.Col, sy: usize) Connectivity {
    const y0 = sy * S;
    var closed: std.StaticBitSet(S * S * S) = .empty;
    var any_closed = false;
    for (0..S) |x| for (0..S) |z| {
        const word = cols[x][z][y0 >> 6];
        const bits: u16 = @truncate(word >> @intCast(y0 & 63));
        if (bits == 0) continue;
        any_closed = true;
        for (0..S) |y| {
            if ((bits >> @intCast(y)) & 1 != 0) closed.set(cell(x, y, z));
        }
    };
    if (!any_closed) return all;
    if (closed.count() == S * S * S) return none;

    var seen = closed;
    var stack: [S * S * S]u16 = undefined;
    var result: Connectivity = 0;
    for (0..S * S * S) |start| {
        if (seen.isSet(start)) continue;
        // A flood fill of one region of open cells.
        var faces: u6 = 0;
        var n: usize = 1;
        stack[0] = @intCast(start);
        seen.set(start);
        while (n > 0) {
            n -= 1;
            const c = stack[n];
            const x: i32 = c >> 8;
            const y: i32 = (c >> 4) & 15;
            const z: i32 = c & 15;
            if (x == 0) faces |= 1 << @backingInt(Face.nx);
            if (x == S - 1) faces |= 1 << @backingInt(Face.px);
            if (y == 0) faces |= 1 << @backingInt(Face.ny);
            if (y == S - 1) faces |= 1 << @backingInt(Face.py);
            if (z == 0) faces |= 1 << @backingInt(Face.nz);
            if (z == S - 1) faces |= 1 << @backingInt(Face.pz);
            for (std.enums.values(Face)) |f| {
                const d = f.step();
                const nx = x + d[0];
                const ny = y + d[1];
                const nz = z + d[2];
                if (nx < 0 or nx >= S or ny < 0 or ny >= S or nz < 0 or nz >= S) continue;
                const ni = cell(@intCast(nx), @intCast(ny), @intCast(nz));
                if (seen.isSet(ni)) continue;
                seen.set(ni);
                stack[n] = @intCast(ni);
                n += 1;
            }
        }
        for (0..6) |a| for (a + 1..6) |b| {
            if ((faces >> @intCast(a)) & 1 != 0 and (faces >> @intCast(b)) & 1 != 0)
                result |= pairBit(@fromBackingInt(@intCast(a)), @fromBackingInt(@intCast(b)));
        };
        if (result == all) break;
    }
    return result;
}

inline fn cell(x: usize, y: usize, z: usize) usize {
    return x * 256 + y * 16 + z;
}

/// The connectivity of each section of `chunk`.
pub fn chunkConnectivity(chunk: *const chunk_mod.Chunk) [SECTION_COUNT]Connectivity {
    var cols: [CHUNK_W][CHUNK_W]chunk_mod.Col = undefined;
    chunk.cubeColumns(&cols);
    var out: [SECTION_COUNT]Connectivity = undefined;
    for (&out, 0..) |*c, sy| c.* = sectionConnectivity(&cols, sy);
    return out;
}

/// A section of the world: chunk (cx, cz), section sy (0 at MIN_Y).
pub const SectionPos = struct {
    cx: i32,
    sy: i32,
    cz: i32,
};

/// The section of the world point (x, y, z). y out of the world gives the
/// nearest section.
pub fn sectionOf(x: f32, y: f32, z: f32) SectionPos {
    const sy = @divFloor(@as(i32, @intFromFloat(@floor(y))) - MIN_Y, S);
    return .{
        .cx = @divFloor(@as(i32, @intFromFloat(@floor(x))), CHUNK_W),
        .sy = std.math.clamp(sy, 0, SECTION_COUNT - 1),
        .cz = @divFloor(@as(i32, @intFromFloat(@floor(z))), CHUNK_W),
    };
}

/// The connectivity of the sections that the walk reads. Null: the
/// section is not known (no mesh yet). The walk then goes through it.
pub const Graph = struct {
    ctx: *const anyopaque,
    connFn: *const fn (ctx: *const anyopaque, p: SectionPos) ?Connectivity,
};

/// The sections that `walk` reached, and their chunk columns.
pub const VisibleSet = struct {
    sections: std.AutoHashMapUnmanaged(SectionPos, void) = .empty,
    columns: std.AutoHashMapUnmanaged([2]i32, void) = .empty,

    pub fn deinit(self: *VisibleSet, allocator: std.mem.Allocator) void {
        self.sections.deinit(allocator);
        self.columns.deinit(allocator);
    }

    pub fn clear(self: *VisibleSet) void {
        self.sections.clearRetainingCapacity();
        self.columns.clearRetainingCapacity();
    }

    pub fn section(self: *const VisibleSet, p: SectionPos) bool {
        return self.sections.contains(p);
    }

    /// True when a section of chunk column (cx, cz) is visible.
    pub fn column(self: *const VisibleSet, cx: i32, cz: i32) bool {
        return self.columns.contains(.{ cx, cz });
    }

    fn add(self: *VisibleSet, allocator: std.mem.Allocator, p: SectionPos) !bool {
        const gop = try self.sections.getOrPut(allocator, p);
        if (gop.found_existing) return false;
        try self.columns.put(allocator, .{ p.cx, p.cz }, {});
        return true;
    }
};

pub const WalkOptions = struct {
    /// The walk stops at this distance from the start, in chunks, on x and
    /// on z (the render distance).
    radius: i32,
    /// Sections out of the frustum stop the walk. Null: no frustum test.
    frustum: ?*const frustum_mod.Frustum = null,
};

const Node = struct {
    p: SectionPos,
    entry: Face,
    /// The directions of the path from the start: one bit for each Face.
    dirs: u6,
};

/// Find the sections that the camera at section `start` can see, into
/// `out` (cleared first).
pub fn walk(allocator: std.mem.Allocator, start: SectionPos, graph: Graph, options: WalkOptions, out: *VisibleSet) !void {
    out.clear();
    _ = try out.add(allocator, start);
    var queue: std.ArrayList(Node) = .empty;
    defer queue.deinit(allocator);
    // From the start section, each direction is open: the camera can be in
    // any cell of it.
    for (std.enums.values(Face)) |f| {
        const n = neighbour(start, f);
        if (!inRange(start, n, options)) continue;
        if (!try out.add(allocator, n)) continue;
        try queue.append(allocator, .{ .p = n, .entry = f.opposite(), .dirs = @as(u6, 1) << @backingInt(f) });
    }
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const node = queue.items[head];
        const conn = graph.connFn(graph.ctx, node.p) orelse all;
        for (std.enums.values(Face)) |f| {
            // Never back toward the camera.
            if (node.dirs & (@as(u6, 1) << @backingInt(f.opposite())) != 0) continue;
            if (!connects(conn, node.entry, f)) continue;
            const n = neighbour(node.p, f);
            if (!inRange(start, n, options)) continue;
            if (out.section(n)) continue;
            _ = try out.add(allocator, n);
            try queue.append(allocator, .{ .p = n, .entry = f.opposite(), .dirs = node.dirs | (@as(u6, 1) << @backingInt(f)) });
        }
    }
}

fn neighbour(p: SectionPos, f: Face) SectionPos {
    const d = f.step();
    return .{ .cx = p.cx + d[0], .sy = p.sy + d[1], .cz = p.cz + d[2] };
}

fn inRange(start: SectionPos, p: SectionPos, options: WalkOptions) bool {
    if (p.sy < 0 or p.sy >= SECTION_COUNT) return false;
    if (@abs(p.cx - start.cx) > options.radius or @abs(p.cz - start.cz) > options.radius) return false;
    if (options.frustum) |fr| return !frustum_mod.sectionOutside(fr.*, p.cx, p.sy, p.cz);
    return true;
}

/// A box in world coordinates.
pub const Box = struct {
    min: [3]f32,
    max: [3]f32,
};

/// For each box, true when it can be seen: it is in the frustum (when
/// given), and a section that it touches is in `visible`. `out` has the
/// length of `boxes`. Returns the number of boxes kept.
pub fn cullBoxes(boxes: []const Box, visible: *const VisibleSet, frustum: ?*const frustum_mod.Frustum, out: []bool) usize {
    std.debug.assert(out.len == boxes.len);
    var kept: usize = 0;
    for (boxes, out) |b, *keep| {
        keep.* = boxVisible(b, visible, frustum);
        if (keep.*) kept += 1;
    }
    return kept;
}

fn boxVisible(b: Box, visible: *const VisibleSet, frustum: ?*const frustum_mod.Frustum) bool {
    if (frustum) |fr| {
        const box = math.Aabb.init(math.Vec3.init(b.min[0], b.min[1], b.min[2]), math.Vec3.init(b.max[0], b.max[1], b.max[2]));
        if (frustum_mod.aabbOutside(fr.*, box)) return false;
    }
    const lo = sectionOf(b.min[0], b.min[1], b.min[2]);
    const hi = sectionOf(b.max[0], b.max[1], b.max[2]);
    var cx = lo.cx;
    while (cx <= hi.cx) : (cx += 1) {
        var cz = lo.cz;
        while (cz <= hi.cz) : (cz += 1) {
            var sy = lo.sy;
            while (sy <= hi.sy) : (sy += 1) {
                if (visible.section(.{ .cx = cx, .sy = sy, .cz = cz })) return true;
            }
        }
    }
    return false;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

/// Full-cube columns with each cell of section 0 closed, except `open`.
fn columnsWith(comptime open: fn (x: usize, y: usize, z: usize) bool) [CHUNK_W][CHUNK_W]chunk_mod.Col {
    var cols: [CHUNK_W][CHUNK_W]chunk_mod.Col = undefined;
    for (0..CHUNK_W) |x| for (0..CHUNK_W) |z| {
        cols[x][z] = @splat(0);
        for (0..S) |y| {
            if (!open(x, y, z)) cols[x][z][0] |= @as(u64, 1) << @intCast(y);
        }
    };
    return cols;
}

test "visibility: a section records the face pairs that connect (REQ-VOXEL-019)" {
    // Empty: each pair. Full: no pair.
    const empty = columnsWith(struct {
        fn f(_: usize, _: usize, _: usize) bool {
            return true;
        }
    }.f);
    try testing.expectEqual(all, sectionConnectivity(&empty, 0));
    const full = columnsWith(struct {
        fn f(_: usize, _: usize, _: usize) bool {
            return false;
        }
    }.f);
    try testing.expectEqual(none, sectionConnectivity(&full, 0));
    // A tunnel along x at y 5, z 5: only -x and +x connect.
    const tunnel = columnsWith(struct {
        fn f(_: usize, y: usize, z: usize) bool {
            return y == 5 and z == 5;
        }
    }.f);
    try testing.expectEqual(pairBit(.nx, .px), sectionConnectivity(&tunnel, 0));
    // An L: from -x to +y, and a closed pocket inside.
    const ell = columnsWith(struct {
        fn f(x: usize, y: usize, z: usize) bool {
            if (z != 8) return x == 8 and y == 8 and z == 4; // the pocket
            return (y == 3 and x <= 9) or (x == 9 and y >= 3);
        }
    }.f);
    try testing.expectEqual(pairBit(.nx, .py), sectionConnectivity(&ell, 0));
    // The section above (all air in these columns) connects each pair.
    if (SECTION_COUNT > 1) try testing.expectEqual(all, sectionConnectivity(&tunnel, 1));
    try testing.expect(connects(none, .px, .px));
    // The 15 pair bits are different.
    var seen: Connectivity = 0;
    for (0..6) |a| for (a + 1..6) |b| {
        const bit = pairBit(@fromBackingInt(@intCast(a)), @fromBackingInt(@intCast(b)));
        try testing.expectEqual(bit, pairBit(@fromBackingInt(@intCast(b)), @fromBackingInt(@intCast(a))));
        try testing.expect(seen & bit == 0);
        seen |= bit;
    };
    try testing.expectEqual(all, seen);
}

/// A test world of sections: closed except for the sections in `open`.
/// A section in `tunnel` connects only -x and +x.
const TestGraph = struct {
    open: []const SectionPos,
    tunnel: []const SectionPos = &.{},

    fn conn(ctx: *const anyopaque, p: SectionPos) ?Connectivity {
        const self: *const TestGraph = @ptrCast(@alignCast(ctx));
        for (self.open) |o| if (std.meta.eql(o, p)) return all;
        for (self.tunnel) |o| if (std.meta.eql(o, p)) return pairBit(.nx, .px);
        return none;
    }

    fn graph(self: *const TestGraph) Graph {
        return .{ .ctx = self, .connFn = conn };
    }
};

test "visibility: the walk stops at closed sections, and keeps the walls (REQ-VOXEL-020)" {
    const a = testing.allocator;
    var vis: VisibleSet = .{};
    defer vis.deinit(a);
    // A closed cave: the camera section and one open section next to it.
    const g: TestGraph = .{ .open = &.{ .{ .cx = 0, .sy = 2, .cz = 0 }, .{ .cx = 1, .sy = 2, .cz = 0 } } };
    try walk(a, .{ .cx = 0, .sy = 2, .cz = 0 }, g.graph(), .{ .radius = 8 }, &vis);
    // The start, its 6 walls, and the walls of the open neighbour (+x
    // side, all but its -x face): 1 + 6 + 5 = 12. The far sections are not
    // in it.
    try testing.expect(vis.section(.{ .cx = 1, .sy = 2, .cz = 0 }));
    try testing.expect(vis.section(.{ .cx = 2, .sy = 2, .cz = 0 }));
    try testing.expect(vis.section(.{ .cx = 0, .sy = 3, .cz = 0 }));
    try testing.expect(!vis.section(.{ .cx = 3, .sy = 2, .cz = 0 }));
    try testing.expect(!vis.column(5, 5));
    try testing.expectEqual(@as(usize, 12), vis.sections.count());

    // A tunnel along +x: the walk goes through it to the end, and not to
    // the side.
    const t: TestGraph = .{ .open = &.{}, .tunnel = &.{ .{ .cx = 1, .sy = 2, .cz = 0 }, .{ .cx = 2, .sy = 2, .cz = 0 }, .{ .cx = 3, .sy = 2, .cz = 0 } } };
    try walk(a, .{ .cx = 0, .sy = 2, .cz = 0 }, t.graph(), .{ .radius = 8 }, &vis);
    try testing.expect(vis.section(.{ .cx = 4, .sy = 2, .cz = 0 }));
    try testing.expect(!vis.section(.{ .cx = 5, .sy = 2, .cz = 0 }));
    try testing.expect(!vis.section(.{ .cx = 2, .sy = 2, .cz = 1 }));

    // Unknown sections (null) are open: the walk goes to the radius.
    const unknown: Graph = .{ .ctx = &t, .connFn = struct {
        fn f(_: *const anyopaque, _: SectionPos) ?Connectivity {
            return null;
        }
    }.f };
    try walk(a, .{ .cx = 0, .sy = 2, .cz = 0 }, unknown, .{ .radius = 2 }, &vis);
    try testing.expect(vis.section(.{ .cx = 2, .sy = 0, .cz = -2 }));
    try testing.expect(!vis.column(3, 0));
    try testing.expectEqual(@as(usize, 25 * SECTION_COUNT), vis.sections.count());
}

test "visibility: the box cull keeps the boxes in visible sections (REQ-VOXEL-020)" {
    const a = testing.allocator;
    var vis: VisibleSet = .{};
    defer vis.deinit(a);
    const g: TestGraph = .{ .open = &.{.{ .cx = 0, .sy = 2, .cz = 0 }} };
    try walk(a, .{ .cx = 0, .sy = 2, .cz = 0 }, g.graph(), .{ .radius = 8 }, &vis);
    const y: f32 = @floatFromInt(MIN_Y + 2 * S);
    const boxes = [_]Box{
        // In the camera section.
        .{ .min = .{ 2, y + 1, 2 }, .max = .{ 3, y + 3, 3 } },
        // Far away in the closed rock.
        .{ .min = .{ 100, y + 1, 2 }, .max = .{ 101, y + 3, 3 } },
        // Over the border of a far section and a visible wall section.
        .{ .min = .{ 30, y + 1, 2 }, .max = .{ 34, y + 3, 3 } },
    };
    var keep: [3]bool = undefined;
    try testing.expectEqual(@as(usize, 2), cullBoxes(&boxes, &vis, null, &keep));
    try testing.expectEqualSlices(bool, &.{ true, false, true }, &keep);
}

/// A test world of sections from a seed: each section is open (all pairs)
/// or closed (no pair).
const RandomGraph = struct {
    seed: u64,
    /// Open sections in 1000.
    open_per_mille: u32,
    start: SectionPos,

    fn isOpen(self: *const RandomGraph, p: SectionPos) bool {
        if (std.meta.eql(p, self.start)) return true;
        var h: u64 = self.seed;
        for ([_]i32{ p.cx, p.sy, p.cz }) |v| {
            h ^= @as(u64, @as(u32, @bitCast(v)));
            h *%= 0x9E3779B97F4A7C15;
            h ^= h >> 29;
        }
        return h % 1000 < self.open_per_mille;
    }

    fn conn(ctx: *const anyopaque, p: SectionPos) ?Connectivity {
        const self: *const RandomGraph = @ptrCast(@alignCast(ctx));
        return if (self.isOpen(p)) all else none;
    }

    fn graph(self: *const RandomGraph) Graph {
        return .{ .ctx = self, .connFn = conn };
    }
};

test "visibility: each section on a line of sight is visible, and the walk culls a closed cave (REQ-VOXEL-020)" {
    // The image check: rays from points in the camera section go through
    // open sections until they hit a closed section. Each section on a ray,
    // the closed section too, must be in the visible set. If not, the cull
    // removes a section that the camera can see, and the image changes.
    const a = testing.allocator;
    var vis: VisibleSet = .{};
    defer vis.deinit(a);
    const radius = 8;
    const start: SectionPos = .{ .cx = 0, .sy = @min(4, SECTION_COUNT - 1), .cz = 0 };
    var prng: std.Random.DefaultPrng = .init(0x5EC7);
    const rand = prng.random();
    var culled_total: usize = 0;
    for ([_]u32{ 150, 300, 450 }) |open| for (0..4) |seed| {
        const g: RandomGraph = .{ .seed = seed, .open_per_mille = open, .start = start };
        try walk(a, start, g.graph(), .{ .radius = radius }, &vis);
        for (0..400) |_| {
            // A ray in section units, with an exact grid walk (DDA), so
            // that it does not jump over the corner of a section.
            const o = [3]f32{
                @as(f32, @floatFromInt(start.cx)) + rand.float(f32),
                @as(f32, @floatFromInt(start.sy)) + rand.float(f32),
                @as(f32, @floatFromInt(start.cz)) + rand.float(f32),
            };
            const dir = [3]f32{ rand.float(f32) * 2 - 1, rand.float(f32) * 2 - 1, rand.float(f32) * 2 - 1 };
            var at = [3]i32{ start.cx, start.sy, start.cz };
            var step: [3]i32 = undefined;
            var t_max: [3]f32 = undefined;
            var t_delta: [3]f32 = undefined;
            for (0..3) |k| {
                step[k] = if (dir[k] < 0) -1 else 1;
                t_delta[k] = if (dir[k] == 0) std.math.inf(f32) else @abs(1 / dir[k]);
                const edge: f32 = @floatFromInt(at[k] + @as(i32, if (step[k] > 0) 1 else 0));
                t_max[k] = if (dir[k] == 0) std.math.inf(f32) else (edge - o[k]) / dir[k];
            }
            while (true) {
                var k: usize = 0;
                if (t_max[1] < t_max[k]) k = 1;
                if (t_max[2] < t_max[k]) k = 2;
                at[k] += step[k];
                t_max[k] += t_delta[k];
                const p: SectionPos = .{ .cx = at[0], .sy = at[1], .cz = at[2] };
                if (!inRange(start, p, .{ .radius = radius })) break;
                if (!vis.section(p)) {
                    std.debug.print("hidden section on a line of sight: {} (open {}, seed {})\n", .{ p, open, seed });
                    return error.TestUnexpectedResult;
                }
                if (!g.isOpen(p)) break;
            }
        }
        // The benchmark: the frustum-only cull draws each column in range.
        const in_range: usize = (2 * radius + 1) * (2 * radius + 1);
        try testing.expect(vis.columns.count() <= in_range);
        culled_total += in_range - vis.columns.count();
    };
    try testing.expect(culled_total > 0);

    // A closed cave of 3 open sections: the walk keeps the cave and its
    // walls, 4 % of the columns in range or less.
    const cave: TestGraph = .{ .open = &.{ start, .{ .cx = 1, .sy = start.sy, .cz = 0 }, .{ .cx = 1, .sy = start.sy, .cz = 1 } } };
    try walk(a, start, cave.graph(), .{ .radius = radius }, &vis);
    try testing.expect(vis.columns.count() * 25 <= (2 * radius + 1) * (2 * radius + 1));
}
