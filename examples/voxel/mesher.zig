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

/// How the mesher emits faces for a chunk.
///
///   .naive  — one quad per visible block face. Preserves the per-block
///             invariant used by `updateForBlockChange` (the `quad_block`
///             parallel array assumes exactly one block owns each quad).
///   .greedy — coplanar same-material + same-lighting faces are merged into
///             larger rectangles. Reduces vertex count by 5–10× on
///             flatland/hilly terrain. Greedy quads span multiple blocks, so
///             the `updateForBlockChange` incremental path is NOT used in
///             greedy mode; block add/remove flags `mesh_dirty = true` and
///             the affected chunk is re-meshed in full next tick. See
///             `examples/voxel/docs/memory.md` §5 for rationale + measured
///             reductions.
pub const MeshingMode = enum { naive, greedy };

const DEBUG = false; // Enable for mesh generation debug logging

/// Vertex format matching voxel.wgsl
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

pub const Mesh = struct {
    allocator: std.mem.Allocator,
    vertices: std.ArrayList(VoxelVertex),
    indices: std.ArrayList(u32),
    /// Parallel to quads: quad_block[i] = packed block idx owning quad i.
    /// Used for O(1) incremental mesh updates — find affected quads by block.
    quad_block: std.ArrayList(u32),
    /// Parallel to quads: highlight intensity 0–255. Freshly rebuilt quads start at 255
    /// and decay each tick. Used by GPU debug mode to tint recently-changed faces.
    quad_highlight: std.ArrayList(u8),
    /// Persistent scratch buffers for sortByDepth — reallocated only when quad count grows.
    sort_scratch: []SortEntry = &.{},
    sort_indices: []u32 = &.{},
    /// True once sort_scratch holds a valid sorted order from the previous frame.
    /// False after mesh rebuild — triggers full pdqsort to establish initial order.
    sort_valid: bool = false,

    pub fn init(allocator: std.mem.Allocator) Mesh {
        return .{
            .allocator = allocator,
            .vertices = .{},
            .indices = .{},
            .quad_block = .{},
            .quad_highlight = .{},
        };
    }

    pub fn deinit(self: *Mesh) void {
        self.vertices.deinit(self.allocator);
        self.indices.deinit(self.allocator);
        self.quad_block.deinit(self.allocator);
        self.quad_highlight.deinit(self.allocator);
        if (self.sort_scratch.len > 0) self.allocator.free(self.sort_scratch);
        if (self.sort_indices.len > 0) self.allocator.free(self.sort_indices);
    }

    pub fn clear(self: *Mesh) void {
        self.vertices.clearRetainingCapacity();
        self.indices.clearRetainingCapacity();
        self.quad_block.clearRetainingCapacity();
        self.quad_highlight.clearRetainingCapacity();
        self.sort_valid = false; // mesh rebuilt — scratch order is stale
    }

    /// Release ALL host-side mesh allocations back to the allocator. Unlike
    /// `clear` (which only zeroes lengths and keeps capacity for reuse), this
    /// drops capacity to 0 — used by the per-frame mesh-eviction pass when a
    /// chunk wanders outside the render distance and we want the host RAM
    /// back, not just the GPU buffer back.
    ///
    /// The Mesh struct itself stays valid: `init`-equivalent state is restored
    /// on every list, so a subsequent `generateMesh` against this Mesh works
    /// fine and just re-grows the storage as it appends.
    pub fn freeHostBuffers(self: *Mesh) void {
        self.vertices.shrinkAndFree(self.allocator, 0);
        self.indices.shrinkAndFree(self.allocator, 0);
        self.quad_block.shrinkAndFree(self.allocator, 0);
        self.quad_highlight.shrinkAndFree(self.allocator, 0);
        if (self.sort_scratch.len > 0) {
            self.allocator.free(self.sort_scratch);
            self.sort_scratch = &.{};
        }
        if (self.sort_indices.len > 0) {
            self.allocator.free(self.sort_indices);
            self.sort_indices = &.{};
        }
        self.sort_valid = false;
    }

    /// Sort faces by depth (painter's algorithm) for correct rendering without
    /// hardware depth testing. Reuses pre-allocated scratch buffers each frame.
    pub fn sortByDepth(self: *Mesh, camera_pos: [3]f32) !void {
        if (self.indices.items.len == 0) return;

        const quad_count = self.indices.items.len / 6;
        if (quad_count == 0) return;

        // Grow scratch buffers only when needed (never shrink)
        if (quad_count > self.sort_scratch.len) {
            if (self.sort_scratch.len > 0) self.allocator.free(self.sort_scratch);
            if (self.sort_indices.len > 0) self.allocator.free(self.sort_indices);
            self.sort_scratch = try self.allocator.alloc(SortEntry, quad_count);
            self.sort_indices = try self.allocator.alloc(u32, quad_count * 6);
            self.sort_valid = false; // fresh allocation — scratch must be repopulated
        }

        const scratch = self.sort_scratch[0..quad_count];

        if (self.sort_valid) {
            // Scratch holds the sorted order from last frame — just update distances in place.
            // The .idx fields still point to the correct quads; only distances changed.
            for (scratch) |*entry| {
                const base_idx = entry.idx * 6;
                const idx0 = self.indices.items[base_idx];
                const idx1 = self.indices.items[base_idx + 1];
                const idx2 = self.indices.items[base_idx + 2];
                const idx3 = self.indices.items[base_idx + 3];

                const v0 = self.vertices.items[idx0].pos;
                const v1 = self.vertices.items[idx1].pos;
                const v2 = self.vertices.items[idx2].pos;
                const v3 = self.vertices.items[idx3].pos;

                const dx = (v0[0] + v1[0] + v2[0] + v3[0]) / 4.0 - camera_pos[0];
                const dy = (v0[1] + v1[1] + v2[1] + v3[1]) / 4.0 - camera_pos[1];
                const dz = (v0[2] + v1[2] + v2[2] + v3[2]) / 4.0 - camera_pos[2];
                entry.dist = dx * dx + dy * dy + dz * dz;
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
            // First frame after mesh rebuild — populate scratch from scratch and use pdqsort.
            for (0..quad_count) |i| {
                const base_idx = i * 6;
                const idx0 = self.indices.items[base_idx];
                const idx1 = self.indices.items[base_idx + 1];
                const idx2 = self.indices.items[base_idx + 2];
                const idx3 = self.indices.items[base_idx + 3];

                const v0 = self.vertices.items[idx0].pos;
                const v1 = self.vertices.items[idx1].pos;
                const v2 = self.vertices.items[idx2].pos;
                const v3 = self.vertices.items[idx3].pos;

                const dx = (v0[0] + v1[0] + v2[0] + v3[0]) / 4.0 - camera_pos[0];
                const dy = (v0[1] + v1[1] + v2[1] + v3[1]) / 4.0 - camera_pos[1];
                const dz = (v0[2] + v1[2] + v2[2] + v3[2]) / 4.0 - camera_pos[2];
                scratch[i] = .{ .idx = i, .dist = dx * dx + dy * dy + dz * dz };
            }

            std.mem.sort(SortEntry, scratch, {}, struct {
                fn lessThan(_: void, a: SortEntry, b: SortEntry) bool {
                    return a.dist > b.dist;
                }
            }.lessThan);

            self.sort_valid = true;
        }

        // Write sorted indices into sort_indices (the GPU upload source).
        // Never modify self.indices — it stays as the canonical unsorted buffer so
        // scratch[i].idx remains a stable quad identifier across frames.
        const out = self.sort_indices[0 .. quad_count * 6];
        for (scratch, 0..) |qd, i| {
            const src_base = qd.idx * 6;
            const dst_base = i * 6;
            @memcpy(out[dst_base .. dst_base + 6], self.indices.items[src_base .. src_base + 6]);
        }
    }

    /// Swap-remove quad at index qi. Moves the last quad into slot qi.
    /// Updates vertices, indices (base address rewrite), and quad_block.
    /// Caller must set sort_valid = false afterwards.
    fn swapRemoveQuad(self: *Mesh, qi: usize) void {
        const quad_count = self.indices.items.len / 6;
        const last = quad_count - 1;

        if (qi != last) {
            // Copy last quad's 4 vertices into slot qi
            const src_v = last * 4;
            const dst_v = qi * 4;
            @memcpy(self.vertices.items[dst_v .. dst_v + 4], self.vertices.items[src_v .. src_v + 4]);

            // Rewrite the 6 index values so the moved quad references its new vertex slot
            const base: u32 = @intCast(dst_v);
            self.indices.items[qi * 6 + 0] = base;
            self.indices.items[qi * 6 + 1] = base + 1;
            self.indices.items[qi * 6 + 2] = base + 2;
            self.indices.items[qi * 6 + 3] = base;
            self.indices.items[qi * 6 + 4] = base + 2;
            self.indices.items[qi * 6 + 5] = base + 3;

            // Update quad_block + quad_highlight for the moved quad
            self.quad_block.items[qi] = self.quad_block.items[last];
            self.quad_highlight.items[qi] = self.quad_highlight.items[last];
        }

        // Shrink all four arrays (no allocation, just adjust len)
        self.vertices.items.len = last * 4;
        self.indices.items.len = last * 6;
        self.quad_block.items.len = last;
        self.quad_highlight.items.len = last;
    }

    /// Incremental mesh update for a single block change at (bx, by, bz).
    /// Only re-meshes the changed block and its ≤6 in-bounds neighbors — O(1)
    /// instead of the O(chunk_volume) full rebuild.
    /// Maintains sort_scratch so the next sortByDepth uses cheap insertion sort
    /// instead of a full pdqsort.
    /// Call this AFTER the chunk data has been modified.
    pub fn updateForBlockChange(
        self: *Mesh,
        chunk: *const Chunk,
        bx: i32,
        by: i32,
        bz: i32,
        camera_pos: [3]f32,
        world_ox: i32,
        world_oz: i32,
        getter: BlockGetter,
        ao_strategy: AOStrategy,
        lighting_mode: LightingMode,
    ) !void {
        const offsets = [7][3]i32{
            .{ 0, 0, 0 },
            .{ 1, 0, 0 },
            .{ -1, 0, 0 },
            .{ 0, 1, 0 },
            .{ 0, -1, 0 },
            .{ 0, 0, 1 },
            .{ 0, 0, -1 },
        };

        // Build the set of affected block indices (in-bounds only)
        var affected: [7]u32 = undefined;
        var n_affected: usize = 0;
        for (offsets) |off| {
            const ax = bx + off[0];
            const ay = by + off[1];
            const az = bz + off[2];
            if (ax >= 0 and ax < CHUNK_W and ay >= 0 and ay < CHUNK_H and az >= 0 and az < CHUNK_W) {
                affected[n_affected] = packBlockIdx(ax, ay, az);
                n_affected += 1;
            }
        }

        // Collect quad indices belonging to affected blocks (linear scan, n≈920 quads)
        var to_remove: [7 * 6]usize = undefined;
        var remove_count: usize = 0;
        for (self.quad_block.items, 0..) |blk, qi| {
            for (affected[0..n_affected]) |ab| {
                if (blk == ab) {
                    to_remove[remove_count] = qi;
                    remove_count += 1;
                    break;
                }
            }
        }

        const quad_count_before = self.indices.items.len / 6;

        // Remove in descending order so earlier indices stay valid through each swap-remove
        std.mem.sort(usize, to_remove[0..remove_count], {}, struct {
            fn desc(_: void, a: usize, b: usize) bool {
                return a > b;
            }
        }.desc);
        for (to_remove[0..remove_count]) |qi| {
            self.swapRemoveQuad(qi);
        }

        const quad_count_after_removes = self.indices.items.len / 6;
        // = quad_count_before - remove_count

        // Maintain sort_scratch so the next frame uses insertion sort (O(n)) instead
        // of pdqsort (O(n log n)).
        //
        // After swap-removes in descending order, all quad positions
        // >= quad_count_after_removes no longer exist. The scratch entries with
        // .idx >= quad_count_after_removes are stale and must be removed.
        // Entries with .idx < quad_count_after_removes remain valid (they reference
        // existing positions — possibly holding different quads due to swaps, but
        // sortByDepth recomputes distances anyway before sorting).
        //
        // Maintaining scratch requires the allocation to be large enough to hold the
        // final quad count. If it's not, fall back to full pdqsort.
        const can_maintain = self.sort_valid and
            self.sort_scratch.len >= quad_count_before;

        var scratch_count: usize = 0;
        if (can_maintain) {
            // One O(n) pass: compact scratch, keeping only valid entries
            for (self.sort_scratch[0..quad_count_before]) |entry| {
                if (entry.idx < quad_count_after_removes) {
                    self.sort_scratch[scratch_count] = entry;
                    scratch_count += 1;
                }
            }
            // scratch_count == quad_count_after_removes at this point
        }

        // Re-mesh each affected block from the current chunk state
        for (affected[0..n_affected]) |ab| {
            const pos = unpackBlockIdx(ab);
            const block = chunk.getBlock(pos.x, pos.y, pos.z);
            if (block == .air) continue;
            const wpx = world_ox + pos.x;
            const wpz = world_oz + pos.z;
            for ([_]Face{ .px, .nx, .py, .ny, .pz, .nz }) |face| {
                if (shouldRenderFace(chunk, getter, pos.x, pos.y, pos.z, world_ox, world_oz, face)) {
                    try addQuad(
                        self,
                        @floatFromInt(wpx),
                        @floatFromInt(pos.y),
                        @floatFromInt(wpz),
                        face,
                        block,
                        ab,
                        255, // freshly rebuilt — max highlight
                        chunk,
                        getter,
                        world_ox,
                        world_oz,
                        ao_strategy,
                        lighting_mode,
                    );
                }
            }
        }

        const quad_count_final = self.indices.items.len / 6;

        if (can_maintain) {
            // Grow scratch if new quads push us past current capacity.
            // Allocate with headroom (+64) to absorb future incremental adds without realloc.
            if (quad_count_final > self.sort_scratch.len) {
                const new_cap = quad_count_final + 64;
                const new_scratch = try self.allocator.alloc(SortEntry, new_cap);
                @memcpy(new_scratch[0..scratch_count], self.sort_scratch[0..scratch_count]);
                if (self.sort_scratch.len > 0) self.allocator.free(self.sort_scratch);
                self.sort_scratch = new_scratch;
                const new_indices = try self.allocator.alloc(u32, new_cap * 6);
                if (self.sort_indices.len > 0) self.allocator.free(self.sort_indices);
                self.sort_indices = new_indices;
            }

            // Append scratch entries for newly-added quads with fresh distances
            for (quad_count_after_removes..quad_count_final) |qi| {
                const base_v = qi * 4;
                const v0 = self.vertices.items[base_v].pos;
                const v1 = self.vertices.items[base_v + 1].pos;
                const v2 = self.vertices.items[base_v + 2].pos;
                const v3 = self.vertices.items[base_v + 3].pos;
                const dx = (v0[0] + v1[0] + v2[0] + v3[0]) / 4.0 - camera_pos[0];
                const dy = (v0[1] + v1[1] + v2[1] + v3[1]) / 4.0 - camera_pos[1];
                const dz = (v0[2] + v1[2] + v2[2] + v3[2]) / 4.0 - camera_pos[2];
                self.sort_scratch[scratch_count] = .{ .idx = qi, .dist = dx * dx + dy * dy + dz * dz };
                scratch_count += 1;
            }
            // sort_valid stays true — next sortByDepth uses cheap insertion sort
        } else {
            self.sort_valid = false;
        }
    }

    /// Reduce all quad highlight intensities by `amount` (saturating at 0).
    /// Call once per tick when gpu_debug is active.
    pub fn decayHighlights(self: *Mesh, amount: u8) void {
        for (self.quad_highlight.items) |*hl| {
            hl.* = hl.* -| amount; // saturating subtract
        }
    }
};

// ---------------------------------------------------------------------------
// Block index packing helpers
// ---------------------------------------------------------------------------

fn packBlockIdx(x: i32, y: i32, z: i32) u32 {
    return @as(u32, @intCast(x)) * (CHUNK_H * CHUNK_W) +
        @as(u32, @intCast(y)) * CHUNK_W +
        @as(u32, @intCast(z));
}

const BlockPos = struct { x: i32, y: i32, z: i32 };

fn unpackBlockIdx(idx: u32) BlockPos {
    return .{
        .z = @intCast(idx % CHUNK_W),
        .y = @intCast((idx / CHUNK_W) % CHUNK_H),
        .x = @intCast(idx / (CHUNK_H * CHUNK_W)),
    };
}

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
    const offset = face_offsets[@intFromEnum(face)];
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
/// Returns [4]f32 — one brightness per vertex in the same order addQuad emits them.
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
        .propagated, .ssao => blk: {
            // Lazily warn once per process about unimplemented strategies.
            unimplemented_warned.warn(strategy);
            break :blk computeFaceAOClassic(chunk, getter, world_ox, world_oz, wx, wy, wz, face);
        },
    };
}

/// One-shot warning state for strategies that fall back to classic.
const UnimplementedWarn = struct {
    propagated: bool = false,
    ssao: bool = false,

    fn warn(self: *UnimplementedWarn, strat: AOStrategy) void {
        switch (strat) {
            .propagated => if (!self.propagated) {
                self.propagated = true;
                std.log.warn("AO strategy '.propagated' not yet implemented — falling back to .classic", .{});
            },
            .ssao => if (!self.ssao) {
                self.ssao = true;
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
        return chunk.skylight[@intCast(lx)][@intCast(wy)][@intCast(lz)];
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
            // Vertex order matches addQuad's .px branch: (y, z) → (0,0)(1,0)(1,1)(0,1).
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
            // Vertex order matches addQuad's .nx branch: (y, z) → (0,1)(1,1)(1,0)(0,0).
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
            // Vertex order matches addQuad's .py branch: (x, z) → (0,0)(0,1)(1,1)(1,0).
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
            // Vertex order matches addQuad's .ny branch: (x, z) → (0,1)(0,0)(1,0)(1,1).
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
            // Vertex order matches addQuad's .pz branch: (x, y) → (0,0)(1,0)(1,1)(0,1).
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
            // Vertex order matches addQuad's .nz branch: (x, y) → (1,0)(0,0)(0,1)(1,1).
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
        return chunk.block_light[@intCast(lx)][@intCast(wy)][@intCast(lz)];
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

/// Add a quad face to the mesh, recording its owning block via block_idx.
/// highlight: initial highlight intensity (255 = freshly rebuilt, 0 = normal).
fn addQuad(
    mesh: *Mesh,
    x: f32,
    y: f32,
    z: f32,
    face: Face,
    block_type: BlockType,
    block_idx: u32,
    highlight: u8,
    chunk: *const Chunk,
    getter: BlockGetter,
    world_ox: i32,
    world_oz: i32,
    ao_strategy: AOStrategy,
    lighting_mode: LightingMode,
) !void {
    const base_idx: u32 = @intCast(mesh.vertices.items.len);
    const normal = face_normals[@intFromEnum(face)];
    const block_u32: u32 = @intFromEnum(block_type);

    // Compute per-vertex ambient occlusion for this face according to the
    // selected strategy. The dispatch is centralized in computeFaceAOForStrategy
    // so future strategies (propagated, ssao) plug in there without touching
    // every quad-emit site.
    const wx: i32 = @intFromFloat(x);
    const wy: i32 = @intFromFloat(y);
    const wz: i32 = @intFromFloat(z);
    const ao = computeFaceAOForStrategy(chunk, getter, world_ox, world_oz, wx, wy, wz, face, ao_strategy);

    // Per-vertex skylight 0..1. When lighting_mode == .none we hand every
    // vertex 1.0 so the shader's sky channel collapses to a no-op multiply.
    const sky: [4]f32 = switch (lighting_mode) {
        .none => .{ 1.0, 1.0, 1.0, 1.0 },
        .skylight => computeFaceSkylight(chunk, getter, world_ox, world_oz, wx, wy, wz, face),
    };

    // Per-vertex block-light 0..1. Baked from the chunk's `block_light` grid
    // (seeded by emissive blocks, BFS-propagated through air). Always
    // computed — block light is a separate channel that is combined with
    // sky in the shader via `max`, so `.none` lighting-mode baselines still
    // work because sky = 1.0 saturates the max against whatever block
    // contributes. When lighting_mode == .none we short-circuit to zero so
    // we don't pay the sample cost for values that will never be read.
    const bl: [4]f32 = switch (lighting_mode) {
        .none => .{ 0.0, 0.0, 0.0, 0.0 },
        .skylight => computeFaceBlockLight(chunk, getter, world_ox, world_oz, wx, wy, wz, face),
    };

    // Define quad vertices based on face direction
    const verts = switch (face) {
        .px => [_]VoxelVertex{ // +X face
            .{ .pos = .{ x + 1, y, z }, .normal = normal, .block_type = block_u32, .uv = .{ 0, 0 }, .ao = ao[0], .skylight = sky[0], .block_light = bl[0] },
            .{ .pos = .{ x + 1, y + 1, z }, .normal = normal, .block_type = block_u32, .uv = .{ 0, 1 }, .ao = ao[1], .skylight = sky[1], .block_light = bl[1] },
            .{ .pos = .{ x + 1, y + 1, z + 1 }, .normal = normal, .block_type = block_u32, .uv = .{ 1, 1 }, .ao = ao[2], .skylight = sky[2], .block_light = bl[2] },
            .{ .pos = .{ x + 1, y, z + 1 }, .normal = normal, .block_type = block_u32, .uv = .{ 1, 0 }, .ao = ao[3], .skylight = sky[3], .block_light = bl[3] },
        },
        .nx => [_]VoxelVertex{ // -X face
            .{ .pos = .{ x, y, z + 1 }, .normal = normal, .block_type = block_u32, .uv = .{ 0, 0 }, .ao = ao[0], .skylight = sky[0], .block_light = bl[0] },
            .{ .pos = .{ x, y + 1, z + 1 }, .normal = normal, .block_type = block_u32, .uv = .{ 0, 1 }, .ao = ao[1], .skylight = sky[1], .block_light = bl[1] },
            .{ .pos = .{ x, y + 1, z }, .normal = normal, .block_type = block_u32, .uv = .{ 1, 1 }, .ao = ao[2], .skylight = sky[2], .block_light = bl[2] },
            .{ .pos = .{ x, y, z }, .normal = normal, .block_type = block_u32, .uv = .{ 1, 0 }, .ao = ao[3], .skylight = sky[3], .block_light = bl[3] },
        },
        .py => [_]VoxelVertex{ // +Y face (CCW from above: +Y normal)
            .{ .pos = .{ x, y + 1, z }, .normal = normal, .block_type = block_u32, .uv = .{ 0, 0 }, .ao = ao[0], .skylight = sky[0], .block_light = bl[0] },
            .{ .pos = .{ x, y + 1, z + 1 }, .normal = normal, .block_type = block_u32, .uv = .{ 0, 1 }, .ao = ao[1], .skylight = sky[1], .block_light = bl[1] },
            .{ .pos = .{ x + 1, y + 1, z + 1 }, .normal = normal, .block_type = block_u32, .uv = .{ 1, 1 }, .ao = ao[2], .skylight = sky[2], .block_light = bl[2] },
            .{ .pos = .{ x + 1, y + 1, z }, .normal = normal, .block_type = block_u32, .uv = .{ 1, 0 }, .ao = ao[3], .skylight = sky[3], .block_light = bl[3] },
        },
        .ny => [_]VoxelVertex{ // -Y face (CCW from below: -Y normal)
            .{ .pos = .{ x, y, z + 1 }, .normal = normal, .block_type = block_u32, .uv = .{ 0, 0 }, .ao = ao[0], .skylight = sky[0], .block_light = bl[0] },
            .{ .pos = .{ x, y, z }, .normal = normal, .block_type = block_u32, .uv = .{ 0, 1 }, .ao = ao[1], .skylight = sky[1], .block_light = bl[1] },
            .{ .pos = .{ x + 1, y, z }, .normal = normal, .block_type = block_u32, .uv = .{ 1, 1 }, .ao = ao[2], .skylight = sky[2], .block_light = bl[2] },
            .{ .pos = .{ x + 1, y, z + 1 }, .normal = normal, .block_type = block_u32, .uv = .{ 1, 0 }, .ao = ao[3], .skylight = sky[3], .block_light = bl[3] },
        },
        .pz => [_]VoxelVertex{ // +Z face (CCW from front: +Z normal)
            .{ .pos = .{ x, y, z + 1 }, .normal = normal, .block_type = block_u32, .uv = .{ 0, 0 }, .ao = ao[0], .skylight = sky[0], .block_light = bl[0] },
            .{ .pos = .{ x + 1, y, z + 1 }, .normal = normal, .block_type = block_u32, .uv = .{ 1, 0 }, .ao = ao[1], .skylight = sky[1], .block_light = bl[1] },
            .{ .pos = .{ x + 1, y + 1, z + 1 }, .normal = normal, .block_type = block_u32, .uv = .{ 1, 1 }, .ao = ao[2], .skylight = sky[2], .block_light = bl[2] },
            .{ .pos = .{ x, y + 1, z + 1 }, .normal = normal, .block_type = block_u32, .uv = .{ 0, 1 }, .ao = ao[3], .skylight = sky[3], .block_light = bl[3] },
        },
        .nz => [_]VoxelVertex{ // -Z face (CCW from back: -Z normal)
            .{ .pos = .{ x + 1, y, z }, .normal = normal, .block_type = block_u32, .uv = .{ 0, 0 }, .ao = ao[0], .skylight = sky[0], .block_light = bl[0] },
            .{ .pos = .{ x, y, z }, .normal = normal, .block_type = block_u32, .uv = .{ 1, 0 }, .ao = ao[1], .skylight = sky[1], .block_light = bl[1] },
            .{ .pos = .{ x, y + 1, z }, .normal = normal, .block_type = block_u32, .uv = .{ 1, 1 }, .ao = ao[2], .skylight = sky[2], .block_light = bl[2] },
            .{ .pos = .{ x + 1, y + 1, z }, .normal = normal, .block_type = block_u32, .uv = .{ 0, 1 }, .ao = ao[3], .skylight = sky[3], .block_light = bl[3] },
        },
    };

    try mesh.vertices.appendSlice(mesh.allocator, &verts);

    // Two triangles per quad (CCW winding)
    const inds = [_]u32{
        base_idx, base_idx + 1, base_idx + 2,
        base_idx, base_idx + 2, base_idx + 3,
    };
    try mesh.indices.appendSlice(mesh.allocator, &inds);

    // Track which block owns this quad + its highlight intensity
    try mesh.quad_block.append(mesh.allocator, block_idx);
    try mesh.quad_highlight.append(mesh.allocator, highlight);

    // Debug logging (gated by DEBUG constant)
    if (DEBUG and x == 8.0 and y == 8.0 and z == 10.0) {
        std.log.info("Block ({d:.0},{d:.0},{d:.0}) face={s} base_idx={}:", .{ x, y, z, @tagName(face), base_idx });
        for (verts, 0..) |v, i| {
            std.log.info("  v{}: pos=({d:.3},{d:.3},{d:.3}) normal=({d:.1},{d:.1},{d:.1})", .{
                i, v.pos[0], v.pos[1], v.pos[2], v.normal[0], v.normal[1], v.normal[2],
            });
        }
        std.log.info("  indices: [{}, {}, {}] [{}, {}, {}]", .{
            inds[0], inds[1], inds[2], inds[3], inds[4], inds[5],
        });
    }
}

/// Full mesh generation from scratch. Use updateForBlockChange for incremental updates.
/// world_ox/world_oz are the world-space block origin of this chunk.
/// getter is used for cross-chunk face culling at chunk boundaries.
/// ao_strategy selects which ambient-occlusion sampler each emitted face uses.
///
/// TODO (in-game settings menu): if ao_strategy changes at runtime, every loaded
/// chunk needs to re-run generateMesh — the AO is baked into the vertex stream
/// and no shader switch will recover it. The render loop already remeshes on
/// `mesh_dirty`; setting that flag on every chunk after a strategy change is
/// the entry point.
pub fn generateMesh(chunk: *const Chunk, mesh: *Mesh, world_ox: i32, world_oz: i32, getter: BlockGetter, ao_strategy: AOStrategy, lighting_mode: LightingMode) !void {
    mesh.clear();

    var x: i32 = 0;
    while (x < CHUNK_W) : (x += 1) {
        var y: i32 = 0;
        while (y < CHUNK_H) : (y += 1) {
            var z: i32 = 0;
            while (z < CHUNK_W) : (z += 1) {
                const block = chunk.getBlock(x, y, z);
                if (block == .air) continue;

                const block_wx = world_ox + x;
                const block_wz = world_oz + z;
                const block_idx = packBlockIdx(x, y, z);
                for ([_]Face{ .px, .nx, .py, .ny, .pz, .nz }) |face| {
                    if (shouldRenderFace(chunk, getter, x, y, z, world_ox, world_oz, face)) {
                        try addQuad(
                            mesh,
                            @floatFromInt(block_wx),
                            @floatFromInt(y),
                            @floatFromInt(block_wz),
                            face,
                            block,
                            block_idx,
                            255, // full rebuild — all quads highlighted
                            chunk,
                            getter,
                            world_ox,
                            world_oz,
                            ao_strategy,
                            lighting_mode,
                        );
                    }
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Greedy meshing
// ---------------------------------------------------------------------------

/// A single face candidate in a 2D greedy-merge plane. Holds everything needed
/// to decide whether two adjacent cells may merge: block type, per-vertex AO,
/// per-vertex skylight. Two cells merge iff every f32 byte in the lighting
/// tuples is bit-identical AND the block types match.
const GreedyCell = struct {
    present: bool = false,
    block_type: BlockType = .air,
    ao: [4]f32 = .{ 0, 0, 0, 0 },
    sky: [4]f32 = .{ 0, 0, 0, 0 },
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
/// a merged w × h quad reproduces the piecewise-bilinear naive result at
/// every interior fragment.
///
/// Why the weaker rule fails: consider two adjacent cells that each have AO
/// quadruple [a, a, b, b] at corners (0,0)(0,1)(1,1)(1,0). Naive emits two
/// separate quads, each with its own (a,a,b,b) gradient from a to b across
/// the cell. Merging them into a 2×1 rect with corners (a, a, b, b) means
/// the gradient now stretches over 2 units — the value at the center of
/// the left cell becomes a 75/25 mix of (a, b) instead of 50/50. RMS drift
/// is large enough to be visible. Requiring uniform-corner cells ducks this
/// entirely: a constant AO gives bilinear-interp == constant, same as naive.
fn greedyCellEq(a: GreedyCell, b: GreedyCell) bool {
    if (!a.present or !b.present) return false;
    if (a.block_type != b.block_type) return false;
    if (!greedyUniform4(a.ao) or !greedyUniform4(b.ao)) return false;
    if (!greedyUniform4(a.sky) or !greedyUniform4(b.sky)) return false;
    if (a.ao[0] != b.ao[0]) return false;
    if (a.sky[0] != b.sky[0]) return false;
    return true;
}

/// Compute the face cell signature for a block face at local (lx, ly, lz).
/// Mirrors the addQuad head — same AO/sky calls — so a greedy merged quad
/// reproduces the lighting a naive quad would have had, exactly.
fn computeGreedyCell(
    chunk: *const Chunk,
    getter: BlockGetter,
    world_ox: i32,
    world_oz: i32,
    lx: i32,
    ly: i32,
    lz: i32,
    face: Face,
    ao_strategy: AOStrategy,
    lighting_mode: LightingMode,
) GreedyCell {
    const block = chunk.getBlock(lx, ly, lz);
    if (block == .air) return .{};
    if (!shouldRenderFace(chunk, getter, lx, ly, lz, world_ox, world_oz, face)) return .{};
    const wx = world_ox + lx;
    const wz = world_oz + lz;
    const ao = computeFaceAOForStrategy(chunk, getter, world_ox, world_oz, wx, ly, wz, face, ao_strategy);
    const sky: [4]f32 = switch (lighting_mode) {
        .none => .{ 1.0, 1.0, 1.0, 1.0 },
        .skylight => computeFaceSkylight(chunk, getter, world_ox, world_oz, wx, ly, wz, face),
    };
    return .{
        .present = true,
        .block_type = block,
        .ao = ao,
        .sky = sky,
    };
}

/// Emit a merged greedy quad covering (w × h) blocks in the face's in-plane
/// (i, j) axes. The vertex layout mirrors the naive `addQuad` for each face
/// with `+1` substituted by `+w` or `+h` on the in-plane axes, so the shader
/// winding/normal path is identical — only the UV range grows.
///
/// `block_idx` is the packed index of the first (ia, ja) block in the rect
/// (`ia`/`ja` are the in-plane axes of the face; `ia`/`ja` can't be used as
/// names here because `ia` is a Zig primitive integer type).
/// In greedy mode the `quad_block` parallel array loses its one-quad-per-block
/// meaning, but we still populate it (any block in the merged rect would do)
/// so the array stays the same length as `indices/6` and `swapRemoveQuad`
/// continues to work when `decayHighlights` etc. run.
fn emitGreedyQuad(
    mesh: *Mesh,
    face: Face,
    d: i32,
    ia: i32,
    ja: i32,
    w: i32,
    h: i32,
    cell: GreedyCell,
    block_idx: u32,
    world_ox: i32,
    world_oz: i32,
) !void {
    std.debug.assert(cell.present);
    std.debug.assert(cell.block_type != .air);
    std.debug.assert(w > 0 and h > 0);

    const base_idx: u32 = @intCast(mesh.vertices.items.len);
    const normal = face_normals[@intFromEnum(face)];
    const block_u32: u32 = @intFromEnum(cell.block_type);

    const wf: f32 = @floatFromInt(w);
    const hf: f32 = @floatFromInt(h);

    // World-space coordinates of the (ia, ja) corner + constants per face.
    // `d` is the in-plane slice index along the face normal.
    const verts = switch (face) {
        .px => blk: {
            // +X face: d = local block x, plane at world x = world_ox + d + 1.
            // In-plane axes: i = local Z, j = local Y. Merge grows w along Z, h along Y.
            const x_f: f32 = @floatFromInt(world_ox + d + 1);
            const y_f: f32 = @floatFromInt(ja);
            const z_f: f32 = @floatFromInt(world_oz + ia);
            break :blk [_]VoxelVertex{
                .{ .pos = .{ x_f, y_f,      z_f      }, .normal = normal, .block_type = block_u32, .uv = .{ 0,  0  }, .ao = cell.ao[0], .skylight = cell.sky[0] },
                .{ .pos = .{ x_f, y_f + hf, z_f      }, .normal = normal, .block_type = block_u32, .uv = .{ 0,  hf }, .ao = cell.ao[1], .skylight = cell.sky[1] },
                .{ .pos = .{ x_f, y_f + hf, z_f + wf }, .normal = normal, .block_type = block_u32, .uv = .{ wf, hf }, .ao = cell.ao[2], .skylight = cell.sky[2] },
                .{ .pos = .{ x_f, y_f,      z_f + wf }, .normal = normal, .block_type = block_u32, .uv = .{ wf, 0  }, .ao = cell.ao[3], .skylight = cell.sky[3] },
            };
        },
        .nx => blk: {
            // -X face: d = local x, plane at world x = world_ox + d.
            // In-plane axes: i = Z, j = Y. Vertex 0 sits at (+z+w) to match naive winding.
            const x_f: f32 = @floatFromInt(world_ox + d);
            const y_f: f32 = @floatFromInt(ja);
            const z_f: f32 = @floatFromInt(world_oz + ia);
            break :blk [_]VoxelVertex{
                .{ .pos = .{ x_f, y_f,      z_f + wf }, .normal = normal, .block_type = block_u32, .uv = .{ 0,  0  }, .ao = cell.ao[0], .skylight = cell.sky[0] },
                .{ .pos = .{ x_f, y_f + hf, z_f + wf }, .normal = normal, .block_type = block_u32, .uv = .{ 0,  hf }, .ao = cell.ao[1], .skylight = cell.sky[1] },
                .{ .pos = .{ x_f, y_f + hf, z_f      }, .normal = normal, .block_type = block_u32, .uv = .{ wf, hf }, .ao = cell.ao[2], .skylight = cell.sky[2] },
                .{ .pos = .{ x_f, y_f,      z_f      }, .normal = normal, .block_type = block_u32, .uv = .{ wf, 0  }, .ao = cell.ao[3], .skylight = cell.sky[3] },
            };
        },
        .py => blk: {
            // +Y face: d = local y, plane at world y = d + 1.
            // In-plane axes: i = X, j = Z. Merge grows w along X, h along Z.
            const x_f: f32 = @floatFromInt(world_ox + ia);
            const y_f: f32 = @floatFromInt(d + 1);
            const z_f: f32 = @floatFromInt(world_oz + ja);
            break :blk [_]VoxelVertex{
                .{ .pos = .{ x_f,      y_f, z_f      }, .normal = normal, .block_type = block_u32, .uv = .{ 0,  0  }, .ao = cell.ao[0], .skylight = cell.sky[0] },
                .{ .pos = .{ x_f,      y_f, z_f + hf }, .normal = normal, .block_type = block_u32, .uv = .{ 0,  hf }, .ao = cell.ao[1], .skylight = cell.sky[1] },
                .{ .pos = .{ x_f + wf, y_f, z_f + hf }, .normal = normal, .block_type = block_u32, .uv = .{ wf, hf }, .ao = cell.ao[2], .skylight = cell.sky[2] },
                .{ .pos = .{ x_f + wf, y_f, z_f      }, .normal = normal, .block_type = block_u32, .uv = .{ wf, 0  }, .ao = cell.ao[3], .skylight = cell.sky[3] },
            };
        },
        .ny => blk: {
            // -Y face: d = local y, plane at world y = d.
            // In-plane axes: i = X, j = Z. Vertex 0 sits at (+z+h) to match naive winding.
            const x_f: f32 = @floatFromInt(world_ox + ia);
            const y_f: f32 = @floatFromInt(d);
            const z_f: f32 = @floatFromInt(world_oz + ja);
            break :blk [_]VoxelVertex{
                .{ .pos = .{ x_f,      y_f, z_f + hf }, .normal = normal, .block_type = block_u32, .uv = .{ 0,  0  }, .ao = cell.ao[0], .skylight = cell.sky[0] },
                .{ .pos = .{ x_f,      y_f, z_f      }, .normal = normal, .block_type = block_u32, .uv = .{ 0,  hf }, .ao = cell.ao[1], .skylight = cell.sky[1] },
                .{ .pos = .{ x_f + wf, y_f, z_f      }, .normal = normal, .block_type = block_u32, .uv = .{ wf, hf }, .ao = cell.ao[2], .skylight = cell.sky[2] },
                .{ .pos = .{ x_f + wf, y_f, z_f + hf }, .normal = normal, .block_type = block_u32, .uv = .{ wf, 0  }, .ao = cell.ao[3], .skylight = cell.sky[3] },
            };
        },
        .pz => blk: {
            // +Z face: d = local z, plane at world z = world_oz + d + 1.
            // In-plane axes: i = X, j = Y. Merge grows w along X, h along Y.
            const x_f: f32 = @floatFromInt(world_ox + ia);
            const y_f: f32 = @floatFromInt(ja);
            const z_f: f32 = @floatFromInt(world_oz + d + 1);
            break :blk [_]VoxelVertex{
                .{ .pos = .{ x_f,      y_f,      z_f }, .normal = normal, .block_type = block_u32, .uv = .{ 0,  0  }, .ao = cell.ao[0], .skylight = cell.sky[0] },
                .{ .pos = .{ x_f + wf, y_f,      z_f }, .normal = normal, .block_type = block_u32, .uv = .{ wf, 0  }, .ao = cell.ao[1], .skylight = cell.sky[1] },
                .{ .pos = .{ x_f + wf, y_f + hf, z_f }, .normal = normal, .block_type = block_u32, .uv = .{ wf, hf }, .ao = cell.ao[2], .skylight = cell.sky[2] },
                .{ .pos = .{ x_f,      y_f + hf, z_f }, .normal = normal, .block_type = block_u32, .uv = .{ 0,  hf }, .ao = cell.ao[3], .skylight = cell.sky[3] },
            };
        },
        .nz => blk: {
            // -Z face: d = local z, plane at world z = world_oz + d.
            // In-plane axes: i = X, j = Y. Vertex 0 sits at (+x+w) to match naive winding.
            const x_f: f32 = @floatFromInt(world_ox + ia);
            const y_f: f32 = @floatFromInt(ja);
            const z_f: f32 = @floatFromInt(world_oz + d);
            break :blk [_]VoxelVertex{
                .{ .pos = .{ x_f + wf, y_f,      z_f }, .normal = normal, .block_type = block_u32, .uv = .{ 0,  0  }, .ao = cell.ao[0], .skylight = cell.sky[0] },
                .{ .pos = .{ x_f,      y_f,      z_f }, .normal = normal, .block_type = block_u32, .uv = .{ wf, 0  }, .ao = cell.ao[1], .skylight = cell.sky[1] },
                .{ .pos = .{ x_f,      y_f + hf, z_f }, .normal = normal, .block_type = block_u32, .uv = .{ wf, hf }, .ao = cell.ao[2], .skylight = cell.sky[2] },
                .{ .pos = .{ x_f + wf, y_f + hf, z_f }, .normal = normal, .block_type = block_u32, .uv = .{ 0,  hf }, .ao = cell.ao[3], .skylight = cell.sky[3] },
            };
        },
    };

    try mesh.vertices.appendSlice(mesh.allocator, &verts);

    const inds = [_]u32{
        base_idx, base_idx + 1, base_idx + 2,
        base_idx, base_idx + 2, base_idx + 3,
    };
    try mesh.indices.appendSlice(mesh.allocator, &inds);

    try mesh.quad_block.append(mesh.allocator, block_idx);
    try mesh.quad_highlight.append(mesh.allocator, 255);
}

/// Translate (d, i, j) in a face's in-plane coordinate system to a local
/// (lx, ly, lz) block coord. Paired with the (u, v) → (i, j) mapping inside
/// each per-face branch of generateMeshGreedy.
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

/// Greedy-merged mesh generation. For each of the 6 face directions, slices
/// the chunk into planes, builds a per-cell `GreedyCell` signature grid, then
/// walks the grid growing rectangles of bit-identical (block_type, ao, sky)
/// cells. One merged quad is emitted per rectangle.
///
/// Complexity per chunk: O(d_max × i_max × j_max × signature_cost). Same as
/// naive in the limit — the greedy walk only touches each cell O(1) extra
/// times via the `visited` mask. On flatland/hilly terrain the merged quad
/// count drops 5–50×; the cost of the scan dominates the cost of the merges.
///
/// The mesher allocates two scratch buffers per call (one GreedyCell grid +
/// one `bool` visited mask). Each is sized for the largest possible slice
/// (CHUNK_W × CHUNK_H = 12288 cells). Per-call re-allocation is accepted
/// because `generateMeshGreedy` runs at most a handful of times per tick and
/// the cost is dwarfed by the AO/sky sample work.
pub fn generateMeshGreedy(
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
    const visited = try mesh.allocator.alloc(bool, slice_len);
    defer mesh.allocator.free(visited);

    // Merge size cap. The voxel demo uses painter's-algorithm sorting in
    // software (no hardware depth — see CLAUDE.md §macOS/Metal wgpu bug)
    // and the sort key is the quad centroid distance. A merged 48×48 quad
    // has its centroid far from its farthest pixel, which causes visible
    // sort inversions against overlapping smaller geometry (pit walls,
    // hover outlines, etc.). Capping the merge at `MAX_GREEDY_DIM` on each
    // axis keeps every merged quad's centroid within half that many blocks
    // of its farthest corner — close enough that painter's sort order
    // matches the naive 1×1 baseline to within the RMS tolerance used by
    // the greedy_vs_naive regression.
    //
    // Cap of 6 lands comfortably inside the RMS tolerance while still
    // hitting the 5–10× reduction target on flatland and capturing most
    // of the hilly-terrain wins. Measured `greedy_vs_naive.tas` per-channel
    // RMS on a flatland pit scene:
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
    // the cap can be lifted; the RMS test will flag any regression.
    const MAX_GREEDY_DIM: i32 = 6;

    inline for ([_]Face{ .px, .nx, .py, .ny, .pz, .nz }) |face| {
        const ext = greedyFaceExtents(face);
        const i_max: i32 = ext.i_max;
        const j_max: i32 = ext.j_max;
        const d_max: i32 = ext.d_max;
        const i_max_usz: usize = @intCast(i_max);
        const j_max_usz: usize = @intCast(j_max);
        const active_slice: usize = i_max_usz * j_max_usz;

        var d: i32 = 0;
        while (d < d_max) : (d += 1) {
            // ---- populate cell grid for this plane ----
            @memset(cells[0..active_slice], .{});
            var ii: i32 = 0;
            while (ii < i_max) : (ii += 1) {
                var jj: i32 = 0;
                while (jj < j_max) : (jj += 1) {
                    const bp = greedyIJToLocalBlock(face, d, ii, jj);
                    const cell = computeGreedyCell(
                        chunk,
                        getter,
                        world_ox,
                        world_oz,
                        bp.x,
                        bp.y,
                        bp.z,
                        face,
                        ao_strategy,
                        lighting_mode,
                    );
                    const ii_usz: usize = @intCast(ii);
                    const jj_usz: usize = @intCast(jj);
                    cells[ii_usz * j_max_usz + jj_usz] = cell;
                }
            }

            // ---- greedy walk ----
            @memset(visited[0..active_slice], false);
            var ia: i32 = 0;
            while (ia < i_max) : (ia += 1) {
                var ja: i32 = 0;
                while (ja < j_max) : (ja += 1) {
                    const ia_usz: usize = @intCast(ia);
                    const ja_usz: usize = @intCast(ja);
                    const idx0 = ia_usz * j_max_usz + ja_usz;
                    if (visited[idx0]) continue;
                    const seed = cells[idx0];
                    if (!seed.present) {
                        visited[idx0] = true;
                        continue;
                    }

                    // Grow width along i (within this j row) — walk +i while
                    // cells keep matching the seed signature and we haven't
                    // hit the painter's-sort cap.
                    var w: i32 = 1;
                    while (ia + w < i_max and w < MAX_GREEDY_DIM) {
                        const iw_usz: usize = @intCast(ia + w);
                        const idxw = iw_usz * j_max_usz + ja_usz;
                        if (visited[idxw]) break;
                        if (!greedyCellEq(seed, cells[idxw])) break;
                        w += 1;
                    }

                    // Grow height along j — every row in [ja+1 .. ja+h) must
                    // be fully available across the w-wide strip and match seed.
                    var h: i32 = 1;
                    grow_h: while (ja + h < j_max and h < MAX_GREEDY_DIM) {
                        var k: i32 = 0;
                        while (k < w) : (k += 1) {
                            const iw_usz: usize = @intCast(ia + k);
                            const jh_usz: usize = @intCast(ja + h);
                            const idxk = iw_usz * j_max_usz + jh_usz;
                            if (visited[idxk]) break :grow_h;
                            if (!greedyCellEq(seed, cells[idxk])) break :grow_h;
                        }
                        h += 1;
                    }

                    // Mark the w × h rect visited.
                    var rk: i32 = 0;
                    while (rk < w) : (rk += 1) {
                        var rl: i32 = 0;
                        while (rl < h) : (rl += 1) {
                            const ri_usz: usize = @intCast(ia + rk);
                            const rj_usz: usize = @intCast(ja + rl);
                            visited[ri_usz * j_max_usz + rj_usz] = true;
                        }
                    }

                    // Emit the merged quad. `block_idx` is the packed index
                    // of the (ia, ja) corner block — see the comment on
                    // `emitGreedyQuad` for why the parallel array is still
                    // populated even though one merged quad can span many blocks.
                    const corner = greedyIJToLocalBlock(face, d, ia, ja);
                    const block_idx = packBlockIdx(corner.x, corner.y, corner.z);
                    try emitGreedyQuad(mesh, face, d, ia, ja, w, h, seed, block_idx, world_ox, world_oz);
                }
            }
        }
    }
}

/// Dispatch helper: run the requested meshing strategy and log a one-liner
/// comparing the emitted quad count to the naive upper bound. For greedy
/// mode we separately count faces that *would* have been emitted by the
/// naive mesher so the log can show the real reduction ratio; the extra
/// pass is a straight neighbour-scan and costs <5% of the full mesh.
pub fn generateMeshForMode(
    chunk: *const Chunk,
    mesh: *Mesh,
    world_ox: i32,
    world_oz: i32,
    getter: BlockGetter,
    ao_strategy: AOStrategy,
    lighting_mode: LightingMode,
    mode: MeshingMode,
) !void {
    switch (mode) {
        .naive => {
            try generateMesh(chunk, mesh, world_ox, world_oz, getter, ao_strategy, lighting_mode);
            const m_count = mesh.indices.items.len / 6;
            std.log.info("[MESH naive: {} quads]", .{m_count});
        },
        .greedy => {
            // Count how many quads a naive pass would have emitted, without
            // actually meshing them. O(chunk_volume × 6) — cheap next to the
            // greedy pass that follows.
            const naive_count = countNaiveFaces(chunk, getter, world_ox, world_oz);

            try generateMeshGreedy(chunk, mesh, world_ox, world_oz, getter, ao_strategy, lighting_mode);
            const m_count = mesh.indices.items.len / 6;

            const reduction_pct: f64 = if (naive_count == 0)
                0.0
            else
                100.0 * (1.0 - @as(f64, @floatFromInt(m_count)) / @as(f64, @floatFromInt(naive_count)));
            std.log.info(
                "[MESH greedy: {}\u{2192}{} quads ({d:.1}% reduction)]",
                .{ naive_count, m_count, reduction_pct },
            );
        },
    }
}

/// Count the visible face candidates that a naive mesher would emit for this
/// chunk. Used by `generateMeshForMode` to print a reduction ratio; matches
/// the same `shouldRenderFace` gate as `generateMesh`/`generateMeshGreedy`.
fn countNaiveFaces(chunk: *const Chunk, getter: BlockGetter, world_ox: i32, world_oz: i32) usize {
    var count: usize = 0;
    var x: i32 = 0;
    while (x < CHUNK_W) : (x += 1) {
        var y: i32 = 0;
        while (y < CHUNK_H) : (y += 1) {
            var z: i32 = 0;
            while (z < CHUNK_W) : (z += 1) {
                if (chunk.getBlock(x, y, z) == .air) continue;
                for ([_]Face{ .px, .nx, .py, .ny, .pz, .nz }) |face| {
                    if (shouldRenderFace(chunk, getter, x, y, z, world_ox, world_oz, face)) count += 1;
                }
            }
        }
    }
    return count;
}
