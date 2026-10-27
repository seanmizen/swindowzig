//! The Unicode bidirectional algorithm (UAX #9): mixed left-to-right and
//! right-to-left text in logical (typed) order becomes the visual order that a
//! font draws from left to right. This file has no font and no GPU code.
//!
//! The steps follow UAX #9: P2-P3 (paragraph level), X1-X10 (explicit levels
//! and isolating run sequences), W1-W7, N0-N2, I1-I2 (implicit levels), and
//! L1, L2 and L4 (a line: whitespace levels, reordering, mirroring). The
//! character data is in `bidi_tables.zig`, generated from the Unicode
//! Character Database. This file does not shape Arabic letters into their
//! joined forms.

const std = @import("std");
const tables = @import("bidi_tables.zig");
const utf8 = @import("utf8.zig");

/// The bidirectional character types (Bidi_Class).
pub const Class = enum(u8) {
    L,
    R,
    AL,
    EN,
    ES,
    ET,
    AN,
    CS,
    NSM,
    BN,
    B,
    S,
    WS,
    ON,
    LRE,
    LRO,
    RLE,
    RLO,
    PDF,
    LRI,
    RLI,
    FSI,
    PDI,
};

/// The base direction of a paragraph. `auto` takes the direction of the first
/// strong character (rules P2 and P3), and left to right if there is none.
pub const Direction = enum { auto, ltr, rtl };

/// The deepest embedding level (BD2).
pub const max_depth = 125;

/// The deepest stack of open brackets in one isolating run sequence (BD16).
const max_brackets = 63;

const none: u32 = std.math.maxInt(u32);

/// The bidirectional type of a code point.
pub fn classOf(cp: u21) Class {
    var lo: usize = 0;
    var hi: usize = tables.classes.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const range = tables.classes[mid];
        if (cp < range.lo) {
            hi = mid;
        } else if (cp > range.hi) {
            lo = mid + 1;
        } else {
            return range.class;
        }
    }
    return .L;
}

/// The mirrored code point (Bidi_Mirroring_Glyph) for a code point in
/// right-to-left text, or the code point itself.
pub fn mirror(cp: u21) u21 {
    var lo: usize = 0;
    var hi: usize = tables.mirrors.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const m = tables.mirrors[mid];
        if (cp < m.cp) {
            hi = mid;
        } else if (cp > m.cp) {
            lo = mid + 1;
        } else {
            return m.mirror;
        }
    }
    return cp;
}

fn bracketOf(cp: u21) ?tables.Bracket {
    var lo: usize = 0;
    var hi: usize = tables.brackets.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const b = tables.brackets[mid];
        if (cp < b.cp) {
            hi = mid;
        } else if (cp > b.cp) {
            lo = mid + 1;
        } else {
            return b;
        }
    }
    return null;
}

/// U+2329 and U+232A are canonically equal to U+3008 and U+3009, so they
/// pair with them (BD16).
fn canonicalBracket(cp: u21) u21 {
    return switch (cp) {
        0x2329 => 0x3008,
        0x232A => 0x3009,
        else => cp,
    };
}

/// True for the code points that control direction and have no glyph: the
/// explicit embeddings, overrides and isolates, the marks LRM, RLM and ALM,
/// and the boundary neutrals (such as ZWJ and the soft hyphen).
pub fn isFormat(cp: u21) bool {
    if (cp == 0x200E or cp == 0x200F or cp == 0x061C) return true;
    return switch (classOf(cp)) {
        .BN, .LRE, .LRO, .RLE, .RLO, .PDF, .LRI, .RLI, .FSI, .PDI => true,
        else => false,
    };
}

/// True if `text` keeps its logical order in a left-to-right paragraph: it
/// has no right-to-left letters, no Arabic digits and no explicit direction
/// controls. Then the algorithm changes nothing, and a caller can skip it.
pub fn isLeftToRight(text: []const u8) bool {
    var it = utf8.Iterator.init(text);
    while (it.next()) |item| {
        if (item.codepoint < 0x0590) continue;
        switch (classOf(item.codepoint)) {
            .R, .AL, .AN, .LRE, .LRO, .RLE, .RLO, .PDF, .LRI, .RLI, .FSI, .PDI => return false,
            else => {},
        }
    }
    return true;
}

fn isRemoved(c: Class) bool {
    return switch (c) {
        .LRE, .LRO, .RLE, .RLO, .PDF, .BN => true,
        else => false,
    };
}

fn isIsolateStart(c: Class) bool {
    return c == .LRI or c == .RLI or c == .FSI;
}

/// The neutral and isolate types of rules N1 and N2.
fn isNeutral(c: Class) bool {
    return switch (c) {
        .B, .S, .WS, .ON, .LRI, .RLI, .FSI, .PDI => true,
        else => false,
    };
}

/// The types that rule L1 resets at the end of a line (with the types that
/// X9 removes).
fn isLineEndSpace(c: Class) bool {
    return switch (c) {
        .WS, .LRI, .RLI, .FSI, .PDI, .BN, .LRE, .LRO, .RLE, .RLO, .PDF => true,
        else => false,
    };
}

/// The strong direction of a resolved type for N0, N1 and N2: EN and AN count
/// as R.
fn strongOf(c: Class) ?Class {
    return switch (c) {
        .L => .L,
        .R, .AL, .EN, .AN => .R,
        else => null,
    };
}

fn directionOfLevel(level: u8) Class {
    return if (level & 1 == 1) .R else .L;
}

fn nextOdd(level: u8) u8 {
    return (level + 1) | 1;
}

fn nextEven(level: u8) u8 {
    return (level + 2) & ~@as(u8, 1);
}

/// BD9: the matching PDI of each isolate initiator, or `none`.
fn matchIsolates(classes: []const Class, match: []u32, matched_pdi: []bool, stack: []u32) void {
    @memset(match, none);
    @memset(matched_pdi, false);
    var depth: usize = 0;
    for (classes, 0..) |c, i| {
        if (isIsolateStart(c)) {
            stack[depth] = @intCast(i);
            depth += 1;
        } else if (c == .PDI and depth > 0) {
            depth -= 1;
            match[stack[depth]] = @intCast(i);
            matched_pdi[i] = true;
        }
    }
}

/// P2: the first strong type in `classes[start..end]`, with the text inside
/// isolates skipped. R and AL give R.
fn firstStrong(classes: []const Class, match: []const u32, start: usize, end: usize) ?Class {
    var i = start;
    while (i < end) : (i += 1) {
        switch (classes[i]) {
            .L => return .L,
            .R, .AL => return .R,
            .LRI, .RLI, .FSI => {
                if (match[i] == none) return null;
                i = match[i];
            },
            else => {},
        }
    }
    return null;
}

/// Resolve the embedding level of each code point (rules P1 to I2). A B
/// (paragraph separator) ends a paragraph, and each paragraph gets its own
/// level when `direction` is `auto`. `codepoints` find the bracket pairs, and
/// `classes` give the type of each code point (normally `classOf`). The
/// levels of the types that X9 removes (BN and the explicit embeddings) copy
/// the level before them. Returns the level of the first paragraph.
pub fn resolveLevels(
    alloc: std.mem.Allocator,
    codepoints: []const u21,
    classes: []const Class,
    direction: Direction,
    levels: []u8,
) !u8 {
    std.debug.assert(codepoints.len == classes.len and levels.len == classes.len);
    var first: ?u8 = null;
    var start: usize = 0;
    while (start < classes.len) {
        var end = start;
        while (end < classes.len and classes[end] != .B) end += 1;
        if (end < classes.len) end += 1; // The B is in its paragraph.
        const level = try resolveParagraph(
            alloc,
            codepoints[start..end],
            classes[start..end],
            direction,
            levels[start..end],
        );
        if (first == null) first = level;
        start = end;
    }
    return first orelse switch (direction) {
        .rtl => 1,
        else => 0,
    };
}

const Entry = struct {
    level: u8,
    override: ?Class,
    isolate: bool,
};

fn resolveParagraph(
    alloc: std.mem.Allocator,
    codepoints: []const u21,
    classes: []const Class,
    direction: Direction,
    levels: []u8,
) !u8 {
    const n = classes.len;
    const match = try alloc.alloc(u32, n);
    defer alloc.free(match);
    const matched_pdi = try alloc.alloc(bool, n);
    defer alloc.free(matched_pdi);
    const scratch = try alloc.alloc(u32, n);
    defer alloc.free(scratch);
    matchIsolates(classes, match, matched_pdi, scratch);

    // P2, P3.
    const para: u8 = switch (direction) {
        .ltr => 0,
        .rtl => 1,
        .auto => if (firstStrong(classes, match, 0, n) == .R) 1 else 0,
    };

    const types = try alloc.dupe(Class, classes);
    defer alloc.free(types);

    // X1 to X8: the explicit levels and overrides.
    var stack: [max_depth + 2]Entry = undefined;
    stack[0] = .{ .level = para, .override = null, .isolate = false };
    var sp: usize = 1;
    var overflow_isolates: usize = 0;
    var overflow_embeddings: usize = 0;
    var valid_isolates: usize = 0;
    for (classes, 0..) |c, i| {
        switch (c) {
            .RLE, .LRE, .RLO, .LRO => {
                const top = stack[sp - 1];
                levels[i] = top.level;
                const level = if (c == .RLE or c == .RLO) nextOdd(top.level) else nextEven(top.level);
                if (level <= max_depth and overflow_isolates == 0 and overflow_embeddings == 0) {
                    stack[sp] = .{
                        .level = level,
                        .override = switch (c) {
                            .RLO => .R,
                            .LRO => .L,
                            else => null,
                        },
                        .isolate = false,
                    };
                    sp += 1;
                } else if (overflow_isolates == 0) {
                    overflow_embeddings += 1;
                }
            },
            .RLI, .LRI, .FSI => {
                const top = stack[sp - 1];
                levels[i] = top.level;
                if (top.override) |o| types[i] = o;
                var rtl = c == .RLI;
                if (c == .FSI) {
                    const end = if (match[i] == none) n else match[i];
                    rtl = firstStrong(classes, match, i + 1, end) == .R;
                }
                const level = if (rtl) nextOdd(top.level) else nextEven(top.level);
                if (level <= max_depth and overflow_isolates == 0 and overflow_embeddings == 0) {
                    valid_isolates += 1;
                    stack[sp] = .{ .level = level, .override = null, .isolate = true };
                    sp += 1;
                } else {
                    overflow_isolates += 1;
                }
            },
            .PDI => {
                if (overflow_isolates > 0) {
                    overflow_isolates -= 1;
                } else if (valid_isolates > 0) {
                    overflow_embeddings = 0;
                    while (!stack[sp - 1].isolate) sp -= 1;
                    sp -= 1;
                    valid_isolates -= 1;
                }
                const top = stack[sp - 1];
                levels[i] = top.level;
                if (top.override) |o| types[i] = o;
            },
            .PDF => {
                if (overflow_isolates > 0) {
                    // Nothing.
                } else if (overflow_embeddings > 0) {
                    overflow_embeddings -= 1;
                } else if (!stack[sp - 1].isolate and sp >= 2) {
                    sp -= 1;
                }
                levels[i] = stack[sp - 1].level;
            },
            .B => levels[i] = para,
            .BN => levels[i] = stack[sp - 1].level,
            else => {
                const top = stack[sp - 1];
                levels[i] = top.level;
                if (top.override) |o| types[i] = o;
            },
        }
    }

    // X9: the kept code points, in order. X10: level runs of them.
    var kept: std.ArrayList(u32) = .empty;
    defer kept.deinit(alloc);
    for (classes, 0..) |c, i| {
        if (!isRemoved(c)) try kept.append(alloc, @intCast(i));
    }
    // run_start[r] is the index in `kept` where run r starts.
    var run_start: std.ArrayList(u32) = .empty;
    defer run_start.deinit(alloc);
    // run_of[i] is the run of code point i.
    const run_of = scratch;
    for (kept.items, 0..) |i, k| {
        if (k == 0 or levels[i] != levels[kept.items[k - 1]]) {
            try run_start.append(alloc, @intCast(k));
        }
        run_of[i] = @intCast(run_start.items.len - 1);
    }
    try run_start.append(alloc, @intCast(kept.items.len));

    // BD13: isolating run sequences. A run that starts with a matched PDI
    // continues the sequence of its isolate initiator.
    var seq: std.ArrayList(u32) = .empty;
    defer seq.deinit(alloc);
    var seq_types: std.ArrayList(Class) = .empty;
    defer seq_types.deinit(alloc);
    const run_count = run_start.items.len - 1;
    for (0..run_count) |first_run| {
        const head = kept.items[run_start.items[first_run]];
        if (classes[head] == .PDI and matched_pdi[head]) continue;
        seq.clearRetainingCapacity();
        var run = first_run;
        while (true) {
            const lo = run_start.items[run];
            const hi = run_start.items[run + 1];
            try seq.appendSlice(alloc, kept.items[lo..hi]);
            const last = kept.items[hi - 1];
            if (!isIsolateStart(classes[last]) or match[last] == none) break;
            run = run_of[match[last]];
        }
        seq_types.clearRetainingCapacity();
        for (seq.items) |i| try seq_types.append(alloc, types[i]);
        try resolveSequence(alloc, codepoints, classes, levels, para, seq.items, seq_types.items);
        for (seq.items, seq_types.items) |i, t| types[i] = t;
    }

    // I1, I2.
    for (kept.items) |i| {
        const t = types[i];
        if (levels[i] & 1 == 0) {
            switch (t) {
                .R => levels[i] += 1,
                .AN, .EN => levels[i] += 2,
                else => {},
            }
        } else {
            switch (t) {
                .L, .EN, .AN => levels[i] += 1,
                else => {},
            }
        }
    }

    // The code points that X9 removed take the level before them.
    for (classes, 0..) |c, i| {
        if (isRemoved(c)) levels[i] = if (i == 0) para else levels[i - 1];
    }
    return para;
}

/// Rules W1 to W7 and N0 to N2 on one isolating run sequence. `seq` holds the
/// code point indexes, and `t` their types (changed in place).
fn resolveSequence(
    alloc: std.mem.Allocator,
    codepoints: []const u21,
    classes: []const Class,
    levels: []const u8,
    para: u8,
    seq: []const u32,
    t: []Class,
) !void {
    const len = seq.len;
    if (len == 0) return;
    const level = levels[seq[0]];
    const embedding = directionOfLevel(level);

    // sos and eos (X10).
    var prev = seq[0];
    while (prev > 0 and isRemoved(classes[prev - 1])) prev -= 1;
    const prev_level = if (prev > 0) levels[prev - 1] else para;
    const sos = directionOfLevel(@max(level, prev_level));

    const last = seq[len - 1];
    var next_level = para;
    if (!isIsolateStart(classes[last])) {
        var next = last + 1;
        while (next < classes.len and isRemoved(classes[next])) next += 1;
        if (next < classes.len) next_level = levels[next];
    }
    const eos = directionOfLevel(@max(level, next_level));

    // W1.
    for (0..len) |k| {
        if (t[k] != .NSM) continue;
        t[k] = if (k == 0) sos else switch (t[k - 1]) {
            .LRI, .RLI, .FSI, .PDI => .ON,
            else => t[k - 1],
        };
    }

    // W2.
    var last_strong = sos;
    for (t) |*c| {
        switch (c.*) {
            .L, .R, .AL => last_strong = c.*,
            .EN => if (last_strong == .AL) {
                c.* = .AN;
            },
            else => {},
        }
    }

    // W3.
    for (t) |*c| {
        if (c.* == .AL) c.* = .R;
    }

    // W4.
    if (len >= 3) {
        for (1..len - 1) |k| {
            const before = t[k - 1];
            const after = t[k + 1];
            if (t[k] == .ES and before == .EN and after == .EN) {
                t[k] = .EN;
            } else if (t[k] == .CS and before == after and (before == .EN or before == .AN)) {
                t[k] = before;
            }
        }
    }

    // W5.
    var k: usize = 0;
    while (k < len) {
        if (t[k] != .ET) {
            k += 1;
            continue;
        }
        const start = k;
        while (k < len and t[k] == .ET) k += 1;
        const touches_en = (start > 0 and t[start - 1] == .EN) or (k < len and t[k] == .EN);
        if (touches_en) @memset(t[start..k], .EN);
    }

    // W6.
    for (t) |*c| {
        switch (c.*) {
            .ES, .ET, .CS => c.* = .ON,
            else => {},
        }
    }

    // W7.
    last_strong = sos;
    for (t) |*c| {
        switch (c.*) {
            .L, .R => last_strong = c.*,
            .EN => if (last_strong == .L) {
                c.* = .L;
            },
            else => {},
        }
    }

    // N0: bracket pairs.
    try resolveBrackets(alloc, codepoints, classes, seq, t, sos, embedding);

    // N1, N2.
    k = 0;
    while (k < len) {
        if (!isNeutral(t[k])) {
            k += 1;
            continue;
        }
        const start = k;
        while (k < len and isNeutral(t[k])) k += 1;
        const before = if (start == 0) sos else strongOf(t[start - 1]) orelse embedding;
        const after = if (k == len) eos else strongOf(t[k]) orelse embedding;
        @memset(t[start..k], if (before == after) before else embedding);
    }
}

const Pair = struct { open: u32, close: u32 };

fn pairLessThan(_: void, a: Pair, b: Pair) bool {
    return a.open < b.open;
}

/// BD16 and N0.
fn resolveBrackets(
    alloc: std.mem.Allocator,
    codepoints: []const u21,
    classes: []const Class,
    seq: []const u32,
    t: []Class,
    sos: Class,
    embedding: Class,
) !void {
    const Open = struct { closer: u21, at: u32 };
    var open: [max_brackets]Open = undefined;
    var depth: usize = 0;
    var pairs: std.ArrayList(Pair) = .empty;
    defer pairs.deinit(alloc);

    for (seq, 0..) |i, k| {
        if (t[k] != .ON) continue;
        const b = bracketOf(codepoints[i]) orelse continue;
        if (b.open) {
            if (depth == max_brackets) break;
            open[depth] = .{ .closer = canonicalBracket(b.pair), .at = @intCast(k) };
            depth += 1;
        } else {
            const closer = canonicalBracket(codepoints[i]);
            var d = depth;
            while (d > 0) {
                d -= 1;
                if (open[d].closer == closer) {
                    try pairs.append(alloc, .{ .open = open[d].at, .close = @intCast(k) });
                    depth = d;
                    break;
                }
            }
        }
    }
    std.mem.sort(Pair, pairs.items, {}, pairLessThan);

    const opposite: Class = if (embedding == .L) .R else .L;
    for (pairs.items) |pair| {
        var has_embedding = false;
        var has_opposite = false;
        for (t[pair.open + 1 .. pair.close]) |c| {
            const s = strongOf(c) orelse continue;
            if (s == embedding) has_embedding = true else has_opposite = true;
        }
        const resolved: Class = if (has_embedding) embedding else if (has_opposite) blk: {
            var context = sos;
            var j = pair.open;
            while (j > 0) {
                j -= 1;
                if (strongOf(t[j])) |s| {
                    context = s;
                    break;
                }
            }
            break :blk if (context == opposite) opposite else embedding;
        } else continue;

        t[pair.open] = resolved;
        t[pair.close] = resolved;
        // Marks after a changed bracket take its type.
        for ([_]u32{ pair.open, pair.close }) |at| {
            var j = at + 1;
            while (j < seq.len and classes[seq[j]] == .NSM) : (j += 1) t[j] = resolved;
        }
    }
}

/// Rules L1 and L2 on one line. `classes` and `levels` are the line's part of
/// the arrays given to `resolveLevels`, and `para` is its paragraph level.
/// `levels` changes (L1). `order` gets the logical index of each visual
/// position, from left to right.
pub fn reorderLine(classes: []const Class, levels: []u8, para: u8, order: []u32) void {
    std.debug.assert(classes.len == levels.len and order.len == levels.len);
    // L1.
    var trailing = true;
    var i = classes.len;
    while (i > 0) {
        i -= 1;
        const c = classes[i];
        if (c == .S or c == .B) {
            levels[i] = para;
            trailing = true;
        } else if (isLineEndSpace(c)) {
            if (trailing) levels[i] = para;
        } else {
            trailing = false;
        }
    }

    // L2.
    for (order, 0..) |*o, k| o.* = @intCast(k);
    var highest: u8 = 0;
    var lowest_odd: u8 = max_depth + 2;
    for (levels) |l| {
        highest = @max(highest, l);
        if (l & 1 == 1) lowest_odd = @min(lowest_odd, l);
    }
    var level = highest;
    while (level >= lowest_odd and level > 0) : (level -= 1) {
        var k: usize = 0;
        while (k < levels.len) {
            if (levels[order[k]] < level) {
                k += 1;
                continue;
            }
            const start = k;
            while (k < levels.len and levels[order[k]] >= level) k += 1;
            std.mem.reverse(u32, order[start..k]);
        }
    }
}

/// Text in visual order: the code points from left to right, with each one
/// in right-to-left text mirrored (rule L4), such as `(` for `)`.
pub const Visual = struct {
    codepoints: []u21,
    /// The byte offset in the source text of each code point.
    offsets: []usize,

    pub fn deinit(self: *Visual, alloc: std.mem.Allocator) void {
        alloc.free(self.codepoints);
        alloc.free(self.offsets);
        self.* = undefined;
    }
};

/// The resolved levels of a text. Use `line` to get one line in visual order.
/// Lines come from the logical text, for example from `layout.wrap`. `line`
/// reorders each line on its own (UAX #9 section 3.4).
pub const Paragraphs = struct {
    alloc: std.mem.Allocator,
    codepoints: []u21,
    /// The byte offset of each code point, and the text length at the end.
    offsets: []usize,
    classes: []Class,
    levels: []u8,
    /// The paragraph level of each code point.
    bases: []u8,

    /// Decode `text` (bad bytes give U+FFFD) and resolve its levels. A
    /// paragraph ends after each B, such as `\n`.
    pub fn init(alloc: std.mem.Allocator, text: []const u8, direction: Direction) !Paragraphs {
        var count: usize = 0;
        var it = utf8.Iterator.init(text);
        while (it.next()) |_| count += 1;

        const codepoints = try alloc.alloc(u21, count);
        errdefer alloc.free(codepoints);
        const offsets = try alloc.alloc(usize, count + 1);
        errdefer alloc.free(offsets);
        const classes = try alloc.alloc(Class, count);
        errdefer alloc.free(classes);
        const levels = try alloc.alloc(u8, count);
        errdefer alloc.free(levels);
        const bases = try alloc.alloc(u8, count);
        errdefer alloc.free(bases);

        it = utf8.Iterator.init(text);
        var k: usize = 0;
        while (it.next()) |item| : (k += 1) {
            codepoints[k] = item.codepoint;
            offsets[k] = item.start;
            classes[k] = classOf(item.codepoint);
        }
        offsets[count] = text.len;

        var start: usize = 0;
        while (start < count) {
            var end = start;
            while (end < count and classes[end] != .B) end += 1;
            if (end < count) end += 1;
            const para = try resolveLevels(alloc, codepoints[start..end], classes[start..end], direction, levels[start..end]);
            @memset(bases[start..end], para);
            start = end;
        }
        return .{
            .alloc = alloc,
            .codepoints = codepoints,
            .offsets = offsets,
            .classes = classes,
            .levels = levels,
            .bases = bases,
        };
    }

    pub fn deinit(self: *Paragraphs) void {
        self.alloc.free(self.codepoints);
        self.alloc.free(self.offsets);
        self.alloc.free(self.classes);
        self.alloc.free(self.levels);
        self.alloc.free(self.bases);
        self.* = undefined;
    }

    /// The index of the code point at byte `offset`, or the code point count.
    fn indexOf(self: *const Paragraphs, offset: usize) usize {
        return std.sort.lowerBound(usize, self.offsets, offset, orderUsize);
    }

    fn orderUsize(a: usize, b: usize) std.math.Order {
        return std.math.order(a, b);
    }

    /// The bytes `text[start..end]` as one line in visual order. `start` and
    /// `end` are at code point boundaries. The caller frees the result with
    /// `deinit`.
    pub fn line(self: *const Paragraphs, alloc: std.mem.Allocator, start: usize, end: usize) !Visual {
        const lo = self.indexOf(start);
        const hi = @max(lo, self.indexOf(end));
        const n = hi - lo;
        const codepoints = try alloc.alloc(u21, n);
        errdefer alloc.free(codepoints);
        const offsets = try alloc.alloc(usize, n);
        errdefer alloc.free(offsets);
        if (n == 0) return .{ .codepoints = codepoints, .offsets = offsets };

        const levels = try alloc.dupe(u8, self.levels[lo..hi]);
        defer alloc.free(levels);
        const order = try alloc.alloc(u32, n);
        defer alloc.free(order);
        reorderLine(self.classes[lo..hi], levels, self.bases[lo], order);

        for (order, 0..) |o, k| {
            const cp = self.codepoints[lo + o];
            codepoints[k] = if (levels[o] & 1 == 1) mirror(cp) else cp;
            offsets[k] = self.offsets[lo + o];
        }
        return .{ .codepoints = codepoints, .offsets = offsets };
    }
};

/// `text` as one line in visual order. The caller frees the result with
/// `deinit`.
pub fn visual(alloc: std.mem.Allocator, text: []const u8, direction: Direction) !Visual {
    var p = try Paragraphs.init(alloc, text, direction);
    defer p.deinit();
    return p.line(alloc, 0, text.len);
}

const testing = std.testing;

/// The notation of the UAX #9 examples: an upper-case letter is right to
/// left (R), a lower-case letter is left to right (L), `<` is RLI, `>` is LRI
/// and `=` is PDI. Other code points have their real type.
fn exampleClass(cp: u21) Class {
    return switch (cp) {
        'A'...'Z' => .R,
        'a'...'z' => .L,
        '<' => .RLI,
        '>' => .LRI,
        '=' => .PDI,
        else => classOf(cp),
    };
}

/// The display of `storage` (in the example notation) on one line, as in
/// UAX #9: the visual order, with mirrored brackets.
fn expectDisplay(storage: []const u8, direction: Direction, want: []const u8) !void {
    const alloc = testing.allocator;
    var cps: std.ArrayList(u21) = .empty;
    defer cps.deinit(alloc);
    var it = utf8.Iterator.init(storage);
    while (it.next()) |item| try cps.append(alloc, item.codepoint);
    const n = cps.items.len;
    const classes = try alloc.alloc(Class, n);
    defer alloc.free(classes);
    for (cps.items, classes) |cp, *c| c.* = exampleClass(cp);
    const levels = try alloc.alloc(u8, n);
    defer alloc.free(levels);
    const para = try resolveLevels(alloc, cps.items, classes, direction, levels);
    const order = try alloc.alloc(u32, n);
    defer alloc.free(order);
    reorderLine(classes, levels, para, order);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    for (order) |o| {
        // The notation characters stand for controls: they do not mirror.
        const notation = classes[o] == .RLI or classes[o] == .LRI or classes[o] == .PDI;
        const cp = if (levels[o] & 1 == 1 and !notation) mirror(cps.items[o]) else cps.items[o];
        var buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(cp, &buf);
        try out.appendSlice(alloc, buf[0..len]);
    }
    try testing.expectEqualStrings(want, out.items);
}

test "UAX #9 reordering examples (section 3.4)" {
    try expectDisplay("car means CAR.", .ltr, "car means RAC.");
    try expectDisplay("<car MEANS CAR.=", .ltr, "<.RAC SNAEM car=");
    try expectDisplay("he said “<car MEANS CAR=.”", .ltr, "he said “<RAC SNAEM car=.”");
    try expectDisplay("DID YOU SAY ’>he said “<car MEANS CAR=”=‘?", .rtl, "?‘=he said “<RAC SNAEM car=”>’ YAS UOY DID");
}

test "UAX #9 bracket pair examples (rule N0)" {
    try expectDisplay("AB(CD[&ef]!)gh", .rtl, "gh(![ef&]DC)BA");
    try expectDisplay("smith (fabrikam ARABIC) HEBREW", .rtl, "WERBEH (CIBARA fabrikam) smith");
    try expectDisplay("ARABIC book(s)", .rtl, "book(s) CIBARA");
}

test "the paragraph direction comes from the first strong letter" {
    try expectDisplay("ABC def", .auto, "def CBA");
    try expectDisplay("abc DEF", .auto, "abc FED");
    // The text in an isolate does not count (rule P2).
    try expectDisplay(">abc= DEF", .auto, "FED =abc>");
    // No strong letter gives left to right.
    try expectDisplay("123 !", .auto, "123 !");
}

test "numbers keep their order in right-to-left text" {
    try expectDisplay("ABC 123 DEF", .ltr, "FED 123 CBA");
    try expectDisplay("abc 12.5 ABC", .rtl, "CBA abc 12.5");
}

/// Lines from BidiCharacterTest.txt (Unicode 16.0.0). The fields are:
/// - the code points
/// - the direction: 0 is left to right, 1 is right to left, 2 is auto
/// - the paragraph level
/// - the levels, with x for a removed code point
/// - the visual order
/// The full file passes too. It is too large to keep here.
const conformance_sample =
    \\05D0 05D1 0028 05D2 05D3 005B 0026 0065 0066 005D 002E 0029 0067 0068;0;0;1 1 0 1 1 0 0 0 0 0 0 0 0 0;1 0 2 4 3 5 6 7 8 9 10 11 12 13
    \\0028 0061 2680 0028 0062 0029 0029;1;1;1 2 2 2 2 2 1;6 1 2 3 4 5 0
    \\202B 0061 0028 0062 202C 202E 0029;2;0;x 2 2 2 x x 1;6 1 2 3
    \\0061 0028 0062 2067 05D0 0066 2069 05D4 0029 05D5;1;1;2 1 2 1 3 4 1 1 1 1;9 8 7 6 5 4 3 2 1 0
    \\0661 002D 0031;0;0;2 0 0;0 1 2
    \\0061 202E 05D0 202C 0020 0031 0020 0032 002D 0033;1;1;2 x 3 x 1 2 1 2 2 2;7 8 9 6 5 4 0 2
    \\202D 0661 202B 0662 202C 2068 0663 2069 202B 0664 202C 0665 202C;0;0;x 2 x 4 x 2 6 2 x 4 x 2 x;1 3 5 6 7 9 11
    \\202A 0661 0028 05D0 0029;2;1;x 4 3 3 3;4 3 2 1
    \\0061 202D 002A 202C 0020 0031 0020 0032 002D 0033;1;1;2 x 2 x 2 2 2 2 2 2;0 2 4 5 6 7 8 9
    \\0627 202B 202C 0020 0031 002D 0032;0;0;1 x x 1 2 1 2;6 5 4 3 0
;

test "a sample of the Unicode conformance test passes" {
    const alloc = testing.allocator;
    var lines = std.mem.splitScalar(u8, conformance_sample, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ';');
        var cps: std.ArrayList(u21) = .empty;
        defer cps.deinit(alloc);
        var hex = std.mem.tokenizeScalar(u8, fields.next().?, ' ');
        while (hex.next()) |h| try cps.append(alloc, try std.fmt.parseInt(u21, h, 16));
        const direction: Direction = switch (fields.next().?[0]) {
            '0' => .ltr,
            '1' => .rtl,
            else => .auto,
        };
        const want_para = try std.fmt.parseInt(u8, fields.next().?, 10);

        const n = cps.items.len;
        const classes = try alloc.alloc(Class, n);
        defer alloc.free(classes);
        for (cps.items, classes) |cp, *c| c.* = classOf(cp);
        const levels = try alloc.alloc(u8, n);
        defer alloc.free(levels);
        const order = try alloc.alloc(u32, n);
        defer alloc.free(order);
        const para = try resolveLevels(alloc, cps.items, classes, direction, levels);
        reorderLine(classes, levels, para, order);
        try testing.expectEqual(want_para, para);

        var want_levels = std.mem.tokenizeScalar(u8, fields.next().?, ' ');
        var k: usize = 0;
        while (want_levels.next()) |w| : (k += 1) {
            if (w[0] == 'x') continue;
            try testing.expectEqual(try std.fmt.parseInt(u8, w, 10), levels[k]);
        }
        var want_order = std.mem.tokenizeScalar(u8, fields.next().?, ' ');
        for (order) |o| {
            if (isRemoved(classes[o])) continue;
            try testing.expectEqual(try std.fmt.parseInt(u32, want_order.next().?, 10), o);
        }
        try testing.expect(want_order.next() == null);
    }
}

test "character data" {
    try testing.expectEqual(Class.L, classOf('a'));
    try testing.expectEqual(Class.R, classOf(0x05D0));
    try testing.expectEqual(Class.AL, classOf(0x0627));
    try testing.expectEqual(Class.EN, classOf('1'));
    try testing.expectEqual(Class.AN, classOf(0x0661));
    try testing.expectEqual(Class.WS, classOf(' '));
    try testing.expectEqual(Class.B, classOf('\n'));
    try testing.expectEqual(Class.NSM, classOf(0x0301));
    // An unassigned code point in the Hebrew block is R by default.
    try testing.expectEqual(Class.R, classOf(0x05FF));
    try testing.expectEqual(@as(u21, ')'), mirror('('));
    try testing.expectEqual(@as(u21, '«'), mirror('»'));
    try testing.expectEqual(@as(u21, 'a'), mirror('a'));
    try testing.expect(isFormat(0x200F));
    try testing.expect(isFormat(0x2067));
    try testing.expect(!isFormat('a'));
}

test "left-to-right text needs no reordering" {
    try testing.expect(isLeftToRight("Zażółć gęślą jaźń (1.5)"));
    try testing.expect(!isLeftToRight("abc \u{05D0}"));
    try testing.expect(!isLeftToRight("\u{0661}"));
    try testing.expect(!isLeftToRight("a\u{202E}b"));
}

test "visual reverses Hebrew and mirrors its brackets" {
    // "(אב) cd" in a left-to-right paragraph.
    var v = try visual(testing.allocator, "(\u{05D0}\u{05D1}) cd", .ltr);
    defer v.deinit(testing.allocator);
    // The brackets are between L (sos) and R, so they resolve to the
    // embedding direction (L) and are not mirrored.
    try testing.expectEqualSlices(u21, &.{ '(', 0x05D1, 0x05D0, ')', ' ', 'c', 'd' }, v.codepoints);
    try testing.expectEqualSlices(usize, &.{ 0, 3, 1, 5, 6, 7, 8 }, v.offsets);

    var r = try visual(testing.allocator, "\u{05D0}(\u{05D1})", .auto);
    defer r.deinit(testing.allocator);
    try testing.expectEqualSlices(u21, &.{ '(', 0x05D1, ')', 0x05D0 }, r.codepoints);
}

test "each line of a paragraph is reordered on its own" {
    const hebrew = "\u{05D0}\u{05D1} \u{05D2}\u{05D3} \u{05D4}\u{05D5}";
    var p = try Paragraphs.init(testing.allocator, hebrew, .auto);
    defer p.deinit();
    // Two lines, as `layout.wrap` breaks them: "אב גד" and "הו". Each is
    // reversed on its own, and the trailing space of the first line goes to
    // the paragraph level (rule L1).
    var first = try p.line(testing.allocator, 0, 10);
    defer first.deinit(testing.allocator);
    try testing.expectEqualSlices(u21, &.{ ' ', 0x05D3, 0x05D2, ' ', 0x05D1, 0x05D0 }, first.codepoints);
    var second = try p.line(testing.allocator, 10, hebrew.len);
    defer second.deinit(testing.allocator);
    try testing.expectEqualSlices(u21, &.{ 0x05D5, 0x05D4 }, second.codepoints);
}

test "a paragraph separator starts a new paragraph with its own direction" {
    var p = try Paragraphs.init(testing.allocator, "\u{05D0}\nabc", .auto);
    defer p.deinit();
    try testing.expectEqual(@as(u8, 1), p.bases[0]);
    try testing.expectEqual(@as(u8, 0), p.bases[2]);
}
