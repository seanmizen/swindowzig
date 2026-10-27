//! Mip level generation on the GPU (REQ-GPU-001).
//!
//! `MipmapGenerator` makes mip levels 1 to N-1 of a 2D texture or a 2D
//! texture array from level 0. It uses one render pass for each level and
//! array layer, so it works on native and on the web with the same calls.
//! Each texel is the mean of a 2x2 block of the level above (see
//! `mip_chain.zig`). An sRGB format loads and stores in linear light, so the
//! mean is in linear light.
//!
//! The texture needs `texture_binding` and `render_attachment` usage, and a
//! format that the GPU can render to (for example `rgba8unorm` or
//! `rgba8unorm_srgb`).

const std = @import("std");
const builtin = @import("builtin");
const gpu_mod = @import("gpu.zig");
const types = @import("types.zig");
const mip_chain = @import("mip_chain.zig");

const is_wasm = builtin.cpu.arch.isWasm();
const web = if (is_wasm) @import("web_bridge.zig") else struct {};

const GPU = gpu_mod.GPU;
const Texture = gpu_mod.Texture;
const TextureView = gpu_mod.TextureView;
const CommandEncoder = gpu_mod.CommandEncoder;

/// What `MipmapGenerator.generate` needs to know about a texture. A
/// `Texture` handle does not keep its size or format.
pub const MipmapTarget = struct {
    format: types.TextureFormat,
    /// The size of mip level 0.
    width: u32,
    height: u32,
    /// The number of array layers. 1 is a plain 2D texture.
    array_layer_count: u32 = 1,
    /// The `mip_level_count` that the texture has. Use
    /// `mip_chain.levelCount` to get it.
    mip_level_count: u32,
    /// For a texture atlas: the size of one tile at level 0. No level mixes
    /// the texels of two tiles (REQ-GPU-002). `mip_level_count` must not be
    /// more than `mip_chain.levelCount` with this tile size.
    tile_size: ?mip_chain.TileSize = null,
};

pub const GenerateError = error{
    TooManyMipLevels,
    TooManyFormats,
} || mip_chain.Error;

const shader_source =
    \\@group(0) @binding(0) var src: texture_2d<f32>;
    \\
    \\// One triangle that covers the target.
    \\@vertex fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
    \\    let p = vec2f(f32((i << 1u) & 2u), f32(i & 2u));
    \\    return vec4f(p * 2.0 - 1.0, 0.0, 1.0);
    \\}
    \\
    \\// The mean of the 2x2 source block. mip_chain.zig has the same maths.
    \\@fragment fn fs_main(@builtin(position) pos: vec4f) -> @location(0) vec4f {
    \\    let dst = vec2u(pos.xy);
    \\    let last = textureDimensions(src) - vec2u(1u, 1u);
    \\    let a = textureLoad(src, min(dst * 2u, last), 0);
    \\    let b = textureLoad(src, min(dst * 2u + vec2u(1u, 0u), last), 0);
    \\    let c = textureLoad(src, min(dst * 2u + vec2u(0u, 1u), last), 0);
    \\    let d = textureLoad(src, min(dst * 2u + vec2u(1u, 1u), last), 0);
    \\    return (a + b + c + d) * 0.25;
    \\}
;

/// Makes mip levels on the GPU. Make one at load time and keep it: it keeps
/// one render pipeline for each texture format that it sees.
pub const MipmapGenerator = struct {
    shader: gpu_mod.ShaderModule,
    bind_group_layout: gpu_mod.BindGroupLayout,
    pipeline_layout: gpu_mod.PipelineLayout,
    pipelines: [max_formats]?FormatPipeline = @splat(null),

    const max_formats = 8;
    const FormatPipeline = struct {
        format: types.TextureFormat,
        pipeline: gpu_mod.RenderPipeline,
    };

    pub fn init(gpu: *GPU) !MipmapGenerator {
        const shader = try gpu.createShaderModule(.{ .label = "sw_gpu_mipmap", .code = shader_source });
        // unfilterable_float: textureLoad needs no filter, and this lets
        // the generator also read float formats that cannot filter.
        var bgl = try gpu.createBindGroupLayout(.{
            .label = "sw_gpu_mipmap_bgl",
            .entries = &[_]types.BindGroupLayoutEntry{.{
                .binding = 0,
                .visibility = .{ .fragment = true },
                .texture = .{ .sample_type = .unfilterable_float, .view_dimension = .@"2d" },
            }},
        });
        const layout = try gpu.createPipelineLayout(.{
            .label = "sw_gpu_mipmap_layout",
            .bind_group_layouts = &[_]*gpu_mod.BindGroupLayout{&bgl},
        });
        return .{ .shader = shader, .bind_group_layout = bgl, .pipeline_layout = layout };
    }

    fn pipelineFor(self: *MipmapGenerator, gpu: *GPU, format: types.TextureFormat) !gpu_mod.RenderPipeline {
        for (&self.pipelines) |*slot| {
            if (slot.*) |p| {
                if (p.format == format) return p.pipeline;
                continue;
            }
            const pipeline = try gpu.createRenderPipeline(.{
                .label = "sw_gpu_mipmap_pipeline",
                .layout = &self.pipeline_layout,
                .vertex = .{ .module = &self.shader, .entry_point = "vs_main" },
                .fragment = .{
                    .module = &self.shader,
                    .entry_point = "fs_main",
                    .targets = &[_]types.ColorTargetState{.{ .format = format }},
                },
                .primitive = .{ .topology = .triangle_list, .cull_mode = .none },
            });
            slot.* = .{ .format = format, .pipeline = pipeline };
            return pipeline;
        }
        return error.TooManyFormats;
    }

    /// Record the passes that make mip levels 1 to `mip_level_count - 1` of
    /// each array layer into `encoder`. Level 0 must hold the image before
    /// the GPU runs the commands. A `writeTexture` before the submit is
    /// sufficient: the queue does the write first.
    pub fn generate(
        self: *MipmapGenerator,
        gpu: *GPU,
        encoder: CommandEncoder,
        texture: Texture,
        target: MipmapTarget,
    ) !void {
        const allowed = try mip_chain.levelCount(target.width, target.height, target.tile_size);
        if (target.mip_level_count > allowed) return error.TooManyMipLevels;
        if (target.mip_level_count <= 1) return;

        const pipeline = try self.pipelineFor(gpu, target.format);

        var layer: u32 = 0;
        while (layer < target.array_layer_count) : (layer += 1) {
            var level: u32 = 1;
            while (level < target.mip_level_count) : (level += 1) {
                var src_view = try texture.createView(.{
                    .dimension = .@"2d",
                    .base_mip_level = level - 1,
                    .mip_level_count = 1,
                    .base_array_layer = layer,
                    .array_layer_count = 1,
                });
                defer releaseView(src_view);
                var dst_view = try texture.createView(.{
                    .dimension = .@"2d",
                    .base_mip_level = level,
                    .mip_level_count = 1,
                    .base_array_layer = layer,
                    .array_layer_count = 1,
                });
                defer releaseView(dst_view);

                const bind_group = try gpu.createBindGroup(.{
                    .layout = &self.bind_group_layout,
                    .entries = &[_]gpu_mod.BindGroupEntry{.{ .binding = 0, .texture_view = &src_view }},
                });
                defer bind_group.release();

                const pass = try encoder.beginRenderPass(.{
                    .label = "sw_gpu_mipmap_pass",
                    .color_attachments = &[_]gpu_mod.RenderPassColorAttachment{.{
                        .view = &dst_view,
                        .load_op = .clear,
                        .store_op = .store,
                    }},
                });
                pass.setPipeline(pipeline);
                pass.setBindGroup(0, bind_group);
                pass.draw(3, 1, 0, 0);
                pass.end();
            }
        }
    }

    /// `generate` with its own command encoder, then submit.
    pub fn generateAndSubmit(self: *MipmapGenerator, gpu: *GPU, texture: Texture, target: MipmapTarget) !void {
        const encoder = try gpu.createCommandEncoder();
        try self.generate(gpu, encoder, texture, target);
        const cmd = try encoder.finish();
        gpu.submit(&[_]gpu_mod.CommandBuffer{cmd});
    }
};

/// The recorded commands keep the view alive on native. On the web, drop
/// the JS handle: a view has no destroy.
fn releaseView(view: TextureView) void {
    if (comptime is_wasm) {
        web.webgpuTextureViewRelease(view.handle);
    } else {
        view.release();
    }
}
