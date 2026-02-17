const std = @import("std");

pub const CHUNK_W = 48; // X and Z dimension
pub const CHUNK_H = 12; // Y dimension

pub const BlockType = enum(u8) {
    air = 0,
    grass = 1,
    dirt = 2,
    stone = 3,
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

    /// Flat terrain: stone base, dirt layer, grass surface at y=7
    pub fn generateTerrain(self: *Chunk) void {
        const surface: i32 = 7;
        var x: i32 = 0;
        while (x < CHUNK_W) : (x += 1) {
            var z: i32 = 0;
            while (z < CHUNK_W) : (z += 1) {
                var y: i32 = 0;
                while (y <= surface) : (y += 1) {
                    if (y == surface) {
                        self.setBlock(x, y, z, .grass);
                    } else if (y >= surface - 2) {
                        self.setBlock(x, y, z, .dirt);
                    } else {
                        self.setBlock(x, y, z, .stone);
                    }
                }
            }
        }
    }
};
