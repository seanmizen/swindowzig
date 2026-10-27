//! The FXAA 3.11 shader source and its quality presets, with no GPU code.
//!
//! `fxaa.wgsl` has placeholder tokens. `shaderSource` replaces them with
//! the values of one quality tier and with the bind group of the scene
//! texture. `GPU.configureFXAA` uses group 0. The post chain of
//! `sw_render` uses group 1, because group 0 holds the frame uniforms
//! there (REQ-GPU-009).

const std = @import("std");
const types = @import("types.zig");

pub const FxaaQuality = types.FxaaQuality;

/// The WGSL source, with the placeholder tokens.
pub const source = @embedFile("fxaa.wgsl");

/// The text of the three quality knobs of one tier.
pub const Preset = struct {
    search_steps: []const u8,
    subpix_cap: []const u8,
    edge_threshold: []const u8,
};

/// The knob values of `quality`. They are near the FXAA 3.11 reference
/// presets 12, 25 and 39.
///   - low: 4 search steps, 0.5 subpix cap, 0.166 edge threshold
///   - medium: 12 search steps, 0.75 subpix cap, 0.125 edge threshold
///   - high: 32 search steps, 0.85 subpix cap, 0.063 edge threshold
pub fn preset(quality: FxaaQuality) Preset {
    return switch (quality) {
        .low => .{ .search_steps = "4", .subpix_cap = "0.5", .edge_threshold = "0.166" },
        .medium => .{ .search_steps = "12", .subpix_cap = "0.75", .edge_threshold = "0.125" },
        .high => .{ .search_steps = "32", .subpix_cap = "0.85", .edge_threshold = "0.063" },
    };
}

/// A buffer that holds the source after `shaderSource`.
pub const max_source_len = 16 * 1024;

pub const Error = error{FxaaSourceBufferTooSmall};

/// Write the source with all placeholder tokens replaced into `dest`, and
/// give the written part. `group` is the bind group of the scene texture
/// (binding 0) and its sampler (binding 1). The time is linear in the
/// source length.
pub fn shaderSource(dest: []u8, quality: FxaaQuality, group: u32) Error![]const u8 {
    const p = preset(quality);
    var group_buf: [10]u8 = undefined;
    const group_text = std.fmt.bufPrint(&group_buf, "{d}", .{group}) catch unreachable;
    const Repl = struct { needle: []const u8, replacement: []const u8 };
    const repls = [_]Repl{
        .{ .needle = "__FXAA_SEARCH_STEPS__", .replacement = p.search_steps },
        .{ .needle = "__FXAA_SUBPIX_CAP__", .replacement = p.subpix_cap },
        .{ .needle = "__FXAA_EDGE_THRESHOLD__", .replacement = p.edge_threshold },
        .{ .needle = "__FXAA_GROUP__", .replacement = group_text },
    };

    var write: usize = 0;
    var read: usize = 0;
    outer: while (read < source.len) {
        for (repls) |r| {
            if (std.mem.startsWith(u8, source[read..], r.needle)) {
                if (write + r.replacement.len > dest.len) return error.FxaaSourceBufferTooSmall;
                @memcpy(dest[write .. write + r.replacement.len], r.replacement);
                write += r.replacement.len;
                read += r.needle.len;
                continue :outer;
            }
        }
        if (write + 1 > dest.len) return error.FxaaSourceBufferTooSmall;
        dest[write] = source[read];
        write += 1;
        read += 1;
    }
    return dest[0..write];
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "fxaa: the source has no placeholder token after the substitution (REQ-GPU-009)" {
    var buf: [max_source_len]u8 = undefined;
    for ([_]FxaaQuality{ .low, .medium, .high }) |q| {
        for ([_]u32{ 0, 1 }) |group| {
            const text = try shaderSource(&buf, q, group);
            try testing.expect(std.mem.indexOf(u8, text, "__FXAA_") == null);
            const p = preset(q);
            var want: [64]u8 = undefined;
            const steps = try std.fmt.bufPrint(&want, "const SEARCH_STEPS: i32 = {s};", .{p.search_steps});
            try testing.expect(std.mem.indexOf(u8, text, steps) != null);
        }
    }
}

test "fxaa: the group token sets the group of the scene texture and sampler (REQ-GPU-009)" {
    var buf: [max_source_len]u8 = undefined;
    const g0 = try shaderSource(&buf, .medium, 0);
    try testing.expect(std.mem.indexOf(u8, g0, "@group(0) @binding(0) var t_scene: texture_2d<f32>;") != null);
    try testing.expect(std.mem.indexOf(u8, g0, "@group(0) @binding(1) var s_scene: sampler;") != null);

    var buf1: [max_source_len]u8 = undefined;
    const g1 = try shaderSource(&buf1, .medium, 1);
    try testing.expect(std.mem.indexOf(u8, g1, "@group(1) @binding(0) var t_scene: texture_2d<f32>;") != null);
    try testing.expect(std.mem.indexOf(u8, g1, "@group(1) @binding(1) var s_scene: sampler;") != null);
    // The two sources differ only at the group numbers.
    try testing.expectEqual(g0.len, g1.len);
}

test "fxaa: a small buffer gives an error" {
    var buf: [64]u8 = undefined;
    try testing.expectError(error.FxaaSourceBufferTooSmall, shaderSource(&buf, .high, 0));
}
