//! The content of the voxel demo for sw_voxel: the block types, the light
//! that each block gives, and the terrain generator. sw_voxel imports this
//! file as the `sw_voxel_content` module. `libs/sw_voxel/src/content.zig`
//! gives the contract.
const std = @import("std");
const sw_voxel = @import("sw_voxel");
pub const world_gen = @import("world_gen.zig");

const chunk = sw_voxel.chunk;
const CHUNK_W = chunk.CHUNK_W;
const CHUNK_H = chunk.CHUNK_H;
const DenseBlocks = chunk.DenseBlocks;
const blockLinearIdx = chunk.blockLinearIdx;

/// The world height of the demo: y 0 to 255, 16 sections of 16 cells.
pub const min_y: i32 = 0;
pub const height: u32 = 256;

/// The block types of the demo. The value is the block id in the chunk
/// storage, in the protocol and in the packed quads. voxel.wgsl gives each
/// id its colour.
pub const Block = enum(u8) {
    air = 0,
    grass = 1,
    dirt = 2,
    stone = 3,
    bedrock = 4,
    /// Minecraft-style glowstone: solid (blocks propagation, culls faces) but
    /// emits `MAX_BLOCK_LIGHT` from its own cell. Seeded during
    /// `computeBlockLight` and propagated outward through adjacent air.
    glowstone = 5,
    /// Oak log / tree trunk. Brown block placed during tree generation.
    /// Solid and opaque — no special light properties.
    wood = 6,
    /// Oak leaf block. Dark green, placed in the spherical canopy around tree tops.
    /// Solid for face-culling purposes (keeps mesh generation simple).
    leaves = 7,
    /// Sand block. Used as the surface layer in desert biomes.
    /// No special physics (falling sand is out of scope for terrain generation).
    sand = 8,
    /// A half block: the lower half of the cell. It has a baked model
    /// (`model`), so the model mesher meshes it. Hotbar slot 5 places it.
    slab = 9,
    debug_marker = 99,
};
const BlockType = Block;

/// The block light that `block` gives. Only glowstone gives light.
pub fn emission(block: Block) u8 {
    return switch (block) {
        .glowstone => chunk.MAX_BLOCK_LIGHT,
        else => 0,
    };
}

const model_mod = sw_voxel.model;

/// The quads of the half block: a box from y 0 to y 0.5. The top is inside
/// the cell, so it has no cull face. The texture coordinates are in block
/// units, as on a greedy face, so the shader gives the half block the same
/// texel grid as a full block.
const slab_quads = model_mod.box(.{ 0, 0, 0 }, .{ 1, 0.5, 1 }, @splat(model_mod.BoxFace{}));
const slab_model: model_mod.BakedModel = .{ .quads = &slab_quads };

/// The baked model of `block`, or null for a full cube. Only the half block
/// has a model.
pub fn model(block: Block) ?*const model_mod.BakedModel {
    return switch (block) {
        .slab => &slab_model,
        else => null,
    };
}

/// The settings of the terrain generator. `seed` is the world seed.
pub const GenConfig = world_gen.WorldGenConfig;

/// The length of a `GenConfig` in the Hello message, without the seed.
///
///   0  u8   preset
///   1  u8×3 reserved, 0
///   4  i32  sea level
///   8  i32  terrain height min
///   12 i32  terrain height max
///   16 f32  noise scale
///   20 u32  noise octaves
///   24 f32  noise persistence
///   28 f32  noise lacunarity
pub const GEN_CONFIG_LEN = 32;

/// Write `config`, without the seed, into `out`. Little-endian.
pub fn encodeGenConfig(config: GenConfig, out: *[GEN_CONFIG_LEN]u8) void {
    out[0] = @backingInt(config.preset);
    @memset(out[1..4], 0);
    std.mem.writeInt(i32, out[4..8], config.sea_level, .little);
    std.mem.writeInt(i32, out[8..12], config.terrain_height_min, .little);
    std.mem.writeInt(i32, out[12..16], config.terrain_height_max, .little);
    std.mem.writeInt(u32, out[16..20], @bitCast(config.noise_scale), .little);
    std.mem.writeInt(u32, out[20..24], config.noise_octaves, .little);
    std.mem.writeInt(u32, out[24..28], @bitCast(config.noise_persistence), .little);
    std.mem.writeInt(u32, out[28..32], @bitCast(config.noise_lacunarity), .little);
}

/// Read a `GenConfig` that `encodeGenConfig` wrote. The seed is 0: the
/// Hello message holds it.
pub fn decodeGenConfig(bytes: *const [GEN_CONFIG_LEN]u8) error{BadField}!GenConfig {
    const preset = std.enums.fromInt(world_gen.Preset, bytes[0]) orelse return error.BadField;
    for (bytes[1..4]) |b| if (b != 0) return error.BadField;
    return .{
        .preset = preset,
        .sea_level = std.mem.readInt(i32, bytes[4..8], .little),
        .terrain_height_min = std.mem.readInt(i32, bytes[8..12], .little),
        .terrain_height_max = std.mem.readInt(i32, bytes[12..16], .little),
        .noise_scale = @bitCast(std.mem.readInt(u32, bytes[16..20], .little)),
        .noise_octaves = std.mem.readInt(u32, bytes[20..24], .little),
        .noise_persistence = @bitCast(std.mem.readInt(u32, bytes[24..28], .little)),
        .noise_lacunarity = @bitCast(std.mem.readInt(u32, bytes[28..32], .little)),
    };
}

/// The blocks of chunk (cx, cz). sw_voxel calls this in the generate stage
/// and in `Chunk.generateTerrain`.
pub fn generate(dense: *DenseBlocks, cx: i32, cz: i32, config: GenConfig) void {
    fillTerrain(dense, cx, cz, config);
}

/// Write `block` at (x, y, z) in `dense`. Out-of-chunk coordinates are
/// ignored, as in `Chunk.setBlock`.
inline fn putDense(dense: *DenseBlocks, x: i32, y: i32, z: i32, block: BlockType) void {
    if (x < 0 or x >= CHUNK_W or y < 0 or y >= CHUNK_H or z < 0 or z >= CHUNK_W) return;
    dense[blockLinearIdx(x, y, z)] = block;
}

/// Read (x, y, z) from `dense`. Out-of-chunk coordinates read as `.air`,
/// as in `Chunk.getBlock`.
inline fn getDense(dense: *const DenseBlocks, x: i32, y: i32, z: i32) BlockType {
    if (x < 0 or x >= CHUNK_W or y < 0 or y >= CHUNK_H or z < 0 or z >= CHUNK_W) return .air;
    return dense[blockLinearIdx(x, y, z)];
}

/// How far the tree pass searches past each chunk edge for tree centres:
/// the maximum trunk height plus the canopy radius.
const TREE_SEARCH: i32 = 11;

/// The surface height and dominant biome of each column of a chunk and of
/// the tree search margin around it, as a heightmap. It samples a column on
/// the first `get` only. Generation reads each column of the chunk in the
/// fill pass and again in the cave pass, and a tree centre in the margin
/// in the tree pass. Before this cache, each read sampled the column again.
const ColumnCache = struct {
    const SIDE = CHUNK_W + 2 * TREE_SEARCH;

    cx: i32,
    cz: i32,
    config: world_gen.WorldGenConfig,
    known: [SIDE][SIDE]bool = @splat(@splat(false)),
    samples: [SIDE][SIDE]world_gen.ColumnSample = undefined,

    /// The sample of world column (wx, wz). The column must be in the chunk
    /// or in the tree search margin.
    fn get(self: *ColumnCache, wx: i32, wz: i32) world_gen.ColumnSample {
        const i: usize = @intCast(wx - (self.cx * CHUNK_W - TREE_SEARCH));
        const k: usize = @intCast(wz - (self.cz * CHUNK_W - TREE_SEARCH));
        if (!self.known[i][k]) {
            self.samples[i][k] = world_gen.sampleColumn(wx, wz, self.config);
            self.known[i][k] = true;
        }
        return self.samples[i][k];
    }
};

/// Write the blocks of chunk (cx, cz) into `dense`: the terrain fill, the
/// glowstone, the caves and the trees. No light. The result depends only on
/// the arguments (P2), so the `generate` stage of sw_voxel and
/// `Chunk.generateTerrain` give the same blocks.
fn fillTerrain(dense: *DenseBlocks, cx: i32, cz: i32, config: world_gen.WorldGenConfig) void {
    // The world seed, mixed for the hash functions. Seed 0 keeps the old terrain.
    const key = config.seedKey();
    @memset(dense, .air);
    var columns: ColumnCache = .{ .cx = cx, .cz = cz, .config = config };

    var x: i32 = 0;
    while (x < CHUNK_W) : (x += 1) {
        var z: i32 = 0;
        while (z < CHUNK_W) : (z += 1) {
            const wx = cx * CHUNK_W + x;
            const wz = cz * CHUNK_W + z;

            // For hilly terrain, use biome-blended height; flatland is always flat.
            // The dominant biome selects the surface block. Flatland
            // (noise_octaves == 0) is always plains, grass-only.
            const column = columns.get(wx, wz);
            const surface = column.height;
            const biome = column.biome;

            putDense(dense, x, 0, z, .bedrock);

            switch (biome) {
                .plains, .forest => {
                    // Standard Minecraft layout: stone, 3× dirt, grass cap.
                    var y: i32 = 1;
                    while (y < surface - 3) : (y += 1) {
                        putDense(dense, x, y, z, .stone);
                    }
                    y = @max(1, surface - 3);
                    while (y < surface) : (y += 1) {
                        putDense(dense, x, y, z, .dirt);
                    }
                    if (surface >= 1 and surface < CHUNK_H) {
                        putDense(dense, x, surface, z, .grass);
                    }
                },
                .badlands => {
                    // Badlands: stone exposed all the way to the top — no dirt, no grass.
                    // This gives the rocky/eroded mesa look.
                    var y: i32 = 1;
                    while (y <= surface and y < CHUNK_H) : (y += 1) {
                        putDense(dense, x, y, z, .stone);
                    }
                },
                .desert => {
                    // Desert: stone base, 3 layers of sand below the surface, sand cap.
                    var y: i32 = 1;
                    while (y < surface - 3) : (y += 1) {
                        putDense(dense, x, y, z, .stone);
                    }
                    y = @max(1, surface - 3);
                    while (y <= surface and y < CHUNK_H) : (y += 1) {
                        putDense(dense, x, y, z, .sand);
                    }
                },
            }

            // Scatter glowstone in the stone layer below Y=40 with
            // ~0.2% probability per block. Uses a splitmix-style hash
            // seeded from (wx, wz, y) for deterministic placement.
            const glow_ceil: i32 = @min(40, surface - 4);
            var gy: i32 = 2; // skip bedrock at Y=0, start above
            while (gy < glow_ceil) : (gy += 1) {
                const seed = @as(u32, @bitCast(wx)) *% 374761393 +%
                    @as(u32, @bitCast(wz)) *% 668265263 +%
                    @as(u32, @bitCast(gy)) *% 2654435761;
                const h = world_gen.mixSeed((seed ^ (seed >> 16)) *% 0x45d9f3b, key);
                if ((h & 0x1FF) == 0) { // ~1/512 chance
                    putDense(dense, x, gy, z, .glowstone);
                }
            }
        }
    }

    // Cave carver: run after terrain fill so we only carve into solid blocks.
    // Only active for non-flat terrain (noise_octaves > 0).
    if (config.noise_octaves > 0) {
        var cx_idx: i32 = 0;
        while (cx_idx < CHUNK_W) : (cx_idx += 1) {
            var cz_idx: i32 = 0;
            while (cz_idx < CHUNK_W) : (cz_idx += 1) {
                const wx = cx * CHUNK_W + cx_idx;
                const wz = cz * CHUNK_W + cz_idx;
                const surface = columns.get(wx, wz).height;
                // Carve from Y=4 (above bedrock zone) to surface-5 (preserve topsoil).
                var wy: i32 = 4;
                while (wy < surface - 4) : (wy += 1) {
                    if (world_gen.shouldCarve(wx, wy, wz, key)) {
                        putDense(dense, cx_idx, wy, cz_idx, .air);
                    }
                }
            }
        }
    }

    // Tree planter: place oak trees seeded from world coordinates.
    // Searches a halo around the chunk so canopy from trees in adjacent
    // chunks is correctly placed here as well.
    // Only active for non-flat terrain AND only in forest biome columns.
    if (config.noise_octaves > 0) {
        var tree_wx: i32 = cx * CHUNK_W - TREE_SEARCH;
        while (tree_wx < cx * CHUNK_W + CHUNK_W + TREE_SEARCH) : (tree_wx += 1) {
            var tree_wz: i32 = cz * CHUNK_W - TREE_SEARCH;
            while (tree_wz < cz * CHUNK_W + CHUNK_W + TREE_SEARCH) : (tree_wz += 1) {
                if (!world_gen.isTreeCenter(tree_wx, tree_wz, key)) continue;

                // Trees only spawn in forest biome — check the dominant biome
                // at the tree's root column before placing it.
                const tree_column = columns.get(tree_wx, tree_wz);
                if (tree_column.biome != .forest) continue;

                const tree_surface = tree_column.height;
                const trunk_h = world_gen.treeHeight(tree_wx, tree_wz, key);
                const trunk_base = tree_surface + 1;
                const trunk_top = tree_surface + trunk_h;

                // Place trunk — putDense ignores out-of-chunk coords silently.
                var ty: i32 = trunk_base;
                while (ty <= trunk_top) : (ty += 1) {
                    const lx = tree_wx - cx * CHUNK_W;
                    const lz = tree_wz - cz * CHUNK_W;
                    if (getDense(dense, lx, ty, lz) == .air) {
                        putDense(dense, lx, ty, lz, .wood);
                    }
                }

                // Place spherical leaf canopy (radius ~3) around trunk top.
                const CANOPY_R: i32 = 3;
                var dy: i32 = -CANOPY_R;
                while (dy <= CANOPY_R) : (dy += 1) {
                    var dx: i32 = -CANOPY_R;
                    while (dx <= CANOPY_R) : (dx += 1) {
                        var dz: i32 = -CANOPY_R;
                        while (dz <= CANOPY_R) : (dz += 1) {
                            if (dx * dx + dy * dy + dz * dz > CANOPY_R * CANOPY_R) continue;
                            // Don't overwrite trunk column blocks.
                            if (dx == 0 and dz == 0 and dy <= 0) continue;
                            const lx = tree_wx + dx - cx * CHUNK_W;
                            const ly = trunk_top + dy;
                            const lz = tree_wz + dz - cz * CHUNK_W;
                            if (ly < 1 or ly >= CHUNK_H) continue;
                            if (getDense(dense, lx, ly, lz) == .air) {
                                putDense(dense, lx, ly, lz, .leaves);
                            }
                        }
                    }
                }
            }
        }
    }
}

test "a GenConfig round trip keeps each field but the seed" {
    for ([_]world_gen.Preset{ .flatland, .hilly }) |preset| {
        var c = world_gen.presetConfig(preset);
        c.seed = 99;
        var bytes: [GEN_CONFIG_LEN]u8 = undefined;
        encodeGenConfig(c, &bytes);
        var got = try decodeGenConfig(&bytes);
        try std.testing.expectEqual(@as(u64, 0), got.seed);
        got.seed = c.seed;
        try std.testing.expectEqual(c, got);
        bytes[0] = 200;
        try std.testing.expectError(error.BadField, decodeGenConfig(&bytes));
    }
}

test {
    // Run the world_gen tests (the ring offset table).
    _ = world_gen;
}
