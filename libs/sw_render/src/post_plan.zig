//! The plan of the post-process chain, with no GPU code: the route of the
//! image through the links, the tonemap curves, and the WGSL text.
//!
//! `post.zig` makes the targets and the pipelines. This file holds only
//! the rules, so the tests run with no GPU (REQ-GPU-008, REQ-GPU-009).

const std = @import("std");
const gpu_mod = @import("sw_gpu");
const wgsl = @import("wgsl.zig");

// =============================================================================
// The route
// =============================================================================

/// The kind of one link of the chain. The links run in this sequence:
/// all `hdr` links, then the tonemap, then all `ldr` links.
pub const Kind = enum {
    /// Reads and writes linear HDR colour, before the tonemap.
    hdr,
    /// Reads HDR colour and writes display colour. The chain has one.
    tonemap,
    /// Reads and writes display colour, after the tonemap. FXAA is one.
    ldr,
};

/// The images that the links read and write. The scene draws into
/// `hdr_a`. Two images of each kind let each link read the output of the
/// link before it.
pub const Slot = enum(u8) {
    hdr_a,
    hdr_b,
    ldr_a,
    ldr_b,
    screen,
};

pub const Link = struct {
    kind: Kind,
    enabled: bool,
};

/// What one enabled link reads and writes.
pub const Route = struct {
    input: Slot,
    output: Slot,
};

pub const RouteError = error{
    /// The links are not in the sequence hdr, tonemap, ldr.
    BadSequence,
    /// The tonemap link is missing, or more than one is present, or it is
    /// disabled.
    NoTonemap,
};

/// Give the route of each link in `links` (in run sequence) to `out`. A
/// disabled link gets null. The first enabled link reads `hdr_a`. Each
/// next link reads the output of the enabled link before it. The last
/// enabled link writes `screen` (REQ-GPU-009).
pub fn route(links: []const Link, out: []?Route) RouteError!void {
    std.debug.assert(out.len >= links.len);
    var tonemaps: usize = 0;
    var last: usize = 0;
    var prev: Kind = .hdr;
    for (links, 0..) |l, i| {
        if (@backingInt(l.kind) < @backingInt(prev)) return error.BadSequence;
        prev = l.kind;
        if (l.kind == .tonemap) {
            if (!l.enabled) return error.NoTonemap;
            tonemaps += 1;
        }
        if (l.enabled) last = i;
    }
    if (tonemaps != 1) return error.NoTonemap;

    var current: Slot = .hdr_a;
    for (links, 0..) |l, i| {
        if (!l.enabled) {
            out[i] = null;
            continue;
        }
        const output: Slot = if (i == last) .screen else switch (l.kind) {
            .hdr => if (current == .hdr_a) .hdr_b else .hdr_a,
            .tonemap => .ldr_a,
            .ldr => if (current == .ldr_a) .ldr_b else .ldr_a,
        };
        out[i] = .{ .input = current, .output = output };
        current = output;
    }
}

/// True when a route in `routes` reads or writes `slot`.
pub fn uses(routes: []const ?Route, slot: Slot) bool {
    for (routes) |r| {
        if (r) |x| if (x.input == slot or x.output == slot) return true;
    }
    return false;
}

// =============================================================================
// The tonemap
// =============================================================================

/// How the tonemap maps HDR colour to the range 0 to 1.
pub const Curve = enum(u32) {
    /// Clamp each channel to 1.
    clamp = 0,
    /// x / (1 + x) on each channel.
    reinhard = 1,
    /// The ACES filmic curve fit of Krzysztof Narkowicz.
    aces = 2,
};

/// The tonemap settings. The game can change them each frame.
pub const Tonemap = struct {
    curve: Curve = .aces,
    /// The tonemap multiplies the scene colour by this value before the curve.
    exposure: f32 = 1.0,
};

/// The tonemap uniforms, with the memory layout of `SwTonemap` in
/// `tonemap_shader`.
pub const TonemapUniforms = extern struct {
    exposure: f32 = 1.0,
    curve: u32 = @backingInt(Curve.aces),
    /// 1: encode the output with the sRGB transfer function. The chain
    /// sets it when the output format does not encode sRGB itself.
    encode_srgb: u32 = 1,
    _pad: u32 = 0,

    pub fn of(t: Tonemap, output_format: gpu_mod.TextureFormat) TonemapUniforms {
        return .{
            .exposure = t.exposure,
            .curve = @backingInt(t.curve),
            .encode_srgb = @intFromBool(!isSrgbFormat(output_format)),
        };
    }
};

/// True for a format that encodes sRGB when a shader writes it.
pub fn isSrgbFormat(format: gpu_mod.TextureFormat) bool {
    return switch (format) {
        .rgba8unorm_srgb, .bgra8unorm_srgb => true,
        else => false,
    };
}

/// The constants of the ACES fit: (x (a x + b)) / (x (c x + d) + e).
pub const aces_fit = struct {
    pub const a: f32 = 2.51;
    pub const b: f32 = 0.03;
    pub const c: f32 = 2.43;
    pub const d: f32 = 0.59;
    pub const e: f32 = 0.14;
};

/// The CPU reference of one channel of the tonemap. The WGSL in
/// `tonemap_shader` does the same steps (REQ-GPU-008).
pub fn tonemapChannel(x: f32, t: Tonemap, encode_srgb: bool) f32 {
    const v = @max(x * t.exposure, 0.0);
    const mapped = switch (t.curve) {
        .clamp => @min(v, 1.0),
        .reinhard => v / (1.0 + v),
        .aces => std.math.clamp((v * (aces_fit.a * v + aces_fit.b)) / (v * (aces_fit.c * v + aces_fit.d) + aces_fit.e), 0.0, 1.0),
    };
    return if (encode_srgb) srgbEncode(mapped) else mapped;
}

/// The sRGB transfer function, from linear 0..1 to encoded 0..1.
pub fn srgbEncode(x: f32) f32 {
    if (x <= 0.0031308) return x * 12.92;
    return 1.055 * std.math.pow(f32, x, 1.0 / 2.4) - 0.055;
}

// =============================================================================
// WGSL
// =============================================================================

/// The bind group of the input image of a link.
pub const input_group: u32 = 1;
/// The bind group of the own uniforms or textures of a link.
pub const params_group: u32 = 2;

/// The WGSL text after `wgsl.prefix` in each post shader. It declares the
/// input image of the link at group 1 (`sw_input`, `sw_input_sampler`)
/// and a vertex entry `sw_post_vs` that draws one triangle over the
/// target. `SwPostOut.uv` is 0 at the top left and 1 at the bottom right.
pub const post_prefix =
    \\@group(1) @binding(0) var sw_input: texture_2d<f32>;
    \\@group(1) @binding(1) var sw_input_sampler: sampler;
    \\
    \\struct SwPostOut {
    \\    @builtin(position) pos: vec4<f32>,
    \\    @location(0) uv: vec2<f32>,
    \\}
    \\
    \\@vertex fn sw_post_vs(@builtin(vertex_index) vi: u32) -> SwPostOut {
    \\    let x = select(-1.0, 3.0, vi == 1u);
    \\    let y = select(-1.0, 3.0, vi == 2u);
    \\    var out: SwPostOut;
    \\    out.pos = vec4<f32>(x, y, 0.0, 1.0);
    \\    out.uv = vec2<f32>((x + 1.0) * 0.5, (1.0 - y) * 0.5);
    \\    return out;
    \\}
    \\
;

/// The full source of a post shader: `wgsl.prefix`, `post_prefix`, then
/// `body`. The body declares `@fragment fn fs_main(in: SwPostOut)`.
pub fn shader(comptime body: []const u8) []const u8 {
    return wgsl.prefix ++ post_prefix ++ body;
}

/// The binding of the depth target in group 1, for an effect that reads
/// it (REQ-GPU-030).
pub const depth_binding: u32 = 2;

/// The WGSL text after `post_prefix` in the shader of an effect that reads
/// a depth target. It declares `sw_depth` and `sw_view_distance`, the
/// distance from the camera of the point at a pixel. `sw_view_distance`
/// uses `sw_frame.proj`: a perspective or an orthographic projection with
/// no rotation. `sky_plan.depthDistance` is its CPU reference.
pub const depth_prefix =
    \\@group(1) @binding(2) var sw_depth: texture_depth_2d;
    \\
    \\fn sw_view_distance(frag_xy: vec2<f32>, depth: f32) -> f32 {
    \\    let p = sw_frame.proj;
    \\    let uv = frag_xy * sw_frame.viewport.zw;
    \\    let ndc = vec2<f32>(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
    \\    let z = (p[3][2] - depth * p[3][3]) / (depth * p[2][3] - p[2][2]);
    \\    let w = p[2][3] * z + p[3][3];
    \\    let x = (ndc.x * w - p[2][0] * z - p[3][0]) / p[0][0];
    \\    let y = (ndc.y * w - p[2][1] * z - p[3][1]) / p[1][1];
    \\    return length(vec3<f32>(x, y, z));
    \\}
    \\
;

/// The full source of a post shader that reads a depth target:
/// `wgsl.prefix`, `post_prefix`, `depth_prefix`, then `body`.
pub fn depthShader(comptime body: []const u8) []const u8 {
    return wgsl.prefix ++ post_prefix ++ depth_prefix ++ body;
}

/// The fog post effect (REQ-GPU-030): `sw_fog` of the shared prefix, at
/// the distance from the depth target. A pixel with no geometry (depth 1)
/// keeps its colour. Use it in place of `sw_fog` in the scene shaders, not
/// with it: a pixel with both gets the fog two times.
pub const depth_fog_shader = depthShader(
    \\@fragment fn fs_main(in: SwPostOut) -> @location(0) vec4<f32> {
    \\    let c = textureSample(sw_input, sw_input_sampler, in.uv);
    \\    let depth = textureLoad(sw_depth, vec2<i32>(in.pos.xy), 0);
    \\    if (depth >= 1.0) {
    \\        return c;
    \\    }
    \\    let amount = sw_fog_amount(sw_view_distance(in.pos.xy, depth));
    \\    return vec4<f32>(mix(c.rgb, sw_frame.sky.fog_color.rgb, amount), c.a);
    \\}
    \\
);

/// The tonemap link.
pub const tonemap_shader = shader(std.fmt.comptimePrint(
    \\struct SwTonemap {{
    \\    exposure: f32,
    \\    curve: u32,
    \\    encode_srgb: u32,
    \\    _pad: u32,
    \\}}
    \\@group(2) @binding(0) var<uniform> sw_tonemap: SwTonemap;
    \\
    \\fn sw_aces(x: vec3<f32>) -> vec3<f32> {{
    \\    let n = x * ({d} * x + {d});
    \\    let m = x * ({d} * x + {d}) + {d};
    \\    return clamp(n / m, vec3<f32>(0.0), vec3<f32>(1.0));
    \\}}
    \\
    \\fn sw_srgb_encode(c: vec3<f32>) -> vec3<f32> {{
    \\    let lo = c * 12.92;
    \\    let hi = 1.055 * pow(c, vec3<f32>(1.0 / 2.4)) - 0.055;
    \\    return select(hi, lo, c <= vec3<f32>(0.0031308));
    \\}}
    \\
    \\@fragment fn fs_main(in: SwPostOut) -> @location(0) vec4<f32> {{
    \\    let hdr = textureSampleLevel(sw_input, sw_input_sampler, in.uv, 0.0).rgb;
    \\    var c = max(hdr * sw_tonemap.exposure, vec3<f32>(0.0));
    \\    switch sw_tonemap.curve {{
    \\        case 1u: {{ c = c / (vec3<f32>(1.0) + c); }}
    \\        case 2u: {{ c = sw_aces(c); }}
    \\        default: {{ c = min(c, vec3<f32>(1.0)); }}
    \\    }}
    \\    if (sw_tonemap.encode_srgb != 0u) {{
    \\        c = sw_srgb_encode(c);
    \\    }}
    \\    return vec4<f32>(c, 1.0);
    \\}}
    \\
, .{ aces_fit.a, aces_fit.b, aces_fit.c, aces_fit.d, aces_fit.e }));

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn expectRoutes(links: []const Link, want: []const ?Route) !void {
    var got: [16]?Route = undefined;
    try route(links, got[0..links.len]);
    try testing.expectEqualSlices(?Route, want, got[0..links.len]);
}

test "post: the tonemap alone reads the scene and writes the screen (REQ-GPU-009)" {
    try expectRoutes(&.{.{ .kind = .tonemap, .enabled = true }}, &.{.{ .input = .hdr_a, .output = .screen }});
}

test "post: the links run in sequence, and each reads the output of the one before (REQ-GPU-009)" {
    // Two HDR links, the tonemap, one game LDR link and FXAA.
    try expectRoutes(&.{
        .{ .kind = .hdr, .enabled = true },
        .{ .kind = .hdr, .enabled = true },
        .{ .kind = .tonemap, .enabled = true },
        .{ .kind = .ldr, .enabled = true },
        .{ .kind = .ldr, .enabled = true },
    }, &.{
        .{ .input = .hdr_a, .output = .hdr_b },
        .{ .input = .hdr_b, .output = .hdr_a },
        .{ .input = .hdr_a, .output = .ldr_a },
        .{ .input = .ldr_a, .output = .ldr_b },
        .{ .input = .ldr_b, .output = .screen },
    });
    // The tonemap and FXAA: FXAA is the last link and writes the screen.
    try expectRoutes(&.{
        .{ .kind = .tonemap, .enabled = true },
        .{ .kind = .ldr, .enabled = true },
    }, &.{
        .{ .input = .hdr_a, .output = .ldr_a },
        .{ .input = .ldr_a, .output = .screen },
    });
}

test "post: a disabled link is skipped, and the route closes the gap (REQ-GPU-009)" {
    try expectRoutes(&.{
        .{ .kind = .hdr, .enabled = false },
        .{ .kind = .hdr, .enabled = true },
        .{ .kind = .tonemap, .enabled = true },
        .{ .kind = .ldr, .enabled = false },
    }, &.{
        null,
        .{ .input = .hdr_a, .output = .hdr_b },
        .{ .input = .hdr_b, .output = .screen },
        null,
    });

    var routes: [4]?Route = undefined;
    try route(&.{
        .{ .kind = .tonemap, .enabled = true },
        .{ .kind = .ldr, .enabled = false },
    }, &routes);
    try testing.expect(uses(routes[0..2], .hdr_a));
    try testing.expect(!uses(routes[0..2], .hdr_b));
    try testing.expect(!uses(routes[0..2], .ldr_a));
}

test "post: route refuses a bad sequence" {
    var out: [4]?Route = undefined;
    try testing.expectError(error.NoTonemap, route(&.{.{ .kind = .hdr, .enabled = true }}, &out));
    try testing.expectError(error.NoTonemap, route(&.{.{ .kind = .tonemap, .enabled = false }}, &out));
    try testing.expectError(error.BadSequence, route(&.{
        .{ .kind = .tonemap, .enabled = true },
        .{ .kind = .hdr, .enabled = true },
    }, &out));
    try testing.expectError(error.NoTonemap, route(&.{
        .{ .kind = .tonemap, .enabled = true },
        .{ .kind = .tonemap, .enabled = true },
    }, &out));
}

test "post: the tonemap curves map HDR colour into 0 to 1 (REQ-GPU-008)" {
    const ops = [_]Curve{ .clamp, .reinhard, .aces };
    for (ops) |op| {
        const t: Tonemap = .{ .curve = op };
        try testing.expectEqual(@as(f32, 0.0), tonemapChannel(0.0, t, false));
        try testing.expectEqual(@as(f32, 0.0), tonemapChannel(-3.0, t, false));
        // The curve does not go down, and it stays in 0 to 1.
        var prev: f32 = 0.0;
        var x: f32 = 0.0;
        while (x < 64.0) : (x += 0.125) {
            const y = tonemapChannel(x, t, false);
            try testing.expect(y >= prev - 1e-6);
            try testing.expect(y >= 0.0 and y <= 1.0);
            prev = y;
        }
    }
    // A value over 1 keeps detail with the curves, and clamps with `clamp`.
    try testing.expectEqual(@as(f32, 1.0), tonemapChannel(4.0, .{ .curve = .clamp }, false));
    try testing.expect(tonemapChannel(4.0, .{ .curve = .reinhard }, false) < tonemapChannel(8.0, .{ .curve = .reinhard }, false));
    try testing.expectApproxEqAbs(@as(f32, 0.8), tonemapChannel(4.0, .{ .curve = .reinhard }, false), 1e-6);
    try testing.expect(tonemapChannel(2.0, .{}, false) < tonemapChannel(4.0, .{}, false));
    // The ACES fit at 1.0.
    try testing.expectApproxEqAbs(@as(f32, 0.8038), tonemapChannel(1.0, .{}, false), 1e-3);
    // Exposure multiplies the input.
    try testing.expectEqual(tonemapChannel(2.0, .{ .exposure = 1.0 }, false), tonemapChannel(1.0, .{ .exposure = 2.0 }, false));
}

test "post: the sRGB encode (REQ-GPU-008)" {
    try testing.expectEqual(@as(f32, 0.0), srgbEncode(0.0));
    try testing.expectApproxEqAbs(@as(f32, 1.0), srgbEncode(1.0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.7354), srgbEncode(0.5), 1e-4);
    // The two parts of the curve meet.
    try testing.expectApproxEqAbs(srgbEncode(0.0031308), 0.0031308 * 12.92, 1e-5);
    // An sRGB output format encodes, so the shader does not.
    try testing.expectEqual(@as(u32, 1), TonemapUniforms.of(.{}, .bgra8unorm).encode_srgb);
    try testing.expectEqual(@as(u32, 0), TonemapUniforms.of(.{}, .bgra8unorm_srgb).encode_srgb);
    try testing.expectEqual(@as(u32, 1), TonemapUniforms.of(.{ .curve = .reinhard }, .rgba8unorm).curve);
}

test "post: SwTonemap in the tonemap shader has the layout of TonemapUniforms (REQ-GPU-008)" {
    const start = std.mem.indexOf(u8, tonemap_shader, "struct SwTonemap {\n").? + "struct SwTonemap {\n".len;
    const end = std.mem.indexOfPos(u8, tonemap_shader, start, "}").?;
    var lines = std.mem.tokenizeScalar(u8, tonemap_shader[start..end], '\n');
    const names = @typeInfo(TonemapUniforms).@"struct".field_names;
    var offsets: [names.len]usize = undefined;
    inline for (names, 0..) |n, j| offsets[j] = @offsetOf(TonemapUniforms, n);
    var i: usize = 0;
    while (lines.next()) |raw| : (i += 1) {
        const line = std.mem.trim(u8, raw, " ,");
        const colon = std.mem.indexOfScalar(u8, line, ':').?;
        try testing.expectEqualStrings(names[i], line[0..colon]);
        try testing.expectEqual(i * 4, offsets[i]);
    }
    try testing.expectEqual(names.len, i);
    try testing.expectEqual(@as(usize, 16), @sizeOf(TonemapUniforms));
    // The curve numbers in the switch match `Curve`.
    try testing.expect(std.mem.indexOf(u8, tonemap_shader, "case 1u: { c = c / (vec3<f32>(1.0) + c); }") != null);
    try testing.expectEqual(@as(u32, 1), @backingInt(Curve.reinhard));
    try testing.expectEqual(@as(u32, 2), @backingInt(Curve.aces));
    try testing.expect(std.mem.indexOf(u8, tonemap_shader, "case 2u: { c = sw_aces(c); }") != null);
}

test "post: the fog effect has the depth prefix after the input prefix (REQ-GPU-030)" {
    const at = wgsl.prefix.len + post_prefix.len;
    try testing.expect(std.mem.startsWith(u8, depth_fog_shader, wgsl.prefix ++ post_prefix));
    try testing.expect(std.mem.indexOf(u8, depth_fog_shader, depth_prefix) == at);
    try testing.expect(std.mem.indexOf(u8, depth_fog_shader, "sw_fog_amount(sw_view_distance(") != null);
}

test "post: each post shader starts with the frame prefix, then the input at group 1" {
    try testing.expect(std.mem.startsWith(u8, tonemap_shader, wgsl.prefix));
    try testing.expect(std.mem.indexOf(u8, tonemap_shader, post_prefix) == wgsl.prefix.len);
    try testing.expect(std.mem.indexOf(u8, post_prefix, "@group(1) @binding(0) var sw_input: texture_2d<f32>;") != null);
    try testing.expect(std.mem.indexOf(u8, post_prefix, "@group(1) @binding(1) var sw_input_sampler: sampler;") != null);
    try testing.expectEqual(@as(u32, 1), input_group);
    try testing.expect(std.mem.indexOf(u8, tonemap_shader, "@group(2) @binding(0) var<uniform> sw_tonemap") != null);
}
