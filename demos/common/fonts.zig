//! The fonts of the demo text. Lato (the flat2d example has its licence)
//! has the Latin letters. Noto Sans Hebrew (`assets/NotoSansHebrew-OFL.txt`)
//! has the Hebrew letters of the menu demo. Both are under the SIL Open
//! Font License.

/// Lato Regular.
pub const latin = @embedFile("demo_font");
/// Noto Sans Hebrew Regular: a static instance, cut to the Basic Latin,
/// Latin-1 and Hebrew blocks.
pub const hebrew = @embedFile("assets/NotoSansHebrew-Regular.ttf");
