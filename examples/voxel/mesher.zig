const std = @import("std");
const chunk_mod = @import("chunk.zig");
const gpu_mod = @import("sw_gpu");
const Chunk = chunk_mod.Chunk;
const BlockType = chunk_mod.BlockType;
const BlockGetter = chunk_mod.BlockGetter;
const CHUNK_W = chunk_mod.CHUNK_W;
const CHUNK_H = chunk_mod.CHUNK_H;
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
    block_light: f32 = 0.0, // offset 44 — block-light brightness 0..1 (0 = no emitter nearby, 1 = adjacent to glowstone)
};

const SortEntry = struct { idx: usize, dist: f32 };

/// The mesh of one chunk, in the GPU format: one 16-byte PackedQuad per quad,
/// and the y range of the quads. The upload writes `quads` to the GPU as it
/// is. The mesher makes the GPU format directly, so a mesh can cross a
/// thread or worker boundary with no conversion.
pub const Mesh = struct {
    allocator: std.mem.Allocator,
    /// One PackedQuad per quad, in the order the mesher makes them.
    quads: std.ArrayList(PackedQuad),
    /// The lowest and the highest y of the quads, for the frustum cull.
    /// With no quads, y_min is CHUNK_H and y_max is 0.
    y_min: f32 = CHUNK_H,
    y_max: f32 = 0,
    /// Scratch for sortByDepth. It grows and never shrinks.
    sort_scratch: []SortEntry = &.{},
    /// The quads in back-to-front order. sortByDepth writes it. The upload
    /// reads it when the depth test is off.
    sorted_quads: []PackedQuad = &.{},
    /// True when sort_scratch holds the sorted order of the previous frame.
    /// False after a rebuild: the next sort is a full sort.
    sort_valid: bool = false,

    pub fn init(allocator: std.mem.Allocator) Mesh {
        return .{ .allocator = allocator, .quads = .empty };
    }

    pub fn deinit(self: *Mesh) void {
        self.quads.deinit(self.allocator);
        if (self.sort_scratch.len > 0) self.allocator.free(self.sort_scratch);
        if (self.sorted_quads.len > 0) self.allocator.free(self.sorted_quads);
    }

    pub fn quadCount(self: *const Mesh) usize {
        return self.quads.items.len;
    }

    pub fn clear(self: *Mesh) void {
        self.quads.clearRetainingCapacity();
        self.y_min = CHUNK_H;
        self.y_max = 0;
        self.sort_valid = false; // mesh rebuilt — scratch order is stale
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
        self.y_min = CHUNK_H;
        self.y_max = 0;
        if (self.sort_scratch.len > 0) {
            self.allocator.free(self.sort_scratch);
            self.sort_scratch = &.{};
        }
        if (self.sorted_quads.len > 0) {
            self.allocator.free(self.sorted_quads);
            self.sorted_quads = &.{};
        }
        self.sort_valid = false;
    }

    /// Append one quad that spans y_lo..y_hi.
    fn addQuad(self: *Mesh, q: PackedQuad, y_lo: f32, y_hi: f32) !void {
        try self.quads.append(self.allocator, q);
        self.y_min = @min(self.y_min, y_lo);
        self.y_max = @max(self.y_max, y_hi);
    }

    /// Sort the quads back to front into `sorted_quads`, for rendering with
    /// the hardware depth test off. The sort key is view-space depth: the dot
    /// product of (quad centroid - camera) with the camera forward vector.
    /// That is the Z the GPU projection uses, so faces in front of each other
    /// along the view direction sort correctly, also when they are to the
    /// side of the camera axis. (world_ox, world_oz) is the chunk origin.
    ///
    /// The scratch buffers stay from frame to frame. After the first sort,
    /// an insertion sort on the order of the previous frame costs O(n) when
    /// the camera moves a little.
    pub fn sortByDepth(self: *Mesh, camera_pos: [3]f32, camera_fwd: [3]f32, world_ox: i32, world_oz: i32) !void {
        const quad_count = self.quads.items.len;
        if (quad_count == 0) return;

        // Grow the scratch buffers only when needed (never shrink).
        if (quad_count > self.sort_scratch.len) {
            if (self.sort_scratch.len > 0) self.allocator.free(self.sort_scratch);
            if (self.sorted_quads.len > 0) self.allocator.free(self.sorted_quads);
            self.sort_scratch = &.{};
            self.sorted_quads = &.{};
            self.sort_scratch = try self.allocator.alloc(SortEntry, quad_count);
            self.sorted_quads = try self.allocator.alloc(PackedQuad, quad_count);
            self.sort_valid = false; // fresh allocation — scratch must be repopulated
        }

        const scratch = self.sort_scratch[0..quad_count];
        const depth = struct {
            fn of(q: PackedQuad, ox: i32, oz: i32, pos: [3]f32, fwd: [3]f32) f32 {
                const c = quadCentroid(q, ox, oz);
                const dx = c[0] - pos[0];
                const dy = c[1] - pos[1];
                const dz = c[2] - pos[2];
                // View-space depth: dot(centroid_delta, camera_forward). Positive = in front.
                return dx * fwd[0] + dy * fwd[1] + dz * fwd[2];
            }
        }.of;

        if (self.sort_valid) {
            // Scratch holds the sorted order from last frame — update the depths in place.
            for (scratch) |*entry| {
                entry.dist = depth(self.quads.items[entry.idx], world_ox, world_oz, camera_pos, camera_fwd);
            }
            // Insertion sort: O(n) for nearly-sorted data (camera moved a little)
            var i: usize = 1;
            while (i < quad_count) : (i += 1) {
                const key = scratch[i];
                var j: usize = i;
                while (j > 0 and scratch[j - 1].dist < key.dist) : (j -= 1) {
                    scratch[j] = scratch[j - 1];
                }
                scratch[j] = key;
            }
        } else {
            // First frame after a rebuild — populate scratch and use pdqsort.
            for (0..quad_count) |i| {
                scratch[i] = .{ .idx = i, .dist = depth(self.quads.items[i], world_ox, world_oz, camera_pos, camera_fwd) };
            }
            std.mem.sort(SortEntry, scratch, {}, struct {
                fn lessThan(_: void, a: SortEntry, b: SortEntry) bool {
                    return a.dist > b.dist;
                }
            }.lessThan);
            self.sort_valid = true;
        }

        // `quads` stays in mesher order, so scratch[i].idx stays a stable
        // quad identifier from frame to frame.
        for (scratch, 0..) |entry, i| self.sorted_quads[i] = self.quads.items[entry.idx];
    }
};

const BlockPos = struct { x: i32, y: i32, z: i32 };

// ---------------------------------------------------------------------------
// Face data
// ---------------------------------------------------------------------------

const Face = enum { px, nx, py, ny, pz, nz };

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

/// Fast face-render check. For neighbours within this chunk's bounds (~92% of cases),
/// uses direct array access. Only falls back to the world getter for out-of-bounds
/// neighbours (chunk boundaries), enabling correct cross-chunk face culling.
fn shouldRenderFace(chunk: *const Chunk, getter: BlockGetter, lx: i32, ly: i32, lz: i32, world_ox: i32, world_oz: i32, face: Face) bool {
    const offset = face_offsets[@backingInt(face)];
    const nx = lx + offset[0];
    const ny = ly + offset[1];
    const nz = lz + offset[2];
    // Fast path: neighbour is within this chunk (paletted bounds-free read,
    // no HashMap). resolveBlockRaw skips the bounds check we just did.
    if (nx >= 0 and nx < CHUNK_W and ny >= 0 and ny < CHUNK_H and nz >= 0 and nz < CHUNK_W) {
        return chunk.resolveBlockRaw(nx, ny, nz) == .air;
    }
    // Slow path: neighbour in adjacent chunk — world HashMap lookup
    return getter.getBlock(world_ox + nx, ny, world_oz + nz) == .air;
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
        return chunk.resolveBlockRaw(lx, wy, lz) != .air;
    }
    return getter.getBlock(wx, wy, wz) != .air;
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
///   - .classic        — face-plane 8-neighbour Mojang AO (3 samples per vertex)
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

/// Classic per-vertex Mojang/Minecraft AO.
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
// Skylight sampling
// ---------------------------------------------------------------------------

/// Read the skylight value at world (wx, wy, wz).
/// Fast path: if (wx, wy, wz) is inside the chunk being meshed, read its
/// skylight grid directly. Slow path: query the world via the getter so the
/// sample crosses chunk boundaries cleanly. Phase 1 has no cross-chunk light
/// propagation, but each chunk independently flood-fills its own air, so
/// adjacent chunks have correct skylight for cells that don't depend on a
/// neighbour's light path. The visible artifact is limited to caves whose
/// brightest light source is on the OTHER side of a chunk seam.
fn skylightSample(chunk: *const Chunk, getter: BlockGetter, world_ox: i32, world_oz: i32, wx: i32, wy: i32, wz: i32) u8 {
    const lx = wx - world_ox;
    const lz = wz - world_oz;
    if (lx >= 0 and lx < CHUNK_W and wy >= 0 and wy < CHUNK_H and lz >= 0 and lz < CHUNK_W) {
        return chunk.skylight.get(@intCast(lx), @intCast(wy), @intCast(lz));
    }
    return getter.getSkylight(wx, wy, wz);
}

/// Per-vertex skylight brightness for a face.
///
/// For each of the 4 vertices, average the skylight of the 4 air cells
/// adjacent to the vertex on the outward side of the face. This is
/// structurally identical to how `computeFaceAOClassic` averages 3
/// neighbours per vertex; here we average 4 to get a smooth analog gradient
/// (skylight is a continuous 0..15 quantity, unlike AO which is 0/1 per
/// neighbour). Solid cells contribute 0, which gives natural darkening when
/// a vertex sits in a corner against a wall — exactly the look we want.
///
/// Returned values are in [0, 1] (skylight / MAX_SKYLIGHT).
///
/// When the lighting mode is `.none` the caller passes a baseline of 1.0 for
/// every vertex by NOT calling this function — it's only invoked when
/// `lighting_mode == .skylight`.
fn computeFaceSkylight(chunk: *const Chunk, getter: BlockGetter, world_ox: i32, world_oz: i32, wx: i32, wy: i32, wz: i32, face: Face) [4]f32 {
    const max_f: f32 = @floatFromInt(chunk_mod.MAX_SKYLIGHT);
    const inv4: f32 = 1.0 / 4.0;
    return switch (face) {
        .px => blk: {
            // +X face at x = wx + 1. Outward column samples the slab wx+1.
            // For each vertex (varying y, z), average the 4 cells in the
            // 2×2 outward neighbourhood at that vertex's y/z corner.
            const a000 = skylightSample(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz - 1);
            const a010 = skylightSample(chunk, getter, world_ox, world_oz, wx + 1, wy, wz - 1);
            const a020 = skylightSample(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz - 1);
            const a001 = skylightSample(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz);
            const a011 = skylightSample(chunk, getter, world_ox, world_oz, wx + 1, wy, wz);
            const a021 = skylightSample(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz);
            const a002 = skylightSample(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz + 1);
            const a012 = skylightSample(chunk, getter, world_ox, world_oz, wx + 1, wy, wz + 1);
            const a022 = skylightSample(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz + 1);
            // Corner order matches the .px entry of face_layouts: (y, z) → (0,0)(1,0)(1,1)(0,1).
            const v0: f32 = @floatFromInt(@as(u32, a000) + a010 + a001 + a011);
            const v1: f32 = @floatFromInt(@as(u32, a010) + a020 + a011 + a021);
            const v2: f32 = @floatFromInt(@as(u32, a011) + a021 + a012 + a022);
            const v3: f32 = @floatFromInt(@as(u32, a001) + a011 + a002 + a012);
            break :blk .{ v0 * inv4 / max_f, v1 * inv4 / max_f, v2 * inv4 / max_f, v3 * inv4 / max_f };
        },
        .nx => blk: {
            const a000 = skylightSample(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz - 1);
            const a010 = skylightSample(chunk, getter, world_ox, world_oz, wx - 1, wy, wz - 1);
            const a020 = skylightSample(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz - 1);
            const a001 = skylightSample(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz);
            const a011 = skylightSample(chunk, getter, world_ox, world_oz, wx - 1, wy, wz);
            const a021 = skylightSample(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz);
            const a002 = skylightSample(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz + 1);
            const a012 = skylightSample(chunk, getter, world_ox, world_oz, wx - 1, wy, wz + 1);
            const a022 = skylightSample(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz + 1);
            // Corner order matches the .nx entry of face_layouts: (y, z) → (0,1)(1,1)(1,0)(0,0).
            const v0: f32 = @floatFromInt(@as(u32, a001) + a011 + a002 + a012);
            const v1: f32 = @floatFromInt(@as(u32, a011) + a021 + a012 + a022);
            const v2: f32 = @floatFromInt(@as(u32, a010) + a020 + a011 + a021);
            const v3: f32 = @floatFromInt(@as(u32, a000) + a010 + a001 + a011);
            break :blk .{ v0 * inv4 / max_f, v1 * inv4 / max_f, v2 * inv4 / max_f, v3 * inv4 / max_f };
        },
        .py => blk: {
            // +Y face at y = wy + 1. Outward slab is wy + 1.
            const a000 = skylightSample(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz - 1);
            const a100 = skylightSample(chunk, getter, world_ox, world_oz, wx, wy + 1, wz - 1);
            const a200 = skylightSample(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz - 1);
            const a001 = skylightSample(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz);
            const a101 = skylightSample(chunk, getter, world_ox, world_oz, wx, wy + 1, wz);
            const a201 = skylightSample(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz);
            const a002 = skylightSample(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz + 1);
            const a102 = skylightSample(chunk, getter, world_ox, world_oz, wx, wy + 1, wz + 1);
            const a202 = skylightSample(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz + 1);
            // Corner order matches the .py entry of face_layouts: (x, z) → (0,0)(0,1)(1,1)(1,0).
            const v0: f32 = @floatFromInt(@as(u32, a000) + a100 + a001 + a101);
            const v1: f32 = @floatFromInt(@as(u32, a001) + a101 + a002 + a102);
            const v2: f32 = @floatFromInt(@as(u32, a101) + a201 + a102 + a202);
            const v3: f32 = @floatFromInt(@as(u32, a100) + a200 + a101 + a201);
            break :blk .{ v0 * inv4 / max_f, v1 * inv4 / max_f, v2 * inv4 / max_f, v3 * inv4 / max_f };
        },
        .ny => blk: {
            const a000 = skylightSample(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz - 1);
            const a100 = skylightSample(chunk, getter, world_ox, world_oz, wx, wy - 1, wz - 1);
            const a200 = skylightSample(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz - 1);
            const a001 = skylightSample(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz);
            const a101 = skylightSample(chunk, getter, world_ox, world_oz, wx, wy - 1, wz);
            const a201 = skylightSample(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz);
            const a002 = skylightSample(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz + 1);
            const a102 = skylightSample(chunk, getter, world_ox, world_oz, wx, wy - 1, wz + 1);
            const a202 = skylightSample(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz + 1);
            // Corner order matches the .ny entry of face_layouts: (x, z) → (0,1)(0,0)(1,0)(1,1).
            const v0: f32 = @floatFromInt(@as(u32, a001) + a101 + a002 + a102);
            const v1: f32 = @floatFromInt(@as(u32, a000) + a100 + a001 + a101);
            const v2: f32 = @floatFromInt(@as(u32, a100) + a200 + a101 + a201);
            const v3: f32 = @floatFromInt(@as(u32, a101) + a201 + a102 + a202);
            break :blk .{ v0 * inv4 / max_f, v1 * inv4 / max_f, v2 * inv4 / max_f, v3 * inv4 / max_f };
        },
        .pz => blk: {
            // +Z face at z = wz + 1. Outward slab is wz + 1.
            const a000 = skylightSample(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz + 1);
            const a100 = skylightSample(chunk, getter, world_ox, world_oz, wx, wy - 1, wz + 1);
            const a200 = skylightSample(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz + 1);
            const a010 = skylightSample(chunk, getter, world_ox, world_oz, wx - 1, wy, wz + 1);
            const a110 = skylightSample(chunk, getter, world_ox, world_oz, wx, wy, wz + 1);
            const a210 = skylightSample(chunk, getter, world_ox, world_oz, wx + 1, wy, wz + 1);
            const a020 = skylightSample(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz + 1);
            const a120 = skylightSample(chunk, getter, world_ox, world_oz, wx, wy + 1, wz + 1);
            const a220 = skylightSample(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz + 1);
            // Corner order matches the .pz entry of face_layouts: (x, y) → (0,0)(1,0)(1,1)(0,1).
            const v0: f32 = @floatFromInt(@as(u32, a000) + a100 + a010 + a110);
            const v1: f32 = @floatFromInt(@as(u32, a100) + a200 + a110 + a210);
            const v2: f32 = @floatFromInt(@as(u32, a110) + a210 + a120 + a220);
            const v3: f32 = @floatFromInt(@as(u32, a010) + a110 + a020 + a120);
            break :blk .{ v0 * inv4 / max_f, v1 * inv4 / max_f, v2 * inv4 / max_f, v3 * inv4 / max_f };
        },
        .nz => blk: {
            const a000 = skylightSample(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz - 1);
            const a100 = skylightSample(chunk, getter, world_ox, world_oz, wx, wy - 1, wz - 1);
            const a200 = skylightSample(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz - 1);
            const a010 = skylightSample(chunk, getter, world_ox, world_oz, wx - 1, wy, wz - 1);
            const a110 = skylightSample(chunk, getter, world_ox, world_oz, wx, wy, wz - 1);
            const a210 = skylightSample(chunk, getter, world_ox, world_oz, wx + 1, wy, wz - 1);
            const a020 = skylightSample(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz - 1);
            const a120 = skylightSample(chunk, getter, world_ox, world_oz, wx, wy + 1, wz - 1);
            const a220 = skylightSample(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz - 1);
            // Corner order matches the .nz entry of face_layouts: (x, y) → (1,0)(0,0)(0,1)(1,1).
            const v0: f32 = @floatFromInt(@as(u32, a100) + a200 + a110 + a210);
            const v1: f32 = @floatFromInt(@as(u32, a000) + a100 + a010 + a110);
            const v2: f32 = @floatFromInt(@as(u32, a010) + a110 + a020 + a120);
            const v3: f32 = @floatFromInt(@as(u32, a110) + a210 + a120 + a220);
            break :blk .{ v0 * inv4 / max_f, v1 * inv4 / max_f, v2 * inv4 / max_f, v3 * inv4 / max_f };
        },
    };
}

// ---------------------------------------------------------------------------
// Block-light sampling (phase 3)
// ---------------------------------------------------------------------------

/// Read the block-light value at world (wx, wy, wz). Fast path reads the
/// owning chunk's grid directly; out-of-chunk samples fall through to the
/// world getter (which in phase 3 always returns 0 across chunk boundaries
/// because cross-chunk block-light propagation is deliberately out of scope).
fn blockLightSample(chunk: *const Chunk, getter: BlockGetter, world_ox: i32, world_oz: i32, wx: i32, wy: i32, wz: i32) u8 {
    const lx = wx - world_ox;
    const lz = wz - world_oz;
    if (lx >= 0 and lx < CHUNK_W and wy >= 0 and wy < CHUNK_H and lz >= 0 and lz < CHUNK_W) {
        return chunk.block_light.get(@intCast(lx), @intCast(wy), @intCast(lz));
    }
    return getter.getBlockLight(wx, wy, wz);
}

/// Per-vertex block-light brightness for a face.
///
/// Shape mirrors `computeFaceSkylight`: for each of the 4 vertices, average
/// the block-light of the 4 air cells in the 2×2 outward neighbourhood at
/// that vertex corner.
///
/// CRITICAL DIFFERENCE from skylight: a face belonging to an emissive block
/// (e.g. a glowstone) must render at the emitter's own level, not at the
/// slightly-dimmer value one BFS hop away in the outward air. This function
/// folds the face-owner's own block-light into the final value via `max`:
///
///     block_light[i] = max(outward_mean[i], owner_level)
///
/// The owner_level comes from `blockLightSample(wx, wy, wz)` — the cell the
/// face belongs to. For non-emissive solids this is 0 (no effect); for a
/// glowstone cell it is `MAX_BLOCK_LIGHT` and the face lights up fully.
fn computeFaceBlockLight(chunk: *const Chunk, getter: BlockGetter, world_ox: i32, world_oz: i32, wx: i32, wy: i32, wz: i32, face: Face) [4]f32 {
    const max_f: f32 = @floatFromInt(chunk_mod.MAX_BLOCK_LIGHT);
    const inv4: f32 = 1.0 / 4.0;
    const owner_u8 = blockLightSample(chunk, getter, world_ox, world_oz, wx, wy, wz);
    const owner_f: f32 = @floatFromInt(owner_u8);
    const owner_norm = owner_f / max_f;

    const raw: [4]f32 = switch (face) {
        .px => blk: {
            const a000 = blockLightSample(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz - 1);
            const a010 = blockLightSample(chunk, getter, world_ox, world_oz, wx + 1, wy, wz - 1);
            const a020 = blockLightSample(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz - 1);
            const a001 = blockLightSample(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz);
            const a011 = blockLightSample(chunk, getter, world_ox, world_oz, wx + 1, wy, wz);
            const a021 = blockLightSample(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz);
            const a002 = blockLightSample(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz + 1);
            const a012 = blockLightSample(chunk, getter, world_ox, world_oz, wx + 1, wy, wz + 1);
            const a022 = blockLightSample(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz + 1);
            const v0: f32 = @floatFromInt(@as(u32, a000) + a010 + a001 + a011);
            const v1: f32 = @floatFromInt(@as(u32, a010) + a020 + a011 + a021);
            const v2: f32 = @floatFromInt(@as(u32, a011) + a021 + a012 + a022);
            const v3: f32 = @floatFromInt(@as(u32, a001) + a011 + a002 + a012);
            break :blk .{ v0 * inv4 / max_f, v1 * inv4 / max_f, v2 * inv4 / max_f, v3 * inv4 / max_f };
        },
        .nx => blk: {
            const a000 = blockLightSample(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz - 1);
            const a010 = blockLightSample(chunk, getter, world_ox, world_oz, wx - 1, wy, wz - 1);
            const a020 = blockLightSample(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz - 1);
            const a001 = blockLightSample(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz);
            const a011 = blockLightSample(chunk, getter, world_ox, world_oz, wx - 1, wy, wz);
            const a021 = blockLightSample(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz);
            const a002 = blockLightSample(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz + 1);
            const a012 = blockLightSample(chunk, getter, world_ox, world_oz, wx - 1, wy, wz + 1);
            const a022 = blockLightSample(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz + 1);
            const v0: f32 = @floatFromInt(@as(u32, a001) + a011 + a002 + a012);
            const v1: f32 = @floatFromInt(@as(u32, a011) + a021 + a012 + a022);
            const v2: f32 = @floatFromInt(@as(u32, a010) + a020 + a011 + a021);
            const v3: f32 = @floatFromInt(@as(u32, a000) + a010 + a001 + a011);
            break :blk .{ v0 * inv4 / max_f, v1 * inv4 / max_f, v2 * inv4 / max_f, v3 * inv4 / max_f };
        },
        .py => blk: {
            const a000 = blockLightSample(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz - 1);
            const a100 = blockLightSample(chunk, getter, world_ox, world_oz, wx, wy + 1, wz - 1);
            const a200 = blockLightSample(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz - 1);
            const a001 = blockLightSample(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz);
            const a101 = blockLightSample(chunk, getter, world_ox, world_oz, wx, wy + 1, wz);
            const a201 = blockLightSample(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz);
            const a002 = blockLightSample(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz + 1);
            const a102 = blockLightSample(chunk, getter, world_ox, world_oz, wx, wy + 1, wz + 1);
            const a202 = blockLightSample(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz + 1);
            const v0: f32 = @floatFromInt(@as(u32, a000) + a100 + a001 + a101);
            const v1: f32 = @floatFromInt(@as(u32, a001) + a101 + a002 + a102);
            const v2: f32 = @floatFromInt(@as(u32, a101) + a201 + a102 + a202);
            const v3: f32 = @floatFromInt(@as(u32, a100) + a200 + a101 + a201);
            break :blk .{ v0 * inv4 / max_f, v1 * inv4 / max_f, v2 * inv4 / max_f, v3 * inv4 / max_f };
        },
        .ny => blk: {
            const a000 = blockLightSample(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz - 1);
            const a100 = blockLightSample(chunk, getter, world_ox, world_oz, wx, wy - 1, wz - 1);
            const a200 = blockLightSample(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz - 1);
            const a001 = blockLightSample(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz);
            const a101 = blockLightSample(chunk, getter, world_ox, world_oz, wx, wy - 1, wz);
            const a201 = blockLightSample(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz);
            const a002 = blockLightSample(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz + 1);
            const a102 = blockLightSample(chunk, getter, world_ox, world_oz, wx, wy - 1, wz + 1);
            const a202 = blockLightSample(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz + 1);
            const v0: f32 = @floatFromInt(@as(u32, a001) + a101 + a002 + a102);
            const v1: f32 = @floatFromInt(@as(u32, a000) + a100 + a001 + a101);
            const v2: f32 = @floatFromInt(@as(u32, a100) + a200 + a101 + a201);
            const v3: f32 = @floatFromInt(@as(u32, a101) + a201 + a102 + a202);
            break :blk .{ v0 * inv4 / max_f, v1 * inv4 / max_f, v2 * inv4 / max_f, v3 * inv4 / max_f };
        },
        .pz => blk: {
            const a000 = blockLightSample(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz + 1);
            const a100 = blockLightSample(chunk, getter, world_ox, world_oz, wx, wy - 1, wz + 1);
            const a200 = blockLightSample(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz + 1);
            const a010 = blockLightSample(chunk, getter, world_ox, world_oz, wx - 1, wy, wz + 1);
            const a110 = blockLightSample(chunk, getter, world_ox, world_oz, wx, wy, wz + 1);
            const a210 = blockLightSample(chunk, getter, world_ox, world_oz, wx + 1, wy, wz + 1);
            const a020 = blockLightSample(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz + 1);
            const a120 = blockLightSample(chunk, getter, world_ox, world_oz, wx, wy + 1, wz + 1);
            const a220 = blockLightSample(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz + 1);
            const v0: f32 = @floatFromInt(@as(u32, a000) + a100 + a010 + a110);
            const v1: f32 = @floatFromInt(@as(u32, a100) + a200 + a110 + a210);
            const v2: f32 = @floatFromInt(@as(u32, a110) + a210 + a120 + a220);
            const v3: f32 = @floatFromInt(@as(u32, a010) + a110 + a020 + a120);
            break :blk .{ v0 * inv4 / max_f, v1 * inv4 / max_f, v2 * inv4 / max_f, v3 * inv4 / max_f };
        },
        .nz => blk: {
            const a000 = blockLightSample(chunk, getter, world_ox, world_oz, wx - 1, wy - 1, wz - 1);
            const a100 = blockLightSample(chunk, getter, world_ox, world_oz, wx, wy - 1, wz - 1);
            const a200 = blockLightSample(chunk, getter, world_ox, world_oz, wx + 1, wy - 1, wz - 1);
            const a010 = blockLightSample(chunk, getter, world_ox, world_oz, wx - 1, wy, wz - 1);
            const a110 = blockLightSample(chunk, getter, world_ox, world_oz, wx, wy, wz - 1);
            const a210 = blockLightSample(chunk, getter, world_ox, world_oz, wx + 1, wy, wz - 1);
            const a020 = blockLightSample(chunk, getter, world_ox, world_oz, wx - 1, wy + 1, wz - 1);
            const a120 = blockLightSample(chunk, getter, world_ox, world_oz, wx, wy + 1, wz - 1);
            const a220 = blockLightSample(chunk, getter, world_ox, world_oz, wx + 1, wy + 1, wz - 1);
            const v0: f32 = @floatFromInt(@as(u32, a100) + a200 + a110 + a210);
            const v1: f32 = @floatFromInt(@as(u32, a000) + a100 + a010 + a110);
            const v2: f32 = @floatFromInt(@as(u32, a010) + a110 + a020 + a120);
            const v3: f32 = @floatFromInt(@as(u32, a110) + a210 + a120 + a220);
            break :blk .{ v0 * inv4 / max_f, v1 * inv4 / max_f, v2 * inv4 / max_f, v3 * inv4 / max_f };
        },
    };

    return .{
        @max(raw[0], owner_norm),
        @max(raw[1], owner_norm),
        @max(raw[2], owner_norm),
        @max(raw[3], owner_norm),
    };
}

// ---------------------------------------------------------------------------
// Greedy meshing
// ---------------------------------------------------------------------------

/// A single face candidate in a 2D greedy-merge plane. Holds everything needed
/// to decide whether two adjacent cells may merge: block type, per-vertex AO,
/// per-vertex skylight, per-vertex block-light. Two cells merge iff every f32
/// byte in the lighting tuples is bit-identical AND the block types match.
const GreedyCell = struct {
    present: bool = false,
    block_type: BlockType = .air,
    ao: [4]f32 = .{ 0, 0, 0, 0 },
    sky: [4]f32 = .{ 0, 0, 0, 0 },
    /// Per-vertex block-light brightness 0..1. Baked from the chunk's
    /// `block_light` grid (seeded by emissive blocks, BFS-propagated through
    /// air). Omitting this from the merge key was the P0 bug: all greedy quads
    /// defaulted to block_light=0 even near glowstone.
    bl: [4]f32 = .{ 0, 0, 0, 0 },
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
/// rectangle. This rule is STRICTER than the classic "matching corners"
/// greedy rule: we only merge cells whose AO and skylight are *uniform*
/// (all four corners equal) AND whose uniform constants match the candidate
/// cell. This is the only rule that guarantees bilinear interpolation over
/// a merged w × h quad reproduces the piecewise-bilinear result of 1×1
/// quads (one quad per block face) at every interior fragment.
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
    ao_strategy: AOStrategy,
    lighting_mode: LightingMode,
) GreedyCell {
    const wx = world_ox + lx;
    const wz = world_oz + lz;
    const ao = computeFaceAOForStrategy(chunk, getter, world_ox, world_oz, wx, ly, wz, face, ao_strategy);
    const sky: [4]f32 = switch (lighting_mode) {
        .none => .{ 1.0, 1.0, 1.0, 1.0 },
        .skylight => computeFaceSkylight(chunk, getter, world_ox, world_oz, wx, ly, wz, face),
    };
    const bl: [4]f32 = switch (lighting_mode) {
        .none => .{ 0.0, 0.0, 0.0, 0.0 },
        .skylight => computeFaceBlockLight(chunk, getter, world_ox, world_oz, wx, ly, wz, face),
    };
    return .{
        .present = true,
        .block_type = block,
        .ao = ao,
        .sky = sky,
        .bl = bl,
    };
}

/// Emit a merged greedy quad covering (w × h) blocks in the face's in-plane
/// (i, j) axes, as one PackedQuad. The cell of the quad is the (ia, ja)
/// corner block, and the light values of all 4 corners are the values of
/// that cell (greedyCellEq merges only cells with the same values).
fn emitGreedyQuad(
    mesh: *Mesh,
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
    const q = packQuad(
        face,
        .{ @intCast(corner.x), @intCast(corner.y), @intCast(corner.z) },
        @intCast(w),
        @intCast(h),
        @backingInt(cell.block_type),
        cell.ao,
        cell.sky,
        cell.bl,
    );
    // The y range: a y face is one plane, the other faces span h blocks of y.
    const y_lo: f32, const y_hi: f32 = switch (face) {
        .py => .{ @floatFromInt(d + 1), @floatFromInt(d + 1) },
        .ny => .{ @floatFromInt(d), @floatFromInt(d) },
        else => .{ @floatFromInt(ja), @floatFromInt(ja + h) },
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

/// One row of a greedy slice as bits: bit j in word j / 64 (j < 256).
const Row = [4]u64;

fn rowGet(r: Row, j: usize) bool {
    return (r[j / 64] >> @intCast(j % 64)) & 1 != 0;
}

fn rowSet(r: *Row, j: usize) void {
    r[j / 64] |= @as(u64, 1) << @intCast(j % 64);
}

fn rowAndNot(a: Row, b: Row) Row {
    return .{ a[0] & ~b[0], a[1] & ~b[1], a[2] & ~b[2], a[3] & ~b[3] };
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
/// column (x, z), bit y is set when the block at (x, y, z) is not air and its
/// neighbour in the face direction is air. Inside the chunk the masks come
/// from the solid masks of the column and its neighbour column (or the column
/// shifted by one for the y faces). At the chunk edge, the neighbour is in
/// another chunk: shouldRenderFace asks the getter, for solid blocks only.
/// The result is the same as shouldRenderFace for every block, so the greedy
/// pass computes cells only where a face is visible.
const VisibleFaces = struct {
    /// [face][x][z]: 256 bits over y, bit y in word y / 64.
    masks: [6][CHUNK_W][CHUNK_W][4]u64,
    /// [face]: bit d is set when slice d has a visible face (d < 256).
    nonempty: [6][4]u64,

    const Col = [4]u64;

    fn compute(allocator: std.mem.Allocator, chunk: *const Chunk, getter: BlockGetter, world_ox: i32, world_oz: i32) !*VisibleFaces {
        comptime std.debug.assert(CHUNK_H == 256);
        const self = try allocator.create(VisibleFaces);
        var solid: [CHUNK_W][CHUNK_W]Col = undefined;
        chunk.solidColumns(&solid);

        for (0..CHUNK_W) |x| for (0..CHUNK_W) |z| {
            const s = solid[x][z];
            // +Y: neighbour above. Bit 255 has its neighbour out of the chunk.
            var up = andNot(s, shiftDown(s));
            up[3] &= ~(@as(u64, 1) << 63);
            // -Y: neighbour below. Bit 0 has its neighbour out of the chunk.
            var down = andNot(s, shiftUp(s));
            down[0] &= ~@as(u64, 1);
            self.masks[@backingInt(Face.py)][x][z] = up;
            self.masks[@backingInt(Face.ny)][x][z] = down;
            self.masks[@backingInt(Face.px)][x][z] = if (x + 1 < CHUNK_W) andNot(s, solid[x + 1][z]) else .{ 0, 0, 0, 0 };
            self.masks[@backingInt(Face.nx)][x][z] = if (x > 0) andNot(s, solid[x - 1][z]) else .{ 0, 0, 0, 0 };
            self.masks[@backingInt(Face.pz)][x][z] = if (z + 1 < CHUNK_W) andNot(s, solid[x][z + 1]) else .{ 0, 0, 0, 0 };
            self.masks[@backingInt(Face.nz)][x][z] = if (z > 0) andNot(s, solid[x][z - 1]) else .{ 0, 0, 0, 0 };

            // Faces with the neighbour out of the chunk: ask shouldRenderFace.
            const xi: i32 = @intCast(x);
            const zi: i32 = @intCast(z);
            if (s[3] >> 63 != 0 and shouldRenderFace(chunk, getter, xi, CHUNK_H - 1, zi, world_ox, world_oz, .py)) self.masks[@backingInt(Face.py)][x][z][3] |= @as(u64, 1) << 63;
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
            var any: Col = .{ 0, 0, 0, 0 };
            for (0..CHUNK_W) |x| for (0..CHUNK_W) |z| {
                const c = self.masks[f][x][z];
                switch (@as(Face, @fromBackingInt(@intCast(f)))) {
                    // y faces: slice d is layer y = d, so OR the columns.
                    .py, .ny => any = .{ any[0] | c[0], any[1] | c[1], any[2] | c[2], any[3] | c[3] },
                    // x faces: slice d is x = d. z faces: slice d is z = d.
                    .px, .nx => if (c[0] | c[1] | c[2] | c[3] != 0) rowSet(&any, x),
                    .pz, .nz => if (c[0] | c[1] | c[2] | c[3] != 0) rowSet(&any, z),
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
                var r: Row = .{ 0, 0, 0, 0 };
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
        return .{ a[0] & ~b[0], a[1] & ~b[1], a[2] & ~b[2], a[3] & ~b[3] };
    }

    /// Bit y of the result is bit y + 1 of `c` (the block above).
    fn shiftDown(c: Col) Col {
        return .{
            (c[0] >> 1) | (c[1] << 63),
            (c[1] >> 1) | (c[2] << 63),
            (c[2] >> 1) | (c[3] << 63),
            c[3] >> 1,
        };
    }

    /// Bit y of the result is bit y - 1 of `c` (the block below).
    fn shiftUp(c: Col) Col {
        return .{
            c[0] << 1,
            (c[1] << 1) | (c[0] >> 63),
            (c[2] << 1) | (c[1] >> 63),
            (c[3] << 1) | (c[2] >> 63),
        };
    }
};

/// Greedy-merged mesh generation. For each of the 6 face directions, slices
/// the chunk into planes, builds a per-cell `GreedyCell` signature grid, then
/// walks the grid growing rectangles of bit-identical (block_type, ao, sky)
/// cells. One merged quad is emitted per rectangle.
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
/// This is the only mesher. The quads go into `mesh.quads` as PackedQuad,
/// and `mesh.y_min` / `mesh.y_max` get the y range of the quads.
pub fn generateMesh(
    chunk: *const Chunk,
    mesh: *Mesh,
    world_ox: i32,
    world_oz: i32,
    getter: BlockGetter,
    ao_strategy: AOStrategy,
    lighting_mode: LightingMode,
) !void {
    mesh.clear();

    // Max plane dim = CHUNK_W × CHUNK_H (applies to all X/Z sliced faces).
    const max_i: usize = @intCast(CHUNK_W);
    const max_j: usize = @intCast(CHUNK_H);
    const slice_len: usize = max_i * max_j;

    const cells = try mesh.allocator.alloc(GreedyCell, slice_len);
    defer mesh.allocator.free(cells);

    const vis = try VisibleFaces.compute(mesh.allocator, chunk, getter, world_ox, world_oz);
    defer mesh.allocator.destroy(vis);

    // Merge size cap. The voxel demo uses painter's-algorithm sorting in
    // software (no hardware depth — see CLAUDE.md §macOS/Metal wgpu bug)
    // and the sort key is the quad centroid distance. A merged 48×48 quad
    // has its centroid far from its farthest pixel, which causes visible
    // sort inversions against overlapping smaller geometry (pit walls,
    // hover outlines, etc.). Capping the merge at `MAX_GREEDY_DIM` on each
    // axis keeps every merged quad's centroid within half that many blocks
    // of its farthest corner — close enough that painter's sort order
    // matches a mesh of 1×1 quads (one quad per block face) to within
    // 2/255 RMS per channel.
    //
    // Cap of 6 lands comfortably inside the RMS tolerance while still
    // hitting the 5–10× reduction target on flatland and capturing most
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
    // bottleneck is the merge rule, not the cap. Once hardware depth
    // testing comes back (see `sw_gpu/src/gpu.zig` macOS/Metal wgpu TODO)
    // the cap can be lifted. depth_stencil_regression.sh compares the
    // depth-off frame with the depth-on frame.
    const MAX_GREEDY_DIM: i32 = 6;

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
            var visited_rows: [CHUNK_W]Row = @splat(.{ 0, 0, 0, 0 });
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
                        ao_strategy,
                        lighting_mode,
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

                    try emitGreedyQuad(mesh, face, d, ia, ja, w, h, seed);
                }
            }
        }
    }
    std.log.info("[MESH greedy: {} quads]", .{mesh.quadCount()});
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
// the chunk origin. W and H are the quad size along the face's in-plane axes.
//   word 0: cell x (4) | cell y (8) | cell z (4) | face (3) | W-1 (4) | H-1 (8)
//   words 1-3: 12 six-bit light fields, 5 + 5 + 2 per word, in this order:
//              ao0..3, sky0..3, bl0..3
//   word 3, bits 12-19: block type. Bits 20-31: 0.
// ao = field / 42, sky = field / 60, block light = field / 60. Every value the
// mesher makes is one of these ratios, so the decode gives the same f32.

pub const PackedQuad = [4]u32;

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

/// The corner steps of face_layouts as voxel.wgsl stores them: 2 bits per
/// corner (i | j << 1), 8 bits per face, faces 0-3 in A and faces 4-5 in B.
fn cornerBits(comptime which: enum { pos, uv }) [2]u32 {
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
    q[0] = cell[0] | (cell[1] << 4) | (cell[2] << 12) | (@as(u32, @backingInt(face)) << 16) |
        ((w - 1) << 19) | ((h - 1) << 23);
    for (fields, 0..) |f, i| q[1 + i / 5] |= f << @intCast(6 * (i % 5));
    q[3] |= (block_type & 0xFF) << 12;
    return q;
}

/// The world-space centroid of a packed quad, for sortByDepth. Each value is
/// an integer or a half integer, so the result is exact.
fn quadCentroid(q: PackedQuad, world_ox: i32, world_oz: i32) [3]f32 {
    const face: u3 = @intCast((q[0] >> 16) & 0x7);
    const w: f32 = @floatFromInt(((q[0] >> 19) & 0xF) + 1);
    const h: f32 = @floatFromInt(((q[0] >> 23) & 0xFF) + 1);
    const fl = face_layouts[face];
    var c = [3]f32{
        @floatFromInt(@as(i32, @intCast(q[0] & 0xF)) + world_ox),
        @floatFromInt((q[0] >> 4) & 0xFF),
        @floatFromInt(@as(i32, @intCast((q[0] >> 12) & 0xF)) + world_oz),
    };
    if (fl.positive) c[fl.normal_axis] += 1;
    c[fl.i_axis] += w * 0.5;
    c[fl.j_axis] += h * 0.5;
    return c;
}

/// Decode corner `corner` (0..3) of a packed quad. Mirrors vs_chunk.
pub fn unpackCorner(q: PackedQuad, corner: usize, world_ox: i32, world_oz: i32) VoxelVertex {
    const cell = [3]i32{
        @intCast(q[0] & 0xF),
        @intCast((q[0] >> 4) & 0xFF),
        @intCast((q[0] >> 12) & 0xF),
    };
    const face: u3 = @intCast((q[0] >> 16) & 0x7);
    const w: f32 = @floatFromInt(((q[0] >> 19) & 0xF) + 1);
    const h: f32 = @floatFromInt(((q[0] >> 23) & 0xFF) + 1);
    const fl = face_layouts[face];
    var pos = [3]f32{
        @floatFromInt(cell[0] + world_ox),
        @floatFromInt(cell[1]),
        @floatFromInt(cell[2] + world_oz),
    };
    if (fl.positive) pos[fl.normal_axis] += 1;
    pos[fl.i_axis] += @as(f32, @floatFromInt(fl.pos[corner][0])) * w;
    pos[fl.j_axis] += @as(f32, @floatFromInt(fl.pos[corner][1])) * h;
    const field = struct {
        fn get(qq: PackedQuad, i: usize) u32 {
            return (qq[1 + i / 5] >> @intCast(6 * (i % 5))) & 0x3F;
        }
    }.get;
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
        const lz = z - self.oz;
        if (lx < 0 or lz < 0 or lx >= CHUNK_W or lz >= CHUNK_W or y < 0 or y >= CHUNK_H) return null;
        return .{ lx, y, lz };
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

fn wgslHexConst(src: []const u8, comptime name: []const u8) !u32 {
    const key = "const " ++ name ++ ": u32 = 0x";
    const start = (std.mem.indexOf(u8, src, key) orelse return error.MissingConstant) + key.len;
    var v: u32 = 0;
    for (src[start..]) |ch| {
        if (ch == '_') continue;
        const d = std.fmt.charToDigit(ch, 16) catch break;
        v = v * 16 + d;
    }
    return v;
}

test "voxel.wgsl corner constants match face_layouts" {
    const src = @embedFile("voxel.wgsl");
    const pos = comptime cornerBits(.pos);
    const uv = comptime cornerBits(.uv);
    try std.testing.expectEqual(pos[0], try wgslHexConst(src, "FACE_POS_A"));
    try std.testing.expectEqual(pos[1], try wgslHexConst(src, "FACE_POS_B"));
    try std.testing.expectEqual(uv[0], try wgslHexConst(src, "FACE_UV_A"));
    try std.testing.expectEqual(uv[1], try wgslHexConst(src, "FACE_UV_B"));
}

/// A stepped hill with an overhang and a glowstone, so every face, merged
/// quads, AO and both light channels occur.
fn testHillChunk(allocator: std.mem.Allocator) !Chunk {
    var chunk = Chunk.init(allocator);
    errdefer chunk.deinit();
    for (0..CHUNK_W) |x| for (0..CHUNK_W) |z| {
        const top: usize = 60 + (x + z) / 4;
        for (0..top) |y| try chunk.setBlock(@intCast(x), @intCast(y), @intCast(z), if (y + 1 == top) .grass else .stone);
    };
    for (4..9) |x| for (4..9) |z| try chunk.setBlock(@intCast(x), 75, @intCast(z), .stone);
    try chunk.setBlock(6, 70, 6, .glowstone);
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
        var y_min: f32 = CHUNK_H;
        var y_max: f32 = 0;
        for (mesh.quads.items) |q| {
            const lx: i32 = @intCast(q[0] & 0xF);
            const ly: i32 = @intCast((q[0] >> 4) & 0xFF);
            const lz: i32 = @intCast((q[0] >> 12) & 0xF);
            const face: Face = @fromBackingInt(@as(u3, @intCast((q[0] >> 16) & 0x7)));
            const block = chunk.getBlock(lx, ly, lz);
            try std.testing.expect(block != .air);
            try std.testing.expect(shouldRenderFace(&chunk, tg.getter(), lx, ly, lz, ox, oz, face));
            const want = computeGreedyCell(&chunk, tg.getter(), ox, oz, lx, ly, lz, face, block, ao, .skylight);
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
            // The centroid is the mean of the 4 corners.
            var mean = [3]f32{ 0, 0, 0 };
            for (0..4) |c| {
                const p = unpackCorner(q, c, ox, oz).pos;
                for (0..3) |a| mean[a] += p[a];
            }
            for (0..3) |a| mean[a] /= 4.0;
            try std.testing.expectEqual(mean, quadCentroid(q, ox, oz));
        }
        try std.testing.expectEqual(y_min, mesh.y_min);
        try std.testing.expectEqual(y_max, mesh.y_max);
    }
}

test "sortByDepth writes every quad once, back to front" {
    const allocator = std.testing.allocator;
    var chunk = try testHillChunk(allocator);
    defer chunk.deinit();
    const tg = TestGetter{ .chunk = &chunk, .ox = 0, .oz = 0 };
    var mesh = Mesh.init(allocator);
    defer mesh.deinit();
    try generateMesh(&chunk, &mesh, 0, 0, tg.getter(), .moore, .skylight);
    const cam = [3]f32{ 8, 90, -20 };
    const fwd = [3]f32{ 0, -0.6, 0.8 };
    // The second sort uses the insertion sort on the first order.
    for (0..2) |_| {
        try mesh.sortByDepth(cam, fwd, 0, 0);
        const n = mesh.quadCount();
        var prev: f32 = std.math.inf(f32);
        for (mesh.sorted_quads[0..n]) |q| {
            const c = quadCentroid(q, 0, 0);
            const d = (c[0] - cam[0]) * fwd[0] + (c[1] - cam[1]) * fwd[1] + (c[2] - cam[2]) * fwd[2];
            try std.testing.expect(d <= prev);
            prev = d;
        }
        const a = try allocator.dupe(PackedQuad, mesh.quads.items);
        defer allocator.free(a);
        const b = try allocator.dupe(PackedQuad, mesh.sorted_quads[0..n]);
        defer allocator.free(b);
        const lt = struct {
            fn lt(_: void, x: PackedQuad, y: PackedQuad) bool {
                for (x, y) |u, v| if (u != v) return u < v;
                return false;
            }
        }.lt;
        std.mem.sort(PackedQuad, a, {}, lt);
        std.mem.sort(PackedQuad, b, {}, lt);
        try std.testing.expectEqualSlices(PackedQuad, a, b);
    }
}
