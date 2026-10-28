//! The content of the sw_voxel unit tests. It has no game names: the block
//! types have numbers, and the generator makes noise hills with holes,
//! floating slabs and emissive blocks. Only the test build imports it.
//!
//! The build runs the unit tests two times, with two world heights from the
//! module `sw_voxel_test_dims`: the default (y 0 to 255), and a tall world
//! (y -64 to 319). The generator works in local y, so both worlds have the
//! same terrain above local y 0.
const std = @import("std");
const sw_voxel = @import("sw_voxel");
const dims = @import("sw_voxel_test_dims");

pub const min_y: i32 = dims.min_y;
pub const height: u32 = dims.height;

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
    // More numbered blocks, so that a section palette can need 8 bits.
    b9 = 9,
    b10 = 10,
    b11 = 11,
    b12 = 12,
    b13 = 13,
    b14 = 14,
    b15 = 15,
    b16 = 16,
    b17 = 17,
    b18 = 18,
    b19 = 19,
    b20 = 20,
    // Fluids (REQ-VOXEL-014): b21 to b23 are fluid 1 at the levels 8, 4
    // and 1. b24 is fluid 2, full.
    b21 = 21,
    b22 = 22,
    b23 = 23,
    b24 = 24,
    // b25 is translucent (REQ-VOXEL-029).
    b25 = 25,
};

/// b25 is translucent red at alpha 128 (REQ-VOXEL-029). The generator
/// does not place it.
pub fn translucent(block: Block) ?[4]u8 {
    return switch (block) {
        .b25 => .{ 255, 0, 0, 128 },
        else => null,
    };
}

/// The fluids b21 to b24. The generator does not place them.
pub fn fluid(block: Block) ?sw_voxel.fluid.Level {
    return switch (block) {
        .b21 => .{ .fluid = 1, .level = 8 },
        .b22 => .{ .fluid = 1, .level = 4 },
        .b23 => .{ .fluid = 1, .level = 1 },
        .b24 => .{ .fluid = 2, .level = 8 },
        else => null,
    };
}

const model_mod = sw_voxel.model;

/// b19: a half block, a box from y 0 to y 0.5 with its top inside the cell.
const half_quads = model_mod.box(.{ 0, 0, 0 }, .{ 1, 0.5, 1 }, @splat(model_mod.BoxFace{}));
/// b20: one plane through the middle of the cell, with a quad on each side
/// and no cull face. The light comes from above.
const plane_quads = [2]model_mod.BakedQuad{
    .{ .pos = .{ .{ 0, 0, 0.5 }, .{ 1, 0, 0.5 }, .{ 1, 1, 0.5 }, .{ 0, 1, 0.5 } }, .uv = .{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } }, .face = .py, .tint_index = 0, .shade = false },
    .{ .pos = .{ .{ 1, 0, 0.5 }, .{ 0, 0, 0.5 }, .{ 0, 1, 0.5 }, .{ 1, 1, 0.5 } }, .uv = .{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } }, .face = .py, .tint_index = 0, .shade = false },
};
const half_model: model_mod.BakedModel = .{ .quads = &half_quads };
const plane_model: model_mod.BakedModel = .{ .quads = &plane_quads };

/// b19 and b20 have models. The generator does not place them, so the
/// terrain is full cubes only.
pub fn model(block: Block) ?*const model_mod.BakedModel {
    return switch (block) {
        .b19 => &half_model,
        .b20 => &plane_model,
        else => null,
    };
}

const CellBox = sw_voxel.collision.CellBox;
/// b16: two boxes, like a stair: the bottom half and the top of the -x half.
const stair_boxes = [2]CellBox{
    .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 0.5, 1 } },
    .{ .min = .{ 0, 0.5, 0 }, .max = .{ 0.5, 1, 1 } },
};
/// b18: a thin post in the middle of the cell.
const post_boxes = [1]CellBox{.{ .min = .{ 0.375, 0, 0.375 }, .max = .{ 0.625, 1, 0.625 } }};
/// b19: the box of the half block.
const half_boxes = [1]CellBox{.{ .min = .{ 0, 0, 0 }, .max = .{ 1, 0.5, 1 } }};

/// The collision boxes of the blocks with no full cube: b16, b18, b19 and
/// b20 (no box). All other blocks use the default. The generator does not
/// place these blocks.
pub fn collision(block: Block) ?[]const CellBox {
    return switch (block) {
        .b16 => &stair_boxes,
        .b18 => &post_boxes,
        .b19 => &half_boxes,
        .b20, .b21, .b22, .b23, .b24 => &.{},
        else => null,
    };
}

/// The tint colours of the tests (REQ-VOXEL-009). The generator places
/// none of b5, b6 and b20, so the terrain has no tint.
///   b5: a colour for each cell (x, z), so a chunk layer has 256 colours.
///   b6: one colour.
///   b20: a colour from the tint index and y.
pub fn tint(block: Block, tint_index: u8, x: i32, y: i32, z: i32) [3]u8 {
    return switch (block) {
        .b5 => .{ @intCast(@mod(x, 16) * 16), @intCast(@mod(z, 16) * 16), 200 },
        .b6 => .{ 40, 180, 60 },
        else => .{ tint_index *% 50, @intCast(@mod(y, 256)), 7 },
    };
}

/// The top face of b5 and each face of b6 have tint index 0.
pub fn tintIndex(block: Block, face: model_mod.Face) i8 {
    return switch (block) {
        .b5 => if (face == .py) 0 else -1,
        .b6 => 0,
        else => -1,
    };
}

/// `emitter` gives full light. b18 gives less light, and lets light
/// through. The generator does not place b18.
pub fn emission(block: Block) u8 {
    return switch (block) {
        .emitter => chunk.MAX_BLOCK_LIGHT,
        .b18 => 9,
        else => 0,
    };
}

/// The model blocks (b19, b20) and b18 let light through. b17 is a full
/// cube that stops a part of the light. All other blocks stop all light.
/// The generator places none of b17 to b20, so the terrain light is the
/// light of full cubes.
pub fn opacity(block: Block) u8 {
    return switch (block) {
        .air, .b18, .b19, .b20, .b25 => 0,
        .b21, .b22, .b23, .b24 => 2,
        .b17 => 3,
        else => 15,
    };
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
