//! Shelf packing for the glyph atlas: rectangles go left to right in a row, and
//! a new row starts under the tallest rectangle of the row above. This file has
//! no GPU code.

const std = @import("std");

pub const Pos = struct {
    x: u32,
    y: u32,
};

pub const Packer = struct {
    size: u32,
    x: u32 = 0,
    y: u32 = 0,
    row_height: u32 = 0,

    pub fn init(size: u32) Packer {
        return .{ .size = size };
    }

    /// Reserve a `w` by `h` rectangle. Returns its top left corner, or null if
    /// it does not fit in what is left.
    pub fn alloc(self: *Packer, w: u32, h: u32) ?Pos {
        if (w > self.size or h > self.size) return null;
        if (self.x + w > self.size) {
            self.y += self.row_height;
            self.x = 0;
            self.row_height = 0;
        }
        if (self.y + h > self.size) return null;
        const pos: Pos = .{ .x = self.x, .y = self.y };
        self.x += w;
        self.row_height = @max(self.row_height, h);
        return pos;
    }
};

const testing = std.testing;

test "rectangles go along a row" {
    var p = Packer.init(32);
    try testing.expectEqual(Pos{ .x = 0, .y = 0 }, p.alloc(10, 8).?);
    try testing.expectEqual(Pos{ .x = 10, .y = 0 }, p.alloc(10, 12).?);
}

test "a new row starts under the tallest rectangle" {
    var p = Packer.init(32);
    _ = p.alloc(10, 8).?;
    _ = p.alloc(10, 12).?;
    try testing.expectEqual(Pos{ .x = 0, .y = 12 }, p.alloc(20, 5).?);
}

test "a full atlas gives null" {
    var p = Packer.init(16);
    try testing.expect(p.alloc(16, 16) != null);
    try testing.expect(p.alloc(1, 1) == null);
}

test "a rectangle larger than the atlas gives null" {
    var p = Packer.init(16);
    try testing.expect(p.alloc(17, 4) == null);
    try testing.expect(p.alloc(4, 17) == null);
    try testing.expectEqual(Pos{ .x = 0, .y = 0 }, p.alloc(4, 4).?);
}

test "no two rectangles overlap" {
    var p = Packer.init(64);
    var placed: [20]struct { pos: Pos, w: u32, h: u32 } = undefined;
    var n: usize = 0;
    var i: u32 = 0;
    while (i < placed.len) : (i += 1) {
        const w = 5 + (i * 7) % 13;
        const h = 4 + (i * 5) % 11;
        const pos = p.alloc(w, h) orelse break;
        try testing.expect(pos.x + w <= 64 and pos.y + h <= 64);
        for (placed[0..n]) |other| {
            const apart = pos.x + w <= other.pos.x or other.pos.x + other.w <= pos.x or
                pos.y + h <= other.pos.y or other.pos.y + other.h <= pos.y;
            try testing.expect(apart);
        }
        placed[n] = .{ .pos = pos, .w = w, .h = h };
        n += 1;
    }
    try testing.expect(n > 5);
}
