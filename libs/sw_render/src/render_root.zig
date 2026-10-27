//! sw_render - rendering helpers on top of sw_gpu. Import it as
//! `const render = @import("sw_render");`.
//!
//! The texture atlas packs many RGBA8 images into one texture with mip
//! levels, and gives the texture coordinates of each image. An animated
//! sprite changes its image with GPU copies only.
//!
//! ```zig
//! var b = render.AtlasBuilder.init(allocator, .{ .cell = 16 });
//! defer b.deinit();
//! const icon = try b.addImage(.{ .width = 16, .height = 16, .pixels = icon_rgba });
//! const spinner = try b.addAnimated(&spinner_images, &.{
//!     .{ .image = 0, .duration = 2 },
//!     .{ .image = 1, .duration = 2 },
//! });
//! var mipmaps = try gpu_mod.MipmapGenerator.init(gpu);
//! var atlas = try b.build(gpu, &mipmaps);
//! const uv = atlas.uv(icon);
//! // Each tick, before the draw:
//! _ = atlas.update(encoder, tick);
//! ```

const atlas_mod = @import("atlas.zig");

/// Atlas packing with no GPU code: the cell grid, rectangles and texture
/// coordinates.
pub const layout = @import("layout.zig");
/// Frame timing of animated sprites, with no GPU code.
pub const animation = @import("animation.zig");

pub const Atlas = atlas_mod.Atlas;
pub const AtlasBuilder = atlas_mod.AtlasBuilder;
pub const AtlasOptions = atlas_mod.Options;
pub const SpriteId = atlas_mod.SpriteId;

pub const Image = layout.Image;
pub const Rect = layout.Rect;
pub const UvRect = layout.UvRect;
pub const Frame = animation.Frame;
