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
//!
//! The frame graph runs the passes of a frame in a set order, with named
//! render targets that follow the window size (REQ-GPU-005). A uniform
//! ring and staged uploads give the per-frame data with no new buffer
//! each frame (REQ-GPU-006). The shared WGSL prefix gives each pass the
//! frame uniforms at group 0 (REQ-GPU-007). See `frame_graph.zig`.

const atlas_mod = @import("atlas.zig");
const frame_graph_mod = @import("frame_graph.zig");
const ring_mod = @import("ring.zig");
const upload_mod = @import("upload.zig");

/// Atlas packing with no GPU code: the cell grid, rectangles and texture
/// coordinates.
pub const layout = @import("layout.zig");
/// Frame timing of animated sprites, with no GPU code.
pub const animation = @import("animation.zig");
/// The rules of the frame graph, with no GPU code: target sizes, the pass
/// order, and the attachment checks.
pub const plan = @import("plan.zig");
/// The shared WGSL prefix and the frame uniforms.
pub const wgsl = @import("wgsl.zig");

pub const Atlas = atlas_mod.Atlas;
pub const AtlasBuilder = atlas_mod.AtlasBuilder;
pub const AtlasOptions = atlas_mod.Options;
pub const SpriteId = atlas_mod.SpriteId;

pub const Image = layout.Image;
pub const Rect = layout.Rect;
pub const UvRect = layout.UvRect;
pub const Frame = animation.Frame;

pub const FrameGraph = frame_graph_mod.FrameGraph;
pub const FrameGraphOptions = frame_graph_mod.Options;
pub const Pass = frame_graph_mod.Pass;
pub const PassDesc = frame_graph_mod.PassDesc;
pub const Callback = frame_graph_mod.Callback;
pub const TargetId = plan.TargetId;
pub const TargetDesc = plan.TargetDesc;
pub const TargetSize = plan.Size;
pub const Extent = plan.Extent;
pub const Attachments = plan.Attachments;
pub const ColorAttachment = plan.ColorAttachment;
pub const DepthAttachment = plan.DepthAttachment;
pub const FrameUniforms = wgsl.FrameUniforms;
pub const UniformRing = ring_mod.UniformRing;
pub const Uploads = upload_mod.Uploads;
