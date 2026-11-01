//! The screens of the pause menu of the shooter (REQ-DEMO-027), on the
//! shared game menu of the demos (demos/common/game_menu.zig,
//! REQ-DEMO-026).
//!
//! - The main screen: Resume, Graphics, Mouse, Audio, and Quit (native
//!   only).
//! - Graphics: the preset, the shadows, the shadow quality, the
//!   anti-aliasing, vsync and the frame limit.
//! - Mouse: the sensitivity and invert Y.
//! - Audio: the volume of the game and of the shots.
//!
//! `tick` builds the tree and reads its events. It changes `prefs`, and
//! tells the caller what to do. The caller applies the settings.
const std = @import("std");
const builtin = @import("builtin");
const demo = @import("demo_common");
const sw_ui = @import("sw_ui");
const sw_core = @import("sw_core");
const sw_render = @import("sw_render");
const gfx = @import("sw_gfx2d");
const prefs_mod = @import("prefs.zig");
const gm = demo.game_menu;
const ids = gm.ids;
const Prefs = prefs_mod.Prefs;

const Screen = enum { graphics, mouse, sound };

/// The screen IDs: 310 to 312.
fn screenId(s: Screen) u32 {
    return ids.screen + 10 + @as(u32, @backingInt(s));
}

/// What the caller does after a tick of the menu.
pub const Result = struct {
    /// The player chose Resume, or pressed Escape on the main screen.
    resume_game: bool = false,
    quit: bool = false,
    /// A setting changed: apply and save the settings.
    changed: bool = false,
};

pub const PauseMenu = struct {
    m: gm.Menu,
    screens: sw_ui.ScreenStack(Screen, 4) = .{},
    /// True while the menu is open: the pass draws it.
    visible: bool = false,

    /// Make the menu at its place: the UI keeps a pointer to the font.
    pub fn init(self: *PauseMenu, allocator: std.mem.Allocator, host: *demo.Host) !void {
        self.* = .{ .m = undefined };
        try self.m.init(allocator, host.gpu);
        try host.graph.addPass(.{
            .name = "shooter_menu",
            // Before the overlay (order 2000): the caption and the stats
            // stay on top. The shooter draws no HUD while the menu is open.
            .order = 1900,
            .attachments = .{ .colors = &.{.{ .target = .screen, .load_op = .load }} },
            .callback = .of(PauseMenu, self, draw),
        });
    }

    pub fn deinit(self: *PauseMenu) void {
        self.m.deinit();
    }

    /// Show the main screen with the focus on Resume.
    pub fn open(self: *PauseMenu) void {
        self.screens = .{};
        self.visible = true;
        self.m.ui.setFocus(ids.resume_game);
    }

    /// Stop the draw of the menu. The next `idle` empties the tree.
    pub fn close(self: *PauseMenu) void {
        self.visible = false;
    }

    /// Build an empty tree: the web mirror then has no menu.
    pub fn idle(self: *PauseMenu, host: *demo.Host) !void {
        self.screens = .{};
        self.visible = false;
        self.m.setLayout(host.gpu.getSurfaceWidth(), host.gpu.getSurfaceHeight(), host.ctx.window());
        try self.m.ui.begin(.{}, self.m.layout_w, gm.layout_height);
        try self.m.ui.finish();
    }

    /// One tick of the open menu. `escape`: the menu can read Escape (see
    /// `Pause.Step.escape`).
    pub fn tick(self: *PauseMenu, host: *demo.Host, snap: *const sw_core.InputSnapshot, prefs: *Prefs, escape: bool) !Result {
        const m = &self.m;
        m.setLayout(host.gpu.getSurfaceWidth(), host.gpu.getSurfaceHeight(), host.ctx.window());
        m.nav.update(snap);
        var input = m.input(snap, host.user_control, &.{});
        if (!escape) input.keys.escape = false;
        try m.ui.begin(input, m.layout_w, gm.layout_height);
        if (self.screens.top()) |top| switch (top) {
            .graphics => try self.buildGraphics(prefs),
            .mouse => try self.buildMouse(prefs),
            .sound => try m.audioScreen(screenId(.sound), &.{
                .{ .base = ids.master, .label = .master, .value = &prefs.volume },
                .{ .base = ids.effects, .label = .shots, .value = &prefs.shots },
            }),
        } else try self.buildMain();
        try m.ui.finish();

        var r: Result = .{};
        // Left and Right change a cycle or toggle button.
        if (input.keys.left or input.keys.right) {
            if (m.ui.focused()) |f| {
                if (step(prefs, f, input.keys.right)) r.changed = true;
            }
        }
        for (m.ui.frameEvents()) |e| switch (e.kind) {
            .activate => {
                if (step(prefs, e.id, true)) {
                    r.changed = true;
                    continue;
                }
                switch (e.id) {
                    ids.resume_game => r.resume_game = true,
                    ids.quit => r.quit = true,
                    ids.graphics => self.screens.push(&m.ui, .graphics) catch {},
                    ids.mouse => self.screens.push(&m.ui, .mouse) catch {},
                    ids.sound => self.screens.push(&m.ui, .sound) catch {},
                    ids.back => _ = self.screens.pop(&m.ui),
                    else => {},
                }
            },
            .cancel => {
                if (self.screens.pop(&m.ui) == null) r.resume_game = true;
            },
            .changed => switch (e.id) {
                ids.sensitivity + 2, ids.master + 2, ids.effects + 2 => r.changed = true,
                else => {},
            },
            .submit => {},
        };
        return r;
    }

    fn buildMain(self: *PauseMenu) !void {
        const m = &self.m;
        try m.beginPanel(null, m.tr(.paused));
        try m.ui.addButton(ids.resume_game, m.tr(.resume_game), gm.Menu.wide(m.tr(.fight_tip)));
        try m.ui.addButton(ids.graphics, m.tr(.graphics), gm.Menu.wide(m.tr(.shooter_graphics_tip)));
        try m.ui.addButton(ids.mouse, m.tr(.mouse), gm.Menu.wide(m.tr(.mouse_tip)));
        try m.ui.addButton(ids.sound, m.tr(.sound), gm.Menu.wide(m.tr(.shooter_sound_tip)));
        // The browser closes a page, not the game.
        if (!builtin.cpu.arch.isWasm()) try m.ui.addButton(ids.quit, m.tr(.quit), gm.Menu.wide(m.tr(.quit_tip)));
        try m.ui.addText(ids.hint, m.tr(.paused_hint), .{});
        m.endPanel();
    }

    fn buildGraphics(self: *PauseMenu, p: *Prefs) !void {
        const m = &self.m;
        try m.beginPanel(screenId(.graphics), m.tr(.graphics));
        try m.cycleButton(ids.preset, .preset, m.qualityName(switch (p.preset) {
            .low => .low,
            .medium => .medium,
            .high => .high,
            .custom => .custom,
        }));
        try m.toggleButton(ids.shadows, .shadows, p.shadows);
        const map = p.shadowMap();
        try m.cycleButton(ids.shadow_quality, .shadow_quality, try m.ui.print("{s} ({d}, {d}x)", .{ m.qualityName(switch (p.shadow_quality) {
            .low => .low,
            .medium => .medium,
            .high => .high,
            .ultra => .ultra,
        }), map.size, map.cascades }));
        try m.cycleButton(ids.aa, .anti_aliasing, switch (p.aa) {
            .off => m.tr(.off),
            .fxaa_low => "FXAA low",
            .fxaa_medium => "FXAA medium",
            .fxaa_high => "FXAA high",
        });
        try m.toggleButton(ids.vsync, .vsync, p.vsync);
        try m.cycleButton(ids.frame_limit, .frame_limit, if (p.fps()) |f| try m.ui.print("{d} fps", .{f}) else m.tr(.no_limit));
        try m.back();
        m.endPanel();
    }

    fn buildMouse(self: *PauseMenu, p: *Prefs) !void {
        const m = &self.m;
        try m.beginPanel(screenId(.mouse), m.tr(.mouse));
        try m.mouseRows(&p.sensitivity, p.invert_y);
        try m.back();
        m.endPanel();
    }

    fn draw(self: *PauseMenu, pass: *sw_render.Pass) anyerror!void {
        if (!self.visible) return;
        try self.m.drawUi(pass, gm.Menu.palette(), gfx.Color.rgba8(8, 10, 16, 120));
        try self.m.drawEnd(pass);
    }
};

/// Change the value of a cycle or toggle button. True when the ID is one.
fn step(p: *Prefs, id: u32, forward: bool) bool {
    switch (id) {
        ids.preset => {
            p.setPreset(switch (p.preset) {
                .low => if (forward) .medium else .high,
                .medium => if (forward) .high else .low,
                .high, .custom => if (forward) .low else .medium,
            });
            return true;
        },
        ids.shadows => p.shadows = !p.shadows,
        ids.shadow_quality => p.shadow_quality = gm.cycle(prefs_mod.ShadowQuality, p.shadow_quality, forward),
        ids.aa => p.aa = gm.cycle(prefs_mod.AntiAliasing, p.aa, forward),
        ids.vsync => {
            p.vsync = !p.vsync;
            return true;
        },
        ids.frame_limit => {
            p.frame_limit = gm.cycle(prefs_mod.FrameLimit, p.frame_limit, forward);
            return true;
        },
        ids.invert_y => {
            p.invert_y = !p.invert_y;
            return true;
        },
        else => return false,
    }
    p.preset = p.matchingPreset();
    return true;
}
