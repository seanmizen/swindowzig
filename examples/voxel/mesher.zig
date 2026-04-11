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
