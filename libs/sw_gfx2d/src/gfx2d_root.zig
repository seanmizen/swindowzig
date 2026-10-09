//! sw_gfx2d - a 2D renderer for filled rectangles, rectangle outlines and
//! textured quads. Import it as `const gfx = @import("sw_gfx2d");`.
//!
//! Coordinates are logical pixels with the origin at the top left. Logical
//! pixels are device pixels divided by `dpi_scale`.

const batch_mod = @import("batch.zig");
const renderer_mod = @import("renderer.zig");

pub const projection = @import("projection.zig");

pub const Renderer = renderer_mod.Renderer;
pub const Options = renderer_mod.Options;
pub const Filter = renderer_mod.Filter;

pub const Batch = batch_mod.Batch;
pub const Color = batch_mod.Color;
pub const Rect = batch_mod.Rect;
pub const Texture = batch_mod.Texture;
pub const Vertex = batch_mod.Vertex;
pub const DrawCall = batch_mod.DrawCall;
