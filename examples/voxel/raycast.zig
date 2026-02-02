const std = @import("std");

pub fn Raycast(comptime Vec3Type: type, comptime ChunkType: type) type {
    return struct {
        const Vec3 = Vec3Type;
        const Chunk = ChunkType;
        const CHUNK_SIZE = 16;

        pub const RaycastHit = struct {
            hit: bool,
            block_pos: Vec3, // Position of the hit block
            face_normal: Vec3, // Normal of the face that was hit
        };

        /// DDA raycast through voxel grid
        /// Returns the first non-air block hit, or miss if nothing hit within max_distance
        pub fn raycast(chunk: *const Chunk, origin: Vec3, direction: Vec3, max_distance: f32) RaycastHit {
            const dir = direction.normalize();

            // Current voxel position
            var voxel_x = @as(i32, @intFromFloat(@floor(origin.x)));
            var voxel_y = @as(i32, @intFromFloat(@floor(origin.y)));
            var voxel_z = @as(i32, @intFromFloat(@floor(origin.z)));

            // Step direction (1 or -1)
            const step_x: i32 = if (dir.x > 0) 1 else -1;
            const step_y: i32 = if (dir.y > 0) 1 else -1;
            const step_z: i32 = if (dir.z > 0) 1 else -1;

            // Distance to next voxel boundary along each axis
            const delta_x = if (@abs(dir.x) < 0.0001) 1e10 else @abs(1.0 / dir.x);
            const delta_y = if (@abs(dir.y) < 0.0001) 1e10 else @abs(1.0 / dir.y);
            const delta_z = if (@abs(dir.z) < 0.0001) 1e10 else @abs(1.0 / dir.z);

            // Initial t values for next boundary crossing
            var t_max_x = if (@abs(dir.x) < 0.0001) 1e10 else blk: {
                const boundary = if (step_x > 0) @floor(origin.x) + 1.0 else @floor(origin.x);
                break :blk (boundary - origin.x) / dir.x;
            };
            var t_max_y = if (@abs(dir.y) < 0.0001) 1e10 else blk: {
                const boundary = if (step_y > 0) @floor(origin.y) + 1.0 else @floor(origin.y);
                break :blk (boundary - origin.y) / dir.y;
            };
            var t_max_z = if (@abs(dir.z) < 0.0001) 1e10 else blk: {
                const boundary = if (step_z > 0) @floor(origin.z) + 1.0 else @floor(origin.z);
                break :blk (boundary - origin.z) / dir.z;
            };

            var face_normal = Vec3.init(0, 0, 0);
            var distance: f32 = 0;

            // DDA traversal
            var iterations: u32 = 0;
            while (iterations < 100 and distance < max_distance) : (iterations += 1) {
                // Check current voxel
                if (voxel_x >= 0 and voxel_x < CHUNK_SIZE and
                    voxel_y >= 0 and voxel_y < CHUNK_SIZE and
                    voxel_z >= 0 and voxel_z < CHUNK_SIZE)
                {
                    const block = chunk.getBlock(voxel_x, voxel_y, voxel_z);
                    if (block != .air) {
                        return .{
                            .hit = true,
                            .block_pos = Vec3.init(@floatFromInt(voxel_x), @floatFromInt(voxel_y), @floatFromInt(voxel_z)),
                            .face_normal = face_normal,
                        };
                    }
                }

                // Step to next voxel
                if (t_max_x < t_max_y) {
                    if (t_max_x < t_max_z) {
                        voxel_x += step_x;
                        distance = t_max_x;
                        t_max_x += delta_x;
                        face_normal = Vec3.init(@as(f32, @floatFromInt(-step_x)), 0, 0);
                    } else {
                        voxel_z += step_z;
                        distance = t_max_z;
                        t_max_z += delta_z;
                        face_normal = Vec3.init(0, 0, @as(f32, @floatFromInt(-step_z)));
                    }
                } else {
                    if (t_max_y < t_max_z) {
                        voxel_y += step_y;
                        distance = t_max_y;
                        t_max_y += delta_y;
                        face_normal = Vec3.init(0, @as(f32, @floatFromInt(-step_y)), 0);
                    } else {
                        voxel_z += step_z;
                        distance = t_max_z;
                        t_max_z += delta_z;
                        face_normal = Vec3.init(0, 0, @as(f32, @floatFromInt(-step_z)));
                    }
                }
            }

            return .{
                .hit = false,
                .block_pos = Vec3.zero(),
                .face_normal = Vec3.zero(),
            };
        }
    };
}
