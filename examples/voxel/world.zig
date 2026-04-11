const std = @import("std");
const chunk_mod = @import("chunk.zig");
const mesher_mod = @import("mesher.zig");
const world_gen = @import("world_gen.zig");
const Chunk = chunk_mod.Chunk;
const Mesh = mesher_mod.Mesh;

/// Render distance in chunks (circular radius).
/// TODO: expose as an in-game setting via the HUD.
pub const RENDER_DISTANCE: i32 = 4;

/// Terrain-generation passes per tick during normal gameplay.
///
/// Rationale for K=2: generation is cheap (value noise + a handful of block
/// writes per column, ~1ms/chunk on the bad laptop used for development) and
/// only runs when the player crosses a chunk boundary. Two per tick keeps the
/// async background fill invisible during casual wandering without spiking
/// the frame budget. The pregen phase (loading screen) uses an unbounded
/// budget — see `generateRing` in main.zig.
pub const CHUNKS_PER_TICK: usize = 2;

/// Horizontal pregen radius used by the first-spawn flow.
///
/// Rationale for N = 25 chunks (RADIUS = 2 → 5×5 horizontal ring at the spawn
/// chunk column):
///   - Horizontal movement dominates first-play UX. A player walking in any
///     direction from spawn should not immediately hit an unmeshed edge.
///   - `RENDER_DISTANCE = 4` is a circular cull radius, but only the inner
///     3×3 (9 chunks) need to be MESHED to have a clean view immediately —
///     those are the chunks whose four horizontal neighbours are all also
///     generated. The outer ring (16 chunks) acts as the "generated but not
///     yet meshed" buffer so the inner 9 CAN be meshed without seam holes.
///   - Vertical is free: chunks are 256-tall columns, not 16-tall sections.
///     We don't need a sphere.
///   - A 5×5 square = 25 columns × ~576 KB per chunk ≈ 14 MB RAM. Comfortable.
///     Moving to 7×7 (radius 3, 49 chunks) would push it to ~28 MB and slow
///     the loading screen; not worth it until we palette-compress chunks.
pub const PREGEN_RADIUS: i32 = 2;

/// A RegionAnchor requests that all chunks within RENDER_DISTANCE be loaded.
/// Currently only the player satisfies this. Future entities (beacons, spectators,
/// off-screen simulations) can provide anchors to extend the loaded region.
pub const RegionAnchor = struct {
    position: [3]f32,
};

/// Convert a world-space block coordinate to a chunk-grid coordinate.
pub fn chunkCoordOf(world_coord: i32) i32 {
    return @divFloor(world_coord, chunk_mod.CHUNK_W);
}

pub const ChunkKey = struct {
    cx: i32,
    cz: i32,

    pub const HashContext = struct {
        pub fn hash(_: HashContext, k: ChunkKey) u64 {
            var h = std.hash.Wyhash.init(0);
            h.update(std.mem.asBytes(&k.cx));
            h.update(std.mem.asBytes(&k.cz));
            return h.final();
        }
        pub fn eql(_: HashContext, a: ChunkKey, b: ChunkKey) bool {
            return a.cx == b.cx and a.cz == b.cz;
        }
    };
};

const ChunkOffset = struct { dx: i32, dz: i32 };

pub const ChunkMap = std.HashMap(ChunkKey, *LoadedChunk, ChunkKey.HashContext, std.hash_map.default_max_load_percentage);

/// Pipeline state for a loaded chunk. Generation (writing the block-ID array)
/// and meshing (building a GPU vertex/index buffer) are two distinct phases.
///
/// `.generated`  — `chunk.blocks` is valid in RAM. Deterministic from seed+coords.
///                 No GPU mesh yet. Cannot be meshed until all four horizontal
///                 neighbours are also at least `.generated` (otherwise face
///                 culling against .air for missing neighbours would punch holes
///                 along chunk seams — the classic "sky gap" artifact).
/// `.meshed`     — `mesh.vertices` / `mesh.indices` are valid. Ready to draw.
///
/// Chunks in this codebase are 48×256×48 *columns*, not 3D cubes, so there is
/// no vertical neighbour to wait on — a column is meshable as soon as its four
/// horizontal neighbours exist.
pub const ChunkState = enum(u8) {
    generated = 0,
    meshed = 1,
};

/// A single loaded chunk: terrain data + mesh + pipeline state.
pub const LoadedChunk = struct {
    chunk: Chunk,
    mesh: Mesh,
    cx: i32,
    cz: i32,
    /// Pipeline state — generated vs meshed. See `ChunkState` doc above.
    state: ChunkState,
    /// True when the mesh needs full regeneration — either because it has
    /// never been meshed yet, or because a neighbour arrived and the seam
    /// faces need re-evaluation. Only meaningful when `state == .meshed`
    /// except for the initial `true` that lives while `.generated`.
    mesh_dirty: bool,
    /// True when mesh was changed incrementally and GPU buffers need re-upload.
    mesh_incremental_dirty: bool,

    pub fn init(allocator: std.mem.Allocator, cx: i32, cz: i32) LoadedChunk {
        return .{
            .chunk = Chunk.init(),
            .mesh = Mesh.init(allocator),
            .cx = cx,
            .cz = cz,
            .state = .generated,
            .mesh_dirty = true,
            .mesh_incremental_dirty = false,
        };
    }

    pub fn deinit(self: *LoadedChunk) void {
        self.mesh.deinit();
    }

    /// World-space X origin of this chunk in block units.
    pub fn worldX(self: *const LoadedChunk) i32 {
        return self.cx * chunk_mod.CHUNK_W;
    }

    /// World-space Z origin of this chunk in block units.
    pub fn worldZ(self: *const LoadedChunk) i32 {
        return self.cz * chunk_mod.CHUNK_W;
    }

    /// World-space X origin as f32.
    pub fn worldXf(self: *const LoadedChunk) f32 {
        return @as(f32, @floatFromInt(self.worldX()));
    }

    /// World-space Z origin as f32.
    pub fn worldZf(self: *const LoadedChunk) f32 {
        return @as(f32, @floatFromInt(self.worldZ()));
    }
};

pub const World = struct {
    allocator: std.mem.Allocator,
    chunks: ChunkMap,
    /// Pre-computed (dx, dz) offsets sorted by distance from origin (innermost first).
    /// Built once at init; reused every tick.
    spiral_offsets: []ChunkOffset,
    /// World generation config. Determined at init from ACTIVE_PRESET; passed to
    /// every chunk's generateTerrain call. Override individual fields after init
    /// to tweak generation without changing the preset.
    gen_config: world_gen.WorldGenConfig,

    pub fn init(allocator: std.mem.Allocator, preset: world_gen.Preset) !World {
        return .{
            .allocator = allocator,
            .chunks = ChunkMap.init(allocator),
            .spiral_offsets = try buildSpiralOffsets(allocator, RENDER_DISTANCE),
            .gen_config = world_gen.presetConfig(preset),
        };
    }

    pub fn deinit(self: *World) void {
        var it = self.chunks.valueIterator();
        while (it.next()) |lc_ptr| {
            lc_ptr.*.deinit();
            self.allocator.destroy(lc_ptr.*);
        }
        self.chunks.deinit();
        self.allocator.free(self.spiral_offsets);
    }

    /// Generate one chunk at (cx, cz) if it does not already exist, and mark
    /// any existing horizontal neighbours as `mesh_dirty` so their seam faces
    /// will be re-evaluated against the new chunk.
    ///
    /// Returns true if a new chunk was created, false if the slot was already
    /// occupied. Cheap to call repeatedly with the same coords.
    pub fn generateChunk(self: *World, cx: i32, cz: i32) !bool {
        const key = ChunkKey{ .cx = cx, .cz = cz };
        if (self.chunks.contains(key)) return false;

        const lc = try self.allocator.create(LoadedChunk);
        lc.* = LoadedChunk.init(self.allocator, cx, cz);
        lc.chunk.generateTerrain(cx, cz, self.gen_config);
        try self.chunks.put(key, lc);

        // Mark adjacent already-loaded chunks dirty so their seam faces will
        // be re-evaluated against this new neighbour on the next mesh pass.
        const adjacent = [_]ChunkKey{
            .{ .cx = cx - 1, .cz = cz },
            .{ .cx = cx + 1, .cz = cz },
            .{ .cx = cx, .cz = cz - 1 },
            .{ .cx = cx, .cz = cz + 1 },
        };
        for (adjacent) |nk| {
            if (self.chunks.get(nk)) |nlc| {
                nlc.mesh_dirty = true;
            }
        }
        return true;
    }

    /// True iff `lc` has all four horizontal neighbours generated (or better).
    /// Since chunks here are full-height columns, "all six neighbours" from
    /// classic 3D-chunk voxel engines collapses to four horizontal neighbours.
    /// A chunk must meet this condition before its mesh is built — otherwise
    /// seam faces would cull against `.air` for the missing sides and produce
    /// visible holes along chunk boundaries.
    pub fn hasAllNeighborsGenerated(self: *const World, cx: i32, cz: i32) bool {
        const neighbors = [_]ChunkKey{
            .{ .cx = cx - 1, .cz = cz },
            .{ .cx = cx + 1, .cz = cz },
            .{ .cx = cx, .cz = cz - 1 },
            .{ .cx = cx, .cz = cz + 1 },
        };
        for (neighbors) |nk| {
            if (!self.chunks.contains(nk)) return false;
        }
        return true;
    }

    /// Update chunk loading for the given anchors.
    /// Generates up to CHUNKS_PER_TICK new chunks per call, innermost-first.
    /// Call this from voxelTick once per tick during normal gameplay.
    ///
    /// Meshing is handled separately by the caller — see main.zig's per-tick
    /// mesh loop. The split keeps generation (cheap, deterministic, no GPU
    /// state) completely decoupled from meshing (must wait for neighbours,
    /// produces GPU buffers).
    pub fn update(self: *World, anchors: []const RegionAnchor) !void {
        var loaded_this_tick: usize = 0;

        outer: for (self.spiral_offsets) |off| {
            if (loaded_this_tick >= CHUNKS_PER_TICK) break;

            for (anchors) |anchor| {
                if (loaded_this_tick >= CHUNKS_PER_TICK) break :outer;

                const anchor_cx = chunkCoordOf(@as(i32, @intFromFloat(@floor(anchor.position[0]))));
                const anchor_cz = chunkCoordOf(@as(i32, @intFromFloat(@floor(anchor.position[2]))));
                if (try self.generateChunk(anchor_cx + off.dx, anchor_cz + off.dz)) {
                    loaded_this_tick += 1;
                }
            }
        }
    }

    /// Get a block at world-space coordinates. Returns .air for unloaded chunks.
    pub fn getBlock(self: *const World, wx: i32, wy: i32, wz: i32) chunk_mod.BlockType {
        const cx = chunkCoordOf(wx);
        const cz = chunkCoordOf(wz);
        const lc = self.chunks.get(.{ .cx = cx, .cz = cz }) orelse return .air;
        const lx = wx - cx * chunk_mod.CHUNK_W;
        const lz = wz - cz * chunk_mod.CHUNK_W;
        return lc.chunk.getBlock(lx, wy, lz);
    }

    /// Set a block at world-space coordinates. Returns false if the chunk is unloaded.
    pub fn setBlock(self: *World, wx: i32, wy: i32, wz: i32, block: chunk_mod.BlockType) bool {
        const cx = chunkCoordOf(wx);
        const cz = chunkCoordOf(wz);
        const lc_ptr = self.chunks.getPtr(.{ .cx = cx, .cz = cz }) orelse return false;
        const lx = wx - cx * chunk_mod.CHUNK_W;
        const lz = wz - cz * chunk_mod.CHUNK_W;
        lc_ptr.*.chunk.setBlock(lx, wy, lz, block);
        return true;
    }

    /// Get the LoadedChunk containing the given world block coordinate.
    pub fn getChunkAtBlock(self: *World, wx: i32, wz: i32) ?*LoadedChunk {
        return self.chunks.get(.{ .cx = chunkCoordOf(wx), .cz = chunkCoordOf(wz) });
    }

    /// Get the skylight at world-space coordinates. Returns MAX_SKYLIGHT for
    /// any cell above the world top (so faces under the open sky stay bright)
    /// and 0 for unloaded chunks (treats the unknown as fully shadowed —
    /// strictly an artifact at the loaded-region boundary, not visible during
    /// normal play because the loading ring extends well past the camera).
    pub fn getSkylight(self: *const World, wx: i32, wy: i32, wz: i32) u8 {
        if (wy >= chunk_mod.CHUNK_H) return chunk_mod.MAX_SKYLIGHT;
        const cx = chunkCoordOf(wx);
        const cz = chunkCoordOf(wz);
        const lc = self.chunks.get(.{ .cx = cx, .cz = cz }) orelse return 0;
        const lx = wx - cx * chunk_mod.CHUNK_W;
        const lz = wz - cz * chunk_mod.CHUNK_W;
        return lc.chunk.getSkylight(lx, wy, lz);
    }

    /// Returns a BlockGetter backed by this World (queries world coords).
    /// Implements both `getBlock` (for solidity / face culling / physics) and
    /// `getSkylight` (for the mesher's per-vertex skylight sampling).
    pub fn asBlockGetter(self: *const World) chunk_mod.BlockGetter {
        return .{
            .ctx = self,
            .getFn = struct {
                fn get(ctx: *const anyopaque, x: i32, y: i32, z: i32) chunk_mod.BlockType {
                    return @as(*const World, @ptrCast(@alignCast(ctx))).getBlock(x, y, z);
                }
            }.get,
            .getSkylightFn = struct {
                fn getSky(ctx: *const anyopaque, x: i32, y: i32, z: i32) u8 {
                    return @as(*const World, @ptrCast(@alignCast(ctx))).getSkylight(x, y, z);
                }
            }.getSky,
        };
    }
};

fn buildSpiralOffsets(allocator: std.mem.Allocator, r: i32) ![]ChunkOffset {
    var offsets = std.ArrayList(ChunkOffset){};
    defer offsets.deinit(allocator);

    var dz: i32 = -r;
    while (dz <= r) : (dz += 1) {
        var dx: i32 = -r;
        while (dx <= r) : (dx += 1) {
            if (dx * dx + dz * dz <= r * r) {
                try offsets.append(allocator, .{ .dx = dx, .dz = dz });
            }
        }
    }

    std.mem.sort(ChunkOffset, offsets.items, {}, struct {
        fn lt(_: void, a: ChunkOffset, b: ChunkOffset) bool {
            return (a.dx * a.dx + a.dz * a.dz) < (b.dx * b.dx + b.dz * b.dz);
        }
    }.lt);

    return offsets.toOwnedSlice(allocator);
}
