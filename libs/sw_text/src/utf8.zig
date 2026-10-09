//! UTF-8 decoding. Bad input never stops the decoder: each bad sequence gives
//! U+FFFD (the replacement character) and the decoder goes on after it.

const std = @import("std");

pub const replacement: u21 = 0xFFFD;

pub const Decoded = struct {
    codepoint: u21,
    /// Bytes used, 1 to 4. At least 1, so a loop always makes progress.
    len: usize,
};

/// Decode the first code point of `bytes`. `bytes` must not be empty.
/// Overlong forms, surrogates, values above U+10FFFF and cut-off sequences
/// give U+FFFD. A bad sequence uses the bytes up to the first bad byte.
pub fn decode(bytes: []const u8) Decoded {
    std.debug.assert(bytes.len > 0);
    const b0: u32 = bytes[0];
    if (b0 < 0x80) return .{ .codepoint = @intCast(b0), .len = 1 };

    var follow: usize = undefined;
    var value: u32 = undefined;
    var smallest: u32 = undefined;
    if (b0 >= 0xC2 and b0 <= 0xDF) {
        follow = 1;
        value = b0 & 0x1F;
        smallest = 0x80;
    } else if (b0 >= 0xE0 and b0 <= 0xEF) {
        follow = 2;
        value = b0 & 0x0F;
        smallest = 0x800;
    } else if (b0 >= 0xF0 and b0 <= 0xF4) {
        follow = 3;
        value = b0 & 0x07;
        smallest = 0x10000;
    } else {
        return .{ .codepoint = replacement, .len = 1 };
    }

    var i: usize = 1;
    while (i <= follow) : (i += 1) {
        if (i >= bytes.len or (bytes[i] & 0xC0) != 0x80) {
            return .{ .codepoint = replacement, .len = i };
        }
        value = (value << 6) | (bytes[i] & 0x3F);
    }
    const surrogate = value >= 0xD800 and value <= 0xDFFF;
    if (value < smallest or value > 0x10FFFF or surrogate) {
        return .{ .codepoint = replacement, .len = follow + 1 };
    }
    return .{ .codepoint = @intCast(value), .len = follow + 1 };
}

pub const Item = struct {
    codepoint: u21,
    /// Byte offset of the code point in the input.
    start: usize,
    len: usize,
};

/// Walk the code points of a string.
pub const Iterator = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn init(bytes: []const u8) Iterator {
        return .{ .bytes = bytes };
    }

    pub fn next(self: *Iterator) ?Item {
        if (self.pos >= self.bytes.len) return null;
        const d = decode(self.bytes[self.pos..]);
        const item: Item = .{ .codepoint = d.codepoint, .start = self.pos, .len = d.len };
        self.pos += d.len;
        return item;
    }
};

const testing = std.testing;

test "ASCII is one byte" {
    const d = decode("A");
    try testing.expectEqual(@as(u21, 'A'), d.codepoint);
    try testing.expectEqual(@as(usize, 1), d.len);
}

test "two-byte sequences give Latin-1 and Latin Extended-A" {
    const e_acute = decode("\xC3\xA9");
    try testing.expectEqual(@as(u21, 0xE9), e_acute.codepoint);
    try testing.expectEqual(@as(usize, 2), e_acute.len);

    const l_stroke = decode("ł");
    try testing.expectEqual(@as(u21, 0x142), l_stroke.codepoint);
    try testing.expectEqual(@as(usize, 2), l_stroke.len);
}

test "three-byte and four-byte sequences" {
    const euro = decode("€");
    try testing.expectEqual(@as(u21, 0x20AC), euro.codepoint);
    try testing.expectEqual(@as(usize, 3), euro.len);

    const grin = decode("\xF0\x9F\x98\x80");
    try testing.expectEqual(@as(u21, 0x1F600), grin.codepoint);
    try testing.expectEqual(@as(usize, 4), grin.len);
}

test "a stray continuation byte gives the replacement" {
    const d = decode("\x80abc");
    try testing.expectEqual(replacement, d.codepoint);
    try testing.expectEqual(@as(usize, 1), d.len);
}

test "an overlong form gives the replacement" {
    // 0xC0 0x80 is an overlong NUL. 0xE0 0x80 0x80 is another.
    try testing.expectEqual(replacement, decode("\xC0\x80").codepoint);
    try testing.expectEqual(replacement, decode("\xE0\x80\x80").codepoint);
    try testing.expectEqual(@as(usize, 3), decode("\xE0\x80\x80").len);
}

test "a surrogate and a value above U+10FFFF give the replacement" {
    try testing.expectEqual(replacement, decode("\xED\xA0\x80").codepoint);
    try testing.expectEqual(replacement, decode("\xF4\x90\x80\x80").codepoint);
}

test "a cut-off sequence gives the replacement and keeps the next byte" {
    const d = decode("\xE2\x82A");
    try testing.expectEqual(replacement, d.codepoint);
    try testing.expectEqual(@as(usize, 2), d.len);
    try testing.expectEqual(replacement, decode("\xE2").codepoint);
}

test "the iterator walks a mixed string" {
    var it = Iterator.init("aé€!");
    const expected = [_]u21{ 'a', 0xE9, 0x20AC, '!' };
    const starts = [_]usize{ 0, 1, 3, 6 };
    for (expected, starts) |cp, start| {
        const item = it.next().?;
        try testing.expectEqual(cp, item.codepoint);
        try testing.expectEqual(start, item.start);
    }
    try testing.expect(it.next() == null);
}

test "the iterator ends on an empty string" {
    var it = Iterator.init("");
    try testing.expect(it.next() == null);
}
