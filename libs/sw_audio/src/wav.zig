//! WAV (RIFF WAVE) decoding to a `Sample`. Integer PCM of 8, 16, 24 or 32
//! bits and IEEE float of 32 or 64 bits, also in the extensible format.
//! Data with more than two channels gives its first two.

const std = @import("std");
const Sample = @import("sample.zig").Sample;

pub const Error = error{ InvalidWav, UnsupportedWav, OutOfMemory };

const format_pcm = 1;
const format_float = 3;
const format_extensible = 0xFFFE;

const Format = struct {
    tag: u16,
    channels: u16,
    rate: u32,
    bits: u16,
    block_align: u16,
};

pub fn decodeWav(allocator: std.mem.Allocator, bytes: []const u8) Error!Sample {
    if (bytes.len < 12) return error.InvalidWav;
    if (!std.mem.eql(u8, bytes[0..4], "RIFF") or !std.mem.eql(u8, bytes[8..12], "WAVE")) return error.InvalidWav;

    var format: ?Format = null;
    var data: ?[]const u8 = null;
    var pos: usize = 12;
    while (pos + 8 <= bytes.len) {
        const id = bytes[pos..][0..4];
        const size = std.mem.readInt(u32, bytes[pos + 4 ..][0..4], .little);
        const body_start = pos + 8;
        // A writer that did not know the length of the data can leave a
        // size that is too large. Use the bytes that exist.
        const body_end = @min(bytes.len, body_start +| size);
        const body = bytes[body_start..body_end];
        if (std.mem.eql(u8, id, "fmt ")) {
            if (body.len < 16) return error.InvalidWav;
            var tag = std.mem.readInt(u16, body[0..2], .little);
            if (tag == format_extensible) {
                // The first two bytes of the sub-format GUID are the tag.
                if (body.len < 26) return error.InvalidWav;
                tag = std.mem.readInt(u16, body[24..26], .little);
            }
            format = .{
                .tag = tag,
                .channels = std.mem.readInt(u16, body[2..4], .little),
                .rate = std.mem.readInt(u32, body[4..8], .little),
                .block_align = std.mem.readInt(u16, body[12..14], .little),
                .bits = std.mem.readInt(u16, body[14..16], .little),
            };
        } else if (std.mem.eql(u8, id, "data")) {
            data = body;
        }
        // Chunks have an even size. An odd size has one pad byte.
        pos = body_start +| size +| (size & 1);
    }

    const f = format orelse return error.InvalidWav;
    const pcm = data orelse return error.InvalidWav;
    if (f.channels == 0 or f.rate == 0) return error.InvalidWav;
    const bytes_per_value: usize = switch (f.tag) {
        format_pcm => switch (f.bits) {
            8, 16, 24, 32 => f.bits / 8,
            else => return error.UnsupportedWav,
        },
        format_float => switch (f.bits) {
            32, 64 => f.bits / 8,
            else => return error.UnsupportedWav,
        },
        else => return error.UnsupportedWav,
    };
    const stride = @max(@as(usize, f.block_align), bytes_per_value * f.channels);
    const frames = pcm.len / stride;
    if (frames == 0) return error.InvalidWav;
    const out_channels: u8 = @intCast(@min(f.channels, 2));

    const out = try allocator.alloc(f32, frames * out_channels);
    errdefer allocator.free(out);
    for (0..frames) |i| {
        for (0..out_channels) |c| {
            const v = pcm[i * stride + c * bytes_per_value ..][0..bytes_per_value];
            out[i * out_channels + c] = value(f.tag, f.bits, v);
        }
    }
    return .{ .data = out, .channels = out_channels, .rate = f.rate };
}

/// One value as a float from -1 to 1.
fn value(tag: u16, bits: u16, v: []const u8) f32 {
    if (tag == format_float) {
        if (bits == 32) return @bitCast(std.mem.readInt(u32, v[0..4], .little));
        return @floatCast(@as(f64, @bitCast(std.mem.readInt(u64, v[0..8], .little))));
    }
    return switch (bits) {
        // 8-bit WAV is unsigned, with 128 as zero.
        8 => (@as(f32, @floatFromInt(v[0])) - 128.0) / 128.0,
        16 => @as(f32, @floatFromInt(std.mem.readInt(i16, v[0..2], .little))) / 32768.0,
        24 => @as(f32, @floatFromInt(std.mem.readInt(i24, v[0..3], .little))) / 8388608.0,
        else => @as(f32, @floatFromInt(std.mem.readInt(i32, v[0..4], .little))) / 2147483648.0,
    };
}

/// Make a WAV file in `buf` for the tests.
fn testWav(buf: []u8, tag: u16, channels: u16, rate: u32, bits: u16, pcm: []const u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    const block: u16 = channels * (bits / 8);
    w.writeAll("RIFF") catch unreachable;
    w.writeInt(u32, @intCast(4 + 8 + 16 + 8 + 4 + 8 + pcm.len), .little) catch unreachable;
    w.writeAll("WAVE") catch unreachable;
    w.writeAll("fmt ") catch unreachable;
    w.writeInt(u32, 16, .little) catch unreachable;
    w.writeInt(u16, tag, .little) catch unreachable;
    w.writeInt(u16, channels, .little) catch unreachable;
    w.writeInt(u32, rate, .little) catch unreachable;
    w.writeInt(u32, rate * block, .little) catch unreachable;
    w.writeInt(u16, block, .little) catch unreachable;
    w.writeInt(u16, bits, .little) catch unreachable;
    // A chunk that the decoder must skip.
    w.writeAll("LIST") catch unreachable;
    w.writeInt(u32, 4, .little) catch unreachable;
    w.writeAll("INFO") catch unreachable;
    w.writeAll("data") catch unreachable;
    w.writeInt(u32, @intCast(pcm.len), .little) catch unreachable;
    w.writeAll(pcm) catch unreachable;
    return w.buffered();
}

test "decodeWav: 16-bit stereo" {
    var buf: [128]u8 = undefined;
    // Two frames: (16384, -32768), (0, 32767).
    const pcm = [_]u8{ 0x00, 0x40, 0x00, 0x80, 0x00, 0x00, 0xFF, 0x7F };
    var s = try decodeWav(std.testing.allocator, testWav(&buf, format_pcm, 2, 22050, 16, &pcm));
    defer s.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 2), s.channels);
    try std.testing.expectEqual(@as(u32, 22050), s.rate);
    try std.testing.expectEqual(@as(usize, 2), s.frames());
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), s.data[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -1), s.data[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), s.data[2], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), s.data[3], 1e-4);
}

test "decodeWav: 8-bit, 24-bit and float mono" {
    var buf: [128]u8 = undefined;
    {
        var s = try decodeWav(std.testing.allocator, testWav(&buf, format_pcm, 1, 8000, 8, &.{ 0, 128, 192 }));
        defer s.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(f32, &.{ -1, 0, 0.5 }, s.data);
    }
    {
        // -8388608 and 4194304.
        var s = try decodeWav(std.testing.allocator, testWav(&buf, format_pcm, 1, 8000, 24, &.{ 0x00, 0x00, 0x80, 0x00, 0x00, 0x40 }));
        defer s.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(f32, &.{ -1, 0.5 }, s.data);
    }
    {
        const v: f32 = -0.25;
        const pcm: [4]u8 = @bitCast(std.mem.nativeToLittle(u32, @bitCast(v)));
        var s = try decodeWav(std.testing.allocator, testWav(&buf, format_float, 1, 48000, 32, &pcm));
        defer s.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(f32, &.{-0.25}, s.data);
    }
}

test "decodeWav: more than two channels gives the first two" {
    var buf: [128]u8 = undefined;
    const pcm = [_]u8{ 0, 64, 255, 128 }; // one frame of four 8-bit channels
    var s = try decodeWav(std.testing.allocator, testWav(&buf, format_pcm, 4, 8000, 8, &pcm));
    defer s.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 2), s.channels);
    try std.testing.expectEqualSlices(f32, &.{ -1, -0.5 }, s.data);
}

test "decodeWav: bad data gives an error" {
    var buf: [128]u8 = undefined;
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidWav, decodeWav(a, "RIFF"));
    try std.testing.expectError(error.InvalidWav, decodeWav(a, "RIFF\x00\x00\x00\x00WAVEjunk"));
    try std.testing.expectError(error.UnsupportedWav, decodeWav(a, testWav(&buf, 2, 1, 8000, 4, &.{ 1, 2 })));
    try std.testing.expectError(error.UnsupportedWav, decodeWav(a, testWav(&buf, format_pcm, 1, 8000, 12, &.{ 1, 2 })));
    try std.testing.expectError(error.InvalidWav, decodeWav(a, testWav(&buf, format_pcm, 0, 8000, 16, &.{ 1, 2 })));
    // No complete frame.
    try std.testing.expectError(error.InvalidWav, decodeWav(a, testWav(&buf, format_pcm, 2, 8000, 16, &.{ 1, 2 })));
}
