//! The world of a chunk worker (C4 option b, P2).
//!
//! A worker owns a copy of the world: the generation config with the seed,
//! and the edit log. It rebuilds each chunk from them. It keeps the chunks
//! that it generated, and their light, in an LRU cache with a memory limit
//! (C14). Main sends only small messages: edits and jobs (protocol.zig).
//!
//! `handle` takes the bytes of one message and gives the bytes of the
//! reply. The Inline executor calls it on the main thread. Each thread of
//! the ThreadPool executor has its own WorkerWorld. A Web Worker (C9) will
//! use the same code in chunks.wasm. So this file must build for
//! wasm32-freestanding: no std.Thread, no clock, no files and no globals.
//!
//! Order: a worker handles its messages in the order that they arrive.
//! Main sends each edit to each worker before the jobs that come after the
//! edit. So when a worker handles a job, its blocks are the blocks of main
//! when the job started, and the block versions of the job are its block
//! versions (C3). A job whose versions differ gets an Error (stale_input).
//!
//! Results (C2): a light job and a mesh job read the blocks of the chunks
//! around the chunk. The worker generates each chunk that is not in its
//! cache. The stages are pure functions, so a chunk that two workers
//! generate is the same in both.
const std = @import("std");
const chunk_mod = @import("../chunk.zig");
const content = @import("../content.zig");
const stages = @import("stages.zig");
const lod = @import("lod.zig");
const protocol = @import("protocol.zig");
const light_rules = @import("../light.zig");

const PalettedBlocks = chunk_mod.PalettedBlocks;
const Version = stages.Version;
const SLOTS = stages.SLOTS;

/// The default cache limit of a worker (C14).
pub const DEFAULT_CACHE_LIMIT: u64 = 64 * 1024 * 1024;

const Key = struct {
    cx: i32,
    cz: i32,
};

/// One cache entry: the blocks of a chunk, with all its edits, and maybe
/// its light.
const Entry = struct {
    key: Key,
    blocks: PalettedBlocks,
    /// The light of the chunk, or null.
    light: ?stages.ChunkLight = null,
    /// The block versions of the 3×3 chunks that the light read.
    light_inputs: [SLOTS]Version = @splat(0),
    light_hash: u64 = 0,
    /// The bytes that the entry holds, for the cache limit.
    bytes: usize = 0,
    /// The LRU list. `prev` is the newer entry.
    prev: ?*Entry = null,
    next: ?*Entry = null,
};

/// The edits of one chunk, in the order that they arrived.
const EditLog = struct {
    version: Version = 0,
    edits: std.ArrayList(protocol.Edit) = .empty,
};

pub const Stats = struct {
    jobs: u64 = 0,
    /// Lookups of blocks or light that found the entry in the cache.
    hits: u64 = 0,
    misses: u64 = 0,
    generated: u64 = 0,
    lit: u64 = 0,
    evicted: u64 = 0,
    edits: u64 = 0,
    /// Edits that updated the cached light incrementally (REQ-VOXEL-005).
    relit: u64 = 0,
    /// The largest cache size after a message, in bytes.
    peak_bytes: usize = 0,
};

pub const WorkerWorld = struct {
    allocator: std.mem.Allocator,
    config: ?content.GenConfig = null,
    cache_limit: u64 = DEFAULT_CACHE_LIMIT,
    cache: std.AutoHashMapUnmanaged(Key, *Entry) = .empty,
    /// The newest entry of the LRU list, and the oldest.
    newest: ?*Entry = null,
    oldest: ?*Entry = null,
    /// The bytes of all entries.
    bytes: usize = 0,
    log: std.AutoHashMapUnmanaged(Key, EditLog) = .empty,
    /// The light stage scratch (about 4 MB). It is not in the cache limit.
    scratch: ?*stages.LightScratch = null,
    stats: Stats = .{},

    pub fn init(allocator: std.mem.Allocator) WorkerWorld {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *WorkerWorld) void {
        self.clearCache();
        self.cache.deinit(self.allocator);
        var it = self.log.valueIterator();
        while (it.next()) |l| l.edits.deinit(self.allocator);
        self.log.deinit(self.allocator);
        if (self.scratch) |s| self.allocator.destroy(s);
        self.* = undefined;
    }

    /// Handle the message in `bytes`, and give the reply, or null when the
    /// message has no reply (an Edit). The caller owns the reply. Each reply
    /// is a Hello, a Result or an Error. It returns an error only when no
    /// memory is available for the reply.
    pub fn handle(self: *WorkerWorld, bytes: []const u8) error{OutOfMemory}!?[]u8 {
        const d = protocol.decode(bytes) catch |err| {
            return try protocol.encodeError(self.allocator, 0, .{ .code = .bad_message, .text = @errorName(err) });
        };
        defer self.enforceLimit();
        switch (d.msg) {
            .hello => |h| {
                if (h.build_hash != protocol.BUILD_HASH) {
                    return try protocol.encodeError(self.allocator, 0, .{ .code = .version_mismatch, .text = "build hash" });
                }
                self.setWorld(h.config, h.cache_limit);
                return try protocol.encodeHello(self.allocator, .{ .cache_limit = h.cache_limit, .config = h.config });
            },
            .edit => |e| {
                self.applyEdit(e) catch return try protocol.encodeError(self.allocator, 0, .{ .code = .out_of_memory, .cx = e.cx, .cz = e.cz });
                return null;
            },
            .job => |j| return try self.runJob(d.id, j),
            .result, .err => return try protocol.encodeError(self.allocator, d.id, .{ .code = .bad_message, .text = "main sends no result" }),
        }
    }

    /// Start a new world: drop the cache and the edit log.
    pub fn setWorld(self: *WorkerWorld, config: content.GenConfig, cache_limit: u64) void {
        self.clearCache();
        var it = self.log.valueIterator();
        while (it.next()) |l| l.edits.deinit(self.allocator);
        self.log.clearRetainingCapacity();
        self.config = config;
        self.cache_limit = cache_limit;
    }

    /// The block version of chunk (cx, cz): the number of its edits.
    pub fn blockVersion(self: *const WorkerWorld, cx: i32, cz: i32) Version {
        const l = self.log.getPtr(.{ .cx = cx, .cz = cz }) orelse return 0;
        return l.version;
    }

    /// Add an edit to the log, and apply it to the cached blocks. When the
    /// cache has the current light of the 3×3 chunks around the edit, the
    /// light changes incrementally (REQ-VOXEL-005), and the light of those
    /// chunks stays current. Else the light of the edited chunk goes, and
    /// `lightOf` computes the light again.
    pub fn applyEdit(self: *WorkerWorld, e: protocol.Edit) !void {
        const key: Key = .{ .cx = e.cx, .cz = e.cz };
        // Before the log changes: the light of the 3×3 chunks must be the
        // light of the blocks before this edit.
        const lit = self.currentLight(e.cx, e.cz);
        const gop = try self.log.getOrPut(self.allocator, key);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        try gop.value_ptr.edits.append(self.allocator, e);
        gop.value_ptr.version = e.version;
        self.stats.edits += 1;
        if (self.cache.get(key)) |entry| {
            try entry.blocks.setAt(self.allocator, e.x, e.y, e.z, e.block);
            if (lit) |entries| {
                self.relightEdit(entries, e) catch |err| {
                    for (entries) |n| {
                        self.dropLight(n);
                        self.recount(n);
                    }
                    return err;
                };
            } else {
                self.dropLight(entry);
                self.recount(entry);
            }
        }
    }

    /// The cache entries of the 3×3 chunks around (cx, cz), by slot, when
    /// each one has the light of the blocks now. Else null.
    fn currentLight(self: *const WorkerWorld, cx: i32, cz: i32) ?[SLOTS]*Entry {
        var out: [SLOTS]*Entry = undefined;
        for (0..SLOTS) |s| {
            const dcx, const dcz = stages.offsetOf(s);
            const n = self.cache.get(.{ .cx = cx + dcx, .cz = cz + dcz }) orelse return null;
            if (n.light == null) return null;
            for (0..SLOTS) |t| {
                const tx, const tz = stages.offsetOf(t);
                if (n.light_inputs[t] != self.blockVersion(n.key.cx + tx, n.key.cz + tz)) return null;
            }
            out[s] = n;
        }
        return out;
    }

    /// Update the light of `entries` (the 3×3 chunks around the edit) for
    /// edit `e`, which is in their blocks now. Each entry then records the
    /// new version of the edited chunk as a light input.
    fn relightEdit(self: *WorkerWorld, entries: [SLOTS]*Entry, e: protocol.Edit) !void {
        var region: light_rules.Region = .{ .allocator = self.allocator };
        for (entries, 0..) |n, s| {
            const dcx, const dcz = stages.offsetOf(s);
            region.parts[light_rules.Region.slot(dcx, dcz)] = .{
                .blocks = &n.blocks,
                .sky = &n.light.?.sky,
                .block = &n.light.?.block,
            };
        }
        try region.update(&.{.{ .x = e.x, .y = e.y, .z = e.z }});
        for (entries, 0..) |n, s| {
            // The edited chunk is at offset -(dcx, dcz) from entry s.
            const dcx, const dcz = stages.offsetOf(s);
            n.light_inputs[stages.slot(-dcx, -dcz)] = e.version;
            n.light_hash = protocol.lightHash(&n.light.?);
            self.recount(n);
        }
        self.stats.relit += 1;
    }

    fn runJob(self: *WorkerWorld, id: u32, job: protocol.Job) ![]u8 {
        if (self.config == null) return protocol.encodeError(self.allocator, id, .{ .code = .no_world, .stage = job.stage, .cx = job.cx, .cz = job.cz });
        self.stats.jobs += 1;
        // C3: the worker has the blocks of main when the job started.
        if (job.stage != .generate) {
            for (0..SLOTS) |s| {
                const dcx, const dcz = stages.offsetOf(s);
                if (job.blocks[s] != self.blockVersion(job.cx + dcx, job.cz + dcz)) {
                    return protocol.encodeError(self.allocator, id, .{ .code = .stale_input, .stage = job.stage, .cx = job.cx, .cz = job.cz });
                }
            }
        }
        return self.runStage(id, job) catch |err| switch (err) {
            error.OutOfMemory => protocol.encodeError(self.allocator, id, .{ .code = .out_of_memory, .stage = job.stage, .cx = job.cx, .cz = job.cz }),
        };
    }

    fn runStage(self: *WorkerWorld, id: u32, job: protocol.Job) error{OutOfMemory}![]u8 {
        var head: protocol.ResultHead = .{
            .stage = job.stage,
            .cx = job.cx,
            .cz = job.cz,
            .block_ver = self.blockVersion(job.cx, job.cz),
        };
        switch (job.stage) {
            .generate => {
                const e = try self.blocksOf(job.cx, job.cz);
                return protocol.encodeResult(self.allocator, id, head, if (job.want_blocks) .{ .blocks = &e.blocks } else .none);
            },
            .light => {
                const e = try self.lightOf(job.cx, job.cz);
                head.light_hash = e.light_hash;
                return protocol.encodeResult(self.allocator, id, head, .none);
            },
            .mesh => {
                // The 3×3 lights first: each light can generate 3×3
                // blocks. The cache holds each entry until the end of the
                // message (enforceLimit), so the pointers stay valid.
                var lights: [SLOTS]*Entry = undefined;
                for (0..SLOTS) |s| {
                    const dcx, const dcz = stages.offsetOf(s);
                    lights[s] = try self.lightOf(job.cx + dcx, job.cz + dcz);
                }
                var hood: stages.Neighbourhood = undefined;
                for (lights, 0..) |e, s| hood[s] = .{ .blocks = &e.blocks, .light = &e.light.? };
                var m = try lod.mesh(self.allocator, &hood, job.cx, job.cz, job.lod, .{
                    .ao = job.ao,
                    .lighting = job.lighting,
                    .smooth_light = job.smooth_light,
                });
                defer m.deinit(self.allocator);
                head.y_min = m.y_min;
                head.y_max = m.y_max;
                head.sections = m.sections;
                head.ranges = m.ranges;
                return protocol.encodeResult(self.allocator, id, head, .{ .mesh = .{ .quads = m.quads, .fluid = m.fluid } });
            },
        }
    }

    // -- Cache ----------------------------------------------------------------

    /// The cache entry of chunk (cx, cz), with its blocks. On a miss, it
    /// generates the chunk and applies its edits in order (P2).
    pub fn blocksOf(self: *WorkerWorld, cx: i32, cz: i32) !*Entry {
        const key: Key = .{ .cx = cx, .cz = cz };
        if (self.cache.get(key)) |e| {
            self.stats.hits += 1;
            self.touch(e);
            return e;
        }
        self.stats.misses += 1;
        self.stats.generated += 1;
        const config = self.config.?;
        var blocks = try stages.generate(self.allocator, config.seed, config, cx, cz);
        errdefer blocks.deinit(self.allocator);
        if (self.log.getPtr(key)) |l| {
            for (l.edits.items) |e| try blocks.setAt(self.allocator, e.x, e.y, e.z, e.block);
        }
        const entry = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(entry);
        entry.* = .{ .key = key, .blocks = blocks };
        try self.cache.put(self.allocator, key, entry);
        self.pushNewest(entry);
        self.recount(entry);
        return entry;
    }

    /// The cache entry of chunk (cx, cz), with the light of its blocks now.
    pub fn lightOf(self: *WorkerWorld, cx: i32, cz: i32) !*Entry {
        var window: stages.Window = undefined;
        var versions: [SLOTS]Version = undefined;
        for (0..SLOTS) |s| {
            const dcx, const dcz = stages.offsetOf(s);
            versions[s] = self.blockVersion(cx + dcx, cz + dcz);
        }
        const e = try self.blocksOf(cx, cz);
        if (e.light != null and std.mem.eql(Version, &e.light_inputs, &versions)) {
            self.stats.hits += 1;
            return e;
        }
        for (0..SLOTS) |s| {
            const dcx, const dcz = stages.offsetOf(s);
            window[s] = &(try self.blocksOf(cx + dcx, cz + dcz)).blocks;
        }
        if (self.scratch == null) self.scratch = try self.allocator.create(stages.LightScratch);
        var light = try stages.lightScratch(self.allocator, &window, self.scratch.?);
        errdefer light.deinit(self.allocator);
        self.dropLight(e);
        e.light = light;
        e.light_inputs = versions;
        e.light_hash = protocol.lightHash(&e.light.?);
        self.stats.lit += 1;
        self.recount(e);
        return e;
    }

    fn dropLight(self: *WorkerWorld, e: *Entry) void {
        if (e.light) |*l| l.deinit(self.allocator);
        e.light = null;
    }

    /// Count the bytes of `e` again.
    fn recount(self: *WorkerWorld, e: *Entry) void {
        self.bytes -= e.bytes;
        e.bytes = @sizeOf(Entry) + e.blocks.sizeBytes();
        if (e.light) |*l| e.bytes += l.sky.bytes() + l.block.bytes();
        self.bytes += e.bytes;
    }

    fn pushNewest(self: *WorkerWorld, e: *Entry) void {
        e.prev = null;
        e.next = self.newest;
        if (self.newest) |n| n.prev = e;
        self.newest = e;
        if (self.oldest == null) self.oldest = e;
    }

    fn unlink(self: *WorkerWorld, e: *Entry) void {
        if (e.prev) |p| p.next = e.next else self.newest = e.next;
        if (e.next) |n| n.prev = e.prev else self.oldest = e.prev;
        e.prev = null;
        e.next = null;
    }

    fn touch(self: *WorkerWorld, e: *Entry) void {
        if (self.newest == e) return;
        self.unlink(e);
        self.pushNewest(e);
    }

    fn destroyEntry(self: *WorkerWorld, e: *Entry) void {
        self.unlink(e);
        _ = self.cache.remove(e.key);
        self.bytes -= e.bytes;
        self.dropLight(e);
        e.blocks.deinit(self.allocator);
        self.allocator.destroy(e);
    }

    /// Remove the oldest entries until the cache is within its limit (C14).
    /// It runs at the end of each message. Thus a running job can go past
    /// the limit, by at most the 5×5 chunks that it reads.
    pub fn enforceLimit(self: *WorkerWorld) void {
        self.stats.peak_bytes = @max(self.stats.peak_bytes, self.bytes);
        while (self.bytes > self.cache_limit) {
            const e = self.oldest orelse break;
            self.destroyEntry(e);
            self.stats.evicted += 1;
        }
    }

    fn clearCache(self: *WorkerWorld) void {
        while (self.oldest) |e| self.destroyEntry(e);
        std.debug.assert(self.bytes == 0);
    }

    pub fn cachedChunks(self: *const WorkerWorld) usize {
        return self.cache.count();
    }
};
