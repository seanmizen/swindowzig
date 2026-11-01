//! The game menu of the demos (REQ-DEMO-026): the menu frame and the
//! screen parts that the `menu` demo and the `shooter` demo share.
//!
//! - `Menu`: the sw_ui tree, the TrueType and bitmap fonts, the 2D
//!   renderer, the gamepad navigation, the language and the font, and the
//!   layout scale. `input` makes the sw_ui input from the keyboard, the
//!   mouse and a gamepad. `drawUi` and `drawEnd` draw the tree in a pass.
//! - The text of each language (`S`, `english`, `hebrew`).
//! - The node IDs (`ids`). The two demos use the same IDs.
//! - The parts of a screen: `beginPanel`, `cycleButton`, `sliderRow`,
//!   `toggleRow`, `toggleButton`, and the shared rows and screens
//!   (`mouseRows`, `audioScreen`).
//!
//! Each demo keeps its own screens and gives the values that they change.
//! The web build mirrors the tree for a screen reader
//! (backends/wasm/a11y.ts): `Ui.finish` sends it.
const std = @import("std");
const sw_ui = @import("sw_ui");
const sw_text = @import("sw_text");
const gfx = @import("sw_gfx2d");
const core = @import("sw_core");
const sw_gpu = @import("sw_gpu");
const sw_render = @import("sw_render");
const pixel_font = @import("pixel_font.zig");

/// The overlay font (Lato, SIL Open Font License).
const font_ttf = @embedFile("demo_font");

/// Noto Sans Hebrew, under the SIL Open Font License
/// (assets/NotoSansHebrew-OFL.txt).
pub const hebrew_ttf = @embedFile("assets/NotoSansHebrew-Regular.ttf");

/// The layout is this many units high at each surface size.
pub const layout_height: f32 = 540;
pub const panel_width: f32 = 370;

// ---- Text -------------------------------------------------------------------

pub const Language = enum { english, hebrew };
pub const FontKind = enum { truetype, bitmap };

pub const S = enum {
    title,
    player_line,
    no_name,
    hint,
    resume_game,
    resume_tip,
    settings,
    settings_tip,
    player,
    player_tip,
    back,
    open_menu,
    open_menu_tip,
    graphics,
    graphics_tip,
    sound,
    sound_tip,
    controls,
    controls_tip,
    gamepad,
    gamepad_tip,
    interface,
    interface_tip,
    preset,
    preset_tip,
    low,
    medium,
    high,
    ultra,
    custom,
    anti_aliasing,
    off,
    on,
    coat,
    exposure,
    time_of_day,
    spin,
    shadows,
    occlusion,
    fog,
    sky,
    wireframe,
    master,
    music,
    effects,
    ui_sounds,
    orbit_left,
    orbit_right,
    orbit_up,
    orbit_down,
    moo,
    press_key,
    conflict,
    no_conflict,
    reset_keys,
    sensitivity,
    invert_y,
    dead_zone,
    dead_zone_tip,
    left_stick,
    right_stick,
    pad_hint,
    no_pad,
    language,
    font,
    font_truetype,
    font_bitmap,
    name,
    keyboard,
    keyboard_tip,
    hours,
    hours_tip,
    // The pause menu of the shooter.
    paused,
    paused_hint,
    fight_tip,
    shooter_graphics_tip,
    mouse,
    mouse_tip,
    shooter_sound_tip,
    shots,
    quit,
    quit_tip,
    shadow_quality,
    vsync,
    frame_limit,
    no_limit,
};

pub const english = std.enums.EnumArray(S, []const u8).init(.{
    .title = "Cow menu",
    .player_line = "Player",
    .no_name = "(no name)",
    .hint = "Arrows, Tab, Enter, Esc. Drag to turn.",
    .resume_game = "Resume",
    .resume_tip = "Hide the menu. Esc shows it again.",
    .settings = "Settings",
    .settings_tip = "Graphics, audio, controls, gamepad, interface",
    .player = "Player",
    .player_tip = "Your name and the time of day",
    .back = "Back",
    .open_menu = "Menu",
    .open_menu_tip = "Esc also opens the menu",
    .graphics = "Graphics",
    .graphics_tip = "The look of the cow scene",
    .sound = "Audio",
    .sound_tip = "A volume for each sound group",
    .controls = "Controls",
    .controls_tip = "Keys, mouse sensitivity, invert Y",
    .gamepad = "Gamepad",
    .gamepad_tip = "The stick dead zone",
    .interface = "Interface",
    .interface_tip = "Language and font",
    .preset = "Preset",
    .preset_tip = "Left and Right change it",
    .low = "Low",
    .medium = "Medium",
    .high = "High",
    .ultra = "Ultra",
    .custom = "Custom",
    .anti_aliasing = "Anti-aliasing",
    .off = "off",
    .on = "on",
    .coat = "Coat",
    .exposure = "Exposure",
    .time_of_day = "Time of day",
    .spin = "Turn speed",
    .shadows = "Shadows",
    .occlusion = "Occlusion",
    .fog = "Fog",
    .sky = "Sky",
    .wireframe = "Wireframe",
    .master = "Master",
    .music = "Music",
    .effects = "Effects",
    .ui_sounds = "Interface",
    .orbit_left = "Turn left",
    .orbit_right = "Turn right",
    .orbit_up = "Turn up",
    .orbit_down = "Turn down",
    .moo = "Moo",
    .press_key = "Press a key (Esc cancels)",
    .conflict = "is also bound to",
    .no_conflict = "No conflicts",
    .reset_keys = "Reset the keys",
    .sensitivity = "Mouse sensitivity",
    .invert_y = "Invert Y",
    .dead_zone = "Dead zone",
    .dead_zone_tip = "The stick is at the centre inside this distance",
    .left_stick = "Left stick",
    .right_stick = "Right stick",
    .pad_hint = "The right stick turns the camera.",
    .no_pad = "No gamepad: press a button on it",
    .language = "Language",
    .font = "Font",
    .font_truetype = "Lato (TrueType)",
    .font_bitmap = "Bitmap font",
    .name = "Player name",
    .keyboard = "On-screen keyboard",
    .keyboard_tip = "Type with the arrow keys or a gamepad",
    .hours = "Time of day",
    .hours_tip = "Pick an hour for the sky",
    .paused = "Paused",
    .paused_hint = "Esc or Start continues the fight.",
    .fight_tip = "Lock the mouse and continue the fight",
    .shooter_graphics_tip = "Preset, shadows, anti-aliasing, frame rate",
    .mouse = "Mouse",
    .mouse_tip = "Sensitivity and invert Y",
    .shooter_sound_tip = "The volume of the game and of the shots",
    .shots = "Shots",
    .quit = "Quit",
    .quit_tip = "Close the game",
    .shadow_quality = "Shadow quality",
    .vsync = "Vsync",
    .frame_limit = "Frame limit",
    .no_limit = "none",
});

// Hebrew needs no letter joining. The bidi algorithm of sw_text puts each
// line in visual order.
pub const hebrew = std.enums.EnumArray(S, []const u8).init(.{
    .title = "תפריט הפרה",
    .player_line = "שחקן",
    .no_name = "(אין שם)",
    .hint = "חצים, Tab, Enter, Esc. גררו כדי לסובב.",
    .resume_game = "המשך",
    .resume_tip = "הסתרת התפריט. Esc מציג אותו שוב.",
    .settings = "הגדרות",
    .settings_tip = "גרפיקה, שמע, שליטה, בקר, ממשק",
    .player = "שחקן",
    .player_tip = "השם שלך והשעה ביום",
    .back = "חזרה",
    .open_menu = "תפריט",
    .open_menu_tip = "גם Esc פותח את התפריט",
    .graphics = "גרפיקה",
    .graphics_tip = "המראה של הפרה",
    .sound = "שמע",
    .sound_tip = "עוצמה לכל קבוצת צלילים",
    .controls = "שליטה",
    .controls_tip = "מקשים, רגישות עכבר, היפוך Y",
    .gamepad = "בקר משחק",
    .gamepad_tip = "האזור המת של הסטיק",
    .interface = "ממשק",
    .interface_tip = "שפה וגופן",
    .preset = "רמת איכות",
    .preset_tip = "ימינה ושמאלה משנים אותה",
    .low = "נמוכה",
    .medium = "בינונית",
    .high = "גבוהה",
    .ultra = "עליונה",
    .custom = "מותאמת",
    .anti_aliasing = "החלקת קצוות",
    .off = "כבוי",
    .on = "פועל",
    .coat = "פרווה",
    .exposure = "חשיפה",
    .time_of_day = "שעה ביום",
    .spin = "מהירות סיבוב",
    .shadows = "צללים",
    .occlusion = "הצללה",
    .fog = "ערפל",
    .sky = "שמיים",
    .wireframe = "רשת קווים",
    .master = "ראשי",
    .music = "מוזיקה",
    .effects = "אפקטים",
    .ui_sounds = "ממשק",
    .orbit_left = "סיבוב שמאלה",
    .orbit_right = "סיבוב ימינה",
    .orbit_up = "סיבוב למעלה",
    .orbit_down = "סיבוב למטה",
    .moo = "מו",
    .press_key = "לחצו על מקש (Esc מבטל)",
    .conflict = "מוקצה גם ל",
    .no_conflict = "אין התנגשויות",
    .reset_keys = "איפוס המקשים",
    .sensitivity = "רגישות עכבר",
    .invert_y = "היפוך Y",
    .dead_zone = "אזור מת",
    .dead_zone_tip = "הסטיק במרכז בתוך המרחק הזה",
    .left_stick = "סטיק שמאלי",
    .right_stick = "סטיק ימני",
    .pad_hint = "הסטיק הימני מסובב את המצלמה.",
    .no_pad = "אין בקר: לחצו על כפתור בבקר",
    .language = "שפה",
    .font = "גופן",
    .font_truetype = "Lato (TrueType)",
    .font_bitmap = "גופן מפת סיביות",
    .name = "שם השחקן",
    .keyboard = "מקלדת על המסך",
    .keyboard_tip = "הקלדה בחצים או בבקר",
    .hours = "שעה ביום",
    .hours_tip = "בחרו שעה לשמיים",
    .paused = "הפסקה",
    .paused_hint = "Esc או Start ממשיכים את הקרב.",
    .fight_tip = "נעילת העכבר והמשך הקרב",
    .shooter_graphics_tip = "רמת איכות, צללים, החלקת קצוות, קצב תמונות",
    .mouse = "עכבר",
    .mouse_tip = "רגישות והיפוך Y",
    .shooter_sound_tip = "עוצמת המשחק ועוצמת היריות",
    .shots = "יריות",
    .quit = "יציאה",
    .quit_tip = "סגירת המשחק",
    .shadow_quality = "איכות צללים",
    .vsync = "סנכרון אנכי",
    .frame_limit = "הגבלת קצב",
    .no_limit = "ללא",
});

/// The Hebrew keys of the on-screen keyboard (the Israeli layout).
pub const hebrew_keys: sw_ui.osk.Layout = .{
    .rows = &.{ "1234567890", "/'קראטוןםפ", "שדגכעיחלךף", "זסבהנמצתץ." },
    .shifted = &.{ "1234567890", "/'קראטוןםפ", "שדגכעיחלךף", "זסבהנמצתץ." },
};

// ---- Gamepad navigation -----------------------------------------------------

const Binding = core.Binding;

/// The gamepad navigation of the UI. The keyboard goes to the UI directly.
pub const Nav = enum { up, down, left, right, activate, back, next, prev };
pub const nav_defaults: core.ActionMap(Nav).Defaults = .{
    .up = &.{ Binding.gamepadButton(.dpad_up), Binding.gamepadAxis(.left_y, false) },
    .down = &.{ Binding.gamepadButton(.dpad_down), Binding.gamepadAxis(.left_y, true) },
    .left = &.{ Binding.gamepadButton(.dpad_left), Binding.gamepadAxis(.left_x, false) },
    .right = &.{ Binding.gamepadButton(.dpad_right), Binding.gamepadAxis(.left_x, true) },
    .activate = &.{Binding.gamepadButton(.south)},
    .back = &.{Binding.gamepadButton(.east)},
    .next = &.{Binding.gamepadButton(.right_shoulder)},
    .prev = &.{Binding.gamepadButton(.left_shoulder)},
};

// ---- IDs --------------------------------------------------------------------

/// The node IDs of the two demos.
pub const ids = struct {
    pub const area: u32 = 1;
    pub const panel: u32 = 2;
    pub const spacer: u32 = 16;
    pub const title: u32 = 3;
    pub const player_line: u32 = 4;
    pub const hint: u32 = 5;
    pub const resume_game: u32 = 6;
    pub const settings: u32 = 7;
    pub const player: u32 = 8;
    pub const open_menu: u32 = 9;
    pub const back: u32 = 10;
    pub const graphics: u32 = 11;
    pub const sound: u32 = 12;
    pub const controls: u32 = 13;
    pub const gamepad: u32 = 14;
    pub const interface: u32 = 15;
    // Graphics.
    pub const preset: u32 = 20;
    pub const aa: u32 = 21;
    pub const coat: u32 = 22;
    pub const shadows: u32 = 23;
    pub const occlusion: u32 = 24;
    pub const fog: u32 = 25;
    pub const sky: u32 = 26;
    pub const wireframe: u32 = 27;
    pub const toggle_row_a: u32 = 28;
    pub const toggle_row_b: u32 = 29;
    pub const shadow_quality: u32 = 30;
    pub const vsync: u32 = 31;
    pub const frame_limit: u32 = 32;
    // A slider row: row, label, slider, value (4 IDs from the base).
    pub const exposure: u32 = 40;
    pub const time: u32 = 44;
    pub const spin: u32 = 48;
    pub const master: u32 = 52;
    pub const music: u32 = 56;
    pub const effects: u32 = 60;
    pub const ui_sounds: u32 = 64;
    pub const sensitivity: u32 = 68;
    pub const dead_zone: u32 = 72;
    // Controls.
    pub const conflict: u32 = 80;
    pub const reset_keys: u32 = 81;
    pub const invert_y: u32 = 82;
    /// A binding row: row, label, button (3 IDs for each action).
    pub const bind_rows: u32 = 90;
    // Gamepad.
    pub const left_stick: u32 = 120;
    pub const right_stick: u32 = 121;
    pub const pad_hint: u32 = 122;
    // Interface.
    pub const language_label: u32 = 130;
    pub const language_list: u32 = 131;
    pub const font_label: u32 = 132;
    pub const font_list: u32 = 133;
    pub const language_item: u32 = 140;
    pub const font_item: u32 = 150;
    // Player.
    pub const name_field: u32 = 160;
    pub const keyboard_button: u32 = 161;
    pub const hours_list: u32 = 162;
    pub const keyboard_field: u32 = 163;
    pub const hour_item: u32 = 200;
    // The pause menu of the shooter.
    pub const mouse: u32 = 230;
    pub const quit: u32 = 231;
    /// The screens are 300 to 307 (the menu demo) and 310 to 312 (the
    /// shooter).
    pub const screen: u32 = 300;
    /// The on-screen keyboard uses osk to osk + sw_ui.osk.id_span - 1.
    pub const osk: u32 = 1000;
};

/// A quality level, for a preset or one setting.
pub const Quality = enum { low, medium, high, ultra, custom };

/// The IDs of one list: Up and Down move inside it.
pub const ListRange = struct { first: u32, last: u32 };

/// The next or the previous value of an enum, in a loop.
pub fn cycle(comptime E: type, v: E, forward: bool) E {
    const n = std.enums.values(E).len;
    // usize: `i + 1` does not fit the backing integer of the last value.
    const i: usize = @backingInt(v);
    return @fromBackingInt(@intCast(if (forward) (i + 1) % n else (i + n - 1) % n));
}

/// Make the bitmap font: the hand-drawn pixel font of `pixel_font.zig`,
/// drawn at a whole number scale. Hebrew and other characters come from the
/// next fonts of the chain.
fn makeBitmapFont(allocator: std.mem.Allocator) !sw_text.TextRenderer {
    const pixels = try allocator.create([pixel_font.sheet_width * pixel_font.sheet_height]u8);
    defer allocator.destroy(pixels);
    var codepoints: [pixel_font.glyphs.len]u21 = undefined;
    var widths: [pixel_font.glyphs.len]u8 = undefined;
    pixel_font.fill(pixels, &codepoints, &widths);
    var t = try sw_text.TextRenderer.initBitmap(allocator, .{
        .sheet = .{ .pixels = pixels, .width = pixel_font.sheet_width, .height = pixel_font.sheet_height, .format = .alpha8 },
        .cell_width = pixel_font.cell_width,
        .cell_height = pixel_font.cell_height,
        .codepoints = &codepoints,
        .widths = &widths,
        .baseline = pixel_font.baseline,
        .integer_scale = true,
    });
    errdefer t.deinit();
    try t.addFont(hebrew_ttf);
    try t.addFont(font_ttf);
    return t;
}

// ---- The menu ---------------------------------------------------------------

/// The menu frame. It must stay at its address: the UI keeps a pointer to
/// the font.
pub const Menu = struct {
    ui: sw_ui.Ui,
    ttf: sw_text.TextRenderer,
    bitmap: sw_text.TextRenderer,
    r2d: gfx.Renderer,
    nav: core.ActionMap(Nav),
    language: Language = .english,
    font: FontKind = .truetype,
    /// The layout width, in layout units.
    layout_w: f32 = 960,
    /// Window units to layout units, for the pointer of the player.
    layout_scale: f32 = 1,

    pub fn init(self: *Menu, allocator: std.mem.Allocator, gpu: *sw_gpu.GPU) !void {
        self.* = .{
            .ui = undefined,
            .ttf = try sw_text.TextRenderer.init(allocator, font_ttf),
            .bitmap = undefined,
            .r2d = undefined,
            .nav = core.ActionMap(Nav).init(nav_defaults),
        };
        errdefer self.ttf.deinit();
        try self.ttf.addFont(hebrew_ttf);
        self.bitmap = try makeBitmapFont(allocator);
        errdefer self.bitmap.deinit();
        self.r2d = try gfx.Renderer.init(allocator, gpu, .{});
        self.ui = sw_ui.Ui.init(allocator, sw_ui.draw.measurer(&self.ttf), .{ .text_size = 15, .control_pad = 6, .field_width = 200 });
    }

    pub fn deinit(self: *Menu) void {
        self.ui.deinit();
        self.r2d.deinit();
        self.bitmap.deinit();
        self.ttf.deinit();
    }

    pub fn tr(self: *const Menu, s: S) []const u8 {
        return switch (self.language) {
            .english => english.get(s),
            .hebrew => hebrew.get(s),
        };
    }

    pub fn rtl(self: *const Menu) bool {
        return self.language == .hebrew;
    }

    pub fn onOff(self: *const Menu, v: bool) []const u8 {
        return self.tr(if (v) .on else .off);
    }

    pub fn text(self: *Menu) *sw_text.TextRenderer {
        return if (self.font == .bitmap) &self.bitmap else &self.ttf;
    }

    /// Give the UI the size of the text of the current font.
    pub fn applyFont(self: *Menu) void {
        self.ui.measurer = sw_ui.draw.measurer(self.text());
    }

    /// Set the layout size from the surface and the window. Call it one
    /// time in each tick, before `input`.
    pub fn setLayout(self: *Menu, surface_w: u32, surface_h: u32, win: anytype) void {
        const sw_h: f32 = @floatFromInt(@max(surface_h, 1));
        const sw_w: f32 = @floatFromInt(@max(surface_w, 1));
        self.layout_w = sw_w * layout_height / sw_h;
        const logical_h = @as(f32, @floatFromInt(@max(win.height, 1))) / @max(win.dpi_scale, 0.01);
        self.layout_scale = layout_height / logical_h;
    }

    /// The input of the UI. Up and Down move the focus to the previous
    /// and next control (as Shift+Tab and Tab), so a gamepad D-pad goes
    /// through each control. In a list of `lists`, they move inside the
    /// list, then out at its ends. The on-screen keyboard keeps the arrow
    /// keys. Call `nav.update(snap)` before.
    pub fn input(self: *Menu, snap: *const core.InputSnapshot, from_player: bool, lists: []const ListRange) sw_ui.Input {
        const nav = &self.nav;
        const shortcut = snap.mods.ctrl or snap.mods.super;
        var keys: sw_ui.Keys = .{
            .tab = snap.keyPressed(.Tab) or nav.pressed(.next) or nav.pressed(.prev),
            .up = snap.keyPressed(.Up) or nav.pressed(.up),
            .down = snap.keyPressed(.Down) or nav.pressed(.down),
            .left = snap.keyPressed(.Left) or nav.pressed(.left),
            .right = snap.keyPressed(.Right) or nav.pressed(.right),
            .enter = snap.keyPressed(.Enter) or nav.pressed(.activate),
            .space = snap.keyPressed(.Space),
            .escape = snap.keyPressed(.Escape) or nav.pressed(.back),
            .backspace = snap.keyPressed(.Backspace),
            .home = snap.keyPressed(.Home),
            .end = snap.keyPressed(.End),
            .delete = snap.keyPressed(.Delete),
            .select_all = shortcut and snap.keyPressed(.A),
            .copy = shortcut and snap.keyPressed(.C),
            .cut = snap.keyPressed(.X) and shortcut,
            .paste = shortcut and snap.keyPressed(.V),
        };
        var shift = snap.mods.shift or nav.down(.prev);
        const focus = self.ui.focused() orelse 0;
        const in_osk = focus >= ids.osk and focus < ids.osk + sw_ui.osk.id_span;
        if (!in_osk and (keys.up or keys.down)) {
            var to_tab = true;
            for (lists) |range| {
                if (focus >= range.first and focus <= range.last) {
                    to_tab = (keys.up and focus == range.first) or (keys.down and focus == range.last);
                }
            }
            if (to_tab) {
                shift = keys.up;
                keys.tab = true;
                keys.up = false;
                keys.down = false;
            }
        }
        // A pointer from the player is in window units. The layout is
        // `layout_height` units high.
        const k: f32 = if (from_player) self.layout_scale else 1;
        return .{
            .keys = keys,
            .shift = shift,
            .pointer_x = snap.mouse.x * k,
            .pointer_y = snap.mouse.y * k,
            .pointer_pressed = snap.buttonPressed(.left),
            .pointer_down = snap.buttonDown(.left),
            .wheel_y = snap.wheel.delta_y,
            .text = snap.text.text(),
            .composition = snap.composition.text(),
        };
    }

    // ---- The parts of a screen ----------------------------------------------

    /// Open the panel of a screen: on the right, or on the left in Hebrew.
    pub fn beginPanel(self: *Menu, screen_id: ?u32, title: []const u8) !void {
        const ui = &self.ui;
        const area: sw_ui.Opts = .{
            .w = .fill,
            .h = .fill,
            .padding = 16,
            .cross_align = if (self.rtl()) .start else .end,
            .label = title,
        };
        if (screen_id) |id| try ui.beginScreen(id, title, area) else try ui.beginColumn(ids.area, area);
        // Right to left, the panel is on the left: it starts under the stats.
        if (self.rtl()) {
            try ui.beginColumn(ids.spacer, .{ .h = .{ .fixed = 64 } });
            ui.endContainer();
        }
        try ui.beginColumn(ids.panel, .{
            .w = .{ .fixed = panel_width },
            .padding = 12,
            .gap = 5,
            .panel = true,
            .cross_align = if (self.rtl()) .end else .start,
            .label = title,
        });
        try ui.addText(ids.title, title, .{});
    }

    pub fn endPanel(self: *Menu) void {
        self.ui.endContainer();
        self.ui.endContainer();
    }

    pub fn wide(tip: []const u8) sw_ui.Opts {
        return .{ .w = .fill, .tooltip = tip };
    }

    /// A button that cycles a value with Left and Right. The screen shows
    /// the value between arrows. A screen reader gets the name with no
    /// arrows, and the keys as the description.
    pub fn cycleButton(self: *Menu, id: u32, label: S, value: []const u8) !void {
        const ui = &self.ui;
        try ui.addButton(id, try ui.print("{s}:  \u{2039} {s} \u{203A}", .{ self.tr(label), value }), .{
            .w = .fill,
            .label = try ui.print("{s}: {s}", .{ self.tr(label), value }),
            .description = self.tr(.preset_tip),
        });
    }

    /// A row: a label, a slider and its value as text. Right to left, the
    /// label is on the right.
    pub fn sliderRow(self: *Menu, base: u32, label: []const u8, value: *f32, opts: sw_ui.SliderOpts, value_text: []const u8, tip: []const u8) !void {
        const ui = &self.ui;
        try ui.beginRow(base, .{ .w = .fill, .gap = 8, .cross_align = .center });
        var o = opts;
        o.text = value_text;
        const parts = [_]u8{ 0, 1, 2 };
        for (parts) |p0| {
            const p = if (self.rtl()) 2 - p0 else p0;
            switch (p) {
                0 => try ui.addText(base + 1, label, .{ .w = .{ .fixed = 120 } }),
                1 => try ui.addSlider(base + 2, label, value, o, .{ .w = .fill, .tooltip = tip }),
                else => try ui.addText(base + 3, value_text, .{ .w = .{ .fixed = 48 } }),
            }
        }
        ui.endContainer();
    }

    /// Two on and off buttons in one row.
    pub fn toggleRow(self: *Menu, row_id: u32, a_id: u32, a_label: S, a: bool, b_id: u32, b_label: S, b: bool) !void {
        const ui = &self.ui;
        try ui.beginRow(row_id, .{ .w = .fill, .gap = 6 });
        const first = if (self.rtl()) b_id else a_id;
        for ([_]u32{ first, if (first == a_id) b_id else a_id }) |id| {
            const lbl = if (id == a_id) a_label else b_label;
            const v = if (id == a_id) a else b;
            try ui.addButton(id, try ui.print("{s}: {s}", .{ self.tr(lbl), self.onOff(v) }), .{ .w = .fill, .selected = v });
        }
        ui.endContainer();
    }

    /// One on and off button with the width of the panel.
    pub fn toggleButton(self: *Menu, id: u32, label: S, v: bool) !void {
        try self.ui.addButton(id, try self.ui.print("{s}: {s}", .{ self.tr(label), self.onOff(v) }), .{ .w = .fill, .selected = v });
    }

    pub fn percent(self: *Menu, v: f32) ![]const u8 {
        return self.ui.print("{d:.0}%", .{v * 100});
    }

    pub fn back(self: *Menu) !void {
        try self.ui.addButton(ids.back, self.tr(.back), wide(""));
    }

    /// The mouse rows: the sensitivity slider and the invert Y button.
    /// A `changed` event of `ids.sensitivity + 2` or an `activate` event
    /// of `ids.invert_y` follows a change.
    pub fn mouseRows(self: *Menu, sensitivity: *f32, invert_y: bool) !void {
        try self.sliderRow(ids.sensitivity, self.tr(.sensitivity), sensitivity, .{ .min = 0.1, .max = 3, .step = 0.1 }, try self.ui.print("{d:.1}x", .{sensitivity.*}), "");
        try self.toggleButton(ids.invert_y, .invert_y, invert_y);
    }

    /// One volume slider of `audioScreen`.
    pub const Volume = struct { base: u32, label: S, value: *f32 };

    /// The audio screen: one slider for each volume, then Back. A change
    /// gives a `changed` event of `base + 2`.
    pub fn audioScreen(self: *Menu, screen_id: u32, volumes: []const Volume) !void {
        try self.beginPanel(screen_id, self.tr(.sound));
        const vol: sw_ui.SliderOpts = .{ .min = 0, .max = 1, .step = 0.05 };
        for (volumes) |v| try self.sliderRow(v.base, self.tr(v.label), v.value, vol, try self.percent(v.value.*), "");
        try self.back();
        self.endPanel();
    }

    /// The name of a quality level.
    pub fn qualityName(self: *const Menu, level: Quality) []const u8 {
        return self.tr(switch (level) {
            .low => .low,
            .medium => .medium,
            .high => .high,
            .ultra => .ultra,
            .custom => .custom,
        });
    }

    // ---- Drawing ------------------------------------------------------------

    /// The colours of the menu: a clear scrim and a dark panel.
    pub fn palette() sw_ui.draw.Palette {
        var p: sw_ui.draw.Palette = .{};
        p.scrim = gfx.Color.rgba8(0, 0, 0, 0);
        p.panel = gfx.Color.rgba8(20, 22, 34, 215);
        return p;
    }

    /// Start the frame of the 2D renderer and draw the tree. `backdrop`
    /// fills the screen first. Draw more with `r2d` and `text()`, then call
    /// `drawEnd`.
    pub fn drawUi(self: *Menu, pass: *sw_render.Pass, pal: sw_ui.draw.Palette, backdrop: ?gfx.Color) !void {
        const k = @as(f32, @floatFromInt(pass.height)) / layout_height;
        self.r2d.beginFrame(pass.width, pass.height, k);
        const t = self.text();
        t.setDpiScale(k);
        if (backdrop) |c| try self.r2d.fillRect(.{ .x = 0, .y = 0, .w = @as(f32, @floatFromInt(pass.width)) / k, .h = layout_height }, c);
        try sw_ui.draw.draw(&self.ui, &self.r2d, t, pal);
    }

    pub fn drawEnd(self: *Menu, pass: *sw_render.Pass) !void {
        try self.r2d.flush(pass.render.?);
    }
};
