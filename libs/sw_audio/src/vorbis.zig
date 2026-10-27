//! Ogg Vorbis: a full decode to a `Sample`, and a `Stream` that decodes a
//! small window at a time. The decoder is stb_vorbis (`c/sw_vorbis.c`). It
//! gets all its memory from one buffer that this file allocates, so it
//! makes no allocations while it decodes.

const std = @import("std");
const Sample = @import("sample.zig").Sample;

extern fn sw_vorbis_open(data: [*]const u8, len: c_int, memory: [*]u8, memory_len: c_int, err: *c_int) ?*anyopaque;
extern fn sw_vorbis_close(handle: *anyopaque) void;
extern fn sw_vorbis_channels(handle: *anyopaque) c_int;
extern fn sw_vorbis_rate(handle: *anyopaque) c_uint;
extern fn sw_vorbis_length(handle: *anyopaque) c_uint;
extern fn sw_vorbis_read(handle: *anyopaque, out: [*]f32, frames: c_int, channels: c_int) c_int;
extern fn sw_vorbis_rewind(handle: *anyopaque) c_int;

/// stb_vorbis error code for "the memory buffer is too small".
const err_out_of_memory = 3;
/// The first size of the decoder memory. stb_vorbis needs about 150 KB for
/// most files. `open` doubles the size until the decoder opens.
const first_memory = 256 * 1024;
const max_memory = 16 * 1024 * 1024;

pub const Error = error{ InvalidVorbis, OutOfMemory };

/// An open decoder and its memory.
const Decoder = struct {
    handle: *anyopaque,
    memory: []u8,
    /// The channels in the data (1 or more).
    source_channels: u8,
    /// The channels that this file gives: 1 or 2. Data with more than two
    /// channels gives its first two.
    channels: u8,
    rate: u32,

    fn open(allocator: std.mem.Allocator, bytes: []const u8) Error!Decoder {
        if (bytes.len < 4 or bytes.len > std.math.maxInt(c_int)) return error.InvalidVorbis;
        if (!std.mem.eql(u8, bytes[0..4], "OggS")) return error.InvalidVorbis;
        var size: usize = first_memory;
        while (size <= max_memory) : (size *= 2) {
            const memory = try allocator.alloc(u8, size);
            var err: c_int = 0;
            if (sw_vorbis_open(bytes.ptr, @intCast(bytes.len), memory.ptr, @intCast(memory.len), &err)) |handle| {
                const source_channels: u8 = @intCast(std.math.clamp(sw_vorbis_channels(handle), 1, 255));
                const rate = sw_vorbis_rate(handle);
                if (rate == 0) {
                    sw_vorbis_close(handle);
                    allocator.free(memory);
                    return error.InvalidVorbis;
                }
                return .{
                    .handle = handle,
                    .memory = memory,
                    .source_channels = source_channels,
                    .channels = @min(source_channels, 2),
                    .rate = rate,
                };
            }
            allocator.free(memory);
            if (err != err_out_of_memory) return error.InvalidVorbis;
        }
        return error.OutOfMemory;
    }

    fn close(self: *Decoder, allocator: std.mem.Allocator) void {
        sw_vorbis_close(self.handle);
        allocator.free(self.memory);
    }

    /// Decode up to `out.len / channels` frames into `out`. Returns the
    /// number of frames. 0 is the end of the data.
    fn read(self: *Decoder, out: []f32) usize {
        const frames = out.len / self.channels;
        if (frames == 0) return 0;
        const n = sw_vorbis_read(self.handle, out.ptr, @intCast(@min(frames, std.math.maxInt(c_int))), self.channels);
        return @intCast(@max(n, 0));
    }
};

/// Decode all of Ogg Vorbis `bytes` to a `Sample`. Use it for short sounds.
/// For long music, use `Stream`.
pub fn decodeVorbis(allocator: std.mem.Allocator, bytes: []const u8) Error!Sample {
    var decoder = try Decoder.open(allocator, bytes);
    defer decoder.close(allocator);
    var data: std.ArrayList(f32) = .empty;
    errdefer data.deinit(allocator);
    const length = sw_vorbis_length(decoder.handle);
    if (length > 0) try data.ensureTotalCapacity(allocator, @as(usize, length) * decoder.channels);
    var chunk: [4096]f32 = undefined;
    while (true) {
        const n = decoder.read(&chunk);
        if (n == 0) break;
        try data.appendSlice(allocator, chunk[0 .. n * decoder.channels]);
    }
    if (data.items.len == 0) return error.InvalidVorbis;
    return .{
        .data = try data.toOwnedSlice(allocator),
        .channels = decoder.channels,
        .rate = decoder.rate,
    };
}

/// Music from compressed Ogg Vorbis data. The stream decodes a small window
/// of frames at a time while it plays, and never decodes all of the data.
/// Its memory does not change with the length of the data.
///
/// One stream plays in one voice at a time. The compressed bytes must stay
/// valid until `deinit`.
pub const Stream = struct {
    allocator: std.mem.Allocator,
    decoder: Decoder,
    /// Decoded frames, interleaved, `decoder.channels` floats each.
    window: []f32,
    /// The frame index of the first frame in `window`.
    start: u64 = 0,
    /// The number of decoded frames in `window`.
    len: usize = 0,

    /// The frames in the decode window.
    pub const window_frames = 4096;

    pub fn open(allocator: std.mem.Allocator, bytes: []const u8) Error!*Stream {
        var decoder = try Decoder.open(allocator, bytes);
        errdefer decoder.close(allocator);
        const window = try allocator.alloc(f32, window_frames * @as(usize, decoder.channels));
        errdefer allocator.free(window);
        const self = try allocator.create(Stream);
        self.* = .{ .allocator = allocator, .decoder = decoder, .window = window };
        return self;
    }

    /// Stop the voice that plays the stream before this call.
    pub fn deinit(self: *Stream) void {
        const allocator = self.allocator;
        self.decoder.close(allocator);
        allocator.free(self.window);
        allocator.destroy(self);
    }

    pub fn channels(self: *const Stream) u8 {
        return self.decoder.channels;
    }

    pub fn rate(self: *const Stream) u32 {
        return self.decoder.rate;
    }

    /// The bytes that the stream owns: the decoder memory, the window and
    /// the `Stream` value.
    pub fn memoryBytes(self: *const Stream) usize {
        return self.decoder.memory.len + self.window.len * @sizeOf(f32) + @sizeOf(Stream);
    }

    /// Go back to the first frame.
    pub fn rewind(self: *Stream) void {
        _ = sw_vorbis_rewind(self.decoder.handle);
        self.start = 0;
        self.len = 0;
    }

    /// The left and right values of frame `index`, or null after the last
    /// frame. A mono stream gives the same value twice. `index` must not be
    /// less than the index of the last call, except after `rewind`.
    pub fn frame(self: *Stream, index: u64) ?[2]f32 {
        if (index < self.start) return null;
        while (index >= self.start + self.len) {
            if (!self.refill()) return null;
        }
        const i: usize = @intCast(index - self.start);
        const ch: usize = self.decoder.channels;
        const left = self.window[i * ch];
        return .{ left, if (ch == 2) self.window[i * ch + 1] else left };
    }

    /// Decode the next frames into the window. The last frame of the window
    /// stays as the first frame, so that a voice can interpolate between
    /// two frames across the edge of the window. Returns false at the end of
    /// the data.
    fn refill(self: *Stream) bool {
        const ch: usize = self.decoder.channels;
        var keep: usize = 0;
        if (self.len > 0) {
            std.mem.copyForwards(f32, self.window[0..ch], self.window[(self.len - 1) * ch ..][0..ch]);
            self.start += self.len - 1;
            keep = 1;
        }
        const n = self.decoder.read(self.window[keep * ch ..]);
        self.len = keep + n;
        return n > 0;
    }
};

const test_ogg = @embedFile("test_ogg");

/// The number of times that a channel crosses zero upward, a measure of its
/// frequency.
fn upCrossings(data: []const f32, ch: usize, channel: usize) usize {
    var count: usize = 0;
    var i: usize = channel + ch;
    while (i < data.len) : (i += ch) {
        if (data[i - ch] < 0 and data[i] >= 0) count += 1;
    }
    return count;
}

test "decodeVorbis: stereo test tone" {
    // testdata/tone.ogg: 1 s at 44100 Hz. Left 440 Hz, right 880 Hz.
    var s = try decodeVorbis(std.testing.allocator, test_ogg);
    defer s.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 2), s.channels);
    try std.testing.expectEqual(@as(u32, 44100), s.rate);
    try std.testing.expect(s.frames() >= 44000 and s.frames() <= 45000);
    const left = upCrossings(s.data, 2, 0);
    const right = upCrossings(s.data, 2, 1);
    try std.testing.expect(left >= 430 and left <= 450);
    try std.testing.expect(right >= 870 and right <= 890);
}

test "decodeVorbis: bad data gives an error" {
    try std.testing.expectError(error.InvalidVorbis, decodeVorbis(std.testing.allocator, "RIFF1234"));
    try std.testing.expectError(error.InvalidVorbis, decodeVorbis(std.testing.allocator, "OggS but not vorbis data"));
    // Data cut short after the headers.
    try std.testing.expectError(error.InvalidVorbis, decodeVorbis(std.testing.allocator, test_ogg[0..200]));
}

test "Stream: gives the same frames as the full decode" {
    var full = try decodeVorbis(std.testing.allocator, test_ogg);
    defer full.deinit(std.testing.allocator);
    const stream = try Stream.open(std.testing.allocator, test_ogg);
    defer stream.deinit();
    try std.testing.expectEqual(full.channels, stream.channels());
    var i: u64 = 0;
    while (stream.frame(i)) |f| : (i += 1) {
        try std.testing.expectEqual(full.data[i * 2], f[0]);
        try std.testing.expectEqual(full.data[i * 2 + 1], f[1]);
    }
    try std.testing.expectEqual(@as(u64, full.frames()), i);
    // After the end, rewind gives the first frame again.
    stream.rewind();
    const first = stream.frame(0).?;
    try std.testing.expectEqual(full.data[0], first[0]);
}

// REQ-AUDIO-002: a stream does not decode all of the data.
test "Stream: memory does not grow with the length of the data" {
    var counting = CountingAllocator{ .child = std.testing.allocator };
    const allocator = counting.allocator();
    const stream = try Stream.open(allocator, test_ogg);
    defer stream.deinit();
    const after_open = counting.peak;
    var i: u64 = 0;
    while (stream.frame(i)) |_| : (i += 1) {}
    // Playing to the end allocates nothing more.
    try std.testing.expectEqual(after_open, counting.peak);
    // The window is smaller than the decoded data.
    try std.testing.expect(Stream.window_frames < i);
    try std.testing.expectEqual(stream.memoryBytes(), counting.live);
}

/// Counts the live bytes and the peak of an allocator, for the memory test.
const CountingAllocator = struct {
    child: std.mem.Allocator,
    live: usize = 0,
    peak: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn add(self: *CountingAllocator, n: usize) void {
        self.live += n;
        self.peak = @max(self.peak, self.live);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.child.rawAlloc(len, alignment, ra) orelse return null;
        self.add(len);
        return p;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(memory, alignment, new_len, ra)) return false;
        self.live -= memory.len;
        self.add(new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.child.rawRemap(memory, alignment, new_len, ra) orelse return null;
        self.live -= memory.len;
        self.add(new_len);
        return p;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ra);
        self.live -= memory.len;
    }
};
