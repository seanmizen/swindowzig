//! A texture atlas on the GPU: many small images in one texture, with mip
//! levels, and animated sprites.
//!
//! `AtlasBuilder` collects RGBA8 images, packs them (see `layout.zig`), and
//! makes the texture. Each image gets a `SpriteId`, and `Atlas.uv` gives its
//! texture coordinates. `MipmapGenerator` of `sw_gpu` makes the mip levels,
//! with the cell of the layout as the tile size. Thus no mip level mixes
//! two sprites (REQ-GPU-004).
//!
//! An animated sprite has frame images and a list of frames (see
//! `animation.zig`). The frame images and their mip levels go into a
//! second texture one time, at build time. `Atlas.update` copies the frame
//! that shows now into the atlas with a GPU texture copy, for each sprite
//! that changed and each mip level. It uploads no texels (REQ-GPU-003).

const std = @import("std");
const gpu_mod = @import("sw_gpu");
const layout_mod = @import("layout.zig");
const animation = @import("animation.zig");

const Rect = layout_mod.Rect;
const UvRect = layout_mod.UvRect;
const Image = layout_mod.Image;
const Frame = animation.Frame;

/// The handle of one sprite in an atlas.
pub const SpriteId = enum(u32) { _ };

pub const Options = struct {
    /// The edge of one grid cell, in texels: a power of two. Each sprite
    /// gets a whole number of cells. The cell sets the mip level count: the
    /// levels down to 1 texel for each cell. Use the size of most sprites.
    cell: u32 = 16,
    /// The largest texture edge, in texels.
    max_size: u32 = 4096,
    /// The texture format. It must be RGBA8, and the GPU must render to it
    /// for the mip levels: `rgba8unorm` or `rgba8unorm_srgb`.
    format: gpu_mod.TextureFormat = .rgba8unorm,
    /// Make mip levels. If false, the atlas has level 0 only.
    mipmaps: bool = true,
    label: ?[]const u8 = null,
};

pub const Error = error{
    BadImage,
    FrameSizesDiffer,
} || layout_mod.Error || animation.Error;

const OwnedImage = struct {
    width: u32,
    height: u32,
    pixels: []u8,

    fn dupe(allocator: std.mem.Allocator, image: Image) Error!OwnedImage {
        if (image.width == 0 or image.height == 0) return error.BadImage;
        if (image.pixels.len != @as(usize, image.width) * image.height * 4) return error.BadImage;
        return .{ .width = image.width, .height = image.height, .pixels = try allocator.dupe(u8, image.pixels) };
    }

    fn view(self: OwnedImage) Image {
        return .{ .width = self.width, .height = self.height, .pixels = self.pixels };
    }
};

const PendingAnimation = struct {
    sprite: u32,
    /// The index of the first frame image of the sprite in
    /// `AtlasBuilder.frame_images`.
    first_image: u32,
    image_count: u32,
    frames: []Frame,
};

/// Collects images, then makes an `Atlas`. The builder copies each image,
/// so the caller can free its pixels after the call.
pub const AtlasBuilder = struct {
    allocator: std.mem.Allocator,
    options: Options,
    /// Level 0 of each sprite. For an animated sprite, the image of its
    /// first frame.
    sprites: std.ArrayList(OwnedImage) = .empty,
    frame_images: std.ArrayList(OwnedImage) = .empty,
    animations: std.ArrayList(PendingAnimation) = .empty,

    pub fn init(allocator: std.mem.Allocator, options: Options) AtlasBuilder {
        return .{ .allocator = allocator, .options = options };
    }

    pub fn deinit(self: *AtlasBuilder) void {
        for (self.sprites.items) |img| self.allocator.free(img.pixels);
        for (self.frame_images.items) |img| self.allocator.free(img.pixels);
        for (self.animations.items) |a| self.allocator.free(a.frames);
        self.sprites.deinit(self.allocator);
        self.frame_images.deinit(self.allocator);
        self.animations.deinit(self.allocator);
        self.* = undefined;
    }

    /// Add one still image. `image` is RGBA8 (see `layout.Image`).
    pub fn addImage(self: *AtlasBuilder, image: Image) Error!SpriteId {
        const owned = try OwnedImage.dupe(self.allocator, image);
        errdefer self.allocator.free(owned.pixels);
        try self.sprites.append(self.allocator, owned);
        return @fromBackingInt(@intCast(self.sprites.items.len - 1));
    }

    /// Add one animated sprite. All of the frame images must have the same
    /// size. Each item of `frames` names an index in `images` and a
    /// duration. The atlas shows the image of the first frame until the
    /// first `Atlas.update`.
    pub fn addAnimated(self: *AtlasBuilder, images: []const Image, frames: []const Frame) Error!SpriteId {
        try animation.validate(frames, images.len);
        for (images) |img| {
            if (img.width != images[0].width or img.height != images[0].height) return error.FrameSizesDiffer;
        }

        const first_image: u32 = @intCast(self.frame_images.items.len);
        errdefer {
            for (self.frame_images.items[first_image..]) |img| self.allocator.free(img.pixels);
            self.frame_images.shrinkRetainingCapacity(first_image);
        }
        for (images) |img| {
            const owned = try OwnedImage.dupe(self.allocator, img);
            errdefer self.allocator.free(owned.pixels);
            try self.frame_images.append(self.allocator, owned);
        }

        const frames_copy = try self.allocator.dupe(Frame, frames);
        errdefer self.allocator.free(frames_copy);
        const shown = try OwnedImage.dupe(self.allocator, images[frames[0].image]);
        errdefer self.allocator.free(shown.pixels);
        try self.sprites.append(self.allocator, shown);
        errdefer _ = self.sprites.pop();
        const sprite: u32 = @intCast(self.sprites.items.len - 1);
        try self.animations.append(self.allocator, .{ .sprite = sprite, .first_image = first_image, .image_count = @intCast(images.len), .frames = frames_copy });
        return @fromBackingInt(@intCast(sprite));
    }

    /// Pack the images, make the textures, write level 0, and record and
    /// submit the mip level passes. The builder stays valid: call `deinit`
    /// after this call.
    pub fn build(self: *AtlasBuilder, gpu: *gpu_mod.GPU, mipmaps: *gpu_mod.MipmapGenerator) !Atlas {
        const allocator = self.allocator;
        const pack_options: layout_mod.Options = .{ .cell = self.options.cell, .max_size = self.options.max_size };

        var atlas_layout = try packImages(allocator, self.sprites.items, pack_options);
        errdefer atlas_layout.deinit(allocator);
        var frames_layout: ?layout_mod.Layout = if (self.animations.items.len > 0)
            try packImages(allocator, self.frame_images.items, pack_options)
        else
            null;
        defer if (frames_layout) |*l| l.deinit(allocator);

        var levels: u32 = 1;
        if (self.options.mipmaps) {
            levels = atlas_layout.mipLevelCount();
            if (frames_layout) |l| levels = @min(levels, l.mipLevelCount());
        }

        const usage: gpu_mod.TextureUsage = .{
            .texture_binding = true,
            .copy_dst = true,
            .copy_src = true,
            .render_attachment = true,
        };
        const texture = try gpu.createTexture(.{
            .label = self.options.label,
            .size = .{ .width = atlas_layout.size, .height = atlas_layout.size },
            .mip_level_count = levels,
            .format = self.options.format,
            .usage = usage,
        });
        errdefer texture.destroy();
        try writeLevel0(allocator, gpu, texture, atlas_layout, self.sprites.items);

        var frames_texture: ?gpu_mod.Texture = null;
        errdefer if (frames_texture) |t| t.destroy();
        if (frames_layout) |l| {
            const t = try gpu.createTexture(.{
                .label = "sw_render_atlas_frames",
                .size = .{ .width = l.size, .height = l.size },
                .mip_level_count = levels,
                .format = self.options.format,
                .usage = usage,
            });
            frames_texture = t;
            try writeLevel0(allocator, gpu, t, l, self.frame_images.items);
        }

        if (levels > 1) {
            const encoder = try gpu.createCommandEncoder();
            try mipmaps.generate(gpu, encoder, texture, .{
                .format = self.options.format,
                .width = atlas_layout.size,
                .height = atlas_layout.size,
                .mip_level_count = levels,
                .tile_size = gpu_mod.TileSize.square(atlas_layout.cell),
            });
            if (frames_texture) |t| {
                try mipmaps.generate(gpu, encoder, t, .{
                    .format = self.options.format,
                    .width = frames_layout.?.size,
                    .height = frames_layout.?.size,
                    .mip_level_count = levels,
                    .tile_size = gpu_mod.TileSize.square(frames_layout.?.cell),
                });
            }
            const cmd = try encoder.finish();
            gpu.submit(&[_]gpu_mod.CommandBuffer{cmd});
        }

        // The animated sprites: the cells of each frame image in the
        // frames texture, and a player for the frame timing.
        const animated = try allocator.alloc(AnimatedSprite, self.animations.items.len);
        var made: usize = 0;
        errdefer {
            for (animated[0..made]) |a| {
                allocator.free(a.frames);
                allocator.free(a.image_cells);
            }
            allocator.free(animated);
        }
        for (self.animations.items, 0..) |pending, i| {
            const cells = try allocator.alloc(Rect, pending.image_count);
            errdefer allocator.free(cells);
            for (cells, 0..) |*c, k| c.* = frames_layout.?.cellRect(pending.first_image + k);
            const frames = try allocator.dupe(Frame, pending.frames);
            animated[i] = .{
                .sprite = pending.sprite,
                .frames = frames,
                .image_cells = cells,
                .player = animation.Player.init(frames),
            };
            made += 1;
        }

        return .{
            .allocator = allocator,
            .texture = texture,
            .frames_texture = frames_texture,
            .format = self.options.format,
            .size = atlas_layout.size,
            .cell = atlas_layout.cell,
            .mip_level_count = levels,
            .rects = atlas_layout.rects,
            .animated = animated,
        };
    }
};

fn packImages(allocator: std.mem.Allocator, images: []const OwnedImage, options: layout_mod.Options) !layout_mod.Layout {
    const sizes = try allocator.alloc(layout_mod.Size, images.len);
    defer allocator.free(sizes);
    for (images, sizes) |img, *s| s.* = .{ .width = img.width, .height = img.height };
    return layout_mod.pack(allocator, sizes, options);
}

fn writeLevel0(
    allocator: std.mem.Allocator,
    gpu: *gpu_mod.GPU,
    texture: gpu_mod.Texture,
    l: layout_mod.Layout,
    images: []const OwnedImage,
) !void {
    const views = try allocator.alloc(Image, images.len);
    defer allocator.free(views);
    for (images, views) |img, *v| v.* = img.view();
    const pixels = try allocator.alloc(u8, @as(usize, l.size) * l.size * 4);
    defer allocator.free(pixels);
    layout_mod.compose(l, views, pixels);
    gpu.writeTexture(texture, pixels, l.size * 4, l.size, .{ .width = l.size, .height = l.size });
}

const AnimatedSprite = struct {
    sprite: u32,
    frames: []Frame,
    /// The cells of each frame image of this sprite in the frames texture.
    image_cells: []Rect,
    player: animation.Player,
};

/// A texture with packed sprites. Make it with `AtlasBuilder.build`.
pub const Atlas = struct {
    allocator: std.mem.Allocator,
    texture: gpu_mod.Texture,
    /// The frame images of the animated sprites, or null if there are none.
    frames_texture: ?gpu_mod.Texture,
    format: gpu_mod.TextureFormat,
    /// The edge of the square texture, in texels.
    size: u32,
    cell: u32,
    mip_level_count: u32,
    rects: []Rect,
    animated: []AnimatedSprite,

    /// Destroy the textures and free the memory.
    pub fn deinit(self: *Atlas) void {
        self.texture.destroy();
        if (self.frames_texture) |t| t.destroy();
        for (self.animated) |a| {
            self.allocator.free(a.frames);
            self.allocator.free(a.image_cells);
        }
        self.allocator.free(self.animated);
        self.allocator.free(self.rects);
        self.* = undefined;
    }

    /// The number of sprites.
    pub fn count(self: Atlas) usize {
        return self.rects.len;
    }

    /// The texture coordinates of a sprite. (0, 0) is the top left corner
    /// of the texture.
    pub fn uv(self: Atlas, id: SpriteId) UvRect {
        return self.layoutView().uv(@backingInt(id));
    }

    /// The texels of a sprite in the texture, at mip level 0.
    pub fn rect(self: Atlas, id: SpriteId) Rect {
        return self.rects[@backingInt(id)];
    }

    /// A view of all of the mip levels, for a bind group.
    pub fn createView(self: Atlas) !gpu_mod.TextureView {
        return self.texture.createView(.{ .dimension = .@"2d" });
    }

    fn layoutView(self: Atlas) layout_mod.Layout {
        return .{ .size = self.size, .cell = self.cell, .rects = self.rects };
    }

    /// Go to `time` (in the unit of the frame durations). For each animated
    /// sprite that must show a different frame image, record GPU copies of
    /// that image, one for each mip level, from the frames texture into the
    /// atlas (REQ-GPU-003). Submit `encoder` before the draw that uses the
    /// atlas. Returns the number of sprites that changed.
    pub fn update(self: *Atlas, encoder: gpu_mod.CommandEncoder, time: u64) u32 {
        const frames_texture = self.frames_texture orelse return 0;
        const l = self.layoutView();
        var changed: u32 = 0;
        for (self.animated) |*a| {
            const image = a.player.advance(time) orelse continue;
            const src = a.image_cells[image];
            const dst = l.cellRect(a.sprite);
            var level: u32 = 0;
            while (level < self.mip_level_count) : (level += 1) {
                const s = src.atLevel(level);
                const d = dst.atLevel(level);
                encoder.copyTextureToTexture(
                    .{ .texture = frames_texture, .mip_level = level, .origin = .{ .x = s.x, .y = s.y } },
                    .{ .texture = self.texture, .mip_level = level, .origin = .{ .x = d.x, .y = d.y } },
                    .{ .width = d.width, .height = d.height },
                );
            }
            changed += 1;
        }
        return changed;
    }

    /// The frame image index that an animated sprite shows now, or null
    /// for a still sprite.
    pub fn shownImage(self: Atlas, id: SpriteId) ?u32 {
        for (self.animated) |a| {
            if (a.sprite == @backingInt(id)) return a.player.shown;
        }
        return null;
    }
};
