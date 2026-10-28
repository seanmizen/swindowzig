//! Occlusion queries of boxes, with results that come back some frames
//! later (REQ-GPU-039). Native and web.
//!
//! Each frame:
//!
//!   1. `begin(gpu, view_proj, tag)` before the render pass. It gives false
//!      when each result buffer waits for the GPU. Then the frame has no
//!      box tests.
//!   2. Give `querySet()` to `RenderPassDescriptor.occlusion_query_set`.
//!   3. `add(min, max)` for each box. The index of the box is the index of
//!      its result.
//!   4. In the pass, after the draws that write the depth: `draw(gpu,
//!      pass)`. It draws each box in its own query, with the depth test on
//!      and no depth or colour write. Then set the pipeline of the game
//!      again.
//!   5. After the pass ends: `resolve(encoder)`.
//!   6. After the submit: `submitted(gpu)`. It starts the read of the
//!      results. It does not wait.
//!   7. `while (q.poll(gpu)) |r| ...`: the results of an earlier frame,
//!      with its tag. A sample count of 0 means that the depth test
//!      rejected each sample of the box.
//!
//! A box result is for the depth of its frame. When the camera or the
//! scene changes, the game decides if a result is still correct.
const std = @import("std");
const gpu_mod = @import("gpu.zig");
const types = @import("types.zig");
const plan = @import("occlusion_plan.zig");

const GPU = gpu_mod.GPU;
pub const Box = plan.Box;

pub const Options = struct {
    /// The most boxes in one frame. At most `GPU.MAX_QUERIES`.
    capacity: u32 = 1024,
    /// The formats and the sample count of the render pass of `draw`.
    color_format: types.TextureFormat,
    depth_format: types.TextureFormat,
    sample_count: u32 = 1,
    /// The frames of results that can wait for the GPU at one time.
    frames_in_flight: u32 = 3,
};

/// The results of one frame.
pub const Results = struct {
    /// The tag of `begin`.
    tag: u64,
    /// The sample count of each box, in the order of `add`. The slice is
    /// valid until the next `poll`.
    samples: []const u64,
};

const shader_source =
    \\struct Box { min: vec4<f32>, max: vec4<f32> };
    \\@group(0) @binding(0) var<uniform> view_proj: mat4x4<f32>;
    \\@group(0) @binding(1) var<storage, read> boxes: array<Box>;
    \\var<private> CORNERS: array<u32, 36> =
++ plan.box_corners_wgsl ++
    \\;
    \\
    \\@vertex fn vs_box(@builtin(vertex_index) vi: u32) -> @builtin(position) vec4<f32> {
    \\    let b = boxes[vi / 36u];
    \\    let c = CORNERS[vi % 36u];
    \\    let p = select(b.min.xyz, b.max.xyz, vec3<bool>((c & 1u) != 0u, (c & 2u) != 0u, (c & 4u) != 0u));
    \\    return view_proj * vec4<f32>(p, 1.0);
    \\}
    \\
    \\@fragment fn fs_box() -> @location(0) vec4<f32> {
    \\    return vec4<f32>(0.0);
    \\}
;

const Slot = struct {
    read: gpu_mod.BufferRead,
    tag: u64 = 0,
    count: u32 = 0,
    /// The frame resolved its results into this slot.
    resolved: bool = false,
};

pub const OcclusionQueries = struct {
    allocator: std.mem.Allocator,
    capacity: u32,
    query_set: gpu_mod.QuerySet,
    resolve_buffer: gpu_mod.Buffer,
    box_buffer: gpu_mod.Buffer,
    uniform_buffer: gpu_mod.Buffer,
    bind_group: gpu_mod.BindGroup,
    pipeline: gpu_mod.RenderPipeline,
    /// On the heap: a native map callback writes to its slot.
    slots: []Slot,
    boxes: []Box,
    samples: []u64,
    count: u32 = 0,
    /// The slot of the frame between `begin` and `submitted`.
    current: ?usize = null,
    tag: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, gpu: *GPU, options: Options) !OcclusionQueries {
        if (options.capacity == 0 or options.capacity > GPU.MAX_QUERIES) return error.BadQueryCount;
        if (options.frames_in_flight == 0) return error.BadFrameCount;
        const cap = options.capacity;
        const result_bytes: u64 = @as(u64, cap) * types.QUERY_RESULT_SIZE;

        const query_set = try gpu.createQuerySet(.{ .label = "sw_gpu_occlusion", .type = .occlusion, .count = cap });
        errdefer query_set.destroy();
        const resolve_buffer = try gpu.createBuffer(.{ .size = result_bytes, .usage = .{ .query_resolve = true, .copy_src = true } });
        errdefer resolve_buffer.destroy();
        var box_buffer = try gpu.createBuffer(.{ .size = @as(u64, cap) * @sizeOf(Box), .usage = .{ .storage = true, .copy_dst = true } });
        errdefer box_buffer.destroy();
        var uniform_buffer = try gpu.createBuffer(.{ .size = 64, .usage = .{ .uniform = true, .copy_dst = true } });
        errdefer uniform_buffer.destroy();

        var shader = try gpu.createShaderModule(.{ .label = "sw_gpu_occlusion", .code = shader_source });
        var bgl = try gpu.createBindGroupLayout(.{
            .label = "sw_gpu_occlusion_bgl",
            .entries = &[_]types.BindGroupLayoutEntry{
                .{ .binding = 0, .visibility = .{ .vertex = true }, .buffer = .{ .type = .uniform } },
                .{ .binding = 1, .visibility = .{ .vertex = true }, .buffer = .{ .type = .read_only_storage } },
            },
        });
        const bind_group = try gpu.createBindGroup(.{
            .layout = &bgl,
            .entries = &[_]gpu_mod.BindGroupEntry{
                .{ .binding = 0, .buffer = &uniform_buffer, .size = 64 },
                .{ .binding = 1, .buffer = &box_buffer, .size = @as(u64, cap) * @sizeOf(Box) },
            },
        });
        errdefer bind_group.release();
        var layout = try gpu.createPipelineLayout(.{
            .label = "sw_gpu_occlusion_layout",
            .bind_group_layouts = &[_]*gpu_mod.BindGroupLayout{&bgl},
        });
        const pipeline = try gpu.createRenderPipeline(.{
            .label = "sw_gpu_occlusion_pipeline",
            .layout = &layout,
            .vertex = .{ .module = &shader, .entry_point = "vs_box" },
            .fragment = .{
                .module = &shader,
                .entry_point = "fs_box",
                // No colour write: the box changes only the query.
                .targets = &[_]types.ColorTargetState{.{ .format = options.color_format, .write_mask = 0 }},
            },
            .primitive = .{ .topology = .triangle_list, .cull_mode = .none },
            .multisample = .{ .count = options.sample_count },
            .depth_stencil = .{
                .format = options.depth_format,
                .depth_write_enabled = false,
                .depth_compare = .less_equal,
                .stencil_read_mask = 0,
                .stencil_write_mask = 0,
            },
        });

        const slots = try allocator.alloc(Slot, options.frames_in_flight);
        errdefer allocator.free(slots);
        var made: usize = 0;
        errdefer for (slots[0..made]) |sl| sl.read.buffer.destroy();
        for (slots) |*sl| {
            const buf = try gpu.createBuffer(.{ .size = result_bytes, .usage = .{ .map_read = true, .copy_dst = true } });
            sl.* = .{ .read = .{ .buffer = buf, .size = result_bytes } };
            made += 1;
        }
        const boxes = try allocator.alloc(Box, cap);
        errdefer allocator.free(boxes);
        const samples = try allocator.alloc(u64, cap);
        return .{
            .allocator = allocator,
            .capacity = cap,
            .query_set = query_set,
            .resolve_buffer = resolve_buffer,
            .box_buffer = box_buffer,
            .uniform_buffer = uniform_buffer,
            .bind_group = bind_group,
            .pipeline = pipeline,
            .slots = slots,
            .boxes = boxes,
            .samples = samples,
        };
    }

    /// Wait for the GPU, then free each object.
    pub fn deinit(self: *OcclusionQueries, gpu: *GPU) void {
        gpu.waitIdle();
        for (self.slots) |*sl| {
            _ = sl.read.poll(gpu);
            sl.read.finish();
            sl.read.buffer.destroy();
        }
        // The buffer destroys can call the native map callbacks: wait
        // again before the slots go.
        gpu.waitIdle();
        self.allocator.free(self.slots);
        self.allocator.free(self.boxes);
        self.allocator.free(self.samples);
        self.bind_group.release();
        self.query_set.destroy();
        self.resolve_buffer.destroy();
        self.box_buffer.destroy();
        self.uniform_buffer.destroy();
        self.* = undefined;
    }

    /// Start a frame of box tests. False when no result buffer is free:
    /// then `add` gives null and the other calls do nothing. It cancels a
    /// frame that did not get to `submitted`.
    pub fn begin(self: *OcclusionQueries, gpu: *GPU, view_proj: [16]f32, tag: u64) bool {
        self.cancel();
        self.count = 0;
        for (self.slots, 0..) |*sl, i| {
            if (sl.resolved or sl.read.state != .idle) continue;
            self.current = i;
            self.tag = tag;
            gpu.writeBuffer(self.uniform_buffer, 0, std.mem.sliceAsBytes(&view_proj));
            return true;
        }
        return false;
    }

    /// The query set for `RenderPassDescriptor.occlusion_query_set`, or
    /// null when no frame is in progress.
    pub fn querySet(self: *const OcclusionQueries) ?gpu_mod.QuerySet {
        return if (self.current != null) self.query_set else null;
    }

    /// Add a box to the frame. Gives the index of its result, or null when
    /// the frame is full or did not begin.
    pub fn add(self: *OcclusionQueries, min: [3]f32, max: [3]f32) ?u32 {
        if (self.current == null or self.count >= self.capacity) return null;
        self.boxes[self.count] = Box.init(min, max);
        self.count += 1;
        return self.count - 1;
    }

    /// Draw each box in its own occlusion query. Call it in the pass that
    /// has `querySet()`, after the draws that write the depth. It changes
    /// the pipeline and bind group 0 of the pass.
    pub fn draw(self: *OcclusionQueries, gpu: *GPU, pass: gpu_mod.RenderPassEncoder) void {
        if (self.current == null or self.count == 0) return;
        gpu.writeBuffer(self.box_buffer, 0, std.mem.sliceAsBytes(self.boxes[0..self.count]));
        pass.setPipeline(self.pipeline);
        pass.setBindGroup(0, self.bind_group);
        for (0..self.count) |i| {
            pass.beginOcclusionQuery(@intCast(i));
            pass.draw(plan.BOX_VERTICES, 1, @as(u32, @intCast(i)) * plan.BOX_VERTICES, 0);
            pass.endOcclusionQuery();
        }
    }

    /// Copy the results of the frame to its result buffer. Call it after
    /// the pass ends.
    pub fn resolve(self: *OcclusionQueries, encoder: gpu_mod.CommandEncoder) void {
        const i = self.current orelse return;
        if (self.count == 0) return;
        const sl = &self.slots[i];
        const bytes = @as(u64, self.count) * types.QUERY_RESULT_SIZE;
        encoder.resolveQuerySet(self.query_set, 0, self.count, self.resolve_buffer, 0);
        encoder.copyBufferToBuffer(self.resolve_buffer, 0, sl.read.buffer, 0, bytes);
        sl.tag = self.tag;
        sl.count = self.count;
        sl.resolved = true;
    }

    /// End the frame. Call it after the submit of the frame: it starts the
    /// read of the results. A frame that did not resolve gives no results.
    pub fn submitted(self: *OcclusionQueries, gpu: *GPU) void {
        const i = self.current orelse return;
        self.current = null;
        const sl = &self.slots[i];
        if (!sl.resolved) return;
        sl.read.size = @as(u64, sl.count) * types.QUERY_RESULT_SIZE;
        sl.read.start(gpu);
    }

    /// End a frame with no submit. Its results are lost.
    pub fn cancel(self: *OcclusionQueries) void {
        const i = self.current orelse return;
        self.current = null;
        self.slots[i].resolved = false;
    }

    /// The results of the oldest frame that the GPU completed, or null. It
    /// does not wait.
    pub fn poll(self: *OcclusionQueries, gpu: *GPU) ?Results {
        var best: ?usize = null;
        for (self.slots, 0..) |*sl, i| {
            if (!sl.resolved or sl.read.state == .idle) continue;
            switch (sl.read.poll(gpu)) {
                .mapped => if (best == null or sl.tag < self.slots[best.?].tag) {
                    best = i;
                },
                .failed => {
                    sl.read.finish();
                    sl.resolved = false;
                },
                .pending, .idle => {},
            }
        }
        const i = best orelse return null;
        const sl = &self.slots[i];
        const out = self.samples[0..sl.count];
        sl.read.read(std.mem.sliceAsBytes(out)) catch {
            sl.read.finish();
            sl.resolved = false;
            return null;
        };
        sl.read.finish();
        sl.resolved = false;
        return .{ .tag = sl.tag, .samples = out };
    }
};
