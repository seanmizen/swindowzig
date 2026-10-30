//! Graphics settings and quality presets (REQ-GPU-026).
//!
//! `GraphicsSettings` holds the values that a settings menu changes: the
//! render distance, the anti-aliasing, the mip levels, the shadows, the
//! lighting mode, vsync and the frame limit. A `Preset` sets all of them. The game reads the
//! values and gives them to the parts that use them:
//!
//! ```zig
//! var s = render.GraphicsSettings.preset(.high);
//! try gpu.configureMSAA(s.antiAliasingConfig(), w, h);
//! gpu.setVsync(s.vsync);
//! lighting.setShadowsEnabled(s.shadows);
//! limiter.setTarget(s.frame_limit);
//! ```
//!
//! The render distance has the unit of the game, for example chunks.
const std = @import("std");
const gpu_mod = @import("sw_gpu");

pub const Preset = enum { low, medium, high, ultra };

pub const AntiAliasing = enum {
    none,
    fxaa,
    msaa2,
    msaa4,
    msaa8,

    /// The MSAA sample count: 1 when the method is not MSAA.
    pub fn samples(self: AntiAliasing) u32 {
        return switch (self) {
            .none, .fxaa => 1,
            .msaa2 => 2,
            .msaa4 => 4,
            .msaa8 => 8,
        };
    }
};

pub const GraphicsSettings = struct {
    /// The view distance, in the unit of the game.
    render_distance: u32 = 12,
    anti_aliasing: AntiAliasing = .fxaa,
    fxaa_quality: gpu_mod.FxaaQuality = .medium,
    /// The most mip levels of a texture. 1: no mips.
    mip_levels: u32 = 5,
    /// The anisotropic filter, 1 to 16. 1: off.
    anisotropy: u16 = 4,
    shadows: bool = true,
    /// The number of shadow cascades.
    shadow_cascades: u32 = 3,
    /// The width and height of each shadow map, in texels.
    shadow_map_size: u32 = 2048,
    /// The world lighting. `.skylight` darkens the places that the sky
    /// does not reach. `.none` lights each face fully.
    lighting: gpu_mod.LightingMode = .skylight,
    vsync: bool = true,
    /// The frame rate that the frame limiter holds. Null: no limit.
    frame_limit: ?u32 = null,

    /// The settings of a preset.
    pub fn preset(p: Preset) GraphicsSettings {
        return switch (p) {
            .low => .{
                .render_distance = 6,
                .anti_aliasing = .none,
                .mip_levels = 1,
                .anisotropy = 1,
                .shadows = false,
                .shadow_cascades = 1,
                .shadow_map_size = 1024,
            },
            .medium => .{
                .render_distance = 10,
                .anti_aliasing = .fxaa,
                .fxaa_quality = .low,
                .mip_levels = 4,
                .anisotropy = 2,
                .shadows = true,
                .shadow_cascades = 2,
                .shadow_map_size = 1024,
            },
            .high => .{},
            .ultra => .{
                .render_distance = 20,
                .anti_aliasing = .msaa4,
                .mip_levels = 8,
                .anisotropy = 16,
                .shadows = true,
                .shadow_cascades = 4,
                .shadow_map_size = 4096,
            },
        };
    }

    /// The preset that has these settings. Null when a value differs from
    /// each preset, for example after the player changes one value. Vsync
    /// and the frame limit are not part of a preset.
    pub fn matchingPreset(self: GraphicsSettings) ?Preset {
        for (std.enums.values(Preset)) |p| {
            var want = preset(p);
            want.vsync = self.vsync;
            want.frame_limit = self.frame_limit;
            if (std.meta.eql(want, self)) return p;
        }
        return null;
    }

    /// The anti-aliasing for `GPU.configureMSAA`.
    pub fn antiAliasingConfig(self: GraphicsSettings) gpu_mod.AntiAliasingConfig {
        return switch (self.anti_aliasing) {
            .none => .{},
            .fxaa => .{ .method = .fxaa, .fxaa_quality = self.fxaa_quality },
            .msaa2, .msaa4, .msaa8 => .{ .method = .msaa, .msaa_samples = self.anti_aliasing.samples() },
        };
    }

    /// The mip levels of a texture that has `full` levels in its full
    /// chain: `full`, but not more than `mip_levels` and not less than 1.
    pub fn mipLevelsFor(self: GraphicsSettings, full: u32) u32 {
        return @max(1, @min(full, self.mip_levels));
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "settings: each preset is better than or equal to the preset below it (REQ-GPU-026)" {
    const all = std.enums.values(Preset);
    for (all[1..], 0..) |p, i| {
        const lo = GraphicsSettings.preset(all[i]);
        const hi = GraphicsSettings.preset(p);
        try testing.expect(hi.render_distance > lo.render_distance);
        try testing.expect(hi.mip_levels >= lo.mip_levels);
        try testing.expect(hi.anisotropy >= lo.anisotropy);
        try testing.expect(hi.shadow_cascades >= lo.shadow_cascades);
        try testing.expect(hi.shadow_map_size >= lo.shadow_map_size);
        try testing.expect(@intFromBool(hi.shadows) >= @intFromBool(lo.shadows));
    }
    try testing.expect(!GraphicsSettings.preset(.low).shadows);
    try testing.expectEqual(AntiAliasing.none, GraphicsSettings.preset(.low).anti_aliasing);
}

test "settings: a preset matches itself, and a changed value matches no preset (REQ-GPU-026)" {
    for (std.enums.values(Preset)) |p| {
        var s = GraphicsSettings.preset(p);
        s.vsync = false;
        s.frame_limit = 30;
        try testing.expectEqual(@as(?Preset, p), s.matchingPreset());
        s.render_distance += 1;
        try testing.expectEqual(@as(?Preset, null), s.matchingPreset());
    }
}

test "settings: the anti-aliasing gives the sw_gpu configuration (REQ-GPU-026)" {
    var s: GraphicsSettings = .{ .anti_aliasing = .msaa4 };
    try testing.expectEqual(gpu_mod.AAMethod.msaa, s.antiAliasingConfig().method);
    try testing.expectEqual(@as(u32, 4), s.antiAliasingConfig().msaa_samples);
    s.anti_aliasing = .msaa2;
    try testing.expectEqual(@as(u32, 2), s.antiAliasingConfig().msaa_samples);
    s.anti_aliasing = .fxaa;
    s.fxaa_quality = .high;
    try testing.expectEqual(gpu_mod.AAMethod.fxaa, s.antiAliasingConfig().method);
    try testing.expectEqual(gpu_mod.FxaaQuality.high, s.antiAliasingConfig().fxaa_quality);
    s.anti_aliasing = .none;
    try testing.expectEqual(gpu_mod.AAMethod.none, s.antiAliasingConfig().method);
    try testing.expectEqual(@as(u32, 1), s.antiAliasingConfig().msaa_samples);
}

test "settings: the mip levels are not more than the setting and not less than 1 (REQ-GPU-026)" {
    const s: GraphicsSettings = .{ .mip_levels = 4 };
    try testing.expectEqual(@as(u32, 4), s.mipLevelsFor(9));
    try testing.expectEqual(@as(u32, 2), s.mipLevelsFor(2));
    try testing.expectEqual(@as(u32, 1), s.mipLevelsFor(0));
    try testing.expectEqual(@as(u32, 1), GraphicsSettings.preset(.low).mipLevelsFor(9));
}
