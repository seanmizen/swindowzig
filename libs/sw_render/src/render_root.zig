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
//!
//! The post chain adds an `rgba16float` scene target to a frame graph, and
//! runs the HDR effects, the tonemap, the LDR effects and FXAA as graph
//! passes (REQ-GPU-008, REQ-GPU-009). See `post.zig`.
//!
//! The sky pass draws a gradient, a sun, a moon and stars from a time of
//! day, or a cube-map skybox (REQ-GPU-010). The shared WGSL prefix gives
//! `sw_fog`, which fades the scene into the horizon colour of the sky
//! (REQ-GPU-011). See `sky.zig`.
//!
//! Box models are trees of boxes that the game animates part by part. One
//! draw call draws all instances of one model (REQ-GPU-014). A first-person
//! pass draws view-space models in front of the world, with their own depth
//! range (REQ-GPU-015). See `box_models.zig`.
//!
//! `Lighting` renders a cascaded shadow map for one directional light,
//! which follows the sun by default, and holds the point lights of the
//! frame. A scene shader samples the shadow with a PCF filter and adds
//! the point lights through a WGSL include (REQ-GPU-016, REQ-GPU-017). A
//! setting turns the shadows off (REQ-GPU-018). See `lighting.zig`.
//!
//! The cloud pass draws a layer of boxes at a set height, from a shape
//! image that the game gives, and the wind moves it (REQ-GPU-020). The
//! precipitation pass draws rain or snow in a column around the camera,
//! and a height map from the game stops it at the ground (REQ-GPU-021).
//! Both use the sky light and the fog. See `weather.zig`.
//!
//! The translucent pass draws quads after the opaque pass, with the depth
//! test on and the depth write off (REQ-GPU-022). It sorts the quads from
//! far to near when the camera moves a set distance (REQ-GPU-023). See
//! `translucent.zig`.

const atlas_mod = @import("atlas.zig");
const box_models_mod = @import("box_models.zig");
const frame_graph_mod = @import("frame_graph.zig");
const lighting_mod = @import("lighting.zig");
const post_mod = @import("post.zig");
const ring_mod = @import("ring.zig");
const sky_mod = @import("sky.zig");
const translucent_mod = @import("translucent.zig");
const upload_mod = @import("upload.zig");
const weather_mod = @import("weather.zig");

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
/// The post chain with no GPU code: the route of the links, the tonemap
/// curves, and the WGSL of the effects (`post.shader`).
pub const post = @import("post_plan.zig");
/// The sky with no GPU code: the time of day, the sky colours, the fog,
/// and the CPU reference of the WGSL sky helpers.
pub const sky = @import("sky_plan.zig");
/// Box models with no GPU code: the mesh, the pose of the parts, the WGSL
/// and the CPU reference of the shader.
pub const box_model = @import("box_model_plan.zig");
/// Shadows and point lights with no GPU code: the cascade fit, the WGSL
/// include (`lighting.include`) and the CPU reference of its helpers.
pub const lighting = @import("lighting_plan.zig");
/// Clouds and precipitation with no GPU code: the settings, the sky light,
/// the WGSL and the CPU reference of the shaders.
pub const weather = @import("weather_plan.zig");
/// The translucent pass with no GPU code: the sort, the states and the
/// CPU reference of the blend.
pub const translucent = @import("translucent_plan.zig");

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
pub const PassId = frame_graph_mod.PassId;
pub const Callback = frame_graph_mod.Callback;
pub const TargetId = plan.TargetId;
pub const TargetDesc = plan.TargetDesc;
pub const TargetSize = plan.Size;
pub const Extent = plan.Extent;
pub const Attachments = plan.Attachments;
pub const ColorAttachment = plan.ColorAttachment;
pub const DepthAttachment = plan.DepthAttachment;
pub const FrameUniforms = wgsl.FrameUniforms;
pub const SkyUniforms = wgsl.SkyUniforms;
pub const UniformRing = ring_mod.UniformRing;
pub const Uploads = upload_mod.Uploads;

pub const PostChain = post_mod.PostChain;
pub const PostOptions = post_mod.Options;
pub const PostEffectDesc = post_mod.EffectDesc;
pub const PostEffectId = post_mod.EffectId;
pub const PostParams = post_mod.Params;
pub const Tonemap = post_mod.Tonemap;
pub const TonemapCurve = post_mod.Curve;

pub const Sky = sky_mod.Sky;
pub const SkyOptions = sky_mod.Options;
pub const SkySettings = sky.Settings;
pub const SkyPalette = sky.Palette;
pub const SkyState = sky.State;
pub const Fog = sky.Fog;
pub const CubeMap = sky_mod.CubeMap;

pub const BoxModels = box_models_mod.BoxModels;
pub const BoxModelOptions = box_models_mod.Options;
pub const BoxModelDesc = box_models_mod.ModelDesc;
pub const BoxModelPart = box_models_mod.Part;
pub const BoxModelBox = box_models_mod.Box;
pub const BoxModelId = box_models_mod.ModelId;
pub const BoxModelLayer = box_models_mod.Layer;
pub const BoxModelInstance = box_models_mod.Instance;
pub const BoxModelView = box_models_mod.View;
pub const BoxModelLight = box_models_mod.Light;
pub const BoxModelStats = box_models_mod.Stats;
pub const FirstPersonOptions = box_models_mod.FirstPersonOptions;

pub const Lighting = lighting_mod.Lighting;
pub const LightingOptions = lighting_mod.Options;
pub const ShadowSettings = lighting.ShadowSettings;
pub const PointLight = lighting.PointLight;
pub const ShadowCasterPass = lighting_mod.CasterPass;
pub const ShadowCaster = lighting_mod.CasterCallback;
pub const LightingUniforms = lighting.LightingUniforms;
pub const Clouds = weather_mod.Clouds;
pub const CloudOptions = weather_mod.CloudOptions;
pub const CloudSettings = weather.CloudSettings;
pub const Precipitation = weather_mod.Precipitation;
pub const PrecipitationOptions = weather_mod.PrecipitationOptions;
pub const PrecipitationSettings = weather.PrecipitationSettings;
pub const PrecipitationKind = weather.PrecipitationKind;
pub const HeightMap = weather.HeightMap;
pub const WeatherInput = weather.FrameInput;
pub const WeatherLight = weather.Light;
pub const Translucent = translucent_mod.Translucent;
pub const TranslucentOptions = translucent_mod.Options;
pub const TranslucentPassOptions = translucent_mod.PassOptions;
pub const TranslucentVertex = translucent.Vertex;
pub const TranslucentQuad = translucent.Quad;
