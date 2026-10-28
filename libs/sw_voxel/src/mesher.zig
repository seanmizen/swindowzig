const std = @import("std");
const chunk_mod = @import("chunk.zig");
const model_mod = @import("model.zig");
const section_mod = @import("section.zig");
const models = @import("models.zig");
const fluid = @import("fluid.zig");
const translucent = @import("translucent.zig");
const content = @import("content.zig");
const gpu_mod = @import("sw_gpu");
const Chunk = chunk_mod.Chunk;
const BlockType = chunk_mod.BlockType;
const BlockGetter = chunk_mod.BlockGetter;
const CellLight = chunk_mod.CellLight;
const CHUNK_W = chunk_mod.CHUNK_W;
const CHUNK_H = chunk_mod.CHUNK_H;
const MIN_Y = chunk_mod.MIN_Y;
pub const AOStrategy = gpu_mod.AOStrategy;
pub const LightingMode = gpu_mod.LightingMode;

/// Vertex format of vs_main in voxel.wgsl. The player cylinder and the chunk
/// border use it. Chunk meshes do not: they use PackedQuad (see below).
/// unpackCorner gives the vertex of one corner of a PackedQuad in this format.
pub const VoxelVertex = extern struct {
    pos: [3]f32, // offset 0
    normal: [3]f32, // offset 12
    block_type: u32, // offset 24
    uv: [2]f32, // offset 28
    ao: f32 = 1.0, // offset 36 — ambient occlusion brightness 0..1
    skylight: f32 = 1.0, // offset 40 — sky brightness 0..1 (0 = pitch cave, 1 = open sky)
    block_light: f32 = 0.0, // offset 44 — block-light brightness 0..1 (0 = no emitter nearby, 1 = adjacent to an emitter)
};

/// The mesh of one chunk, in the GPU format: one 16-byte PackedQuad per quad,
/// and the y range of the quads. The quads are in order of their section
/// (`ranges`, REQ-VOXEL-023). In a section, the greedy quads come first,
/// then the model quad records (see "Model quad records" below). The upload
/// writes `quads` to the GPU as it is. The mesher makes the GPU format
/// directly, so a mesh can cross a thread or worker boundary with no
/// conversion.
pub const Mesh = struct {
    allocator: std.mem.Allocator,
    /// One PackedQuad per quad, in order of section.
    quads: std.ArrayList(PackedQuad),
    /// The lowest and the highest world y of the quads, for the frustum
    /// cull. With no quads, y_min is MIN_Y + CHUNK_H and y_max is MIN_Y.
    y_min: f32 = EMPTY_Y_MIN,
    y_max: f32 = EMPTY_Y_MAX,
    /// The draw range of each section (REQ-VOXEL-023).
    ranges: SectionRanges = EMPTY_RANGES,
    /// While the mesher runs: the lowest and the highest section of each
    /// quad, in the order of `quads`.
    spans: std.ArrayList([2]u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Mesh {
        return .{ .allocator = allocator, .quads = .empty };
    }

    pub fn deinit(self: *Mesh) void {
        self.quads.deinit(self.allocator);
        self.spans.deinit(self.allocator);
    }

    pub fn quadCount(self: *const Mesh) usize {
        return self.quads.items.len;
    }

    pub fn clear(self: *Mesh) void {
        self.quads.clearRetainingCapacity();
        self.spans.clearRetainingCapacity();
        self.y_min = EMPTY_Y_MIN;
        self.y_max = EMPTY_Y_MAX;
        self.ranges = EMPTY_RANGES;
    }

    /// Release ALL host-side mesh allocations back to the allocator. Unlike
    /// `clear` (which only zeroes lengths and keeps capacity for reuse), this
    /// drops capacity to 0 — used by the per-frame mesh-eviction pass when a
    /// chunk wanders outside the render distance and we want the host RAM
    /// back, not just the GPU buffer back.
    ///
    /// The Mesh struct itself stays valid: a subsequent `generateMesh` against
    /// this Mesh works and grows the storage again as it appends.
    pub fn freeHostBuffers(self: *Mesh) void {
        self.quads.clearAndFree(self.allocator);
        self.spans.clearAndFree(self.allocator);
        self.y_min = EMPTY_Y_MIN;
        self.y_max = EMPTY_Y_MAX;
        self.ranges = EMPTY_RANGES;
    }

    /// Append one quad that spans y_lo..y_hi.
    fn addQuad(self: *Mesh, q: PackedQuad, y_lo: f32, y_hi: f32) !void {
        try self.quads.append(self.allocator, q);
        try self.spans.append(self.allocator, quadSpan(y_lo, y_hi));
        self.y_min = @min(self.y_min, y_lo);
        self.y_max = @max(self.y_max, y_hi);
    }

    /// Put the quads in order of their lowest section, and set `ranges`
    /// (REQ-VOXEL-023). The sort is stable: in a section, the quads keep
    /// the order of the mesher. Call it before the tint records go in.
    fn sortBySection(self: *Mesh) !void {
        std.debug.assert(self.spans.items.len == self.quads.items.len);
        var counts: [SECTION_COUNT]u32 = @splat(0);
        var tops: [SECTION_COUNT]u8 = undefined;
        for (&tops, 0..) |*t, s| t.* = @intCast(s);
        for (self.spans.items) |sp| {
            counts[sp[0]] += 1;
            tops[sp[0]] = @max(tops[sp[0]], sp[1]);
        }
        var starts: [SECTION_COUNT]u32 = undefined;
        var at: u32 = 0;
        for (&starts, counts, 0..) |*st, c, s| {
            st.* = at;
            at += c;
            self.ranges[s] = .{ .end = @intCast(at), .top = tops[s] };
        }
        // Quads that are in order already do not move.
        var in_order = true;
        if (self.spans.items.len > 1) for (self.spans.items[1..], 0..) |sp, i| {
            if (sp[0] < self.spans.items[i][0]) {
                in_order = false;
                break;
            }
        };
        if (in_order) {
            self.spans.clearRetainingCapacity();
            return;
        }
        const sorted = try self.allocator.alloc(PackedQuad, self.quads.items.len);
        defer self.allocator.free(sorted);
        for (self.quads.items, self.spans.items) |q, sp| {
            sorted[starts[sp[0]]] = q;
            starts[sp[0]] += 1;
        }
        @memcpy(self.quads.items, sorted);
        self.spans.clearRetainingCapacity();
    }

    /// Move each range end by `n` quads: the tint records at the start.
    fn shiftRanges(self: *Mesh, n: usize) void {
        for (&self.ranges) |*r| r.end += @intCast(n);
    }
};

/// The draw range of one section of a mesh (REQ-VOXEL-023). The quads of
/// section s are from the `end` of section s - 1 (0 for section 0) to the
/// `end` of section s. A quad is in the section of its lowest point. A
/// quad can go up into the sections above it: `top` is the highest section
/// that a quad of the range touches. Draw the range when a section from s
/// to `top` is visible. The tint records at the start of a mesh are in the
/// range of section 0.
pub const SectionRange = packed struct(u32) {
    end: u24,
    top: u8,
};
pub const SectionRanges = [SECTION_COUNT]SectionRange;
pub const SECTION_COUNT = chunk_mod.SECTION_COUNT;
/// The ranges of a mesh with no quads.
pub const EMPTY_RANGES: SectionRanges = blk: {
    var r: SectionRanges = undefined;
    for (&r, 0..) |*x, s| x.* = .{ .end = 0, .top = s };
    break :blk r;
};

/// The sections of the cells that a quad from y_lo to y_hi (world y)
/// touches. A flat quad on a section border is in the two sections: the
/// two cells on its sides.
fn quadSpan(y_lo: f32, y_hi: f32) [2]u8 {
    const lo = if (y_hi > y_lo or y_lo != @floor(y_lo)) y_lo else y_lo - 1;
    const hi = if (y_hi > y_lo) @max(lo, @ceil(y_hi) - 1) else y_hi;
    return .{ sectionOfY(lo), sectionOfY(hi) };
}

fn sectionOfY(y: f32) u8 {
    const s = @divFloor(@as(i32, @intFromFloat(@floor(y))) - MIN_Y, 16);
    return @intCast(std.math.clamp(s, 0, SECTION_COUNT - 1));
}

/// The y range of a mesh with no quads: y_min above y_max.
pub const EMPTY_Y_MIN: f32 = MIN_Y + CHUNK_H;
pub const EMPTY_Y_MAX: f32 = MIN_Y;

const BlockPos = struct { x: i32, y: i32, z: i32 };

// ---------------------------------------------------------------------------
// Face data
// ---------------------------------------------------------------------------

const Face = model_mod.Face;

const face_normals = [_][3]f32{
    .{ 1, 0, 0 }, // +X
    .{ -1, 0, 0 }, // -X
    .{ 0, 1, 0 }, // +Y
    .{ 0, -1, 0 }, // -Y
    .{ 0, 0, 1 }, // +Z
    .{ 0, 0, -1 }, // -Z
};

const face_offsets = [_][3]i32{
    .{ 1, 0, 0 }, // +X
    .{ -1, 0, 0 }, // -X
    .{ 0, 1, 0 }, // +Y
    .{ 0, -1, 0 }, // -Y
    .{ 0, 0, 1 }, // +Z
    .{ 0, 0, -1 }, // -Z
};

/// Fast face-render check: true when the neighbour in the face direction is
/// not a full cube (air or a block with a model). For neighbours within this
/// chunk's bounds (~92% of cases), uses direct array access. Only falls back
/// to the world getter for out-of-bounds neighbours (chunk boundaries),
/// enabling correct cross-chunk face culling.
fn shouldRenderFace(chunk: *const Chunk, getter: BlockGetter, lx: i32, ly: i32, lz: i32, world_ox: i32, world_oz: i32, face: Face) bool {
    const offset = face_offsets[@backingInt(face)];
    const nx = lx + offset[0];
    const ny = ly + offset[1];
    const nz = lz + offset[2];
    // Fast path: neighbour is within this chunk (paletted bounds-free read,
    // no HashMap). resolveBlockRaw skips the bounds check we just did.
    if (nx >= 0 and nx < CHUNK_W and ny >= 0 and ny < CHUNK_H and nz >= 0 and nz < CHUNK_W) {
        return !models.isCube(chunk.resolveBlockRaw(nx, ny, nz));
    }
    // Slow path: neighbour in adjacent chunk — world HashMap lookup
    return !models.isCube(getter.getBlock(world_ox + nx, ny + MIN_Y, world_oz + nz));
}

// ---------------------------------------------------------------------------
// Ambient occlusion helpers
// ---------------------------------------------------------------------------

/// Returns true if the block at world coords (wx, wy, wz) is solid.
/// Fast path for in-chunk; falls through to the world getter for cross-chunk.
fn isSolid(chunk: *const Chunk, getter: BlockGetter, world_ox: i32, world_oz: i32, wx: i32, wy: i32, wz: i32) bool {
    const lx = wx - world_ox;
    const lz = wz - world_oz;
    if (lx >= 0 and lx < CHUNK_W and wy >= 0 and wy < CHUNK_H and lz >= 0 and lz < CHUNK_W) {
        return occludes(chunk.resolveBlockRaw(lx, wy, lz));
    }
    return occludes(getter.getBlock(wx, wy + MIN_Y, wz));
}

/// The blocks that darken the AO of a corner: not air, not a fluid and not
/// translucent. One table, so the AO pays one read for each block.
const occluder_table: [256]bool = blk: {
    @setEvalBranchQuota(100_000);
    var t: [256]bool = @splat(false);
    for (@typeInfo(BlockType).@"enum".field_values) |v| {
        const b: BlockType = @fromBackingInt(v);
        t[v] = b != .air and !fluid.isFluid(b) and !translucent.isTranslucent(b);
    }
    break :blk t;
};

/// True when `block` darkens the AO of a corner.
inline fn occludes(block: BlockType) bool {
    return occluder_table[@backingInt(block)];
}

fn aoValue(s1: bool, s2: bool, c: bool) f32 {
    if (s1 and s2) return 0.0;
    const blocked: u32 = @as(u32, @intFromBool(s1)) + @as(u32, @intFromBool(s2)) + @as(u32, @intFromBool(c));
    return (3.0 - @as(f32, @floatFromInt(blocked))) / 3.0;
}

/// Moore-extended per-vertex AO formula.
///
/// Combines the classic 3 face-plane samples (s1, s2, c — at outward+1) with
/// the corresponding 3 samples from the *deeper* slab (ds1, ds2, dc — at
/// outward+2). Both layers contribute equally — picking 0.5 for the far weight
/// gave correctly-localized but visually subtle darkening; equal weight makes
/// the indoor-corner contribution actually visible without affecting flat
/// outdoor faces (where both slabs read all-air anyway).
///
///   occlusion = (s1 + s2 + c) + (ds1 + ds2 + dc)
///   max_occ   = 3 + 3 = 6
///   ao        = (max_occ - occlusion) / max_occ   ∈ [0, 1]
///
/// The classic hard-zero on `s1 ∧ s2` (face-touching contact corner) is kept
/// — those vertices stay maximally dark regardless of the deeper layer. This
/// prevents Moore from making concave hard corners *brighter* than classic.
fn aoMooreValue(s1: bool, s2: bool, c: bool, ds1: bool, ds2: bool, dc: bool) f32 {
    if (s1 and s2) return 0.0;
    const near: f32 = @floatFromInt(@as(u32, @intFromBool(s1)) + @as(u32, @intFromBool(s2)) + @as(u32, @intFromBool(c)));
    const far: f32 = @floatFromInt(@as(u32, @intFromBool(ds1)) + @as(u32, @intFromBool(ds2)) + @as(u32, @intFromBool(dc)));
    const occlusion = near + far;
    const max_occlusion: f32 = 6.0;
    return std.math.clamp((max_occlusion - occlusion) / max_occlusion, 0.0, 1.0);
}

/// Compute per-vertex AO brightness (0..1) for a face quad.
/// Returns [4]f32 — one brightness per corner, in the corner order of face_layouts.
///
/// Strategy dispatch:
///   - .none           — returns [1.0]*4 (no occlusion at all)
///   - .classic        — face-plane 8-neighbour AO (3 samples per vertex)
///   - .moore          — extended outward sampling; falls back to classic in
///                       commit A (this file), implemented in commit B
///   - .propagated     — TODO; falls back to classic with a runtime warning
///   - .ssao           — TODO; falls back to classic with a runtime warning
fn computeFaceAOForStrategy(
    chunk: *const Chunk,
    getter: BlockGetter,
    world_ox: i32,
    world_oz: i32,
    wx: i32,
    wy: i32,
    wz: i32,
    face: Face,
    strategy: AOStrategy,
) [4]f32 {
    return switch (strategy) {
        .none => .{ 1.0, 1.0, 1.0, 1.0 },
        .classic => computeFaceAOClassic(chunk, getter, world_ox, world_oz, wx, wy, wz, face),
        .moore => computeFaceAOMoore(chunk, getter, world_ox, world_oz, wx, wy, wz, face),
        .propagated => computeFaceAOPropagated(chunk, getter, world_ox, world_oz, wx, wy, wz, face),
        .ssao => blk: {
            // Lazily warn once per process about unimplemented strategies.
            unimplemented_warned.warn(strategy);
            break :blk computeFaceAOClassic(chunk, getter, world_ox, world_oz, wx, wy, wz, face);
        },
    };
}

/// One-shot warning state for strategies that fall back to classic. The
/// flag is atomic, because the chunk workers of the thread pool mesh in
/// parallel (pipeline/exec_threads.zig).
const UnimplementedWarn = struct {
    ssao: std.atomic.Value(bool) = .init(false),

    fn warn(self: *UnimplementedWarn, strat: AOStrategy) void {
        switch (strat) {
            .ssao => if (!self.ssao.swap(true, .monotonic)) {
                std.log.warn("AO strategy '.ssao' not yet implemented — falling back to .classic", .{});
            },
            else => {},
        }
    }
};

var unimplemented_warned: UnimplementedWarn = .{};

/// Classic per-vertex AO (the 3-neighbour corner rule).
/// Samples the 8 face-plane neighbours one cell beyond the face plane and
/// picks 3 (side1, side2, corner) per vertex via `aoValue`.
fn computeFaceAOClassic(chunk: *const Chunk, getter: BlockGetter, world_ox: i32, world_oz: i32, wx: i32, wy: i32, wz: i32, face: Face) [4]f32 {
    return switch (face) {
        .px => blk: {
            // +X face at x+1 plane — corners vary in Y and Z
            const s_ym = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz);
            const s_yp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz);
            const s_zm = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy, wz - 1);
            const s_zp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy, wz + 1);
            const s_ym_zm = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz - 1);
            const s_yp_zm = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz - 1);
            const s_yp_zp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz + 1);
            const s_ym_zp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz + 1);
            break :blk .{
                aoValue(s_ym, s_zm, s_ym_zm), // v0: (wx+1, wy,   wz  )
                aoValue(s_yp, s_zm, s_yp_zm), // v1: (wx+1, wy+1, wz  )
                aoValue(s_yp, s_zp, s_yp_zp), // v2: (wx+1, wy+1, wz+1)
                aoValue(s_ym, s_zp, s_ym_zp), // v3: (wx+1, wy,   wz+1)
            };
        },
        .nx => blk: {
            // -X face at x plane — corners vary in Y and Z
            const s_ym = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz);
            const s_yp = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz);
            const s_zm = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy, wz - 1);
            const s_zp = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy, wz + 1);
            const s_ym_zm = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz - 1);
            const s_yp_zm = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz - 1);
            const s_yp_zp = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz + 1);
            const s_ym_zp = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz + 1);
            break :blk .{
                aoValue(s_ym, s_zp, s_ym_zp), // v0: (wx, wy,   wz+1)
                aoValue(s_yp, s_zp, s_yp_zp), // v1: (wx, wy+1, wz+1)
                aoValue(s_yp, s_zm, s_yp_zm), // v2: (wx, wy+1, wz  )
                aoValue(s_ym, s_zm, s_ym_zm), // v3: (wx, wy,   wz  )
            };
        },
        .py => blk: {
            // +Y face at y+1 plane — corners vary in X and Z
            const s_xm = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz);
            const s_xp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz);
            const s_zm = isSolid(chunk, getter, world_ox, world_oz, wx, wy + 1, wz - 1);
            const s_zp = isSolid(chunk, getter, world_ox, world_oz, wx, wy + 1, wz + 1);
            const s_xm_zm = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz - 1);
            const s_xm_zp = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz + 1);
            const s_xp_zp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz + 1);
            const s_xp_zm = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz - 1);
            break :blk .{
                aoValue(s_xm, s_zm, s_xm_zm), // v0: (wx,   wy+1, wz  )
                aoValue(s_xm, s_zp, s_xm_zp), // v1: (wx,   wy+1, wz+1)
                aoValue(s_xp, s_zp, s_xp_zp), // v2: (wx+1, wy+1, wz+1)
                aoValue(s_xp, s_zm, s_xp_zm), // v3: (wx+1, wy+1, wz  )
            };
        },
        .ny => blk: {
            // -Y face at y plane — corners vary in X and Z
            const s_xm = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz);
            const s_xp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz);
            const s_zm = isSolid(chunk, getter, world_ox, world_oz, wx, wy - 1, wz - 1);
            const s_zp = isSolid(chunk, getter, world_ox, world_oz, wx, wy - 1, wz + 1);
            const s_xm_zm = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz - 1);
            const s_xm_zp = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz + 1);
            const s_xp_zm = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz - 1);
            const s_xp_zp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz + 1);
            break :blk .{
                aoValue(s_xm, s_zp, s_xm_zp), // v0: (wx,   wy, wz+1)
                aoValue(s_xm, s_zm, s_xm_zm), // v1: (wx,   wy, wz  )
                aoValue(s_xp, s_zm, s_xp_zm), // v2: (wx+1, wy, wz  )
                aoValue(s_xp, s_zp, s_xp_zp), // v3: (wx+1, wy, wz+1)
            };
        },
        .pz => blk: {
            // +Z face at z+1 plane — corners vary in X and Y
            const s_xm = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy, wz + 1);
            const s_xp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy, wz + 1);
            const s_ym = isSolid(chunk, getter, world_ox, world_oz, wx, wy - 1, wz + 1);
            const s_yp = isSolid(chunk, getter, world_ox, world_oz, wx, wy + 1, wz + 1);
            const s_xm_ym = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz + 1);
            const s_xp_ym = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz + 1);
            const s_xp_yp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz + 1);
            const s_xm_yp = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz + 1);
            break :blk .{
                aoValue(s_xm, s_ym, s_xm_ym), // v0: (wx,   wy,   wz+1)
                aoValue(s_xp, s_ym, s_xp_ym), // v1: (wx+1, wy,   wz+1)
                aoValue(s_xp, s_yp, s_xp_yp), // v2: (wx+1, wy+1, wz+1)
                aoValue(s_xm, s_yp, s_xm_yp), // v3: (wx,   wy+1, wz+1)
            };
        },
        .nz => blk: {
            // -Z face at z plane — corners vary in X and Y
            const s_xm = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy, wz - 1);
            const s_xp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy, wz - 1);
            const s_ym = isSolid(chunk, getter, world_ox, world_oz, wx, wy - 1, wz - 1);
            const s_yp = isSolid(chunk, getter, world_ox, world_oz, wx, wy + 1, wz - 1);
            const s_xm_ym = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz - 1);
            const s_xp_ym = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz - 1);
            const s_xm_yp = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz - 1);
            const s_xp_yp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz - 1);
            break :blk .{
                aoValue(s_xp, s_ym, s_xp_ym), // v0: (wx+1, wy,   wz)
                aoValue(s_xm, s_ym, s_xm_ym), // v1: (wx,   wy,   wz)
                aoValue(s_xm, s_yp, s_xm_yp), // v2: (wx,   wy+1, wz)
                aoValue(s_xp, s_yp, s_xp_yp), // v3: (wx+1, wy+1, wz)
            };
        },
    };
}

/// Extended-Moore per-vertex AO.
///
/// Samples both the classic outward+1 face-plane (8 cells) and the
/// outward+2 slab (8 cells), then per vertex picks 3 from each and feeds
/// them to `aoMooreValue`. Where classic only sees the slice immediately
/// beyond the face, Moore can also detect:
///   - distant walls just behind the face plane (overhang shadows)
///   - long crevices where the deeper slab is occluded
///   - 2-cell-deep concave corners (e.g. a 1×N×1 vertical shaft) — the
///     middle-row vertices on the wall faces darken because both near and
///     far slabs are partially solid.
///
/// Cost: 16 isSolid samples per face (vs 8 for classic). Mesh-time only,
/// no GPU cost — the result is baked into the per-vertex `ao` field as
/// usual. Indoor corners and overhang vertices come out visibly darker;
/// flat unoccluded faces are unchanged because both slabs read all-air.
fn computeFaceAOMoore(chunk: *const Chunk, getter: BlockGetter, world_ox: i32, world_oz: i32, wx: i32, wy: i32, wz: i32, face: Face) [4]f32 {
    return switch (face) {
        .px => blk: {
            // Near plane: x = wx + 1   |   Far plane: x = wx + 2
            const s_ym = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz);
            const s_yp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz);
            const s_zm = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy, wz - 1);
            const s_zp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy, wz + 1);
            const s_ym_zm = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz - 1);
            const s_yp_zm = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz - 1);
            const s_yp_zp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz + 1);
            const s_ym_zp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz + 1);
            const d_ym = isSolid(chunk, getter, world_ox, world_oz, wx + 2, wy - 1, wz);
            const d_yp = isSolid(chunk, getter, world_ox, world_oz, wx + 2, wy + 1, wz);
            const d_zm = isSolid(chunk, getter, world_ox, world_oz, wx + 2, wy, wz - 1);
            const d_zp = isSolid(chunk, getter, world_ox, world_oz, wx + 2, wy, wz + 1);
            const d_ym_zm = isSolid(chunk, getter, world_ox, world_oz, wx + 2, wy - 1, wz - 1);
            const d_yp_zm = isSolid(chunk, getter, world_ox, world_oz, wx + 2, wy + 1, wz - 1);
            const d_yp_zp = isSolid(chunk, getter, world_ox, world_oz, wx + 2, wy + 1, wz + 1);
            const d_ym_zp = isSolid(chunk, getter, world_ox, world_oz, wx + 2, wy - 1, wz + 1);
            break :blk .{
                aoMooreValue(s_ym, s_zm, s_ym_zm, d_ym, d_zm, d_ym_zm), // v0
                aoMooreValue(s_yp, s_zm, s_yp_zm, d_yp, d_zm, d_yp_zm), // v1
                aoMooreValue(s_yp, s_zp, s_yp_zp, d_yp, d_zp, d_yp_zp), // v2
                aoMooreValue(s_ym, s_zp, s_ym_zp, d_ym, d_zp, d_ym_zp), // v3
            };
        },
        .nx => blk: {
            // Near plane: x = wx - 1   |   Far plane: x = wx - 2
            const s_ym = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz);
            const s_yp = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz);
            const s_zm = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy, wz - 1);
            const s_zp = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy, wz + 1);
            const s_ym_zm = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz - 1);
            const s_yp_zm = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz - 1);
            const s_yp_zp = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz + 1);
            const s_ym_zp = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz + 1);
            const d_ym = isSolid(chunk, getter, world_ox, world_oz, wx - 2, wy - 1, wz);
            const d_yp = isSolid(chunk, getter, world_ox, world_oz, wx - 2, wy + 1, wz);
            const d_zm = isSolid(chunk, getter, world_ox, world_oz, wx - 2, wy, wz - 1);
            const d_zp = isSolid(chunk, getter, world_ox, world_oz, wx - 2, wy, wz + 1);
            const d_ym_zm = isSolid(chunk, getter, world_ox, world_oz, wx - 2, wy - 1, wz - 1);
            const d_yp_zm = isSolid(chunk, getter, world_ox, world_oz, wx - 2, wy + 1, wz - 1);
            const d_yp_zp = isSolid(chunk, getter, world_ox, world_oz, wx - 2, wy + 1, wz + 1);
            const d_ym_zp = isSolid(chunk, getter, world_ox, world_oz, wx - 2, wy - 1, wz + 1);
            break :blk .{
                aoMooreValue(s_ym, s_zp, s_ym_zp, d_ym, d_zp, d_ym_zp),
                aoMooreValue(s_yp, s_zp, s_yp_zp, d_yp, d_zp, d_yp_zp),
                aoMooreValue(s_yp, s_zm, s_yp_zm, d_yp, d_zm, d_yp_zm),
                aoMooreValue(s_ym, s_zm, s_ym_zm, d_ym, d_zm, d_ym_zm),
            };
        },
        .py => blk: {
            // Near plane: y = wy + 1   |   Far plane: y = wy + 2
            const s_xm = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz);
            const s_xp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz);
            const s_zm = isSolid(chunk, getter, world_ox, world_oz, wx, wy + 1, wz - 1);
            const s_zp = isSolid(chunk, getter, world_ox, world_oz, wx, wy + 1, wz + 1);
            const s_xm_zm = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz - 1);
            const s_xm_zp = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz + 1);
            const s_xp_zp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz + 1);
            const s_xp_zm = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz - 1);
            const d_xm = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy + 2, wz);
            const d_xp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy + 2, wz);
            const d_zm = isSolid(chunk, getter, world_ox, world_oz, wx, wy + 2, wz - 1);
            const d_zp = isSolid(chunk, getter, world_ox, world_oz, wx, wy + 2, wz + 1);
            const d_xm_zm = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy + 2, wz - 1);
            const d_xm_zp = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy + 2, wz + 1);
            const d_xp_zp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy + 2, wz + 1);
            const d_xp_zm = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy + 2, wz - 1);
            break :blk .{
                aoMooreValue(s_xm, s_zm, s_xm_zm, d_xm, d_zm, d_xm_zm),
                aoMooreValue(s_xm, s_zp, s_xm_zp, d_xm, d_zp, d_xm_zp),
                aoMooreValue(s_xp, s_zp, s_xp_zp, d_xp, d_zp, d_xp_zp),
                aoMooreValue(s_xp, s_zm, s_xp_zm, d_xp, d_zm, d_xp_zm),
            };
        },
        .ny => blk: {
            // Near plane: y = wy - 1   |   Far plane: y = wy - 2
            const s_xm = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz);
            const s_xp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz);
            const s_zm = isSolid(chunk, getter, world_ox, world_oz, wx, wy - 1, wz - 1);
            const s_zp = isSolid(chunk, getter, world_ox, world_oz, wx, wy - 1, wz + 1);
            const s_xm_zm = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz - 1);
            const s_xm_zp = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz + 1);
            const s_xp_zm = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz - 1);
            const s_xp_zp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz + 1);
            const d_xm = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy - 2, wz);
            const d_xp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy - 2, wz);
            const d_zm = isSolid(chunk, getter, world_ox, world_oz, wx, wy - 2, wz - 1);
            const d_zp = isSolid(chunk, getter, world_ox, world_oz, wx, wy - 2, wz + 1);
            const d_xm_zm = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy - 2, wz - 1);
            const d_xm_zp = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy - 2, wz + 1);
            const d_xp_zm = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy - 2, wz - 1);
            const d_xp_zp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy - 2, wz + 1);
            break :blk .{
                aoMooreValue(s_xm, s_zp, s_xm_zp, d_xm, d_zp, d_xm_zp),
                aoMooreValue(s_xm, s_zm, s_xm_zm, d_xm, d_zm, d_xm_zm),
                aoMooreValue(s_xp, s_zm, s_xp_zm, d_xp, d_zm, d_xp_zm),
                aoMooreValue(s_xp, s_zp, s_xp_zp, d_xp, d_zp, d_xp_zp),
            };
        },
        .pz => blk: {
            // Near plane: z = wz + 1   |   Far plane: z = wz + 2
            const s_xm = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy, wz + 1);
            const s_xp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy, wz + 1);
            const s_ym = isSolid(chunk, getter, world_ox, world_oz, wx, wy - 1, wz + 1);
            const s_yp = isSolid(chunk, getter, world_ox, world_oz, wx, wy + 1, wz + 1);
            const s_xm_ym = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz + 1);
            const s_xp_ym = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz + 1);
            const s_xp_yp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz + 1);
            const s_xm_yp = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz + 1);
            const d_xm = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy, wz + 2);
            const d_xp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy, wz + 2);
            const d_ym = isSolid(chunk, getter, world_ox, world_oz, wx, wy - 1, wz + 2);
            const d_yp = isSolid(chunk, getter, world_ox, world_oz, wx, wy + 1, wz + 2);
            const d_xm_ym = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz + 2);
            const d_xp_ym = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz + 2);
            const d_xp_yp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz + 2);
            const d_xm_yp = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz + 2);
            break :blk .{
                aoMooreValue(s_xm, s_ym, s_xm_ym, d_xm, d_ym, d_xm_ym),
                aoMooreValue(s_xp, s_ym, s_xp_ym, d_xp, d_ym, d_xp_ym),
                aoMooreValue(s_xp, s_yp, s_xp_yp, d_xp, d_yp, d_xp_yp),
                aoMooreValue(s_xm, s_yp, s_xm_yp, d_xm, d_yp, d_xm_yp),
            };
        },
        .nz => blk: {
            // Near plane: z = wz - 1   |   Far plane: z = wz - 2
            const s_xm = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy, wz - 1);
            const s_xp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy, wz - 1);
            const s_ym = isSolid(chunk, getter, world_ox, world_oz, wx, wy - 1, wz - 1);
            const s_yp = isSolid(chunk, getter, world_ox, world_oz, wx, wy + 1, wz - 1);
            const s_xm_ym = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz - 1);
            const s_xp_ym = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz - 1);
            const s_xm_yp = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz - 1);
            const s_xp_yp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz - 1);
            const d_xm = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy, wz - 2);
            const d_xp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy, wz - 2);
            const d_ym = isSolid(chunk, getter, world_ox, world_oz, wx, wy - 1, wz - 2);
            const d_yp = isSolid(chunk, getter, world_ox, world_oz, wx, wy + 1, wz - 2);
            const d_xm_ym = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz - 2);
            const d_xp_ym = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz - 2);
            const d_xm_yp = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz - 2);
            const d_xp_yp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz - 2);
            break :blk .{
                aoMooreValue(s_xp, s_ym, s_xp_ym, d_xp, d_ym, d_xp_ym),
                aoMooreValue(s_xm, s_ym, s_xm_ym, d_xm, d_ym, d_xm_ym),
                aoMooreValue(s_xm, s_yp, s_xm_yp, d_xm, d_yp, d_xm_yp),
                aoMooreValue(s_xp, s_yp, s_xp_yp, d_xp, d_yp, d_xp_yp),
            };
        },
    };
}

/// Propagated per-vertex AO formula.
///
/// Extends the Moore two-slab approach to a third slab at outward+3, with
/// geometrically-decaying weights (1.0, 0.5, 0.25).  The hard-zero on
/// `s1 ∧ s2` (immediate face-touching corner contact) is preserved from
/// classic/moore so concave hard corners stay maximally dark.
///
///   occlusion = (near_occ × 1.0) + (mid_occ × 0.5) + (far_occ × 0.25)
///   near/mid/far each ∈ [0, 3]
///   max_occ = 3×1.0 + 3×0.5 + 3×0.25 = 5.25
///   ao = clamp((max_occ - occlusion) / max_occ, 0, 1)
///
/// On flat open terrain all three slabs return air so near=mid=far=0 and
/// ao=1.0 — identical to classic/moore, no regression.  In indoor corners
/// the third slab picks up the ceiling/walls two more hops out, darkening
/// the shadowed pocket smoothly over ~3 blocks instead of the moore's ~2.
fn aoPropValue(
    s1: bool,
    s2: bool,
    c: bool,
    ds1: bool,
    ds2: bool,
    dc: bool,
    fs1: bool,
    fs2: bool,
    fc: bool,
) f32 {
    if (s1 and s2) return 0.0;
    const near: f32 = @floatFromInt(@as(u32, @intFromBool(s1)) + @as(u32, @intFromBool(s2)) + @as(u32, @intFromBool(c)));
    const mid: f32 = @floatFromInt(@as(u32, @intFromBool(ds1)) + @as(u32, @intFromBool(ds2)) + @as(u32, @intFromBool(dc)));
    const far: f32 = @floatFromInt(@as(u32, @intFromBool(fs1)) + @as(u32, @intFromBool(fs2)) + @as(u32, @intFromBool(fc)));
    const occ = near * 1.0 + mid * 0.5 + far * 0.25;
    const max_occ: f32 = 3.0 * 1.0 + 3.0 * 0.5 + 3.0 * 0.25; // 5.25
    return std.math.clamp((max_occ - occ) / max_occ, 0.0, 1.0);
}

/// Propagated per-vertex AO for a face quad. Three concentric face-plane
/// slabs at outward+1, +2, +3, weighted 1.0 / 0.5 / 0.25. Returns [4]f32
/// in the corner order of face_layouts.
fn computeFaceAOPropagated(chunk: *const Chunk, getter: BlockGetter, world_ox: i32, world_oz: i32, wx: i32, wy: i32, wz: i32, face: Face) [4]f32 {
    return switch (face) {
        .px => blk: {
            // Near (+1), mid (+2), far (+3) planes, all at varying Y and Z.
            const n_ym = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz);
            const n_yp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz);
            const n_zm = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy, wz - 1);
            const n_zp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy, wz + 1);
            const n_ym_zm = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz - 1);
            const n_yp_zm = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz - 1);
            const n_yp_zp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz + 1);
            const n_ym_zp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz + 1);
            const m_ym = isSolid(chunk, getter, world_ox, world_oz, wx + 2, wy - 1, wz);
            const m_yp = isSolid(chunk, getter, world_ox, world_oz, wx + 2, wy + 1, wz);
            const m_zm = isSolid(chunk, getter, world_ox, world_oz, wx + 2, wy, wz - 1);
            const m_zp = isSolid(chunk, getter, world_ox, world_oz, wx + 2, wy, wz + 1);
            const m_ym_zm = isSolid(chunk, getter, world_ox, world_oz, wx + 2, wy - 1, wz - 1);
            const m_yp_zm = isSolid(chunk, getter, world_ox, world_oz, wx + 2, wy + 1, wz - 1);
            const m_yp_zp = isSolid(chunk, getter, world_ox, world_oz, wx + 2, wy + 1, wz + 1);
            const m_ym_zp = isSolid(chunk, getter, world_ox, world_oz, wx + 2, wy - 1, wz + 1);
            const f_ym = isSolid(chunk, getter, world_ox, world_oz, wx + 3, wy - 1, wz);
            const f_yp = isSolid(chunk, getter, world_ox, world_oz, wx + 3, wy + 1, wz);
            const f_zm = isSolid(chunk, getter, world_ox, world_oz, wx + 3, wy, wz - 1);
            const f_zp = isSolid(chunk, getter, world_ox, world_oz, wx + 3, wy, wz + 1);
            const f_ym_zm = isSolid(chunk, getter, world_ox, world_oz, wx + 3, wy - 1, wz - 1);
            const f_yp_zm = isSolid(chunk, getter, world_ox, world_oz, wx + 3, wy + 1, wz - 1);
            const f_yp_zp = isSolid(chunk, getter, world_ox, world_oz, wx + 3, wy + 1, wz + 1);
            const f_ym_zp = isSolid(chunk, getter, world_ox, world_oz, wx + 3, wy - 1, wz + 1);
            break :blk .{
                aoPropValue(n_ym, n_zm, n_ym_zm, m_ym, m_zm, m_ym_zm, f_ym, f_zm, f_ym_zm),
                aoPropValue(n_yp, n_zm, n_yp_zm, m_yp, m_zm, m_yp_zm, f_yp, f_zm, f_yp_zm),
                aoPropValue(n_yp, n_zp, n_yp_zp, m_yp, m_zp, m_yp_zp, f_yp, f_zp, f_yp_zp),
                aoPropValue(n_ym, n_zp, n_ym_zp, m_ym, m_zp, m_ym_zp, f_ym, f_zp, f_ym_zp),
            };
        },
        .nx => blk: {
            const n_ym = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz);
            const n_yp = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz);
            const n_zm = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy, wz - 1);
            const n_zp = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy, wz + 1);
            const n_ym_zm = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz - 1);
            const n_yp_zm = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz - 1);
            const n_yp_zp = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz + 1);
            const n_ym_zp = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz + 1);
            const m_ym = isSolid(chunk, getter, world_ox, world_oz, wx - 2, wy - 1, wz);
            const m_yp = isSolid(chunk, getter, world_ox, world_oz, wx - 2, wy + 1, wz);
            const m_zm = isSolid(chunk, getter, world_ox, world_oz, wx - 2, wy, wz - 1);
            const m_zp = isSolid(chunk, getter, world_ox, world_oz, wx - 2, wy, wz + 1);
            const m_ym_zm = isSolid(chunk, getter, world_ox, world_oz, wx - 2, wy - 1, wz - 1);
            const m_yp_zm = isSolid(chunk, getter, world_ox, world_oz, wx - 2, wy + 1, wz - 1);
            const m_yp_zp = isSolid(chunk, getter, world_ox, world_oz, wx - 2, wy + 1, wz + 1);
            const m_ym_zp = isSolid(chunk, getter, world_ox, world_oz, wx - 2, wy - 1, wz + 1);
            const f_ym = isSolid(chunk, getter, world_ox, world_oz, wx - 3, wy - 1, wz);
            const f_yp = isSolid(chunk, getter, world_ox, world_oz, wx - 3, wy + 1, wz);
            const f_zm = isSolid(chunk, getter, world_ox, world_oz, wx - 3, wy, wz - 1);
            const f_zp = isSolid(chunk, getter, world_ox, world_oz, wx - 3, wy, wz + 1);
            const f_ym_zm = isSolid(chunk, getter, world_ox, world_oz, wx - 3, wy - 1, wz - 1);
            const f_yp_zm = isSolid(chunk, getter, world_ox, world_oz, wx - 3, wy + 1, wz - 1);
            const f_yp_zp = isSolid(chunk, getter, world_ox, world_oz, wx - 3, wy + 1, wz + 1);
            const f_ym_zp = isSolid(chunk, getter, world_ox, world_oz, wx - 3, wy - 1, wz + 1);
            break :blk .{
                aoPropValue(n_ym, n_zp, n_ym_zp, m_ym, m_zp, m_ym_zp, f_ym, f_zp, f_ym_zp),
                aoPropValue(n_yp, n_zp, n_yp_zp, m_yp, m_zp, m_yp_zp, f_yp, f_zp, f_yp_zp),
                aoPropValue(n_yp, n_zm, n_yp_zm, m_yp, m_zm, m_yp_zm, f_yp, f_zm, f_yp_zm),
                aoPropValue(n_ym, n_zm, n_ym_zm, m_ym, m_zm, m_ym_zm, f_ym, f_zm, f_ym_zm),
            };
        },
        .py => blk: {
            const n_xm = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz);
            const n_xp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz);
            const n_zm = isSolid(chunk, getter, world_ox, world_oz, wx, wy + 1, wz - 1);
            const n_zp = isSolid(chunk, getter, world_ox, world_oz, wx, wy + 1, wz + 1);
            const n_xm_zm = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz - 1);
            const n_xm_zp = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz + 1);
            const n_xp_zp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz + 1);
            const n_xp_zm = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz - 1);
            const m_xm = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy + 2, wz);
            const m_xp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy + 2, wz);
            const m_zm = isSolid(chunk, getter, world_ox, world_oz, wx, wy + 2, wz - 1);
            const m_zp = isSolid(chunk, getter, world_ox, world_oz, wx, wy + 2, wz + 1);
            const m_xm_zm = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy + 2, wz - 1);
            const m_xm_zp = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy + 2, wz + 1);
            const m_xp_zp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy + 2, wz + 1);
            const m_xp_zm = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy + 2, wz - 1);
            const f_xm = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy + 3, wz);
            const f_xp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy + 3, wz);
            const f_zm = isSolid(chunk, getter, world_ox, world_oz, wx, wy + 3, wz - 1);
            const f_zp = isSolid(chunk, getter, world_ox, world_oz, wx, wy + 3, wz + 1);
            const f_xm_zm = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy + 3, wz - 1);
            const f_xm_zp = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy + 3, wz + 1);
            const f_xp_zp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy + 3, wz + 1);
            const f_xp_zm = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy + 3, wz - 1);
            break :blk .{
                aoPropValue(n_xm, n_zm, n_xm_zm, m_xm, m_zm, m_xm_zm, f_xm, f_zm, f_xm_zm),
                aoPropValue(n_xm, n_zp, n_xm_zp, m_xm, m_zp, m_xm_zp, f_xm, f_zp, f_xm_zp),
                aoPropValue(n_xp, n_zp, n_xp_zp, m_xp, m_zp, m_xp_zp, f_xp, f_zp, f_xp_zp),
                aoPropValue(n_xp, n_zm, n_xp_zm, m_xp, m_zm, m_xp_zm, f_xp, f_zm, f_xp_zm),
            };
        },
        .ny => blk: {
            const n_xm = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz);
            const n_xp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz);
            const n_zm = isSolid(chunk, getter, world_ox, world_oz, wx, wy - 1, wz - 1);
            const n_zp = isSolid(chunk, getter, world_ox, world_oz, wx, wy - 1, wz + 1);
            const n_xm_zm = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz - 1);
            const n_xm_zp = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz + 1);
            const n_xp_zm = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz - 1);
            const n_xp_zp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz + 1);
            const m_xm = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy - 2, wz);
            const m_xp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy - 2, wz);
            const m_zm = isSolid(chunk, getter, world_ox, world_oz, wx, wy - 2, wz - 1);
            const m_zp = isSolid(chunk, getter, world_ox, world_oz, wx, wy - 2, wz + 1);
            const m_xm_zm = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy - 2, wz - 1);
            const m_xm_zp = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy - 2, wz + 1);
            const m_xp_zm = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy - 2, wz - 1);
            const m_xp_zp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy - 2, wz + 1);
            const f_xm = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy - 3, wz);
            const f_xp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy - 3, wz);
            const f_zm = isSolid(chunk, getter, world_ox, world_oz, wx, wy - 3, wz - 1);
            const f_zp = isSolid(chunk, getter, world_ox, world_oz, wx, wy - 3, wz + 1);
            const f_xm_zm = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy - 3, wz - 1);
            const f_xm_zp = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy - 3, wz + 1);
            const f_xp_zm = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy - 3, wz - 1);
            const f_xp_zp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy - 3, wz + 1);
            break :blk .{
                aoPropValue(n_xm, n_zp, n_xm_zp, m_xm, m_zp, m_xm_zp, f_xm, f_zp, f_xm_zp),
                aoPropValue(n_xm, n_zm, n_xm_zm, m_xm, m_zm, m_xm_zm, f_xm, f_zm, f_xm_zm),
                aoPropValue(n_xp, n_zm, n_xp_zm, m_xp, m_zm, m_xp_zm, f_xp, f_zm, f_xp_zm),
                aoPropValue(n_xp, n_zp, n_xp_zp, m_xp, m_zp, m_xp_zp, f_xp, f_zp, f_xp_zp),
            };
        },
        .pz => blk: {
            const n_xm = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy, wz + 1);
            const n_xp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy, wz + 1);
            const n_ym = isSolid(chunk, getter, world_ox, world_oz, wx, wy - 1, wz + 1);
            const n_yp = isSolid(chunk, getter, world_ox, world_oz, wx, wy + 1, wz + 1);
            const n_xm_ym = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz + 1);
            const n_xp_ym = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz + 1);
            const n_xp_yp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz + 1);
            const n_xm_yp = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz + 1);
            const m_xm = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy, wz + 2);
            const m_xp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy, wz + 2);
            const m_ym = isSolid(chunk, getter, world_ox, world_oz, wx, wy - 1, wz + 2);
            const m_yp = isSolid(chunk, getter, world_ox, world_oz, wx, wy + 1, wz + 2);
            const m_xm_ym = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz + 2);
            const m_xp_ym = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz + 2);
            const m_xp_yp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz + 2);
            const m_xm_yp = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz + 2);
            const f_xm = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy, wz + 3);
            const f_xp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy, wz + 3);
            const f_ym = isSolid(chunk, getter, world_ox, world_oz, wx, wy - 1, wz + 3);
            const f_yp = isSolid(chunk, getter, world_ox, world_oz, wx, wy + 1, wz + 3);
            const f_xm_ym = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz + 3);
            const f_xp_ym = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz + 3);
            const f_xp_yp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz + 3);
            const f_xm_yp = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz + 3);
            break :blk .{
                aoPropValue(n_xm, n_ym, n_xm_ym, m_xm, m_ym, m_xm_ym, f_xm, f_ym, f_xm_ym),
                aoPropValue(n_xp, n_ym, n_xp_ym, m_xp, m_ym, m_xp_ym, f_xp, f_ym, f_xp_ym),
                aoPropValue(n_xp, n_yp, n_xp_yp, m_xp, m_yp, m_xp_yp, f_xp, f_yp, f_xp_yp),
                aoPropValue(n_xm, n_yp, n_xm_yp, m_xm, m_yp, m_xm_yp, f_xm, f_yp, f_xm_yp),
            };
        },
        .nz => blk: {
            const n_xm = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy, wz - 1);
            const n_xp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy, wz - 1);
            const n_ym = isSolid(chunk, getter, world_ox, world_oz, wx, wy - 1, wz - 1);
            const n_yp = isSolid(chunk, getter, world_ox, world_oz, wx, wy + 1, wz - 1);
            const n_xm_ym = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz - 1);
            const n_xp_ym = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz - 1);
            const n_xm_yp = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz - 1);
            const n_xp_yp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz - 1);
            const m_xm = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy, wz - 2);
            const m_xp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy, wz - 2);
            const m_ym = isSolid(chunk, getter, world_ox, world_oz, wx, wy - 1, wz - 2);
            const m_yp = isSolid(chunk, getter, world_ox, world_oz, wx, wy + 1, wz - 2);
            const m_xm_ym = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz - 2);
            const m_xp_ym = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz - 2);
            const m_xm_yp = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz - 2);
            const m_xp_yp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz - 2);
            const f_xm = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy, wz - 3);
            const f_xp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy, wz - 3);
            const f_ym = isSolid(chunk, getter, world_ox, world_oz, wx, wy - 1, wz - 3);
            const f_yp = isSolid(chunk, getter, world_ox, world_oz, wx, wy + 1, wz - 3);
            const f_xm_ym = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz - 3);
            const f_xp_ym = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz - 3);
            const f_xm_yp = isSolid(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz - 3);
            const f_xp_yp = isSolid(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz - 3);
            break :blk .{
                aoPropValue(n_xp, n_ym, n_xp_ym, m_xp, m_ym, m_xp_ym, f_xp, f_ym, f_xp_ym),
                aoPropValue(n_xm, n_ym, n_xm_ym, m_xm, m_ym, m_xm_ym, f_xm, f_ym, f_xm_ym),
                aoPropValue(n_xm, n_yp, n_xm_yp, m_xm, m_yp, m_xm_yp, f_xm, f_yp, f_xm_yp),
                aoPropValue(n_xp, n_yp, n_xp_yp, m_xp, m_yp, m_xp_yp, f_xp, f_yp, f_xp_yp),
            };
        },
    };
}

// ---------------------------------------------------------------------------
// Light sampling (REQ-VOXEL-008)
// ---------------------------------------------------------------------------

/// The light of the cell at (wx, wy, wz): x and z in the coordinates of the
/// getter, y local. A cell in the chunk reads the chunk directly. A cell
/// out of the chunk reads the getter, so the sample crosses the chunk edge.
fn lightSample(chunk: *const Chunk, getter: BlockGetter, world_ox: i32, world_oz: i32, wx: i32, wy: i32, wz: i32) CellLight {
    const lx = wx - world_ox;
    const lz = wz - world_oz;
    if (lx >= 0 and lx < CHUNK_W and wy >= 0 and wy < CHUNK_H and lz >= 0 and lz < CHUNK_W) {
        // The cell is in the chunk: the grids with no second bounds check
        // (the values of Chunk.lightAt).
        const x: u32 = @intCast(lx);
        const y: u32 = @intCast(wy);
        const z: u32 = @intCast(lz);
        return .{ .sky = chunk.skylight.get(x, y, z), .block = chunk.block_light.get(x, y, z) };
    }
    return getter.lightAt(wx, wy + MIN_Y, wz);
}

/// The sky light and the block light of the 4 corners of a face, 0 to 1,
/// in the corner order of face_layouts.
const FaceLight = struct {
    sky: [4]f32,
    bl: [4]f32,

    /// Full sky light and no block light: the light with lighting off.
    const off: FaceLight = .{ .sky = @splat(1.0), .bl = @splat(0.0) };
};

/// Smooth light of a face: for each corner, the mean light of the 4 cells
/// that touch the corner on the outward side of the face (the face plane
/// slab one cell out). A solid cell has light 0, so a corner against a wall
/// gets darker. The light of the 9 cells comes from the light engine
/// (`lightAt`).
///
/// The block light of a corner is also at least the block light of the
/// cell that owns the face. A face of an emitter then shows the light of
/// the emitter, not the light one step out:
///
///     block_light[i] = max(outward_mean[i], owner_level)
fn computeFaceLight(chunk: *const Chunk, getter: BlockGetter, world_ox: i32, world_oz: i32, wx: i32, wy: i32, wz: i32, face: Face) FaceLight {
    return switch (face) {
        inline else => |f| computeFaceLightOf(f, chunk, getter, world_ox, world_oz, wx, wy, wz),
    };
}

/// computeFaceLight for a face that is known at compile time, so that the
/// sample offsets are constants.
fn computeFaceLightOf(comptime face: Face, chunk: *const Chunk, getter: BlockGetter, world_ox: i32, world_oz: i32, wx: i32, wy: i32, wz: i32) FaceLight {
    const fl = comptime face_layouts[@backingInt(face)];
    const off = comptime face_offsets[@backingInt(face)];
    // The 3 × 3 cells of the outward slab, by step -1, 0, 1 along i and j.
    var sky: [3][3]u32 = undefined;
    var blk: [3][3]u32 = undefined;
    inline for (0..3) |di| inline for (0..3) |dj| {
        var p = [3]i32{ wx + off[0], wy + off[1], wz + off[2] };
        p[fl.i_axis] += @as(i32, @intCast(di)) - 1;
        p[fl.j_axis] += @as(i32, @intCast(dj)) - 1;
        const l = lightSample(chunk, getter, world_ox, world_oz, p[0], p[1], p[2]);
        sky[di][dj] = l.sky;
        blk[di][dj] = l.block;
    };
    const owner = lightSample(chunk, getter, world_ox, world_oz, wx, wy, wz).block;
    const sky_max: f32 = @floatFromInt(chunk_mod.MAX_SKYLIGHT);
    const bl_max: f32 = @floatFromInt(chunk_mod.MAX_BLOCK_LIGHT);
    const owner_norm = @as(f32, @floatFromInt(owner)) / bl_max;
    const inv4: f32 = 1.0 / 4.0;
    var out: FaceLight = undefined;
    inline for (0..4) |c| {
        // A corner at step s along an axis touches the cells at steps
        // s - 1 and s, which are indices s and s + 1.
        const si: usize = fl.pos[c][0];
        const sj: usize = fl.pos[c][1];
        const s_sum = sky[si][sj] + sky[si + 1][sj] + sky[si][sj + 1] + sky[si + 1][sj + 1];
        const b_sum = blk[si][sj] + blk[si + 1][sj] + blk[si][sj + 1] + blk[si + 1][sj + 1];
        out.sky[c] = @as(f32, @floatFromInt(s_sum)) * inv4 / sky_max;
        out.bl[c] = @max(@as(f32, @floatFromInt(b_sum)) * inv4 / bl_max, owner_norm);
    }
    return out;
}

/// Flat light of a face (smooth light off): the light of the cell in front
/// of the face, the same for the 4 corners. The block light is at least
/// the block light of the owner cell, as for smooth light.
fn computeFlatLight(chunk: *const Chunk, getter: BlockGetter, world_ox: i32, world_oz: i32, wx: i32, wy: i32, wz: i32, face: Face) FaceLight {
    const off = face_offsets[@backingInt(face)];
    const front = lightSample(chunk, getter, world_ox, world_oz, wx + off[0], wy + off[1], wz + off[2]);
    const owner = lightSample(chunk, getter, world_ox, world_oz, wx, wy, wz).block;
    const sky = @as(f32, @floatFromInt(front.sky)) / @as(f32, @floatFromInt(chunk_mod.MAX_SKYLIGHT));
    const bl = @as(f32, @floatFromInt(@max(front.block, owner))) / @as(f32, @floatFromInt(chunk_mod.MAX_BLOCK_LIGHT));
    return .{ .sky = @splat(sky), .bl = @splat(bl) };
}

/// The light of a face with the mesh options: off, flat or smooth.
fn faceLight(chunk: *const Chunk, getter: BlockGetter, world_ox: i32, world_oz: i32, wx: i32, wy: i32, wz: i32, face: Face, options: MeshOptions) FaceLight {
    return switch (options.lighting) {
        .none => FaceLight.off,
        .skylight => if (options.smooth_light)
            computeFaceLight(chunk, getter, world_ox, world_oz, wx, wy, wz, face)
        else
            computeFlatLight(chunk, getter, world_ox, world_oz, wx, wy, wz, face),
    };
}

// ---------------------------------------------------------------------------
// Tints (REQ-VOXEL-009)
// ---------------------------------------------------------------------------

/// The tint colour of a quad with no tint.
const NO_TINT: u32 = 0xFFFF_FFFF;

/// The tint colour of a quad with tint index `tint_index` of `block` at the
/// world cell (x, y, z), as red | green << 8 | blue << 16, or NO_TINT.
fn tintColor(block: BlockType, tint_index: i8, x: i32, y: i32, z: i32) u32 {
    if (!content.has_tint or tint_index < 0) return NO_TINT;
    const rgb = content.tint(block, @intCast(tint_index), x, y, z);
    return @as(u32, rgb[0]) | (@as(u32, rgb[1]) << 8) | (@as(u32, rgb[2]) << 16);
}

/// The tint colours of one mesh. A quad holds a slot of the palette (1 to
/// MAX_TINT_SLOTS, 0 is no tint), and the mesh starts with tint records
/// that hold the colours (see "Tint records" below). When the palette is
/// full, a new colour gets the slot of the nearest colour in the palette.
const TintPalette = struct {
    colors: [MAX_TINT_SLOTS]u32 = undefined,
    len: usize = 0,

    /// The slot of `rgb`: 0 for NO_TINT, else 1 to MAX_TINT_SLOTS.
    fn slot(self: *TintPalette, rgb: u32) u32 {
        if (rgb == NO_TINT) return 0;
        for (self.colors[0..self.len], 0..) |c, i| {
            if (c == rgb) return @intCast(i + 1);
        }
        if (self.len < MAX_TINT_SLOTS) {
            self.colors[self.len] = rgb;
            self.len += 1;
            return @intCast(self.len);
        }
        // Full: the nearest colour, the lowest slot on a tie.
        var best: usize = 0;
        var best_d: u32 = std.math.maxInt(u32);
        for (self.colors, 0..) |c, i| {
            var d: u32 = 0;
            inline for (0..3) |k| {
                const a: i32 = @intCast((c >> (8 * k)) & 0xFF);
                const b: i32 = @intCast((rgb >> (8 * k)) & 0xFF);
                d += @intCast((a - b) * (a - b));
            }
            if (d < best_d) {
                best_d = d;
                best = i;
            }
        }
        return @intCast(best + 1);
    }

    /// Put the tint records at the start of the quads of `mesh`. The
    /// record of slots 4k + 1 to 4k + 4 is at index k.
    fn writeRecords(self: *const TintPalette, mesh: *Mesh) !void {
        if (self.len == 0) return;
        const n = (self.len + 3) / 4;
        var records: [(MAX_TINT_SLOTS + 3) / 4]PackedQuad = @splat(.{ 0, 0, 0, 0 });
        for (self.colors[0..self.len], 0..) |c, i| records[i / 4][i % 4] = c;
        for (records[0..n]) |*r| r[3] |= TINT_RECORD_SLOT << TINT_SLOT_SHIFT;
        try mesh.quads.insertSlice(mesh.allocator, 0, records[0..n]);
        mesh.shiftRanges(n);
    }
};

// ---------------------------------------------------------------------------
// Greedy meshing
// ---------------------------------------------------------------------------

/// A single face candidate in a 2D greedy-merge plane. Holds everything needed
/// to decide whether two adjacent cells may merge: block type, per-vertex AO,
/// per-vertex skylight, per-vertex block-light and the tint colour. Two cells
/// merge iff every f32 byte in the lighting tuples is bit-identical AND the
/// block types and the tints match (REQ-VOXEL-010).
const GreedyCell = struct {
    present: bool = false,
    block_type: BlockType = .air,
    ao: [4]f32 = .{ 0, 0, 0, 0 },
    sky: [4]f32 = .{ 0, 0, 0, 0 },
    /// Per-vertex block-light brightness 0..1. Baked from the chunk's
    /// `block_light` grid (seeded by emissive blocks, BFS-propagated through
    /// air). Omitting this from the merge key was the P0 bug: all greedy quads
    /// defaulted to block_light=0 even near an emissive block.
    bl: [4]f32 = .{ 0, 0, 0, 0 },
    /// The tint colour (`tintColor`), or NO_TINT.
    tint: u32 = NO_TINT,
};

/// True iff all four corner values in `v` are bit-identical. Used to detect
/// cells that are shade-constant across their entire face — the only cells
/// that can be greedy-merged without breaking interpolation. See the long
/// comment on `greedyCellEq` for why we can't use the weaker "corners-match"
/// rule.
fn greedyUniform4(v: [4]f32) bool {
    return v[0] == v[1] and v[0] == v[2] and v[0] == v[3];
}

/// Decide whether two adjacent face cells may merge into the same greedy
/// rectangle (REQ-VOXEL-010). This rule is STRICTER than the classic
/// "matching corners" greedy rule: we only merge cells whose AO and light
/// are *uniform* (all four corners equal) AND whose uniform constants and
/// tint match the candidate cell. This is the only rule that guarantees
/// bilinear interpolation over a merged w × h quad reproduces the
/// piecewise-bilinear result of 1×1 quads (one quad per block face) at
/// every interior fragment, so merged quads show no seams.
///
/// Why the weaker rule fails: consider two adjacent cells that each have AO
/// quadruple [a, a, b, b] at corners (0,0)(0,1)(1,1)(1,0). 1×1 quads are two
/// separate quads, each with its own (a,a,b,b) gradient from a to b across
/// the cell. Merging them into a 2×1 rect with corners (a, a, b, b) means
/// the gradient now stretches over 2 units — the value at the center of
/// the left cell becomes a 75/25 mix of (a, b) instead of 50/50. RMS drift
/// is large enough to be visible. Requiring uniform-corner cells ducks this
/// entirely: a constant AO gives bilinear-interp == constant, same as 1×1 quads.
fn greedyCellEq(a: GreedyCell, b: GreedyCell) bool {
    if (!a.present or !b.present) return false;
    if (a.block_type != b.block_type) return false;
    if (a.tint != b.tint) return false;
    if (!greedyUniform4(a.ao) or !greedyUniform4(b.ao)) return false;
    if (!greedyUniform4(a.sky) or !greedyUniform4(b.sky)) return false;
    if (!greedyUniform4(a.bl) or !greedyUniform4(b.bl)) return false;
    if (a.ao[0] != b.ao[0]) return false;
    if (a.sky[0] != b.sky[0]) return false;
    if (a.bl[0] != b.bl[0]) return false;
    return true;
}

/// Compute the face cell signature for a block face at local (lx, ly, lz).
/// The light values are per corner, in the corner order of face_layouts.
/// The caller passes a visible face (VisibleFaces): `block` is not air and the
/// neighbour in the face direction is air.
fn computeGreedyCell(
    chunk: *const Chunk,
    getter: BlockGetter,
    world_ox: i32,
    world_oz: i32,
    lx: i32,
    ly: i32,
    lz: i32,
    face: Face,
    block: BlockType,
    options: MeshOptions,
) GreedyCell {
    const wx = world_ox + lx;
    const wz = world_oz + lz;
    const ao = computeFaceAOForStrategy(chunk, getter, world_ox, world_oz, wx, ly, wz, face, options.ao);
    const light = faceLight(chunk, getter, world_ox, world_oz, wx, ly, wz, face, options);
    const origin = options.originOr(world_ox, world_oz);
    return .{
        .present = true,
        .block_type = block,
        .ao = ao,
        .sky = light.sky,
        .bl = light.bl,
        .tint = tintColor(block, models.cubeTintIndex(block, face), origin[0] + lx, MIN_Y + ly, origin[1] + lz),
    };
}

/// Emit a merged greedy quad covering (w × h) blocks in the face's in-plane
/// (i, j) axes, as one PackedQuad. The cell of the quad is the (ia, ja)
/// corner block, and the light values of all 4 corners are the values of
/// that cell (greedyCellEq merges only cells with the same values).
fn emitGreedyQuad(
    mesh: *Mesh,
    palette: *TintPalette,
    face: Face,
    d: i32,
    ia: i32,
    ja: i32,
    w: i32,
    h: i32,
    cell: GreedyCell,
) !void {
    std.debug.assert(cell.present);
    std.debug.assert(cell.block_type != .air);
    std.debug.assert(w > 0 and h > 0);

    const corner = greedyIJToLocalBlock(face, d, ia, ja);
    var q = packQuad(
        face,
        .{ @intCast(corner.x), @intCast(corner.y), @intCast(corner.z) },
        @intCast(w),
        @intCast(h),
        @backingInt(cell.block_type),
        cell.ao,
        cell.sky,
        cell.bl,
    );
    q[3] |= palette.slot(cell.tint) << TINT_SLOT_SHIFT;
    // The world y range: a y face is one plane, the other faces span h
    // blocks of y.
    const y_lo: f32, const y_hi: f32 = switch (face) {
        .py => .{ @floatFromInt(MIN_Y + d + 1), @floatFromInt(MIN_Y + d + 1) },
        .ny => .{ @floatFromInt(MIN_Y + d), @floatFromInt(MIN_Y + d) },
        else => .{ @floatFromInt(MIN_Y + ja), @floatFromInt(MIN_Y + ja + h) },
    };
    try mesh.addQuad(q, y_lo, y_hi);
}

/// Translate (d, i, j) in a face's in-plane coordinate system to a local
/// (lx, ly, lz) block coord. Paired with the (u, v) → (i, j) mapping inside
/// each per-face branch of generateMesh.
fn greedyIJToLocalBlock(face: Face, d: i32, i: i32, j: i32) BlockPos {
    return switch (face) {
        .px, .nx => .{ .x = d, .y = j, .z = i }, // i = Z, j = Y
        .py, .ny => .{ .x = i, .y = d, .z = j }, // i = X, j = Z
        .pz, .nz => .{ .x = i, .y = j, .z = d }, // i = X, j = Y
    };
}

/// Return the (i_max, j_max, d_max) extents of each face's plane grid.
/// `d_max` is the number of plane slices, `i_max × j_max` is the size of
/// each slice.
fn greedyFaceExtents(face: Face) struct { i_max: i32, j_max: i32, d_max: i32 } {
    return switch (face) {
        // +X/-X slice on X: each slice is (Z × Y)
        .px, .nx => .{ .i_max = CHUNK_W, .j_max = CHUNK_H, .d_max = CHUNK_W },
        // +Y/-Y slice on Y: each slice is (X × Z)
        .py, .ny => .{ .i_max = CHUNK_W, .j_max = CHUNK_W, .d_max = CHUNK_H },
        // +Z/-Z slice on Z: each slice is (X × Y)
        .pz, .nz => .{ .i_max = CHUNK_W, .j_max = CHUNK_H, .d_max = CHUNK_W },
    };
}

/// One row of a greedy slice as bits: bit j in word j / 64 (j < CHUNK_H).
const Row = chunk_mod.Col;

fn rowGet(r: Row, j: usize) bool {
    return (r[j / 64] >> @intCast(j % 64)) & 1 != 0;
}

fn rowSet(r: *Row, j: usize) void {
    r[j / 64] |= @as(u64, 1) << @intCast(j % 64);
}

fn rowAndNot(a: Row, b: Row) Row {
    var out: Row = undefined;
    inline for (0..chunk_mod.COL_WORDS) |k| out[k] = a[k] & ~b[k];
    return out;
}

fn lowestBit(r: Row) ?usize {
    for (r, 0..) |word, k| {
        if (word != 0) return k * 64 + @ctz(word);
    }
    return null;
}

/// Iterator over the set bits of a row, lowest first.
fn rowBits(r: Row) RowBits {
    return .{ .r = r };
}

const RowBits = struct {
    r: Row,
    fn next(self: *RowBits) ?usize {
        const j = lowestBit(self.r) orelse return null;
        self.r[j / 64] &= self.r[j / 64] - 1;
        return j;
    }
};

/// Every visible face of a chunk, as bit masks: for each face direction and
/// column (x, z), bit y is set when the block at (x, y, z) is a full cube and
/// its neighbour in the face direction is not (air or a block with a model). Inside the chunk the masks come
/// from the solid masks of the column and its neighbour column (or the column
/// shifted by one for the y faces). At the chunk edge, the neighbour is in
/// another chunk: shouldRenderFace asks the getter, for full cubes only.
/// The result is the same as shouldRenderFace for every block, so the greedy
/// pass computes cells only where a face is visible.
const VisibleFaces = struct {
    /// [face][x][z]: CHUNK_H bits over y, bit y in word y / 64.
    masks: [6][CHUNK_W][CHUNK_W]Col,
    /// [face]: bit d is set when slice d has a visible face (d < CHUNK_H).
    nonempty: [6]Col,

    const Col = chunk_mod.Col;
    const zero: Col = @splat(0);
    /// The word and the bit of the top cell (y = CHUNK_H - 1).
    const TOP_WORD = (CHUNK_H - 1) / 64;
    const TOP_BIT: u6 = (CHUNK_H - 1) % 64;

    fn compute(allocator: std.mem.Allocator, chunk: *const Chunk, getter: BlockGetter, world_ox: i32, world_oz: i32) !*VisibleFaces {
        const self = try allocator.create(VisibleFaces);
        var solid: [CHUNK_W][CHUNK_W]Col = undefined;
        chunk.cubeColumns(&solid);

        for (0..CHUNK_W) |x| for (0..CHUNK_W) |z| {
            const s = solid[x][z];
            // +Y: neighbour above. The top bit has its neighbour out of the
            // chunk.
            var up = andNot(s, shiftDown(s));
            up[TOP_WORD] &= ~(@as(u64, 1) << TOP_BIT);
            // -Y: neighbour below. Bit 0 has its neighbour out of the chunk.
            var down = andNot(s, shiftUp(s));
            down[0] &= ~@as(u64, 1);
            self.masks[@backingInt(Face.py)][x][z] = up;
            self.masks[@backingInt(Face.ny)][x][z] = down;
            self.masks[@backingInt(Face.px)][x][z] = if (x + 1 < CHUNK_W) andNot(s, solid[x + 1][z]) else zero;
            self.masks[@backingInt(Face.nx)][x][z] = if (x > 0) andNot(s, solid[x - 1][z]) else zero;
            self.masks[@backingInt(Face.pz)][x][z] = if (z + 1 < CHUNK_W) andNot(s, solid[x][z + 1]) else zero;
            self.masks[@backingInt(Face.nz)][x][z] = if (z > 0) andNot(s, solid[x][z - 1]) else zero;

            // Faces with the neighbour out of the chunk: ask shouldRenderFace.
            const xi: i32 = @intCast(x);
            const zi: i32 = @intCast(z);
            if (s[TOP_WORD] >> TOP_BIT & 1 != 0 and shouldRenderFace(chunk, getter, xi, CHUNK_H - 1, zi, world_ox, world_oz, .py)) self.masks[@backingInt(Face.py)][x][z][TOP_WORD] |= @as(u64, 1) << TOP_BIT;
            if (s[0] & 1 != 0 and shouldRenderFace(chunk, getter, xi, 0, zi, world_ox, world_oz, .ny)) self.masks[@backingInt(Face.ny)][x][z][0] |= 1;
            inline for (.{ Face.px, Face.nx, Face.pz, Face.nz }) |face| {
                const at_edge = switch (face) {
                    .px => x + 1 == CHUNK_W,
                    .nx => x == 0,
                    .pz => z + 1 == CHUNK_W,
                    .nz => z == 0,
                    else => unreachable,
                };
                if (at_edge) {
                    for (0..CHUNK_H) |y| {
                        if (s[y / 64] >> @intCast(y % 64) & 1 == 0) continue;
                        if (shouldRenderFace(chunk, getter, xi, @intCast(y), zi, world_ox, world_oz, face)) {
                            self.masks[@backingInt(face)][x][z][y / 64] |= @as(u64, 1) << @intCast(y % 64);
                        }
                    }
                }
            }
        };
        for (0..6) |f| {
            var any: Col = zero;
            for (0..CHUNK_W) |x| for (0..CHUNK_W) |z| {
                const c = self.masks[f][x][z];
                switch (@as(Face, @fromBackingInt(@intCast(f)))) {
                    // y faces: slice d is layer y = d, so OR the columns.
                    .py, .ny => {
                        inline for (0..chunk_mod.COL_WORDS) |k| any[k] |= c[k];
                    },
                    // x faces: slice d is x = d. z faces: slice d is z = d.
                    .px, .nx => if (!isZero(c)) rowSet(&any, x),
                    .pz, .nz => if (!isZero(c)) rowSet(&any, z),
                }
            };
            self.nonempty[f] = any;
        }
        return self;
    }

    fn has(self: *const VisibleFaces, face: Face, x: i32, y: i32, z: i32) bool {
        const yu: u32 = @intCast(y);
        return self.masks[@backingInt(face)][@intCast(x)][@intCast(z)][yu / 64] >> @intCast(yu % 64) & 1 != 0;
    }

    /// Row ii of slice d, as greedyIJToLocalBlock maps it: bit jj is set when
    /// the face at (d, ii, jj) is visible.
    fn sliceRow(self: *const VisibleFaces, face: Face, d: i32, ii: usize) Row {
        const f = @backingInt(face);
        const du: usize = @intCast(d);
        return switch (face) {
            .px, .nx => self.masks[f][du][ii], // i = Z, j = Y: the column (x = d, z = ii)
            .pz, .nz => self.masks[f][ii][du], // i = X, j = Y: the column (x = ii, z = d)
            .py, .ny => blk: { // i = X, j = Z: bit d of each column (x = ii, z = jj)
                var r: Row = zero;
                for (0..CHUNK_W) |z| {
                    if (rowGet(self.masks[f][ii][z], du)) r[0] |= @as(u64, 1) << @intCast(z);
                }
                break :blk r;
            },
        };
    }

    /// True when slice d of this face direction has a visible face.
    fn sliceHasFace(self: *const VisibleFaces, face: Face, d: i32) bool {
        return rowGet(self.nonempty[@backingInt(face)], @intCast(d));
    }

    fn andNot(a: Col, b: Col) Col {
        return rowAndNot(a, b);
    }

    fn isZero(c: Col) bool {
        var any: u64 = 0;
        inline for (0..chunk_mod.COL_WORDS) |k| any |= c[k];
        return any == 0;
    }

    /// Bit y of the result is bit y + 1 of `c` (the block above).
    fn shiftDown(c: Col) Col {
        var out: Col = undefined;
        inline for (0..chunk_mod.COL_WORDS) |k| {
            out[k] = c[k] >> 1;
            if (k + 1 < chunk_mod.COL_WORDS) out[k] |= c[k + 1] << 63;
        }
        return out;
    }

    /// Bit y of the result is bit y - 1 of `c` (the block below).
    fn shiftUp(c: Col) Col {
        var out: Col = undefined;
        inline for (0..chunk_mod.COL_WORDS) |k| {
            out[k] = c[k] << 1;
            if (k > 0) out[k] |= c[k - 1] >> 63;
        }
        return out;
    }
};

/// Greedy-merged mesh generation. For each of the 6 face directions, slices
/// the chunk into planes, builds a per-cell `GreedyCell` signature grid, then
/// walks the grid growing rectangles of bit-identical (block_type, ao, sky,
/// block light, tint) cells. One merged quad is emitted per rectangle.
///
/// Cost per chunk: VisibleFaces makes the visible faces as bit masks, one
/// 256-bit column per face direction. Slices with no visible face are
/// skipped, cells are computed only for visible faces, and the walk jumps to
/// the next free bit of each row. So the cost scales with the visible faces,
/// not with the chunk volume (6 × 65 536 cells). bench_mesher measures it.
///
/// The mesher allocates two scratch buffers per call (one GreedyCell grid
/// for the largest slice, CHUNK_W × CHUNK_H cells, and the VisibleFaces
/// masks). The per-call allocation is acceptable because the AO and sky samples
/// cost much more.
///
/// The greedy quads go into `mesh.quads` as PackedQuad, and `mesh.y_min` /
/// `mesh.y_max` get the y range of the quads. Then the model mesher adds a
/// record for each visible quad of each block with a model (REQ-VOXEL-001).
/// With no model block in the chunk, it adds nothing, so a chunk of full
/// cubes gives the same bytes as before the model mesher. When a quad has
/// a tint, the mesh starts with the tint records (REQ-VOXEL-009).
///
/// This is `generateMeshWith` with smooth light on and the tint position
/// from `world_ox` and `world_oz`.
pub fn generateMesh(
    chunk: *const Chunk,
    mesh: *Mesh,
    world_ox: i32,
    world_oz: i32,
    getter: BlockGetter,
    ao_strategy: AOStrategy,
    lighting_mode: LightingMode,
) !void {
    return generateMeshWith(chunk, mesh, world_ox, world_oz, getter, .{ .ao = ao_strategy, .lighting = lighting_mode });
}

/// The options of the mesher.
pub const MeshOptions = struct {
    /// The ambient occlusion of each corner. `.none` turns AO off: each
    /// corner gets AO 1.
    ao: AOStrategy = .classic,
    /// `.none`: full sky light and no block light on each corner.
    /// `.skylight`: the light of the light engine.
    lighting: LightingMode = .skylight,
    /// True: smooth light, the mean light of the 4 cells at each corner.
    /// False: flat light, the light of the cell in front of each face on
    /// all 4 corners (REQ-VOXEL-008).
    smooth_light: bool = true,
    /// The world x and z of local cell (0, 0) of the chunk, for the tint
    /// colours (REQ-VOXEL-009). Null: `world_ox` and `world_oz`. Give it
    /// when the getter uses other coordinates, as the mesh stage does
    /// (`pipeline/stages.zig`).
    origin: ?[2]i32 = null,
    /// The largest size of a merged quad on each axis, in cells. The far
    /// terrain mesh (REQ-VOXEL-021) uses a larger value.
    max_merge: i32 = 6,

    fn originOr(self: MeshOptions, world_ox: i32, world_oz: i32) [2]i32 {
        return self.origin orelse .{ world_ox, world_oz };
    }
};

/// Mesh a chunk with `options`. `world_ox` and `world_oz` are the x and z
/// of local cell (0, 0) in the coordinates of `getter`.
pub fn generateMeshWith(
    chunk: *const Chunk,
    mesh: *Mesh,
    world_ox: i32,
    world_oz: i32,
    getter: BlockGetter,
    options: MeshOptions,
) !void {
    mesh.clear();
    var palette: TintPalette = .{};

    // Max plane dim = CHUNK_W × CHUNK_H (applies to all X/Z sliced faces).
    const max_i: usize = @intCast(CHUNK_W);
    const max_j: usize = @intCast(CHUNK_H);
    const slice_len: usize = max_i * max_j;

    const cells = try mesh.allocator.alloc(GreedyCell, slice_len);
    defer mesh.allocator.free(cells);

    const vis = try VisibleFaces.compute(mesh.allocator, chunk, getter, world_ox, world_oz);
    defer mesh.allocator.destroy(vis);

    // Merge size cap. The cap is from the time when the voxel demo used
    // painter's-algorithm sorting in software, with no hardware depth test,
    // and the sort key was the quad centroid distance. A merged 48×48 quad
    // has its centroid far from its farthest pixel, which causes visible
    // sort inversions against overlapping smaller geometry (pit walls,
    // hover outlines, etc.). Capping the merge at `MAX_GREEDY_DIM` on each
    // axis keeps every merged quad's centroid within half that many blocks
    // of its farthest corner — close enough that painter's sort order
    // matches a mesh of 1×1 quads (one quad per block face) to within
    // 2/255 RMS per channel.
    //
    // Cap of 6 lands comfortably inside the RMS tolerance while still
    // hitting the 5–10× reduction target on flat demo terrain and capturing most
    // of the hilly-terrain wins. Per-channel RMS against 1×1 quads on a
    // flatland pit scene (measured in April 2026):
    //   cap=4 → 0.62 /255   (safe)
    //   cap=6 → 0.65 /255   (safe, picked)
    //   cap=7 → 0.64 /255   (borderline, passes)
    //   cap=8 → 9.63 /255   (fails ≥2 threshold — visible pit-wall inversions)
    //   cap=∞ → 20.8 /255   (fails badly)
    // The cliff between 7 and 8 is narrow, so 6 gives a safer headroom.
    // Measured reduction at cap=6:
    //   flatland → 4608 → ~130 quads (97.2% / ~35× reduction)
    //   hilly    → ~5300 → ~1700 quads (67.8% / ~3.1× reduction)
    // Hilly falls short of the 5-10× target because the uniform-AO/sky
    // rule that `greedyCellEq` enforces rejects most bumpy terrain — the
    // bottleneck is the merge rule, not the cap. The hardware depth test is
    // now always on, so a later change can lift the cap. That change gives
    // a new quad hash in bench_mesher and needs new lavapipe goldens.
    // `options.max_merge` holds the cap. Its default is 6.
    const MAX_GREEDY_DIM: i32 = options.max_merge;

    inline for ([_]Face{ .px, .nx, .py, .ny, .pz, .nz }) |face| {
        const ext = greedyFaceExtents(face);
        const i_max: i32 = ext.i_max;
        const j_max: i32 = ext.j_max;
        const d_max: i32 = ext.d_max;
        const i_max_usz: usize = @intCast(i_max);
        const j_max_usz: usize = @intCast(j_max);

        var d: i32 = 0;
        while (d < d_max) : (d += 1) {
            // A slice with no visible face of this direction emits nothing.
            if (!vis.sliceHasFace(face, d)) continue;

            // Rows of the slice as bit masks: row ii, bit jj. `present` has the
            // visible faces, `visited` the cells that a quad already covers.
            // Cells are computed only where `present` has a bit, so the cell
            // grid needs no clear: a cell is read only where its bit is set.
            var present: [CHUNK_W]Row = undefined;
            var visited_rows: [CHUNK_W]Row = @splat(@splat(0));
            for (0..i_max_usz) |ii| present[ii] = vis.sliceRow(face, d, @intCast(ii));

            // ---- populate cells for the visible faces ----
            for (0..i_max_usz) |ii| {
                var it = rowBits(present[ii]);
                while (it.next()) |jj| {
                    const bp = greedyIJToLocalBlock(face, d, @intCast(ii), @intCast(jj));
                    cells[ii * j_max_usz + jj] = computeGreedyCell(
                        chunk,
                        getter,
                        world_ox,
                        world_oz,
                        bp.x,
                        bp.y,
                        bp.z,
                        face,
                        chunk.resolveBlockRaw(bp.x, bp.y, bp.z),
                        options,
                    );
                }
            }

            // ---- greedy walk ----
            // Seeds in the same order as a scan of ja upward in each row ia:
            // the lowest present bit that no quad covers yet.
            var ia: i32 = 0;
            while (ia < i_max) : (ia += 1) {
                const ia_usz: usize = @intCast(ia);
                while (lowestBit(rowAndNot(present[ia_usz], visited_rows[ia_usz]))) |ja_usz| {
                    const ja: i32 = @intCast(ja_usz);
                    const seed = cells[ia_usz * j_max_usz + ja_usz];
                    const free = struct {
                        fn at(p: *const [CHUNK_W]Row, v: *const [CHUNK_W]Row, i: usize, j: usize) bool {
                            return rowGet(p[i], j) and !rowGet(v[i], j);
                        }
                    }.at;

                    // Grow width along i (within this j row) while cells match
                    // the seed and the cap allows.
                    var w: i32 = 1;
                    while (ia + w < i_max and w < MAX_GREEDY_DIM) {
                        const iw_usz: usize = @intCast(ia + w);
                        if (!free(&present, &visited_rows, iw_usz, ja_usz)) break;
                        if (!greedyCellEq(seed, cells[iw_usz * j_max_usz + ja_usz])) break;
                        w += 1;
                    }

                    // Grow height along j: every row in [ja+1 .. ja+h) must be
                    // free and match across the w-wide strip.
                    var h: i32 = 1;
                    grow_h: while (ja + h < j_max and h < MAX_GREEDY_DIM) {
                        var k: i32 = 0;
                        while (k < w) : (k += 1) {
                            const ik_usz: usize = @intCast(ia + k);
                            const jh_usz: usize = @intCast(ja + h);
                            if (!free(&present, &visited_rows, ik_usz, jh_usz)) break :grow_h;
                            if (!greedyCellEq(seed, cells[ik_usz * j_max_usz + jh_usz])) break :grow_h;
                        }
                        h += 1;
                    }

                    // Mark the w × h rect visited.
                    var rk: i32 = 0;
                    while (rk < w) : (rk += 1) {
                        var rl: i32 = 0;
                        while (rl < h) : (rl += 1) {
                            rowSet(&visited_rows[@intCast(ia + rk)], @intCast(ja + rl));
                        }
                    }

                    try emitGreedyQuad(mesh, &palette, face, d, ia, ja, w, h, seed);
                }
            }
        }
    }
    try generateModelQuads(chunk, mesh, world_ox, world_oz, getter, options, &palette);
    try mesh.sortBySection();
    try palette.writeRecords(mesh);
    std.log.info("[MESH greedy: {} quads]", .{mesh.quadCount()});
}

// ---------------------------------------------------------------------------
// Model meshing (REQ-VOXEL-001)
// ---------------------------------------------------------------------------

/// True when the neighbour of local cell (lx, ly, lz) in direction `face` is
/// a full cube, so it hides a quad with that cull face (REQ-VOXEL-002).
fn neighbourIsCube(chunk: *const Chunk, getter: BlockGetter, lx: i32, ly: i32, lz: i32, world_ox: i32, world_oz: i32, face: Face) bool {
    return !shouldRenderFace(chunk, getter, lx, ly, lz, world_ox, world_oz, face);
}

/// Add a model quad record for each visible quad of each block with a
/// model. It reads the cell of the block, its 6 neighbours and the cells
/// of the AO and light samples of a face, so the mesh stage stays in its
/// bounded neighbourhood.
fn generateModelQuads(
    chunk: *const Chunk,
    mesh: *Mesh,
    world_ox: i32,
    world_oz: i32,
    getter: BlockGetter,
    options: MeshOptions,
    palette: *TintPalette,
) !void {
    if (!models.any) return;
    for (&chunk.blocks.sections, 0..) |*sec, s| {
        // Skip a section with no model block in its palette.
        const has = for (sec.palette()) |b| {
            if (models.hasModel(b)) break true;
        } else false;
        if (!has) continue;
        const y0: i32 = @intCast(s * section_mod.SIZE);
        var x: i32 = 0;
        while (x < CHUNK_W) : (x += 1) {
            var y: i32 = y0;
            while (y < y0 + section_mod.SIZE) : (y += 1) {
                var z: i32 = 0;
                while (z < CHUNK_W) : (z += 1) {
                    const block = chunk.resolveBlockRaw(x, y, z);
                    if (!models.hasModel(block)) continue;
                    try emitModelBlock(chunk, mesh, world_ox, world_oz, getter, options, palette, x, y, z, block);
                }
            }
        }
    }
}

/// The in-plane position (i, j) of each corner of a model quad that lies
/// on the side of its cell in its light direction, by index in
/// `models.quads`. Null for a quad that is not on the cell grid. i and j
/// are the in-plane axes of the face (face_layouts), 0 to 1.
const model_grid: [models.quads.len]?[4][2]f32 = blk: {
    @setEvalBranchQuota(100_000);
    var out: [models.quads.len]?[4][2]f32 = undefined;
    for (models.quads, 0..) |q, qi| {
        const fl = face_layouts[@backingInt(q.face)];
        const plane: f32 = if (fl.positive) 1.0 else 0.0;
        var on_grid = true;
        var ij: [4][2]f32 = undefined;
        for (q.pos, 0..) |p, c| {
            if (@abs(p[fl.normal_axis] - plane) > 1.0e-4) on_grid = false;
            ij[c] = .{ std.math.clamp(p[fl.i_axis], 0.0, 1.0), std.math.clamp(p[fl.j_axis], 0.0, 1.0) };
        }
        out[qi] = if (on_grid) ij else null;
    }
    break :blk out;
};

/// The value at in-plane position (i, j) of a face with corner values `v`
/// (in the corner order of face_layouts): the bilinear mix of the 4 corners.
fn faceValueAt(face: Face, v: [4]f32, ij: [2]f32) f32 {
    const fl = face_layouts[@backingInt(face)];
    // at[si][sj]: the value of the corner at step (si, sj).
    var at: [2][2]f32 = undefined;
    for (0..4) |c| at[fl.pos[c][0]][fl.pos[c][1]] = v[c];
    const i = ij[0];
    const j = ij[1];
    return (1 - i) * (1 - j) * at[0][0] + i * (1 - j) * at[1][0] + (1 - i) * j * at[0][1] + i * j * at[1][1];
}

/// The AO and the light of each corner of model quad `qi` of the block at
/// local (lx, ly, lz) (REQ-VOXEL-008).
///
/// A quad on the cell grid (its corners on the side of the cell in its
/// light direction, `model_grid`) gets the AO and the light of the full
/// face of the cell, mixed at the position of each corner. A full-size quad
/// then gets the values of a greedy face. A part of a face (for example
/// the side of a half block) gets the values at its corners.
///
/// A quad that is not on the grid (for example the top of a half block, or
/// a plane through the cell) gets flat light: the light of the neighbour
/// cell in its light direction on all 4 corners, and AO 1. Its corners do
/// not touch the cells that the corner samples read, so these samples do
/// not apply to it.
fn modelQuadShade(chunk: *const Chunk, getter: BlockGetter, world_ox: i32, world_oz: i32, options: MeshOptions, qi: usize, lx: i32, ly: i32, lz: i32) struct { ao: [4]f32, light: FaceLight } {
    const q = models.quads[qi];
    const wx = world_ox + lx;
    const wz = world_oz + lz;
    const grid = model_grid[qi] orelse {
        const light: FaceLight = switch (options.lighting) {
            .none => FaceLight.off,
            .skylight => computeFlatLight(chunk, getter, world_ox, world_oz, wx, ly, wz, q.face),
        };
        return .{ .ao = @splat(1.0), .light = light };
    };
    const ao_face = computeFaceAOForStrategy(chunk, getter, world_ox, world_oz, wx, ly, wz, q.face, options.ao);
    const light_face = faceLight(chunk, getter, world_ox, world_oz, wx, ly, wz, q.face, options);
    var ao: [4]f32 = undefined;
    var light: FaceLight = undefined;
    for (0..4) |c| {
        ao[c] = faceValueAt(q.face, ao_face, grid[c]);
        light.sky[c] = faceValueAt(q.face, light_face.sky, grid[c]);
        light.bl[c] = faceValueAt(q.face, light_face.bl, grid[c]);
    }
    return .{ .ao = ao, .light = light };
}

fn emitModelBlock(
    chunk: *const Chunk,
    mesh: *Mesh,
    world_ox: i32,
    world_oz: i32,
    getter: BlockGetter,
    options: MeshOptions,
    palette: *TintPalette,
    lx: i32,
    ly: i32,
    lz: i32,
    block: BlockType,
) !void {
    const r = models.range(block);
    const origin = options.originOr(world_ox, world_oz);
    for (r.first..@as(usize, r.first) + r.count) |qi| {
        const q = models.quads[qi];
        if (q.cull_face) |cf| {
            if (neighbourIsCube(chunk, getter, lx, ly, lz, world_ox, world_oz, cf)) continue;
        }
        const shade = modelQuadShade(chunk, getter, world_ox, world_oz, options, qi, lx, ly, lz);
        var rec = packModelQuad(
            .{ @intCast(lx), @intCast(ly), @intCast(lz) },
            @intCast(qi),
            @backingInt(block),
            shade.ao,
            shade.light.sky,
            shade.light.bl,
        );
        const tint = tintColor(block, q.tint_index, origin[0] + lx, MIN_Y + ly, origin[1] + lz);
        rec[3] |= palette.slot(tint) << TINT_SLOT_SHIFT;
        var y_lo: f32 = q.pos[0][1];
        var y_hi: f32 = q.pos[0][1];
        for (q.pos[1..]) |p| {
            y_lo = @min(y_lo, p[1]);
            y_hi = @max(y_hi, p[1]);
        }
        const base: f32 = @floatFromInt(MIN_Y + ly);
        try mesh.addQuad(rec, base + y_lo, base + y_hi);
    }
}

// ============================================================================
// Packed quads: the mesh format on the CPU and on the GPU
// ============================================================================
//
// The mesher makes one 16-byte PackedQuad per quad. The upload writes these
// bytes to the GPU with no conversion. vs_chunk in voxel.wgsl makes the 6
// vertices of the 2 triangles from it. unpackCorner below is the same decode
// in Zig, so a test can check the decode.
//
// Layout (bit 0 = LSB). The cell is the block that owns the face, relative to
// the chunk origin: x and z local, y local (0 is world y MIN_Y). W and H are
// the quad size along the face's in-plane axes.
//   word 0: cell x (4) | cell y bits 0-7 (8) | cell z (4) | face (3) | W-1 (4) | H-1 (8)
//   words 1-3: 12 six-bit light fields, 5 + 5 + 2 per word, in this order:
//              ao0..3, sky0..3, bl0..3
//   word 3, bits 12-19: block type. Bits 20-23: cell y bits 8-11, 0 in a
//   column of 256 cells or less. Bits 24-30: tint slot (0 = no tint).
//   Bit 31: 0.
// ao = field / 42, sky = field / 60, block light = field / 60. Every value of
// a greedy face is one of these ratios, so the decode gives the same f32. A
// model quad on a part of a face mixes the corner values, and the field
// holds the nearest ratio.
//
// Model quad records (REQ-VOXEL-001). A record of a model quad is also 16
// bytes in the same stream, after the greedy quads. Bit 31 of word 3 is 1 in
// a model record and 0 in a greedy quad. A model record has the layout of a
// greedy quad, but word 0 bits 16-31 hold the index of the quad in
// `models.gpu_table` in place of the face, W and H:
//   word 0: cell x (4) | cell y bits 0-7 (8) | cell z (4) | model quad index (16)
//   words 1-3: the 12 light fields, as above
//   word 3, bits 12-19: block type. Bits 20-23: cell y bits 8-11. Bits
//   24-30: tint slot. Bit 31: 1.
// The shader reads the corners, the texture coordinates, the face, the tint
// index and the shade flag of the quad from the table. A world of full cubes
// has no model records, so its bytes do not change.
//
// Tint records (REQ-VOXEL-009). A quad with a tint holds a tint slot, 1 to
// MAX_TINT_SLOTS, in word 3 bits 24-30. The colours of the slots are in tint
// records at the start of the stream, before the greedy quads. The record at
// index k holds the colours of slots 4k + 1 to 4k + 4, one per word:
//   word n, bits 0-23: red | green << 8 | blue << 16 of slot 4k + n + 1
//   word 3, bits 24-30: TINT_RECORD_SLOT (127). Other bits: 0.
// The shader draws no triangle for a tint record. A mesh with no tint has no
// tint records, and each tint slot is 0, so its bytes do not change.

pub const PackedQuad = [4]u32;

/// The bit of the tint slot in word 3 of a quad.
pub const TINT_SLOT_SHIFT: u5 = 24;
/// The tint slots of one mesh: 1 to 126.
pub const MAX_TINT_SLOTS: usize = 126;
/// The tint slot value that marks a tint record.
pub const TINT_RECORD_SLOT: u32 = 0x7F;

/// The tint slot of a quad: 0 for no tint, else 1 to MAX_TINT_SLOTS.
pub fn tintSlot(q: PackedQuad) u32 {
    return (q[3] >> TINT_SLOT_SHIFT) & 0x7F;
}

/// True when `q` is a tint record, not a quad.
pub fn isTintRecord(q: PackedQuad) bool {
    return tintSlot(q) == TINT_RECORD_SLOT;
}

/// The tint colour of quad `q` of `quads` (a mesh), as red, green, blue,
/// or null for a quad with no tint. Mirrors tintOf in voxel.wgsl.
pub fn quadTint(quads: []const PackedQuad, q: PackedQuad) ?[3]u8 {
    const s = tintSlot(q);
    if (s == 0 or s == TINT_RECORD_SLOT) return null;
    const word = quads[(s - 1) / 4][(s - 1) % 4];
    return .{ @truncate(word), @truncate(word >> 8), @truncate(word >> 16) };
}

pub const AO_STEPS: f32 = 42.0;
pub const LIGHT_STEPS: f32 = 60.0;

/// Per face: the axis of the face normal, the in-plane axes i (W) and j (H),
/// and per corner the position step (0 or 1) along i and j and the uv step.
/// The corner order is the order of the per-corner light values. voxel.wgsl
/// has the corner steps as bit constants (FACE_POS_*, FACE_UV_*): see
/// cornerBits, and the test that checks them.
const FaceLayout = struct {
    normal_axis: u2,
    i_axis: u2,
    j_axis: u2,
    positive: bool,
    pos: [4][2]u1,
    uv: [4][2]u1,
};

const face_layouts = [6]FaceLayout{
    // px: i = Z, j = Y
    .{ .normal_axis = 0, .i_axis = 2, .j_axis = 1, .positive = true, .pos = .{ .{ 0, 0 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 } }, .uv = .{ .{ 0, 0 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 } } },
    // nx: i = Z, j = Y
    .{ .normal_axis = 0, .i_axis = 2, .j_axis = 1, .positive = false, .pos = .{ .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 }, .{ 0, 0 } }, .uv = .{ .{ 0, 0 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 } } },
    // py: i = X, j = Z
    .{ .normal_axis = 1, .i_axis = 0, .j_axis = 2, .positive = true, .pos = .{ .{ 0, 0 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 } }, .uv = .{ .{ 0, 0 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 } } },
    // ny: i = X, j = Z
    .{ .normal_axis = 1, .i_axis = 0, .j_axis = 2, .positive = false, .pos = .{ .{ 0, 1 }, .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 } }, .uv = .{ .{ 0, 0 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 } } },
    // pz: i = X, j = Y
    .{ .normal_axis = 2, .i_axis = 0, .j_axis = 1, .positive = true, .pos = .{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } }, .uv = .{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } } },
    // nz: i = X, j = Y
    .{ .normal_axis = 2, .i_axis = 0, .j_axis = 1, .positive = false, .pos = .{ .{ 1, 0 }, .{ 0, 0 }, .{ 0, 1 }, .{ 1, 1 } }, .uv = .{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } } },
};

/// The corner steps of face_layouts as a shader that decodes `PackedQuad`
/// stores them (voxel.wgsl of the demo): 2 bits per corner (i | j << 1), 8
/// bits per face, faces 0-3 in A and faces 4-5 in B.
pub fn cornerBits(comptime which: enum { pos, uv }) [2]u32 {
    var out = [2]u32{ 0, 0 };
    for (face_layouts, 0..) |fl, f| {
        const steps = if (which == .pos) fl.pos else fl.uv;
        var byte: u32 = 0;
        for (steps, 0..) |st, c| byte |= (@as(u32, st[0]) | (@as(u32, st[1]) << 1)) << @intCast(2 * c);
        out[f / 4] |= byte << @intCast(8 * (f % 4));
    }
    return out;
}

fn quantize(v: f32, steps: f32) u32 {
    return @intFromFloat(@round(v * steps));
}

/// Pack one quad. `cell` is the local block that owns the face, w and h are
/// the size along the in-plane axes i and j, and the light values are per
/// corner, in the corner order of face_layouts.
fn packQuad(face: Face, cell: [3]u32, w: u32, h: u32, block_type: u32, ao: [4]f32, sky: [4]f32, bl: [4]f32) PackedQuad {
    var fields: [12]u32 = undefined;
    for (0..4) |c| {
        fields[c] = quantize(ao[c], AO_STEPS);
        fields[4 + c] = quantize(sky[c], LIGHT_STEPS);
        fields[8 + c] = quantize(bl[c], LIGHT_STEPS);
    }
    var q: PackedQuad = .{ 0, 0, 0, 0 };
    q[0] = cell[0] | ((cell[1] & 0xFF) << 4) | (cell[2] << 12) | (@as(u32, @backingInt(face)) << 16) |
        ((w - 1) << 19) | ((h - 1) << 23);
    for (fields, 0..) |f, i| q[1 + i / 5] |= f << @intCast(6 * (i % 5));
    q[3] |= (block_type & 0xFF) << 12;
    q[3] |= (cell[1] >> 8) << 20;
    return q;
}

/// Bit 31 of word 3: set in a model quad record.
pub const MODEL_RECORD_BIT: u32 = 1 << 31;

/// True when `q` is a model quad record, not a greedy quad.
pub fn isModelRecord(q: PackedQuad) bool {
    return q[3] & MODEL_RECORD_BIT != 0;
}

/// The index in `models.quads` (and `models.gpu_table`) of a model record.
pub fn modelQuadIndex(q: PackedQuad) u16 {
    return @intCast(q[0] >> 16);
}

/// Pack one model quad record. `cell` is the local block of the model, and
/// the light values are per corner of the baked quad.
fn packModelQuad(cell: [3]u32, quad_index: u16, block_type: u32, ao: [4]f32, sky: [4]f32, bl: [4]f32) PackedQuad {
    // The light fields, the block type and the high y bits are in the same
    // place as in a greedy quad.
    var q = packQuad(.px, cell, 1, 1, block_type, ao, sky, bl);
    q[0] = (q[0] & 0xFFFF) | (@as(u32, quad_index) << 16);
    q[3] |= MODEL_RECORD_BIT;
    return q;
}

/// The local y of the cell of a packed quad.
pub fn cellY(q: PackedQuad) u32 {
    return ((q[0] >> 4) & 0xFF) | (((q[3] >> 20) & 0xF) << 8);
}

/// Decode corner `corner` (0..3) of a packed quad or a model quad record,
/// in world coordinates. Mirrors vs_chunk.
pub fn unpackCorner(q: PackedQuad, corner: usize, world_ox: i32, world_oz: i32) VoxelVertex {
    const cell = [3]i32{
        @intCast(q[0] & 0xF),
        @intCast(cellY(q)),
        @intCast((q[0] >> 12) & 0xF),
    };
    const field = struct {
        fn get(qq: PackedQuad, i: usize) u32 {
            return (qq[1 + i / 5] >> @intCast(6 * (i % 5))) & 0x3F;
        }
    }.get;
    if (models.any and isModelRecord(q)) {
        const mq = models.quads[modelQuadIndex(q)];
        const p = mq.pos;
        const e1 = [3]f32{ p[1][0] - p[0][0], p[1][1] - p[0][1], p[1][2] - p[0][2] };
        const e2 = [3]f32{ p[2][0] - p[0][0], p[2][1] - p[0][1], p[2][2] - p[0][2] };
        const n = [3]f32{ e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0] };
        const len = @sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
        return .{
            .pos = .{
                @as(f32, @floatFromInt(cell[0] + world_ox)) + p[corner][0],
                @as(f32, @floatFromInt(cell[1] + MIN_Y)) + p[corner][1],
                @as(f32, @floatFromInt(cell[2] + world_oz)) + p[corner][2],
            },
            .normal = .{ n[0] / len, n[1] / len, n[2] / len },
            .block_type = (q[3] >> 12) & 0xFF,
            .uv = mq.uv[corner],
            .ao = @as(f32, @floatFromInt(field(q, corner))) / AO_STEPS,
            .skylight = @as(f32, @floatFromInt(field(q, 4 + corner))) / LIGHT_STEPS,
            .block_light = @as(f32, @floatFromInt(field(q, 8 + corner))) / LIGHT_STEPS,
        };
    }
    const face: u3 = @intCast((q[0] >> 16) & 0x7);
    const w: f32 = @floatFromInt(((q[0] >> 19) & 0xF) + 1);
    const h: f32 = @floatFromInt(((q[0] >> 23) & 0xFF) + 1);
    const fl = face_layouts[face];
    var pos = [3]f32{
        @floatFromInt(cell[0] + world_ox),
        @floatFromInt(cell[1] + MIN_Y),
        @floatFromInt(cell[2] + world_oz),
    };
    if (fl.positive) pos[fl.normal_axis] += 1;
    pos[fl.i_axis] += @as(f32, @floatFromInt(fl.pos[corner][0])) * w;
    pos[fl.j_axis] += @as(f32, @floatFromInt(fl.pos[corner][1])) * h;
    return .{
        .pos = pos,
        .normal = face_normals[face],
        .block_type = (q[3] >> 12) & 0xFF,
        .uv = .{ @as(f32, @floatFromInt(fl.uv[corner][0])) * w, @as(f32, @floatFromInt(fl.uv[corner][1])) * h },
        .ao = @as(f32, @floatFromInt(field(q, corner))) / AO_STEPS,
        .skylight = @as(f32, @floatFromInt(field(q, 4 + corner))) / LIGHT_STEPS,
        .block_light = @as(f32, @floatFromInt(field(q, 8 + corner))) / LIGHT_STEPS,
    };
}

/// Test getter for one chunk at world (ox, oz): outside the chunk is air in
/// full skylight, with no block light.
const TestGetter = struct {
    chunk: *const Chunk,
    ox: i32,
    oz: i32,

    fn local(self: *const TestGetter, x: i32, y: i32, z: i32) ?[3]i32 {
        const lx = x - self.ox;
        const ly = y - MIN_Y;
        const lz = z - self.oz;
        if (lx < 0 or lz < 0 or lx >= CHUNK_W or lz >= CHUNK_W or ly < 0 or ly >= CHUNK_H) return null;
        return .{ lx, ly, lz };
    }
    fn block(ctx: *const anyopaque, x: i32, y: i32, z: i32) BlockType {
        const self: *const TestGetter = @ptrCast(@alignCast(ctx));
        const l = self.local(x, y, z) orelse return .air;
        return self.chunk.getBlock(l[0], l[1], l[2]);
    }
    fn sky(ctx: *const anyopaque, x: i32, y: i32, z: i32) u8 {
        const self: *const TestGetter = @ptrCast(@alignCast(ctx));
        const l = self.local(x, y, z) orelse return chunk_mod.MAX_SKYLIGHT;
        return self.chunk.getSkylight(l[0], l[1], l[2]);
    }
    fn blockLight(ctx: *const anyopaque, x: i32, y: i32, z: i32) u8 {
        const self: *const TestGetter = @ptrCast(@alignCast(ctx));
        const l = self.local(x, y, z) orelse return 0;
        return self.chunk.getBlockLight(l[0], l[1], l[2]);
    }
    fn getter(self: *const TestGetter) BlockGetter {
        return .{ .ctx = self, .getFn = block, .getSkylightFn = sky, .getBlockLightFn = blockLight };
    }
};

/// A stepped hill with an overhang and an emissive block, so every face, merged
/// quads, AO and both light channels occur.
fn testHillChunk(allocator: std.mem.Allocator) !Chunk {
    var chunk = Chunk.init(allocator);
    errdefer chunk.deinit();
    for (0..CHUNK_W) |x| for (0..CHUNK_W) |z| {
        const top: usize = 60 + (x + z) / 4;
        for (0..top) |y| try chunk.setBlock(@intCast(x), @intCast(y), @intCast(z), if (y + 1 == top) .b3 else .solid);
    };
    for (4..9) |x| for (4..9) |z| try chunk.setBlock(@intCast(x), 75, @intCast(z), .solid);
    try chunk.setBlock(6, 70, 6, .emitter);
    try chunk.computeSkylight();
    try chunk.computeBlockLight();
    return chunk;
}

test "each packed quad decodes to the face, block and light of its cell" {
    const allocator = std.testing.allocator;
    const ox: i32 = 32;
    const oz: i32 = -48;
    for ([_]AOStrategy{ .classic, .moore, .propagated }) |ao| {
        var chunk = try testHillChunk(allocator);
        defer chunk.deinit();
        const tg = TestGetter{ .chunk = &chunk, .ox = ox, .oz = oz };
        var mesh = Mesh.init(allocator);
        defer mesh.deinit();
        try generateMesh(&chunk, &mesh, ox, oz, tg.getter(), ao, .skylight);
        try std.testing.expect(mesh.quadCount() > 0);
        var y_min: f32 = EMPTY_Y_MIN;
        var y_max: f32 = EMPTY_Y_MAX;
        for (mesh.quads.items) |q| {
            const lx: i32 = @intCast(q[0] & 0xF);
            const ly: i32 = @intCast(cellY(q));
            const lz: i32 = @intCast((q[0] >> 12) & 0xF);
            const face: Face = @fromBackingInt(@as(u3, @intCast((q[0] >> 16) & 0x7)));
            const block = chunk.getBlock(lx, ly, lz);
            try std.testing.expect(block != .air);
            try std.testing.expect(shouldRenderFace(&chunk, tg.getter(), lx, ly, lz, ox, oz, face));
            const want = computeGreedyCell(&chunk, tg.getter(), ox, oz, lx, ly, lz, face, block, .{ .ao = ao, .lighting = .skylight });
            for (0..4) |c| {
                const got = unpackCorner(q, c, ox, oz);
                try std.testing.expectEqual(@as(u32, @backingInt(block)), got.block_type);
                try std.testing.expectEqual(face_normals[@backingInt(face)], got.normal);
                try std.testing.expectEqual(want.ao[c], got.ao);
                try std.testing.expectEqual(want.sky[c], got.skylight);
                try std.testing.expectEqual(want.bl[c], got.block_light);
                y_min = @min(y_min, got.pos[1]);
                y_max = @max(y_max, got.pos[1]);
            }
        }
        try std.testing.expectEqual(y_min, mesh.y_min);
        try std.testing.expectEqual(y_max, mesh.y_max);
    }
}

test "a packed quad keeps a cell y above 255" {
    for ([_]u32{ 0, 255, 256, 300, 4095 }) |y| {
        const q = packQuad(.px, .{ 3, y, 9 }, 2, 5, 1, @splat(1), @splat(1), @splat(0));
        try std.testing.expectEqual(y, cellY(q));
        const corner = unpackCorner(q, 0, 0, 0);
        try std.testing.expectEqual(@as(f32, @floatFromInt(@as(i32, @intCast(y)) + MIN_Y)), corner.pos[1]);
    }
}

test "faces at the bottom and the top of the column" {
    const allocator = std.testing.allocator;
    var chunk = Chunk.init(allocator);
    defer chunk.deinit();
    // One block at local y 0 and one at the top cell, in two sections.
    try chunk.setBlock(2, 0, 3, .solid);
    try chunk.setBlock(5, CHUNK_H - 1, 7, .solid);
    try chunk.computeSkylight();
    try chunk.computeBlockLight();
    const tg = TestGetter{ .chunk = &chunk, .ox = 0, .oz = 0 };
    var mesh = Mesh.init(allocator);
    defer mesh.deinit();
    try generateMesh(&chunk, &mesh, 0, 0, tg.getter(), .classic, .skylight);
    // Each block shows 6 faces: the getter gives air above and below.
    try std.testing.expectEqual(@as(usize, 12), mesh.quadCount());
    var low: usize = 0;
    var high: usize = 0;
    for (mesh.quads.items) |q| {
        switch (cellY(q)) {
            0 => low += 1,
            CHUNK_H - 1 => high += 1,
            else => return error.TestUnexpectedResult,
        }
    }
    try std.testing.expectEqual(@as(usize, 6), low);
    try std.testing.expectEqual(@as(usize, 6), high);
    try std.testing.expectEqual(@as(f32, MIN_Y), mesh.y_min);
    try std.testing.expectEqual(@as(f32, MIN_Y + CHUNK_H), mesh.y_max);
}

test "each section has a draw range, and each quad is in the range of its lowest section (REQ-VOXEL-023)" {
    const allocator = std.testing.allocator;
    var chunk = Chunk.init(allocator);
    defer chunk.deinit();
    // A floor, and a pillar from local y 13 to 37: its side faces go over
    // two section borders. A flat top at y 48 is on a section border. A
    // half block with a model at y 70.
    for (0..CHUNK_W) |x| for (0..CHUNK_W) |z| try chunk.setBlock(@intCast(x), 0, @intCast(z), .solid);
    for (13..38) |y| try chunk.setBlock(1, @intCast(y), 1, .solid);
    try chunk.setBlock(9, 47, 9, .solid);
    try chunk.setBlock(5, 70, 6, .b19);
    var mesh = Mesh.init(allocator);
    defer mesh.deinit();
    try meshAlone(&chunk, &mesh);
    try std.testing.expect(mesh.quadCount() > 0);
    try std.testing.expectEqual(@as(usize, mesh.quadCount()), mesh.ranges[SECTION_COUNT - 1].end);
    try std.testing.expectEqual(@as(usize, 0), mesh.spans.items.len);
    var start: usize = 0;
    var spans_two = false;
    for (mesh.ranges, 0..) |r, s| {
        try std.testing.expect(r.end >= start);
        try std.testing.expect(r.top >= s and r.top < SECTION_COUNT);
        var top: usize = s;
        for (mesh.quads.items[start..r.end]) |q| {
            if (isTintRecord(q)) continue;
            var y_lo: f32 = std.math.inf(f32);
            var y_hi: f32 = -std.math.inf(f32);
            for (0..4) |c| {
                const v = unpackCorner(q, c, 0, 0);
                y_lo = @min(y_lo, v.pos[1]);
                y_hi = @max(y_hi, v.pos[1]);
            }
            const sp = quadSpan(y_lo, y_hi);
            // A quad is in the range of its lowest section, and the range
            // reaches its highest section.
            try std.testing.expectEqual(@as(u8, @intCast(s)), sp[0]);
            try std.testing.expect(sp[1] <= r.top);
            top = @max(top, sp[1]);
            if (sp[1] > sp[0]) spans_two = true;
        }
        try std.testing.expectEqual(top, r.top);
        start = r.end;
    }
    try std.testing.expect(spans_two);

    // A flat face on a section border is in the two sections.
    const b: f32 = @floatFromInt(MIN_Y + 48);
    try std.testing.expectEqual([2]u8{ sectionOfY(b - 1), sectionOfY(b) }, quadSpan(b, b));
    try std.testing.expectEqual([2]u8{ sectionOfY(b), sectionOfY(b) }, quadSpan(b + 0.5, b + 0.5));
    // A side face of 16 cells from a border is in one section.
    try std.testing.expectEqual([2]u8{ sectionOfY(b), sectionOfY(b) }, quadSpan(b, b + 16));

    // A mesh with no quads has empty ranges.
    var empty_chunk = Chunk.init(allocator);
    defer empty_chunk.deinit();
    try meshAlone(&empty_chunk, &mesh);
    try std.testing.expectEqual(EMPTY_RANGES, mesh.ranges);
}

/// Count the greedy quads and the model records of a mesh.
fn countRecords(mesh: *const Mesh) struct { greedy: usize, model: usize } {
    var greedy: usize = 0;
    var model: usize = 0;
    for (mesh.quads.items) |q| {
        if (isModelRecord(q)) model += 1 else greedy += 1;
    }
    return .{ .greedy = greedy, .model = model };
}

/// Mesh `chunk` at the origin with the test getter (air outside).
fn meshAlone(chunk: *Chunk, mesh: *Mesh) !void {
    try chunk.computeSkylight();
    try chunk.computeBlockLight();
    const tg = TestGetter{ .chunk = chunk, .ox = 0, .oz = 0 };
    try generateMesh(chunk, mesh, 0, 0, tg.getter(), .classic, .skylight);
}

test "a chunk of full cubes has no model records (REQ-VOXEL-001)" {
    const allocator = std.testing.allocator;
    var chunk = try testHillChunk(allocator);
    defer chunk.deinit();
    var mesh = Mesh.init(allocator);
    defer mesh.deinit();
    try meshAlone(&chunk, &mesh);
    try std.testing.expect(mesh.quadCount() > 0);
    try std.testing.expectEqual(@as(usize, 0), countRecords(&mesh).model);
}

test "a block with a model gets model records and no greedy faces (REQ-VOXEL-001)" {
    const allocator = std.testing.allocator;
    var chunk = Chunk.init(allocator);
    defer chunk.deinit();
    // b19 is the half block of the test content: 6 quads.
    try chunk.setBlock(5, 70, 6, .b19);
    var mesh = Mesh.init(allocator);
    defer mesh.deinit();
    try meshAlone(&chunk, &mesh);
    const n = countRecords(&mesh);
    try std.testing.expectEqual(@as(usize, 0), n.greedy);
    try std.testing.expectEqual(@as(usize, 6), n.model);
    try std.testing.expectEqual(@as(f32, MIN_Y + 70), mesh.y_min);
    try std.testing.expectEqual(@as(f32, MIN_Y + 70.5), mesh.y_max);

    // Each record decodes to the corners and the texture coordinates of
    // its baked quad, moved to the cell, with the light of the neighbour
    // in the light direction: open sky here.
    const r = models.range(.b19);
    for (mesh.quads.items) |q| {
        const qi = modelQuadIndex(q);
        try std.testing.expect(qi >= r.first and qi < r.first + r.count);
        const baked = models.quads[qi];
        for (0..4) |c| {
            const v = unpackCorner(q, c, 0, 0);
            try std.testing.expectEqual(@as(u32, @backingInt(BlockType.b19)), v.block_type);
            try std.testing.expectEqual(5 + baked.pos[c][0], v.pos[0]);
            try std.testing.expectEqual(@as(f32, MIN_Y + 70) + baked.pos[c][1], v.pos[1]);
            try std.testing.expectEqual(6 + baked.pos[c][2], v.pos[2]);
            try std.testing.expectEqual(baked.uv[c], v.uv);
            try std.testing.expectEqual(face_normals[@backingInt(baked.face)], v.normal);
            try std.testing.expectEqual(@as(f32, 1.0), v.ao);
            // The half block has opacity 0 (REQ-VOXEL-003), so the sky
            // light goes through it: the cell under it gets full sky light.
            try std.testing.expectEqual(@as(f32, 1.0), v.skylight);
            try std.testing.expectEqual(@as(f32, 0.0), v.block_light);
        }
    }
}

test "a quad with a cull face is not drawn next to a full cube (REQ-VOXEL-002)" {
    const allocator = std.testing.allocator;
    var chunk = Chunk.init(allocator);
    defer chunk.deinit();
    try chunk.setBlock(5, 70, 6, .b19);
    // A full cube below hides the bottom quad (cull face -Y). The top quad
    // is inside the cell, so the full cube above does not hide it.
    try chunk.setBlock(5, 69, 6, .solid);
    try chunk.setBlock(5, 71, 6, .solid);
    // A block with a model does not hide a quad: b20 at +X.
    try chunk.setBlock(6, 70, 6, .b20);
    var mesh = Mesh.init(allocator);
    defer mesh.deinit();
    try meshAlone(&chunk, &mesh);

    var half_faces = std.EnumSet(Face){};
    var plane_quads: usize = 0;
    for (mesh.quads.items) |q| {
        if (!isModelRecord(q)) continue;
        const baked = models.quads[modelQuadIndex(q)];
        const block: BlockType = @fromBackingInt(@as(u8, @intCast((q[3] >> 12) & 0xFF)));
        switch (block) {
            .b19 => half_faces.insert(baked.face),
            .b20 => plane_quads += 1,
            else => return error.TestUnexpectedResult,
        }
    }
    try std.testing.expect(!half_faces.contains(.ny));
    try std.testing.expectEqual(@as(usize, 5), half_faces.count());
    // The quads of b20 have no cull face.
    try std.testing.expectEqual(@as(usize, 2), plane_quads);

    // The full cubes show the faces that touch the half block: 6 faces
    // each, because no full cube touches them.
    var cube_faces: usize = 0;
    for (quadsOnly(&mesh)) |q| {
        if (!isModelRecord(q)) cube_faces += 1;
    }
    try std.testing.expectEqual(@as(usize, 12), cube_faces);
}

test "the model records take the light of the neighbour in the light direction" {
    const allocator = std.testing.allocator;
    var chunk = Chunk.init(allocator);
    defer chunk.deinit();
    // A half block in a closed box of full cubes, with an emitter at +X: the
    // quads read no sky light, and the +X quad is hidden by the emitter.
    for (0..3) |dx| for (0..3) |dy| for (0..3) |dz| {
        try chunk.setBlock(@intCast(4 + dx), @intCast(69 + dy), @intCast(5 + dz), .solid);
    };
    try chunk.setBlock(5, 70, 6, .b20);
    try chunk.setBlock(5, 71, 6, .air);
    try chunk.setBlock(5, 72, 6, .emitter);
    try chunk.setBlock(5, 73, 6, .solid);
    var mesh = Mesh.init(allocator);
    defer mesh.deinit();
    try meshAlone(&chunk, &mesh);
    var seen: usize = 0;
    for (mesh.quads.items) |q| {
        if (!isModelRecord(q)) continue;
        seen += 1;
        // The light direction of b20 is +Y: the air cell under the emitter.
        const v = unpackCorner(q, 0, 0, 0);
        try std.testing.expectEqual(@as(f32, 0.0), v.skylight);
        const want: f32 = @as(f32, @floatFromInt(chunk_mod.MAX_BLOCK_LIGHT - 1)) / @as(f32, @floatFromInt(chunk_mod.MAX_BLOCK_LIGHT));
        try std.testing.expectEqual(want, v.block_light);
    }
    try std.testing.expectEqual(@as(usize, 2), seen);

    // With lighting off, the sky light is full and the block light is 0.
    const tg = TestGetter{ .chunk = &chunk, .ox = 0, .oz = 0 };
    try generateMesh(&chunk, &mesh, 0, 0, tg.getter(), .none, .none);
    for (mesh.quads.items) |q| {
        if (!isModelRecord(q)) continue;
        const v = unpackCorner(q, 0, 0, 0);
        try std.testing.expectEqual(@as(f32, 1.0), v.skylight);
        try std.testing.expectEqual(@as(f32, 0.0), v.block_light);
    }
}

test "the face of a full cube next to a half block gets the sky light (REQ-VOXEL-003)" {
    const allocator = std.testing.allocator;
    var chunk = Chunk.init(allocator);
    defer chunk.deinit();
    // A full cube in the open sky, with a half block (b19, opacity 0) at
    // +X. The +X face of the cube reads the light of the half block cell
    // and the cells around it.
    try chunk.setBlock(5, 70, 6, .solid);
    try chunk.setBlock(6, 70, 6, .b19);
    var mesh = Mesh.init(allocator);
    defer mesh.deinit();
    try meshAlone(&chunk, &mesh);
    // The sky light goes through the half block with no loss.
    try std.testing.expectEqual(chunk_mod.MAX_SKYLIGHT, chunk.lightAt(6, 70, 6).sky);
    try std.testing.expectEqual(chunk_mod.MAX_SKYLIGHT, chunk.lightAt(6, 69, 6).sky);
    var seen = false;
    for (mesh.quads.items) |q| {
        if (isModelRecord(q)) continue;
        const face: Face = @fromBackingInt(@as(u3, @intCast((q[0] >> 16) & 0x7)));
        if (face != .px) continue;
        seen = true;
        for (0..4) |c| try std.testing.expectEqual(@as(f32, 1.0), unpackCorner(q, c, 0, 0).skylight);
    }
    try std.testing.expect(seen);
}

test "a model record keeps a cell y above 255 and the quad index" {
    for ([_]u32{ 0, 255, 256, 4095 }) |y| {
        for ([_]u16{ 0, 1, 0xFFFF }) |qi| {
            const q = packModelQuad(.{ 15, y, 3 }, qi, 7, @splat(1), @splat(0.5), @splat(0));
            try std.testing.expect(isModelRecord(q));
            try std.testing.expectEqual(y, cellY(q));
            try std.testing.expectEqual(qi, modelQuadIndex(q));
            try std.testing.expectEqual(@as(u32, 15), q[0] & 0xF);
            try std.testing.expectEqual(@as(u32, 3), (q[0] >> 12) & 0xF);
            try std.testing.expectEqual(@as(u32, 7), (q[3] >> 12) & 0xFF);
        }
    }
    // A greedy quad never has the model record bit.
    try std.testing.expect(!isModelRecord(packQuad(.nz, .{ 15, 4095, 15 }, 16, 256, 255, @splat(1), @splat(1), @splat(1))));
}

test "a box face has the corners and the winding of a greedy quad" {
    const cube = model_mod.box(.{ 0, 0, 0 }, .{ 1, 1, 1 }, @splat(model_mod.BoxFace{}));
    for (cube, 0..) |bq, f| {
        const face: Face = @fromBackingInt(@as(u3, @intCast(f)));
        try std.testing.expectEqual(face, bq.face);
        const q = packQuad(face, .{ 0, 0, 0 }, 1, 1, 1, @splat(1), @splat(1), @splat(0));
        for (0..4) |c| {
            const v = unpackCorner(q, c, 0, 0);
            try std.testing.expectEqual(bq.pos[c][0], v.pos[0]);
            try std.testing.expectEqual(bq.pos[c][1] + MIN_Y, v.pos[1]);
            try std.testing.expectEqual(bq.pos[c][2], v.pos[2]);
            try std.testing.expectEqual(bq.uv[c], v.uv);
        }
    }
}

// ---------------------------------------------------------------------------
// AO, smooth light and tint tests (REQ-VOXEL-008, REQ-VOXEL-009, REQ-VOXEL-010)
// ---------------------------------------------------------------------------

/// The quads of `mesh` with no tint records.
fn quadsOnly(mesh: *const Mesh) []const PackedQuad {
    var n: usize = 0;
    while (n < mesh.quads.items.len and isTintRecord(mesh.quads.items[n])) n += 1;
    return mesh.quads.items[n..];
}

/// The face of a greedy quad.
fn quadFace(q: PackedQuad) Face {
    return @fromBackingInt(@as(u3, @intCast((q[0] >> 16) & 0x7)));
}

/// Mesh `chunk` at the origin with `options` and the test getter.
fn meshWith(chunk: *Chunk, mesh: *Mesh, options: MeshOptions) !void {
    try chunk.computeSkylight();
    try chunk.computeBlockLight();
    const tg = TestGetter{ .chunk = chunk, .ox = 0, .oz = 0 };
    try generateMeshWith(chunk, mesh, 0, 0, tg.getter(), options);
}

test "a corner gets its AO from its 3 neighbour blocks: 0 to 3 occluders (REQ-VOXEL-008)" {
    // The rule: (3 - occluders) / 3, and 0 when both sides are solid.
    try std.testing.expectEqual(@as(f32, 1.0), aoValue(false, false, false));
    try std.testing.expectEqual(@as(f32, 2.0 / 3.0), aoValue(true, false, false));
    try std.testing.expectEqual(@as(f32, 2.0 / 3.0), aoValue(false, true, false));
    try std.testing.expectEqual(@as(f32, 2.0 / 3.0), aoValue(false, false, true));
    try std.testing.expectEqual(@as(f32, 1.0 / 3.0), aoValue(true, false, true));
    try std.testing.expectEqual(@as(f32, 0.0), aoValue(true, true, false));
    try std.testing.expectEqual(@as(f32, 0.0), aoValue(true, true, true));

    // The same rule in a mesh: one block, and 0 to 3 occluders around
    // corner 0 of its top face. Corner 0 of +Y is at step (0, 0): the
    // occluders are at -X, -Z and -X-Z in the layer above.
    const allocator = std.testing.allocator;
    const cases = [_]struct { cells: []const [3]i32, ao: f32 }{
        .{ .cells = &.{}, .ao = 1.0 },
        .{ .cells = &.{.{ 4, 71, 5 }}, .ao = 2.0 / 3.0 },
        .{ .cells = &.{.{ 4, 71, 4 }}, .ao = 2.0 / 3.0 },
        .{ .cells = &.{ .{ 4, 71, 5 }, .{ 4, 71, 4 } }, .ao = 1.0 / 3.0 },
        .{ .cells = &.{ .{ 4, 71, 5 }, .{ 5, 71, 4 } }, .ao = 0.0 },
        .{ .cells = &.{ .{ 4, 71, 5 }, .{ 5, 71, 4 }, .{ 4, 71, 4 } }, .ao = 0.0 },
    };
    for (cases) |case| {
        var chunk = Chunk.init(allocator);
        defer chunk.deinit();
        try chunk.setBlock(5, 70, 5, .solid);
        for (case.cells) |c| try chunk.setBlock(c[0], c[1], c[2], .solid);
        var mesh = Mesh.init(allocator);
        defer mesh.deinit();
        try meshWith(&chunk, &mesh, .{ .ao = .classic });
        var seen = false;
        for (quadsOnly(&mesh)) |q| {
            if (quadFace(q) != .py or cellY(q) != 70 or (q[0] & 0xF) != 5) continue;
            seen = true;
            try std.testing.expectEqual(case.ao, unpackCorner(q, 0, 0, 0).ao);
        }
        try std.testing.expect(seen);
        // AO off: every corner is 1.
        try meshWith(&chunk, &mesh, .{ .ao = .none });
        for (quadsOnly(&mesh)) |q| {
            for (0..4) |c| try std.testing.expectEqual(@as(f32, 1.0), unpackCorner(q, c, 0, 0).ao);
        }
    }
}

test "smooth light is the mean light of the 4 cells at each corner (REQ-VOXEL-008)" {
    const allocator = std.testing.allocator;
    var chunk = try testHillChunk(allocator);
    defer chunk.deinit();
    var mesh = Mesh.init(allocator);
    defer mesh.deinit();
    try meshWith(&chunk, &mesh, .{ .ao = .classic });
    const tg = TestGetter{ .chunk = &chunk, .ox = 0, .oz = 0 };
    const getter = tg.getter();
    var checked: usize = 0;
    for (quadsOnly(&mesh)) |q| {
        const face = quadFace(q);
        const fl = face_layouts[@backingInt(face)];
        for (0..4) |c| {
            const v = unpackCorner(q, c, 0, 0);
            // The 4 cells that touch the corner on the outward side.
            var p: [3]i32 = undefined;
            for (0..3) |a| p[a] = @intFromFloat(v.pos[a]);
            p[1] -= MIN_Y;
            if (!fl.positive) p[fl.normal_axis] -= 1;
            var sum: u32 = 0;
            for ([_]i32{ -1, 0 }) |di| for ([_]i32{ -1, 0 }) |dj| {
                var cell = p;
                cell[fl.i_axis] += di;
                cell[fl.j_axis] += dj;
                sum += lightSample(&chunk, getter, 0, 0, cell[0], cell[1], cell[2]).sky;
            };
            const want = @as(f32, @floatFromInt(sum)) / 4.0 / @as(f32, @floatFromInt(chunk_mod.MAX_SKYLIGHT));
            try std.testing.expectApproxEqAbs(want, v.skylight, 0.5 / LIGHT_STEPS);
            checked += 1;
        }
    }
    try std.testing.expect(checked > 100);
}

test "smooth light off gives each face the light of the cell in front of it (REQ-VOXEL-008)" {
    const allocator = std.testing.allocator;
    var chunk = try testHillChunk(allocator);
    defer chunk.deinit();
    var mesh = Mesh.init(allocator);
    defer mesh.deinit();
    try meshWith(&chunk, &mesh, .{ .ao = .none, .smooth_light = false });
    for (quadsOnly(&mesh)) |q| {
        const face = quadFace(q);
        const off = face_offsets[@backingInt(face)];
        const lx: i32 = @intCast(q[0] & 0xF);
        const ly: i32 = @intCast(cellY(q));
        const lz: i32 = @intCast((q[0] >> 12) & 0xF);
        const tg = TestGetter{ .chunk = &chunk, .ox = 0, .oz = 0 };
        const want = lightSample(&chunk, tg.getter(), 0, 0, lx + off[0], ly + off[1], lz + off[2]);
        for (0..4) |c| {
            const v = unpackCorner(q, c, 0, 0);
            try std.testing.expectEqual(@as(f32, @floatFromInt(want.sky)) / @as(f32, @floatFromInt(chunk_mod.MAX_SKYLIGHT)), v.skylight);
            try std.testing.expectEqual(unpackCorner(q, 0, 0, 0).block_light, v.block_light);
        }
    }
}

test "greedy faces with different AO, light or tint do not merge (REQ-VOXEL-010)" {
    const base: GreedyCell = .{ .present = true, .block_type = .solid, .ao = @splat(1), .sky = @splat(1), .bl = @splat(0) };
    try std.testing.expect(greedyCellEq(base, base));
    var other = base;
    other.ao = @splat(2.0 / 3.0);
    try std.testing.expect(!greedyCellEq(base, other));
    other = base;
    other.sky = @splat(0.5);
    try std.testing.expect(!greedyCellEq(base, other));
    other = base;
    other.bl = @splat(0.5);
    try std.testing.expect(!greedyCellEq(base, other));
    other = base;
    other.tint = 0x102030;
    try std.testing.expect(!greedyCellEq(base, other));
    // A cell with a gradient does not merge, also with itself.
    other = base;
    other.ao = .{ 1, 1, 2.0 / 3.0, 2.0 / 3.0 };
    try std.testing.expect(!greedyCellEq(other, other));

    // In a mesh: a row of 4 blocks has one top quad. An occluder next to
    // the first block changes its AO, so the row splits.
    const allocator = std.testing.allocator;
    for ([_]bool{ false, true }) |occluder| {
        var chunk = Chunk.init(allocator);
        defer chunk.deinit();
        for (2..6) |x| try chunk.setBlock(@intCast(x), 70, 5, .solid);
        if (occluder) try chunk.setBlock(1, 71, 5, .solid);
        var mesh = Mesh.init(allocator);
        defer mesh.deinit();
        try meshWith(&chunk, &mesh, .{ .ao = .classic });
        var tops: usize = 0;
        for (quadsOnly(&mesh)) |q| {
            if (quadFace(q) != .py or cellY(q) != 70 or (q[0] & 0xF) < 2) continue;
            tops += 1;
            // A merged quad has the same AO on its 4 corners.
            const merged = (q[0] >> 19) & 0xF != 0 or (q[0] >> 23) & 0xFF != 0;
            if (!merged) continue;
            const a0 = unpackCorner(q, 0, 0, 0).ao;
            for (1..4) |c| try std.testing.expectEqual(a0, unpackCorner(q, c, 0, 0).ao);
        }
        if (occluder) try std.testing.expect(tops > 1) else try std.testing.expectEqual(@as(usize, 1), tops);
    }
}

test "quads with a tint index get the tint colour of the content (REQ-VOXEL-009)" {
    const allocator = std.testing.allocator;
    var chunk = Chunk.init(allocator);
    defer chunk.deinit();
    // A layer of b6 (one colour on each face) and a layer of b5 (one
    // colour for each cell on the top face only).
    for (0..CHUNK_W) |x| for (0..CHUNK_W) |z| {
        try chunk.setBlock(@intCast(x), 60, @intCast(z), .b6);
        try chunk.setBlock(@intCast(x), 80, @intCast(z), .b5);
    };
    var mesh = Mesh.init(allocator);
    defer mesh.deinit();
    const ox: i32 = 16 * 3;
    const oz: i32 = -16;
    try chunk.computeSkylight();
    try chunk.computeBlockLight();
    const tg = TestGetter{ .chunk = &chunk, .ox = ox, .oz = oz };
    try generateMeshWith(&chunk, &mesh, ox, oz, tg.getter(), .{});

    // The tint records come first: 126 slots in 32 records.
    var records: usize = 0;
    while (isTintRecord(mesh.quads.items[records])) records += 1;
    try std.testing.expectEqual((MAX_TINT_SLOTS + 3) / 4, records);
    const all = mesh.quads.items;
    var b5_exact: usize = 0;
    var b5_tops: usize = 0;
    var b6_quads: usize = 0;
    for (all[records..]) |q| {
        try std.testing.expect(!isTintRecord(q));
        const block: BlockType = @fromBackingInt(@as(u8, @intCast((q[3] >> 12) & 0xFF)));
        const lx: i32 = @intCast(q[0] & 0xF);
        const ly: i32 = @intCast(cellY(q));
        const lz: i32 = @intCast((q[0] >> 12) & 0xF);
        const got = quadTint(all, q);
        switch (block) {
            .b6 => {
                b6_quads += 1;
                try std.testing.expectEqual(@as(?[3]u8, .{ 40, 180, 60 }), got);
            },
            .b5 => {
                if (quadFace(q) != .py) {
                    try std.testing.expectEqual(@as(?[3]u8, null), got);
                    continue;
                }
                // A tinted face does not merge with a face of another colour.
                try std.testing.expectEqual(@as(u32, 0), (q[0] >> 19) & 0xF);
                try std.testing.expectEqual(@as(u32, 0), (q[0] >> 23) & 0xFF);
                b5_tops += 1;
                const want = sw_content_tint(.b5, 0, ox + lx, MIN_Y + ly, oz + lz);
                // The palette is full after 126 colours: then the quad gets
                // the nearest colour of the palette.
                if (std.mem.eql(u8, &want, &got.?)) b5_exact += 1;
            },
            else => return error.TestUnexpectedResult,
        }
    }
    try std.testing.expectEqual(@as(usize, CHUNK_W * CHUNK_W), b5_tops);
    try std.testing.expect(b5_exact >= MAX_TINT_SLOTS - 1);
    try std.testing.expect(b5_exact < b5_tops);
    try std.testing.expect(b6_quads > 0);

    // A model quad gets the tint of its tint index: the b20 plane. A full
    // cube with no tint index has tint slot 0.
    var small = Chunk.init(allocator);
    defer small.deinit();
    try small.setBlock(3, 90, 3, .b20);
    try small.setBlock(6, 70, 3, .solid);
    try meshWith(&small, &mesh, .{});
    try std.testing.expect(isTintRecord(mesh.quads.items[0]));
    var b20_quads: usize = 0;
    for (quadsOnly(&mesh)) |q| {
        if (!isModelRecord(q)) {
            try std.testing.expectEqual(@as(u32, 0), tintSlot(q));
            continue;
        }
        b20_quads += 1;
        try std.testing.expectEqual(@as(?[3]u8, sw_content_tint(.b20, 0, 3, MIN_Y + 90, 3)), quadTint(mesh.quads.items, q));
    }
    try std.testing.expectEqual(@as(usize, 2), b20_quads);

    // A mesh with no tint has no tint records and the same bytes.
    var plain = Chunk.init(allocator);
    defer plain.deinit();
    try plain.setBlock(3, 70, 3, .solid);
    try meshWith(&plain, &mesh, .{});
    for (mesh.quads.items) |q| {
        try std.testing.expectEqual(@as(u32, 0), tintSlot(q));
    }
}

/// The tint colour of the test content.
fn sw_content_tint(block: BlockType, index: u8, x: i32, y: i32, z: i32) [3]u8 {
    return content.tint(block, index, x, y, z);
}

test "the tint palette keeps 126 colours, then gives the nearest one" {
    var p: TintPalette = .{};
    try std.testing.expectEqual(@as(u32, 0), p.slot(NO_TINT));
    for (0..MAX_TINT_SLOTS) |i| {
        const rgb: u32 = @intCast(i * 2);
        try std.testing.expectEqual(@as(u32, @intCast(i + 1)), p.slot(rgb));
        try std.testing.expectEqual(@as(u32, @intCast(i + 1)), p.slot(rgb));
    }
    // Full: 7 is nearest to 6 and 8 (slots 4 and 5): the lowest slot wins.
    try std.testing.expectEqual(@as(u32, 4), p.slot(7));
    try std.testing.expectEqual(@as(u32, MAX_TINT_SLOTS), p.slot(0xFF));
}

test "a model quad on the cell grid gets AO and smooth light, a quad off the grid gets flat light (REQ-VOXEL-008)" {
    const allocator = std.testing.allocator;
    var chunk = Chunk.init(allocator);
    defer chunk.deinit();
    // A half block (b19) on a floor, with a wall block at -X. The floor
    // hides the bottom quad of the half block.
    for (3..8) |x| for (3..8) |z| try chunk.setBlock(@intCast(x), 69, @intCast(z), .solid);
    try chunk.setBlock(5, 70, 5, .b19);
    try chunk.setBlock(4, 70, 6, .solid);
    var mesh = Mesh.init(allocator);
    defer mesh.deinit();
    try meshWith(&chunk, &mesh, .{ .ao = .classic });
    const tg = TestGetter{ .chunk = &chunk, .ox = 0, .oz = 0 };
    var faces = std.EnumSet(Face){};
    for (quadsOnly(&mesh)) |q| {
        if (!isModelRecord(q)) continue;
        const baked = models.quads[modelQuadIndex(q)];
        faces.insert(baked.face);
        const full_ao = computeFaceAOClassic(&chunk, tg.getter(), 0, 0, 5, 70, 5, baked.face);
        const full_light = computeFaceLight(&chunk, tg.getter(), 0, 0, 5, 70, 5, baked.face);
        switch (baked.face) {
            .py => {
                // The top is inside the cell: off the grid. Flat light from
                // the cell above, and AO 1.
                const above = chunk.lightAt(5, 71, 5);
                for (0..4) |c| {
                    const v = unpackCorner(q, c, 0, 0);
                    try std.testing.expectEqual(@as(f32, 1.0), v.ao);
                    try std.testing.expectEqual(@as(f32, @floatFromInt(above.sky)) / 15.0, v.skylight);
                }
            },
            else => {
                // A side: on the grid, from y 0 to 0.5. The bottom corners
                // have the values of the full face, the top corners the
                // mean of the bottom and the top of the full face.
                const fl = face_layouts[@backingInt(baked.face)];
                for (0..4) |c| {
                    const v = unpackCorner(q, c, 0, 0);
                    const i = baked.pos[c][fl.i_axis];
                    const j = baked.pos[c][fl.j_axis];
                    const want_ao = faceValueAt(baked.face, full_ao, .{ i, j });
                    const want_sky = faceValueAt(baked.face, full_light.sky, .{ i, j });
                    try std.testing.expectApproxEqAbs(want_ao, v.ao, 0.5 / AO_STEPS);
                    try std.testing.expectApproxEqAbs(want_sky, v.skylight, 0.5 / LIGHT_STEPS);
                }
            },
        }
    }
    // The bottom is hidden by the floor (cull face -Y).
    try std.testing.expect(!faces.contains(.ny));
    try std.testing.expectEqual(@as(usize, 5), faces.count());

    // The -X side touches the wall corner at +Z: its AO is less than 1 at
    // the bottom corner on that side.
    var darker = false;
    for (quadsOnly(&mesh)) |q| {
        if (!isModelRecord(q) or models.quads[modelQuadIndex(q)].face != .nx) continue;
        for (0..4) |c| darker = darker or unpackCorner(q, c, 0, 0).ao < 1.0;
    }
    try std.testing.expect(darker);
}

test "faceValueAt gives the corner values at the corners and their mean in the middle" {
    for (0..6) |f| {
        const face: Face = @fromBackingInt(@as(u3, @intCast(f)));
        const fl = face_layouts[f];
        const v = [4]f32{ 0.1, 0.2, 0.4, 0.8 };
        for (0..4) |c| {
            const ij = [2]f32{ @floatFromInt(fl.pos[c][0]), @floatFromInt(fl.pos[c][1]) };
            try std.testing.expectEqual(v[c], faceValueAt(face, v, ij));
        }
        try std.testing.expectApproxEqAbs(@as(f32, 0.375), faceValueAt(face, v, .{ 0.5, 0.5 }), 1e-6);
    }
}
