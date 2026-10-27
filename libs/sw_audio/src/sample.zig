//! Decoded sound: frames of 32-bit floats in memory.

const std = @import("std");

/// Decoded frames. `data` is interleaved: one float for a mono frame, left
/// then right for a stereo frame. Values are -1 to 1.
pub const Sample = struct {
    data: []f32,
    /// 1 (mono) or 2 (stereo).
    channels: u8,
    /// Frames each second.
    rate: u32,

    pub fn frames(self: Sample) usize {
        return self.data.len / self.channels;
    }

    /// The length in seconds.
    pub fn duration(self: Sample) f32 {
        return @as(f32, @floatFromInt(self.frames())) / @as(f32, @floatFromInt(self.rate));
    }

    /// The left and right values of frame `index`. A mono sample gives the
    /// same value twice.
    pub fn frame(self: Sample, index: usize) [2]f32 {
        if (self.channels == 1) return .{ self.data[index], self.data[index] };
        return .{ self.data[index * 2], self.data[index * 2 + 1] };
    }

    /// Free `data`. Use the allocator that decoded the sample.
    pub fn deinit(self: *Sample, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        self.* = undefined;
    }
};

test "Sample: frames, duration and frame values" {
    var data = [_]f32{ 0.1, 0.2, 0.3, 0.4 };
    const stereo = Sample{ .data = &data, .channels = 2, .rate = 2 };
    try std.testing.expectEqual(@as(usize, 2), stereo.frames());
    try std.testing.expectEqual(@as(f32, 1), stereo.duration());
    try std.testing.expectEqual([2]f32{ 0.3, 0.4 }, stereo.frame(1));
    const mono = Sample{ .data = &data, .channels = 1, .rate = 4 };
    try std.testing.expectEqual([2]f32{ 0.2, 0.2 }, mono.frame(1));
}
