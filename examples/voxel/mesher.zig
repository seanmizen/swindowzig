const std = @import("std");
const chunk_mod = @import("chunk.zig");
const Chunk = chunk_mod.Chunk;
const BlockType = chunk_mod.BlockType;
const BlockGetter = chunk_mod.BlockGetter;
const CHUNK_W = chunk_mod.CHUNK_W;
const CHUNK_H = chunk_mod.CHUNK_H;

const DEBUG = false; // Enable for mesh generation debug logging

/// Vertex format matching voxel.wgsl
pub const VoxelVertex = extern struct {
    pos: [3]f32,
    normal: [3]f32,
    block_type: u32,
    uv: [2]f32,
    _padding: [3]f32 = [_]f32{0} ** 3, // Pad to 48 bytes (16-byte aligned)
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
    // Fast path: neighbour is within this chunk (direct array access, no HashMap)
    if (nx >= 0 and nx < CHUNK_W and ny >= 0 and ny < CHUNK_H and nz >= 0 and nz < CHUNK_W) {
        return chunk.blocks[@intCast(nx)][@intCast(ny)][@intCast(nz)] == .air;
    }
    // Slow path: neighbour in adjacent chunk — world HashMap lookup
    return getter.getBlock(world_ox + nx, ny, world_oz + nz) == .air;
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
) !void {
    const base_idx: u32 = @intCast(mesh.vertices.items.len);
    const normal = face_normals[@intFromEnum(face)];
    const block_u32: u32 = @intFromEnum(block_type);

    // Define quad vertices based on face direction
    const verts = switch (face) {
        .px => [_]VoxelVertex{ // +X face
            .{ .pos = .{ x + 1, y, z }, .normal = normal, .block_type = block_u32, .uv = .{ 0, 0 } },
            .{ .pos = .{ x + 1, y + 1, z }, .normal = normal, .block_type = block_u32, .uv = .{ 0, 1 } },
            .{ .pos = .{ x + 1, y + 1, z + 1 }, .normal = normal, .block_type = block_u32, .uv = .{ 1, 1 } },
            .{ .pos = .{ x + 1, y, z + 1 }, .normal = normal, .block_type = block_u32, .uv = .{ 1, 0 } },
        },
        .nx => [_]VoxelVertex{ // -X face
            .{ .pos = .{ x, y, z + 1 }, .normal = normal, .block_type = block_u32, .uv = .{ 0, 0 } },
            .{ .pos = .{ x, y + 1, z + 1 }, .normal = normal, .block_type = block_u32, .uv = .{ 0, 1 } },
            .{ .pos = .{ x, y + 1, z }, .normal = normal, .block_type = block_u32, .uv = .{ 1, 1 } },
            .{ .pos = .{ x, y, z }, .normal = normal, .block_type = block_u32, .uv = .{ 1, 0 } },
        },
        .py => [_]VoxelVertex{ // +Y face (CCW from above: +Y normal)
            .{ .pos = .{ x, y + 1, z }, .normal = normal, .block_type = block_u32, .uv = .{ 0, 0 } },
            .{ .pos = .{ x, y + 1, z + 1 }, .normal = normal, .block_type = block_u32, .uv = .{ 0, 1 } },
            .{ .pos = .{ x + 1, y + 1, z + 1 }, .normal = normal, .block_type = block_u32, .uv = .{ 1, 1 } },
            .{ .pos = .{ x + 1, y + 1, z }, .normal = normal, .block_type = block_u32, .uv = .{ 1, 0 } },
        },
        .ny => [_]VoxelVertex{ // -Y face (CCW from below: -Y normal)
            .{ .pos = .{ x, y, z + 1 }, .normal = normal, .block_type = block_u32, .uv = .{ 0, 0 } },
            .{ .pos = .{ x, y, z }, .normal = normal, .block_type = block_u32, .uv = .{ 0, 1 } },
            .{ .pos = .{ x + 1, y, z }, .normal = normal, .block_type = block_u32, .uv = .{ 1, 1 } },
            .{ .pos = .{ x + 1, y, z + 1 }, .normal = normal, .block_type = block_u32, .uv = .{ 1, 0 } },
        },
        .pz => [_]VoxelVertex{ // +Z face (CCW from front: +Z normal)
            .{ .pos = .{ x, y, z + 1 }, .normal = normal, .block_type = block_u32, .uv = .{ 0, 0 } },
            .{ .pos = .{ x + 1, y, z + 1 }, .normal = normal, .block_type = block_u32, .uv = .{ 1, 0 } },
            .{ .pos = .{ x + 1, y + 1, z + 1 }, .normal = normal, .block_type = block_u32, .uv = .{ 1, 1 } },
            .{ .pos = .{ x, y + 1, z + 1 }, .normal = normal, .block_type = block_u32, .uv = .{ 0, 1 } },
        },
        .nz => [_]VoxelVertex{ // -Z face (CCW from back: -Z normal)
            .{ .pos = .{ x + 1, y, z }, .normal = normal, .block_type = block_u32, .uv = .{ 0, 0 } },
            .{ .pos = .{ x, y, z }, .normal = normal, .block_type = block_u32, .uv = .{ 1, 0 } },
            .{ .pos = .{ x, y + 1, z }, .normal = normal, .block_type = block_u32, .uv = .{ 1, 1 } },
            .{ .pos = .{ x + 1, y + 1, z }, .normal = normal, .block_type = block_u32, .uv = .{ 0, 1 } },
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
pub fn generateMesh(chunk: *const Chunk, mesh: *Mesh, world_ox: i32, world_oz: i32, getter: BlockGetter) !void {
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
                        );
                    }
                }
            }
        }
    }
}
