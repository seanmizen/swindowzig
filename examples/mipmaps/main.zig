// mipmaps - a ground plane that goes far into the distance, with a texture
// atlas from a 2D texture array. sw_gpu makes the mip levels on the GPU, with
// the tile limit of the atlas, so no level mixes two tiles. Space changes
// the sampler:
//
//   0: no mip levels. The far plane shimmers.
//   1: trilinear mip filtering. The far plane is smooth but soft.
//   2: trilinear and 16x anisotropic filtering (the default).
//
// Native `--check`: no window. The example makes the mip levels on the GPU,
// reads each level back, compares it with the CPU reference in
// sw_gpu.mip_chain, and exits with 0 (pass) or 1 (fail). See REQ-GPU-001
// and REQ-GPU-002. The check also draws layer 1 through a view with the
// explicit dimension `2d-array`, and through a view with the explicit
// dimension `2d`. It compares each result with level 0 (REQ-GPU-034).
const std = @import("std");
const builtin = @import("builtin");
const sw = @import("sw_app");
const sw_math = @import("sw_math");
const gpu_mod = @import("sw_gpu");
const mip_chain = gpu_mod.mip_chain;

pub const std_options: std.Options = .{
    .logFn = if (builtin.cpu.arch.isWasm()) sw.webLogFn else std.log.defaultLog,
};

pub const main = if (builtin.cpu.arch.isWasm()) mainWasm else mainNative;

// The browser does not call main. backends/wasm/loader.ts calls the exports
// that exportWeb makes.
fn mainWasm() void {}

comptime {
    if (builtin.cpu.arch.isWasm()) sw.exportWeb(config, Callbacks);
}

var check_mode = false;

fn mainNative(init: std.process.Init) !void {
    var c = config;
    c.io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--check")) {
            check_mode = true;
            c.headless = true;
            c.headless_gpu = true;
            c.tick_timing = .unlimited;
        }
    }
    try sw.run(c, Callbacks);
}

const config: sw.Config = .{
    .title = "mipmaps",
    .size = .{ .w = 960, .h = 540 },
    .tick_hz = 60,
};

// The atlas: 2 array layers. Each layer is 4x4 tiles of 64x64 texels.
const tile_px = 64;
const tiles_per_edge = 4;
const atlas_px = tile_px * tiles_per_edge;
const layer_count = 2;
const atlas_format: gpu_mod.TextureFormat = .rgba8unorm_srgb;
const tile_size = gpu_mod.TileSize.square(tile_px);

const Mode = enum(u8) { no_mips, trilinear, anisotropic };

var atlas: ?gpu_mod.Texture = null;
var atlas_view: ?gpu_mod.TextureView = null;
var vertex_buffer: ?gpu_mod.Buffer = null;
var uniform_buffer: ?gpu_mod.Buffer = null;
var pipeline: ?gpu_mod.RenderPipeline = null;
var bind_groups: [3]?gpu_mod.BindGroup = .{ null, null, null };
var mode: Mode = .anisotropic;
var scroll: f32 = 0;

const shader_code =
    \\struct Uniforms { mvp: mat4x4f, scroll: vec4f }
    \\@group(0) @binding(0) var<uniform> u: Uniforms;
    \\@group(0) @binding(1) var atlas: texture_2d_array<f32>;
    \\@group(0) @binding(2) var samp: sampler;
    \\
    \\struct VOut {
    \\    @builtin(position) pos: vec4f,
    \\    @location(0) world: vec2f,
    \\}
    \\
    \\@vertex fn vs_main(@location(0) p: vec2f) -> VOut {
    \\    var o: VOut;
    \\    o.pos = u.mvp * vec4f(p.x, 0.0, p.y, 1.0);
    \\    o.world = p + u.scroll.xy;
    \\    return o;
    \\}
    \\
    \\@fragment fn fs_main(in: VOut) -> @location(0) vec4f {
    \\    // One atlas tile for each world unit. A 4x4 block of tiles uses one
    \\    // array layer, and the next block uses the other layer.
    \\    let cell = floor(in.world);
    \\    let local = clamp(in.world - cell, vec2f(0.004), vec2f(0.996));
    \\    let tile = fract(cell / 4.0) * 4.0;
    \\    let block = floor(cell / 4.0);
    \\    let layer = i32(round(fract((block.x + block.y) * 0.5) * 2.0));
    \\    let uv = (tile + local) / 4.0;
    \\    // The gradients of the continuous coordinate: the mip level does not
    \\    // jump at the tile edges.
    \\    let g = in.world / 4.0;
    \\    let c = textureSampleGrad(atlas, samp, uv, layer, dpdx(g), dpdy(g));
    \\    // The atlas is sRGB, so c is linear. The target is not sRGB.
    \\    return vec4f(pow(c.rgb, vec3f(1.0 / 2.2)), 1.0);
    \\}
;

// The plane: two triangles on y = 0, from the camera far into the distance.
const plane = [_][2]f32{
    .{ -80, 4 }, .{ 80, 4 },    .{ 80, -400 },
    .{ -80, 4 }, .{ 80, -400 }, .{ -80, -400 },
};

/// The two colours of the checker in each tile. Each tile and layer has its
/// own pair, so a mix of two tiles shows in the check.
fn tileColours(layer: u32, tile: u32) [2][3]u8 {
    const h = (layer * 16 + tile) *% 2654435761;
    const a: [3]u8 = .{ @truncate(h >> 8), @truncate(h >> 16), @truncate(h >> 24) };
    const b: [3]u8 = .{ 255 - a[0] / 2, 255 - a[1] / 3, 255 - a[2] / 4 };
    return .{ a, b };
}

/// Level 0 of one layer: each tile is a checker of 4x4 texel cells. That
/// detail is smaller than a pixel far away, and it shimmers with no mips.
fn makeLayer(layer: u32, out: []u8) void {
    for (0..atlas_px) |y| for (0..atlas_px) |x| {
        const tile: u32 = @intCast((y / tile_px) * tiles_per_edge + x / tile_px);
        const colours = tileColours(layer, tile);
        const odd = ((x / 4) + (y / 4)) % 2 == 1;
        const c = if (odd) colours[1] else colours[0];
        const i = (y * atlas_px + x) * 4;
        out[i..][0..4].* = .{ c[0], c[1], c[2], 255 };
    };
}

fn createSampler(gpu: *gpu_mod.GPU, m: Mode) !gpu_mod.Sampler {
    return switch (m) {
        .no_mips => gpu.createSampler(.{
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_filter = .nearest,
            .lod_max_clamp = 0,
        }),
        .trilinear => gpu.createSampler(.{
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_filter = .linear,
        }),
        .anisotropic => gpu.createSampler(.{
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_filter = .linear,
            .max_anisotropy = 16,
        }),
    };
}

const Callbacks = struct {
    pub fn init(ctx: *sw.Context) !void {
        const gpu = ctx.gpu();
        if (!gpu.isReady()) return;

        // The texture array, with the levels that the tile size allows.
        const levels = try mip_chain.levelCount(atlas_px, atlas_px, tile_size);
        const tex = try gpu.createTexture(.{
            .label = "atlas",
            .size = .{ .width = atlas_px, .height = atlas_px, .depth_or_array_layers = layer_count },
            .mip_level_count = levels,
            .format = atlas_format,
            .usage = .{ .texture_binding = true, .render_attachment = true, .copy_dst = true, .copy_src = true },
        });
        atlas = tex;

        // Write level 0 of each layer.
        const pixels = try ctx.allocator().alloc(u8, atlas_px * atlas_px * 4);
        defer ctx.allocator().free(pixels);
        for (0..layer_count) |layer| {
            makeLayer(@intCast(layer), pixels);
            gpu.writeTextureRegion(tex, pixels, .{
                .origin = .{ .z = @intCast(layer) },
                .size = .{ .width = atlas_px, .height = atlas_px, .depth_or_array_layers = 1 },
                .bytes_per_row = atlas_px * 4,
                .rows_per_image = atlas_px,
            });
        }

        // Make the other levels on the GPU.
        var mipmaps = try gpu_mod.MipmapGenerator.init(gpu);
        try mipmaps.generateAndSubmit(gpu, tex, .{
            .format = atlas_format,
            .width = atlas_px,
            .height = atlas_px,
            .array_layer_count = layer_count,
            .mip_level_count = levels,
            .tile_size = tile_size,
        });
        std.log.info("mipmaps: {d} layers, {d} mip levels, tile {d} px", .{ layer_count, levels, tile_px });

        if (comptime !builtin.cpu.arch.isWasm()) {
            if (check_mode) {
                const mips_ok = check(ctx.allocator(), gpu, tex, levels) catch |err| blk: {
                    std.log.err("mipmaps: check failed: {s}", .{@errorName(err)});
                    break :blk false;
                };
                const views_ok = checkViews(ctx.allocator(), gpu, tex) catch |err| blk: {
                    std.log.err("mipmaps: view check failed: {s}", .{@errorName(err)});
                    break :blk false;
                };
                std.process.exit(if (mips_ok and views_ok) 0 else 1);
            }
        }

        atlas_view = try tex.createView(.{ .dimension = .@"2d-array" });

        vertex_buffer = try gpu.createBuffer(.{
            .size = @sizeOf(@TypeOf(plane)),
            .usage = .{ .vertex = true, .copy_dst = true },
        });
        gpu.writeBuffer(vertex_buffer.?, 0, std.mem.sliceAsBytes(&plane));
        uniform_buffer = try gpu.createBuffer(.{
            .size = 256,
            .usage = .{ .uniform = true, .copy_dst = true },
        });

        var bgl = try gpu.createBindGroupLayout(.{
            .entries = &[_]gpu_mod.BindGroupLayoutEntry{
                .{ .binding = 0, .visibility = .{ .vertex = true }, .buffer = .{ .type = .uniform } },
                .{
                    .binding = 1,
                    .visibility = .{ .fragment = true },
                    .texture = .{ .sample_type = .float, .view_dimension = .@"2d-array" },
                },
                .{ .binding = 2, .visibility = .{ .fragment = true }, .sampler = .{ .type = .filtering } },
            },
        });
        for (&bind_groups, 0..) |*bg, i| {
            var sampler = try createSampler(gpu, @fromBackingInt(@intCast(i)));
            bg.* = try gpu.createBindGroup(.{
                .layout = &bgl,
                .entries = &[_]gpu_mod.BindGroupEntry{
                    .{ .binding = 0, .buffer = &uniform_buffer.?, .size = 256 },
                    .{ .binding = 1, .texture_view = &atlas_view.? },
                    .{ .binding = 2, .sampler = &sampler },
                },
            });
        }

        var layout = try gpu.createPipelineLayout(.{
            .bind_group_layouts = &[_]*gpu_mod.BindGroupLayout{&bgl},
        });
        var shader = try gpu.createShaderModule(.{ .code = shader_code });
        pipeline = try gpu.createRenderPipeline(.{
            .layout = &layout,
            .vertex = .{
                .module = &shader,
                .entry_point = "vs_main",
                .buffers = &[_]gpu_mod.VertexBufferLayout{.{
                    .array_stride = 8,
                    .attributes = &[_]gpu_mod.VertexAttribute{
                        .{ .format = .float32x2, .offset = 0, .shader_location = 0 },
                    },
                }},
            },
            .fragment = .{
                .module = &shader,
                .entry_point = "fs_main",
                .targets = &[_]gpu_mod.ColorTargetState{.{ .format = .bgra8unorm }},
            },
            .primitive = .{ .topology = .triangle_list, .cull_mode = .none },
        });
        std.log.info("mipmaps: press Space to change the sampler (mode {s})", .{@tagName(mode)});
    }

    pub fn tick(ctx: *sw.Context) !void {
        scroll -= 0.02;
        if (scroll < -400) scroll = 0;
        if (ctx.input().keyPressed(.Space)) {
            mode = @fromBackingInt(@intCast((@backingInt(mode) + 1) % 3));
            std.log.info("mipmaps: mode {s}", .{@tagName(mode)});
        }
    }

    pub fn render(ctx: *sw.Context) !void {
        const gpu = ctx.gpu();
        if (!gpu.isReady()) return;
        const p = pipeline orelse return;

        const w: f32 = @floatFromInt(@max(1, gpu.getSurfaceWidth()));
        const h: f32 = @floatFromInt(@max(1, gpu.getSurfaceHeight()));
        const proj = sw_math.perspective(std.math.pi / 3.0, w / h, 0.1, 500.0);
        const view = sw_math.lookAt(
            .{ .x = 0, .y = 1.2, .z = 0 },
            .{ .x = 0, .y = 0.9, .z = -10 },
            .{ .x = 0, .y = 1, .z = 0 },
        );
        const mvp = proj.mul(view);
        var uniforms: [20]f32 = undefined;
        @memcpy(uniforms[0..16], &mvp.data);
        uniforms[16..20].* = .{ 0, scroll, 0, 0 };
        gpu.writeBuffer(uniform_buffer.?, 0, std.mem.sliceAsBytes(&uniforms));

        var view_tex = try gpu.getCurrentTextureView();
        const encoder = try gpu.createCommandEncoder();
        const pass = try encoder.beginRenderPass(.{
            .color_attachments = &[_]gpu_mod.RenderPassColorAttachment{.{
                .view = &view_tex,
                .load_op = .clear,
                .store_op = .store,
                .clear_value = .{ .r = 0.45, .g = 0.62, .b = 0.85, .a = 1.0 },
            }},
        });
        pass.setPipeline(p);
        pass.setBindGroup(0, bind_groups[@backingInt(mode)].?);
        pass.setVertexBuffer(0, vertex_buffer.?, 0, @sizeOf(@TypeOf(plane)));
        pass.draw(plane.len, 1, 0, 0);
        pass.end();
        const cmd = try encoder.finish();
        gpu.submit(&[_]gpu_mod.CommandBuffer{cmd});
        view_tex.release();
        gpu.present();
    }

    pub fn shutdown(ctx: *sw.Context) !void {
        _ = ctx;
    }
};

// =============================================================================
// Native check: the GPU mip levels against the CPU reference
// =============================================================================

fn srgbToLinear(v: u8) f32 {
    const x = @as(f32, @floatFromInt(v)) / 255.0;
    return if (x <= 0.04045) x / 12.92 else std.math.pow(f32, (x + 0.055) / 1.055, 2.4);
}

fn linearToSrgb(v: f32) u8 {
    const x = std.math.clamp(v, 0, 1);
    const s = if (x <= 0.0031308) x * 12.92 else 1.055 * std.math.pow(f32, x, 1.0 / 2.4) - 0.055;
    return @intFromFloat(@round(s * 255.0));
}

/// The largest difference that the check accepts, in sRGB steps. The GPU
/// rounds sRGB in its own way.
const tolerance = 2;

fn check(allocator: std.mem.Allocator, gpu: *gpu_mod.GPU, tex: gpu_mod.Texture, levels: u32) !bool {
    var ok = true;
    const bytes = try allocator.alloc(u8, atlas_px * atlas_px * 4);
    defer allocator.free(bytes);
    const reference = try allocator.alloc(mip_chain.Texel, atlas_px * atlas_px);
    defer allocator.free(reference);
    const next = try allocator.alloc(mip_chain.Texel, atlas_px * atlas_px);
    defer allocator.free(next);

    for (0..layer_count) |layer_usize| {
        const layer: u32 = @intCast(layer_usize);
        makeLayer(layer, bytes);
        for (reference, 0..) |*t, i| {
            const b = bytes[i * 4 ..][0..4];
            t.* = .{ srgbToLinear(b[0]), srgbToLinear(b[1]), srgbToLinear(b[2]), @as(f32, @floatFromInt(b[3])) / 255.0 };
        }

        var level: u32 = 1;
        while (level < levels) : (level += 1) {
            const sw_ = mip_chain.levelSize(atlas_px, level - 1);
            const dw = mip_chain.levelSize(atlas_px, level);
            mip_chain.downsample(reference[0 .. sw_ * sw_], sw_, sw_, next[0 .. dw * dw]);
            @memcpy(reference[0 .. dw * dw], next[0 .. dw * dw]);

            const gpu_bytes = try gpu.readTexture(allocator, tex, level, layer, dw, dw);
            defer allocator.free(gpu_bytes);
            var worst: u32 = 0;
            for (reference[0 .. dw * dw], 0..) |t, i| {
                for (0..3) |c| {
                    const want: i32 = linearToSrgb(t[c]);
                    const got: i32 = gpu_bytes[i * 4 + c];
                    worst = @max(worst, @abs(want - got));
                }
            }
            const pass = worst <= tolerance;
            if (!pass) ok = false;
            std.log.info("mipmaps: layer {d} level {d} ({d}x{d}): largest difference {d} ({s})", .{
                layer, level, dw, dw, worst, if (pass) "pass" else "FAIL",
            });
        }

        // The last level has one texel for each tile. Each texel must be the
        // mean of its own tile only (REQ-GPU-002).
        const last = mip_chain.levelSize(atlas_px, levels - 1);
        const gpu_bytes = try gpu.readTexture(allocator, tex, levels - 1, layer, last, last);
        defer allocator.free(gpu_bytes);
        for (0..tiles_per_edge * tiles_per_edge) |tile_usize| {
            const tile: u32 = @intCast(tile_usize);
            const colours = tileColours(layer, tile);
            for (0..3) |c| {
                const mean = (srgbToLinear(colours[0][c]) + srgbToLinear(colours[1][c])) * 0.5;
                const want: i32 = linearToSrgb(mean);
                const got: i32 = gpu_bytes[tile * 4 + c];
                if (@abs(want - got) > tolerance) {
                    ok = false;
                    std.log.err("mipmaps: layer {d} tile {d} channel {d}: want {d}, got {d}", .{ layer, tile, c, want, got });
                }
            }
        }
    }
    std.log.info("mipmaps: check {s}", .{if (ok) "passed" else "FAILED"});
    return ok;
}

// =============================================================================
// Native check: views with an explicit dimension (REQ-GPU-034)
// =============================================================================

/// The array layer that the view check reads.
const view_check_layer = 1;

/// A shader that copies level 0 of one atlas layer to the target, one texel
/// for each pixel. `tex_type` is the WGSL texture type. `layer_arg` is the
/// layer argument of `textureLoad`, or empty for a `texture_2d`.
fn viewCheckShader(comptime tex_type: []const u8, comptime layer_arg: []const u8) []const u8 {
    return "@group(0) @binding(0) var atlas: " ++ tex_type ++ ";\n" ++
        \\@vertex fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
        \\    let p = vec2f(f32((i << 1u) & 2u), f32(i & 2u));
        \\    return vec4f(p * 2.0 - 1.0, 0.0, 1.0);
        \\}
        \\@fragment fn fs_main(@builtin(position) pos: vec4f) -> @location(0) vec4f {
        \\    let c = vec2i(pos.xy);
        \\
    ++ "    return textureLoad(atlas, c" ++ layer_arg ++ ", 0);\n}\n";
}

/// Draw level 0 of layer `view_check_layer` through one view, read the
/// target back, and compare it with the texels that `makeLayer` wrote. If
/// the view has the wrong dimension, the view does not match the bind group
/// layout, and the GPU rejects the bind group.
fn checkOneView(
    allocator: std.mem.Allocator,
    gpu: *gpu_mod.GPU,
    view: *gpu_mod.TextureView,
    view_dimension: gpu_mod.TextureViewDimension,
    code: []const u8,
    name: []const u8,
) !bool {
    const target = try gpu.createTexture(.{
        .label = "view check target",
        .size = .{ .width = atlas_px, .height = atlas_px, .depth_or_array_layers = 1 },
        .format = atlas_format,
        .usage = .{ .render_attachment = true, .copy_src = true },
    });
    defer target.destroy();
    var target_view = try target.createView(.{ .dimension = .@"2d" });
    defer target_view.release();

    var bgl = try gpu.createBindGroupLayout(.{
        .entries = &[_]gpu_mod.BindGroupLayoutEntry{.{
            .binding = 0,
            .visibility = .{ .fragment = true },
            .texture = .{ .sample_type = .float, .view_dimension = view_dimension },
        }},
    });
    const bind_group = try gpu.createBindGroup(.{
        .layout = &bgl,
        .entries = &[_]gpu_mod.BindGroupEntry{.{ .binding = 0, .texture_view = view }},
    });
    defer bind_group.release();
    var layout = try gpu.createPipelineLayout(.{
        .bind_group_layouts = &[_]*gpu_mod.BindGroupLayout{&bgl},
    });
    var shader = try gpu.createShaderModule(.{ .code = code });
    const p = try gpu.createRenderPipeline(.{
        .layout = &layout,
        .vertex = .{ .module = &shader, .entry_point = "vs_main" },
        .fragment = .{
            .module = &shader,
            .entry_point = "fs_main",
            .targets = &[_]gpu_mod.ColorTargetState{.{ .format = atlas_format }},
        },
        .primitive = .{ .topology = .triangle_list, .cull_mode = .none },
    });

    const encoder = try gpu.createCommandEncoder();
    const pass = try encoder.beginRenderPass(.{
        .color_attachments = &[_]gpu_mod.RenderPassColorAttachment{.{
            .view = &target_view,
            .load_op = .clear,
            .store_op = .store,
        }},
    });
    pass.setPipeline(p);
    pass.setBindGroup(0, bind_group);
    pass.draw(3, 1, 0, 0);
    pass.end();
    const cmd = try encoder.finish();
    gpu.submit(&[_]gpu_mod.CommandBuffer{cmd});

    const got = try gpu.readTexture(allocator, target, 0, 0, atlas_px, atlas_px);
    defer allocator.free(got);
    const want = try allocator.alloc(u8, atlas_px * atlas_px * 4);
    defer allocator.free(want);
    makeLayer(view_check_layer, want);

    var worst: u32 = 0;
    for (want, got) |w, g| worst = @max(worst, @abs(@as(i32, w) - @as(i32, g)));
    const ok = worst <= tolerance;
    std.log.info("mipmaps: {s} view of layer {d}: largest difference {d} ({s})", .{
        name, view_check_layer, worst, if (ok) "pass" else "FAIL",
    });
    return ok;
}

/// Make one view with the explicit dimension `2d-array` and one view with
/// the explicit dimension `2d`. Draw with each view (REQ-GPU-034).
fn checkViews(allocator: std.mem.Allocator, gpu: *gpu_mod.GPU, tex: gpu_mod.Texture) !bool {
    var array_view = try tex.createView(.{ .dimension = .@"2d-array" });
    defer array_view.release();
    const array_ok = try checkOneView(
        allocator,
        gpu,
        &array_view,
        .@"2d-array",
        comptime viewCheckShader("texture_2d_array<f32>", std.fmt.comptimePrint(", {d}", .{view_check_layer})),
        "2d-array",
    );

    var layer_view = try tex.createView(.{
        .dimension = .@"2d",
        .base_array_layer = view_check_layer,
        .array_layer_count = 1,
    });
    defer layer_view.release();
    const layer_ok = try checkOneView(
        allocator,
        gpu,
        &layer_view,
        .@"2d",
        comptime viewCheckShader("texture_2d<f32>", ""),
        "2d",
    );
    return array_ok and layer_ok;
}
