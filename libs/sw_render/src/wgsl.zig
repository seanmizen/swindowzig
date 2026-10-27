//! The shared WGSL prefix: the bindings that every pass of a frame graph
//! can read (REQ-GPU-007).
//!
//! Group 0 binding 0 holds `FrameUniforms`: the camera matrices, the
//! viewport size and the time. `FrameGraph` owns the buffer and its bind
//! group, and writes it one time each frame. A shader starts with `prefix`
//! (use `shader`), and a pass calls `Pass.bindFrame` before its draws.
//! Groups 1 to 3 belong to the pass.
//!
//! `FrameUniforms.sky` holds the sky and the fog of the frame (`SkyUniforms`).
//! The prefix gives WGSL helpers that read it: `sw_view_ray`,
//! `sw_sky_gradient`, `sw_sky_lights`, `sw_sky_color`, `sw_fog_amount` and
//! `sw_fog`. A scene shader calls `sw_fog(colour, world_pos)` to fade into
//! the horizon colour of the sky (REQ-GPU-011). `sky_plan.zig` holds the CPU
//! reference of each helper.

const std = @import("std");

/// The bind group index of the frame uniforms.
pub const frame_group: u32 = 0;
/// The binding of the frame uniforms in `frame_group`.
pub const frame_binding: u32 = 0;

pub const identity: [16]f32 = .{
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    0, 0, 0, 1,
};

/// The sky and the fog of one frame, with the memory layout of `SwSky` in
/// `prefix`. Colours are linear RGB. `Sky.update` (or `sky_plan.uniforms`)
/// gives the values. The default has no sky and no fog: `sw_fog` then gives
/// the colour with no change.
pub const SkyUniforms = extern struct {
    /// xyz: the unit vector to the sun. w: the time of day, 0 to 1.
    sun_dir: [4]f32 = .{ 0, 1, 0, 0.5 },
    /// xyz: the unit vector to the moon. w: not used.
    moon_dir: [4]f32 = .{ 0, -1, 0, 0 },
    /// rgb: the colour straight up. w: not used.
    zenith: [4]f32 = .{ 0, 0, 0, 0 },
    /// rgb: the colour at the horizon. w: the gradient exponent. The
    /// gradient is `mix(horizon, zenith, pow(dir.y, exponent))`.
    horizon: [4]f32 = .{ 0, 0, 0, 0.5 },
    /// rgb: the colour below the horizon. w: how fast the horizon colour
    /// changes to this colour below the horizon (1 / dir.y).
    ground: [4]f32 = .{ 0, 0, 0, 8 },
    /// rgb: the colour of the sun disc (HDR). w: the cosine of the angular
    /// radius of the disc.
    sun_color: [4]f32 = .{ 0, 0, 0, 1 },
    /// rgb: the colour of the moon disc (HDR). w: the cosine of the angular
    /// radius of the disc.
    moon_color: [4]f32 = .{ 0, 0, 0, 1 },
    /// rgb: the colour of the glow around the sun. w: the glow exponent.
    glow: [4]f32 = .{ 0, 0, 0, 8 },
    /// rgb: the fog colour. w: the most fog, 0 to 1. 0: no fog.
    fog_color: [4]f32 = .{ 0, 0, 0, 0 },
    /// x: the distance where the fog starts. y: the distance of full fog.
    /// z and w: not used.
    fog: [4]f32 = .{ 0, 1, 0, 0 },
};

/// The frame uniforms, with the memory layout of `SwFrame` in `prefix`.
/// The matrices are column-major, as in `sw_math.Mat4.data`.
pub const FrameUniforms = extern struct {
    view: [16]f32 = identity,
    proj: [16]f32 = identity,
    view_proj: [16]f32 = identity,
    inv_view_proj: [16]f32 = identity,
    /// The camera position in world space. `w` is not used.
    camera_pos: [4]f32 = .{ 0, 0, 0, 1 },
    /// The surface width, height, 1 / width and 1 / height, in pixels.
    /// `FrameGraph.execute` sets it.
    viewport: [4]f32 = .{ 1, 1, 1, 1 },
    /// The time in seconds.
    time: f32 = 0,
    /// The time since the last frame, in seconds.
    delta: f32 = 0,
    /// The frame count. `FrameGraph.execute` sets it.
    frame: u32 = 0,
    _pad: u32 = 0,
    /// The sky and the fog. The default has no sky and no fog.
    sky: SkyUniforms = .{},
};

/// The WGSL text that declares `SwFrame`, the `sw_frame` binding and the
/// sky and fog helpers.
pub const prefix =
    \\struct SwSky {
    \\    sun_dir: vec4<f32>,
    \\    moon_dir: vec4<f32>,
    \\    zenith: vec4<f32>,
    \\    horizon: vec4<f32>,
    \\    ground: vec4<f32>,
    \\    sun_color: vec4<f32>,
    \\    moon_color: vec4<f32>,
    \\    glow: vec4<f32>,
    \\    fog_color: vec4<f32>,
    \\    fog: vec4<f32>,
    \\}
    \\struct SwFrame {
    \\    view: mat4x4<f32>,
    \\    proj: mat4x4<f32>,
    \\    view_proj: mat4x4<f32>,
    \\    inv_view_proj: mat4x4<f32>,
    \\    camera_pos: vec4<f32>,
    \\    viewport: vec4<f32>,
    \\    time: f32,
    \\    delta: f32,
    \\    frame: u32,
    \\    _pad: u32,
    \\    sky: SwSky,
    \\}
    \\@group(0) @binding(0) var<uniform> sw_frame: SwFrame;
    \\
++ sky_helpers;

/// The sky and fog helpers in `prefix`. `sky_plan.zig` has the CPU
/// reference of each function (REQ-GPU-010, REQ-GPU-011).
pub const sky_helpers =
    \\// The unit view ray in world space through the pixel at `frag_xy`
    \\// (`@builtin(position).xy`). It needs a perspective `proj` and a
    \\// rigid `view`, and a target with the surface size.
    \\fn sw_view_ray(frag_xy: vec2<f32>) -> vec3<f32> {
    \\    let ndc = vec2<f32>(frag_xy.x * sw_frame.viewport.z * 2.0 - 1.0, 1.0 - frag_xy.y * sw_frame.viewport.w * 2.0);
    \\    let p = sw_frame.proj;
    \\    let v = vec3<f32>((ndc.x + p[2][0]) / p[0][0], (ndc.y + p[2][1]) / p[1][1], -1.0);
    \\    let m = sw_frame.view;
    \\    return normalize(vec3<f32>(dot(m[0].xyz, v), dot(m[1].xyz, v), dot(m[2].xyz, v)));
    \\}
    \\
    \\// A disc of angular radius acos(cos_r) around the direction with dot `d`.
    \\fn sw_sky_disc(d: f32, cos_r: f32) -> f32 {
    \\    let w = max((1.0 - cos_r) * 0.25, 1e-6);
    \\    return smoothstep(cos_r - w, cos_r + w, d);
    \\}
    \\
    \\// The sky gradient along the unit direction `dir`: zenith, horizon, ground.
    \\fn sw_sky_gradient(dir: vec3<f32>) -> vec3<f32> {
    \\    let s = sw_frame.sky;
    \\    if (dir.y >= 0.0) {
    \\        return mix(s.horizon.rgb, s.zenith.rgb, pow(max(dir.y, 1e-12), s.horizon.w));
    \\    }
    \\    return mix(s.horizon.rgb, s.ground.rgb, min(-dir.y * s.ground.w, 1.0));
    \\}
    \\
    \\// The glow, the sun and the moon along the unit direction `dir`.
    \\fn sw_sky_lights(dir: vec3<f32>) -> vec3<f32> {
    \\    let s = sw_frame.sky;
    \\    let above = smoothstep(-0.02, 0.02, dir.y);
    \\    let ds = dot(dir, s.sun_dir.xyz);
    \\    let dm = dot(dir, s.moon_dir.xyz);
    \\    var c = s.glow.rgb * pow(max(ds, 1e-6), s.glow.w);
    \\    c += s.sun_color.rgb * (sw_sky_disc(ds, s.sun_color.w) * above);
    \\    c += s.moon_color.rgb * (sw_sky_disc(dm, s.moon_color.w) * above);
    \\    return c;
    \\}
    \\
    \\// The sky colour along the unit direction `dir`, with no stars.
    \\fn sw_sky_color(dir: vec3<f32>) -> vec3<f32> {
    \\    return sw_sky_gradient(dir) + sw_sky_lights(dir);
    \\}
    \\
    \\// The fog amount at the distance `dist` from the camera, 0 to 1.
    \\fn sw_fog_amount(dist: f32) -> f32 {
    \\    let f = sw_frame.sky.fog;
    \\    let t = clamp((dist - f.x) / max(f.y - f.x, 1e-4), 0.0, 1.0);
    \\    return t * sw_frame.sky.fog_color.w;
    \\}
    \\
    \\// `color` at the world position `world_pos`, with the distance fog.
    \\// The camera position is `sw_frame.camera_pos`.
    \\fn sw_fog(color: vec3<f32>, world_pos: vec3<f32>) -> vec3<f32> {
    \\    let amount = sw_fog_amount(distance(world_pos, sw_frame.camera_pos.xyz));
    \\    return mix(color, sw_frame.sky.fog_color.rgb, amount);
    \\}
    \\
;

/// `prefix` followed by the shader `body`.
pub fn shader(comptime body: []const u8) []const u8 {
    return prefix ++ body;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn wgslSize(ty: []const u8) usize {
    if (std.mem.eql(u8, ty, "mat4x4<f32>")) return 64;
    if (std.mem.eql(u8, ty, "vec4<f32>")) return 16;
    if (std.mem.eql(u8, ty, "f32") or std.mem.eql(u8, ty, "u32")) return 4;
    if (std.mem.eql(u8, ty, "SwSky")) return @sizeOf(SkyUniforms);
    unreachable;
}

/// Check that the WGSL struct `name` in `prefix` has the members, sizes
/// and offsets of the Zig struct `T`.
fn expectLayout(comptime T: type, name: []const u8) !void {
    const info = @typeInfo(T).@"struct";
    const names = info.field_names;
    var head_buf: [64]u8 = undefined;
    const head = try std.fmt.bufPrint(&head_buf, "struct {s} {{\n", .{name});
    const start = std.mem.indexOf(u8, prefix, head).? + head.len;
    const end = std.mem.indexOfPos(u8, prefix, start, "}").?;
    var sizes: [names.len]usize = undefined;
    var offsets: [names.len]usize = undefined;
    inline for (names, info.field_types, 0..) |n, F, j| {
        sizes[j] = @sizeOf(F);
        offsets[j] = @offsetOf(T, n);
    }
    var lines = std.mem.tokenizeScalar(u8, prefix[start..end], '\n');
    var i: usize = 0;
    var offset: usize = 0;
    while (lines.next()) |raw| : (i += 1) {
        const line = std.mem.trim(u8, raw, " ,");
        const colon = std.mem.indexOfScalar(u8, line, ':').?;
        const ty = std.mem.trim(u8, line[colon + 1 ..], " ");
        try testing.expect(i < names.len);
        try testing.expectEqualStrings(names[i], line[0..colon]);
        try testing.expectEqual(sizes[i], wgslSize(ty));
        // A struct member starts on 16 bytes. Each member of these structs
        // is 16 bytes or less, so the members follow each other with no gap.
        if (std.mem.eql(u8, ty, "SwSky")) offset = std.mem.alignForward(usize, offset, 16);
        try testing.expectEqual(offsets[i], offset);
        offset += wgslSize(ty);
    }
    try testing.expectEqual(names.len, i);
    // A WGSL uniform struct size is a multiple of 16.
    try testing.expectEqual(@sizeOf(T), offset);
    try testing.expectEqual(@as(usize, 0), @sizeOf(T) % 16);
}

test "wgsl: SwFrame in the prefix has the layout of FrameUniforms (REQ-GPU-007)" {
    try expectLayout(FrameUniforms, "SwFrame");
    try testing.expect(std.mem.indexOf(u8, prefix, "@group(0) @binding(0) var<uniform> sw_frame: SwFrame;") != null);
    try testing.expectEqual(@as(u32, 0), frame_group);
    try testing.expectEqual(@as(u32, 0), frame_binding);
}

test "wgsl: SwSky in the prefix has the layout of SkyUniforms (REQ-GPU-007)" {
    try expectLayout(SkyUniforms, "SwSky");
    // The default has no fog.
    const d: SkyUniforms = .{};
    try testing.expectEqual(@as(f32, 0), d.fog_color[3]);
}

test "wgsl: shader puts the prefix first" {
    const text = comptime shader("@fragment fn fs() {}\n");
    try testing.expect(std.mem.startsWith(u8, text, prefix));
    try testing.expect(std.mem.endsWith(u8, text, "@fragment fn fs() {}\n"));
}
