//! A pixel font for the menu demo: the printable ASCII characters, drawn by
//! hand on a grid of 5 x 9 pixels. Rows 0 to 6 are above the baseline, and
//! rows 7 and 8 are the descenders (g, j, p, q, y, the comma). Each glyph
//! has its own advance, so i and l are narrow. Draw it only at a whole
//! number scale (`BitmapFont.Desc.integer_scale`): then each stroke has the
//! same width.
//!
//! The table comes from a list of rows of '#' and '.' (one glyph each), so
//! each row here is a 5-bit number: the high bit is the left column.

const std = @import("std");

pub const Glyph = struct {
    cp: u21,
    /// The pen movement after the glyph, in font pixels.
    advance: u8,
    rows: [9]u5,
};

/// One cell of the sheet: the 5 columns of a glyph and one empty column, and
/// the 9 rows and one empty row.
pub const cell_width = 6;
pub const cell_height = 10;
/// The rows from the top of a cell to the baseline.
pub const baseline = 7;
pub const columns = 16;

pub const glyphs = [_]Glyph{
    .{ .cp = ' ', .advance = 4, .rows = .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000 } },
    .{ .cp = '!', .advance = 4, .rows = .{ 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b00000, 0b10000, 0b00000, 0b00000 } },
    .{ .cp = '"', .advance = 6, .rows = .{ 0b01010, 0b01010, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000 } },
    .{ .cp = '#', .advance = 6, .rows = .{ 0b01010, 0b01010, 0b11111, 0b01010, 0b11111, 0b01010, 0b01010, 0b00000, 0b00000 } },
    .{ .cp = '$', .advance = 6, .rows = .{ 0b00100, 0b01111, 0b10100, 0b01110, 0b00101, 0b11110, 0b00100, 0b00000, 0b00000 } },
    .{ .cp = '%', .advance = 6, .rows = .{ 0b11000, 0b11001, 0b00010, 0b00100, 0b01000, 0b10011, 0b00011, 0b00000, 0b00000 } },
    .{ .cp = '&', .advance = 6, .rows = .{ 0b01100, 0b10010, 0b10100, 0b01000, 0b10101, 0b10010, 0b01101, 0b00000, 0b00000 } },
    .{ .cp = '\'', .advance = 4, .rows = .{ 0b10000, 0b10000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000 } },
    .{ .cp = '(', .advance = 5, .rows = .{ 0b00100, 0b01000, 0b10000, 0b10000, 0b10000, 0b01000, 0b00100, 0b00000, 0b00000 } },
    .{ .cp = ')', .advance = 5, .rows = .{ 0b10000, 0b01000, 0b00100, 0b00100, 0b00100, 0b01000, 0b10000, 0b00000, 0b00000 } },
    .{ .cp = '*', .advance = 6, .rows = .{ 0b00000, 0b00100, 0b10101, 0b01110, 0b10101, 0b00100, 0b00000, 0b00000, 0b00000 } },
    .{ .cp = '+', .advance = 6, .rows = .{ 0b00000, 0b00100, 0b00100, 0b11111, 0b00100, 0b00100, 0b00000, 0b00000, 0b00000 } },
    .{ .cp = ',', .advance = 4, .rows = .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b11000, 0b11000, 0b01000, 0b10000 } },
    .{ .cp = '-', .advance = 6, .rows = .{ 0b00000, 0b00000, 0b00000, 0b11111, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000 } },
    .{ .cp = '.', .advance = 4, .rows = .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b11000, 0b11000, 0b00000, 0b00000 } },
    .{ .cp = '/', .advance = 6, .rows = .{ 0b00001, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b10000, 0b00000, 0b00000 } },
    .{ .cp = '0', .advance = 6, .rows = .{ 0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110, 0b00000, 0b00000 } },
    .{ .cp = '1', .advance = 6, .rows = .{ 0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110, 0b00000, 0b00000 } },
    .{ .cp = '2', .advance = 6, .rows = .{ 0b01110, 0b10001, 0b00001, 0b00110, 0b01000, 0b10000, 0b11111, 0b00000, 0b00000 } },
    .{ .cp = '3', .advance = 6, .rows = .{ 0b11111, 0b00010, 0b00100, 0b00010, 0b00001, 0b10001, 0b01110, 0b00000, 0b00000 } },
    .{ .cp = '4', .advance = 6, .rows = .{ 0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010, 0b00000, 0b00000 } },
    .{ .cp = '5', .advance = 6, .rows = .{ 0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110, 0b00000, 0b00000 } },
    .{ .cp = '6', .advance = 6, .rows = .{ 0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110, 0b00000, 0b00000 } },
    .{ .cp = '7', .advance = 6, .rows = .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000, 0b00000, 0b00000 } },
    .{ .cp = '8', .advance = 6, .rows = .{ 0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110, 0b00000, 0b00000 } },
    .{ .cp = '9', .advance = 6, .rows = .{ 0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b01100, 0b00000, 0b00000 } },
    .{ .cp = ':', .advance = 4, .rows = .{ 0b00000, 0b11000, 0b11000, 0b00000, 0b11000, 0b11000, 0b00000, 0b00000, 0b00000 } },
    .{ .cp = ';', .advance = 4, .rows = .{ 0b00000, 0b11000, 0b11000, 0b00000, 0b11000, 0b11000, 0b01000, 0b10000, 0b00000 } },
    .{ .cp = '<', .advance = 6, .rows = .{ 0b00010, 0b00100, 0b01000, 0b10000, 0b01000, 0b00100, 0b00010, 0b00000, 0b00000 } },
    .{ .cp = '=', .advance = 6, .rows = .{ 0b00000, 0b00000, 0b11111, 0b00000, 0b11111, 0b00000, 0b00000, 0b00000, 0b00000 } },
    .{ .cp = '>', .advance = 6, .rows = .{ 0b01000, 0b00100, 0b00010, 0b00001, 0b00010, 0b00100, 0b01000, 0b00000, 0b00000 } },
    .{ .cp = '?', .advance = 6, .rows = .{ 0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b00000, 0b00100, 0b00000, 0b00000 } },
    .{ .cp = '@', .advance = 6, .rows = .{ 0b01110, 0b10001, 0b10111, 0b10101, 0b10111, 0b10000, 0b01111, 0b00000, 0b00000 } },
    .{ .cp = 'A', .advance = 6, .rows = .{ 0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001, 0b00000, 0b00000 } },
    .{ .cp = 'B', .advance = 6, .rows = .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110, 0b00000, 0b00000 } },
    .{ .cp = 'C', .advance = 6, .rows = .{ 0b01110, 0b10001, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110, 0b00000, 0b00000 } },
    .{ .cp = 'D', .advance = 6, .rows = .{ 0b11110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b11110, 0b00000, 0b00000 } },
    .{ .cp = 'E', .advance = 6, .rows = .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111, 0b00000, 0b00000 } },
    .{ .cp = 'F', .advance = 6, .rows = .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000, 0b00000, 0b00000 } },
    .{ .cp = 'G', .advance = 6, .rows = .{ 0b01110, 0b10001, 0b10000, 0b10111, 0b10001, 0b10001, 0b01111, 0b00000, 0b00000 } },
    .{ .cp = 'H', .advance = 6, .rows = .{ 0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001, 0b00000, 0b00000 } },
    .{ .cp = 'I', .advance = 5, .rows = .{ 0b11100, 0b01000, 0b01000, 0b01000, 0b01000, 0b01000, 0b11100, 0b00000, 0b00000 } },
    .{ .cp = 'J', .advance = 6, .rows = .{ 0b00111, 0b00010, 0b00010, 0b00010, 0b00010, 0b10010, 0b01100, 0b00000, 0b00000 } },
    .{ .cp = 'K', .advance = 6, .rows = .{ 0b10001, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001, 0b00000, 0b00000 } },
    .{ .cp = 'L', .advance = 6, .rows = .{ 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111, 0b00000, 0b00000 } },
    .{ .cp = 'M', .advance = 6, .rows = .{ 0b10001, 0b11011, 0b10101, 0b10101, 0b10001, 0b10001, 0b10001, 0b00000, 0b00000 } },
    .{ .cp = 'N', .advance = 6, .rows = .{ 0b10001, 0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001, 0b00000, 0b00000 } },
    .{ .cp = 'O', .advance = 6, .rows = .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110, 0b00000, 0b00000 } },
    .{ .cp = 'P', .advance = 6, .rows = .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000, 0b00000, 0b00000 } },
    .{ .cp = 'Q', .advance = 6, .rows = .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101, 0b00000, 0b00000 } },
    .{ .cp = 'R', .advance = 6, .rows = .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001, 0b00000, 0b00000 } },
    .{ .cp = 'S', .advance = 6, .rows = .{ 0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110, 0b00000, 0b00000 } },
    .{ .cp = 'T', .advance = 6, .rows = .{ 0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00000, 0b00000 } },
    .{ .cp = 'U', .advance = 6, .rows = .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110, 0b00000, 0b00000 } },
    .{ .cp = 'V', .advance = 6, .rows = .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100, 0b00000, 0b00000 } },
    .{ .cp = 'W', .advance = 6, .rows = .{ 0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b10101, 0b01010, 0b00000, 0b00000 } },
    .{ .cp = 'X', .advance = 6, .rows = .{ 0b10001, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0b10001, 0b00000, 0b00000 } },
    .{ .cp = 'Y', .advance = 6, .rows = .{ 0b10001, 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b00100, 0b00000, 0b00000 } },
    .{ .cp = 'Z', .advance = 6, .rows = .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111, 0b00000, 0b00000 } },
    .{ .cp = '[', .advance = 5, .rows = .{ 0b11100, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11100, 0b00000, 0b00000 } },
    .{ .cp = '\\', .advance = 6, .rows = .{ 0b10000, 0b10000, 0b01000, 0b00100, 0b00010, 0b00001, 0b00001, 0b00000, 0b00000 } },
    .{ .cp = ']', .advance = 5, .rows = .{ 0b11100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b11100, 0b00000, 0b00000 } },
    .{ .cp = '^', .advance = 6, .rows = .{ 0b00100, 0b01010, 0b10001, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000 } },
    .{ .cp = '_', .advance = 6, .rows = .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b11111, 0b00000 } },
    .{ .cp = '`', .advance = 4, .rows = .{ 0b10000, 0b01000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000 } },
    .{ .cp = 'a', .advance = 6, .rows = .{ 0b00000, 0b00000, 0b01110, 0b00001, 0b01111, 0b10001, 0b01111, 0b00000, 0b00000 } },
    .{ .cp = 'b', .advance = 6, .rows = .{ 0b10000, 0b10000, 0b11110, 0b10001, 0b10001, 0b10001, 0b11110, 0b00000, 0b00000 } },
    .{ .cp = 'c', .advance = 6, .rows = .{ 0b00000, 0b00000, 0b01110, 0b10000, 0b10000, 0b10001, 0b01110, 0b00000, 0b00000 } },
    .{ .cp = 'd', .advance = 6, .rows = .{ 0b00001, 0b00001, 0b01111, 0b10001, 0b10001, 0b10001, 0b01111, 0b00000, 0b00000 } },
    .{ .cp = 'e', .advance = 6, .rows = .{ 0b00000, 0b00000, 0b01110, 0b10001, 0b11111, 0b10000, 0b01110, 0b00000, 0b00000 } },
    .{ .cp = 'f', .advance = 6, .rows = .{ 0b00110, 0b01001, 0b01000, 0b11100, 0b01000, 0b01000, 0b01000, 0b00000, 0b00000 } },
    .{ .cp = 'g', .advance = 6, .rows = .{ 0b00000, 0b00000, 0b01111, 0b10001, 0b10001, 0b01111, 0b00001, 0b10001, 0b01110 } },
    .{ .cp = 'h', .advance = 6, .rows = .{ 0b10000, 0b10000, 0b10110, 0b11001, 0b10001, 0b10001, 0b10001, 0b00000, 0b00000 } },
    .{ .cp = 'i', .advance = 5, .rows = .{ 0b01000, 0b00000, 0b11000, 0b01000, 0b01000, 0b01000, 0b11100, 0b00000, 0b00000 } },
    .{ .cp = 'j', .advance = 6, .rows = .{ 0b00010, 0b00000, 0b00110, 0b00010, 0b00010, 0b00010, 0b00010, 0b10010, 0b01100 } },
    .{ .cp = 'k', .advance = 6, .rows = .{ 0b10000, 0b10000, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b00000, 0b00000 } },
    .{ .cp = 'l', .advance = 5, .rows = .{ 0b11000, 0b01000, 0b01000, 0b01000, 0b01000, 0b01000, 0b11100, 0b00000, 0b00000 } },
    .{ .cp = 'm', .advance = 6, .rows = .{ 0b00000, 0b00000, 0b11010, 0b10101, 0b10101, 0b10001, 0b10001, 0b00000, 0b00000 } },
    .{ .cp = 'n', .advance = 6, .rows = .{ 0b00000, 0b00000, 0b10110, 0b11001, 0b10001, 0b10001, 0b10001, 0b00000, 0b00000 } },
    .{ .cp = 'o', .advance = 6, .rows = .{ 0b00000, 0b00000, 0b01110, 0b10001, 0b10001, 0b10001, 0b01110, 0b00000, 0b00000 } },
    .{ .cp = 'p', .advance = 6, .rows = .{ 0b00000, 0b00000, 0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000 } },
    .{ .cp = 'q', .advance = 6, .rows = .{ 0b00000, 0b00000, 0b01111, 0b10001, 0b10001, 0b01111, 0b00001, 0b00001, 0b00001 } },
    .{ .cp = 'r', .advance = 6, .rows = .{ 0b00000, 0b00000, 0b10110, 0b11001, 0b10000, 0b10000, 0b10000, 0b00000, 0b00000 } },
    .{ .cp = 's', .advance = 6, .rows = .{ 0b00000, 0b00000, 0b01111, 0b10000, 0b01110, 0b00001, 0b11110, 0b00000, 0b00000 } },
    .{ .cp = 't', .advance = 6, .rows = .{ 0b01000, 0b01000, 0b11100, 0b01000, 0b01000, 0b01001, 0b00110, 0b00000, 0b00000 } },
    .{ .cp = 'u', .advance = 6, .rows = .{ 0b00000, 0b00000, 0b10001, 0b10001, 0b10001, 0b10011, 0b01101, 0b00000, 0b00000 } },
    .{ .cp = 'v', .advance = 6, .rows = .{ 0b00000, 0b00000, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100, 0b00000, 0b00000 } },
    .{ .cp = 'w', .advance = 6, .rows = .{ 0b00000, 0b00000, 0b10001, 0b10001, 0b10101, 0b10101, 0b01010, 0b00000, 0b00000 } },
    .{ .cp = 'x', .advance = 6, .rows = .{ 0b00000, 0b00000, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0b00000, 0b00000 } },
    .{ .cp = 'y', .advance = 6, .rows = .{ 0b00000, 0b00000, 0b10001, 0b10001, 0b10001, 0b01111, 0b00001, 0b10001, 0b01110 } },
    .{ .cp = 'z', .advance = 6, .rows = .{ 0b00000, 0b00000, 0b11111, 0b00010, 0b00100, 0b01000, 0b11111, 0b00000, 0b00000 } },
    .{ .cp = '{', .advance = 5, .rows = .{ 0b00100, 0b01000, 0b01000, 0b10000, 0b01000, 0b01000, 0b00100, 0b00000, 0b00000 } },
    .{ .cp = '|', .advance = 4, .rows = .{ 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b00000 } },
    .{ .cp = '}', .advance = 5, .rows = .{ 0b10000, 0b01000, 0b01000, 0b00100, 0b01000, 0b01000, 0b10000, 0b00000, 0b00000 } },
    .{ .cp = '~', .advance = 6, .rows = .{ 0b00000, 0b00000, 0b01000, 0b10101, 0b00010, 0b00000, 0b00000, 0b00000, 0b00000 } },
};

pub const sheet_width = cell_width * columns;
pub const sheet_height = cell_height * ((glyphs.len + columns - 1) / columns);

/// Draw the glyph sheet into `pixels` (one coverage byte each, 0 or 255),
/// and give each cell its code point and advance.
pub fn fill(pixels: *[sheet_width * sheet_height]u8, codepoints: *[glyphs.len]u21, widths: *[glyphs.len]u8) void {
    @memset(pixels, 0);
    for (glyphs, 0..) |gl, i| {
        codepoints[i] = gl.cp;
        widths[i] = gl.advance;
        const cx = (i % columns) * cell_width;
        const cy = (i / columns) * cell_height;
        for (gl.rows, 0..) |row, y| {
            for (0..5) |x| {
                const bit = @as(u5, 1) << @intCast(4 - x);
                if (row & bit != 0) pixels[(cy + y) * sheet_width + cx + x] = 255;
            }
        }
    }
}

test "the pixel font has each printable ASCII character once" {
    var seen: std.StaticBitSet(128) = .initEmpty();
    for (glyphs) |gl| {
        try std.testing.expect(gl.cp >= 0x20 and gl.cp < 0x7F);
        try std.testing.expect(!seen.isSet(gl.cp));
        seen.set(gl.cp);
        try std.testing.expect(gl.advance >= 1 and gl.advance <= cell_width);
    }
    try std.testing.expectEqual(@as(usize, 95), seen.count());
}
