//! A bitmap font for the demo text: 5 x 7 pixel glyphs in 6 x 8 cells,
//! for the space to "Z". The lower-case letters use the capitals. The menu
//! demo gives it as the bitmap-font option of sw_text (`BitmapFont`).
const std = @import("std");
const sw_text = @import("sw_text");

pub const cell_w = 6;
pub const cell_h = 8;
const first: u8 = 0x20;
const columns = 16;
const glyph_count = 59 + 26;
const rows = (glyph_count + columns - 1) / columns;
pub const sheet_w = columns * cell_w;
pub const sheet_h = rows * cell_h;

// The glyphs of the space (0x20) to "Z" (0x5A). Each glyph is 7 rows of 5
// bits. The high bit is the left column.
const glyphs = [59][7]u5{
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

/// The glyph sheet, the code point and the width of each cell.
pub const Sheet = struct {
    pixels: [sheet_w * sheet_h]u8,
    codepoints: [rows * columns]u21,
    widths: [rows * columns]u8,

    pub fn desc(self: *const Sheet) sw_text.BitmapFont.Desc {
        return .{
            .sheet = .{ .pixels = &self.pixels, .width = sheet_w, .height = sheet_h, .format = .alpha8 },
            .cell_width = cell_w,
            .cell_height = cell_h,
            .codepoints = &self.codepoints,
            .widths = &self.widths,
            .baseline = 7,
        };
    }
};

/// Draw each glyph into its cell.
pub fn makeSheet() Sheet {
    var s: Sheet = .{ .pixels = @splat(0), .codepoints = @splat(0), .widths = @splat(0) };
    for (0..glyph_count) |cell| {
        // Cells 59 to 84 are "a" to "z", with the glyphs of "A" to "Z".
        const glyph = if (cell < 59) cell else cell - 59 + ('A' - first);
        const cp: u21 = if (cell < 59) @intCast(first + cell) else @intCast('a' + cell - 59);
        s.codepoints[cell] = cp;
        s.widths[cell] = cell_w;
        const cx = (cell % columns) * cell_w;
        const cy = (cell / columns) * cell_h;
        for (glyphs[glyph], 0..) |row, y| {
            for (0..5) |x| {
                const bit = (@as(u8, row) >> @intCast(4 - x)) & 1;
                if (bit != 0) s.pixels[(cy + y) * sheet_w + cx + x] = 255;
            }
        }
    }
    return s;
}

test "bitmap font: the sheet has a glyph for A and for a" {
    const s = makeSheet();
    try std.testing.expectEqual(@as(u21, 'A'), s.codepoints['A' - first]);
    try std.testing.expectEqual(@as(u21, 'a'), s.codepoints[59]);
    var ink: usize = 0;
    for (s.pixels) |p| ink += @intFromBool(p != 0);
    try std.testing.expect(ink > 100);
}
