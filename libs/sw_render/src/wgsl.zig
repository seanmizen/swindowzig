//! The shared WGSL prefix: the bindings that every pass of a frame graph
//! can read (REQ-GPU-007).
//!
//! Group 0 binding 0 holds `FrameUniforms`: the camera matrices, the
//! viewport size and the time. `FrameGraph` owns the buffer and its bind
//! group, and writes it one time each frame. A shader starts with `prefix`
//! (use `shader`), and a pass calls `Pass.bindFrame` before its draws.
//! Groups 1 to 3 belong to the pass.

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
};

/// The WGSL text that declares `SwFrame` and the `sw_frame` binding.
pub const prefix =
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
    \\}
    \\@group(0) @binding(0) var<uniform> sw_frame: SwFrame;
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
    unreachable;
}

fn fieldSize(comptime types: []const type, i: usize) usize {
    inline for (types, 0..) |T, j| {
        if (i == j) return @sizeOf(T);
    }
    unreachable;
}

fn fieldOffset(comptime names: []const [:0]const u8, i: usize) usize {
    inline for (names, 0..) |n, j| {
        if (i == j) return @offsetOf(FrameUniforms, n);
    }
    unreachable;
}

test "wgsl: SwFrame in the prefix has the layout of FrameUniforms (REQ-GPU-007)" {
    const info = @typeInfo(FrameUniforms).@"struct";
    const names = info.field_names;
    const start = std.mem.indexOf(u8, prefix, "struct SwFrame {\n").? + "struct SwFrame {\n".len;
    const end = std.mem.indexOfPos(u8, prefix, start, "}").?;
    var lines = std.mem.tokenizeScalar(u8, prefix[start..end], '\n');
    var i: usize = 0;
    var offset: usize = 0;
    while (lines.next()) |raw| : (i += 1) {
        const line = std.mem.trim(u8, raw, " ,");
        const colon = std.mem.indexOfScalar(u8, line, ':').?;
        const name = line[0..colon];
        const ty = std.mem.trim(u8, line[colon + 1 ..], " ");
        try testing.expect(i < names.len);
        try testing.expectEqualStrings(names[i], name);
        try testing.expectEqual(fieldSize(info.field_types, i), wgslSize(ty));
        // Each WGSL member starts at the Zig offset. The members follow
        // each other with no gap.
        try testing.expectEqual(fieldOffset(names, i), offset);
        offset += wgslSize(ty);
    }
    try testing.expectEqual(names.len, i);
    // A WGSL uniform struct size is a multiple of 16.
    try testing.expectEqual(@sizeOf(FrameUniforms), offset);
    try testing.expectEqual(@as(usize, 0), @sizeOf(FrameUniforms) % 16);
    try testing.expect(std.mem.indexOf(u8, prefix, "@group(0) @binding(0) var<uniform> sw_frame: SwFrame;") != null);
    try testing.expectEqual(@as(u32, 0), frame_group);
    try testing.expectEqual(@as(u32, 0), frame_binding);
}

test "wgsl: shader puts the prefix first" {
    const text = comptime shader("@fragment fn fs() {}\n");
    try testing.expect(std.mem.startsWith(u8, text, prefix));
    try testing.expect(std.mem.endsWith(u8, text, "@fragment fn fs() {}\n"));
}
