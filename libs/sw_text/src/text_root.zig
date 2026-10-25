//! sw_text - text from TrueType fonts, drawn with sw_gfx2d. Import it as
//! `const text = @import("sw_text");`.
//!
//! ```zig
//! var t = try text.TextRenderer.init(allocator, @embedFile("font.ttf"));
//! t.setDpiScale(ctx.window().dpi_scale);
//! _ = try t.drawWrapped(&renderer, "Café", 10, 10, 200, .{ .size = 16 });
//! ```
//!
//! Glyphs are drawn into the atlas when a string first uses them. A code point
//! the font lacks draws as an outlined box. The font reader is stb_truetype
//! (see THIRD_PARTY_NOTICES.md).

const text_mod = @import("text.zig");

pub const utf8 = @import("utf8.zig");
pub const layout = @import("layout.zig");
pub const atlas = @import("atlas.zig");

pub const Font = @import("font.zig").Font;
pub const Metrics = @import("font.zig").Metrics;

pub const TextRenderer = text_mod.TextRenderer;
pub const Style = text_mod.Style;
pub const Size = text_mod.Size;
pub const Line = layout.Line;
