//! PNG decoding to RGBA8 with stb_image (c/sw_stb.c, public domain or MIT).
//! The C code allocates through the Zig allocator that `decodePng` is given,
//! so it works on native and on freestanding wasm.

const std = @import("std");

extern fn sw_png_decode(data: [*]const u8, len: c_int, width: *c_int, height: *c_int) ?[*]u8;
extern fn sw_png_error() [*:0]const u8;
extern fn sw_png_free(pixels: ?[*]u8) void;
extern fn sw_png_set_allocator(
    alloc_fn: *const fn (usize) callconv(.c) ?*anyopaque,
    free_fn: *const fn (?*anyopaque) callconv(.c) void,
) void;

/// Decoded pixels: 4 bytes a texel (R, G, B, A), rows packed, top row first.
/// `pixels.len` is `width * height * 4`.
pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []u8,

    pub fn deinit(self: Image, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

pub const DecodeError = error{
    /// The bytes are not a valid PNG, or the image is larger than
    /// `max_dimension` on one side. `lastErrorMessage` gives the reason.
    InvalidPng,
    OutOfMemory,
};

/// The largest width or height `decodePng` accepts. It must match
/// STBI_MAX_DIMENSIONS in c/sw_stb.c.
pub const max_dimension = 8192;

// stb_image allocations carry a header with the size, so `free` needs no size.
// The header keeps the 16 byte alignment of the block.
const header_len = 16;

// The allocator of the decode in progress. A decode runs on one thread.
threadlocal var stb_allocator: ?std.mem.Allocator = null;
threadlocal var stb_out_of_memory = false;

fn stbAlloc(size: usize) callconv(.c) ?*anyopaque {
    const allocator = stb_allocator orelse return null;
    const total = std.math.add(usize, size, header_len) catch {
        stb_out_of_memory = true;
        return null;
    };
    const block = allocator.alignedAlloc(u8, .@"16", total) catch {
        stb_out_of_memory = true;
        return null;
    };
    const stored: *usize = @ptrCast(block.ptr);
    stored.* = size;
    return block.ptr + header_len;
}

fn stbFree(ptr: ?*anyopaque) callconv(.c) void {
    const allocator = stb_allocator orelse return;
    const p = ptr orelse return;
    const bytes: [*]u8 = @ptrCast(p);
    const base: [*]align(16) u8 = @alignCast(bytes - header_len);
    const stored: *const usize = @ptrCast(base);
    allocator.free(base[0 .. stored.* + header_len]);
}

/// Decode PNG `bytes` to RGBA8. The caller owns the result (`Image.deinit`).
/// Every PNG colour type and bit depth gives RGBA8. 16 bit channels are
/// reduced to 8 bit.
pub fn decodePng(allocator: std.mem.Allocator, bytes: []const u8) DecodeError!Image {
    if (bytes.len == 0 or bytes.len > std.math.maxInt(c_int)) return error.InvalidPng;

    sw_png_set_allocator(&stbAlloc, &stbFree);
    stb_allocator = allocator;
    stb_out_of_memory = false;
    defer stb_allocator = null;

    var width: c_int = 0;
    var height: c_int = 0;
    const decoded = sw_png_decode(bytes.ptr, @intCast(bytes.len), &width, &height) orelse {
        return if (stb_out_of_memory) error.OutOfMemory else error.InvalidPng;
    };
    defer sw_png_free(decoded);
    if (width <= 0 or height <= 0) return error.InvalidPng;

    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const pixels = try allocator.alloc(u8, w * h * 4);
    @memcpy(pixels, decoded[0 .. w * h * 4]);
    return .{ .width = @intCast(w), .height = @intCast(h), .pixels = pixels };
}

/// The reason for the last failed `decodePng`. It is valid until the next
/// decode and is not thread safe.
pub fn lastErrorMessage() []const u8 {
    return std.mem.span(sw_png_error());
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// A 2x2 RGBA PNG made for these tests: red, green / blue, half-transparent
/// white.
const test_png = [_]u8{
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x08, 0x06, 0x00, 0x00, 0x00, 0x72, 0xb6, 0x0d,
    0x24, 0x00, 0x00, 0x00, 0x13, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0xf8, 0xcf, 0xc0, 0xf0,
    0x1f, 0x0c, 0x81, 0x34, 0x08, 0x34, 0x00, 0x00, 0x49, 0x49, 0x09, 0x78, 0x9c, 0x51, 0x17, 0x92,
    0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
};

test "decodePng: size and pixels" {
    const a = std.testing.allocator;
    const image = try decodePng(a, &test_png);
    defer image.deinit(a);

    try std.testing.expectEqual(@as(u32, 2), image.width);
    try std.testing.expectEqual(@as(u32, 2), image.height);
    try std.testing.expectEqualSlices(u8, &.{
        255, 0,   0,   255,
        0,   255, 0,   255,
        0,   0,   255, 255,
        255, 255, 255, 128,
    }, image.pixels);
}

test "decodePng: bytes that are not a PNG return an error" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidPng, decodePng(a, ""));
    try std.testing.expectError(error.InvalidPng, decodePng(a, "this is not a png at all"));
    try std.testing.expect(lastErrorMessage().len > 0);
    // A PNG cut in the middle of its data.
    try std.testing.expectError(error.InvalidPng, decodePng(a, test_png[0..40]));
}

test "decodePng: an allocation failure returns OutOfMemory and frees everything" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, decodePng(failing.allocator(), &test_png));

    // Fail on each later allocation in turn. The testing allocator reports
    // any leak.
    var index: usize = 1;
    while (index < 8) : (index += 1) {
        var f = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = index });
        if (decodePng(f.allocator(), &test_png)) |image| {
            image.deinit(f.allocator());
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
    }
}
