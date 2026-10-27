//! sw_text - text from TrueType fonts, drawn with sw_gfx2d. Import it as
//! `const text = @import("sw_text");`.
//!
//! ```zig
//! var t = try text.TextRenderer.init(allocator, @embedFile("font.ttf"));
//! t.setDpiScale(ctx.window().dpi_scale);
//! _ = try t.drawWrapped(&renderer, "Café", 10, 10, 200, .{ .size = 16 });
//! ```
//!
//! Glyphs are drawn into the atlas when a string first uses them. A renderer
//! has a font chain: `addFont` and `addBitmapFont` add a face to the end, and
//! a code point draws with the first face that has it. A code point that no
//! face has draws as an outlined box. `initBitmap` starts the chain with a
//! bitmap font (a glyph sheet and a width table). Arabic letters take their
//! joined forms (`shape`), and the Unicode bidirectional algorithm (`bidi`)
//! puts each line in visual order, so mixed left-to-right and right-to-left
//! text draws in the correct order. A font that does not have a presentation
//! form draws the letter in its nominal form. The font reader is
//! stb_truetype, and the bidi and shaping data comes from the Unicode
//! Character Database (see THIRD_PARTY_NOTICES.md).

const text_mod = @import("text.zig");

pub const utf8 = @import("utf8.zig");
pub const layout = @import("layout.zig");
pub const atlas = @import("atlas.zig");
pub const bidi = @import("bidi.zig");
pub const shape = @import("shape.zig");
pub const caret = @import("caret.zig");
pub const CaretLayout = caret.CaretLayout;

pub const Font = @import("font.zig").Font;
pub const Metrics = @import("font.zig").Metrics;
pub const BitmapFont = @import("bitmap_font.zig").BitmapFont;
pub const Face = @import("face.zig").Face;
pub const ChainMetrics = @import("face.zig").ChainMetrics;
pub const Direction = bidi.Direction;

pub const TextRenderer = text_mod.TextRenderer;
pub const Style = text_mod.Style;
pub const Size = text_mod.Size;
pub const Line = layout.Line;
