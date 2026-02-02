const std = @import("std");
const chunk_mod = @import("chunk.zig");
const Chunk = chunk_mod.Chunk;
const BlockType = chunk_mod.BlockType;
const CHUNK_SIZE = chunk_mod.CHUNK_SIZE;

/// Vertex format matching voxel.wgsl
pub const VoxelVertex = extern struct {
    pos: [3]f32,
    normal: [3]f32,
    block_type: u32,
    uv: [2]f32,
};

pub const Mesh = struct {
    allocator: std.mem.Allocator,
    vertices: std.ArrayList(VoxelVertex),
    indices: std.ArrayList(u32),

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
    }

    pub fn clear(self: *Mesh) void {
        self.vertices.clearRetainingCapacity();
        self.indices.clearRetainingCapacity();
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
        .py => [_]VoxelVertex{ // +Y face
            .{ .pos = .{ x, y + 1, z }, .normal = normal, .block_type = block_u32, .uv = .{ 0, 0 } },
            .{ .pos = .{ x + 1, y + 1, z }, .normal = normal, .block_type = block_u32, .uv = .{ 1, 0 } },
            .{ .pos = .{ x + 1, y + 1, z + 1 }, .normal = normal, .block_type = block_u32, .uv = .{ 1, 1 } },
            .{ .pos = .{ x, y + 1, z + 1 }, .normal = normal, .block_type = block_u32, .uv = .{ 0, 1 } },
        },
        .ny => [_]VoxelVertex{ // -Y face
            .{ .pos = .{ x, y, z + 1 }, .normal = normal, .block_type = block_u32, .uv = .{ 0, 0 } },
            .{ .pos = .{ x + 1, y, z + 1 }, .normal = normal, .block_type = block_u32, .uv = .{ 1, 0 } },
            .{ .pos = .{ x + 1, y, z }, .normal = normal, .block_type = block_u32, .uv = .{ 1, 1 } },
            .{ .pos = .{ x, y, z }, .normal = normal, .block_type = block_u32, .uv = .{ 0, 1 } },
        },
        .pz => [_]VoxelVertex{ // +Z face
            .{ .pos = .{ x, y, z + 1 }, .normal = normal, .block_type = block_u32, .uv = .{ 0, 0 } },
            .{ .pos = .{ x, y + 1, z + 1 }, .normal = normal, .block_type = block_u32, .uv = .{ 0, 1 } },
            .{ .pos = .{ x + 1, y + 1, z + 1 }, .normal = normal, .block_type = block_u32, .uv = .{ 1, 1 } },
            .{ .pos = .{ x + 1, y, z + 1 }, .normal = normal, .block_type = block_u32, .uv = .{ 1, 0 } },
        },
        .nz => [_]VoxelVertex{ // -Z face
            .{ .pos = .{ x + 1, y, z }, .normal = normal, .block_type = block_u32, .uv = .{ 0, 0 } },
            .{ .pos = .{ x + 1, y + 1, z }, .normal = normal, .block_type = block_u32, .uv = .{ 0, 1 } },
            .{ .pos = .{ x, y + 1, z }, .normal = normal, .block_type = block_u32, .uv = .{ 1, 1 } },
            .{ .pos = .{ x, y, z }, .normal = normal, .block_type = block_u32, .uv = .{ 1, 0 } },
        },
    };

    try mesh.vertices.appendSlice(mesh.allocator, &verts);

    // Two triangles per quad (CCW winding)
    const inds = [_]u32{
        base_idx,     base_idx + 1, base_idx + 2,
        base_idx,     base_idx + 2, base_idx + 3,
    };
    try mesh.indices.appendSlice(mesh.allocator, &inds);
}

/// Simple (non-greedy) meshing: one quad per visible face
pub fn generateMesh(chunk: *const Chunk, mesh: *Mesh) !void {
    mesh.clear();

    var x: i32 = 0;
    while (x < CHUNK_SIZE) : (x += 1) {
        var y: i32 = 0;
        while (y < CHUNK_SIZE) : (y += 1) {
            var z: i32 = 0;
            while (z < CHUNK_SIZE) : (z += 1) {
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
