// menu - a full game menu over a live background: the turning cow. Each
// setting applies at once to the background.
//
// - The main screen: Play, Settings, Language, a player name (a text field
//   and the on-screen keyboard), a scroll list of times of day, and Quit.
// - A screen stack with Back. The keyboard (Tab, the arrows, Enter,
//   Escape), the mouse and a gamepad (the d-pad, south, east, the
//   shoulders) move the focus.
// - Graphics: the preset, the anti-aliasing, toggles and sliders.
// - Audio: a volume for each group (master, effects, ambience).
// - Controls: key rebinding with a conflict warning, the mouse sensitivity,
//   invert Y.
// - Gamepad: the stick dead zone, with the stick value after the dead
//   zone.
// - Language: English or Hebrew (right to left), and a TTF or a bitmap
//   font. A tooltip explains each control.
//
// On the web, sw_ui sends its semantic tree to the screen-reader mirror,
// so a screen reader reads each widget (REQ-A11Y-001).
//
// Play hides the menu. Then the keys of the Controls screen turn the cow,
// a drag of the left mouse button (or the right stick) moves the camera,
// and Escape shows the menu again.
//
// The demo plays `menu.tas` once, which uses each part of the menu. Escape
// on the first screen stops the script. `--check` plays it with no window
// and checks each setting (REQ-DEMO-001).
const std = @import("std");
const builtin = @import("builtin");
const sw = @import("sw_app");
const gfx = @import("sw_gfx2d");
const sw_text = @import("sw_text");
const sw_ui = @import("sw_ui");
const sw_audio = @import("sw_audio");
const demo = @import("demo_common");

const run = demo.run;
const cow_scene = demo.cow_scene;
const sound = demo.sound;
const Binding = sw.core_types.Binding;

pub const std_options: std.Options = .{
    .logFn = if (builtin.cpu.arch.isWasm()) sw.webLogFn else std.log.defaultLog,
};

pub const main = if (builtin.cpu.arch.isWasm()) mainWasm else mainNative;

fn mainWasm() void {}

comptime {
    if (builtin.cpu.arch.isWasm()) sw.exportWeb(config, Callbacks);
}

const tick_hz = 60;
const config: sw.Config = .{
    .title = "menu",
    .size = .{ .w = 1280, .h = 720 },
    .tick_hz = tick_hz,
    .surface_follows_window = true,
};

const script_source = @embedFile("menu.tas");

var options: run.Options = .{};

fn mainNative(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    options = run.parseArgs(args) catch |err| {
        std.log.err("menu: {s}. {s}", .{ @errorName(err), run.usage });
        std.process.exit(2);
    };
    var c = config;
    c.io = init.io;
    run.configure(options, &c);
    try sw.run(c, Callbacks);
}

// =============================================================================
// The strings, in English and in Hebrew
// =============================================================================

const Lang = enum { en, he };
const Str = enum {
    title,
    play,
    settings,
    language,
    name,
    keyboard,
    quit,
    back,
    graphics,
    audio,
    controls,
    gamepad,
    preset,
    low,
    medium,
    high,
    aa,
    shadows,
    ao,
    fog,
    wireframe,
    meshing,
    greedy,
    naive,
    exposure,
    time,
    turn,
    master,
    effects,
    ambience,
    mouse_sens,
    invert_y,
    dead_zone,
    stick,
    press_key,
    conflict,
    english,
    hebrew,
    font,
    font_ttf,
    font_bitmap,
    on,
    off,
    times,
    turn_left,
    turn_right,
    pause_turn,
    next_palette,
    playing,
    tip_preset,
    tip_aa,
    tip_rebind,
    tip_dead_zone,
    tip_font,
    tip_name,
};

const strings = std.enums.EnumArray(Str, [2][]const u8).init(.{
    .title = .{ "Menu demo", "הדגמת תפריט" },
    .play = .{ "Play", "שחק" },
    .settings = .{ "Settings", "הגדרות" },
    .language = .{ "Language and font", "שפה וגופן" },
    .name = .{ "Player name", "שם השחקן" },
    .keyboard = .{ "Keyboard", "מקלדת" },
    .quit = .{ "Quit", "יציאה" },
    .back = .{ "Back", "חזרה" },
    .graphics = .{ "Graphics", "גרפיקה" },
    .audio = .{ "Audio", "שמע" },
    .controls = .{ "Controls", "מקשים" },
    .gamepad = .{ "Gamepad", "בקר משחק" },
    .preset = .{ "Preset", "רמת איכות" },
    .low = .{ "Low", "נמוכה" },
    .medium = .{ "Medium", "בינונית" },
    .high = .{ "High", "גבוהה" },
    .aa = .{ "Anti-aliasing", "החלקת קצוות" },
    .shadows = .{ "Shadows", "צללים" },
    .ao = .{ "Ambient occlusion", "הצללה סביבתית" },
    .fog = .{ "Fog", "ערפל" },
    .wireframe = .{ "Wireframe", "רשת קווים" },
    .meshing = .{ "Meshing", "בניית רשת" },
    .greedy = .{ "greedy", "מאוחדת" },
    .naive = .{ "naive", "פשוטה" },
    .exposure = .{ "Exposure", "חשיפה" },
    .time = .{ "Time of day", "שעה ביום" },
    .turn = .{ "Turn speed", "מהירות סיבוב" },
    .master = .{ "Master volume", "עוצמה ראשית" },
    .effects = .{ "Effects", "אפקטים" },
    .ambience = .{ "Ambience", "רקע" },
    .mouse_sens = .{ "Mouse sensitivity", "רגישות העכבר" },
    .invert_y = .{ "Invert Y", "היפוך ציר Y" },
    .dead_zone = .{ "Stick dead zone", "אזור מת של המקל" },
    .stick = .{ "Left stick", "מקל שמאלי" },
    .press_key = .{ "Press a key for:", "לחץ על מקש עבור:" },
    .conflict = .{ "Warning: this key is also used by:", "אזהרה: גם הפעולה הזו משתמשת במקש:" },
    .english = .{ "English", "English" },
    .hebrew = .{ "עברית", "עברית" },
    .font = .{ "Font", "גופן" },
    .font_ttf = .{ "Lato (TTF)", "Lato (TTF)" },
    .font_bitmap = .{ "Bitmap 5x7", "Bitmap 5x7" },
    .on = .{ "on", "פועל" },
    .off = .{ "off", "כבוי" },
    .times = .{ "Time of day", "שעה ביום" },
    .turn_left = .{ "Turn left", "סיבוב שמאלה" },
    .turn_right = .{ "Turn right", "סיבוב ימינה" },
    .pause_turn = .{ "Stop the turn", "עצירת הסיבוב" },
    .next_palette = .{ "Next palette", "צבע הבא" },
    .playing = .{ "Escape: menu. Keys of Controls: turn. Drag: camera.", "Escape: תפריט. גרירה: מצלמה." },
    .tip_preset = .{ "Sets the anti-aliasing and the shadows", "קובע את החלקת הקצוות ואת הצללים" },
    .tip_aa = .{ "Off, FXAA or MSAA with 4 samples", "כבוי, FXAA או MSAA" },
    .tip_rebind = .{ "Enter, then press the new key. Escape cancels.", "Enter, ואז המקש החדש. Escape מבטל." },
    .tip_dead_zone = .{ "Stick values inside this distance are zero", "ערכים בתוך המרחק הזה הם אפס" },
    .tip_font = .{ "The bitmap font has no Hebrew: the TTF chain draws it", "לגופן מפת הסיביות אין עברית" },
    .tip_name = .{ "Type it, or use the on-screen keyboard", "הקלד, או השתמש במקלדת על המסך" },
});

var lang: Lang = .en;

fn tr(s: Str) []const u8 {
    return strings.get(s)[@backingInt(lang)];
}

// =============================================================================
// The state
// =============================================================================

const Screen = enum { settings, graphics, audio, controls, gamepad, language, keyboard, rebind };
var screens: sw_ui.ScreenStack(Screen, 8) = .{};
var menu_open = true;

/// The game actions of Play. The Controls screen rebinds them.
const Action = enum { turn_left, turn_right, pause_turn, next_palette };
const action_names = [_]Str{ .turn_left, .turn_right, .pause_turn, .next_palette };
var actions = sw.core_types.ActionMap(Action).init(.{
    .turn_left = &.{ Binding.key(.A), Binding.gamepadAxis(.left_x, false) },
    .turn_right = &.{ Binding.key(.D), Binding.gamepadAxis(.left_x, true) },
    .pause_turn = &.{ Binding.key(.Space), Binding.gamepadButton(.north) },
    .next_palette = &.{ Binding.key(.P), Binding.gamepadButton(.west) },
});
var capture: sw.core_types.BindingCapture = .{};
var rebinding: ?Action = null;
/// The tick of the rebind start. The capture reads the next ticks only, so
/// the Enter that started it is not the new key.
var rebind_tick: u64 = 0;
var conflict: ?Action = null;
var conflict_key: ?Binding = null;

/// The gamepad navigation of the UI (as in flat2d).
const Nav = enum { up, down, left, right, activate, back, next, prev };
var nav = sw.core_types.ActionMap(Nav).init(.{
    .up = &.{ Binding.gamepadButton(.dpad_up), Binding.gamepadAxis(.left_y, false) },
    .down = &.{ Binding.gamepadButton(.dpad_down), Binding.gamepadAxis(.left_y, true) },
    .left = &.{ Binding.gamepadButton(.dpad_left), Binding.gamepadAxis(.left_x, false) },
    .right = &.{ Binding.gamepadButton(.dpad_right), Binding.gamepadAxis(.left_x, true) },
    .activate = &.{Binding.gamepadButton(.south)},
    .back = &.{Binding.gamepadButton(.east)},
    .next = &.{Binding.gamepadButton(.right_shoulder)},
    .prev = &.{Binding.gamepadButton(.left_shoulder)},
});

var scene: ?*cow_scene.Scene = null;
var settings: cow_scene.Settings = .{};
var preset: run.Preset = .high;
var player: ?run.Player = null;
var scripted = true;
var frames: run.Frames = .{ .options = .{} };

var ui_state: ?sw_ui.Ui = null;
var ttf_text: ?sw_text.TextRenderer = null;
var bitmap_text: ?sw_text.TextRenderer = null;
var bitmap_sheet: demo.bitmap_font.Sheet = undefined;
var use_bitmap = false;

var name_storage: [64]u8 = undefined;
var name_value: sw_ui.TextValue = .{ .buffer = &name_storage };
var keyboard: sw_ui.osk.Keyboard = .{};

var volumes: [3]f32 = .{ 0.8, 0.8, 0.5 };
var audio: ?sw_audio.Audio = null;
var click_sample: ?sw_audio.Sample = null;
var moo_sample: ?sw_audio.Sample = null;
var wind_sample: ?sw_audio.Sample = null;
var wind_voice: ?sw_audio.Voice = null;

// The slider values. Each tick copies them into the settings.
var exposure: f32 = 1;
var time_of_day: f32 = 0.36;
var turn_speed: f32 = 0.45;
var sensitivity: f32 = 1;
var dead_zone: f32 = 0.15;
var time_choice: usize = 3;
const times = [_]f32{ 0.22, 0.26, 0.30, 0.36, 0.42, 0.50, 0.58, 0.66, 0.72, 0.76, 0.80, 0.02 };

// What the check reads.
const Seen = struct {
    mouse_activate: bool = false,
    gamepad_activate: bool = false,
    keyboard_activate: bool = false,
    conflict_warning: bool = false,
    osk_typed: bool = false,
    tooltip: bool = false,
    max_depth: usize = 0,
    hebrew_frame: bool = false,
    bitmap_frame: bool = false,
    played: bool = false,
};
var seen: Seen = .{};

// =============================================================================
// The IDs of the nodes
// =============================================================================

const ids = struct {
    const root: u32 = 1;
    const panel: u32 = 2;
    const title: u32 = 3;
    const play: u32 = 4;
    const settings: u32 = 5;
    const language: u32 = 6;
    const name_row: u32 = 7;
    const name_field: u32 = 8;
    const keyboard_button: u32 = 9;
    const times: u32 = 10;
    const quit: u32 = 11;
    const status: u32 = 12;
    const playing: u32 = 13;
    /// The Back button of each screen: back + the screen number.
    const back: u32 = 400;

    const settings_screen: u32 = 20;
    const settings_panel: u32 = 21;
    const graphics: u32 = 22;
    const audio: u32 = 23;
    const controls: u32 = 24;
    const gamepad: u32 = 25;

    const graphics_screen: u32 = 30;
    const graphics_panel: u32 = 31;
    const graphics_cols: u32 = 32;
    const graphics_left: u32 = 33;
    const graphics_right: u32 = 34;
    const preset_list: u32 = 35;
    const aa: u32 = 36;
    const shadows: u32 = 37;
    const ao: u32 = 38;
    const fog: u32 = 39;
    const wireframe: u32 = 40;
    const meshing: u32 = 41;
    const exposure: u32 = 42;
    const time: u32 = 43;
    const turn: u32 = 44;

    const audio_screen: u32 = 50;
    const audio_panel: u32 = 51;
    const volume: u32 = 52; // 52, 53, 54

    const controls_screen: u32 = 60;
    const controls_panel: u32 = 61;
    const action_list: u32 = 62;
    const sensitivity: u32 = 63;
    const invert: u32 = 64;
    const warning: u32 = 65;

    const gamepad_screen: u32 = 70;
    const gamepad_panel: u32 = 71;
    const dead_zone: u32 = 72;
    const stick: u32 = 73;

    const language_screen: u32 = 80;
    const language_panel: u32 = 81;
    const lang_list: u32 = 82;
    const font_list: u32 = 83;

    const keyboard_screen: u32 = 90;
    const keyboard_panel: u32 = 91;
    const keyboard_field: u32 = 92;

    const rebind_screen: u32 = 95;
    const rebind_panel: u32 = 96;
    const rebind_text: u32 = 97;

    /// Labels and texts: label + n.
    const label: u32 = 200;
    const preset_item: u32 = 300;
    const time_item: u32 = 320;
    const action_item: u32 = 340;
    const lang_item: u32 = 360;
    const font_item: u32 = 370;
    const osk: u32 = 1000;
};

// =============================================================================
// The UI
// =============================================================================

fn uiInput(ctx: *sw.Context) sw_ui.Input {
    const input = ctx.input();
    const shortcut = input.mods.ctrl or input.mods.super;
    const wheel_lines = if (builtin.cpu.arch.isWasm()) input.wheel.delta_y / 40 else input.wheel.delta_y;
    // The rebind screen reads the keys itself.
    const capturing = screens.top() == .rebind;
    return .{
        .keys = if (capturing) .{} else .{
            .tab = input.keyPressed(.Tab) or nav.pressed(.next) or nav.pressed(.prev),
            .up = input.keyPressed(.Up) or nav.pressed(.up),
            .down = input.keyPressed(.Down) or nav.pressed(.down),
            .left = input.keyPressed(.Left) or nav.pressed(.left),
            .right = input.keyPressed(.Right) or nav.pressed(.right),
            .enter = input.keyPressed(.Enter) or nav.pressed(.activate),
            .space = input.keyPressed(.Space),
            .escape = input.keyPressed(.Escape) or nav.pressed(.back),
            .backspace = input.keyPressed(.Backspace),
            .home = input.keyPressed(.Home),
            .end = input.keyPressed(.End),
            .delete = input.keyPressed(.Delete),
            .select_all = shortcut and input.keyPressed(.A),
            .copy = shortcut and input.keyPressed(.C),
            .cut = shortcut and input.keyPressed(.X),
            .paste = shortcut and input.keyPressed(.V),
        },
        .shift = input.mods.shift or nav.down(.prev),
        .pointer_x = input.mouse.x,
        .pointer_y = input.mouse.y,
        .pointer_pressed = input.buttonPressed(.left),
        .pointer_down = input.buttonDown(.left),
        .wheel_y = wheel_lines,
        .text = input.text.text(),
        .composition = input.composition.text(),
    };
}

fn onOff(b: bool) []const u8 {
    return tr(if (b) .on else .off);
}

fn bindingText(u: *sw_ui.Ui, b: Binding) ![]const u8 {
    return switch (b.source) {
        .none => "-",
        .key => |k| try u.print("{s}", .{@tagName(k)}),
        .mouse => |m| try u.print("mouse {s}", .{@tagName(m)}),
        .gamepad_button => |g| try u.print("pad {s}", .{@tagName(g)}),
        .gamepad_axis => |d| try u.print("pad {s}{s}", .{ @tagName(d.axis), if (d.positive) "+" else "-" }),
    };
}

fn backId(screen: Screen) u32 {
    return ids.back + @backingInt(screen);
}

fn panelOpts() sw_ui.Opts {
    return .{ .padding = 14, .gap = 6, .panel = true, .w = .{ .fixed = 330 } };
}

fn screenOpts() sw_ui.Opts {
    return .{ .w = .fill, .h = .fill, .padding = 16 };
}

fn buildUi(u: *sw_ui.Ui, input: sw_ui.Input, width: f32, height: f32) !void {
    try u.begin(input, width, height);
    try u.beginColumn(ids.root, .{ .w = .fill, .h = .fill, .padding = 16 });
    if (menu_open) {
        try u.beginColumn(ids.panel, .{ .padding = 14, .gap = 6, .panel = true, .label = tr(.title), .w = .{ .fixed = 330 } });
        try u.addText(ids.title, tr(.title), .{});
        try u.addButton(ids.play, tr(.play), .{ .w = .fill });
        try u.addButton(ids.settings, tr(.settings), .{ .w = .fill });
        try u.addButton(ids.language, tr(.language), .{ .w = .fill, .tooltip = tr(.tip_font) });
        try u.beginRow(ids.name_row, .{ .gap = 6, .w = .fill, .label = tr(.name) });
        try u.addTextField(ids.name_field, tr(.name), &name_value, .{ .w = .fill, .tooltip = tr(.tip_name) });
        try u.addButton(ids.keyboard_button, tr(.keyboard), .{ .tooltip = tr(.tip_name) });
        u.endContainer();
        try u.beginScrollList(ids.times, tr(.times), .{ .w = .fill, .h = .{ .fixed = 96 } });
        for (times, 0..) |t, i| {
            var b: [8]u8 = undefined;
            const label = try u.print("{s}", .{cow_scene.clock(&b, t)});
            try u.addListItem(ids.time_item + @as(u32, @intCast(i)), label, .{ .w = .fill, .selected = i == time_choice });
        }
        u.endContainer();
        try u.addButton(ids.quit, tr(.quit), .{ .w = .fill, .disabled = builtin.cpu.arch.isWasm() });
        const who = if (name_value.slice().len > 0) name_value.slice() else "-";
        try u.addText(ids.status, try u.print("{s}: {s}", .{ tr(.name), who }), .{ .live = true });
        u.endContainer();
    } else {
        try u.addText(ids.playing, tr(.playing), .{});
    }
    u.endContainer();

    for (screens.items()) |entry| switch (entry.screen) {
        .settings => try buildSettings(u),
        .graphics => try buildGraphics(u),
        .audio => try buildAudio(u),
        .controls => try buildControls(u),
        .gamepad => try buildGamepad(u),
        .language => try buildLanguage(u),
        .keyboard => try buildKeyboard(u),
        .rebind => try buildRebind(u),
    };
    try u.finish();
}

fn buildSettings(u: *sw_ui.Ui) !void {
    try u.beginScreen(ids.settings_screen, tr(.settings), screenOpts());
    try u.beginColumn(ids.settings_panel, panelOpts());
    try u.addText(ids.label + 0, tr(.settings), .{});
    try u.addButton(ids.graphics, tr(.graphics), .{ .w = .fill });
    try u.addButton(ids.audio, tr(.audio), .{ .w = .fill });
    try u.addButton(ids.controls, tr(.controls), .{ .w = .fill });
    try u.addButton(ids.gamepad, tr(.gamepad), .{ .w = .fill });
    try u.addButton(backId(.settings), tr(.back), .{ .w = .fill });
    u.endContainer();
    u.endContainer();
}

fn slider(u: *sw_ui.Ui, id: u32, label_id: u32, name: Str, value: *f32, min: f32, max: f32, step: f32, comptime fmt: []const u8, tip: []const u8) !void {
    try u.addText(label_id, try u.print("{s}: " ++ fmt, .{ tr(name), value.* }), .{});
    try u.addSlider(id, tr(name), value, .{ .min = min, .max = max, .step = step, .text = try u.print(fmt, .{value.*}) }, .{ .w = .fill, .tooltip = tip });
}

fn buildGraphics(u: *sw_ui.Ui) !void {
    const s = settings;
    try u.beginScreen(ids.graphics_screen, tr(.graphics), screenOpts());
    try u.beginColumn(ids.graphics_panel, .{ .padding = 14, .gap = 6, .panel = true, .w = .{ .fixed = 560 } });
    try u.addText(ids.label + 1, tr(.graphics), .{});
    try u.beginRow(ids.graphics_cols, .{ .gap = 12, .w = .fill });
    try u.beginColumn(ids.graphics_left, .{ .gap = 6, .w = .fill });
    try u.beginList(ids.preset_list, tr(.preset), .{ .w = .fill });
    for ([_]Str{ .low, .medium, .high }, 0..) |p, i| {
        try u.addListItem(ids.preset_item + @as(u32, @intCast(i)), try u.print("{s}: {s}", .{ tr(.preset), tr(p) }), .{ .w = .fill, .selected = @backingInt(preset) == i, .tooltip = tr(.tip_preset) });
    }
    u.endContainer();
    try u.addButton(ids.aa, try u.print("{s}: {s}", .{ tr(.aa), @tagName(s.aa) }), .{ .w = .fill, .tooltip = tr(.tip_aa) });
    try u.addButton(ids.shadows, try u.print("{s}: {s}", .{ tr(.shadows), onOff(s.shadows) }), .{ .w = .fill });
    try u.addButton(ids.ao, try u.print("{s}: {s}", .{ tr(.ao), onOff(s.ao) }), .{ .w = .fill });
    try u.addButton(ids.fog, try u.print("{s}: {s}", .{ tr(.fog), onOff(s.fog) }), .{ .w = .fill });
    u.endContainer();
    try u.beginColumn(ids.graphics_right, .{ .gap = 6, .w = .fill });
    try u.addButton(ids.wireframe, try u.print("{s}: {s}", .{ tr(.wireframe), onOff(s.wireframe) }), .{ .w = .fill });
    try u.addButton(ids.meshing, try u.print("{s}: {s}", .{ tr(.meshing), tr(if (s.meshing == .greedy) .greedy else .naive) }), .{ .w = .fill });
    try slider(u, ids.exposure, ids.label + 2, .exposure, &exposure, 0.3, 3, 0.1, "{d:.1}", "");
    try slider(u, ids.time, ids.label + 3, .time, &time_of_day, 0, 1, 0.02, "{d:.2}", "");
    try slider(u, ids.turn, ids.label + 4, .turn, &turn_speed, 0, 2, 0.1, "{d:.1}", "");
    u.endContainer();
    u.endContainer();
    try u.addButton(backId(.graphics), tr(.back), .{ .w = .fill });
    u.endContainer();
    u.endContainer();
}

fn buildAudio(u: *sw_ui.Ui) !void {
    try u.beginScreen(ids.audio_screen, tr(.audio), screenOpts());
    try u.beginColumn(ids.audio_panel, panelOpts());
    try u.addText(ids.label + 5, tr(.audio), .{});
    for ([_]Str{ .master, .effects, .ambience }, 0..) |name, i| {
        const k: u32 = @intCast(i);
        try slider(u, ids.volume + k, ids.label + 6 + k, name, &volumes[i], 0, 1, 0.05, "{d:.2}", "");
    }
    try u.addButton(backId(.audio), tr(.back), .{ .w = .fill });
    u.endContainer();
    u.endContainer();
}

fn buildControls(u: *sw_ui.Ui) !void {
    try u.beginScreen(ids.controls_screen, tr(.controls), screenOpts());
    try u.beginColumn(ids.controls_panel, panelOpts());
    try u.addText(ids.label + 10, tr(.controls), .{});
    try u.beginList(ids.action_list, tr(.controls), .{ .w = .fill });
    for (std.enums.values(Action), 0..) |a, i| {
        const b = actions.bindings(a)[0];
        const item = try u.print("{s}: {s}", .{ tr(action_names[i]), try bindingText(u, b) });
        try u.addListItem(ids.action_item + @as(u32, @intCast(i)), item, .{ .w = .fill, .tooltip = tr(.tip_rebind) });
    }
    u.endContainer();
    if (conflict) |c| {
        try u.addText(ids.warning, try u.print("{s} {s}", .{ tr(.conflict), tr(action_names[@backingInt(c)]) }), .{ .live = true });
    }
    try slider(u, ids.sensitivity, ids.label + 11, .mouse_sens, &sensitivity, 0.1, 3, 0.1, "{d:.1}", "");
    try u.addButton(ids.invert, try u.print("{s}: {s}", .{ tr(.invert_y), onOff(actions.mouse.invert_y) }), .{ .w = .fill });
    try u.addButton(backId(.controls), tr(.back), .{ .w = .fill });
    u.endContainer();
    u.endContainer();
}

var stick_text: [64]u8 = undefined;

fn buildGamepad(u: *sw_ui.Ui) !void {
    try u.beginScreen(ids.gamepad_screen, tr(.gamepad), screenOpts());
    try u.beginColumn(ids.gamepad_panel, panelOpts());
    try u.addText(ids.label + 12, tr(.gamepad), .{});
    try slider(u, ids.dead_zone, ids.label + 13, .dead_zone, &dead_zone, 0, 0.9, 0.05, "{d:.2}", tr(.tip_dead_zone));
    try u.addText(ids.stick, try u.print("{s}", .{stick_line}), .{ .live = true });
    try u.addButton(backId(.gamepad), tr(.back), .{ .w = .fill });
    u.endContainer();
    u.endContainer();
}

var stick_line: []const u8 = "";

fn buildLanguage(u: *sw_ui.Ui) !void {
    try u.beginScreen(ids.language_screen, tr(.language), screenOpts());
    try u.beginColumn(ids.language_panel, panelOpts());
    try u.addText(ids.label + 14, tr(.language), .{});
    try u.beginList(ids.lang_list, tr(.language), .{ .w = .fill });
    try u.addListItem(ids.lang_item + 0, tr(.english), .{ .w = .fill, .selected = lang == .en });
    try u.addListItem(ids.lang_item + 1, tr(.hebrew), .{ .w = .fill, .selected = lang == .he });
    u.endContainer();
    try u.addText(ids.label + 15, tr(.font), .{});
    try u.beginList(ids.font_list, tr(.font), .{ .w = .fill });
    try u.addListItem(ids.font_item + 0, tr(.font_ttf), .{ .w = .fill, .selected = !use_bitmap });
    try u.addListItem(ids.font_item + 1, tr(.font_bitmap), .{ .w = .fill, .selected = use_bitmap, .tooltip = tr(.tip_font) });
    u.endContainer();
    try u.addButton(backId(.language), tr(.back), .{ .w = .fill });
    u.endContainer();
    u.endContainer();
}

fn buildKeyboard(u: *sw_ui.Ui) !void {
    try u.beginScreen(ids.keyboard_screen, tr(.keyboard), .{ .w = .fill, .h = .fill, .main_align = .end, .cross_align = .center, .padding = 16 });
    try u.beginColumn(ids.keyboard_panel, .{ .padding = 12, .gap = 8, .panel = true, .cross_align = .center });
    try u.addTextField(ids.keyboard_field, tr(.name), &name_value, .{ .w = .{ .fixed = 420 } });
    try keyboard.build(u, ids.osk, .{});
    u.endContainer();
    u.endContainer();
}

fn buildRebind(u: *sw_ui.Ui) !void {
    try u.beginScreen(ids.rebind_screen, tr(.controls), .{ .w = .fill, .h = .fill, .main_align = .center, .cross_align = .center });
    try u.beginColumn(ids.rebind_panel, .{ .padding = 20, .gap = 8, .panel = true });
    const a = rebinding orelse .turn_left;
    try u.addText(ids.rebind_text, try u.print("{s} {s}", .{ tr(.press_key), tr(action_names[@backingInt(a)]) }), .{ .live = true });
    u.endContainer();
    u.endContainer();
}

fn playClick(freq_high: bool) void {
    const a = if (audio) |*p| p else return;
    const s = if (click_sample) |*c| c else return;
    _ = a.playSample(s, .{ .group = sound.group_effects, .pitch = if (freq_high) 1.5 else 1.0 });
}

/// Toggle one setting of the Graphics screen.
fn handleActivate(ctx: *sw.Context, u: *sw_ui.Ui, id: u32, from_pointer: bool) !void {
    var s = settings;
    switch (id) {
        ids.play => {
            menu_open = false;
            seen.played = true;
            if (audio) |*a| {
                if (moo_sample) |*m| _ = a.playSample(m, .{ .group = sound.group_effects });
            }
        },
        ids.settings => try screens.push(u, .settings),
        ids.language => try screens.push(u, .language),
        ids.keyboard_button => try screens.push(u, .keyboard),
        ids.quit => ctx.requestShutdown(),
        ids.graphics => try screens.push(u, .graphics),
        ids.audio => try screens.push(u, .audio),
        ids.controls => try screens.push(u, .controls),
        ids.gamepad => try screens.push(u, .gamepad),
        ids.aa => s.aa = switch (s.aa) {
            .off => .fxaa,
            .fxaa => .msaa,
            .msaa => .off,
        },
        ids.shadows => s.shadows = !s.shadows,
        ids.ao => s.ao = !s.ao,
        ids.fog => s.fog = !s.fog,
        ids.wireframe => s.wireframe = !s.wireframe,
        ids.meshing => s.meshing = if (s.meshing == .greedy) .naive else .greedy,
        ids.invert => actions.mouse.invert_y = !actions.mouse.invert_y,
        else => {
            if (id >= ids.back and id < ids.back + std.enums.values(Screen).len) {
                _ = screens.pop(u);
            } else if (id >= ids.preset_item and id < ids.preset_item + 3) {
                preset = @fromBackingInt(@intCast(id - ids.preset_item));
                // A preset sets the anti-aliasing, the shadows and the
                // shadow maps. The other settings stay.
                const p = cow_scene.Settings.fromGraphics(run.graphics(preset));
                s.aa = p.aa;
                s.fxaa_quality = p.fxaa_quality;
                s.shadows = p.shadows;
                s.cascades = p.cascades;
                s.shadow_map_size = p.shadow_map_size;
            } else if (id >= ids.time_item and id < ids.time_item + times.len) {
                time_choice = id - ids.time_item;
                time_of_day = times[time_choice];
            } else if (id >= ids.action_item and id < ids.action_item + 4) {
                rebinding = @fromBackingInt(@intCast(id - ids.action_item));
                rebind_tick = ctx.tickId();
                capture.reset();
                conflict = null;
                try screens.push(u, .rebind);
            } else if (id >= ids.lang_item and id < ids.lang_item + 2) {
                lang = @fromBackingInt(@intCast(id - ids.lang_item));
            } else if (id >= ids.font_item and id < ids.font_item + 2) {
                use_bitmap = id == ids.font_item + 1;
                applyFont(u);
            }
        },
    }
    if (from_pointer) seen.mouse_activate = true;
    playClick(false);
    if (!std.meta.eql(s, settings)) {
        settings = s;
        try scene.?.apply(s);
    }
}

fn applyFont(u: *sw_ui.Ui) void {
    const t = if (use_bitmap) &bitmap_text.? else &ttf_text.?;
    u.measurer = sw_ui.draw.measurer(t);
    if (scene) |sc| sc.overlay().text = t;
}

fn handleUi(ctx: *sw.Context, u: *sw_ui.Ui) !void {
    const in = ctx.input();
    if (screens.top() == .keyboard) {
        const r = keyboard.apply(u, ids.osk, &name_value);
        if (r.changed) seen.osk_typed = true;
        if (r.done) _ = screens.pop(u);
    }
    const pointer = in.buttonPressed(.left);
    for (u.frameEvents()) |e| switch (e.kind) {
        .activate => {
            if (nav.pressed(.activate)) seen.gamepad_activate = true;
            if (in.keyPressed(.Enter)) seen.keyboard_activate = true;
            try handleActivate(ctx, u, e.id, pointer);
        },
        .cancel => {
            if (screens.pop(u) == null) {
                if (u.focused()) |f| {
                    if (f == ids.name_field) u.clearFocus();
                }
            }
        },
        .changed => {},
        .submit => {},
    };
    if (u.tooltip() != null) seen.tooltip = true;
    seen.max_depth = @max(seen.max_depth, screens.items().len);

    const wanted = u.wantsTextInput();
    if (wanted and !ctx.isTextInputActive()) ctx.startTextInput();
    if (!wanted and ctx.isTextInputActive()) ctx.stopTextInput();
}

/// The rebind screen: the next key, button or axis is the new binding.
fn handleRebind(ctx: *sw.Context, u: *sw_ui.Ui) void {
    if (screens.top() != .rebind) return;
    if (ctx.tickId() <= rebind_tick) return;
    const in = ctx.input();
    if (in.keyPressed(.Escape)) {
        _ = screens.pop(u);
        rebinding = null;
        return;
    }
    const b = capture.update(in) orelse return;
    const a = rebinding.?;
    conflict = actions.findAction(b, a);
    if (conflict != null) {
        seen.conflict_warning = true;
        conflict_key = b;
    }
    actions.bind(a, 0, b);
    rebinding = null;
    _ = screens.pop(u);
    playClick(true);
}

/// The live values of the sliders and of the audio.
fn applySliders() !void {
    var s = settings;
    s.exposure = exposure;
    s.time = time_of_day;
    s.turn_speed = turn_speed;
    actions.mouse.setSensitivity(sensitivity);
    actions.gamepad.setStickDeadZone(dead_zone);
    nav.gamepad = actions.gamepad;
    if (!std.meta.eql(s, settings)) {
        settings = s;
        try scene.?.apply(s);
    }
    if (audio) |*a| {
        a.setMasterVolume(volumes[0]);
        a.setGroupVolume(sound.group_effects, volumes[1]);
        a.setGroupVolume(sound.group_ambience, volumes[2]);
    }
}

/// Play: the actions turn the cow, the mouse and the right stick move the
/// camera.
fn playTick(ctx: *sw.Context) !void {
    const sc = scene.?;
    const in = ctx.input();
    const dt = 1.0 / @as(f32, tick_hz);
    sc.angle += (actions.value(.turn_right) - actions.value(.turn_left)) * 2 * dt;
    if (actions.pressed(.pause_turn)) turn_speed = if (turn_speed > 0) 0 else 0.45;
    if (actions.pressed(.next_palette)) {
        var s = settings;
        s.palette = @intCast((s.palette + 1) % demo.cow.palettes.len);
        settings = s;
        try sc.apply(s);
    }
    if (in.buttonDown(.left)) {
        const look = actions.mouse.look(in);
        sc.yaw -= look.dx * 0.005;
        sc.pitch += look.dy * 0.005;
    }
    for (&in.gamepads) |*g| {
        const r = g.stick(.right, actions.gamepad);
        const ry: f32 = if (actions.mouse.invert_y) -r.y else r.y;
        sc.yaw -= r.x * 2 * dt;
        sc.pitch += ry * dt;
    }
    sc.pitch = std.math.clamp(sc.pitch, -0.4, 0.9);
}

fn drawHud(_: ?*anyopaque, o: *demo.overlay.Overlay) anyerror!void {
    const u = if (ui_state) |*p| p else return;
    try sw_ui.draw.draw(u, &o.renderer, o.text, .{});
    if (lang == .he) seen.hebrew_frame = true;
    if (use_bitmap) seen.bitmap_frame = true;
    // The frame time at the top right.
    try o.print(o.width - 120, 8, 14, gfx.Color.rgba8(230, 230, 230, 255), "{d:.1} ms", .{o.frameMs()});
}

// =============================================================================
// The callbacks
// =============================================================================

const Callbacks = struct {
    pub fn init(ctx: *sw.Context) !void {
        const gpu = ctx.gpu();
        if (!gpu.isReady()) return;
        const allocator = ctx.allocator();
        frames = .{ .options = options };
        preset = options.preset;
        settings = cow_scene.Settings.fromGraphics(run.graphics(preset));
        settings.time = time_of_day;
        scene = try cow_scene.Scene.create(allocator, gpu, settings, options.offline(), null, drawHud);

        // The TTF chain: Lato, then Hebrew. The bitmap chain: the bitmap
        // font, then the same TTF fonts for the letters that it does not
        // have.
        ttf_text = try sw_text.TextRenderer.init(allocator, demo.fonts.latin);
        try ttf_text.?.addFont(demo.fonts.hebrew);
        bitmap_sheet = demo.bitmap_font.makeSheet();
        bitmap_text = try sw_text.TextRenderer.initBitmap(allocator, bitmap_sheet.desc());
        try bitmap_text.?.addFont(demo.fonts.latin);
        try bitmap_text.?.addFont(demo.fonts.hebrew);
        ui_state = sw_ui.Ui.init(allocator, sw_ui.draw.measurer(&ttf_text.?), .{});
        const u = &ui_state.?;
        u.setFocus(ids.play);
        if (!options.offline()) u.clipboard = sw_ui.Clipboard.platform(ctx);
        applyFont(u);

        // No audio in a run with no window: the run must not need a device.
        if (!options.offline()) {
            audio = sw_audio.Audio.init();
            click_sample = try sound.click(allocator, 880);
            moo_sample = try sound.moo(allocator);
            wind_sample = try sound.wind(allocator, 6);
            if (audio) |*a| wind_voice = a.playSample(&wind_sample.?, .{ .group = sound.group_ambience, .looping = true, .volume = 0.5 });
        }
        const source = try run.loadScript(ctx, options, script_source);
        player = try run.Player.init(allocator, source, tick_hz);
        std.log.info("menu: GPU ready", .{});
    }

    pub fn preTick(ctx: *sw.Context) !void {
        if (!scripted) return;
        if (player) |*p| try p.feed(ctx);
    }

    pub fn tick(ctx: *sw.Context) !void {
        const sc = scene orelse return;
        const u = if (ui_state) |*p| p else return;
        nav.update(ctx.input());
        actions.update(ctx.input());
        if (player) |*p| {
            if (scripted and p.done(ctx.tickId()) and !options.offline()) scripted = false;
        }

        if (menu_open) {
            handleRebind(ctx, u);
            const win = ctx.window();
            const logical = gfx.projection.logicalSize(win.width, win.height, win.dpi_scale);
            try buildUi(u, uiInput(ctx), logical.w, logical.h);
            try handleUi(ctx, u);
        } else {
            try playTick(ctx);
            if (ctx.input().keyPressed(.Escape) or nav.pressed(.back)) {
                menu_open = true;
                u.setFocus(ids.play);
            }
            const win = ctx.window();
            const logical = gfx.projection.logicalSize(win.width, win.height, win.dpi_scale);
            try buildUi(u, uiInput(ctx), logical.w, logical.h);
        }
        if (debug_bounds) {
            for ([_]u32{ ids.play, ids.settings, ids.language, ids.name_field, ids.keyboard_button, ids.times, ids.quit, ids.graphics, ids.back, ids.aa, ids.fog }) |id| {
                if (u.bounds(id)) |b| std.log.info("bounds {d}: {d} {d} {d} {d}", .{ id, b.x, b.y, b.w, b.h });
            }
        }
        try applySliders();
        updateStickLine(ctx);
        sc.step(1.0 / @as(f32, tick_hz));
    }

    pub fn render(ctx: *sw.Context) !void {
        const gpu = ctx.gpu();
        if (!gpu.isReady()) return;
        const sc = scene orelse return;
        const p = &player.?;
        const t = p.tasTick(ctx.tickId());
        if (frames.wanted(t) and try sc.render(ctx)) {
            try frames.frame(ctx, t);
            gpu.present();
        }
        if (options.offline() and p.done(ctx.tickId())) finishOffline(ctx);
    }

    pub fn shutdown(ctx: *sw.Context) !void {
        const allocator = ctx.allocator();
        if (audio) |*a| a.stopAll();
        if (scene) |s| s.destroy();
        scene = null;
        if (ui_state) |*u| u.deinit();
        ui_state = null;
        if (ttf_text) |*t| t.deinit();
        if (bitmap_text) |*t| t.deinit();
        for ([_]*?sw_audio.Sample{ &click_sample, &moo_sample, &wind_sample }) |s| {
            if (s.*) |*v| sound.free(allocator, v);
            s.* = null;
        }
        if (player) |*p| p.deinit();
        frames.hashes.deinit(allocator);
    }
};

var stick_buf: [96]u8 = undefined;

fn updateStickLine(ctx: *sw.Context) void {
    const in = ctx.input();
    var x: f32 = 0;
    var y: f32 = 0;
    for (&in.gamepads) |*g| {
        if (!g.connected) continue;
        const s = g.stick(.left, actions.gamepad);
        x = s.x;
        y = s.y;
        break;
    }
    stick_line = std.fmt.bufPrint(&stick_buf, "{s}: {d:.2} {d:.2}", .{ tr(.stick), x, y }) catch "";
}

fn finishOffline(ctx: *sw.Context) noreturn {
    var ok = true;
    if (options.check) {
        const s = settings;
        const want = [_]struct { bool, []const u8 }{
            .{ screens.items().len == 0, "the script ends on the main screen" },
            .{ seen.max_depth >= 2, "a screen over a screen (the stack)" },
            .{ seen.keyboard_activate, "a keyboard activation" },
            .{ seen.gamepad_activate, "a gamepad activation" },
            .{ seen.mouse_activate, "a mouse activation" },
            .{ seen.tooltip, "a tooltip" },
            .{ preset == .low, "the preset low" },
            .{ s.aa == .msaa, "MSAA from the anti-aliasing button" },
            .{ !s.fog, "the fog off" },
            .{ s.wireframe, "the wireframe on" },
            .{ exposure > 1.25, "a larger exposure from the slider" },
            .{ volumes[2] < 0.45, "a lower ambience volume" },
            .{ seen.conflict_warning, "a conflict warning" },
            .{ actions.bindings(.turn_left)[0].eql(Binding.key(.J)), "turn left rebound to J" },
            .{ actions.mouse.invert_y, "invert Y" },
            .{ dead_zone > 0.3, "a larger dead zone" },
            .{ seen.osk_typed and name_value.slice().len >= 2, "a name from the on-screen keyboard" },
            .{ seen.hebrew_frame, "a frame in Hebrew" },
            .{ seen.bitmap_frame, "a frame with the bitmap font" },
            .{ seen.played, "Play" },
        };
        for (want) |w| {
            if (!w[0]) {
                std.log.err("menu: the script did not give: {s}", .{w[1]});
                ok = false;
            }
        }
        // The semantic tree has a name for each focusable widget.
        const tree = ui_state.?.semanticTree();
        if (tree.nodes.len < 5) {
            std.log.err("menu: the semantic tree has {d} nodes", .{tree.nodes.len});
            ok = false;
        }
        std.log.info("menu: name \"{s}\", preset {s}, exposure {d:.2}", .{ name_value.slice(), @tagName(preset), exposure });
        std.log.info("menu: check {s}", .{if (ok) "passed" else "FAILED"});
    }
    run.exitOffline(ctx, &frames, "menu", if (ok) 0 else 1);
}
const debug_bounds = false;
