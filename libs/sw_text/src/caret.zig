//! Caret and selection geometry for one line of text, with the bidirectional
//! algorithm. This file has no font and no GPU code: a "metrics" value is any
//! type with `advance(cp) f32`, as in `layout.zig`.
//!
//! A text field edits the text in logical order (the order of the bytes). The
//! line is drawn in visual order. `CaretLayout` gives, for each code point in
//! logical order, its box on the drawn line. From that it gives the x of the
//! caret at a byte offset, the byte offset nearest to an x (a click), and the
//! boxes of a selection, which can be in more than one part in mixed text.
//!
//! The widths are those of the shaped text (REQ-TEXT-005). A lam-alef
//! ligature is one glyph for two code points: each letter gets half of the
//! glyph, so the caret can go between the lam and the alef.

const std = @import("std");
const bidi = @import("bidi.zig");
const shape = @import("shape.zig");
const utf8 = @import("utf8.zig");

pub const CaretLayout = struct {
    alloc: std.mem.Allocator,
    /// The byte offset of each code point, then the text length at the end.
    offsets: []usize,
    /// The left edge of each code point on the drawn line, in logical order.
    left: []f32,
    /// The width of each code point, in logical order.
    width: []f32,
    /// The code point is in right-to-left text (an odd bidi level).
    rtl: []bool,
    /// The width of the line.
    total: f32,

    pub fn deinit(self: *CaretLayout) void {
        self.alloc.free(self.offsets);
        self.alloc.free(self.left);
        self.alloc.free(self.width);
        self.alloc.free(self.rtl);
        self.* = undefined;
    }

    /// The number of code points.
    pub fn count(self: *const CaretLayout) usize {
        return self.left.len;
    }

    /// The index of the code point that starts at byte `offset`. An offset
    /// in a code point gives the next code point. The text length gives
    /// `count()`.
    pub fn indexOf(self: *const CaretLayout, offset: usize) usize {
        return std.sort.lowerBound(usize, self.offsets, offset, orderUsize);
    }

    fn orderUsize(a: usize, b: usize) std.math.Order {
        return std.math.order(a, b);
    }

    /// The x of the caret before the code point at byte `offset`: the left
    /// edge of a left-to-right code point, the right edge of a right-to-left
    /// one. At the end of the text, the caret is after the last code point.
    pub fn caretX(self: *const CaretLayout, offset: usize) f32 {
        const n = self.count();
        if (n == 0) return 0;
        const i = @min(self.indexOf(offset), n);
        if (i < n) return if (self.rtl[i]) self.left[i] + self.width[i] else self.left[i];
        const last = n - 1;
        return if (self.rtl[last]) self.left[last] else self.left[last] + self.width[last];
    }

    /// The byte offset of the caret position nearest to `x`.
    pub fn offsetAt(self: *const CaretLayout, x: f32) usize {
        var best: usize = 0;
        var best_d = std.math.inf(f32);
        for (self.offsets) |offset| {
            const d = @abs(self.caretX(offset) - x);
            if (d < best_d) {
                best_d = d;
                best = offset;
            }
        }
        return best;
    }
};

/// The caret layout of `text` as one line. The caller frees it with
/// `deinit`.
pub fn caretLayout(alloc: std.mem.Allocator, m: anytype, text: []const u8, direction: bidi.Direction) !CaretLayout {
    var n: usize = 0;
    var it = utf8.Iterator.init(text);
    while (it.next()) |_| n += 1;

    const offsets = try alloc.alloc(usize, n + 1);
    errdefer alloc.free(offsets);
    const left = try alloc.alloc(f32, n);
    errdefer alloc.free(left);
    const width = try alloc.alloc(f32, n);
    errdefer alloc.free(width);
    const rtl = try alloc.alloc(bool, n);
    errdefer alloc.free(rtl);

    var total: f32 = 0;
    if (direction != .rtl and bidi.isLeftToRight(text)) {
        // Visual order is logical order.
        it = utf8.Iterator.init(text);
        var k: usize = 0;
        while (it.next()) |item| : (k += 1) {
            offsets[k] = item.start;
            left[k] = total;
            width[k] = m.advance(item.codepoint);
            rtl[k] = false;
            total += width[k];
        }
    } else {
        var p = try bidi.Paragraphs.init(alloc, text, direction);
        defer p.deinit();
        var v = try p.line(alloc, 0, text.len);
        defer v.deinit(alloc);
        @memcpy(offsets[0..n], p.offsets[0..n]);
        for (v.codepoints, v.offsets) |cp, byte| {
            const k = std.sort.lowerBound(usize, p.offsets[0..n], byte, CaretLayout.orderUsize);
            left[k] = total;
            width[k] = shape.advance(m, cp);
            rtl[k] = p.levels[k] & 1 == 1;
            total += width[k];
        }
        splitLigatures(p.codepoints[0..n], left, width, rtl);
    }
    offsets[n] = text.len;
    return .{ .alloc = alloc, .offsets = offsets, .left = left, .width = width, .rtl = rtl, .total = total };
}

/// Give each letter of a lam-alef ligature half of the ligature box. The
/// lam is first in logical order: in right-to-left text it is the right
/// half.
fn splitLigatures(codepoints: []const u21, left: []f32, width: []f32, rtl: []const bool) void {
    for (codepoints, 0..) |cp, part| {
        if (cp != shape.ligature_part) continue;
        // The ligature is the last code point before the part that is not
        // a mark.
        var lig = part;
        while (lig > 0) {
            lig -= 1;
            if (shape.joiningType(codepoints[lig]) != .T) break;
        }
        const n = shape.nominal(codepoints[lig]) orelse continue;
        if (n.second == 0) continue;
        const half = width[lig] / 2;
        const box_left = left[lig];
        width[lig] = half;
        width[part] = half;
        if (rtl[lig]) {
            left[lig] = box_left + half;
            left[part] = box_left;
        } else {
            left[part] = box_left + half;
        }
    }
}

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;

/// Each code point is 10 pixels wide.
const Mono = struct {
    pub fn advance(_: Mono, _: u21) f32 {
        return 10;
    }
};

test "caret: left-to-right text" {
    var c = try caretLayout(testing.allocator, Mono{}, "ab\u{e9}", .auto);
    defer c.deinit();
    try testing.expectEqual(@as(usize, 3), c.count());
    try testing.expectEqual(@as(f32, 0), c.caretX(0));
    try testing.expectEqual(@as(f32, 10), c.caretX(1));
    // "é" is two bytes. Its start is offset 2, the end is offset 4.
    try testing.expectEqual(@as(f32, 20), c.caretX(2));
    try testing.expectEqual(@as(f32, 30), c.caretX(4));
    try testing.expectEqual(@as(usize, 2), c.offsetAt(19));
    try testing.expectEqual(@as(usize, 4), c.offsetAt(100));
    try testing.expectEqual(@as(usize, 0), c.offsetAt(-5));
}

test "caret: empty text" {
    var c = try caretLayout(testing.allocator, Mono{}, "", .auto);
    defer c.deinit();
    try testing.expectEqual(@as(f32, 0), c.caretX(0));
    try testing.expectEqual(@as(usize, 0), c.offsetAt(50));
}

test "caret: right-to-left text goes from the right" {
    // Three Hebrew letters, two bytes each. Visual order: the last letter is
    // at the left.
    const text = "\u{5d0}\u{5d1}\u{5d2}";
    var c = try caretLayout(testing.allocator, Mono{}, text, .auto);
    defer c.deinit();
    try testing.expect(c.rtl[0] and c.rtl[2]);
    try testing.expectEqual(@as(f32, 20), c.left[0]);
    try testing.expectEqual(@as(f32, 0), c.left[2]);
    try testing.expectEqual(@as(f32, 30), c.caretX(0));
    try testing.expectEqual(@as(f32, 20), c.caretX(2));
    try testing.expectEqual(@as(f32, 0), c.caretX(text.len));
    try testing.expectEqual(@as(usize, 0), c.offsetAt(29));
    try testing.expectEqual(text.len, c.offsetAt(1));
}

test "caret: mixed text keeps the logical boxes" {
    // "ab", then two Hebrew letters, in a left-to-right paragraph. The
    // Hebrew run is drawn reversed after "ab".
    const text = "ab\u{5d0}\u{5d1}";
    var c = try caretLayout(testing.allocator, Mono{}, text, .ltr);
    defer c.deinit();
    try testing.expectEqual(@as(f32, 40), c.total);
    try testing.expectEqual(@as(f32, 0), c.left[0]);
    try testing.expectEqual(@as(f32, 10), c.left[1]);
    try testing.expectEqual(@as(f32, 30), c.left[2]);
    try testing.expectEqual(@as(f32, 20), c.left[3]);
    // The caret before the first Hebrew letter is at its right edge.
    try testing.expectEqual(@as(f32, 40), c.caretX(2));
    try testing.expectEqual(@as(f32, 20), c.caretX(text.len));
}

/// Each presentation form is 10 wide, a lam-alef ligature is 16 wide and
/// each other code point is 20 wide, so the widths show if the text was
/// shaped. A line is 20 high.
const Shaped = struct {
    pub fn advance(_: Shaped, cp: u21) f32 {
        if (cp >= 0xFEF5 and cp <= 0xFEFC) return 16;
        if (cp >= 0xFB50 and cp <= 0xFEFF) return 10;
        return 20;
    }
    pub fn lineHeight(_: Shaped) f32 {
        return 20;
    }
};

test "caret: shaped Arabic text keeps a position for each byte offset" {
    // "Salam": seen, lam, alef, meem, two bytes each. Shaped: initial seen
    // (10), the lam-alef ligature (16) and isolated meem (10).
    const text = "\u{633}\u{644}\u{627}\u{645}";
    var c = try caretLayout(testing.allocator, Shaped{}, text, .auto);
    defer c.deinit();
    try testing.expectEqual(@as(f32, 36), c.total);
    // The width agrees with `layout.measure`, which `TextRenderer.measure`
    // uses.
    try testing.expectEqual(@as(f32, 36), @import("layout.zig").measure(Shaped{}, text).w);
    // From the right: seen [26, 36], lam [18, 26], alef [10, 18], meem
    // [0, 10]. Lam and alef each have half of the ligature.
    try testing.expectEqual(@as(f32, 36), c.caretX(0));
    try testing.expectEqual(@as(f32, 26), c.caretX(2));
    try testing.expectEqual(@as(f32, 18), c.caretX(4));
    try testing.expectEqual(@as(f32, 10), c.caretX(6));
    try testing.expectEqual(@as(f32, 0), c.caretX(text.len));
    // A click maps back to each byte offset of the text.
    try testing.expectEqual(@as(usize, 0), c.offsetAt(35));
    try testing.expectEqual(@as(usize, 2), c.offsetAt(25));
    try testing.expectEqual(@as(usize, 4), c.offsetAt(18));
    try testing.expectEqual(@as(usize, 6), c.offsetAt(11));
    try testing.expectEqual(text.len, c.offsetAt(1));
}

test "caret: a diacritic in shaped text keeps its own box" {
    // Beh, fatha, beh. The fatha is 20 wide here, so its box is visible.
    const text = "\u{628}\u{64E}\u{628}";
    var c = try caretLayout(testing.allocator, Shaped{}, text, .auto);
    defer c.deinit();
    try testing.expectEqual(@as(f32, 40), c.total);
    try testing.expectEqual(@as(f32, 40), c.caretX(0));
    try testing.expectEqual(@as(f32, 30), c.caretX(2));
    try testing.expectEqual(@as(f32, 10), c.caretX(4));
    try testing.expectEqual(@as(f32, 0), c.caretX(text.len));
}

test "caret: mixed Latin, Arabic and numbers" {
    // "ab " + lam alef + " 1" in a left-to-right paragraph. The space and
    // the digit after the Arabic word are right to left (rules W2 and N1).
    const text = "ab \u{644}\u{627} 1";
    var c = try caretLayout(testing.allocator, Shaped{}, text, .auto);
    defer c.deinit();
    try testing.expectEqual(@as(f32, 20 * 5 + 16), c.total);
    // Visual order: "ab " [0, 60], "1" [60, 80], " " [80, 100], then the
    // ligature: alef [100, 108] and lam [108, 116].
    try testing.expectEqual(@as(f32, 0), c.caretX(0));
    try testing.expectEqual(@as(f32, 116), c.caretX(3));
    try testing.expectEqual(@as(f32, 108), c.caretX(5));
    try testing.expectEqual(@as(f32, 100), c.caretX(7));
    try testing.expectEqual(@as(f32, 60), c.caretX(8));
    try testing.expectEqual(@as(f32, 80), c.caretX(text.len));
    try testing.expectEqual(@as(usize, 3), c.offsetAt(115));
    try testing.expectEqual(@as(usize, 5), c.offsetAt(108));
}
