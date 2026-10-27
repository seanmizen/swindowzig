// justabox - A single colored box that slowly spins.
// Dead simple. MEGA KISS. No camera movement, no input, no complexity.
//
// It draws with the sw_render frame graph. The box pass draws into the HDR
// target of the post chain, with linear colour. The chain then runs the
// tonemap and FXAA, and FXAA writes the screen (REQ-GPU-008,
// REQ-GPU-009). The frame uniforms of the WGSL prefix give the view and
// projection, and the uniform ring gives the model matrix (REQ-GPU-005,
// REQ-GPU-006, REQ-GPU-007).
//
// Native `--check`: no window. The example draws frames through the chain,
// reads the screen back, and exits with 0 (pass) or 1 (fail). The
// background must have the tonemapped clear colour of the CPU reference,
// and FXAA must change the box edges and nothing else.
const std = @import("std");
const sw = @import("sw_app");
const builtin = @import("builtin");
const sw_math = @import("sw_math");
const gpu_mod = @import("sw_gpu");
const sw_render = @import("sw_render");

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
    .title = "justabox",
    .size = .{ .w = 800, .h = 600 },
    .tick_hz = 60,
};

const Vertex = struct {
    position: [3]f32,
    color: [3]f32,
};

// 6 faces, 4 vertices each = 24 vertices total
// Each face gets a distinct color. CCW winding for back-face culling.
// Face order: +X (red), -X (cyan), +Y (green), -Y (magenta), +Z (blue), -Z (yellow)
const cube_vertices = [24]Vertex{
    // +X face (red): right side
    .{ .position = .{ 0.5, -0.5, -0.5 }, .color = .{ 1.0, 0.2, 0.2 } },
    .{ .position = .{ 0.5, 0.5, -0.5 }, .color = .{ 1.0, 0.2, 0.2 } },
    .{ .position = .{ 0.5, 0.5, 0.5 }, .color = .{ 1.0, 0.2, 0.2 } },
    .{ .position = .{ 0.5, -0.5, 0.5 }, .color = .{ 1.0, 0.2, 0.2 } },

    // -X face (cyan): left side
    .{ .position = .{ -0.5, -0.5, 0.5 }, .color = .{ 0.2, 1.0, 1.0 } },
    .{ .position = .{ -0.5, 0.5, 0.5 }, .color = .{ 0.2, 1.0, 1.0 } },
    .{ .position = .{ -0.5, 0.5, -0.5 }, .color = .{ 0.2, 1.0, 1.0 } },
    .{ .position = .{ -0.5, -0.5, -0.5 }, .color = .{ 0.2, 1.0, 1.0 } },

    // +Y face (green): top
    .{ .position = .{ -0.5, 0.5, -0.5 }, .color = .{ 0.2, 1.0, 0.2 } },
    .{ .position = .{ -0.5, 0.5, 0.5 }, .color = .{ 0.2, 1.0, 0.2 } },
    .{ .position = .{ 0.5, 0.5, 0.5 }, .color = .{ 0.2, 1.0, 0.2 } },
    .{ .position = .{ 0.5, 0.5, -0.5 }, .color = .{ 0.2, 1.0, 0.2 } },

    // -Y face (magenta): bottom
    .{ .position = .{ 0.5, -0.5, -0.5 }, .color = .{ 1.0, 0.2, 1.0 } },
    .{ .position = .{ 0.5, -0.5, 0.5 }, .color = .{ 1.0, 0.2, 1.0 } },
    .{ .position = .{ -0.5, -0.5, 0.5 }, .color = .{ 1.0, 0.2, 1.0 } },
    .{ .position = .{ -0.5, -0.5, -0.5 }, .color = .{ 1.0, 0.2, 1.0 } },

    // +Z face (blue): front
    .{ .position = .{ -0.5, -0.5, 0.5 }, .color = .{ 0.2, 0.2, 1.0 } },
    .{ .position = .{ 0.5, -0.5, 0.5 }, .color = .{ 0.2, 0.2, 1.0 } },
    .{ .position = .{ 0.5, 0.5, 0.5 }, .color = .{ 0.2, 0.2, 1.0 } },
    .{ .position = .{ -0.5, 0.5, 0.5 }, .color = .{ 0.2, 0.2, 1.0 } },

    // -Z face (yellow): back
    .{ .position = .{ 0.5, -0.5, -0.5 }, .color = .{ 1.0, 1.0, 0.2 } },
    .{ .position = .{ -0.5, -0.5, -0.5 }, .color = .{ 1.0, 1.0, 0.2 } },
    .{ .position = .{ -0.5, 0.5, -0.5 }, .color = .{ 1.0, 1.0, 0.2 } },
    .{ .position = .{ 0.5, 0.5, -0.5 }, .color = .{ 1.0, 1.0, 0.2 } },
};

// Base indices for one face (quad = 2 triangles, CCW)
const face_indices_base = [6]u16{ 0, 1, 2, 0, 2, 3 };

// 6 faces x 6 indices = 36 total indices
const num_faces = 6;
var sorted_indices: [36]u16 = undefined;

// Face order for back-to-front sorting
var face_order: [num_faces]usize = .{ 0, 1, 2, 3, 4, 5 };

var graph: ?sw_render.FrameGraph = null;
var post: ?sw_render.PostChain = null;
var pipeline: ?sw.gpu_types.RenderPipeline = null;
var vertex_buffer: ?gpu_mod.Buffer = null;
var index_buffer: ?gpu_mod.Buffer = null;
var draw_bind_group: ?gpu_mod.BindGroup = null;
var angle: f32 = 0.0;

// Frame timing
const target_fps: u64 = 60;
const frame_time_ns: u64 = std.time.ns_per_s / target_fps;
var last_frame_time: u64 = 0;

/// The per-draw uniforms, from the uniform ring.
const Draw = extern struct { model: [16]f32 };

const shader_code = sw_render.wgsl.shader(std.fmt.comptimePrint("const hdr_boost: f32 = {d:.1};\n", .{hdr_boost}) ++
    \\struct Draw { model: mat4x4<f32> }
    \\@group(1) @binding(0) var<uniform> draw: Draw;
    \\
    \\struct VSOut {
    \\    @builtin(position) pos: vec4f,
    \\    @location(0) color: vec3f,
    \\}
    \\
    \\@vertex fn vs_main(
    \\    @location(0) pos: vec3f,
    \\    @location(1) color: vec3f,
    \\) -> VSOut {
    \\    var out: VSOut;
    \\    out.pos = sw_frame.view_proj * (draw.model * vec4f(pos, 1.0));
    \\    out.color = color;
    \\    return out;
    \\}
    \\
    \\@fragment fn fs_main(in: VSOut) -> @location(0) vec4f {
    \\    // The HDR target holds linear colour. The face colours are
    \\    // display colours, so decode them, and make them brighter than 1.
    \\    return vec4f(pow(in.color, vec3f(2.2)) * hdr_boost, 1.0);
    \\}
);

/// The face colours are multiplied by this value in the HDR target. The
/// tonemap maps the values over 1 back into the display range.
const hdr_boost = 2.0;

/// The clear colour of the HDR target, in linear colour.
const clear_linear: [3]f32 = .{ 0.006, 0.006, 0.012 };

const Callbacks = struct {
    pub fn init(ctx: *sw.Context) !void {
        const gpu = ctx.gpu();
        if (!gpu.isReady()) return;

        // Vertex buffer
        vertex_buffer = try gpu.createBuffer(.{
            .size = @sizeOf(Vertex) * 24,
            .usage = .{ .vertex = true, .copy_dst = true },
        });
        gpu.writeBuffer(vertex_buffer.?, 0, std.mem.sliceAsBytes(&cube_vertices));

        // Index buffer (updated each frame for depth sorting)
        buildIndices();
        index_buffer = try gpu.createBuffer(.{
            .size = @sizeOf(u16) * 36,
            .usage = .{ .index = true, .copy_dst = true },
        });
        gpu.writeBuffer(index_buffer.?, 0, std.mem.sliceAsBytes(&sorted_indices));

        // The frame graph: one pass that clears the HDR target and draws
        // the box. The post chain then runs the tonemap and FXAA.
        graph = try sw_render.FrameGraph.init(ctx.allocator(), gpu, .{ .ring_capacity = 4096 });
        const g = &graph.?;
        post = try sw_render.PostChain.init(ctx.allocator(), g, .{ .fxaa = .medium });
        const p = &post.?;
        try g.addPass(.{
            .name = "box",
            .attachments = .{ .colors = &.{.{
                .target = p.hdr,
                .clear_value = .{ .r = clear_linear[0], .g = clear_linear[1], .b = clear_linear[2], .a = 1.0 },
            }} },
            .callback = .plain(drawBox),
        });

        // Group 1: the model matrix, at a dynamic offset in the uniform ring.
        var draw_layout = try gpu.createBindGroupLayout(.{
            .entries = &[_]sw.gpu_types.BindGroupLayoutEntry{
                sw_render.UniformRing.layoutEntry(0, .{ .vertex = true }, @sizeOf(Draw)),
            },
        });
        draw_bind_group = try gpu.createBindGroup(.{
            .layout = &draw_layout,
            .entries = &[_]gpu_mod.BindGroupEntry{g.ring.bindGroupEntry(0, @sizeOf(Draw))},
        });

        // Pipeline layout: group 0 is the frame uniforms of the WGSL prefix.
        var pipeline_layout = try gpu.createPipelineLayout(.{
            .bind_group_layouts = &[_]*gpu_mod.BindGroupLayout{ &g.frame_layout, &draw_layout },
        });

        // Shader
        var shader = try gpu.createShaderModule(.{ .code = shader_code });

        // Render pipeline
        pipeline = try gpu.createRenderPipeline(.{
            .layout = &pipeline_layout,
            .vertex = .{
                .module = &shader,
                .entry_point = "vs_main",
                .buffers = &[_]sw.gpu_types.VertexBufferLayout{.{
                    .array_stride = @sizeOf(Vertex),
                    .attributes = &[_]sw.gpu_types.VertexAttribute{
                        .{ .format = .float32x3, .offset = 0, .shader_location = 0 },
                        .{ .format = .float32x3, .offset = 12, .shader_location = 1 },
                    },
                }},
            },
            .fragment = .{
                .module = &shader,
                .entry_point = "fs_main",
                .targets = &[_]sw.gpu_types.ColorTargetState{.{
                    .format = p.hdr_format,
                }},
            },
            .primitive = .{
                .topology = .triangle_list,
                .front_face = .ccw,
                .cull_mode = .back,
            },
            .multisample = .{
                .count = 1,
                .mask = 0xFFFFFFFF,
                .alpha_to_coverage_enabled = false,
            },
        });

        std.log.info("justabox: GPU ready", .{});
    }

    pub fn tick(ctx: *sw.Context) !void {
        _ = ctx;
        // The check draws a box that does not move.
        if (check_mode) return;
        angle += 0.01; // ~0.6 deg/frame at 60hz = one full rotation per ~10 seconds
    }

    pub fn render(ctx: *sw.Context) !void {
        const gpu = ctx.gpu();
        if (!gpu.isReady()) return;
        if (pipeline == null) return;

        // Frame limiting
        const now = ctx.timeNs();
        if (last_frame_time > 0 and !check_mode) {
            const elapsed = now - last_frame_time;
            if (elapsed < frame_time_ns) {
                if (ctx.io) |io| io.sleep(.fromNanoseconds(frame_time_ns - elapsed), .awake) catch {};
            }
        }
        last_frame_time = ctx.timeNs();

        // Build the view and projection matrices
        const proj = sw_math.perspective(
            std.math.pi / 3.0, // 60 degree fov
            800.0 / 600.0,
            0.1,
            100.0,
        );
        const view = sw_math.lookAt(
            .{ .x = 2.0, .y = 2.0, .z = 4.0 },
            .{ .x = 0.0, .y = 0.0, .z = 0.0 },
            .{ .x = 0.0, .y = 1.0, .z = 0.0 },
        );
        const g = &graph.?;

        // Sort faces back-to-front (painter's algorithm, no hardware depth
        // testing). The index write goes through the staged uploads.
        sortFaces();
        buildIndices();
        try g.uploads.write(index_buffer.?, 0, std.mem.sliceAsBytes(&sorted_indices));

        // Render: the graph runs the box pass and the post chain, and
        // submits.
        if (try g.execute(.{ .view = view.data, .proj = proj.data, .view_proj = proj.mul(view).data })) {
            if (comptime !builtin.cpu.arch.isWasm()) {
                if (check_mode) try checkFrame(ctx);
            }
            gpu.present();
        }
    }

    pub fn shutdown(ctx: *sw.Context) !void {
        _ = ctx;
        if (post) |*p| p.deinit();
        post = null;
        if (graph) |*g| g.deinit();
        graph = null;
    }
};

// =============================================================================
// Native check: the frame after the post chain
// =============================================================================

var check_frame: u32 = 0;
var with_fxaa: ?[]u8 = null;

/// Frame 3 reads the screen with FXAA on, then turns FXAA off. Frame 4
/// reads the screen with FXAA off, compares the two, and exits.
fn checkFrame(ctx: *sw.Context) !void {
    check_frame += 1;
    if (check_frame < 3) return;
    const allocator = ctx.allocator();
    const gpu = ctx.gpu();
    const pixels = try gpu.captureFrame(allocator);
    if (check_frame == 3) {
        with_fxaa = pixels;
        try post.?.setFxaa(null);
        return;
    }
    defer allocator.free(pixels);
    const ok = comparePixels(with_fxaa.?, pixels, gpu.getSurfaceWidth(), gpu.getSurfaceHeight());
    allocator.free(with_fxaa.?);
    std.process.exit(if (ok) 0 else 1);
}

fn comparePixels(fxaa: []const u8, plain: []const u8, width: u32, height: u32) bool {
    var ok = true;
    // The background: the clear colour after the tonemap (ACES, exposure
    // 1, sRGB encode), from the CPU reference. The capture is BGRA.
    const tonemap: sw_render.Tonemap = .{};
    var want: [3]u8 = undefined;
    for (0..3) |c| {
        const v = sw_render.post.tonemapChannel(clear_linear[c], tonemap, true);
        want[c] = @intFromFloat(@round(v * 255.0));
    }
    const corner = plain[0..4];
    const got: [3]u8 = .{ corner[2], corner[1], corner[0] };
    for (0..3) |c| {
        const d = @abs(@as(i32, got[c]) - @as(i32, want[c]));
        if (d > 2) {
            std.log.err("justabox: background is {any}, the tonemapped clear colour is {any}", .{ got, want });
            ok = false;
            break;
        }
    }
    if (!std.mem.eql(u8, fxaa[0..4], corner)) {
        std.log.err("justabox: FXAA changed the flat background", .{});
        ok = false;
    }

    // The box: the centre pixel is not the background.
    const centre = ((height / 2) * width + width / 2) * 4;
    if (std.mem.eql(u8, plain[centre..][0..4], corner)) {
        std.log.err("justabox: the box is not at the centre of the screen", .{});
        ok = false;
    }

    // FXAA changes some pixels (the box edges), and few of them.
    var changed: usize = 0;
    var i: usize = 0;
    while (i < plain.len) : (i += 4) {
        if (!std.mem.eql(u8, plain[i..][0..3], fxaa[i..][0..3])) changed += 1;
    }
    const total = @as(usize, width) * height;
    std.log.info("justabox: FXAA changed {d} of {d} pixels", .{ changed, total });
    if (changed == 0 or changed * 20 > total) {
        std.log.err("justabox: FXAA must change the box edges only", .{});
        ok = false;
    }
    std.log.info("justabox: check {s}", .{if (ok) "passed" else "FAILED"});
    return ok;
}

/// The box pass: the frame graph began the render pass on the screen.
fn drawBox(pass: *sw_render.Pass) !void {
    const draw_offset = try pass.push(Draw{ .model = sw_math.Mat4.rotationY(angle).data });
    const rp = pass.render.?;
    rp.setPipeline(pipeline.?);
    pass.bindFrame();
    rp.setBindGroupWithOffsets(1, draw_bind_group.?, &.{draw_offset});
    rp.setVertexBuffer(0, vertex_buffer.?, 0, @sizeOf(Vertex) * 24);
    rp.setIndexBuffer(index_buffer.?, .uint16, 0, @sizeOf(u16) * 36);
    rp.drawIndexed(36, 1, 0, 0, 0);
}

// Compute centroid of each face (average of 4 vertices after rotation)
// and sort face_order back-to-front relative to camera at (2, 2, 4).
fn sortFaces() void {
    const cam = sw_math.Vec3{ .x = 2.0, .y = 2.0, .z = 4.0 };
    const rot = sw_math.Mat4.rotationY(angle);

    var distances: [num_faces]f32 = undefined;
    for (0..num_faces) |f| {
        var cx: f32 = 0;
        var cy: f32 = 0;
        var cz: f32 = 0;
        for (0..4) |v| {
            const p = cube_vertices[f * 4 + v].position;
            // Rotate vertex
            const rx = rot.get(0, 0) * p[0] + rot.get(0, 1) * p[1] + rot.get(0, 2) * p[2];
            const ry = rot.get(1, 0) * p[0] + rot.get(1, 1) * p[1] + rot.get(1, 2) * p[2];
            const rz = rot.get(2, 0) * p[0] + rot.get(2, 1) * p[1] + rot.get(2, 2) * p[2];
            cx += rx;
            cy += ry;
            cz += rz;
        }
        cx /= 4.0;
        cy /= 4.0;
        cz /= 4.0;
        const dx = cx - cam.x;
        const dy = cy - cam.y;
        const dz = cz - cam.z;
        distances[f] = dx * dx + dy * dy + dz * dz;
    }

    // Insertion sort (only 6 elements, descending = back-to-front)
    for (1..num_faces) |i| {
        const key = face_order[i];
        const key_dist = distances[key];
        var j: usize = i;
        while (j > 0 and distances[face_order[j - 1]] < key_dist) {
            face_order[j] = face_order[j - 1];
            j -= 1;
        }
        face_order[j] = key;
    }
}

fn buildIndices() void {
    for (face_order, 0..) |face, i| {
        const base: u16 = @intCast(face * 4);
        const out = i * 6;
        for (face_indices_base, 0..) |idx, k| {
            sorted_indices[out + k] = base + idx;
        }
    }
}
