// atlas - a texture atlas from sw_render: still sprites and animated
// sprites in one texture with mip levels. The window shows the atlas. Each
// animated sprite changes its image with GPU copies only.
//
// Native `--check`: no window. The example builds the atlas, reads it back
// from the GPU, and checks the sprites at level 0 and at the last mip
// level. Then it moves the time forward and checks that only the changed
// sprites change. It exits with 0 (pass) or 1 (fail). See REQ-GPU-003 and
// REQ-GPU-004.
const std = @import("std");
const builtin = @import("builtin");
const sw = @import("sw_app");
const gpu_mod = @import("sw_gpu");
const render = @import("sw_render");

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
    .title = "atlas",
    .size = .{ .w = 720, .h = 720 },
    .tick_hz = 20,
};

const Rgba = [4]u8;

const red: Rgba = .{ 255, 0, 0, 255 };
const green: Rgba = .{ 0, 255, 0, 255 };
const blue: Rgba = .{ 0, 0, 255, 255 };
const white: Rgba = .{ 255, 255, 255, 255 };
const yellow: Rgba = .{ 255, 255, 0, 255 };
const magenta: Rgba = .{ 255, 0, 255, 255 };
const cyan: Rgba = .{ 0, 255, 255, 255 };
const orange: Rgba = .{ 255, 128, 0, 255 };

/// One still sprite: a size and one colour.
const Still = struct { w: u32, h: u32, colour: Rgba };
const stills = [_]Still{
    .{ .w = 16, .h = 16, .colour = red },
    .{ .w = 32, .h = 16, .colour = green },
    .{ .w = 10, .h = 10, .colour = blue },
    .{ .w = 16, .h = 32, .colour = white },
};

/// Animated sprite A: three images, and a frame list that shows image 1
/// two times in each loop.
const a_colours = [_]Rgba{ yellow, magenta, cyan };
const a_frames = [_]render.Frame{
    .{ .image = 0, .duration = 2 },
    .{ .image = 1, .duration = 3 },
    .{ .image = 2, .duration = 1 },
    .{ .image = 1, .duration = 2 },
};
/// Animated sprite B: two images, each for 4 time units.
const b_colours = [_]Rgba{ orange, blue };
const b_frames = [_]render.Frame{
    .{ .image = 0, .duration = 4 },
    .{ .image = 1, .duration = 4 },
};

var atlas: ?render.Atlas = null;
var still_ids: [stills.len]render.SpriteId = undefined;
var sprite_a: render.SpriteId = undefined;
var sprite_b: render.SpriteId = undefined;
var pipeline: ?gpu_mod.RenderPipeline = null;
var bind_group: ?gpu_mod.BindGroup = null;
var time: u64 = 0;

const shader_code =
    \\@group(0) @binding(0) var atlas: texture_2d<f32>;
    \\@group(0) @binding(1) var samp: sampler;
    \\
    \\struct VOut {
    \\    @builtin(position) pos: vec4f,
    \\    @location(0) uv: vec2f,
    \\}
    \\
    \\// A square that shows all of the atlas.
    \\@vertex fn vs_main(@builtin(vertex_index) i: u32) -> VOut {
    \\    var corners = array<vec2f, 6>(
    \\        vec2f(0, 0), vec2f(1, 0), vec2f(1, 1),
    \\        vec2f(0, 0), vec2f(1, 1), vec2f(0, 1));
    \\    let c = corners[i];
    \\    var o: VOut;
    \\    o.pos = vec4f(c.x * 1.8 - 0.9, 0.9 - c.y * 1.8, 0.0, 1.0);
    \\    o.uv = c;
    \\    return o;
    \\}
    \\
    \\@fragment fn fs_main(in: VOut) -> @location(0) vec4f {
    \\    let c = textureSample(atlas, samp, in.uv);
    \\    return vec4f(c.rgb * c.a + vec3f(0.1) * (1.0 - c.a), 1.0);
    \\}
;

fn solid(allocator: std.mem.Allocator, w: u32, h: u32, colour: Rgba) ![]u8 {
    const px = try allocator.alloc(u8, @as(usize, w) * h * 4);
    var i: usize = 0;
    while (i < px.len) : (i += 4) px[i..][0..4].* = colour;
    return px;
}

fn buildAtlas(allocator: std.mem.Allocator, gpu: *gpu_mod.GPU) !render.Atlas {
    var b = render.AtlasBuilder.init(allocator, .{ .cell = 16, .label = "atlas" });
    defer b.deinit();
    for (stills, 0..) |s, i| {
        const px = try solid(allocator, s.w, s.h, s.colour);
        defer allocator.free(px);
        still_ids[i] = try b.addImage(.{ .width = s.w, .height = s.h, .pixels = px });
    }
    sprite_a = try addAnimated(allocator, &b, &a_colours, &a_frames);
    sprite_b = try addAnimated(allocator, &b, &b_colours, &b_frames);
    var mipmaps = try gpu_mod.MipmapGenerator.init(gpu);
    return b.build(gpu, &mipmaps);
}

fn addAnimated(allocator: std.mem.Allocator, b: *render.AtlasBuilder, colours: []const Rgba, frames: []const render.Frame) !render.SpriteId {
    var images: [4]render.Image = undefined;
    var pixels: [4][]u8 = undefined;
    for (colours, 0..) |c, i| {
        pixels[i] = try solid(allocator, 16, 16, c);
        images[i] = .{ .width = 16, .height = 16, .pixels = pixels[i] };
    }
    defer for (pixels[0..colours.len]) |p| allocator.free(p);
    return b.addAnimated(images[0..colours.len], frames);
}

const Callbacks = struct {
    pub fn init(ctx: *sw.Context) !void {
        const gpu = ctx.gpu();
        if (!gpu.isReady()) return;

        atlas = try buildAtlas(ctx.allocator(), gpu);
        const a = &atlas.?;
        std.log.info("atlas: {d} sprites, {d}x{d} texels, {d} mip levels", .{ a.count(), a.size, a.size, a.mip_level_count });

        if (comptime !builtin.cpu.arch.isWasm()) {
            if (check_mode) {
                const ok = check(ctx.allocator(), gpu, a) catch |err| blk: {
                    std.log.err("atlas: check failed: {s}", .{@errorName(err)});
                    break :blk false;
                };
                std.process.exit(if (ok) 0 else 1);
            }
        }

        var view = try a.createView();
        var sampler = try gpu.createSampler(.{
            .mag_filter = .nearest,
            .min_filter = .linear,
            .mipmap_filter = .linear,
        });
        var bgl = try gpu.createBindGroupLayout(.{
            .entries = &[_]gpu_mod.BindGroupLayoutEntry{
                .{ .binding = 0, .visibility = .{ .fragment = true }, .texture = .{ .sample_type = .float, .view_dimension = .@"2d" } },
                .{ .binding = 1, .visibility = .{ .fragment = true }, .sampler = .{ .type = .filtering } },
            },
        });
        bind_group = try gpu.createBindGroup(.{
            .layout = &bgl,
            .entries = &[_]gpu_mod.BindGroupEntry{
                .{ .binding = 0, .texture_view = &view },
                .{ .binding = 1, .sampler = &sampler },
            },
        });
        var layout = try gpu.createPipelineLayout(.{
            .bind_group_layouts = &[_]*gpu_mod.BindGroupLayout{&bgl},
        });
        var shader = try gpu.createShaderModule(.{ .code = shader_code });
        pipeline = try gpu.createRenderPipeline(.{
            .layout = &layout,
            .vertex = .{ .module = &shader, .entry_point = "vs_main" },
            .fragment = .{
                .module = &shader,
                .entry_point = "fs_main",
                .targets = &[_]gpu_mod.ColorTargetState{.{ .format = .bgra8unorm }},
            },
            .primitive = .{ .topology = .triangle_list, .cull_mode = .none },
        });
    }

    pub fn tick(ctx: *sw.Context) !void {
        _ = ctx;
        time += 1;
    }

    pub fn render(ctx: *sw.Context) !void {
        const gpu = ctx.gpu();
        if (!gpu.isReady()) return;
        const p = pipeline orelse return;

        var view_tex = try gpu.getCurrentTextureView();
        const encoder = try gpu.createCommandEncoder();
        // The copies go before the pass that samples the atlas.
        _ = atlas.?.update(encoder, time);
        const pass = try encoder.beginRenderPass(.{
            .color_attachments = &[_]gpu_mod.RenderPassColorAttachment{.{
                .view = &view_tex,
                .load_op = .clear,
                .store_op = .store,
                .clear_value = .{ .r = 0.2, .g = 0.2, .b = 0.25, .a = 1.0 },
            }},
        });
        pass.setPipeline(p);
        pass.setBindGroup(0, bind_group.?);
        pass.draw(6, 1, 0, 0);
        pass.end();
        const cmd = try encoder.finish();
        gpu.submit(&[_]gpu_mod.CommandBuffer{cmd});
        view_tex.release();
        gpu.present();
    }

    pub fn shutdown(ctx: *sw.Context) !void {
        _ = ctx;
        if (atlas) |*a| a.deinit();
        atlas = null;
    }
};

// =============================================================================
// Native check: the atlas texels on the GPU
// =============================================================================

/// The colour that sprite `id` must have at time `t`.
fn expected(id: render.SpriteId, t: u64) Rgba {
    if (id == sprite_a) return a_colours[render.animation.imageAt(&a_frames, t)];
    if (id == sprite_b) return b_colours[render.animation.imageAt(&b_frames, t)];
    for (still_ids, 0..) |s, i| if (s == id) return stills[i].colour;
    unreachable;
}

/// Read each mip level, and check that each texel of each sprite cell has
/// the colour of the sprite. With one colour for each sprite, each level
/// has the same colour while no level mixes two sprites (REQ-GPU-004).
fn checkTexels(allocator: std.mem.Allocator, gpu: *gpu_mod.GPU, a: *const render.Atlas, t: u64) !bool {
    var ok = true;
    const l: render.layout.Layout = .{ .size = a.size, .cell = a.cell, .rects = a.rects };
    var level: u32 = 0;
    while (level < a.mip_level_count) : (level += 1) {
        const edge = gpu_mod.mip_chain.levelSize(a.size, level);
        const texels = try gpu.readTexture(allocator, a.texture, level, 0, edge, edge);
        defer allocator.free(texels);
        for (0..a.count()) |i| {
            const id: render.SpriteId = @fromBackingInt(@intCast(i));
            const want = expected(id, t);
            const r = l.cellRect(i).atLevel(level);
            var bad: u32 = 0;
            for (r.y..r.y + r.height) |y| for (r.x..r.x + r.width) |x| {
                const got = texels[(y * edge + x) * 4 ..][0..4].*;
                if (!std.mem.eql(u8, &got, &want)) bad += 1;
            };
            if (bad > 0) {
                ok = false;
                std.log.err("atlas: time {d} level {d} sprite {d}: {d} texels have the wrong colour", .{ t, level, i, bad });
            }
        }
    }
    return ok;
}

fn check(allocator: std.mem.Allocator, gpu: *gpu_mod.GPU, a: *render.Atlas) !bool {
    var ok = try checkTexels(allocator, gpu, a, 0);

    // The UV rectangle of a sprite covers its texels only.
    const blue_uv = a.uv(still_ids[2]);
    const blue_rect = a.rect(still_ids[2]);
    const s: f32 = @floatFromInt(a.size);
    if (blue_uv.u1 - blue_uv.u0 != 10.0 / s or blue_uv.u0 != @as(f32, @floatFromInt(blue_rect.x)) / s) {
        ok = false;
        std.log.err("atlas: the UV rectangle of the 10x10 sprite is wrong", .{});
    }

    // Move the time forward. Each step changes only the sprites that the
    // frame lists change, and the GPU copies give the new colours.
    const steps = [_]struct { t: u64, changed: u32 }{
        .{ .t = 1, .changed = 0 },
        .{ .t = 2, .changed = 1 }, // A: yellow to magenta
        .{ .t = 4, .changed = 1 }, // B: orange to blue
        .{ .t = 5, .changed = 1 }, // A: magenta to cyan
        .{ .t = 6, .changed = 1 }, // A: cyan to magenta
        .{ .t = 7, .changed = 0 },
        .{ .t = 8, .changed = 2 }, // A: magenta to yellow. B: blue to orange
        .{ .t = 8, .changed = 0 },
    };
    for (steps) |step| {
        const encoder = try gpu.createCommandEncoder();
        const changed = a.update(encoder, step.t);
        const cmd = try encoder.finish();
        gpu.submit(&[_]gpu_mod.CommandBuffer{cmd});
        if (changed != step.changed) {
            ok = false;
            std.log.err("atlas: time {d}: {d} sprites changed, want {d}", .{ step.t, changed, step.changed });
        }
        if (!try checkTexels(allocator, gpu, a, step.t)) ok = false;
    }
    std.log.info("atlas: check {s}", .{if (ok) "passed" else "FAILED"});
    return ok;
}
