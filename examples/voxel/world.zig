const std = @import("std");
const chunk_mod = @import("chunk.zig");
const world_gen = @import("world_gen.zig");
const stages = @import("pipeline/stages.zig");
const protocol = @import("pipeline/protocol.zig");
const mesh_bytes = @import("pipeline/mesh_bytes.zig");
const Chunk = chunk_mod.Chunk;
const Version = stages.Version;
const Inputs = stages.Inputs;

/// Default render distance in chunks (circular radius). The `--render-distance=N`
/// flag and the Settings picker change it. The value is chunks, not blocks:
/// the visible disc is `DEFAULT_RENDER_DISTANCE × CHUNK_W` blocks across.
/// See `examples/voxel/docs/chunk-size-investigation.md` for the pair of
/// chunk width and render distance.
pub const DEFAULT_RENDER_DISTANCE: i32 = 12;

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

pub const ChunkMap = std.HashMap(ChunkKey, *LoadedChunk, ChunkKey.HashContext, std.hash_map.default_max_load_percentage);

/// What main knows of the mesh of a chunk (C5). The quads go to the GPU
/// and main keeps no copy of them.
pub const MeshInfo = struct {
    quad_count: u32 = 0,
    /// The y range of the quads, for the frustum cull. With no quads, y_min
    /// is CHUNK_H and y_max is 0.
    y_min: f32 = chunk_mod.CHUNK_H,
    y_max: f32 = 0,
    /// protocol.meshHash of the quad bytes. The tests compare meshes by it.
    hash: u64 = 0,

    pub fn quadCount(self: MeshInfo) usize {
        return self.quad_count;
    }
};

/// A chunk in the World: its versions, its mesh, and the blocks near the
/// player. The chunk scheduler uses it (pipeline/scheduler.zig, C3).
///
/// The stages of a chunk (C2): Generated (blocks), Lit (light), Meshed
/// (mesh), Uploaded (on the GPU). A worker generated each chunk in the
/// World, and has its blocks (C4). Main has the blocks too when `has_blocks`
/// is true (the prefetch radius, C6). The chunk has light when
/// `light_inputs` is not null, and a mesh when `mesh_inputs` is not null.
/// The light is in the workers. Main keeps only its hash. A result is
/// current when its input versions are the versions of now. The scheduler
/// decides that.
pub const LoadedChunk = struct {
    /// The blocks, when `has_blocks` is true. The scheduler path keeps no
    /// light here. The reference path (`World.generateChunk`) does.
    chunk: Chunk,
    /// True when main has the blocks of the chunk (C6).
    has_blocks: bool = false,
    /// The hash of the installed light (protocol.lightHash).
    light_hash: u64 = 0,
    /// The counts of the installed mesh. Main keeps no quads (C5).
    mesh: MeshInfo = .{},
    /// The quad bytes of a new mesh, until main uploads them to the GPU and
    /// frees them (C5). Null when no upload waits.
    upload: ?mesh_bytes.MeshBytes = null,
    cx: i32,
    cz: i32,
    /// The content version of the blocks: 0 after generation, and 1 more
    /// for each edit.
    block_ver: Version = 0,
    /// The version of the installed light. 0 when the chunk has no light.
    light_ver: Version = 0,
    /// The input versions of the installed light, or null.
    light_inputs: ?Inputs = null,
    /// The input versions of the installed mesh, or null.
    mesh_inputs: ?Inputs = null,
    /// The mesh options (AO, lighting) of the installed mesh.
    mesh_options: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, cx: i32, cz: i32) LoadedChunk {
        return .{
            .chunk = Chunk.init(allocator),
            .cx = cx,
            .cz = cz,
        };
    }

    pub fn deinit(self: *LoadedChunk) void {
        self.dropUpload();
        self.chunk.deinit();
    }

    pub fn hasLight(self: *const LoadedChunk) bool {
        return self.light_inputs != null;
    }

    pub fn hasMesh(self: *const LoadedChunk) bool {
        return self.mesh_inputs != null;
    }

    /// Forget the mesh. The GPU buffers belong to main.zig, and main frees them.
    pub fn dropMesh(self: *LoadedChunk) void {
        self.dropUpload();
        self.mesh = .{};
        self.mesh_inputs = null;
    }

    /// Free the quad bytes that wait for the upload, if any.
    pub fn dropUpload(self: *LoadedChunk) void {
        if (self.upload) |u| u.release();
        self.upload = null;
    }

    /// Set a new mesh: the counts, and the quad bytes for the upload. The
    /// chunk takes `bytes`.
    pub fn setMesh(self: *LoadedChunk, info: MeshInfo, bytes: mesh_bytes.MeshBytes) void {
        self.dropUpload();
        self.mesh = info;
        self.upload = bytes;
    }

    /// Free the light. The chunk then reads skylight 0 and block light 0.
    pub fn dropLight(self: *LoadedChunk) void {
        self.chunk.skylight.deinit(self.chunk.allocator);
        self.chunk.block_light.deinit(self.chunk.allocator);
        self.chunk.skylight = .{};
        self.chunk.block_light = .{};
        self.light_inputs = null;
        self.light_ver = 0;
        self.light_hash = 0;
    }

    /// Free the blocks on main. The workers and the edit log keep them (C4).
    /// The chunk then reads as a missing chunk.
    pub fn dropBlocks(self: *LoadedChunk) void {
        self.chunk.blocks.deinit(self.chunk.allocator);
        self.has_blocks = false;
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
    /// The render distance in chunks (circular radius). The fog and the
    /// frustum read it. The scheduler sets it (Scheduler.setRenderDistance).
    render_distance: i32,
    /// The world generation config. `init` sets it from the preset, and
    /// each generation reads it. Change a field after init to change the
    /// generation without a new preset.
    gen_config: world_gen.WorldGenConfig,
    /// The next light version. Light versions are never used again, so a
    /// recorded light version names one light content (C3).
    next_light_version: Version = 1,
    /// The edit log (P2): the edits of each chunk, in order. A chunk that
    /// main generates inline gets its edits from it (C6).
    edits: std.HashMapUnmanaged(ChunkKey, std.ArrayList(protocol.Edit), ChunkKey.HashContext, std.hash_map.default_max_load_percentage) = .empty,

    pub fn init(allocator: std.mem.Allocator, preset: world_gen.Preset, render_distance: i32) !World {
        return .{
            .allocator = allocator,
            .chunks = ChunkMap.init(allocator),
            .render_distance = render_distance,
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
        var eit = self.edits.valueIterator();
        while (eit.next()) |list| list.deinit(self.allocator);
        self.edits.deinit(self.allocator);
    }

    /// Add chunk (cx, cz) with the blocks of a generate result. The chunk
    /// takes `blocks`. The chunk has no light and no mesh. Its block version
    /// is the version of the edit log. The chunk must not be in the World.
    pub fn installBlocks(self: *World, cx: i32, cz: i32, blocks: chunk_mod.PalettedBlocks) !*LoadedChunk {
        const lc = try self.installRemote(cx, cz, self.editVersion(cx, cz));
        lc.chunk.blocks = blocks;
        lc.has_blocks = true;
        return lc;
    }

    /// Add chunk (cx, cz) with no blocks on main: a worker generated it
    /// (C4). The chunk must not be in the World.
    pub fn installRemote(self: *World, cx: i32, cz: i32, block_ver: Version) !*LoadedChunk {
        const key = ChunkKey{ .cx = cx, .cz = cz };
        std.debug.assert(!self.chunks.contains(key));
        const lc = try self.allocator.create(LoadedChunk);
        errdefer self.allocator.destroy(lc);
        lc.* = LoadedChunk.init(self.allocator, cx, cz);
        lc.block_ver = block_ver;
        try self.chunks.put(key, lc);
        return lc;
    }

    /// Give `lc` the blocks `blocks`. The chunk takes them. `lc` must have
    /// no blocks on main.
    pub fn setBlocks(self: *World, lc: *LoadedChunk, blocks: chunk_mod.PalettedBlocks) void {
        _ = self;
        std.debug.assert(!lc.has_blocks);
        lc.chunk.blocks.deinit(lc.chunk.allocator);
        lc.chunk.blocks = blocks;
        lc.has_blocks = true;
    }

    /// Add an edit to the edit log.
    pub fn logEdit(self: *World, edit: protocol.Edit) !void {
        const gop = try self.edits.getOrPut(self.allocator, .{ .cx = edit.cx, .cz = edit.cz });
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(self.allocator, edit);
    }

    /// The block version of chunk (cx, cz) in the edit log: the version
    /// after its last edit, or 0.
    pub fn editVersion(self: *const World, cx: i32, cz: i32) Version {
        const list = self.edits.get(.{ .cx = cx, .cz = cz }) orelse return 0;
        return list.items[list.items.len - 1].version;
    }

    /// Apply the edits of chunk (cx, cz) from the edit log to `blocks`, in
    /// order (P2).
    pub fn applyEditLog(self: *const World, cx: i32, cz: i32, blocks: *chunk_mod.PalettedBlocks) !void {
        const list = self.edits.get(.{ .cx = cx, .cz = cz }) orelse return;
        for (list.items) |e| try blocks.set(self.allocator, chunk_mod.blockLinearIdx(e.x, e.y, e.z), e.block);
    }

    /// Remove chunk (cx, cz) and free it. The GPU buffers belong to main.
    pub fn removeChunk(self: *World, cx: i32, cz: i32) void {
        const kv = self.chunks.fetchRemove(.{ .cx = cx, .cz = cz }) orelse return;
        kv.value.deinit();
        self.allocator.destroy(kv.value);
    }

    /// The chunk at chunk coords (cx, cz), or null.
    pub fn get(self: *const World, cx: i32, cz: i32) ?*LoadedChunk {
        return self.chunks.get(.{ .cx = cx, .cz = cz });
    }

    /// The reference path: generate chunk (cx, cz) with its light, and
    /// exchange light with its face neighbours (`relightSeams`). The game
    /// does not use it. The chunk scheduler runs the stages of
    /// pipeline/stages.zig. The stage tests, the terrain hash and the
    /// benchmarks compare the stages with this path.
    ///
    /// Returns true if a new chunk was created, false if the slot was already
    /// occupied.
    pub fn generateChunk(self: *World, cx: i32, cz: i32) !bool {
        const key = ChunkKey{ .cx = cx, .cz = cz };
        if (self.chunks.contains(key)) return false;

        const lc = try self.allocator.create(LoadedChunk);
        lc.* = LoadedChunk.init(self.allocator, cx, cz);
        try lc.chunk.generateTerrain(cx, cz, self.gen_config);
        lc.has_blocks = true;
        try self.chunks.put(key, lc);

        // Per-chunk RAM audit — log palette width + byte cost once on first
        // generation so the palette-compression benefit is visible in TAS
        // runs without having to attach a heap profiler. The legacy
        // `[W][H][W]BlockType` layout cost 576 KB flat per chunk regardless
        // of terrain (see `docs/memory.md` §1); the paletted figure varies
        // from ~256 B (uniform chunk) to 576 KB + palette header.
        std.log.info(
            "[CHUNK SIZE] ({d:3},{d:3}) palette_len={d:3} bits={d} block_bytes={d:7} total_bytes={d:7}",
            .{
                cx,
                cz,
                lc.chunk.paletteLen(),
                lc.chunk.bitsPerEntry(),
                lc.chunk.blockDataBytes(),
                lc.chunk.totalBytes(),
            },
        );

        _ = try self.relightSeams(cx, cz);
        return true;
    }

    /// Recompute the light channels `ch` of `lc`, seeded from the edges of
    /// its live face neighbours.
    fn relightChunk(self: *const World, lc: *LoadedChunk, ch: Channels) !void {
        const xn = self.chunkAt(lc.cx - 1, lc.cz);
        const xp = self.chunkAt(lc.cx + 1, lc.cz);
        const zn = self.chunkAt(lc.cx, lc.cz - 1);
        const zp = self.chunkAt(lc.cx, lc.cz + 1);
        if (ch.sky) try lc.chunk.computeSkylightWithNeighbors(xn, xp, zn, zp);
        if (ch.block) try lc.chunk.computeBlockLightWithNeighbors(xn, xp, zn, zp);
    }

    /// Exchange light across the borders of the new chunk at (cx, cz).
    /// Generation lights a chunk on its own, so without this step skylight
    /// in a cave and light from a glowstone stop at the chunk border. The
    /// new chunk is seeded from its neighbours, then `spreadLight` carries
    /// its edge light outward. The relight runs only where an edge can make
    /// a cell across the border brighter (see `canSeed`).
    ///
    /// Returns true when the new chunk got new light.
    pub fn relightSeams(self: *World, cx: i32, cz: i32) !bool {
        const lc = self.chunks.get(.{ .cx = cx, .cz = cz }) orelse return false;
        var own: Channels = .{};
        for (std.enums.values(Edge)) |side| {
            const n = self.neighbour(lc, side) orelse continue;
            own = own.merge(canSeed(&n.chunk, &lc.chunk, side));
        }
        if (own.any()) try self.relightChunk(lc, own);

        var queue: RelightQueue = .empty;
        defer queue.deinit(self.allocator);
        for (std.enums.values(Edge)) |side| {
            const n = self.neighbour(lc, side) orelse continue;
            try queueRelight(&queue, self.allocator, n, canSeed(&lc.chunk, &n.chunk, side.opposite()));
        }
        const again = try self.spreadLight(&queue, lc);
        return own.any() or again;
    }

    /// Relight each chunk in `queue` (only the listed channels) from its
    /// live face neighbours. When the light of a
    /// channel changes on an edge of a relit chunk, the chunk on that side
    /// goes in the queue for that channel. The light values move towards a
    /// fixed point, so the queue empties. Returns true when `watch` was
    /// relit again.
    fn spreadLight(self: *World, queue: *RelightQueue, watch: ?*LoadedChunk) !bool {
        var watch_relit = false;
        var before: EdgeLight = undefined;
        var after: EdgeLight = undefined;
        var i: usize = 0;
        while (i < queue.items.len) : (i += 1) {
            const item = queue.items[i];
            const lc = item.lc;
            readEdges(&lc.chunk, &before);
            try self.relightChunk(lc, item.ch);
            if (lc == watch) watch_relit = true;
            readEdges(&lc.chunk, &after);
            for (std.enums.values(Edge)) |side| {
                const k = @backingInt(side);
                const changed: Channels = .{
                    .sky = !std.mem.eql(u8, &before.sky[k], &after.sky[k]),
                    .block = !std.mem.eql(u8, &before.block[k], &after.block[k]),
                };
                const n = self.neighbour(lc, side) orelse continue;
                try queueRelightAfter(queue, self.allocator, i, n, changed);
            }
        }
        return watch_relit;
    }

    /// The live chunk next to `lc` on `side`, or null.
    fn neighbour(self: *const World, lc: *const LoadedChunk, side: Edge) ?*LoadedChunk {
        return switch (side) {
            .x_neg => self.chunks.get(.{ .cx = lc.cx - 1, .cz = lc.cz }),
            .x_pos => self.chunks.get(.{ .cx = lc.cx + 1, .cz = lc.cz }),
            .z_neg => self.chunks.get(.{ .cx = lc.cx, .cz = lc.cz - 1 }),
            .z_pos => self.chunks.get(.{ .cx = lc.cx, .cz = lc.cz + 1 }),
        };
    }

    /// The chunk data at chunk coords (cx, cz), or null when it is not loaded.
    pub fn chunkAt(self: *const World, cx: i32, cz: i32) ?*const Chunk {
        const lc = self.chunks.get(.{ .cx = cx, .cz = cz }) orelse return null;
        return &lc.chunk;
    }

    /// Get a block at world-space coordinates. Returns MISSING_BLOCK (air)
    /// for a chunk that main has no blocks for.
    pub fn getBlock(self: *const World, wx: i32, wy: i32, wz: i32) chunk_mod.BlockType {
        const cx = chunkCoordOf(wx);
        const cz = chunkCoordOf(wz);
        const lc = self.chunks.get(.{ .cx = cx, .cz = cz }) orelse return chunk_mod.MISSING_BLOCK;
        if (!lc.has_blocks) return chunk_mod.MISSING_BLOCK;

        const lx = wx - cx * chunk_mod.CHUNK_W;
        const lz = wz - cz * chunk_mod.CHUNK_W;
        return lc.chunk.getBlock(lx, wy, lz);
    }

    /// The reference path: set a block at world-space coordinates and relight
    /// the chunk and its face neighbours (`spreadLight`). Returns false if
    /// the chunk is unloaded. The game does not use it: an edit in the game
    /// goes through `Scheduler.editBlock`, and the light stage relights.
    /// The stage tests compare the light stage with this path.
    pub fn setBlock(self: *World, wx: i32, wy: i32, wz: i32, block: chunk_mod.BlockType) !bool {
        const cx = chunkCoordOf(wx);
        const cz = chunkCoordOf(wz);
        const lc_ptr = self.chunks.getPtr(.{ .cx = cx, .cz = cz }) orelse return false;
        const lx = wx - cx * chunk_mod.CHUNK_W;
        const lz = wz - cz * chunk_mod.CHUNK_W;
        // Paletted chunk — setBlock can allocate when the palette grows
        // past a power-of-two boundary. Propagate the error instead of
        // swallowing it; OOM here is the caller's problem, not ours.
        try lc_ptr.*.chunk.setBlock(lx, wy, lz, block);

        // Live horizontal neighbours (null if unloaded), for the relight.
        const nb_xn = self.chunks.get(.{ .cx = cx - 1, .cz = cz });
        const nb_xp = self.chunks.get(.{ .cx = cx + 1, .cz = cz });
        const nb_zn = self.chunks.get(.{ .cx = cx, .cz = cz - 1 });
        const nb_zp = self.chunks.get(.{ .cx = cx, .cz = cz + 1 });

        // Recompute skylight and block-light for the owning chunk, seeding
        // from neighbour edges so light from a neighbour (a glowstone near
        // the border, or sky through a cave) crosses into this chunk.
        try self.relightChunk(lc_ptr.*, .{ .sky = true, .block = true });

        // Re-run the light for each live horizontal neighbour, seeding from
        // this chunk's newly-updated edges. This propagates light across the
        // boundary in both directions: a glowstone placed at our x=0 will push
        // level-14 light into the cx-1 chunk; a glowstone in cx-1 near x=CHUNK_W-1
        // will push into our chunk (handled above). `spreadLight`
        // continues to chunks further away while edge light changes.
        var queue: RelightQueue = .empty;
        defer queue.deinit(self.allocator);
        for ([_]?*LoadedChunk{ nb_xn, nb_xp, nb_zn, nb_zp }) |nb| {
            if (nb) |nlc| try queueRelight(&queue, self.allocator, nlc, .{ .sky = true, .block = true });
        }
        _ = try self.spreadLight(&queue, null);

        return true;
    }

    /// Get the LoadedChunk containing the given world block coordinate.
    pub fn getChunkAtBlock(self: *World, wx: i32, wz: i32) ?*LoadedChunk {
        return self.chunks.get(.{ .cx = chunkCoordOf(wx), .cz = chunkCoordOf(wz) });
    }

    /// Get the skylight at world-space coordinates. Returns MAX_SKYLIGHT for
    /// any cell above the world top, and also for unloaded chunks.
    ///
    /// Unloaded-chunk default is MAX_SKYLIGHT (not 0): the sky continues
    /// beyond the render boundary, so treating missing neighbours as pitch-black
    /// causes false dark seams along the outer edge of the loaded area. Vertices
    /// at the boundary whose skylight samples fall into an unloaded chunk get
    /// full sunlight instead of artificial shadow. Any in-chunk dimming (caves,
    /// overhangs) only exists in *loaded* terrain and is handled by each chunk's
    /// own skylight grid; we cannot know the state of unloaded terrain, and
    /// "bright unknown" is far less jarring than "dark unknown".
    ///
    /// Note: getBlock returns .air for unloaded chunks (no false AO occlusion).
    /// getBlockLight returns 0 for unloaded chunks (no false emitter glow).
    /// Only skylight uses MAX_SKYLIGHT because it has a global source (the sun).
    pub fn getSkylight(self: *const World, wx: i32, wy: i32, wz: i32) u8 {
        if (wy >= chunk_mod.CHUNK_H) return chunk_mod.MAX_SKYLIGHT;
        // Below the world is dark, also under a missing chunk, as in a loaded
        // chunk (Chunk.getSkylight) and in SnapshotGetter.
        if (wy < 0) return 0;
        const cx = chunkCoordOf(wx);
        const cz = chunkCoordOf(wz);
        const lc = self.chunks.get(.{ .cx = cx, .cz = cz }) orelse return chunk_mod.MISSING_SKYLIGHT;
        const lx = wx - cx * chunk_mod.CHUNK_W;
        const lz = wz - cz * chunk_mod.CHUNK_W;
        return lc.chunk.getSkylight(lx, wy, lz);
    }

    /// Get the block-light at world-space coordinates. Returns 0 for any
    /// out-of-world coordinate and for unloaded chunks — block light has no
    /// global seed (unlike the sun) so "unknown" naturally means "no light".
    pub fn getBlockLight(self: *const World, wx: i32, wy: i32, wz: i32) u8 {
        const cx = chunkCoordOf(wx);
        const cz = chunkCoordOf(wz);
        const lc = self.chunks.get(.{ .cx = cx, .cz = cz }) orelse return chunk_mod.MISSING_BLOCK_LIGHT;
        const lx = wx - cx * chunk_mod.CHUNK_W;
        const lz = wz - cz * chunk_mod.CHUNK_W;
        return lc.chunk.getBlockLight(lx, wy, lz);
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
            .getBlockLightFn = struct {
                fn getBl(ctx: *const anyopaque, x: i32, y: i32, z: i32) u8 {
                    return @as(*const World, @ptrCast(@alignCast(ctx))).getBlockLight(x, y, z);
                }
            }.getBl,
        };
    }
};

/// One of the four vertical edge planes of a chunk.
const Edge = enum {
    x_neg,
    x_pos,
    z_neg,
    z_pos,

    fn opposite(self: Edge) Edge {
        return switch (self) {
            .x_neg => .x_pos,
            .x_pos => .x_neg,
            .z_neg => .z_pos,
            .z_pos => .z_neg,
        };
    }
};

/// The light channels that a relight recomputes.
const Channels = struct {
    sky: bool = false,
    block: bool = false,

    fn any(self: Channels) bool {
        return self.sky or self.block;
    }
    fn merge(a: Channels, b: Channels) Channels {
        return .{ .sky = a.sky or b.sky, .block = a.block or b.block };
    }
};

/// Chunks that need a relight, and of which channels.
const RelightQueue = std.ArrayList(struct { lc: *LoadedChunk, ch: Channels });

/// Add `lc` to `queue` for the channels `ch`. A chunk that is in the queue
/// already gets the channels added to its entry.
fn queueRelight(queue: *RelightQueue, a: std.mem.Allocator, lc: *LoadedChunk, ch: Channels) !void {
    return queueRelightAfter(queue, a, null, lc, ch);
}

/// `queueRelight`, but entries at or before index `done` are done already,
/// so a chunk found only there goes in again.
fn queueRelightAfter(queue: *RelightQueue, a: std.mem.Allocator, done: ?usize, lc: *LoadedChunk, ch: Channels) !void {
    if (!ch.any()) return;
    const start = if (done) |d| d + 1 else 0;
    for (queue.items[start..]) |*item| {
        if (item.lc == lc) {
            item.ch = item.ch.merge(ch);
            return;
        }
    }
    try queue.append(a, .{ .lc = lc, .ch = ch });
}

/// The light of the four edge planes of a chunk, indexed by `Edge`.
const EdgeLight = struct {
    sky: [4][chunk_mod.CHUNK_H * chunk_mod.CHUNK_W]u8,
    block: [4][chunk_mod.CHUNK_H * chunk_mod.CHUNK_W]u8,
};

fn readEdges(ch: *const Chunk, out: *EdgeLight) void {
    const W = chunk_mod.CHUNK_W;
    for (0..chunk_mod.CHUNK_H) |y| for (0..W) |i| {
        const k = y * W + i;
        for (std.enums.values(Edge)) |side| {
            const x: usize, const z: usize = edgeCell(side, i);
            out.sky[@backingInt(side)][k] = ch.skylight.get(x, y, z);
            out.block[@backingInt(side)][k] = ch.block_light.get(x, y, z);
        }
    };
}

/// Local (x, z) of cell `i` along the `side` edge plane of a chunk.
fn edgeCell(side: Edge, i: usize) struct { usize, usize } {
    const W = chunk_mod.CHUNK_W;
    return switch (side) {
        .x_neg => .{ 0, i },
        .x_pos => .{ W - 1, i },
        .z_neg => .{ i, 0 },
        .z_pos => .{ i, W - 1 },
    };
}

/// The light channels in which the edge of `src` can make a cell of `dst`
/// brighter. `side` is the edge of `dst` that touches `src`. The rule is
/// the seed rule of `computeSkylightWithNeighbors` and
/// `computeBlockLightWithNeighbors`: an air cell gets (source - 1) when the
/// source is 2 or more and the result is brighter.
fn canSeed(src: *const Chunk, dst: *const Chunk, side: Edge) Channels {
    var out: Channels = .{};
    for (0..chunk_mod.CHUNK_H) |y| for (0..chunk_mod.CHUNK_W) |i| {
        const dx: usize, const dz: usize = edgeCell(side, i);
        const sx: usize, const sz: usize = edgeCell(side.opposite(), i);
        const s_sky = src.skylight.get(sx, y, sz);
        const s_block = src.block_light.get(sx, y, sz);
        if (s_sky < 2 and s_block < 2) continue;
        if (dst.resolveBlockRaw(@intCast(dx), @intCast(y), @intCast(dz)) != .air) continue;
        if (s_sky >= 2 and dst.skylight.get(dx, y, dz) < s_sky - 1) out.sky = true;
        if (s_block >= 2 and dst.block_light.get(dx, y, dz) < s_block - 1) out.block = true;
        if (out.sky and out.block) return out;
    };
    return out;
}

const ChunkOffset = struct { dx: i32, dz: i32 };

/// The (dx, dz) offsets of a disc of radius r, nearest first. For the tests.
fn buildSpiralOffsets(allocator: std.mem.Allocator, r: i32) ![]ChunkOffset {
    var offsets: std.ArrayList(ChunkOffset) = .empty;
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

/// Cells of `lc` whose skylight or block light differs from a recompute
/// seeded by its live face neighbours (what `World.setBlock` gives the
/// chunk). `own` gets a fresh copy of the chunk, lit on its own.
fn countSeamLightErrors(world: *World, lc: *const LoadedChunk, own: *Chunk) !usize {
    try own.generateTerrain(lc.cx, lc.cz, world.gen_config);
    var want = Chunk.init(world.allocator);
    defer want.deinit();
    try want.generateTerrain(lc.cx, lc.cz, world.gen_config);
    const xn = world.chunkAt(lc.cx - 1, lc.cz);
    const xp = world.chunkAt(lc.cx + 1, lc.cz);
    const zn = world.chunkAt(lc.cx, lc.cz - 1);
    const zp = world.chunkAt(lc.cx, lc.cz + 1);
    try want.computeSkylightWithNeighbors(xn, xp, zn, zp);
    try want.computeBlockLightWithNeighbors(xn, xp, zn, zp);
    var errors: usize = 0;
    for (0..chunk_mod.CHUNK_W) |x| for (0..chunk_mod.CHUNK_H) |y| for (0..chunk_mod.CHUNK_W) |z| {
        if (lc.chunk.skylight.get(x, y, z) != want.skylight.get(x, y, z)) errors += 1;
        if (lc.chunk.block_light.get(x, y, z) != want.block_light.get(x, y, z)) errors += 1;
    };
    return errors;
}

test "generated chunks get light from their neighbours" {
    var world = try World.init(std.testing.allocator, .hilly, 4);
    defer world.deinit();
    // Generate in spiral order, nearest first.
    const R: i32 = 6;
    const offsets = try buildSpiralOffsets(std.testing.allocator, R);
    defer std.testing.allocator.free(offsets);
    for (offsets) |off| _ = try world.generateChunk(off.dx, off.dz);

    // Check every chunk that has all four face neighbours. At least one
    // chunk must get light from a neighbour, or the test checks nothing.
    var seeded: usize = 0;
    var errors: usize = 0;
    var it = world.chunks.valueIterator();
    while (it.next()) |lc_ptr| {
        const lc = lc_ptr.*;
        if (world.chunkAt(lc.cx - 1, lc.cz) == null or world.chunkAt(lc.cx + 1, lc.cz) == null or
            world.chunkAt(lc.cx, lc.cz - 1) == null or world.chunkAt(lc.cx, lc.cz + 1) == null) continue;
        var own = Chunk.init(world.allocator);
        defer own.deinit();
        errors += try countSeamLightErrors(&world, lc, &own);
        diff: for (0..chunk_mod.CHUNK_W) |x| for (0..chunk_mod.CHUNK_H) |y| for (0..chunk_mod.CHUNK_W) |z| {
            if (own.skylight.get(x, y, z) != lc.chunk.skylight.get(x, y, z) or
                own.block_light.get(x, y, z) != lc.chunk.block_light.get(x, y, z))
            {
                seeded += 1;
                break :diff;
            }
        };
    }
    try std.testing.expectEqual(@as(usize, 0), errors);
    try std.testing.expect(seeded > 0);
}

test "a shaft dug into a cave lights the cave across the chunk border" {
    // Sean's repro: at (14, 15) on the hilly world, a shaft from the
    // surface down to y=60 opens into a cave at y <= 66. x=15 and z=15 are
    // the last cells before the borders with chunks (1,0) and (0,1).
    var world = try World.init(std.testing.allocator, .hilly, 4);
    defer world.deinit();
    const offsets = try buildSpiralOffsets(std.testing.allocator, 3);
    defer std.testing.allocator.free(offsets);
    for (offsets) |off| _ = try world.generateChunk(off.dx, off.dz);
    var y: i32 = chunk_mod.CHUNK_H - 1;
    while (y > 60 and world.getBlock(14, y, 15) == .air) y -= 1;
    while (y >= 60) : (y -= 1) _ = try world.setBlock(14, y, 15, .air);

    // The shaft is open to the sky, and the cave next to it gets 14.
    try std.testing.expectEqual(@as(u8, 15), world.getSkylight(14, 60, 15));
    try std.testing.expectEqual(.air, world.getBlock(15, 62, 15));
    try std.testing.expectEqual(@as(u8, 14), world.getSkylight(15, 62, 15));
    // Across the borders the cave gets light, not 0. (16, 62, 15) is two
    // steps from the shaft. (14, 62, 16) is next to the shaft.
    try std.testing.expectEqual(.air, world.getBlock(16, 62, 15));
    try std.testing.expectEqual(@as(u8, 13), world.getSkylight(16, 62, 15));
    try std.testing.expectEqual(.air, world.getBlock(14, 62, 16));
    try std.testing.expectEqual(@as(u8, 14), world.getSkylight(14, 62, 16));
}
