const std = @import("std");
const chunk_mod = @import("chunk.zig");
const Chunk = chunk_mod.Chunk;
const BlockType = chunk_mod.BlockType;
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
        };
    }

    pub fn deinit(self: *Mesh) void {
        self.vertices.deinit(self.allocator);
        self.indices.deinit(self.allocator);
        if (self.sort_scratch.len > 0) self.allocator.free(self.sort_scratch);
        if (self.sort_indices.len > 0) self.allocator.free(self.sort_indices);
    }

    pub fn clear(self: *Mesh) void {
        self.vertices.clearRetainingCapacity();
        self.indices.clearRetainingCapacity();
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
};

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

/// Check if a face should be rendered (neighbor is air or out of bounds)
fn shouldRenderFace(chunk: *const Chunk, x: i32, y: i32, z: i32, face: Face) bool {
    const offset = face_offsets[@intFromEnum(face)];
    const nx = x + offset[0];
    const ny = y + offset[1];
    const nz = z + offset[2];
    return chunk.getBlock(nx, ny, nz) == .air;
}

/// Add a quad face to the mesh
fn addQuad(
    mesh: *Mesh,
    x: f32,
    y: f32,
    z: f32,
    face: Face,
    block_type: BlockType,
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

/// Simple (non-greedy) meshing: one quad per visible face
pub fn generateMesh(chunk: *const Chunk, mesh: *Mesh) !void {
    mesh.clear();

    var x: i32 = 0;
    while (x < CHUNK_W) : (x += 1) {
        var y: i32 = 0;
        while (y < CHUNK_H) : (y += 1) {
            var z: i32 = 0;
            while (z < CHUNK_W) : (z += 1) {
                const block = chunk.getBlock(x, y, z);
                if (block == .air) continue;

                // Check each face
                for ([_]Face{ .px, .nx, .py, .ny, .pz, .nz }) |face| {
                    if (shouldRenderFace(chunk, x, y, z, face)) {
                        try addQuad(
                            mesh,
                            @floatFromInt(x),
                            @floatFromInt(y),
                            @floatFromInt(z),
                            face,
                            block,
                        );
                    }
                }
            }
        }
    }
}
