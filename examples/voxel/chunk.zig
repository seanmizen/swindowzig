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

/// Maximum skylight level. Matches Minecraft's 4-bit (0..15) range — we store
/// it in a u8 right now because the engine doesn't yet care about packing
/// multiple light channels. See `examples/voxel/docs/lighting.md` for the
/// full reasoning.
pub const MAX_SKYLIGHT: u8 = 15;

pub const Chunk = struct {
    blocks: [CHUNK_W][CHUNK_H][CHUNK_W]BlockType,
    /// Per-block skylight value, range [0, MAX_SKYLIGHT]. Computed by
    /// `computeSkylight()` after `generateTerrain()`. Solid blocks always
    /// store 0. Air blocks store the brightness of sunlight that reaches them
    /// after BFS propagation through air. Phase 1: per-chunk only — light
    /// does not cross chunk boundaries, so wide horizontal caves spanning
    /// two chunks will show a brightness seam at the join.
    skylight: [CHUNK_W][CHUNK_H][CHUNK_W]u8,

    pub fn init() Chunk {
        return .{
            .blocks = [_][CHUNK_H][CHUNK_W]BlockType{
                [_][CHUNK_W]BlockType{
                    [_]BlockType{.air} ** CHUNK_W,
                } ** CHUNK_H,
            } ** CHUNK_W,
            .skylight = [_][CHUNK_H][CHUNK_W]u8{
                [_][CHUNK_W]u8{
                    [_]u8{0} ** CHUNK_W,
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

    /// Read the skylight at (x, y, z) using local chunk coordinates.
    /// Returns MAX_SKYLIGHT for any coordinate above the chunk top (so faces
    /// looking at the open sky stay bright) and 0 elsewhere out of bounds.
    /// The "bright above, dark elsewhere" asymmetry is what makes faces at
    /// the top of the world look right without a heightmap.
    pub fn getSkylight(self: *const Chunk, x: i32, y: i32, z: i32) u8 {
        if (y >= CHUNK_H) return MAX_SKYLIGHT; // above world top = open sky
        if (x < 0 or x >= CHUNK_W or y < 0 or z < 0 or z >= CHUNK_W) return 0;
        return self.skylight[@intCast(x)][@intCast(y)][@intCast(z)];
    }

    /// Recompute skylight for the entire chunk from the current `blocks` array.
    /// Two-pass algorithm:
    ///
    ///   Pass 1 (column seed):
    ///     For each (x, z) column, walk downward from y=CHUNK_H-1. Every air
    ///     block sets skylight = MAX_SKYLIGHT until the first solid block.
    ///     Below that solid, every air block starts at skylight = 0.
    ///     Solid blocks always store 0.
    ///
    ///   Pass 2 (bucket-sort BFS, levels MAX_SKYLIGHT down to 2):
    ///     For each level L from MAX_SKYLIGHT down to 2, sweep the chunk and
    ///     for each air cell with skylight == L, propagate (L - 1) into any
    ///     air neighbour with a strictly lower current skylight. This is
    ///     equivalent to a level-bucketed BFS but needs no queue allocation:
    ///     each cell is visited at most once per level transition because the
    ///     check `current < L - 1` short-circuits stale propagation.
    ///
    /// O(MAX_SKYLIGHT × N) where N = CHUNK_W² × CHUNK_H. For our 48×256×48
    /// chunks that's ~9M neighbour checks per chunk — single-digit
    /// milliseconds on a modern desktop, run once per chunk at generate time.
    /// Allocator-free by design so it can be called from `generateTerrain`
    /// without changing the existing call sites.
    pub fn computeSkylight(self: *Chunk) void {
        // Pass 1 — top-down column seed.
        var x: i32 = 0;
        while (x < CHUNK_W) : (x += 1) {
            var z: i32 = 0;
            while (z < CHUNK_W) : (z += 1) {
                var seen_solid = false;
                var y: i32 = CHUNK_H - 1;
                while (y >= 0) : (y -= 1) {
                    const xu: usize = @intCast(x);
                    const yu: usize = @intCast(y);
                    const zu: usize = @intCast(z);
                    if (self.blocks[xu][yu][zu] != .air) {
                        seen_solid = true;
                        self.skylight[xu][yu][zu] = 0;
                    } else if (!seen_solid) {
                        self.skylight[xu][yu][zu] = MAX_SKYLIGHT;
                    } else {
                        self.skylight[xu][yu][zu] = 0;
                    }
                }
            }
        }

        // Pass 2 — bucket-sort BFS, level MAX_SKYLIGHT down to 2.
        // Cells at level 1 have nothing to give (1 - 1 = 0), so we can stop
        // before that pass. Iteration order is x → y → z so the innermost
        // loop is stride-1 in the [x][y][z] array — keeps cache lines hot.
        var level: u8 = MAX_SKYLIGHT;
        while (level >= 2) : (level -= 1) {
            const target: u8 = level - 1;
            var ix: i32 = 0;
            while (ix < CHUNK_W) : (ix += 1) {
                var iy: i32 = 0;
                while (iy < CHUNK_H) : (iy += 1) {
                    var iz: i32 = 0;
                    while (iz < CHUNK_W) : (iz += 1) {
                        const xu: usize = @intCast(ix);
                        const yu: usize = @intCast(iy);
                        const zu: usize = @intCast(iz);
                        if (self.skylight[xu][yu][zu] != level) continue;
                        // Six axis-aligned neighbours.
                        const neighbours = [_][3]i32{
                            .{ ix + 1, iy, iz },
                            .{ ix - 1, iy, iz },
                            .{ ix, iy + 1, iz },
                            .{ ix, iy - 1, iz },
                            .{ ix, iy, iz + 1 },
                            .{ ix, iy, iz - 1 },
                        };
                        for (neighbours) |n| {
                            const nx = n[0];
                            const ny = n[1];
                            const nz = n[2];
                            if (nx < 0 or nx >= CHUNK_W or ny < 0 or ny >= CHUNK_H or nz < 0 or nz >= CHUNK_W) continue;
                            const nxu: usize = @intCast(nx);
                            const nyu: usize = @intCast(ny);
                            const nzu: usize = @intCast(nz);
                            if (self.blocks[nxu][nyu][nzu] != .air) continue;
                            if (self.skylight[nxu][nyu][nzu] >= target) continue;
                            self.skylight[nxu][nyu][nzu] = target;
                        }
                    }
                }
            }
        }
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

        // Skylight: must run after the blocks array is fully populated, since
        // the BFS reads `blocks` to know which cells block propagation.
        self.computeSkylight();
    }
};

/// Type-erased block source. Allows player physics, raycasting, and the
/// mesher to work with either a single Chunk (local coords) or a World
/// (world coords). The mesher additionally uses `getSkylight` to look up
/// per-block sky values across chunk boundaries — without it, faces on a
/// chunk's edge would sample OOB and have to fall back to a default,
/// producing visible bright/dark seams.
pub const BlockGetter = struct {
    ctx: *const anyopaque,
    getFn: *const fn (ctx: *const anyopaque, x: i32, y: i32, z: i32) BlockType,
    getSkylightFn: *const fn (ctx: *const anyopaque, x: i32, y: i32, z: i32) u8,

    pub fn getBlock(self: BlockGetter, x: i32, y: i32, z: i32) BlockType {
        return self.getFn(self.ctx, x, y, z);
    }

    pub fn getSkylight(self: BlockGetter, x: i32, y: i32, z: i32) u8 {
        return self.getSkylightFn(self.ctx, x, y, z);
    }
};
