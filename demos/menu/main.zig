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
// The menu frame, the text, the fonts and the shared screen parts are in
// demos/common/game_menu.zig: the shooter uses them too (REQ-DEMO-026).
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
const core = @import("sw_core");
const gfx = @import("sw_gfx2d");
const audio = demo.audio;
const gm = demo.game_menu;
const S = gm.S;
const ids = gm.ids;
const Language = gm.Language;
const FontKind = gm.FontKind;
const layout_height = gm.layout_height;

const D = demo.Demo(App);
pub const std_options = demo.std_options;
pub const main = D.main;

comptime {
    D.exportWeb();
}

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

const Screen = enum { settings, player, keyboard, graphics, sound, controls, gamepad, interface };

// ---- State ------------------------------------------------------------------

var scene: demo.CowScene = undefined;
/// The menu frame (game_menu.zig).
var m: gm.Menu = undefined;
const ui = &m.ui;
const nav = &m.nav;
var ms: MenuSettings = .{};
var cow: demo.CowSettings = .{};
var screens: sw_ui.ScreenStack(Screen, 6) = .{};
var name_storage: [64]u8 = undefined;
var name_value: sw_ui.TextValue = .{ .buffer = &name_storage };
var keyboard: sw_ui.osk.Keyboard = .{ .key_size = 30 };
var actions = core.ActionMap(Act).init(act_defaults);
var capture: core.BindingCapture = .{};
var capturing: ?Act = null;
var conflict_buf: [128]u8 = undefined;
var conflict_text: []const u8 = "";
var yaw: f32 = 0;
var pitch: f32 = 0;
var dragging = false;
var last_pointer: [2]f32 = .{ 0, 0 };
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

/// Give the menu frame the language and the font of the settings.
fn sync() void {
    m.language = ms.language;
    m.font = ms.font;
}

fn tr(s: S) []const u8 {
    sync();
    return m.tr(s);
}

fn rtl() bool {
    return ms.language == .hebrew;
}

fn text() *sw_text.TextRenderer {
    sync();
    return m.text();
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

/// The lists of the menu: the arrow keys move inside each one.
const lists = [_]gm.ListRange{
    .{ .first = ids.language_item, .last = ids.language_item + 1 },
    .{ .first = ids.font_item, .last = ids.font_item + 1 },
    .{ .first = ids.hour_item, .last = ids.hour_item + 23 },
};

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
        .mouse => |button| w.print("Mouse {s}", .{@tagName(button)}) catch {},
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

fn buildMain() !void {
    try m.beginPanel(null, tr(.title));
    const name = if (name_value.slice().len > 0) name_value.slice() else tr(.no_name);
    try ui.addText(ids.player_line, try ui.print("{s}: {s}", .{ tr(.player_line), name }), .{ .live = true });
    try ui.addButton(ids.resume_game, tr(.resume_game), gm.Menu.wide(tr(.resume_tip)));
    try ui.addButton(ids.player, tr(.player), gm.Menu.wide(tr(.player_tip)));
    try ui.addButton(ids.settings, tr(.settings), gm.Menu.wide(tr(.settings_tip)));
    try ui.addText(ids.hint, tr(.hint), .{});
    m.endPanel();
}

fn buildSettings() !void {
    try m.beginPanel(300, tr(.settings));
    try ui.addButton(ids.graphics, tr(.graphics), gm.Menu.wide(tr(.graphics_tip)));
    try ui.addButton(ids.sound, tr(.sound), gm.Menu.wide(tr(.sound_tip)));
    try ui.addButton(ids.controls, tr(.controls), gm.Menu.wide(tr(.controls_tip)));
    try ui.addButton(ids.gamepad, tr(.gamepad), gm.Menu.wide(tr(.gamepad_tip)));
    try ui.addButton(ids.interface, tr(.interface), gm.Menu.wide(tr(.interface_tip)));
    try ui.addButton(ids.back, tr(.back), gm.Menu.wide(""));
    m.endPanel();
}

fn presetName(p: Preset) []const u8 {
    sync();
    return m.qualityName(switch (p) {
        .low => .low,
        .medium => .medium,
        .high => .high,
        .custom => .custom,
    });
}

fn buildGraphics() !void {
    try m.beginPanel(301, tr(.graphics));
    try m.cycleButton(ids.preset, .preset, presetName(ms.preset));
    const aa_name = switch (cow.aa) {
        .off => tr(.off),
        .fxaa => "FXAA",
        .msaa => "MSAA 4x",
    };
    try m.cycleButton(ids.aa, .anti_aliasing, aa_name);
    try m.cycleButton(ids.coat, .coat, @tagName(cow.palette));
    try m.sliderRow(ids.exposure, tr(.exposure), &cow.exposure, .{ .min = 0.2, .max = 2.5, .step = 0.1 }, try ui.print("{d:.1}", .{cow.exposure}), "");
    try m.sliderRow(ids.time, tr(.time_of_day), &cow.time, .{ .min = 0, .max = 1, .step = 0.02 }, try ui.print("{d:0>2}:{d:0>2}", .{ hourOf(cow.time), minuteOf(cow.time) }), "");
    try m.sliderRow(ids.spin, tr(.spin), &cow.spin, .{ .min = 0, .max = 2, .step = 0.1 }, try ui.print("{d:.1}", .{cow.spin}), "");
    try m.toggleRow(ids.toggle_row_a, ids.shadows, .shadows, cow.shadows, ids.occlusion, .occlusion, cow.ao);
    try m.toggleRow(ids.toggle_row_b, ids.fog, .fog, cow.fog, ids.sky, .sky, cow.sky);
    try m.toggleButton(ids.wireframe, .wireframe, cow.wireframe);
    try m.back();
    m.endPanel();
}

fn hourOf(t: f32) u32 {
    const minutes: u32 = @intFromFloat(@round(t * 24 * 60));
    return (minutes / 60) % 24;
}

fn minuteOf(t: f32) u32 {
    const minutes: u32 = @intFromFloat(@round(t * 24 * 60));
    return minutes % 60;
}

fn buildSound() !void {
    try m.audioScreen(302, &.{
        .{ .base = ids.master, .label = .master, .value = &ms.master },
        .{ .base = ids.music, .label = .music, .value = &ms.music },
        .{ .base = ids.effects, .label = .effects, .value = &ms.effects },
        .{ .base = ids.ui_sounds, .label = .ui_sounds, .value = &ms.interface },
    });
}

fn buildControls() !void {
    try m.beginPanel(303, tr(.controls));
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
    try m.mouseRows(&ms.sensitivity, ms.invert_y);
    try ui.addButton(ids.reset_keys, tr(.reset_keys), gm.Menu.wide(""));
    try ui.addButton(ids.back, tr(.back), gm.Menu.wide(""));
    m.endPanel();
}

fn buildGamepad(snap: *const core.InputSnapshot) !void {
    try m.beginPanel(304, tr(.gamepad));
    try m.sliderRow(ids.dead_zone, tr(.dead_zone), &ms.dead_zone, .{ .min = 0, .max = 0.9, .step = 0.05 }, try ui.print("{d:.2}", .{ms.dead_zone}), tr(.dead_zone_tip));
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
    try ui.addButton(ids.back, tr(.back), gm.Menu.wide(""));
    m.endPanel();
}

fn buildInterface() !void {
    try m.beginPanel(305, tr(.interface));
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
    try ui.addButton(ids.back, tr(.back), gm.Menu.wide(""));
    m.endPanel();
}

fn buildPlayer() !void {
    try m.beginPanel(306, tr(.player));
    try ui.addTextField(ids.name_field, tr(.name), &name_value, .{ .w = .fill });
    try ui.addButton(ids.keyboard_button, tr(.keyboard), gm.Menu.wide(tr(.keyboard_tip)));
    try ui.beginScrollList(ids.hours_list, tr(.hours), .{ .w = .fill, .h = .{ .fixed = 170 }, .tooltip = tr(.hours_tip) });
    const current = hourOf(cow.time);
    for (0..24) |h| {
        try ui.addListItem(ids.hour_item + @as(u32, @intCast(h)), try ui.print("{d:0>2}:00", .{h}), .{ .w = .fill, .selected = h == current });
    }
    ui.endContainer();
    try ui.addButton(ids.back, tr(.back), gm.Menu.wide(""));
    m.endPanel();
}

fn buildKeyboard() !void {
    try m.beginPanel(307, tr(.keyboard));
    try ui.addTextField(ids.keyboard_field, tr(.name), &name_value, .{ .w = .fill });
    keyboard.letters_layout = if (rtl()) gm.hebrew_keys else sw_ui.osk.letters;
    try keyboard.build(ui, ids.osk, .{ .label = tr(.keyboard) });
    m.endPanel();
}

fn buildUi(input: sw_ui.Input, snap: *const core.InputSnapshot) !void {
    sync();
    try ui.begin(input, m.layout_w, layout_height);
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
    screens.push(ui, s) catch {};
    play(group_ui, 1.5);
}

fn setMenu(open: bool) void {
    ms.menu = open;
    ui.setFocus(if (open) ids.resume_game else ids.open_menu);
}

const cycle = gm.cycle;

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
        const r = keyboard.apply(ui, ids.osk, &name_value);
        if (r.changed) {
            std.log.info("menu: name = \"{s}\"", .{name_value.slice()});
            play(group_ui, 1.0);
        }
        if (r.done) _ = screens.pop(ui);
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
            if (screens.pop(ui) != null) {
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
            _ = screens.pop(ui);
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
    sync();
    m.applyFont();
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
    sync();
    try m.drawUi(pass, gm.Menu.palette(), null);
    if (moo_flash > 0) {
        const k = @as(f32, @floatFromInt(pass.height)) / layout_height;
        const lw = @as(f32, @floatFromInt(pass.width)) / k;
        _ = try m.text().draw(&m.r2d, "Moo!", if (rtl()) lw - 120 else 40, 200, .{ .size = 40, .color = gfx.Color.rgba8(255, 240, 200, 255) });
    }
    try m.drawEnd(pass);
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
        try m.init(host.allocator, host.gpu);
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
        m.setLayout(host.gpu.getSurfaceWidth(), host.gpu.getSurfaceHeight(), host.ctx.window());

        nav.update(snap);
        var input: sw_ui.Input = undefined;
        if (capturing != null) {
            updateCapture(snap);
            // The UI gets no keys while it waits for a binding.
            input = .{ .pointer_x = snap.mouse.x, .pointer_y = snap.mouse.y };
        } else {
            actions.update(snap);
            sync();
            input = m.input(snap, host.user_control, &lists);
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
        m.deinit();
        scene.deinit();
    }
};
