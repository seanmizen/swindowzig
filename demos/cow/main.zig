// cow - a voxel cow turns on a stand while the settings change one at a
// time. A caption names each change. The top left shows the frame time,
// the frame-time chart, the quad count of the cow and the settings.
//
// The demo plays `cow.tas`, which presses one key for each change: the
// anti-aliasing (off, FXAA, MSAA), the meshing (naive, then greedy, with a
// wireframe), the tonemap curve, the exposure, a palette swap, the time of
// day, the shadows, the AO, the fog and the sky. The script runs again at
// its end. Escape stops the script, and the keys are then yours:
//
//   1 anti-aliasing   2 meshing   3 wireframe   4 tonemap curve
//   5 exposure down   6 exposure up   7 palette   T (hold) time of day
//   8 shadows   9 AO   0 fog   K sky   Space stop or start the turn
//
// Native flags: see demos/common/run.zig. `--check` plays the script with
// no window and checks that each setting changed, that the greedy mesh has
// fewer quads than the naive mesh, and that each change changed the frame
// (REQ-DEMO-001).
const std = @import("std");
const builtin = @import("builtin");
const sw = @import("sw_app");
const gfx = @import("sw_gfx2d");
const demo = @import("demo_common");

const run = demo.run;
const cow_scene = demo.cow_scene;

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
    .title = "cow",
    .size = .{ .w = 1280, .h = 720 },
    .tick_hz = tick_hz,
    .surface_follows_window = true,
};

const script_source = @embedFile("cow.tas");

var options: run.Options = .{};

fn mainNative(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    options = run.parseArgs(args) catch |err| {
        std.log.err("cow: {s}. {s}", .{ @errorName(err), run.usage });
        std.process.exit(2);
    };
    var c = config;
    c.io = init.io;
    run.configure(options, &c);
    try sw.run(c, Callbacks);
}

var scene: ?*cow_scene.Scene = null;
var player: ?run.Player = null;
var frames: run.Frames = .{ .options = .{} };
var settings: cow_scene.Settings = .{};
var turning = true;
/// The caption of the last change.
var caption_buf: [96]u8 = undefined;
var caption: []const u8 = "";
/// The script runs until a key press of the player.
var scripted = true;

// The check: each setting that the script must change, and the frame hash
// before and after each change.
const Changed = struct {
    aa_off: bool = false,
    aa_fxaa: bool = false,
    aa_msaa: bool = false,
    naive: bool = false,
    wireframe: bool = false,
    curves: [3]bool = .{ false, false, false },
    exposure: bool = false,
    palette: bool = false,
    time: bool = false,
    shadows_off: bool = false,
    ao_off: bool = false,
    fog_off: bool = false,
    sky: bool = false,
};
var changed: Changed = .{};

fn setCaption(comptime fmt: []const u8, args: anytype) void {
    caption = std.fmt.bufPrint(&caption_buf, fmt, args) catch "";
}

/// One key: one change of one setting.
fn applyKeys(ctx: *sw.Context) !void {
    const in = ctx.input();
    var s = settings;
    if (in.keyPressed(.Num1)) {
        s.aa = switch (s.aa) {
            .off => .fxaa,
            .fxaa => .msaa,
            .msaa => .off,
        };
        setCaption("Anti-aliasing: {s}", .{switch (s.aa) {
            .off => "off",
            .fxaa => "FXAA (post effect)",
            .msaa => "MSAA, 4 samples",
        }});
        switch (s.aa) {
            .off => changed.aa_off = true,
            .fxaa => changed.aa_fxaa = true,
            .msaa => changed.aa_msaa = true,
        }
    }
    if (in.keyPressed(.Num2)) {
        s.meshing = if (s.meshing == .greedy) .naive else .greedy;
        if (s.meshing == .naive) changed.naive = true;
        setCaption("Meshing: {s}", .{if (s.meshing == .greedy) "greedy (merged faces)" else "naive (one quad for each face)"});
    }
    if (in.keyPressed(.Num3)) {
        s.wireframe = !s.wireframe;
        if (s.wireframe) changed.wireframe = true;
        setCaption("Wireframe: {s}", .{if (s.wireframe) "on" else "off"});
    }
    if (in.keyPressed(.Num4)) {
        s.curve = switch (s.curve) {
            .clamp => .reinhard,
            .reinhard => .aces,
            .aces => .clamp,
        };
        changed.curves[@backingInt(s.curve)] = true;
        setCaption("Tonemap: {s}", .{cow_scene.curve_names[@backingInt(s.curve)]});
    }
    if (in.keyPressed(.Num5) or in.keyPressed(.Num6)) {
        s.exposure = std.math.clamp(if (in.keyPressed(.Num6)) s.exposure * 1.5 else s.exposure / 1.5, 0.2, 5);
        changed.exposure = true;
        setCaption("Exposure: {d:.2}", .{s.exposure});
    }
    if (in.keyPressed(.Num7)) {
        s.palette = @intCast((s.palette + 1) % demo.cow.palettes.len);
        changed.palette = true;
        setCaption("Palette: {s}", .{demo.cow.palette_names[s.palette]});
    }
    if (in.keyDown(.T)) {
        s.time = @mod(s.time + 0.25 / @as(f32, tick_hz), 1.0);
        changed.time = true;
        var b: [8]u8 = undefined;
        setCaption("Time of day: {s}", .{cow_scene.clock(&b, s.time)});
    }
    if (in.keyPressed(.Num8)) {
        s.shadows = !s.shadows;
        if (!s.shadows) changed.shadows_off = true;
        setCaption("Shadows: {s}", .{if (s.shadows) "on" else "off"});
    }
    if (in.keyPressed(.Num9)) {
        s.ao = !s.ao;
        if (!s.ao) changed.ao_off = true;
        setCaption("Ambient occlusion: {s}", .{if (s.ao) "on" else "off"});
    }
    if (in.keyPressed(.Num0)) {
        s.fog = !s.fog;
        if (!s.fog) changed.fog_off = true;
        setCaption("Fog: {s}", .{if (s.fog) "on" else "off"});
    }
    if (in.keyPressed(.K)) {
        s.sky = if (s.sky == .day) .violet else .day;
        changed.sky = true;
        setCaption("Sky: {s}", .{if (s.sky == .day) "day palette" else "violet palette"});
    }
    if (in.keyPressed(.Space)) turning = !turning;
    if (!std.meta.eql(s, settings)) {
        settings = s;
        if (scene) |sc| try sc.apply(s);
    }
}

fn drawHud(_: ?*anyopaque, o: *demo.overlay.Overlay) anyerror!void {
    const sc = scene orelse return;
    const white = gfx.Color.rgba8(240, 240, 240, 255);
    const grey = gfx.Color.rgba8(190, 190, 200, 255);
    try o.renderer.fillRect(.{ .x = 8, .y = 8, .w = 330, .h = 150 }, gfx.Color.rgba8(0, 0, 0, 140));
    try o.chart(14, 14);
    try o.print(184, 14, 16, white, "{d:.1} ms", .{o.frameMs()});
    try o.print(184, 34, 14, grey, "preset {s}", .{@tagName(options.preset)});
    const s = sc.settings;
    try o.print(14, 62, 16, white, "cow quads: {d} ({s})", .{ sc.quadCount(), @tagName(s.meshing) });
    try o.print(14, 82, 14, grey, "AA {s}   tonemap {s}   exposure {d:.2}", .{ @tagName(s.aa), cow_scene.curve_names[@backingInt(s.curve)], s.exposure });
    var b: [8]u8 = undefined;
    try o.print(14, 100, 14, grey, "time {s}   shadows {s}   AO {s}", .{ cow_scene.clock(&b, s.time), onOff(s.shadows), onOff(s.ao) });
    try o.print(14, 118, 14, grey, "fog {s}   sky {s}   draw calls {d}", .{ onOff(s.fog), @tagName(s.sky), sc.drawCalls() });
    try o.print(14, 136, 12, grey, "{s}", .{if (scripted) "script: cow.tas (Escape: stop it)" else "keys: 1-9, 0, T, K, Space"});
    if (caption.len > 0) try o.caption(caption);
}

fn onOff(b: bool) []const u8 {
    return if (b) "on" else "off";
}

const Callbacks = struct {
    pub fn init(ctx: *sw.Context) !void {
        const gpu = ctx.gpu();
        if (!gpu.isReady()) return;
        const allocator = ctx.allocator();
        frames = .{ .options = options };
        settings = cow_scene.Settings.fromGraphics(run.graphics(options.preset));
        scene = try cow_scene.Scene.create(allocator, gpu, settings, options.offline(), null, drawHud);
        const source = try run.loadScript(ctx, options, script_source);
        player = try run.Player.init(allocator, source, tick_hz);
        std.log.info("cow: GPU ready. {d} naive quads, {d} greedy quads with AO.", .{ scene.?.quads[0][1], scene.?.quads[1][1] });
    }

    pub fn preTick(ctx: *sw.Context) !void {
        if (!scripted) return;
        if (player) |*p| try p.feed(ctx);
    }

    pub fn tick(ctx: *sw.Context) !void {
        const sc = scene orelse return;
        // Escape stops the script and gives the keys to the player.
        if (ctx.input().keyPressed(.Escape)) scripted = false;
        try applyKeys(ctx);
        if (turning) sc.step(1.0 / @as(f32, tick_hz));
        if (player) |*p| {
            if (scripted and p.done(ctx.tickId())) {
                if (options.offline()) {
                    // The frame of the last tick is the last frame.
                } else {
                    // Play the tour again from the default settings.
                    p.restart();
                    settings = cow_scene.Settings.fromGraphics(run.graphics(options.preset));
                    try sc.apply(settings);
                    sc.angle = 0;
                    caption = "";
                }
            }
        }
    }

    pub fn render(ctx: *sw.Context) !void {
        const gpu = ctx.gpu();
        if (!gpu.isReady()) return;
        const sc = scene orelse return;
        const p = &player.?;
        const t = p.tasTick(ctx.tickId());
        if (frames.wanted(t) and try sc.render(ctx)) {
            try frames.frame(ctx, t);
            if (options.check) checkFrame(t);
            gpu.present();
        }
        if (options.offline() and p.done(ctx.tickId())) finishOffline(ctx);
    }

    pub fn shutdown(ctx: *sw.Context) !void {
        if (scene) |sc| sc.destroy();
        scene = null;
        if (player) |*p| p.deinit();
        player = null;
        frames.hashes.deinit(ctx.allocator());
    }
};

var last_hash: ?u64 = null;
var hash_changes: u32 = 0;

fn checkFrame(t: u64) void {
    const items = frames.hashes.items;
    if (items.len == 0 or items[items.len - 1].tick != t) return;
    const h = items[items.len - 1].hash;
    if (last_hash) |l| {
        if (l != h) hash_changes += 1;
    }
    last_hash = h;
}

fn finishOffline(ctx: *sw.Context) noreturn {
    var ok = true;
    if (options.check) {
        const c = changed;
        const all = [_]struct { bool, []const u8 }{
            .{ c.aa_off, "anti-aliasing off" },
            .{ c.aa_fxaa, "FXAA" },
            .{ c.aa_msaa, "MSAA" },
            .{ c.naive, "naive meshing" },
            .{ c.wireframe, "wireframe" },
            .{ c.curves[0] and c.curves[1] and c.curves[2], "each tonemap curve" },
            .{ c.exposure, "exposure" },
            .{ c.palette, "palette swap" },
            .{ c.time, "time of day" },
            .{ c.shadows_off, "shadows off" },
            .{ c.ao_off, "AO off" },
            .{ c.fog_off, "fog off" },
            .{ c.sky, "sky" },
        };
        for (all) |a| {
            if (!a[0]) {
                std.log.err("cow: the script did not change: {s}", .{a[1]});
                ok = false;
            }
        }
        const sc = scene.?;
        if (sc.quads[1][1] * 2 >= sc.quads[0][1]) {
            std.log.err("cow: the greedy mesh has {d} quads, the naive mesh {d}", .{ sc.quads[1][1], sc.quads[0][1] });
            ok = false;
        }
        // The cow turns, so most checkpoint frames differ from the one
        // before. A frame that does not change shows a broken render.
        const n: u32 = @intCast(frames.hashes.items.len);
        if (n < 10 or hash_changes + 2 < n - 1) {
            std.log.err("cow: only {d} of {d} checkpoint frames changed", .{ hash_changes, n });
            ok = false;
        }
        std.log.info("cow: check {s}", .{if (ok) "passed" else "FAILED"});
    }
    run.exitOffline(ctx, &frames, "cow", if (ok) 0 else 1);
}
