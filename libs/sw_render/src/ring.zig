//! A uniform ring buffer: one GPU buffer for the per-draw uniforms of a
//! frame (REQ-GPU-006).
//!
//! Each `push` copies a value into a CPU copy of the buffer, at the next
//! offset that the GPU accepts for a dynamic offset (256 bytes). It gives
//! that offset to the draw: `setBindGroupWithOffsets`. `flush` sends all
//! values of the frame to the GPU with one `writeBuffer`. `reset` sets the
//! offset back to 0 for the next frame.
//!
//! The ring makes no buffer after `init`. `writeBuffer` goes into the queue
//! after the commands of the frames before it, so a new frame can write
//! over the bytes of the last frame.

const std = @import("std");
const gpu_mod = @import("sw_gpu");

/// The smallest dynamic offset step that every WebGPU device accepts
/// (`minUniformBufferOffsetAlignment`).
pub const offset_alignment: u32 = 256;

pub const Error = error{ RingFull, EmptyValue };

/// The offset arithmetic of the ring, with no GPU code.
pub const Cursor = struct {
    capacity: u32,
    used: u32 = 0,

    /// Reserve `size` bytes. Give the offset of the first byte. The offset
    /// is a multiple of `offset_alignment`.
    pub fn take(self: *Cursor, size: u32) Error!u32 {
        if (size == 0) return error.EmptyValue;
        const start = std.mem.alignForward(u32, self.used, offset_alignment);
        if (start > self.capacity or size > self.capacity - start) return error.RingFull;
        self.used = start + size;
        return start;
    }

    pub fn reset(self: *Cursor) void {
        self.used = 0;
    }
};

pub const UniformRing = struct {
    allocator: std.mem.Allocator,
    buffer: gpu_mod.Buffer,
    /// The CPU copy of the bytes of this frame.
    staging: []u8,
    cursor: Cursor,

    /// Make a ring of `capacity` bytes. The capacity rounds up to a multiple
    /// of `offset_alignment`.
    pub fn init(allocator: std.mem.Allocator, gpu: *gpu_mod.GPU, capacity: u32) !UniformRing {
        const size = std.mem.alignForward(u32, @max(capacity, offset_alignment), offset_alignment);
        const staging = try allocator.alloc(u8, size);
        errdefer allocator.free(staging);
        @memset(staging, 0);
        const buffer = try gpu.createBuffer(.{
            .label = "sw_render uniform ring",
            .size = size,
            .usage = .{ .uniform = true, .copy_dst = true },
        });
        return .{ .allocator = allocator, .buffer = buffer, .staging = staging, .cursor = .{ .capacity = size } };
    }

    pub fn deinit(self: *UniformRing) void {
        self.buffer.destroy();
        self.allocator.free(self.staging);
        self.* = undefined;
    }

    /// Copy the bytes of `value` into the ring. Give the dynamic offset of
    /// the value. Push only between `reset` and `flush`.
    pub fn push(self: *UniformRing, value: anytype) Error!u32 {
        return self.pushBytes(std.mem.asBytes(&value));
    }

    pub fn pushBytes(self: *UniformRing, bytes: []const u8) Error!u32 {
        const offset = try self.cursor.take(@intCast(bytes.len));
        @memcpy(self.staging[offset..][0..bytes.len], bytes);
        return offset;
    }

    /// Set the offset back to 0 for a new frame.
    pub fn reset(self: *UniformRing) void {
        self.cursor.reset();
    }

    /// Send the bytes of this frame to the GPU: one `writeBuffer`. `sink`
    /// is the `*GPU`, or a test double with the same `writeBuffer`.
    pub fn flush(self: *UniformRing, sink: anytype) void {
        if (self.cursor.used == 0) return;
        // writeBuffer needs a size that is a multiple of 4.
        const size = std.mem.alignForward(u32, self.cursor.used, 4);
        sink.writeBuffer(self.buffer, 0, self.staging[0..size]);
    }

    /// The bind group layout entry of a ring binding. `min_size` is the
    /// size of the struct that the shader reads.
    pub fn layoutEntry(binding: u32, visibility: gpu_mod.ShaderStage, min_size: u64) gpu_mod.BindGroupLayoutEntry {
        return .{
            .binding = binding,
            .visibility = visibility,
            .buffer = .{ .type = .uniform, .has_dynamic_offset = true, .min_binding_size = min_size },
        };
    }

    /// The bind group entry of a ring binding. `size` is the size of the
    /// struct that the shader reads. `self` must not move during the
    /// `createBindGroup` call.
    pub fn bindGroupEntry(self: *UniformRing, binding: u32, size: u64) gpu_mod.BindGroupEntry {
        return .{ .binding = binding, .buffer = &self.buffer, .offset = 0, .size = size };
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "ring: offsets are aligned for dynamic offsets (REQ-GPU-006)" {
    var c: Cursor = .{ .capacity = 1024 };
    try testing.expectEqual(@as(u32, 0), try c.take(64));
    try testing.expectEqual(@as(u32, 256), try c.take(4));
    try testing.expectEqual(@as(u32, 512), try c.take(256));
    try testing.expectEqual(@as(u32, 768), try c.take(256));
    // The ring is full.
    try testing.expectError(error.RingFull, c.take(1));
    try testing.expectError(error.EmptyValue, c.take(0));
    // A new frame starts at offset 0 in the same capacity.
    c.reset();
    try testing.expectEqual(@as(u32, 0), try c.take(1024));
    try testing.expectError(error.RingFull, c.take(4));
    // A value larger than the ring.
    c.reset();
    try testing.expectError(error.RingFull, c.take(1025));
}

const FakeGpu = struct {
    writes: u32 = 0,
    last: []const u8 = &.{},

    pub fn writeBuffer(self: *FakeGpu, buffer: gpu_mod.Buffer, offset: u64, data: []const u8) void {
        _ = buffer;
        std.debug.assert(offset == 0);
        self.writes += 1;
        self.last = data;
    }
};

test "ring: one write for each frame, and no new memory after init (REQ-GPU-006)" {
    var staging: [1024]u8 = @splat(0);
    var ring: UniformRing = .{
        .allocator = testing.failing_allocator,
        .buffer = undefined,
        .staging = &staging,
        .cursor = .{ .capacity = staging.len },
    };
    var fake: FakeGpu = .{};

    var frame: u32 = 0;
    while (frame < 3) : (frame += 1) {
        ring.reset();
        const a = try ring.push(@as([4]u32, @splat(frame)));
        const b = try ring.push(@as([2]f32, .{ 1.0, 2.0 }));
        try testing.expectEqual(@as(u32, 0), a);
        try testing.expectEqual(@as(u32, 256), b);
        ring.flush(&fake);
        try testing.expectEqual(frame + 1, fake.writes);
        try testing.expectEqual(@as(usize, 264), fake.last.len);
        try testing.expectEqual(frame, std.mem.bytesToValue(u32, fake.last[0..4]));
        try testing.expectEqual(@as(f32, 2.0), std.mem.bytesToValue(f32, fake.last[260..264]));
    }

    // An empty frame sends nothing.
    ring.reset();
    ring.flush(&fake);
    try testing.expectEqual(@as(u32, 3), fake.writes);
}
