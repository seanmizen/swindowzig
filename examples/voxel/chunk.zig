const std = @import("std");

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

    /// Flat terrain matching Minecraft superflat layout:
    ///   Y=0       bedrock
    ///   Y=1–59    stone
    ///   Y=60–62   dirt
    ///   Y=63      grass (surface — Minecraft sea level)
    pub fn generateTerrain(self: *Chunk) void {
        var x: i32 = 0;
        while (x < CHUNK_W) : (x += 1) {
            var z: i32 = 0;
            while (z < CHUNK_W) : (z += 1) {
                self.setBlock(x, 0, z, .bedrock);
                var y: i32 = 1;
                while (y <= 59) : (y += 1) {
                    self.setBlock(x, y, z, .stone);
                }
                y = 60;
                while (y <= 62) : (y += 1) {
                    self.setBlock(x, y, z, .dirt);
                }
                self.setBlock(x, 63, z, .grass);
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
