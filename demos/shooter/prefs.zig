//! The settings of the shooter that the pause menu changes, and their
//! text form for `sw_platform` storage (REQ-DEMO-028).
//!
//! The graphics: the preset, the shadows, the shadow quality (the map size
//! and the cascade count), the anti-aliasing (FXAA), vsync and the frame
//! limit. The mouse: the sensitivity and invert Y. The volume of the game
//! and of the shots. The ambient light of the indoor room.
//!
//! The text has one setting on each line: `<name> <value>`. A line that
//! the demo cannot read keeps the value before it, so an old or a damaged
//! save does not stop the game.
const std = @import("std");
const sw_render = @import("sw_render");
const FxaaQuality = @import("sw_gpu").FxaaQuality;

/// The storage key.
pub const key = "shooter-settings";

pub const Preset = enum { low, medium, high, custom };
/// The top of the ambient light slider of the room (REQ-DEMO-033).
pub const max_indoor_ambient: f32 = 0.3;
pub const ShadowQuality = enum { low, medium, high, ultra };
pub const AntiAliasing = enum { off, fxaa_low, fxaa_medium, fxaa_high };
pub const FrameLimit = enum { none, fps30, fps60, fps120, fps144 };

pub const Prefs = struct {
    preset: Preset = .medium,
    shadows: bool = true,
    shadow_quality: ShadowQuality = .medium,
    aa: AntiAliasing = .fxaa_low,
    vsync: bool = true,
    frame_limit: FrameLimit = .none,
    sensitivity: f32 = 1.0,
    invert_y: bool = false,
    volume: f32 = 1.0,
    shots: f32 = 1.0,
    /// The ambient light of the indoor room (REQ-DEMO-033). The default
    /// is the default of `scene.Settings.indoor_ambient`.
    indoor_ambient: f32 = 0.04,

    /// The settings that the scene has after `Scene.init` with the
    /// graphics settings `g` of a `--preset`, and the shadows on.
    pub fn fromGraphics(g: sw_render.GraphicsSettings) Prefs {
        var p: Prefs = .{
            .shadow_quality = qualityOf(g.shadow_map_size, @max(g.shadow_cascades, 1)),
            .aa = switch (g.fxaa_quality) {
                .low => .fxaa_low,
                .medium => .fxaa_medium,
                .high => .fxaa_high,
            },
            .vsync = g.vsync,
        };
        p.preset = p.matchingPreset();
        return p;
    }

    /// Set the graphics values of a preset. `custom` changes nothing.
    pub fn setPreset(self: *Prefs, p: Preset) void {
        self.preset = p;
        switch (p) {
            .low => {
                self.shadows = false;
                self.shadow_quality = .low;
                self.aa = .off;
            },
            .medium => {
                self.shadows = true;
                self.shadow_quality = .medium;
                self.aa = .fxaa_low;
            },
            .high => {
                self.shadows = true;
                self.shadow_quality = .high;
                self.aa = .fxaa_medium;
            },
            .custom => {},
        }
    }

    /// The preset that has the graphics values of these settings, or
    /// `custom`. Vsync and the frame limit are not part of a preset.
    pub fn matchingPreset(self: Prefs) Preset {
        for ([_]Preset{ .low, .medium, .high }) |p| {
            var want = self;
            want.setPreset(p);
            if (want.shadows == self.shadows and want.shadow_quality == self.shadow_quality and want.aa == self.aa) return p;
        }
        return .custom;
    }

    /// The size of each shadow map and the cascade count.
    pub fn shadowMap(self: Prefs) struct { size: u32, cascades: u32 } {
        return switch (self.shadow_quality) {
            .low => .{ .size = 1024, .cascades = 1 },
            .medium => .{ .size = 1024, .cascades = 2 },
            .high => .{ .size = 2048, .cascades = 3 },
            .ultra => .{ .size = 4096, .cascades = 4 },
        };
    }

    /// The FXAA quality, or null for no anti-aliasing.
    pub fn fxaa(self: Prefs) ?FxaaQuality {
        return switch (self.aa) {
            .off => null,
            .fxaa_low => .low,
            .fxaa_medium => .medium,
            .fxaa_high => .high,
        };
    }

    /// The frame rate of the frame limit, or null for no limit.
    pub fn fps(self: Prefs) ?u32 {
        return switch (self.frame_limit) {
            .none => null,
            .fps30 => 30,
            .fps60 => 60,
            .fps120 => 120,
            .fps144 => 144,
        };
    }

    /// Write the settings as text into `buf`.
    pub fn encode(self: Prefs, buf: []u8) ![]const u8 {
        var w: std.Io.Writer = .fixed(buf);
        const info = @typeInfo(Prefs).@"struct";
        inline for (info.field_names, info.field_types) |name, T| {
            const v = @field(self, name);
            switch (@typeInfo(T)) {
                .@"enum" => try w.print("{s} {s}\n", .{ name, @tagName(v) }),
                .bool => try w.print("{s} {s}\n", .{ name, if (v) "on" else "off" }),
                .float => try w.print("{s} {d:.2}\n", .{ name, v }),
                else => @compileError("prefs: no text form for " ++ name),
            }
        }
        return w.buffered();
    }

    /// Read the text of `encode` over these settings. A line with an
    /// unknown name or a bad value does not change a setting.
    pub fn decode(self: *Prefs, text: []const u8) void {
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \r\t");
            const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            const name = line[0..space];
            const value = std.mem.trim(u8, line[space + 1 ..], " ");
            const info = @typeInfo(Prefs).@"struct";
            inline for (info.field_names, info.field_types) |fname, T| {
                if (std.mem.eql(u8, name, fname)) setValue(T, &@field(self, fname), value);
            }
        }
        self.sensitivity = std.math.clamp(self.sensitivity, 0.1, 3);
        self.volume = std.math.clamp(self.volume, 0, 1);
        self.shots = std.math.clamp(self.shots, 0, 1);
        self.indoor_ambient = std.math.clamp(self.indoor_ambient, 0, max_indoor_ambient);
    }
};

fn setValue(comptime T: type, out: *T, value: []const u8) void {
    switch (@typeInfo(T)) {
        .@"enum" => out.* = std.meta.stringToEnum(T, value) orelse return,
        .bool => {
            if (std.mem.eql(u8, value, "on")) out.* = true else if (std.mem.eql(u8, value, "off")) out.* = false;
        },
        .float => {
            const v = std.fmt.parseFloat(T, value) catch return;
            if (std.math.isFinite(v)) out.* = v;
        },
        else => @compileError("prefs: no text form"),
    }
}

/// The shadow quality of a map size and a cascade count. A size and count
/// that no quality has give the nearest quality below.
fn qualityOf(size: u32, cascades: u32) ShadowQuality {
    if (cascades >= 4 and size >= 4096) return .ultra;
    if (cascades >= 3 and size >= 2048) return .high;
    if (cascades >= 2) return .medium;
    return .low;
}

test "prefs: the text form gives the same settings back (REQ-DEMO-028)" {
    var p: Prefs = .{};
    p.setPreset(.high);
    p.shadow_quality = .ultra;
    p.vsync = false;
    p.frame_limit = .fps60;
    p.sensitivity = 1.7;
    p.invert_y = true;
    p.volume = 0.35;
    p.indoor_ambient = 0.12;
    p.preset = p.matchingPreset();
    var buf: [512]u8 = undefined;
    const text = try p.encode(&buf);
    var q: Prefs = .{};
    q.decode(text);
    try std.testing.expectEqual(p, q);
    try std.testing.expectEqual(Preset.custom, q.preset);
}

test "prefs: a bad line keeps the value before it (REQ-DEMO-028)" {
    var q: Prefs = .{};
    q.decode("shadows maybe\nvolume nan\nshadow_quality huge\nnot_a_setting 3\nsensitivity 99\n\ninvert_y on\nindoor_ambient 5");
    // A value out of the range of the slider goes to its end (REQ-DEMO-033).
    try std.testing.expectEqual(max_indoor_ambient, q.indoor_ambient);
    try std.testing.expect(q.shadows);
    try std.testing.expectEqual(@as(f32, 1.0), q.volume);
    try std.testing.expectEqual(ShadowQuality.medium, q.shadow_quality);
    try std.testing.expectEqual(@as(f32, 3), q.sensitivity);
    try std.testing.expect(q.invert_y);
}

test "prefs: a preset sets the graphics, and a change gives custom (REQ-DEMO-027)" {
    var p: Prefs = .{};
    p.setPreset(.low);
    try std.testing.expect(!p.shadows);
    try std.testing.expectEqual(@as(?FxaaQuality, null), p.fxaa());
    try std.testing.expectEqual(Preset.low, p.matchingPreset());
    p.shadows = true;
    try std.testing.expectEqual(Preset.custom, p.matchingPreset());
    p.setPreset(.high);
    try std.testing.expectEqual(@as(u32, 2048), p.shadowMap().size);
    try std.testing.expectEqual(@as(u32, 3), p.shadowMap().cascades);
}

test "prefs: the --preset graphics give the settings of the scene (REQ-DEMO-027)" {
    try std.testing.expectEqual(Preset.medium, Prefs.fromGraphics(sw_render.GraphicsSettings.preset(.medium)).preset);
    try std.testing.expectEqual(Preset.high, Prefs.fromGraphics(sw_render.GraphicsSettings.preset(.high)).preset);
    // The low preset of the demos keeps the shadows and FXAA: no preset of
    // the menu has them.
    const low = Prefs.fromGraphics(sw_render.GraphicsSettings.preset(.low));
    try std.testing.expectEqual(ShadowQuality.low, low.shadow_quality);
    try std.testing.expectEqual(Preset.custom, low.preset);
}
