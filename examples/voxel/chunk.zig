const std = @import("std");
const world_gen = @import("world_gen.zig");

pub const CHUNK_W = 48; // X and Z dimension
pub const CHUNK_H = 256; // Y dimension (matches classic Minecraft build height)

pub const BlockType = enum(u8) {
    air = 0,
    grass = 1,
    dirt = 2,
    stone = 3,
    bedrock = 4,
    debug_marker = 99,
};

pub const Chunk = struct {
    blocks: [CHUNK_W][CHUNK_H][CHUNK_W]BlockType,

    pub fn init() Chunk {
        return .{
            .blocks = [_][CHUNK_H][CHUNK_W]BlockType{
                [_][CHUNK_W]BlockType{
                    [_]BlockType{.air} ** CHUNK_W,
                } ** CHUNK_H,
            } ** CHUNK_W,
        };
    }

    pub fn getBlock(self: *const Chunk, x: i32, y: i32, z: i32) BlockType {
        if (x < 0 or x >= CHUNK_W or y < 0 or y >= CHUNK_H or z < 0 or z >= CHUNK_W) {
            return .air;
        }
        return self.blocks[@intCast(x)][@intCast(y)][@intCast(z)];
    }

    pub fn setBlock(self: *Chunk, x: i32, y: i32, z: i32, block: BlockType) void {
        if (x < 0 or x >= CHUNK_W or y < 0 or y >= CHUNK_H or z < 0 or z >= CHUNK_W) {
            return;
        }
        self.blocks[@intCast(x)][@intCast(y)][@intCast(z)] = block;
    }

    /// Generate terrain for this chunk at chunk grid position (cx, cz).
    ///
    /// Layout per column (surface = noise-sampled height):
    ///   Y=0             bedrock
    ///   Y=1..(surface-4) stone
    ///   Y=(surface-3)..(surface-1) dirt (3 layers)
    ///   Y=surface       grass
    ///
    /// For the flatland preset (noise_octaves=0), surface is always
    /// terrain_height_min=63, reproducing the original Minecraft superflat layout.
    pub fn generateTerrain(self: *Chunk, cx: i32, cz: i32, config: world_gen.WorldGenConfig) void {
        var x: i32 = 0;
        while (x < CHUNK_W) : (x += 1) {
            var z: i32 = 0;
            while (z < CHUNK_W) : (z += 1) {
                const wx = cx * CHUNK_W + x;
                const wz = cz * CHUNK_W + z;
                const surface = world_gen.sampleHeight(wx, wz, config);

                self.setBlock(x, 0, z, .bedrock);

                // Stone fills from Y=1 up to (but not including) the 3-dirt band.
                var y: i32 = 1;
                while (y < surface - 3) : (y += 1) {
                    self.setBlock(x, y, z, .stone);
                }

                // Three dirt layers immediately below the surface.
                y = @max(1, surface - 3);
                while (y < surface) : (y += 1) {
                    self.setBlock(x, y, z, .dirt);
                }

                // Grass cap.
                if (surface >= 1 and surface < CHUNK_H) {
                    self.setBlock(x, surface, z, .grass);
                }
            }
        }
    }
};

/// Type-erased block source. Allows player physics and raycasting to work with
/// either a single Chunk (local coords) or a World (world coords).
pub const BlockGetter = struct {
    ctx: *const anyopaque,
    getFn: *const fn (ctx: *const anyopaque, x: i32, y: i32, z: i32) BlockType,

    pub fn getBlock(self: BlockGetter, x: i32, y: i32, z: i32) BlockType {
        return self.getFn(self.ctx, x, y, z);
    }
};
