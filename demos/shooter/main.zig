// shooter - a first-person shootout in a snowy arena, offline
// (REQ-DEMO-020). The player fights three bots that move, take cover and
// fire back. The fight code comes from the action game (seanorepo
// apps/action): the gun models and their stats, the hands, the body
// model, the ragdoll, the movement, the impact effects and the bullet
// sounds. It has no network code.
//
// The engine features: falling snow and a cloud layer, the fog, the sky
// and the shadows (sw_render), the particles of the muzzle flashes, the
// impacts and the snow, 3D gun sound (sw_audio), box models for the bots,
// collision with sw_math boxes and rays, and the input actions of sw_core
// with the keyboard, the mouse and a gamepad.
//
// The script (shooter.tas) plays the player with `key`, `mouse` and
// `button` commands, so a check run gives the same fight and the same
// frames each time (REQ-DEMO-021). In a window, the script plays in a
// loop until a key, a click or a gamepad button takes the control.
//
// Controls: WASD move, mouse or arrow keys look, left button fire, right
// button aim, R reload, Space jump, Q and E lean. Gamepad: left stick
// move, right stick look, right trigger fire, left trigger aim, south
// jump, west reload, shoulders lean.
//
//   zig build run -Ddemo=shooter
//   ./zig-out/bin/shooter --check                     # the frame hashes
//   zig build web -Ddemo=shooter && yarn dev:demo shooter
const std = @import("std");
const builtin = @import("builtin");
const demo = @import("demo_common");
const sw_core = @import("sw_core");
const sw_gfx2d = @import("sw_gfx2d");
const sw_render = @import("sw_render");
const vec = @import("vec.zig");
const arena = @import("arena.zig");
const weapon = @import("weapon.zig");
const game_mod = @import("game.zig");
const scene_mod = @import("scene.zig");
const fx = @import("impact_fx.zig");
const sfx_mod = @import("sfx.zig");
const V3 = vec.V3;
const v3 = vec.v3;

const D = demo.Demo(App);
pub const std_options = demo.std_options;
pub const main = D.main;

comptime {
    D.exportWeb();
}

/// The input actions of the player (REQ-INPUT-003, REQ-INPUT-005).
const Action = enum { forward, back, left, right, look_left, look_right, look_up, look_down, fire, aim, jump, reload, lean_left, lean_right };
const Actions = sw_core.ActionMap(Action);
const Bind = sw_core.Binding;

const bindings: Actions.Defaults = .{
    .forward = &.{ Bind.key(.W), Bind.gamepadAxis(.left_y, false) },
    .back = &.{ Bind.key(.S), Bind.gamepadAxis(.left_y, true) },
    .left = &.{ Bind.key(.A), Bind.gamepadAxis(.left_x, false) },
    .right = &.{ Bind.key(.D), Bind.gamepadAxis(.left_x, true) },
    .look_left = &.{ Bind.key(.Left), Bind.gamepadAxis(.right_x, false) },
    .look_right = &.{ Bind.key(.Right), Bind.gamepadAxis(.right_x, true) },
    .look_up = &.{ Bind.key(.Up), Bind.gamepadAxis(.right_y, false) },
    .look_down = &.{ Bind.key(.Down), Bind.gamepadAxis(.right_y, true) },
    .fire = &.{ Bind.mouse(.left), Bind.key(.F), Bind.gamepadAxis(.right_trigger, true) },
    .aim = &.{ Bind.mouse(.right), Bind.gamepadAxis(.left_trigger, true) },
    .jump = &.{ Bind.key(.Space), Bind.gamepadButton(.south) },
    .reload = &.{ Bind.key(.R), Bind.gamepadButton(.west) },
    .lean_left = &.{ Bind.key(.Q), Bind.gamepadButton(.left_shoulder) },
    .lean_right = &.{ Bind.key(.E), Bind.gamepadButton(.right_shoulder) },
};

/// Radians of turn for each pixel of mouse move.
const mouse_turn: f32 = 0.0022;
/// Radians each second at full stick, or with an arrow key.
const key_turn: f32 = 2.4;
const seed: u64 = 79;

const App = struct {
    pub const name = "shooter";
    pub const script = @embedFile("shooter.tas");

    var scene: scene_mod.Scene = undefined;
    var g: game_mod.Game = undefined;
    var particles: fx.System = undefined;
    var fx_rng: std.Random.DefaultPrng = .init(seed);
    var sfx: ?sfx_mod.Sfx = null;
    var actions: Actions = undefined;
    var mouse: sw_core.MouseSettings = .{};
    /// A key, a click or a gamepad button took the control from the script.
    var live = false;
    var ticks: u64 = 0;

    pub fn init(host: *demo.Host) !void {
        try weapon.loadModels(host.allocator);
        arena.build();
        const gr = host.graphics;
        scene = try scene_mod.Scene.init(host.allocator, &host.graph, &host.post, .{
            .shadow_map_size = gr.shadow_map_size,
            .shadow_cascades = @max(gr.shadow_cascades, 1),
            .fxaa_quality = gr.fxaa_quality,
        });
        particles = try fx.System.init(host.allocator, 2048);
        g = game_mod.Game.init(seed, .{});
        actions = Actions.init(bindings);
        // No sound in a capture or a check run (REQ-DEMO-004).
        if (!host.deterministic()) sfx = sfx_mod.Sfx.init(host.allocator) catch null;
    }

    pub fn reset(_: *demo.Host) !void {
        if (live) return;
        g = game_mod.Game.init(seed, g.settings);
        particles.clear();
        fx_rng = .init(seed);
        ticks = 0;
    }

    pub fn set(_: *demo.Host, setting: []const u8, value: []const u8) !void {
        var s = scene.settings();
        if (demo.reflect.setField(scene_mod.Settings, &s, setting, value)) {
            try scene.apply(s);
            return;
        } else |err| if (err != error.UnknownSetting) return err;
        try demo.reflect.setField(game_mod.Settings, &g.settings, setting, value);
    }

    fn anyLiveInput(in: *const sw_core.InputSnapshot) bool {
        if (in.keyboard.pressed.count() > 0 or in.mouse.pressed.count() > 0) return true;
        for (in.gamepads) |pad| {
            if (pad.pressed.count() > 0) return true;
        }
        return false;
    }

    fn readInput(snap: *const sw_core.InputSnapshot, dt: f32) game_mod.Input {
        actions.update(snap);
        const look = mouse.look(snap);
        return .{
            .move_x = actions.value(.right) - actions.value(.left),
            .move_y = actions.value(.forward) - actions.value(.back),
            .look_yaw = look.dx * mouse_turn + (actions.value(.look_right) - actions.value(.look_left)) * key_turn * dt,
            .look_pitch = -look.dy * mouse_turn + (actions.value(.look_up) - actions.value(.look_down)) * key_turn * 0.7 * dt,
            .fire = actions.down(.fire),
            .fire_pressed = actions.pressed(.fire),
            .aim = actions.down(.aim),
            .jump = actions.pressed(.jump),
            .reload = actions.pressed(.reload),
            .lean = (if (actions.down(.lean_right)) @as(f32, 1) else 0) - (if (actions.down(.lean_left)) @as(f32, 1) else 0),
        };
    }

    pub fn tick(host: *demo.Host) !void {
        const dt = host.dt;
        if (!host.deterministic() and !live and anyLiveInput(host.ctx.input())) {
            live = true;
            host.ctx.setCursorMode(.locked);
        }
        const snap = if (live) host.ctx.input() else &host.script_input;
        g.step(dt, readInput(snap, dt));
        ticks += 1;

        // The particles of the tick.
        const light = scene.dustLight();
        const r = fx_rng.random();
        const ev = &g.events;
        for (ev.shots[0..ev.shot_n]) |s| {
            if (s.first) {
                const d = vec.norm(s.e - s.o);
                if (s.bot == null) {
                    // The shot of the player starts at the eye. The flash
                    // is at the muzzle of the gun in the hands.
                    const f = vec.forward(g.you.yaw, g.you.pitch);
                    const right = vec.norm(vec.cross(f, v3(0, 1, 0)));
                    const up = vec.cross(right, f);
                    fx.flash(&particles, r, s.o + f * vec.s(0.85) + right * vec.s(0.12) - up * vec.s(0.1), d, 0.45);
                } else fx.flash(&particles, r, s.o + d * vec.s(0.05), d, 1);
            }
            if (s.surface) |m| {
                if (!s.hit_player) fx.spawn(&particles, r, s.e, s.normal, m, s.snow, if (weapon.gunStats(s.model).pellets > 1) 0.5 else 1, light);
            }
        }
        for (ev.steps[0..ev.step_n]) |p| fx.snowStep(&particles, r, p, light);
        particles.step(dt);

        if (sfx) |*a| {
            a.setListener(g.eye(), vec.forward(g.you.yaw, g.you.pitch));
            a.shots(ev);
        }
    }

    pub fn frame(_: *demo.Host, w: u32, h: u32) !sw_render.FrameUniforms {
        var cam: scene_mod.Camera = .{ .eye = g.eye(), .yaw = g.you.yaw, .pitch = g.you.pitch, .roll = g.roll() };
        if (followCamera()) |c| cam = c;
        const seconds = @as(f64, @floatFromInt(ticks)) / @as(f64, @floatFromInt(demo.tick_hz));
        return scene.frame(w, h, cam, &g, &particles, seconds);
    }

    /// The camera behind and over a bot (`set follow <n>`): it looks at
    /// the bot from the side away from the player.
    fn followCamera() ?scene_mod.Camera {
        if (g.settings.follow < 0) return null;
        const i: usize = @intCast(g.settings.follow);
        if (i >= g.bot_n) return null;
        const b = &g.bots[i];
        const at = (if (b.alive()) b.body.pos else b.rag.centre()) + v3(0, 1.0, 0);
        var away = at - g.you.pos;
        away[1] = 0;
        away = vec.norm(away);
        const side = v3(-away[2], 0, away[0]);
        const eye = at + away * vec.s(3.2) + side * vec.s(1.6) + v3(0, 2.0, 0);
        const d = at - eye;
        return .{ .eye = eye, .yaw = std.math.atan2(-d[0], -d[2]), .pitch = std.math.atan2(d[1], @sqrt(d[0] * d[0] + d[2] * d[2])), .follow = true };
    }

    pub fn statLines(_: *demo.Host, bufs: [][128]u8, out: [][]const u8) usize {
        const st = scene.stats();
        out[0] = std.fmt.bufPrint(&bufs[0], "wave {d}  |  bots {d}/{d}  |  kills {d}  |  particles {d}", .{ g.wave, g.liveBots(), g.bot_n, g.kills, st.particles }) catch "";
        const ms = scene.modelStats();
        out[1] = std.fmt.bufPrint(&bufs[1], "box models: {d} draws, {d} shadow draws, {d} instances, {d} records", .{ ms.draw_calls, ms.shadow_draw_calls, ms.instances, ms.records }) catch "";
        return 2;
    }

    fn rgba(r: u8, gr: u8, b: u8, a: f32) sw_gfx2d.Color {
        return sw_gfx2d.Color.rgba8(r, gr, b, @intFromFloat(std.math.clamp(a, 0, 1) * 255));
    }

    /// Text with a dark shadow, so it reads on the snow (range.zig of the
    /// action game).
    fn shadowed(o: *demo.Overlay, s: []const u8, x: f32, y: f32, size: f32, col: sw_gfx2d.Color) !void {
        _ = try o.text.draw(&o.renderer, s, x + 1.5, y + 1.5, .{ .size = size, .color = .{ .r = 0, .g = 0, .b = 0, .a = 0.6 * col.a } });
        _ = try o.text.draw(&o.renderer, s, x, y, .{ .size = size, .color = col });
    }

    pub fn drawOverlay(host: *demo.Host, o: *demo.Overlay) !void {
        const r = &o.renderer;
        const w: f32 = @floatFromInt(host.gpu.getSurfaceWidth());
        const h: f32 = @floatFromInt(host.gpu.getSurfaceHeight());
        const k = h / 540.0;
        const cx = w / 2;
        const cy = h / 2;
        var buf: [64]u8 = undefined;

        // The red edge of a hit, strong at once and then fading.
        if (g.hurt < 0.6) {
            const a = 0.45 * (1 - g.hurt / 0.6);
            const e = 40 * k;
            try r.fillRect(.{ .x = 0, .y = 0, .w = w, .h = e }, rgba(200, 20, 10, a));
            try r.fillRect(.{ .x = 0, .y = h - e, .w = w, .h = e }, rgba(200, 20, 10, a));
            try r.fillRect(.{ .x = 0, .y = e, .w = e, .h = h - 2 * e }, rgba(200, 20, 10, a));
            try r.fillRect(.{ .x = w - e, .y = e, .w = e, .h = h - 2 * e }, rgba(200, 20, 10, a));
        }
        // The camera follows a bot: no HUD of the player.
        if (g.settings.follow >= 0) return;
        if (!g.alive()) {
            try r.fillRect(.{ .x = 0, .y = 0, .w = w, .h = h }, rgba(60, 0, 0, 0.45));
            const s = "DOWN - BACK IN A MOMENT";
            const m = o.text.measure(s, 30 * k);
            try shadowed(o, s, cx - m.w / 2, cy - m.h / 2, 30 * k, rgba(255, 235, 220, 1));
            return;
        }

        // The crosshair: four ticks that open with the cone of the gun.
        const st = weapon.statsOf(g.item);
        const sp = @sqrt(g.you.vel[0] * g.you.vel[0] + g.you.vel[2] * g.you.vel[2]);
        const cone = g.hands.spread(st, @min(1, sp / 6.4), !g.you.grounded);
        const gap = (4 + cone * 700) * k * (1 - 0.7 * g.hands.ads);
        const len = 7 * k;
        const t = 2 * k;
        const ch = rgba(245, 245, 240, 0.9 * (1 - 0.8 * g.hands.ads));
        try r.fillRect(.{ .x = cx - gap - len, .y = cy - t / 2, .w = len, .h = t }, ch);
        try r.fillRect(.{ .x = cx + gap, .y = cy - t / 2, .w = len, .h = t }, ch);
        try r.fillRect(.{ .x = cx - t / 2, .y = cy - gap - len, .w = t, .h = len }, ch);
        try r.fillRect(.{ .x = cx - t / 2, .y = cy + gap, .w = t, .h = len }, ch);
        // The hit marker.
        if (g.marker > 0) {
            const a = g.marker / 0.18;
            const m = 10 * k;
            try r.fillRect(.{ .x = cx - m, .y = cy - m, .w = 5 * k, .h = 5 * k }, rgba(255, 80, 60, a));
            try r.fillRect(.{ .x = cx + m - 5 * k, .y = cy - m, .w = 5 * k, .h = 5 * k }, rgba(255, 80, 60, a));
            try r.fillRect(.{ .x = cx - m, .y = cy + m - 5 * k, .w = 5 * k, .h = 5 * k }, rgba(255, 80, 60, a));
            try r.fillRect(.{ .x = cx + m - 5 * k, .y = cy + m - 5 * k, .w = 5 * k, .h = 5 * k }, rgba(255, 80, 60, a));
        }
        // The damage numbers: red for the body, gold for the head.
        for (g.numbers[0..g.number_n], 0..) |n, i| {
            const a = std.math.clamp((1.3 - n.age) / 0.4, 0, 1);
            const size: f32 = (if (n.head) @as(f32, 22) else 18) * k;
            const col = if (n.head) sw_gfx2d.Color{ .r = 1, .g = 0.82, .b = 0.25, .a = a } else sw_gfx2d.Color{ .r = 0.95, .g = 0.25, .b = 0.2, .a = a };
            const s = std.fmt.bufPrint(&buf, "-{d:.0}{s}{s}", .{ n.dmg, if (n.head) " HEAD" else "", if (n.kill) " KILL" else "" }) catch "";
            try shadowed(o, s, cx + 24 * k, cy - (36 + 22 * @as(f32, @floatFromInt(i)) + n.age * 12) * k, size, col);
        }

        // The health bar at the bottom left, and the ammo at the right.
        const bx = 22 * k;
        const by = h - 128 * k;
        const bw = 170 * k;
        const hpk = std.math.clamp(g.hp / game_mod.max_hp, 0, 1);
        try r.fillRect(.{ .x = bx - 2 * k, .y = by - 2 * k, .w = bw + 4 * k, .h = 14 * k }, rgba(0, 0, 0, 0.6));
        const hc = if (hpk > 0.5) rgba(90, 220, 110, 1) else if (hpk > 0.25) rgba(240, 200, 60, 1) else rgba(235, 70, 55, 1);
        try r.fillRect(.{ .x = bx, .y = by, .w = bw * hpk, .h = 10 * k }, hc);
        try shadowed(o, std.fmt.bufPrint(&buf, "{d:.0} HP", .{@ceil(g.hp)}) catch "", bx, by - 24 * k, 18 * k, rgba(245, 240, 232, 1));
        var lb: [32]u8 = undefined;
        const ammo = if (g.hands.reloading >= 0) "RELOADING" else std.fmt.bufPrint(&buf, "{d} / {d}", .{ g.item.ammo, st.mag }) catch "";
        const am = o.text.measure(ammo, 22 * k);
        try shadowed(o, ammo, w - am.w - 22 * k, by - 10 * k, 22 * k, rgba(245, 240, 232, 1));
        const gl = weapon.label(&lb, g.item.model);
        const gm = o.text.measure(gl, 13 * k);
        try shadowed(o, gl, w - gm.w - 22 * k, by - 28 * k, 13 * k, rgba(200, 205, 215, 1));

        // The health bars over the bots that the player can see.
        for (g.bots[0..g.bot_n]) |*b| {
            if (!b.alive()) continue;
            const top = b.body.pos + v3(0, 2.05, 0);
            if (!arena.clear(g.eye(), top)) continue;
            const p = scene.project(top, host.gpu.getSurfaceWidth(), host.gpu.getSurfaceHeight()) orelse continue;
            const bk = std.math.clamp(b.hp / game_mod.max_hp, 0, 1);
            const ww = 40 * k;
            try r.fillRect(.{ .x = p[0] - ww / 2 - 1, .y = p[1] - 1, .w = ww + 2, .h = 6 * k + 2 }, rgba(0, 0, 0, 0.6));
            try r.fillRect(.{ .x = p[0] - ww / 2, .y = p[1], .w = ww * bk, .h = 6 * k }, rgba(235, 70, 55, 0.95));
        }
        if (!host.deterministic() and !live) {
            const s = "Press a key, click or press a gamepad button to play";
            const m = o.text.measure(s, 14 * k);
            try shadowed(o, s, w - m.w - 16 * k, 14 * k, 14 * k, rgba(255, 244, 214, 0.9));
        }
    }

    pub fn deinit(host: *demo.Host) void {
        if (sfx) |*a| a.deinit();
        sfx = null;
        scene.deinit();
        particles.deinit(host.allocator);
        for (weapon.models) |m| host.allocator.free(m.verts);
        host.allocator.free(weapon.models);
        weapon.models = &.{};
    }
};

test {
    _ = builtin;
}
