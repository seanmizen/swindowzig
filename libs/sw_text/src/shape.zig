//! Arabic contextual shaping (REQ-TEXT-001). Each Arabic letter changes to
//! its isolated, initial, medial or final presentation form (U+FB50 to
//! U+FEFF), from the joining types of its neighbours in logical order. Lam
//! followed by alef changes to one lam-alef ligature (REQ-TEXT-002). A
//! transparent code point (joining type T, such as a diacritic) does not
//! break a join (REQ-TEXT-006). Text with no Arabic letters does not change
//! (REQ-TEXT-007). This file has no font and no GPU code.
//!
//! Shaping does not change the number of code points, so a byte offset in
//! the text still maps to one shaped code point. The alef of a lam-alef
//! ligature changes to `ligature_part`, which has no glyph and no width.
//!
//! The data is in `shaping_tables.zig`, made by
//! `libs/sw_text/tools/gen_shaping_tables.py` from `ArabicShaping.txt` and
//! `UnicodeData.txt`.

const std = @import("std");
const tables = @import("shaping_tables.zig");
const utf8 = @import("utf8.zig");

/// The joining types (Joining_Type) of `ArabicShaping.txt`. R joins to the
/// letter before it in logical order, L to the letter after it, and D to
/// both. C (such as tatweel and ZWJ) causes a join on both sides and does
/// not change. T is transparent. U does not join.
pub const JoiningType = enum(u8) { U, R, L, D, C, T };

/// The code point that takes the place of the alef in a lam-alef ligature:
/// the ligature on the lam draws the two letters. It is above U+10FFFF, so
/// it is never in decoded text. It has no glyph and no width.
pub const ligature_part: u21 = 0x110000;

const lam: u21 = 0x0644;

/// The first code point that joins (U+0620, Kashmiri yeh). The shaper
/// returns each code point below it at once.
const first_joining: u21 = 0x0620;

/// The joining type of a code point.
pub fn joiningType(cp: u21) JoiningType {
    var lo: usize = 0;
    var hi: usize = tables.joining.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const range = tables.joining[mid];
        if (cp < range.lo) {
            hi = mid;
        } else if (cp > range.hi) {
            lo = mid + 1;
        } else {
            return range.type;
        }
    }
    return .U;
}

fn formsOf(cp: u21) ?tables.Forms {
    var lo: usize = 0;
    var hi: usize = tables.forms.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const f = tables.forms[mid];
        if (cp < f.cp) {
            hi = mid;
        } else if (cp > f.cp) {
            lo = mid + 1;
        } else {
            return f;
        }
    }
    return null;
}

fn lamAlef(alef: u21) ?tables.Ligature {
    for (tables.lam_alef) |l| {
        if (l.alef == alef) return l;
    }
    return null;
}

/// The letters of a presentation form, for a font that does not have the
/// form: one letter, or lam and alef for a lam-alef ligature (`second` is
/// then not 0). Null for a code point that is not a presentation form.
pub fn nominal(cp: u21) ?tables.Nominal {
    if (cp < 0xFB50 or cp > 0xFEFF) return null;
    var lo: usize = 0;
    var hi: usize = tables.nominal.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const n = tables.nominal[mid];
        if (cp < n.cp) {
            hi = mid;
        } else if (cp > n.cp) {
            lo = mid + 1;
        } else {
            return n;
        }
    }
    return null;
}

/// True if `cp` is a letter with presentation forms: shaping can change it.
pub fn hasForms(cp: u21) bool {
    return cp >= first_joining and formsOf(cp) != null;
}

/// True if shaping can change `text`. Text with no Arabic letters gives
/// false, and the caller can skip the shaper.
pub fn needsShaping(text: []const u8) bool {
    var it = utf8.Iterator.init(text);
    while (it.next()) |item| {
        if (hasForms(item.codepoint)) return true;
    }
    return false;
}

/// The pen movement of a shaped code point: 0 for `ligature_part`, and
/// `m.advance(cp)` for each other code point. `m` is a metrics value as in
/// `layout.zig`.
pub fn advance(m: anytype, cp: u21) f32 {
    if (cp == ligature_part) return 0;
    return m.advance(cp);
}

/// The code points of UTF-8 text in logical order, shaped. Each item has the
/// byte offset and length of its code point in the text, as in
/// `utf8.Iterator`, and the shaped code point. The iterator returns a code
/// point below U+0620 that follows no joining letter after one comparison.
pub const Iterator = struct {
    inner: utf8.Iterator,
    /// The last code point that is not transparent can join to a letter
    /// after it (joining type D, L or C).
    joins_next: bool = false,
    /// The byte offset of the alef in the lam-alef ligature before it.
    part_at: ?usize = null,

    pub fn init(text: []const u8) Iterator {
        return .{ .inner = utf8.Iterator.init(text) };
    }

    pub fn next(self: *Iterator) ?utf8.Item {
        var item = self.inner.next() orelse return null;
        if (self.part_at) |at| {
            if (at == item.start) {
                self.part_at = null;
                // The ligature is right-joining, as an alef is.
                self.joins_next = false;
                item.codepoint = ligature_part;
                return item;
            }
        }
        const cp = item.codepoint;
        // No code point below U+0620 joins (a test checks the table), and
        // only a transparent one can keep a join open.
        if (cp < first_joining and !self.joins_next) return item;

        const t = joiningType(cp);
        switch (t) {
            .T => return item,
            .U => {
                self.joins_next = false;
                return item;
            },
            .C => {
                self.joins_next = true;
                return item;
            },
            .R, .L, .D => {},
        }
        const joins_before = self.joins_next and t != .L;
        const after = self.peek();
        const joins_after = (t == .D or t == .L) and switch (after.type) {
            .D, .R, .C => true,
            else => false,
        };
        self.joins_next = t == .D or t == .L;

        if (cp == lam and after.item != null) {
            if (lamAlef(after.item.?.codepoint)) |l| {
                const lig = if (joins_before) l.final else l.isolated;
                if (lig != 0) {
                    item.codepoint = lig;
                    self.part_at = after.item.?.start;
                    self.joins_next = false;
                    return item;
                }
            }
        }

        const f = formsOf(cp) orelse return item;
        const form = if (joins_before and joins_after)
            f.medial
        else if (joins_before)
            f.final
        else if (joins_after)
            f.initial
        else
            f.isolated;
        // Unicode has no such form for a few letters: keep the letter.
        if (form != 0) item.codepoint = form;
        return item;
    }

    const Next = struct { type: JoiningType, item: ?utf8.Item };

    /// The next code point that is not transparent, and its joining type
    /// (U at the end of the text).
    fn peek(self: *const Iterator) Next {
        var it = self.inner;
        while (it.next()) |item| {
            const t = joiningType(item.codepoint);
            if (t != .T) return .{ .type = t, .item = item };
        }
        return .{ .type = .U, .item = null };
    }
};

/// Write the shaped code points of `text` to `out`, which has one entry for
/// each code point of `text` (bad bytes give U+FFFD, as in `utf8`).
pub fn shapeInto(text: []const u8, out: []u21) void {
    var it = Iterator.init(text);
    var k: usize = 0;
    while (it.next()) |item| : (k += 1) out[k] = item.codepoint;
    std.debug.assert(k == out.len);
}

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;

fn expectShaped(text: []const u8, want: []const u21) !void {
    var got: [32]u21 = undefined;
    var n: usize = 0;
    var it = utf8.Iterator.init(text);
    while (it.next()) |_| n += 1;
    shapeInto(text, got[0..n]);
    try testing.expectEqualSlices(u21, want, got[0..n]);
}

test "joining types come from ArabicShaping.txt" {
    try testing.expectEqual(JoiningType.R, joiningType(0x0627)); // alef
    try testing.expectEqual(JoiningType.D, joiningType(0x0628)); // beh
    try testing.expectEqual(JoiningType.U, joiningType(0x0621)); // hamza
    try testing.expectEqual(JoiningType.C, joiningType(0x0640)); // tatweel
    try testing.expectEqual(JoiningType.C, joiningType(0x200D)); // ZWJ
    try testing.expectEqual(JoiningType.U, joiningType(0x200C)); // ZWNJ
    try testing.expectEqual(JoiningType.T, joiningType(0x064E)); // fatha (Mn)
    try testing.expectEqual(JoiningType.T, joiningType(0x0301)); // a Latin accent (Mn)
    try testing.expectEqual(JoiningType.U, joiningType('a'));
}

test "no code point below U+0620 joins" {
    // The iterator returns these code points at once (see `Iterator.next`).
    for (tables.joining) |range| {
        if (range.lo < first_joining) try testing.expectEqual(JoiningType.T, range.type);
    }
    for (tables.forms) |f| try testing.expect(f.cp >= first_joining);
}

test "beh takes each of its four forms" {
    try expectShaped("\u{628}", &.{0xFE8F}); // isolated
    try expectShaped("\u{628}\u{628}", &.{ 0xFE91, 0xFE90 }); // initial, final
    try expectShaped("\u{628}\u{628}\u{628}", &.{ 0xFE91, 0xFE92, 0xFE90 }); // medial
}

test "meem and heh take each of their forms" {
    try expectShaped("\u{645}\u{645}\u{645}", &.{ 0xFEE3, 0xFEE4, 0xFEE2 });
    try expectShaped("\u{647}", &.{0xFEE9});
    try expectShaped("\u{647}\u{647}\u{647}", &.{ 0xFEEB, 0xFEEC, 0xFEEA });
}

test "a right-joining letter does not join to the letter after it" {
    // Beh, dal, beh: dal joins to the beh before it only.
    try expectShaped("\u{628}\u{62F}\u{628}", &.{ 0xFE91, 0xFEAA, 0xFE8F });
    // Dal, alef: two isolated letters.
    try expectShaped("\u{62F}\u{627}", &.{ 0xFEA9, 0xFE8D });
    // Teh marbuta at the end of a word.
    try expectShaped("\u{628}\u{629}", &.{ 0xFE91, 0xFE94 });
}

test "a diacritic in a word does not break the join" {
    // Beh, fatha, beh: the fatha stays and the two behs join.
    try expectShaped("\u{628}\u{64E}\u{628}", &.{ 0xFE91, 0x064E, 0xFE90 });
    // Two marks between the letters.
    try expectShaped("\u{628}\u{651}\u{64E}\u{628}\u{628}", &.{ 0xFE91, 0x0651, 0x064E, 0xFE92, 0xFE90 });
    // A mark at the end of the word.
    try expectShaped("\u{628}\u{628}\u{64F}", &.{ 0xFE91, 0xFE90, 0x064F });
}

test "lam followed by alef is the lam-alef ligature" {
    try expectShaped("\u{644}\u{627}", &.{ 0xFEFB, ligature_part });
    // After a joining letter, the ligature takes its final form.
    try expectShaped("\u{628}\u{644}\u{627}", &.{ 0xFE91, 0xFEFC, ligature_part });
    // Alef with hamza above, with madda, with hamza below.
    try expectShaped("\u{644}\u{623}", &.{ 0xFEF7, ligature_part });
    try expectShaped("\u{644}\u{622}", &.{ 0xFEF5, ligature_part });
    try expectShaped("\u{628}\u{644}\u{625}", &.{ 0xFE91, 0xFEFA, ligature_part });
    // A mark between lam and alef.
    try expectShaped("\u{644}\u{64E}\u{627}", &.{ 0xFEFB, 0x064E, ligature_part });
    // The ligature does not join to the letter after it. "Salam": seen,
    // lam, alef, meem.
    try expectShaped("\u{633}\u{644}\u{627}\u{645}", &.{ 0xFEB3, 0xFEFC, ligature_part, 0xFEE1 });
    // Lam before a letter that is not an alef takes its usual form.
    try expectShaped("\u{644}\u{628}", &.{ 0xFEDF, 0xFE90 });
}

test "tatweel and ZWJ cause a join, ZWNJ and a space break it" {
    try expectShaped("\u{640}\u{628}", &.{ 0x0640, 0xFE90 });
    try expectShaped("\u{628}\u{640}", &.{ 0xFE91, 0x0640 });
    try expectShaped("\u{628}\u{200D}", &.{ 0xFE91, 0x200D });
    try expectShaped("\u{628}\u{200C}\u{628}", &.{ 0xFE8F, 0x200C, 0xFE8F });
    try expectShaped("\u{628} \u{628}", &.{ 0xFE8F, ' ', 0xFE8F });
    // A Latin letter between two Arabic letters breaks the join.
    try expectShaped("\u{628}a\u{628}", &.{ 0xFE8F, 'a', 0xFE8F });
}

test "text with no Arabic letters is unchanged" {
    const text = "Hello, w\u{301}orld 123 \u{5d0}\u{4E2D}";
    try testing.expect(!needsShaping(text));
    var it = Iterator.init(text);
    var plain = utf8.Iterator.init(text);
    while (plain.next()) |want| {
        const got = it.next().?;
        try testing.expectEqual(want.codepoint, got.codepoint);
        try testing.expectEqual(want.start, got.start);
        try testing.expectEqual(want.len, got.len);
    }
    try testing.expect(it.next() == null);
    try testing.expect(needsShaping("abc \u{628}"));
}

test "the iterator keeps the byte offsets of the text" {
    var it = Iterator.init("a\u{644}\u{627}");
    try testing.expectEqual(@as(usize, 0), it.next().?.start);
    const l = it.next().?;
    try testing.expectEqual(@as(u21, 0xFEFB), l.codepoint);
    try testing.expectEqual(@as(usize, 1), l.start);
    const part = it.next().?;
    try testing.expectEqual(ligature_part, part.codepoint);
    try testing.expectEqual(@as(usize, 3), part.start);
    try testing.expectEqual(@as(usize, 2), part.len);
}

test "each presentation form maps back to its letters" {
    try testing.expectEqual(@as(u21, 0x0628), nominal(0xFE92).?.first);
    try testing.expectEqual(@as(u21, 0), nominal(0xFE92).?.second);
    const lig = nominal(0xFEFC).?;
    try testing.expectEqual(@as(u21, 0x0644), lig.first);
    try testing.expectEqual(@as(u21, 0x0627), lig.second);
    try testing.expect(nominal(0x0628) == null);
    try testing.expect(nominal('a') == null);
    // Every form in the table maps back to its letter.
    for (tables.forms) |f| {
        for ([_]u21{ f.isolated, f.final, f.initial, f.medial }) |form| {
            if (form != 0) try testing.expectEqual(f.cp, nominal(form).?.first);
        }
    }
}

test "the part of a ligature has no width" {
    const Ten = struct {
        pub fn advance(_: @This(), _: u21) f32 {
            return 10;
        }
    };
    try testing.expectEqual(@as(f32, 0), advance(Ten{}, ligature_part));
    try testing.expectEqual(@as(f32, 10), advance(Ten{}, 0xFEFB));
}
