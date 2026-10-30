// menu - a full game menu over a live background: the turning cow
// (REQ-DEMO-009).
//
// The menu uses sw_ui: a main screen, a screen stack with Back, and the
// focus moves with the keyboard, the mouse and a gamepad. Each setting
// applies at once to the cow behind the menu:
//
// - Graphics: the preset, the anti-aliasing, the coat, the exposure, the
//   time of day and the turn speed, and the shadows, occlusion, fog, sky and
//   wireframe toggles.
// - Audio: one volume for each sound group (sw_audio). A change plays a
//   short sound of that group.
// - Controls: key rebinding (sw_core ActionMap and BindingCapture) with a
//   conflict warning, the mouse sensitivity and invert Y. The keys and a
//   mouse drag turn the camera round the cow.
// - Gamepad: the stick dead zone. The right stick turns the camera.
// - Interface: English or Hebrew (right to left), and a TrueType font or a
//   bitmap font.
// - Player: a text field, the on-screen keyboard, and a scroll list.
//
// The web build mirrors the UI for a screen reader (backends/wasm/a11y.ts).
//
//   zig build run -Ddemo=menu                      # window: the script plays
//                                                  # until you press a key
//   ./zig-out/bin/menu --check                     # compare the frame hashes
//   zig build web -Ddemo=menu && yarn dev:demo menu
const std = @import("std");
const demo = @import("demo_common");
const sw_render = @import("sw_render");
const sw_ui = @import("sw_ui");
const sw_text = @import("sw_text");
const gfx = @import("sw_gfx2d");
const core = @import("sw_core");
const audio = demo.audio;

const D = demo.Demo(App);
pub const std_options = demo.std_options;
pub const main = D.main;

comptime {
    D.exportWeb();
}

/// Noto Sans Hebrew, under the SIL Open Font License
/// (assets/NotoSansHebrew-OFL.txt).
const hebrew_ttf = @embedFile("assets/NotoSansHebrew-Regular.ttf");

/// The layout is this many units high at each surface size.
const layout_height: f32 = 540;
const panel_width: f32 = 370;

// ---- Text -------------------------------------------------------------------

const Language = enum { english, hebrew };
const FontKind = enum { truetype, bitmap };

const S = enum {
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
};

const english = std.enums.EnumArray(S, []const u8).init(.{
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
});

// Hebrew needs no letter joining. The bidi algorithm of sw_text puts each
// line in visual order.
const hebrew = std.enums.EnumArray(S, []const u8).init(.{
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
});

/// The Hebrew keys of the on-screen keyboard (the Israeli layout).
const hebrew_keys: sw_ui.osk.Layout = .{
    .rows = &.{ "1234567890", "/'קראטוןםפ", "שדגכעיחלךף", "זסבהנמצתץ." },
    .shifted = &.{ "1234567890", "/'קראטוןםפ", "שדגכעיחלךף", "זסבהנמצתץ." },
};

// ---- Settings ---------------------------------------------------------------

const Preset = enum { low, medium, high, custom };

/// The menu settings. A script `set <name> <value>` changes a field here,
/// or a field of `demo.CowSettings`.
const MenuSettings = struct {
    language: Language = .english,
    font: FontKind = .truetype,
    preset: Preset = .medium,
    master: f32 = 0.8,
    music: f32 = 0.5,
    effects: f32 = 0.8,
    interface: f32 = 0.6,
    sensitivity: f32 = 1.0,
    invert_y: bool = false,
    dead_zone: f32 = 0.15,
    menu: bool = true,
};

fn presetSettings(p: Preset, base: demo.CowSettings) demo.CowSettings {
    var s = base;
    switch (p) {
        .low => {
            s.aa = .off;
            s.shadows = false;
            s.ao = false;
            s.fog = false;
        },
        .medium => {
            s.aa = .fxaa;
            s.shadows = true;
            s.ao = true;
            s.fog = true;
        },
        .high => {
            s.aa = .msaa;
            s.shadows = true;
            s.ao = true;
            s.fog = true;
        },
        .custom => {},
    }
    return s;
}

// ---- Input actions ----------------------------------------------------------

const Binding = core.Binding;

/// The actions that the player can rebind.
const Act = enum { orbit_left, orbit_right, orbit_up, orbit_down, moo };
const act_names = [_]S{ .orbit_left, .orbit_right, .orbit_up, .orbit_down, .moo };

const act_defaults: core.ActionMap(Act).Defaults = .{
    .orbit_left = &.{Binding.key(.A)},
    .orbit_right = &.{Binding.key(.D)},
    .orbit_up = &.{Binding.key(.W)},
    .orbit_down = &.{Binding.key(.S)},
    .moo = &.{ Binding.key(.M), Binding.gamepadButton(.north) },
};

/// The gamepad navigation of the UI. The keyboard goes to the UI directly.
const Nav = enum { up, down, left, right, activate, back, next, prev };
const nav_defaults: core.ActionMap(Nav).Defaults = .{
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

const Screen = enum { settings, player, keyboard, graphics, sound, controls, gamepad, interface };

const ids = struct {
    const area: u32 = 1;
    const panel: u32 = 2;
    const spacer: u32 = 16;
    const title: u32 = 3;
    const player_line: u32 = 4;
    const hint: u32 = 5;
    const resume_game: u32 = 6;
    const settings: u32 = 7;
    const player: u32 = 8;
    const open_menu: u32 = 9;
    const back: u32 = 10;
    const graphics: u32 = 11;
    const sound: u32 = 12;
    const controls: u32 = 13;
    const gamepad: u32 = 14;
    const interface: u32 = 15;
    // Graphics.
    const preset: u32 = 20;
    const aa: u32 = 21;
    const coat: u32 = 22;
    const shadows: u32 = 23;
    const occlusion: u32 = 24;
    const fog: u32 = 25;
    const sky: u32 = 26;
    const wireframe: u32 = 27;
    const toggle_row_a: u32 = 28;
    const toggle_row_b: u32 = 29;
    // A slider row: row, label, slider, value (4 IDs from the base).
    const exposure: u32 = 40;
    const time: u32 = 44;
    const spin: u32 = 48;
    const master: u32 = 52;
    const music: u32 = 56;
    const effects: u32 = 60;
    const ui_sounds: u32 = 64;
    const sensitivity: u32 = 68;
    const dead_zone: u32 = 72;
    // Controls.
    const conflict: u32 = 80;
    const reset_keys: u32 = 81;
    const invert_y: u32 = 82;
    /// A binding row: row, label, button (3 IDs for each action).
    const bind_rows: u32 = 90;
    // Gamepad.
    const left_stick: u32 = 120;
    const right_stick: u32 = 121;
    const pad_hint: u32 = 122;
    // Interface.
    const language_label: u32 = 130;
    const language_list: u32 = 131;
    const font_label: u32 = 132;
    const font_list: u32 = 133;
    const language_item: u32 = 140;
    const font_item: u32 = 150;
    // Player.
    const name_field: u32 = 160;
    const keyboard_button: u32 = 161;
    const hours_list: u32 = 162;
    const keyboard_field: u32 = 163;
    const hour_item: u32 = 200;
    /// The screens are 300 to 307.
    /// The on-screen keyboard uses osk to osk + sw_ui.osk.id_span - 1.
    const osk: u32 = 1000;
};

// ---- State ------------------------------------------------------------------

var scene: demo.CowScene = undefined;
var ui: sw_ui.Ui = undefined;
var ttf: sw_text.TextRenderer = undefined;
var bitmap: sw_text.TextRenderer = undefined;
var r2d: gfx.Renderer = undefined;
var ms: MenuSettings = .{};
var cow: demo.CowSettings = .{};
var screens: sw_ui.ScreenStack(Screen, 6) = .{};
var name_storage: [64]u8 = undefined;
var name_value: sw_ui.TextValue = .{ .buffer = &name_storage };
var keyboard: sw_ui.osk.Keyboard = .{ .key_size = 30 };
var actions = core.ActionMap(Act).init(act_defaults);
var nav = core.ActionMap(Nav).init(nav_defaults);
var capture: core.BindingCapture = .{};
var capturing: ?Act = null;
var conflict_buf: [128]u8 = undefined;
var conflict_text: []const u8 = "";
var yaw: f32 = 0;
var pitch: f32 = 0;
var dragging = false;
var last_pointer: [2]f32 = .{ 0, 0 };
var layout_w: f32 = 960;
var layout_scale: f32 = 1;
var last_focus: u32 = 0;
var moo_flash: u32 = 0;

// Sound: one sample for each group. Capture and check runs play no sound.
const group_ui: u8 = 0;
const group_music: u8 = 1;
const group_effects: u8 = 2;
var sound: ?audio.Audio = null;
var click_sample: audio.Sample = undefined;
var moo_sample: audio.Sample = undefined;
var music_sample: audio.Sample = undefined;
var music_voice: ?audio.Voice = null;
var samples_made = false;
var last_sound_tick: [3]u64 = @splat(0);
var tick_count: u64 = 0;

fn tr(s: S) []const u8 {
    return switch (ms.language) {
        .english => english.get(s),
        .hebrew => hebrew.get(s),
    };
}

fn rtl() bool {
    return ms.language == .hebrew;
}

fn onOff(v: bool) []const u8 {
    return tr(if (v) .on else .off);
}

fn text() *sw_text.TextRenderer {
    return if (ms.font == .bitmap) &bitmap else &ttf;
}

// ---- The bitmap font --------------------------------------------------------

const bitmap_first: u21 = 32;
const bitmap_count = 95;
const bitmap_columns = 16;
const bitmap_rows = 6;

/// Make a bitmap font of the printable ASCII characters: Lato drawn small,
/// with each pixel on or off. The sheet is a grid of equal cells, as an
/// artist draws a pixel font. Hebrew and other characters come from the
/// next fonts of the chain.
fn makeBitmapFont(allocator: std.mem.Allocator) !sw_text.TextRenderer {
    var font = try sw_text.Font.init(allocator, demo.font_ttf);
    defer font.deinit();
    const size: f32 = 10;
    const scale = font.scale(size);
    const vm = font.vmetrics(size);
    const baseline: u32 = @intFromFloat(@ceil(vm.ascent));
    const cell_h: u32 = baseline + @as(u32, @intFromFloat(@ceil(-vm.descent)));
    const cell_w: u32 = 10;
    const sheet_w = cell_w * bitmap_columns;
    const sheet_h = cell_h * bitmap_rows;
    const pixels = try allocator.alloc(u8, sheet_w * sheet_h);
    defer allocator.free(pixels);
    @memset(pixels, 0);
    var codepoints: [bitmap_count]u21 = undefined;
    var widths: [bitmap_count]u8 = undefined;
    var glyph_buf: [64 * 64]u8 = undefined;
    for (0..bitmap_count) |i| {
        const cp: u21 = bitmap_first + @as(u21, @intCast(i));
        codepoints[i] = cp;
        const g = font.glyphIndex(cp);
        widths[i] = @intCast(std.math.clamp(@as(i32, @intFromFloat(@round(font.advance(g, size)))), 1, cell_w));
        const box = font.bitmapBox(g, scale);
        const w = box.width();
        const h = box.height();
        if (w == 0 or h == 0 or w * h > glyph_buf.len) continue;
        font.render(g, scale, box, glyph_buf[0 .. w * h]);
        const cx = (i % bitmap_columns) * cell_w;
        const cy = (i / bitmap_columns) * cell_h;
        for (0..h) |y| {
            const ty = @as(i32, @intCast(baseline)) + box.y0 + @as(i32, @intCast(y));
            if (ty < 0 or ty >= cell_h) continue;
            for (0..w) |x| {
                const tx = box.x0 + @as(i32, @intCast(x));
                if (tx < 0 or tx >= cell_w) continue;
                const on = glyph_buf[y * w + x] >= 64;
                pixels[(cy + @as(usize, @intCast(ty))) * sheet_w + cx + @as(usize, @intCast(tx))] = if (on) 255 else 0;
            }
        }
    }
    var t = try sw_text.TextRenderer.initBitmap(allocator, .{
        .sheet = .{ .pixels = pixels, .width = sheet_w, .height = sheet_h, .format = .alpha8 },
        .cell_width = cell_w,
        .cell_height = cell_h,
        .codepoints = &codepoints,
        .widths = &widths,
        .baseline = baseline,
    });
    errdefer t.deinit();
    try t.addFont(hebrew_ttf);
    try t.addFont(demo.font_ttf);
    return t;
}

// ---- Sound ------------------------------------------------------------------

const sample_rate = 48000;

fn makeSample(allocator: std.mem.Allocator, seconds: f32, comptime f: fn (t: f32, len: f32) f32) !audio.Sample {
    const n: usize = @intFromFloat(seconds * sample_rate);
    const data = try allocator.alloc(f32, n);
    for (data, 0..) |*v, i| v.* = f(@as(f32, @floatFromInt(i)) / sample_rate, seconds);
    return .{ .data = data, .channels = 1, .rate = sample_rate };
}

/// A short click for a focus move.
fn clickWave(t: f32, _: f32) f32 {
    return 0.4 * @sin(std.math.tau * 1400 * t) * @exp(-t * 90);
}

/// A low falling tone with a slow vibrato, for the effects group.
fn mooWave(t: f32, len: f32) f32 {
    const f = 150 - 40 * t / len + 4 * @sin(std.math.tau * 5 * t);
    const phase = @mod(f * t, 1.0);
    const saw = 2 * phase - 1;
    const env = @min(t / 0.08, 1) * @min((len - t) / 0.2, 1);
    return 0.35 * saw * env;
}

/// A soft arpeggio in A minor that loops, for the music group.
fn musicWave(t: f32, _: f32) f32 {
    const notes = [_]f32{ 220.0, 261.63, 329.63, 440.0, 329.63, 261.63, 196.0, 246.94 };
    const note_len: f32 = 0.25;
    const i: usize = @intFromFloat(@floor(t / note_len));
    const local = t - @as(f32, @floatFromInt(i)) * note_len;
    const f = notes[i % notes.len];
    const env = @min(local / 0.01, 1) * @exp(-local * 6);
    return 0.18 * env * (@sin(std.math.tau * f * t) + 0.3 * @sin(std.math.tau * 2 * f * t));
}

fn startSound(allocator: std.mem.Allocator) !void {
    click_sample = try makeSample(allocator, 0.06, clickWave);
    moo_sample = try makeSample(allocator, 0.7, mooWave);
    music_sample = try makeSample(allocator, 2.0, musicWave);
    samples_made = true;
    var a = audio.Audio.init();
    if (!a.isReady()) return;
    sound = a;
    applyVolumes();
    music_voice = a.playSample(&music_sample, .{ .group = group_music, .looping = true });
}

fn applyVolumes() void {
    const a = if (sound) |*p| p else return;
    a.setMasterVolume(ms.master);
    a.setGroupVolume(group_ui, ms.interface);
    a.setGroupVolume(group_music, ms.music);
    a.setGroupVolume(group_effects, ms.effects);
}

/// Play the sound of a group, at most one time each 8 ticks.
fn play(group: u8, pitch_scale: f32) void {
    const a = if (sound) |*p| p else return;
    if (tick_count < last_sound_tick[group] + 8 and last_sound_tick[group] != 0) return;
    last_sound_tick[group] = tick_count;
    const sample = switch (group) {
        group_effects => &moo_sample,
        group_music => &click_sample,
        else => &click_sample,
    };
    _ = a.playSample(sample, .{ .group = group, .pitch = pitch_scale });
}

// ---- Input ------------------------------------------------------------------

/// True when the ID is a list item: the arrow keys move inside its list.
fn listRange(id: u32) ?struct { first: u32, last: u32 } {
    if (id >= ids.language_item and id < ids.language_item + 2) return .{ .first = ids.language_item, .last = ids.language_item + 1 };
    if (id >= ids.font_item and id < ids.font_item + 2) return .{ .first = ids.font_item, .last = ids.font_item + 1 };
    if (id >= ids.hour_item and id < ids.hour_item + 24) return .{ .first = ids.hour_item, .last = ids.hour_item + 23 };
    return null;
}

/// The input of the UI. Up and Down move the focus to the previous and next
/// control (as Shift+Tab and Tab), so a gamepad D-pad goes through each
/// control. In a list, they move inside the list, then out at its ends.
/// The on-screen keyboard keeps the arrow keys.
fn uiInput(snap: *const core.InputSnapshot, from_player: bool) sw_ui.Input {
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
    const focus = ui.focused() orelse 0;
    const in_osk = focus >= ids.osk and focus < ids.osk + sw_ui.osk.id_span;
    if (!in_osk and (keys.up or keys.down)) {
        var to_tab = true;
        if (listRange(focus)) |range| {
            to_tab = (keys.up and focus == range.first) or (keys.down and focus == range.last);
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
    const k: f32 = if (from_player) layout_scale else 1;
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

/// The label of a binding: "W", "Shift+J", "Pad north".
fn bindingLabel(b: Binding, buf: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    if (b.mods.ctrl) w.writeAll("Ctrl+") catch {};
    if (b.mods.alt) w.writeAll("Alt+") catch {};
    if (b.mods.shift) w.writeAll("Shift+") catch {};
    if (b.mods.super) w.writeAll("Cmd+") catch {};
    switch (b.source) {
        .none => w.writeAll("-") catch {},
        .key => |k| w.writeAll(@tagName(k)) catch {},
        .mouse => |m| w.print("Mouse {s}", .{@tagName(m)}) catch {},
        .gamepad_button => |p| w.print("Pad {s}", .{@tagName(p)}) catch {},
        .gamepad_axis => |d| w.print("Pad {s}{s}", .{ @tagName(d.axis), if (d.positive) "+" else "-" }) catch {},
    }
    return w.buffered();
}

/// Wait for the new binding of `capturing`. Escape (or the east gamepad
/// button) cancels. A binding that another action has gives a warning.
fn updateCapture(snap: *const core.InputSnapshot) void {
    const a = capturing orelse return;
    if (snap.keyPressed(.Escape) or (snap.gamepads[0].buttonPressed(.east))) {
        capturing = null;
        return;
    }
    const b = capture.update(snap) orelse return;
    capturing = null;
    actions.bind(a, 0, b);
    var label_buf: [32]u8 = undefined;
    if (actions.findAction(b, a)) |other| {
        conflict_text = std.fmt.bufPrint(&conflict_buf, "{s}: {s} {s} {s}", .{ tr(act_names[@backingInt(a)]), bindingLabel(b, &label_buf), tr(.conflict), tr(act_names[@backingInt(other)]) }) catch "";
        play(group_effects, 0.7);
    } else {
        conflict_text = "";
    }
    std.log.info("menu: {s} = {s}", .{ @tagName(a), bindingLabel(b, &label_buf) });
}

// ---- Building the UI --------------------------------------------------------

/// Open the panel of a screen: on the right, or on the left in Hebrew.
fn beginPanel(screen_id: ?u32, title: []const u8) !void {
    const area: sw_ui.Opts = .{
        .w = .fill,
        .h = .fill,
        .padding = 16,
        .cross_align = if (rtl()) .start else .end,
        .label = title,
    };
    if (screen_id) |id| try ui.beginScreen(id, title, area) else try ui.beginColumn(ids.area, area);
    // Right to left, the panel is on the left: it starts under the stats.
    if (rtl()) {
        try ui.beginColumn(ids.spacer, .{ .h = .{ .fixed = 64 } });
        ui.endContainer();
    }
    try ui.beginColumn(ids.panel, .{
        .w = .{ .fixed = panel_width },
        .padding = 12,
        .gap = 5,
        .panel = true,
        .cross_align = if (rtl()) .end else .start,
        .label = title,
    });
    try ui.addText(ids.title, title, .{});
}

fn endPanel() void {
    ui.endContainer();
    ui.endContainer();
}

fn wide(tip: []const u8) sw_ui.Opts {
    return .{ .w = .fill, .tooltip = tip };
}

/// A row: a label, a slider and its value as text. Right to left, the
/// label is on the right.
fn sliderRow(base: u32, label: []const u8, value: *f32, opts: sw_ui.SliderOpts, value_text: []const u8, tip: []const u8) !void {
    try ui.beginRow(base, .{ .w = .fill, .gap = 8, .cross_align = .center });
    var o = opts;
    o.text = value_text;
    const parts = [_]u8{ 0, 1, 2 };
    for (parts) |p0| {
        const p = if (rtl()) 2 - p0 else p0;
        switch (p) {
            0 => try ui.addText(base + 1, label, .{ .w = .{ .fixed = 120 } }),
            1 => try ui.addSlider(base + 2, label, value, o, .{ .w = .fill, .tooltip = tip }),
            else => try ui.addText(base + 3, value_text, .{ .w = .{ .fixed = 48 } }),
        }
    }
    ui.endContainer();
}

fn toggleRow(row_id: u32, a_id: u32, a_label: S, a: bool, b_id: u32, b_label: S, b: bool) !void {
    try ui.beginRow(row_id, .{ .w = .fill, .gap = 6 });
    const first = if (rtl()) b_id else a_id;
    for ([_]u32{ first, if (first == a_id) b_id else a_id }) |id| {
        const lbl = if (id == a_id) a_label else b_label;
        const v = if (id == a_id) a else b;
        try ui.addButton(id, try ui.print("{s}: {s}", .{ tr(lbl), onOff(v) }), .{ .w = .fill, .selected = v });
    }
    ui.endContainer();
}

fn buildMain() !void {
    try beginPanel(null, tr(.title));
    const name = if (name_value.slice().len > 0) name_value.slice() else tr(.no_name);
    try ui.addText(ids.player_line, try ui.print("{s}: {s}", .{ tr(.player_line), name }), .{ .live = true });
    try ui.addButton(ids.resume_game, tr(.resume_game), wide(tr(.resume_tip)));
    try ui.addButton(ids.player, tr(.player), wide(tr(.player_tip)));
    try ui.addButton(ids.settings, tr(.settings), wide(tr(.settings_tip)));
    try ui.addText(ids.hint, tr(.hint), .{});
    endPanel();
}

fn buildSettings() !void {
    try beginPanel(300, tr(.settings));
    try ui.addButton(ids.graphics, tr(.graphics), wide(tr(.graphics_tip)));
    try ui.addButton(ids.sound, tr(.sound), wide(tr(.sound_tip)));
    try ui.addButton(ids.controls, tr(.controls), wide(tr(.controls_tip)));
    try ui.addButton(ids.gamepad, tr(.gamepad), wide(tr(.gamepad_tip)));
    try ui.addButton(ids.interface, tr(.interface), wide(tr(.interface_tip)));
    try ui.addButton(ids.back, tr(.back), wide(""));
    endPanel();
}

fn presetName(p: Preset) []const u8 {
    return tr(switch (p) {
        .low => .low,
        .medium => .medium,
        .high => .high,
        .custom => .custom,
    });
}

fn buildGraphics() !void {
    try beginPanel(301, tr(.graphics));
    try ui.addButton(ids.preset, try ui.print("{s}: {s}", .{ tr(.preset), presetName(ms.preset) }), wide(tr(.preset_tip)));
    const aa_name = switch (cow.aa) {
        .off => tr(.off),
        .fxaa => "FXAA",
        .msaa => "MSAA 4x",
    };
    try ui.addButton(ids.aa, try ui.print("{s}: {s}", .{ tr(.anti_aliasing), aa_name }), wide(tr(.preset_tip)));
    try ui.addButton(ids.coat, try ui.print("{s}: {s}", .{ tr(.coat), @tagName(cow.palette) }), wide(tr(.preset_tip)));
    try sliderRow(ids.exposure, tr(.exposure), &cow.exposure, .{ .min = 0.2, .max = 2.5, .step = 0.1 }, try ui.print("{d:.1}", .{cow.exposure}), "");
    try sliderRow(ids.time, tr(.time_of_day), &cow.time, .{ .min = 0, .max = 1, .step = 0.02 }, try ui.print("{d:0>2}:{d:0>2}", .{ hourOf(cow.time), minuteOf(cow.time) }), "");
    try sliderRow(ids.spin, tr(.spin), &cow.spin, .{ .min = 0, .max = 2, .step = 0.1 }, try ui.print("{d:.1}", .{cow.spin}), "");
    try toggleRow(ids.toggle_row_a, ids.shadows, .shadows, cow.shadows, ids.occlusion, .occlusion, cow.ao);
    try toggleRow(ids.toggle_row_b, ids.fog, .fog, cow.fog, ids.sky, .sky, cow.sky);
    try ui.addButton(ids.wireframe, try ui.print("{s}: {s}", .{ tr(.wireframe), onOff(cow.wireframe) }), .{ .w = .fill, .selected = cow.wireframe });
    try ui.addButton(ids.back, tr(.back), wide(""));
    endPanel();
}

fn hourOf(t: f32) u32 {
    const minutes: u32 = @intFromFloat(@round(t * 24 * 60));
    return (minutes / 60) % 24;
}

fn minuteOf(t: f32) u32 {
    const minutes: u32 = @intFromFloat(@round(t * 24 * 60));
    return minutes % 60;
}

fn percent(v: f32) ![]const u8 {
    return ui.print("{d:.0}%", .{v * 100});
}

fn buildSound() !void {
    try beginPanel(302, tr(.sound));
    const vol: sw_ui.SliderOpts = .{ .min = 0, .max = 1, .step = 0.05 };
    try sliderRow(ids.master, tr(.master), &ms.master, vol, try percent(ms.master), "");
    try sliderRow(ids.music, tr(.music), &ms.music, vol, try percent(ms.music), "");
    try sliderRow(ids.effects, tr(.effects), &ms.effects, vol, try percent(ms.effects), "");
    try sliderRow(ids.ui_sounds, tr(.ui_sounds), &ms.interface, vol, try percent(ms.interface), "");
    try ui.addButton(ids.back, tr(.back), wide(""));
    endPanel();
}

fn buildControls() !void {
    try beginPanel(303, tr(.controls));
    for (act_names, 0..) |label, i| {
        const a: Act = @fromBackingInt(@intCast(i));
        const base = ids.bind_rows + @as(u32, @intCast(i)) * 3;
        try ui.beginRow(base, .{ .w = .fill, .gap = 8, .cross_align = .center });
        var buf: [32]u8 = undefined;
        const value = if (capturing == a) tr(.press_key) else try ui.print("{s}", .{bindingLabel(actions.bindings(a)[0], &buf)});
        for (0..2) |p0| {
            const p = if (rtl()) 1 - p0 else p0;
            if (p == 0) {
                try ui.addText(base + 1, tr(label), .{ .w = .{ .fixed = 120 } });
            } else {
                try ui.addButton(base + 2, value, .{ .w = .fill, .selected = capturing == a, .tooltip = "Enter, then a key" });
            }
        }
        ui.endContainer();
    }
    try ui.addText(ids.conflict, if (conflict_text.len > 0) conflict_text else tr(.no_conflict), .{ .live = true });
    try sliderRow(ids.sensitivity, tr(.sensitivity), &ms.sensitivity, .{ .min = 0.1, .max = 3, .step = 0.1 }, try ui.print("{d:.1}x", .{ms.sensitivity}), "");
    try ui.addButton(ids.invert_y, try ui.print("{s}: {s}", .{ tr(.invert_y), onOff(ms.invert_y) }), .{ .w = .fill, .selected = ms.invert_y });
    try ui.addButton(ids.reset_keys, tr(.reset_keys), wide(""));
    try ui.addButton(ids.back, tr(.back), wide(""));
    endPanel();
}

fn buildGamepad(snap: *const core.InputSnapshot) !void {
    try beginPanel(304, tr(.gamepad));
    try sliderRow(ids.dead_zone, tr(.dead_zone), &ms.dead_zone, .{ .min = 0, .max = 0.9, .step = 0.05 }, try ui.print("{d:.2}", .{ms.dead_zone}), tr(.dead_zone_tip));
    const g = &snap.gamepads[0];
    if (g.connected) {
        const l = g.stick(.left, nav.gamepad);
        const r = g.stick(.right, nav.gamepad);
        try ui.addText(ids.left_stick, try ui.print("{s}: {d:.2} {d:.2} > {d:.2} {d:.2}", .{ tr(.left_stick), g.rawAxis(.left_x), g.rawAxis(.left_y), l.x, l.y }), .{});
        try ui.addText(ids.right_stick, try ui.print("{s}: {d:.2} {d:.2} > {d:.2} {d:.2}", .{ tr(.right_stick), g.rawAxis(.right_x), g.rawAxis(.right_y), r.x, r.y }), .{});
    } else {
        try ui.addText(ids.left_stick, tr(.no_pad), .{});
    }
    try ui.addText(ids.pad_hint, tr(.pad_hint), .{});
    try ui.addButton(ids.back, tr(.back), wide(""));
    endPanel();
}

fn buildInterface() !void {
    try beginPanel(305, tr(.interface));
    try ui.addText(ids.language_label, tr(.language), .{});
    try ui.beginList(ids.language_list, tr(.language), .{ .w = .fill });
    try ui.addListItem(ids.language_item, "English", .{ .w = .fill, .selected = ms.language == .english });
    try ui.addListItem(ids.language_item + 1, "עברית", .{ .w = .fill, .selected = ms.language == .hebrew });
    ui.endContainer();
    try ui.addText(ids.font_label, tr(.font), .{});
    try ui.beginList(ids.font_list, tr(.font), .{ .w = .fill });
    try ui.addListItem(ids.font_item, tr(.font_truetype), .{ .w = .fill, .selected = ms.font == .truetype });
    try ui.addListItem(ids.font_item + 1, tr(.font_bitmap), .{ .w = .fill, .selected = ms.font == .bitmap });
    ui.endContainer();
    try ui.addButton(ids.back, tr(.back), wide(""));
    endPanel();
}

fn buildPlayer() !void {
    try beginPanel(306, tr(.player));
    try ui.addTextField(ids.name_field, tr(.name), &name_value, .{ .w = .fill });
    try ui.addButton(ids.keyboard_button, tr(.keyboard), wide(tr(.keyboard_tip)));
    try ui.beginScrollList(ids.hours_list, tr(.hours), .{ .w = .fill, .h = .{ .fixed = 170 }, .tooltip = tr(.hours_tip) });
    const current = hourOf(cow.time);
    for (0..24) |h| {
        try ui.addListItem(ids.hour_item + @as(u32, @intCast(h)), try ui.print("{d:0>2}:00", .{h}), .{ .w = .fill, .selected = h == current });
    }
    ui.endContainer();
    try ui.addButton(ids.back, tr(.back), wide(""));
    endPanel();
}

fn buildKeyboard() !void {
    try beginPanel(307, tr(.keyboard));
    try ui.addTextField(ids.keyboard_field, tr(.name), &name_value, .{ .w = .fill });
    keyboard.letters_layout = if (rtl()) hebrew_keys else sw_ui.osk.letters;
    try keyboard.build(&ui, ids.osk, .{ .label = tr(.keyboard) });
    endPanel();
}

fn buildUi(input: sw_ui.Input, snap: *const core.InputSnapshot) !void {
    try ui.begin(input, layout_w, layout_height);
    if (screens.top()) |top| switch (top) {
        .settings => try buildSettings(),
        .player => try buildPlayer(),
        .keyboard => try buildKeyboard(),
        .graphics => try buildGraphics(),
        .sound => try buildSound(),
        .controls => try buildControls(),
        .gamepad => try buildGamepad(snap),
        .interface => try buildInterface(),
    } else if (ms.menu) {
        try buildMain();
    } else {
        try ui.beginColumn(ids.area, .{ .w = .fill, .padding = 16, .cross_align = if (rtl()) .start else .end });
        if (rtl()) {
            try ui.beginColumn(ids.spacer, .{ .h = .{ .fixed = 64 } });
            ui.endContainer();
        }
        try ui.addButton(ids.open_menu, tr(.open_menu), .{ .tooltip = tr(.open_menu_tip) });
        ui.endContainer();
    }
    try ui.finish();
}

// ---- Events -----------------------------------------------------------------

fn openScreen(s: Screen) void {
    screens.push(&ui, s) catch {};
    play(group_ui, 1.5);
}

fn setMenu(open: bool) void {
    ms.menu = open;
    ui.setFocus(if (open) ids.resume_game else ids.open_menu);
}

fn cycle(comptime E: type, v: E, forward: bool) E {
    const n = std.enums.values(E).len;
    const i = @backingInt(v);
    return @fromBackingInt(@intCast(if (forward) (i + 1) % n else (i + n - 1) % n));
}

/// Change the value of a cycle or toggle button. True when the ID is one.
fn step(id: u32, forward: bool) !bool {
    switch (id) {
        ids.preset => {
            ms.preset = switch (ms.preset) {
                .low => if (forward) .medium else .high,
                .medium => if (forward) .high else .low,
                .high, .custom => if (forward) .low else .medium,
            };
            cow = presetSettings(ms.preset, cow);
        },
        ids.aa => {
            cow.aa = cycle(demo.cow_scene.AntiAliasing, cow.aa, forward);
            ms.preset = .custom;
        },
        ids.coat => cow.palette = cycle(demo.cow_model.PaletteId, cow.palette, forward),
        ids.shadows => {
            cow.shadows = !cow.shadows;
            ms.preset = .custom;
        },
        ids.occlusion => {
            cow.ao = !cow.ao;
            ms.preset = .custom;
        },
        ids.fog => {
            cow.fog = !cow.fog;
            ms.preset = .custom;
        },
        ids.sky => cow.sky = !cow.sky,
        ids.wireframe => cow.wireframe = !cow.wireframe,
        ids.invert_y => ms.invert_y = !ms.invert_y,
        else => return false,
    }
    try applyAll();
    play(group_ui, 1.2);
    return true;
}

fn handleEvents(input: sw_ui.Input) !void {
    if (screens.top() == .keyboard) {
        const r = keyboard.apply(&ui, ids.osk, &name_value);
        if (r.changed) {
            std.log.info("menu: name = \"{s}\"", .{name_value.slice()});
            play(group_ui, 1.0);
        }
        if (r.done) _ = screens.pop(&ui);
    }
    // Left and Right change a cycle or toggle button.
    if (input.keys.left or input.keys.right) {
        if (ui.focused()) |f| {
            if (f != ids.back) _ = try step(f, input.keys.right);
        }
    }
    for (ui.frameEvents()) |e| switch (e.kind) {
        .activate => try activate(e.id),
        .cancel => {
            if (screens.pop(&ui) != null) {
                play(group_ui, 0.8);
            } else if (ui.focused() == ids.name_field) {
                ui.clearFocus();
            } else {
                setMenu(!ms.menu);
            }
        },
        .changed => try changed(e.id),
        .submit => {},
    };
}

fn activate(id: u32) !void {
    if (try step(id, true)) return;
    if (id >= ids.language_item and id < ids.language_item + 2) {
        ms.language = @fromBackingInt(@intCast(id - ids.language_item));
        play(group_ui, 1.2);
        return;
    }
    if (id >= ids.font_item and id < ids.font_item + 2) {
        ms.font = @fromBackingInt(@intCast(id - ids.font_item));
        try applyAll();
        return;
    }
    if (id >= ids.hour_item and id < ids.hour_item + 24) {
        cow.time = @as(f32, @floatFromInt(id - ids.hour_item)) / 24.0;
        try applyAll();
        return;
    }
    if (id >= ids.bind_rows and id < ids.bind_rows + act_names.len * 3) {
        if ((id - ids.bind_rows) % 3 == 2) {
            capturing = @fromBackingInt(@intCast((id - ids.bind_rows) / 3));
            capture.reset();
        }
        return;
    }
    switch (id) {
        ids.resume_game => setMenu(false),
        ids.open_menu => setMenu(true),
        ids.settings => openScreen(.settings),
        ids.player => openScreen(.player),
        ids.keyboard_button => openScreen(.keyboard),
        ids.graphics => openScreen(.graphics),
        ids.sound => openScreen(.sound),
        ids.controls => openScreen(.controls),
        ids.gamepad => openScreen(.gamepad),
        ids.interface => openScreen(.interface),
        ids.reset_keys => {
            actions.resetAll();
            conflict_text = "";
        },
        ids.back => {
            _ = screens.pop(&ui);
            play(group_ui, 0.8);
        },
        else => {},
    }
}

fn changed(id: u32) !void {
    switch (id) {
        ids.exposure + 2, ids.time + 2, ids.spin + 2 => try applyAll(),
        ids.master + 2 => {
            applyVolumes();
            play(group_music, 1.0);
        },
        ids.music + 2 => applyVolumes(),
        ids.effects + 2 => {
            applyVolumes();
            play(group_effects, 1.0);
        },
        ids.ui_sounds + 2 => {
            applyVolumes();
            play(group_ui, 1.0);
        },
        ids.sensitivity + 2, ids.dead_zone + 2 => try applyAll(),
        else => {},
    }
}

/// Apply the settings to the scene, the input maps, the sound and the font.
fn applyAll() !void {
    try scene.apply(cow);
    actions.mouse.setSensitivity(ms.sensitivity);
    actions.mouse.invert_y = ms.invert_y;
    nav.gamepad.setStickDeadZone(ms.dead_zone);
    actions.gamepad = nav.gamepad;
    capture.gamepad = nav.gamepad;
    applyVolumes();
    ui.measurer = sw_ui.draw.measurer(text());
}

// ---- The camera -------------------------------------------------------------

/// Turn the camera: the rebindable keys, the right stick, and a mouse drag
/// outside the panel. The scene gets the new orbit at once.
fn updateCamera(host: *demo.Host, input: sw_ui.Input, snap: *const core.InputSnapshot) void {
    const dt = host.dt;
    const typing = ui.wantsTextInput() or capturing != null;
    if (!typing) {
        yaw += actions.axis(.orbit_left, .orbit_right) * 1.5 * dt;
        pitch += actions.axis(.orbit_down, .orbit_up) * 1.0 * dt;
        if (actions.pressed(.moo)) {
            play(group_effects, 1.0);
            moo_flash = 40;
        }
    }
    const r = snap.gamepads[0].stick(.right, nav.gamepad);
    yaw += r.x * 1.5 * dt;
    pitch -= r.y * 1.0 * dt;

    const over_ui = blk: {
        const b = ui.bounds(if (ms.menu or screens.top() != null) ids.panel else ids.open_menu) orelse break :blk false;
        break :blk b.contains(input.pointer_x, input.pointer_y);
    };
    if (input.pointer_pressed) {
        dragging = !over_ui;
        last_pointer = .{ input.pointer_x, input.pointer_y };
    }
    if (!input.pointer_down) dragging = false;
    if (dragging) {
        const look = actions.mouse.apply(input.pointer_x - last_pointer[0], input.pointer_y - last_pointer[1]);
        yaw -= look.dx * 0.01;
        pitch += look.dy * 0.01;
        last_pointer = .{ input.pointer_x, input.pointer_y };
    }
    yaw = @mod(yaw + std.math.pi, std.math.tau) - std.math.pi;
    pitch = std.math.clamp(pitch, -0.5, 1.0);
    scene.setOrbit(yaw, pitch);
}

// ---- The demo ---------------------------------------------------------------

fn drawMenu(pass: *sw_render.Pass) !void {
    const k = @as(f32, @floatFromInt(pass.height)) / layout_height;
    r2d.beginFrame(pass.width, pass.height, k);
    const t = text();
    t.setDpiScale(k);
    var palette: sw_ui.draw.Palette = .{};
    palette.scrim = gfx.Color.rgba8(0, 0, 0, 0);
    palette.panel = gfx.Color.rgba8(20, 22, 34, 215);
    try sw_ui.draw.draw(&ui, &r2d, t, palette);
    if (moo_flash > 0) {
        const lw = @as(f32, @floatFromInt(pass.width)) / k;
        _ = try t.draw(&r2d, "Moo!", if (rtl()) lw - 120 else 40, 200, .{ .size = 40, .color = gfx.Color.rgba8(255, 240, 200, 255) });
    }
    try r2d.flush(pass.render.?);
}

fn resetState() !void {
    ms = .{};
    cow = presetSettings(.medium, .{});
    screens = .{};
    name_value.clear();
    keyboard = .{ .key_size = 30 };
    actions.resetAll();
    capturing = null;
    conflict_text = "";
    yaw = 0;
    pitch = 0;
    dragging = false;
    moo_flash = 0;
    scene.setAngle(0);
    scene.setOrbit(0, 0);
    ui.setFocus(ids.resume_game);
    try applyAll();
}

const App = struct {
    pub const name = "menu";
    pub const script = @embedFile("menu.tas");
    pub const interactive = true;

    pub fn init(host: *demo.Host) !void {
        const g = host.graphics;
        scene = try demo.CowScene.init(host.allocator, &host.graph, &host.post, .{
            .fxaa_quality = g.fxaa_quality,
            .shadow_map_size = g.shadow_map_size,
            .shadow_cascades = @max(g.shadow_cascades, 1),
        });
        ttf = try sw_text.TextRenderer.init(host.allocator, demo.font_ttf);
        try ttf.addFont(hebrew_ttf);
        bitmap = try makeBitmapFont(host.allocator);
        r2d = try gfx.Renderer.init(host.allocator, host.gpu, .{});
        ui = sw_ui.Ui.init(host.allocator, sw_ui.draw.measurer(&ttf), .{ .text_size = 15, .control_pad = 6, .field_width = 200 });
        if (!host.deterministic()) {
            ui.clipboard = sw_ui.Clipboard.platform(host.ctx);
            startSound(host.allocator) catch |err| std.log.warn("menu: no sound: {s}", .{@errorName(err)});
        }
        try host.graph.addPass(.{
            .name = "menu_ui",
            .order = 1500,
            .attachments = .{ .colors = &.{.{ .target = .screen, .load_op = .load }} },
            .callback = .plain(drawMenu),
        });
        try resetState();
    }

    pub fn reset(_: *demo.Host) !void {
        try resetState();
    }

    pub fn set(_: *demo.Host, setting: []const u8, value: []const u8) !void {
        demo.reflect.setField(MenuSettings, &ms, setting, value) catch |err| switch (err) {
            error.UnknownSetting => try demo.reflect.setField(demo.CowSettings, &cow, setting, value),
            else => return err,
        };
        if (std.mem.eql(u8, setting, "preset")) cow = presetSettings(ms.preset, cow);
        try applyAll();
    }

    pub fn tick(host: *demo.Host) !void {
        tick_count += 1;
        const snap = host.input();
        const win = host.ctx.window();
        const sw_h: f32 = @floatFromInt(@max(host.gpu.getSurfaceHeight(), 1));
        const sw_w: f32 = @floatFromInt(@max(host.gpu.getSurfaceWidth(), 1));
        layout_w = sw_w * layout_height / sw_h;
        // Window units to layout units, for the pointer of the player.
        const logical_h = @as(f32, @floatFromInt(@max(win.height, 1))) / @max(win.dpi_scale, 0.01);
        layout_scale = layout_height / logical_h;

        nav.update(snap);
        var input: sw_ui.Input = undefined;
        if (capturing != null) {
            updateCapture(snap);
            // The UI gets no keys while it waits for a binding.
            input = .{ .pointer_x = snap.mouse.x, .pointer_y = snap.mouse.y };
        } else {
            actions.update(snap);
            input = uiInput(snap, host.user_control);
        }
        try buildUi(input, snap);
        try handleEvents(input);
        if (ui.focused()) |f| {
            if (f != last_focus) play(group_ui, 1.0);
            last_focus = f;
        }
        if (host.user_control) {
            const wanted = ui.wantsTextInput();
            if (wanted and !host.ctx.isTextInputActive()) host.ctx.startTextInput();
            if (!wanted and host.ctx.isTextInputActive()) host.ctx.stopTextInput();
        }
        updateCamera(host, input, snap);
        if (moo_flash > 0) moo_flash -= 1;
        scene.tick(host.dt);
    }

    pub fn frame(_: *demo.Host, w: u32, h: u32) !sw_render.FrameUniforms {
        return scene.frame(w, h);
    }

    pub fn statLines(host: *demo.Host, bufs: [][128]u8, out: [][]const u8) usize {
        var n: usize = 0;
        if (!host.deterministic() and !host.user_control) {
            out[n] = "script plays: press a key or click to take control";
            n += 1;
        }
        out[n] = std.fmt.bufPrint(&bufs[n], "camera yaw {d:.2} pitch {d:.2}", .{ yaw, pitch }) catch "";
        n += 1;
        return n;
    }

    pub fn deinit(host: *demo.Host) void {
        if (sound) |*a| a.stopAll();
        if (samples_made) {
            for ([_]*audio.Sample{ &click_sample, &moo_sample, &music_sample }) |sm| host.allocator.free(sm.data);
            samples_made = false;
        }
        ui.deinit();
        r2d.deinit();
        bitmap.deinit();
        ttf.deinit();
        scene.deinit();
    }
};
