//! `PassTimer`: GPU time of each frame graph pass, from timestamp queries
//! (REQ-GPU-028).
//!
//! Each render pass writes a timestamp at its start and its end. After the
//! passes, the graph copies the timestamps to a buffer that the CPU can
//! read. After the submit, `collect` waits for the GPU and reads them.
//! The wait stops the CPU until the GPU completes the frame, so use the
//! timer for a debug overlay, not in each frame of a release build.
//!
//! The timer needs the timestamp feature of the device. `init` gives
//! `error.TimestampsNotSupported` when the device does not have it, and
//! on the web.
//!
//! ```zig
//! var timer = try render.PassTimer.init(gpu, .{});
//! graph.setTimer(&timer);
//! // After graph.execute:
//! for (timer.times()) |t| std.log.info("{s}: {d:.3} ms", .{ t.name, t.ms });
//! ```
const std = @import("std");
const gpu_mod = @import("sw_gpu");
const pacing = @import("frame_pacing.zig");

pub const PassTime = struct {
    name: []const u8,
    ms: f32,
};

pub const Options = struct {
    /// The most passes that one frame times.
    max_passes: u32 = 32,
    /// The length of one timestamp tick in ns. wgpu-native does not give
    /// the period of the queue. It is 1 on most desktop drivers.
    period_ns: f32 = 1,
};

pub const PassTimer = struct {
    gpu: *gpu_mod.GPU,
    options: Options,
    query_set: gpu_mod.QuerySet,
    resolve_buffer: gpu_mod.Buffer,
    read_buffer: gpu_mod.Buffer,
    names: [][]const u8,
    ticks: []u64,
    results: []PassTime,
    allocator: std.mem.Allocator,
    /// The passes that write timestamps in the frame that records now.
    count: u32 = 0,
    /// The passes of the last `collect`.
    result_count: u32 = 0,
    /// The frame recorded timestamps and `collect` did not read them.
    pending: bool = false,

    pub fn init(allocator: std.mem.Allocator, gpu: *gpu_mod.GPU, options: Options) !PassTimer {
        if (!gpu.supportsTimestamps()) return error.TimestampsNotSupported;
        if (options.max_passes == 0) return error.NoPasses;
        const queries = options.max_passes * 2;
        const query_set = try gpu.createTimestampQuerySet(queries);
        errdefer query_set.destroy();
        const size = @as(u64, queries) * @sizeOf(u64);
        var resolve_buffer = try gpu.createBuffer(.{
            .label = "sw_render pass timer resolve",
            .size = size,
            .usage = .{ .query_resolve = true, .copy_src = true },
        });
        errdefer resolve_buffer.destroy();
        var read_buffer = try gpu.createBuffer(.{
            .label = "sw_render pass timer read",
            .size = size,
            .usage = .{ .map_read = true, .copy_dst = true },
        });
        errdefer read_buffer.destroy();
        const names = try allocator.alloc([]const u8, options.max_passes);
        errdefer allocator.free(names);
        const ticks = try allocator.alloc(u64, queries);
        errdefer allocator.free(ticks);
        const results = try allocator.alloc(PassTime, options.max_passes);
        return .{
            .gpu = gpu,
            .options = options,
            .query_set = query_set,
            .resolve_buffer = resolve_buffer,
            .read_buffer = read_buffer,
            .names = names,
            .ticks = ticks,
            .results = results,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PassTimer) void {
        self.query_set.destroy();
        self.resolve_buffer.destroy();
        self.read_buffer.destroy();
        self.allocator.free(self.names);
        self.allocator.free(self.ticks);
        self.allocator.free(self.results);
        self.* = undefined;
    }

    /// Start a frame. The frame graph calls it.
    pub fn begin(self: *PassTimer) void {
        self.count = 0;
        self.pending = false;
    }

    /// The timestamp writes of the next pass, or null when the frame
    /// times `max_passes` passes already. The frame graph calls it. The
    /// name must stay valid until the next `begin`.
    pub fn writes(self: *PassTimer, name: []const u8) ?gpu_mod.RenderPassTimestampWrites {
        if (self.count >= self.options.max_passes) return null;
        const i = self.count;
        self.names[i] = name;
        self.count += 1;
        return .{ .query_set = self.query_set, .begin_index = i * 2, .end_index = i * 2 + 1 };
    }

    /// Record the copy of the timestamps of this frame. The frame graph
    /// calls it after the last pass.
    pub fn resolve(self: *PassTimer, encoder: gpu_mod.CommandEncoder) void {
        if (self.count == 0) return;
        const n = self.count * 2;
        encoder.resolveQuerySet(self.query_set, 0, n, self.resolve_buffer, 0);
        encoder.copyBufferToBuffer(self.resolve_buffer, 0, self.read_buffer, 0, @as(u64, n) * @sizeOf(u64));
        self.pending = true;
    }

    /// Read the timestamps of the submitted frame. The frame graph calls
    /// it after the submit. It waits for the GPU.
    pub fn collect(self: *PassTimer) !void {
        if (!self.pending) return;
        self.pending = false;
        const n = self.count * 2;
        try self.gpu.readBuffer(self.read_buffer, 0, std.mem.sliceAsBytes(self.ticks[0..n]));
        for (0..self.count) |i| {
            self.results[i] = .{
                .name = self.names[i],
                .ms = pacing.timestampMs(self.ticks[i * 2], self.ticks[i * 2 + 1], self.options.period_ns),
            };
        }
        self.result_count = self.count;
    }

    /// The pass times of the last collected frame, in the order the
    /// passes ran.
    pub fn times(self: *const PassTimer) []const PassTime {
        return self.results[0..self.result_count];
    }

    /// The time of the pass `name` in the last collected frame.
    pub fn find(self: *const PassTimer, name: []const u8) ?f32 {
        for (self.times()) |t| {
            if (std.mem.eql(u8, t.name, name)) return t.ms;
        }
        return null;
    }

    /// The sum of the pass times of the last collected frame.
    pub fn total(self: *const PassTimer) f32 {
        var sum: f32 = 0;
        for (self.times()) |t| sum += t.ms;
        return sum;
    }
};
