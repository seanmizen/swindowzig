const std = @import("std");
const chunk_mod = @import("chunk.zig");
const mesher_mod = @import("mesher.zig");
const world_gen = @import("world_gen.zig");
const Chunk = chunk_mod.Chunk;
const Mesh = mesher_mod.Mesh;

/// Render distance in chunks (circular radius).
/// TODO: expose as an in-game setting via the HUD.
pub const RENDER_DISTANCE: i32 = 4;

/// Terrain-generation passes per tick. Keeps tick time bounded while loading.
const CHUNKS_PER_TICK: usize = 2;

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

/// A single loaded chunk: terrain data + mesh + dirty flags.
pub const LoadedChunk = struct {
    chunk: Chunk,
    mesh: Mesh,
    cx: i32,
    cz: i32,
    /// True when the mesh needs full regeneration (just loaded, or neighbor arrived).
    mesh_dirty: bool,
    /// True when mesh was changed incrementally and GPU buffers need re-upload.
    mesh_incremental_dirty: bool,

    pub fn init(allocator: std.mem.Allocator, cx: i32, cz: i32) LoadedChunk {
        return .{
            .chunk = Chunk.init(),
            .mesh = Mesh.init(allocator),
            .cx = cx,
            .cz = cz,
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

    pub fn init(allocator: std.mem.Allocator) !World {
        return .{
            .allocator = allocator,
            .chunks = ChunkMap.init(allocator),
            .spiral_offsets = try buildSpiralOffsets(allocator, RENDER_DISTANCE),
            .gen_config = world_gen.presetConfig(world_gen.ACTIVE_PRESET),
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

    /// Update chunk loading for the given anchors.
    /// Loads up to CHUNKS_PER_TICK new chunks per call, innermost-first.
    /// When a new chunk is loaded, adjacent already-loaded chunks are re-meshed
    /// so their boundary faces are correctly culled against the new neighbour.
    /// Call this from voxelTick once per tick.
    pub fn update(self: *World, anchors: []const RegionAnchor) !void {
        var loaded_this_tick: usize = 0;

        outer: for (self.spiral_offsets) |off| {
            if (loaded_this_tick >= CHUNKS_PER_TICK) break;

            for (anchors) |anchor| {
                if (loaded_this_tick >= CHUNKS_PER_TICK) break :outer;

                const anchor_cx = chunkCoordOf(@as(i32, @intFromFloat(@floor(anchor.position[0]))));
                const anchor_cz = chunkCoordOf(@as(i32, @intFromFloat(@floor(anchor.position[2]))));
                const key = ChunkKey{ .cx = anchor_cx + off.dx, .cz = anchor_cz + off.dz };

                if (!self.chunks.contains(key)) {
                    const lc = try self.allocator.create(LoadedChunk);
                    lc.* = LoadedChunk.init(self.allocator, key.cx, key.cz);
                    lc.chunk.generateTerrain(key.cx, key.cz, self.gen_config);
                    try self.chunks.put(key, lc);
                    loaded_this_tick += 1;

                    // Re-mesh adjacent already-loaded chunks so their boundary faces
                    // are re-evaluated against this new neighbour.
                    const adjacent = [_]ChunkKey{
                        .{ .cx = key.cx - 1, .cz = key.cz },
                        .{ .cx = key.cx + 1, .cz = key.cz },
                        .{ .cx = key.cx, .cz = key.cz - 1 },
                        .{ .cx = key.cx, .cz = key.cz + 1 },
                    };
                    for (adjacent) |nk| {
                        if (self.chunks.getPtr(nk)) |nlc_ptr| {
                            nlc_ptr.*.mesh_dirty = true;
                        }
                    }
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

    /// Returns a BlockGetter backed by this World (queries world coords).
    pub fn asBlockGetter(self: *const World) chunk_mod.BlockGetter {
        return .{
            .ctx = self,
            .getFn = struct {
                fn get(ctx: *const anyopaque, x: i32, y: i32, z: i32) chunk_mod.BlockType {
                    return @as(*const World, @ptrCast(@alignCast(ctx))).getBlock(x, y, z);
                }
            }.get,
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
