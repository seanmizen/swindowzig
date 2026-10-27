//! Staged buffer uploads: the per-frame writes to GPU buffers go into one
//! CPU arena, and `flush` sends them before the submit (REQ-GPU-006).
//!
//! Writes that touch, in the same buffer, merge into one `writeBuffer`
//! call. On the web, each `writeBuffer` is a call into JavaScript, so a
//! frame of many small writes becomes a few calls. The arena keeps its
//! memory between frames, so a frame makes no new allocation and no new
//! GPU buffer after the first frames.

const std = @import("std");
const gpu_mod = @import("sw_gpu");

pub const Error = error{Unaligned} || std.mem.Allocator.Error;

const Write = struct {
    buffer: gpu_mod.Buffer,
    offset: u64,
    /// The first byte in `Uploads.bytes`.
    start: usize,
    len: usize,
};

pub const Uploads = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    writes: std.ArrayList(Write) = .empty,

    pub fn init(allocator: std.mem.Allocator) Uploads {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Uploads) void {
        self.bytes.deinit(self.allocator);
        self.writes.deinit(self.allocator);
        self.* = undefined;
    }

    /// Copy `data` into the arena, for `buffer` at `offset`. The buffer
    /// needs `copy_dst` usage. WebGPU needs an `offset` and a length that
    /// are multiples of 4. The caller can free `data` after the call. A
    /// later write to the same bytes wins.
    pub fn write(self: *Uploads, buffer: gpu_mod.Buffer, offset: u64, data: []const u8) Error!void {
        if (offset % 4 != 0 or data.len % 4 != 0) return error.Unaligned;
        if (data.len == 0) return;
        const start = self.bytes.items.len;
        try self.bytes.appendSlice(self.allocator, data);
        if (self.writes.items.len > 0) {
            const last = &self.writes.items[self.writes.items.len - 1];
            if (last.buffer.handle == buffer.handle and last.offset + last.len == offset and last.start + last.len == start) {
                last.len += data.len;
                return;
            }
        }
        self.writes.append(self.allocator, .{ .buffer = buffer, .offset = offset, .start = start, .len = data.len }) catch |err| {
            self.bytes.shrinkRetainingCapacity(start);
            return err;
        };
    }

    /// `write` for the bytes of one value.
    pub fn writeValue(self: *Uploads, buffer: gpu_mod.Buffer, offset: u64, value: anytype) Error!void {
        return self.write(buffer, offset, std.mem.asBytes(&value));
    }

    /// The number of `writeBuffer` calls that `flush` makes now.
    pub fn pending(self: *const Uploads) usize {
        return self.writes.items.len;
    }

    /// Send each write in the sequence of the `write` calls, then clear
    /// the arena. `sink` is the `*GPU`, or a test double with the same
    /// `writeBuffer`. Call it before the submit of the frame.
    pub fn flush(self: *Uploads, sink: anytype) void {
        for (self.writes.items) |w| {
            sink.writeBuffer(w.buffer, w.offset, self.bytes.items[w.start..][0..w.len]);
        }
        self.bytes.clearRetainingCapacity();
        self.writes.clearRetainingCapacity();
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

/// Two fake GPU buffers of 64 bytes, and the count of `writeBuffer` calls.
const FakeGpu = struct {
    memory: [2][64]u8 = @splat(@splat(0)),
    calls: u32 = 0,

    pub fn writeBuffer(self: *FakeGpu, buffer: gpu_mod.Buffer, offset: u64, data: []const u8) void {
        const i = bufferIndex(buffer);
        @memcpy(self.memory[i][offset..][0..data.len], data);
        self.calls += 1;
    }
};

fn fakeBuffer(i: usize) gpu_mod.Buffer {
    const T = @FieldType(gpu_mod.Buffer, "handle");
    return .{ .handle = switch (@typeInfo(T)) {
        .int => @intCast(i + 1),
        else => @ptrFromInt(0x1000 * (i + 1)),
    } };
}

fn bufferIndex(b: gpu_mod.Buffer) usize {
    const T = @FieldType(gpu_mod.Buffer, "handle");
    return switch (@typeInfo(T)) {
        .int => b.handle - 1,
        else => @intFromPtr(b.handle) / 0x1000 - 1,
    };
}

test "uploads: writes land at their offsets, in order, and the later write wins (REQ-GPU-006)" {
    var up = Uploads.init(testing.allocator);
    defer up.deinit();
    var fake: FakeGpu = .{};
    const a = fakeBuffer(0);
    const b = fakeBuffer(1);

    var expected: [2][64]u8 = @splat(@splat(0));
    const Plan = struct { buf: usize, offset: usize, len: usize, value: u8 };
    const plan = [_]Plan{
        .{ .buf = 0, .offset = 0, .len = 16, .value = 1 },
        .{ .buf = 0, .offset = 16, .len = 16, .value = 2 }, // touches the last: merges
        .{ .buf = 1, .offset = 8, .len = 8, .value = 3 },
        .{ .buf = 0, .offset = 8, .len = 16, .value = 4 }, // over the first two
        .{ .buf = 0, .offset = 60, .len = 4, .value = 5 },
    };
    var data: [64]u8 = undefined;
    for (plan) |p| {
        @memset(data[0..p.len], p.value);
        try up.write(if (p.buf == 0) a else b, p.offset, data[0..p.len]);
        @memset(expected[p.buf][p.offset..][0..p.len], p.value);
    }
    // The first two writes merge.
    try testing.expectEqual(@as(usize, 4), up.pending());
    up.flush(&fake);
    try testing.expectEqual(@as(u32, 4), fake.calls);
    try testing.expectEqualSlices(u8, &expected[0], &fake.memory[0]);
    try testing.expectEqualSlices(u8, &expected[1], &fake.memory[1]);
    try testing.expectEqual(@as(usize, 0), up.pending());
}

test "uploads: a frame after the first makes no new allocation (REQ-GPU-006)" {
    var up = Uploads.init(testing.allocator);
    defer up.deinit();
    var fake: FakeGpu = .{};
    const a = fakeBuffer(0);

    var frame: u8 = 0;
    var capacity: usize = 0;
    while (frame < 4) : (frame += 1) {
        try up.writeValue(a, 0, @as([4]u32, @splat(frame)));
        try up.writeValue(a, 32, @as(u32, frame));
        up.flush(&fake);
        if (frame == 0) capacity = up.bytes.capacity;
        try testing.expectEqual(capacity, up.bytes.capacity);
        try testing.expectEqual(@as(u32, frame), std.mem.bytesToValue(u32, fake.memory[0][32..36]));
    }
    try testing.expectEqual(@as(u32, 8), fake.calls);
}

test "uploads: offsets and sizes must be multiples of 4" {
    var up = Uploads.init(testing.allocator);
    defer up.deinit();
    try testing.expectError(error.Unaligned, up.write(fakeBuffer(0), 2, &.{ 0, 0, 0, 0 }));
    try testing.expectError(error.Unaligned, up.write(fakeBuffer(0), 0, &.{ 0, 0, 0 }));
    try up.write(fakeBuffer(0), 0, &.{});
    try testing.expectEqual(@as(usize, 0), up.pending());
}
