//! Measuring and wrapping. This file has no font and no GPU code. A "metrics"
//! value is any type with these methods:
//!
//!   fn advance(self: M, codepoint: u21) f32   // pen movement for one code point
//!   fn lineHeight(self: M) f32                // distance between two baselines

const std = @import("std");
const utf8 = @import("utf8.zig");

pub const Size = struct {
    w: f32,
    h: f32,
};

/// A line of text: the bytes `text[start..end]`, and their width.
pub const Line = struct {
    start: usize,
    end: usize,
    width: f32,
};

/// The width of `text` on one line. A newline is not special here.
pub fn lineWidth(m: anytype, text: []const u8) f32 {
    var width: f32 = 0;
    var it = utf8.Iterator.init(text);
    while (it.next()) |item| width += m.advance(item.codepoint);
    return width;
}

/// The size of `text` drawn with no wrapping. A newline (`\n`) starts a new
/// line. The width is that of the widest line. The height is the line height
/// times the number of lines, and an empty string has one line.
pub fn measure(m: anytype, text: []const u8) Size {
    var width: f32 = 0;
    var lines: usize = 1;
    var start: usize = 0;
    for (text, 0..) |byte, i| {
        if (byte != '\n') continue;
        width = @max(width, lineWidth(m, text[start..i]));
        lines += 1;
        start = i + 1;
    }
    width = @max(width, lineWidth(m, text[start..]));
    return .{ .w = width, .h = m.lineHeight() * @as(f32, @floatFromInt(lines)) };
}

/// Break `text` into lines no wider than `max_width`. A break goes at a space
/// (the space is dropped) or at a newline. A word wider than `max_width` is
/// split between two code points. A line holds at least one code point, so a
/// very narrow `max_width` still makes progress. The result has at least one
/// line. The caller frees it with `alloc.free`.
pub fn wrap(alloc: std.mem.Allocator, m: anytype, text: []const u8, max_width: f32) ![]Line {
    var lines: std.ArrayList(Line) = .empty;
    errdefer lines.deinit(alloc);

    const Break = struct { end: usize, next: usize };
    var line_start: usize = 0;
    var width: f32 = 0;
    var last_break: ?Break = null;

    var it = utf8.Iterator.init(text);
    while (it.next()) |item| {
        const cp = item.codepoint;
        if (cp == '\n') {
            try lines.append(alloc, .{ .start = line_start, .end = item.start, .width = width });
            line_start = item.start + item.len;
            width = 0;
            last_break = null;
            continue;
        }
        const advance = m.advance(cp);
        if (cp == ' ') {
            last_break = .{ .end = item.start, .next = item.start + item.len };
            width += advance;
            continue;
        }
        if (width + advance > max_width and item.start > line_start) {
            if (last_break) |b| {
                try lines.append(alloc, .{
                    .start = line_start,
                    .end = b.end,
                    .width = lineWidth(m, text[line_start..b.end]),
                });
                line_start = b.next;
                width = lineWidth(m, text[line_start..item.start]);
            } else {
                try lines.append(alloc, .{ .start = line_start, .end = item.start, .width = width });
                line_start = item.start;
                width = 0;
            }
            last_break = null;
        }
        width += advance;
    }
    try lines.append(alloc, .{ .start = line_start, .end = text.len, .width = width });
    return lines.toOwnedSlice(alloc);
}

/// The size of `text` after `wrap`.
pub fn measureWrapped(alloc: std.mem.Allocator, m: anytype, text: []const u8, max_width: f32) !Size {
    const lines = try wrap(alloc, m, text, max_width);
    defer alloc.free(lines);
    var width: f32 = 0;
    for (lines) |line| width = @max(width, line.width);
    return .{ .w = width, .h = m.lineHeight() * @as(f32, @floatFromInt(lines.len)) };
}

const testing = std.testing;

/// Every code point is 10 wide. A line is 20 high.
const Mono = struct {
    pub fn advance(_: Mono, _: u21) f32 {
        return 10;
    }
    pub fn lineHeight(_: Mono) f32 {
        return 20;
    }
};

fn expectLines(text: []const u8, max_width: f32, expected: []const []const u8) !void {
    const lines = try wrap(testing.allocator, Mono{}, text, max_width);
    defer testing.allocator.free(lines);
    try testing.expectEqual(expected.len, lines.len);
    for (expected, lines) |want, line| {
        try testing.expectEqualStrings(want, text[line.start..line.end]);
    }
}

test "measure counts code points, not bytes" {
    const size = measure(Mono{}, "café");
    try testing.expectEqual(@as(f32, 40), size.w);
    try testing.expectEqual(@as(f32, 20), size.h);
}

test "measure of an empty string is one empty line" {
    const size = measure(Mono{}, "");
    try testing.expectEqual(@as(f32, 0), size.w);
    try testing.expectEqual(@as(f32, 20), size.h);
}

test "measure uses the widest line and every line's height" {
    const size = measure(Mono{}, "ab\nabcd\nabc");
    try testing.expectEqual(@as(f32, 40), size.w);
    try testing.expectEqual(@as(f32, 60), size.h);
}

test "a bad byte measures as one replacement character" {
    try testing.expectEqual(@as(f32, 30), measure(Mono{}, "a\xFFb").w);
}

test "text that fits stays on one line" {
    try expectLines("one two", 100, &.{"one two"});
}

test "wrap breaks at a space" {
    try expectLines("aaa bbb ccc", 70, &.{ "aaa bbb", "ccc" });
    try expectLines("aaa bbb ccc", 30, &.{ "aaa", "bbb", "ccc" });
}

test "wrap puts a word that just fits on the line" {
    try expectLines("aaa bbb", 70, &.{"aaa bbb"});
    try expectLines("aaa bbbb", 70, &.{ "aaa", "bbbb" });
}

test "wrap splits a word wider than the line" {
    try expectLines("abcdefgh", 30, &.{ "abc", "def", "gh" });
}

test "wrap splits a long word after the text before it" {
    try expectLines("ab cdefgh", 30, &.{ "ab", "cde", "fgh" });
}

test "wrap honours a newline" {
    try expectLines("ab\ncd", 100, &.{ "ab", "cd" });
    try expectLines("ab\n\ncd", 100, &.{ "ab", "", "cd" });
}

test "wrap of an empty string is one empty line" {
    try expectLines("", 100, &.{""});
}

test "wrap keeps a multi-byte code point whole" {
    try expectLines("éé éé", 20, &.{ "éé", "éé" });
}

test "wrap with a very narrow width still makes progress" {
    try expectLines("abc", 1, &.{ "a", "b", "c" });
}

test "wrap gives each line its width" {
    const lines = try wrap(testing.allocator, Mono{}, "aaa bbbbb", 70);
    defer testing.allocator.free(lines);
    try testing.expectEqual(@as(f32, 30), lines[0].width);
    try testing.expectEqual(@as(f32, 50), lines[1].width);
}

test "measureWrapped is as wide as the widest line and as high as all lines" {
    const size = try measureWrapped(testing.allocator, Mono{}, "aaa bbb ccc", 70);
    try testing.expectEqual(@as(f32, 70), size.w);
    try testing.expectEqual(@as(f32, 40), size.h);
}
