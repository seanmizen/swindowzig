const std = @import("std");

pub const CHUNK_SIZE = 16;

pub const BlockType = enum(u8) {
    air = 0,
    grass = 1,
    dirt = 2,
    stone = 3,
};

pub const Chunk = struct {
    blocks: [CHUNK_SIZE][CHUNK_SIZE][CHUNK_SIZE]BlockType,

    pub fn init() Chunk {
        return .{
            .blocks = [_][CHUNK_SIZE][CHUNK_SIZE]BlockType{
                [_][CHUNK_SIZE]BlockType{
                    [_]BlockType{.air} ** CHUNK_SIZE,
                } ** CHUNK_SIZE,
            } ** CHUNK_SIZE,
        };
    }

    pub fn getBlock(self: *const Chunk, x: i32, y: i32, z: i32) BlockType {
        if (x < 0 or x >= CHUNK_SIZE or y < 0 or y >= CHUNK_SIZE or z < 0 or z >= CHUNK_SIZE) {
            return .air;
        }
        return self.blocks[@intCast(x)][@intCast(y)][@intCast(z)];
    }

    pub fn setBlock(self: *Chunk, x: i32, y: i32, z: i32, block: BlockType) void {
        if (x < 0 or x >= CHUNK_SIZE or y < 0 or y >= CHUNK_SIZE or z < 0 or z >= CHUNK_SIZE) {
            return;
        }
        self.blocks[@intCast(x)][@intCast(y)][@intCast(z)] = block;
    }

    /// Generate simple terrain: stone bottom, dirt middle, grass top
    pub fn generateTerrain(self: *Chunk) void {
        var x: i32 = 0;
        while (x < CHUNK_SIZE) : (x += 1) {
            var z: i32 = 0;
            while (z < CHUNK_SIZE) : (z += 1) {
                // Create a simple height map (flat with some variation)
                const height = 8 + @rem(x + z, 4);

                var y: i32 = 0;
                while (y < height) : (y += 1) {
                    if (y == height - 1) {
                        self.setBlock(x, y, z, .grass);
                    } else if (y >= height - 4) {
                        self.setBlock(x, y, z, .dirt);
                    } else {
                        self.setBlock(x, y, z, .stone);
                    }
                }
            }
        }
    }
};
