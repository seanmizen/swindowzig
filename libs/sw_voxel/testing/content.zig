//! The content of the sw_voxel unit tests. It has no game names: the block
//! types have numbers, and the generator makes noise hills with holes,
//! floating slabs and emissive blocks. Only the test build imports it.
const std = @import("std");
const sw_voxel = @import("sw_voxel");

const chunk = sw_voxel.chunk;
const CHUNK_W = chunk.CHUNK_W;
const CHUNK_H = chunk.CHUNK_H;

pub const Block = enum(u8) {
    air = 0,
    solid = 1,
    emitter = 2,
    b3 = 3,
    b4 = 4,
    b5 = 5,
    b6 = 6,
    b7 = 7,
    b8 = 8,
};

/// Only `emitter` gives light.
pub fn emission(block: Block) u8 {
    return if (block == .emitter) chunk.MAX_BLOCK_LIGHT else 0;
}

pub const GenConfig = struct {
    seed: u64 = 0,
    /// The lowest surface height.
    base: i32 = 60,
    /// The surface height range above `base`.
    amplitude: i32 = 24,
};

pub const GEN_CONFIG_LEN = 8;

pub fn encodeGenConfig(config: GenConfig, out: *[GEN_CONFIG_LEN]u8) void {
    std.mem.writeInt(i32, out[0..4], config.base, .little);
    std.mem.writeInt(i32, out[4..8], config.amplitude, .little);
}

pub fn decodeGenConfig(bytes: *const [GEN_CONFIG_LEN]u8) error{BadField}!GenConfig {
    const base = std.mem.readInt(i32, bytes[0..4], .little);
    const amplitude = std.mem.readInt(i32, bytes[4..8], .little);
    if (base < 1 or amplitude < 0 or base + amplitude >= CHUNK_H - 16) return error.BadField;
    return .{ .base = base, .amplitude = amplitude };
}

fn hash(seed: u64, x: i32, y: i32, z: i32) u64 {
    var h = std.hash.Wyhash.init(seed);
    h.update(std.mem.asBytes(&[3]i32{ x, y, z }));
    return h.final();
}

/// Value noise on a grid of 8 columns, 0 to `amplitude`.
fn surface(config: GenConfig, wx: i32, wz: i32) i32 {
    const gx = @divFloor(wx, 8);
    const gz = @divFloor(wz, 8);
    const fx: f32 = @as(f32, @floatFromInt(wx - gx * 8)) / 8.0;
    const fz: f32 = @as(f32, @floatFromInt(wz - gz * 8)) / 8.0;
    const amp: u64 = @intCast(config.amplitude + 1);
    const c00: f32 = @floatFromInt(hash(config.seed, gx, 0, gz) % amp);
    const c10: f32 = @floatFromInt(hash(config.seed, gx + 1, 0, gz) % amp);
    const c01: f32 = @floatFromInt(hash(config.seed, gx, 0, gz + 1) % amp);
    const c11: f32 = @floatFromInt(hash(config.seed, gx + 1, 0, gz + 1) % amp);
    const top = c00 + (c10 - c00) * fx;
    const bottom = c01 + (c11 - c01) * fx;
    return config.base + @as(i32, @intFromFloat(top + (bottom - top) * fz));
}

pub fn generate(dense: *chunk.DenseBlocks, cx: i32, cz: i32, config: GenConfig) void {
    @memset(dense, .air);
    for (0..CHUNK_W) |ux| for (0..CHUNK_W) |uz| {
        const x: i32 = @intCast(ux);
        const z: i32 = @intCast(uz);
        const wx = cx * CHUNK_W + x;
        const wz = cz * CHUNK_W + z;
        const h = surface(config, wx, wz);
        var y: i32 = 0;
        while (y <= h) : (y += 1) {
            // Holes of 4×4×4 cells below the surface.
            const hole = y > 8 and y < h - 4 and
                hash(config.seed, @divFloor(wx, 4), @divFloor(y, 4), @divFloor(wz, 4)) % 6 == 0;
            if (hole) continue;
            const b: Block = if (y == h)
                .b3
            else if (hash(config.seed, wx, y, wz) % 211 == 0) .emitter else .solid;
            dense[chunk.blockLinearIdx(x, y, z)] = b;
        }
        // Floating slabs of 4×4 columns above the surface.
        if (hash(config.seed, @divFloor(wx, 4), -1, @divFloor(wz, 4)) % 5 == 0) {
            const sy = config.base + config.amplitude + 6;
            dense[chunk.blockLinearIdx(x, sy, z)] = .b4;
        }
    };
}
