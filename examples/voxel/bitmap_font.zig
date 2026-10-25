// ─── Bitmap font + text rendering ────────────────────────────────────────────
// 5×7 pixel bitmap font covering ASCII 0x20 (space) to 0x5A (Z).
// Each glyph is 7 rows of 5 bits; MSB is the leftmost column.
// Lowercase a–z are automatically promoted to uppercase in drawChar.
// Entries for unused punctuation are all-zero (invisible placeholder).

const OverlayRenderer = @import("overlay.zig").OverlayRenderer;

pub const GLYPH_W: f32 = 5; // glyph width  in bitmap pixels
pub const GLYPH_H: f32 = 7; // glyph height in bitmap pixels
pub const GLYPH_GAP: f32 = 1; // horizontal gap between characters

// Scale used by the legacy step-mode HUD (kept for drawStepHud compatibility).
pub const DIGIT_SCALE: f32 = 3;
pub const DIGIT_STEP: f32 = (GLYPH_W + GLYPH_GAP) * DIGIT_SCALE;

pub const CHAR_FIRST: u8 = 0x20; // ' '
pub const CHAR_LAST: u8 = 0x5A; //  'Z'

// 59 entries: 0x20 … 0x5A
pub const char_bitmaps = [59][7]u5{
    // 0x20 ' '
    .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000 },
    // 0x21 '!'
    .{ 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00000, 0b00100 },
    // 0x22–0x27  (unused punctuation — invisible)
    .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000 },
    .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000 },
    .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000 },
    .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000 },
    .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000 },
    .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000 },
    // 0x28 '('
    .{ 0b00010, 0b00100, 0b01000, 0b01000, 0b01000, 0b00100, 0b00010 },
    // 0x29 ')'
    .{ 0b01000, 0b00100, 0b00010, 0b00010, 0b00010, 0b00100, 0b01000 },
    // 0x2A '*'  (unused)
    .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000 },
    // 0x2B '+'
    .{ 0b00000, 0b00100, 0b00100, 0b11111, 0b00100, 0b00100, 0b00000 },
    // 0x2C ','
    .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b01100, 0b00100, 0b01000 },
    // 0x2D '-'
    .{ 0b00000, 0b00000, 0b00000, 0b11111, 0b00000, 0b00000, 0b00000 },
    // 0x2E '.'
    .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b01100, 0b01100 },
    // 0x2F '/'
    .{ 0b00001, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b10000 },
    // 0x30 '0'
    .{ 0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110 },
    // 0x31 '1'
    .{ 0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 },
    // 0x32 '2'
    .{ 0b01110, 0b10001, 0b00001, 0b00110, 0b01000, 0b10000, 0b11111 },
    // 0x33 '3'
    .{ 0b11111, 0b00010, 0b00100, 0b00110, 0b00001, 0b10001, 0b01110 },
    // 0x34 '4'
    .{ 0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010 },
    // 0x35 '5'
    .{ 0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110 },
    // 0x36 '6'
    .{ 0b01110, 0b10000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110 },
    // 0x37 '7'
    .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000 },
    // 0x38 '8'
    .{ 0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110 },
    // 0x39 '9'
    .{ 0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00001, 0b01110 },
    // 0x3A ':'
    .{ 0b00000, 0b01100, 0b01100, 0b00000, 0b01100, 0b01100, 0b00000 },
    // 0x3B ';'  (unused)
    .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000 },
    // 0x3C '<'  (unused)
    .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000 },
    // 0x3D '='
    .{ 0b00000, 0b00000, 0b11111, 0b00000, 0b11111, 0b00000, 0b00000 },
    // 0x3E '>'  (used by pause-menu selection marker)
    .{ 0b10000, 0b01000, 0b00100, 0b00010, 0b00100, 0b01000, 0b10000 },
    // 0x3F '?'
    .{ 0b01110, 0b10001, 0b00001, 0b00110, 0b00100, 0b00000, 0b00100 },
    // 0x40 '@'  (unused)
    .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000 },
    // 0x41 'A'
    .{ 0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 },
    // 0x42 'B'
    .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110 },
    // 0x43 'C'
    .{ 0b01110, 0b10001, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110 },
    // 0x44 'D'
    .{ 0b11110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b11110 },
    // 0x45 'E'
    .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111 },
    // 0x46 'F'
    .{ 0b11111, 0b10000, 0b10000, 0b11100, 0b10000, 0b10000, 0b10000 },
    // 0x47 'G'
    .{ 0b01110, 0b10001, 0b10000, 0b10011, 0b10001, 0b10001, 0b01111 },
    // 0x48 'H'
    .{ 0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 },
    // 0x49 'I'
    .{ 0b01110, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 },
    // 0x4A 'J'
    .{ 0b00111, 0b00010, 0b00010, 0b00010, 0b10010, 0b10010, 0b01100 },
    // 0x4B 'K'
    .{ 0b10001, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001 },
    // 0x4C 'L'
    .{ 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111 },
    // 0x4D 'M'
    .{ 0b10001, 0b11011, 0b10101, 0b10101, 0b10001, 0b10001, 0b10001 },
    // 0x4E 'N'
    .{ 0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001, 0b10001 },
    // 0x4F 'O'
    .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 },
    // 0x50 'P'
    .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000 },
    // 0x51 'Q'
    .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101 },
    // 0x52 'R'
    .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001 },
    // 0x53 'S'
    .{ 0b01110, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b01110 },
    // 0x54 'T'
    .{ 0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100 },
    // 0x55 'U'
    .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 },
    // 0x56 'V'
    .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b01010, 0b00100 },
    // 0x57 'W'
    .{ 0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b11011, 0b10001 },
    // 0x58 'X'
    .{ 0b10001, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0b10001 },
    // 0x59 'Y'
    .{ 0b10001, 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b00100 },
    // 0x5A 'Z'
    .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111 },
};

/// Draw one character from the bitmap font at pixel position (x, y).
/// `scale` is the size in screen pixels of each bitmap pixel.
/// Lowercase a–z are automatically mapped to their uppercase equivalents.
/// Characters outside 0x20–0x5A are silently skipped (rendered blank).
pub fn drawChar(overlay: *OverlayRenderer, c: u8, x: f32, y: f32, col: [4]f32, scale: f32, ow: f32, oh: f32) !void {
    const ch = if (c >= 'a' and c <= 'z') c - 0x20 else c;
    if (ch < CHAR_FIRST or ch > CHAR_LAST) return;
    const bm = char_bitmaps[ch - CHAR_FIRST];
    for (bm, 0..) |row, ry| {
        for (0..5) |cx| {
            const bit: u3 = @intCast(4 - cx);
            if ((row >> bit) & 1 == 1) {
                const px = x + @as(f32, @floatFromInt(cx)) * scale;
                const py = y + @as(f32, @floatFromInt(ry)) * scale;
                try overlay.rect(px, py, scale, scale, col, ow, oh);
            }
        }
    }
}

/// Draw a string at pixel position (x, y).
/// Each character cell advances `(GLYPH_W + GLYPH_GAP) * scale` pixels.
pub fn drawText(overlay: *OverlayRenderer, text: []const u8, x: f32, y: f32, col: [4]f32, scale: f32, ow: f32, oh: f32) !void {
    const advance = (GLYPH_W + GLYPH_GAP) * scale;
    for (text, 0..) |c, i| {
        try drawChar(overlay, c, x + @as(f32, @floatFromInt(i)) * advance, y, col, scale, ow, oh);
    }
}

/// Draw a string horizontally centred on the screen at pixel row y.
pub fn drawCenteredText(overlay: *OverlayRenderer, text: []const u8, y: f32, col: [4]f32, scale: f32, ow: f32, oh: f32) !void {
    const text_w = @as(f32, @floatFromInt(text.len)) * (GLYPH_W + GLYPH_GAP) * scale;
    try drawText(overlay, text, (ow - text_w) / 2.0, y, col, scale, ow, oh);
}

// Legacy wrappers used by the step-mode HUD — draw at DIGIT_SCALE (3×).
fn drawDigit(overlay: *OverlayRenderer, digit: u8, x: f32, y: f32, col: [4]f32, ow: f32, oh: f32) !void {
    if (digit > 9) return;
    try drawChar(overlay, '0' + digit, x, y, col, DIGIT_SCALE, ow, oh);
}

fn drawNumber(overlay: *OverlayRenderer, n: u64, x: f32, y: f32, col: [4]f32, ow: f32, oh: f32) !void {
    var buf: [20]u8 = undefined;
    var len: usize = 0;
    var val = n;
    if (val == 0) {
        buf[0] = 0;
        len = 1;
    } else {
        while (val > 0) {
            buf[len] = @intCast(val % 10);
            len += 1;
            val /= 10;
        }
        var lo: usize = 0;
        var hi: usize = len - 1;
        while (lo < hi) {
            const tmp = buf[lo];
            buf[lo] = buf[hi];
            buf[hi] = tmp;
            lo += 1;
            hi -= 1;
        }
    }
    for (buf[0..len], 0..) |d, i| {
        try drawDigit(overlay, d, x + @as(f32, @floatFromInt(i)) * DIGIT_STEP, y, col, ow, oh);
    }
}

pub fn drawStepHud(
    overlay: *OverlayRenderer,
    tas_tick: u64,
    is_executing: bool,
    is_finished: bool,
    current_index: usize,
    total_events: usize,
    ow: f32,
    oh: f32,
) !void {
    const pad: f32 = 8;
    const bar_h: f32 = GLYPH_H * DIGIT_SCALE + pad * 2;
    const bar_w: f32 = 260;
    const bx = (ow - bar_w) / 2.0;
    const by: f32 = 6;

    // Background
    try overlay.rect(bx, by, bar_w, bar_h, .{ 0.04, 0.04, 0.08, 0.88 }, ow, oh);

    // State pill: green = executing step, amber = waiting for Right arrow, grey = finished
    const pill_col: [4]f32 = if (is_finished)
        .{ 0.55, 0.55, 0.55, 1.0 }
    else if (is_executing)
        .{ 0.25, 0.92, 0.35, 1.0 }
    else
        .{ 0.95, 0.72, 0.10, 1.0 };
    try overlay.rect(bx + pad, by + pad, 16, GLYPH_H * DIGIT_SCALE, pill_col, ow, oh);

    // "TICK" label — four small squares in a row, colour matches state
    const lbl_x = bx + pad + 16 + 6;
    const digit_y = by + pad;

    // Draw TAS tick number
    const white = [4]f32{ 0.95, 0.95, 0.95, 1.0 };
    try drawNumber(overlay, tas_tick, lbl_x, digit_y, white, ow, oh);

    // Progress bar (events consumed / total) at the bottom of the panel
    const prog_y = by + bar_h - 5;
    const prog_w = bar_w - pad * 2;
    try overlay.rect(bx + pad, prog_y, prog_w, 3, .{ 0.2, 0.2, 0.25, 0.9 }, ow, oh);
    if (total_events > 0) {
        const frac = @as(f32, @floatFromInt(current_index)) / @as(f32, @floatFromInt(total_events));
        try overlay.rect(bx + pad, prog_y, prog_w * frac, 3, pill_col, ow, oh);
    }
}
