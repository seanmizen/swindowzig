// shooter - a first-person shootout in a snowy arena, offline. Bots move
// between cover points, crouch, stand up and fire back. There is no
// network code.
//
// The scene uses the engine: falling snow that stops on the crates
// (sw_render Precipitation with a height map), a moving cloud layer, the
// fog and the sky, cascaded shadows, particles (the muzzle flash, the
// tracers, the impacts, the sparks on a bot, the snow under the feet), a
// point light at each muzzle flash, 3D gun sound (sw_audio), box models
// for the bots, collision with the boxes of the arena, the first-person
// camera of sw_math, and the input actions of sw_core with a gamepad.
//
// The gun models come from guns.bin (the Quaternius "Ultimate Gun Pack",
// CC0). The impact sounds come from the modal synthesis in `audio/`. Both
// are from Sean's own game code (seanorepo apps/action).
//
// Keys: W A S D or the left stick move. The mouse or the right stick
// looks (click the window to lock the mouse). The left mouse button or
// the right trigger fires. R or west reloads. Space or south jumps.
// Escape unlocks the mouse.
//
// The demo plays `shooter.tas` with no window (`--capture`, `--hashes`,
// `--check`). In a window it gives the control to the player. The bots
// use a seeded random number generator on the fixed timestep, so a replay
// gives the same fight (REQ-DEMO-001). `--check` checks that the player
// fired and hit a bot, that the bots fired back and hit the player, and
// that the particles and the snow drew.
const std = @import("std");
const builtin = @import("builtin");
const sw = @import("sw_app");
const gfx = @import("sw_gfx2d");
const sw_math = @import("sw_math");
const sw_render = @import("sw_render");
const sw_audio = @import("sw_audio");
const demo = @import("demo_common");
const arena = @import("arena.zig");
const bots_mod = @import("bots.zig");
const guns = @import("guns.zig");
const impact = @import("audio/impact.zig");
const dsp = @import("audio/dsp.zig");

const run = demo.run;
const mesh = demo.mesh;
const sound = demo.sound;
const Mat4 = sw_math.Mat4;
const Quat = sw_math.Quat;
const Vec3 = sw_math.Vec3;
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
const dt: f32 = 1.0 / @as(f32, tick_hz);
const config: sw.Config = .{
    .title = "shooter",
    .size = .{ .w = 1280, .h = 720 },
    .tick_hz = tick_hz,
    .surface_follows_window = true,
};

const script_source = @embedFile("shooter.tas");

var options: run.Options = .{};

fn mainNative(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    options = run.parseArgs(args) catch |err| {
        std.log.err("shooter: {s}. {s}", .{ @errorName(err), run.usage });
        std.process.exit(2);
    };
    var c = config;
    c.io = init.io;
    run.configure(options, &c);
    try sw.run(c, Callbacks);
}

// =============================================================================
// The input actions
// =============================================================================

const Action = enum { forward, back, left, right, jump, fire, reload };
var actions = sw.core_types.ActionMap(Action).init(.{
    .forward = &.{ Binding.key(.W), Binding.gamepadAxis(.left_y, false) },
    .back = &.{ Binding.key(.S), Binding.gamepadAxis(.left_y, true) },
    .left = &.{ Binding.key(.A), Binding.gamepadAxis(.left_x, false) },
    .right = &.{ Binding.key(.D), Binding.gamepadAxis(.left_x, true) },
    .jump = &.{ Binding.key(.Space), Binding.gamepadButton(.south) },
    .fire = &.{ Binding.mouse(.left), Binding.gamepadAxis(.right_trigger, true) },
    .reload = &.{ Binding.key(.R), Binding.gamepadButton(.west) },
});

// =============================================================================
// The state
// =============================================================================

const bot_count = 4;
const mag_size = 30;
const fire_interval: f32 = 0.1;
const reload_time: f32 = 1.8;
const eye_height: f32 = 1.62;
const start: [3]f32 = .{ 0, 0, 17 };

const Player = struct {
    body: arena.Body = .{ .pos = start },
    health: f32 = 100,
    since_hurt: f32 = 10,
    ammo: u32 = mag_size,
    reserve: u32 = 150,
    reload: f32 = 0,
    cooldown: f32 = 0,
    kick: f32 = 0,
    flash: f32 = 0,
    hit_marker: f32 = 0,
    hurt_flash: f32 = 0,
};

const Stats = struct {
    shots: u32 = 0,
    bot_hits: u32 = 0,
    bot_kills: u32 = 0,
    bot_shots: u32 = 0,
    player_hits: u32 = 0,
    deaths: u32 = 0,
    max_particles: usize = 0,
    gamepad_moves: u32 = 0,
    jumps: u32 = 0,
    reloads: u32 = 0,
};

var player: Player = .{};
var stats: Stats = .{};
var bots: [bot_count]bots_mod.Bot = undefined;
var events: std.ArrayList(bots_mod.Event) = .empty;
var rng = run.Rng.init(0x5A0);
var camera: sw_math.camera.Controller = .init(.{ .fov = 70 * std.math.pi / 180.0, .near = 0.05, .far = 400 });
var cam_out: ?sw_math.camera.Output = null;
var seconds: f64 = 0;
var flashes: [4]struct { pos: [3]f32, life: f32 } = @splat(.{ .pos = .{ 0, 0, 0 }, .life = 0 });

var tas: ?run.Player = null;
var frames: run.Frames = .{ .options = .{} };
var graphics: sw_render.GraphicsSettings = .{};

// The render objects.
var graph: ?sw_render.FrameGraph = null;
var post: ?sw_render.PostChain = null;
var sky: ?sw_render.Sky = null;
var lighting: ?sw_render.Lighting = null;
var clouds: ?sw_render.Clouds = null;
var snow: ?sw_render.Precipitation = null;
var particles: ?sw_render.Particles = null;
var system: ?sw_render.ParticleSystem = null;
var models: ?sw_render.BoxModels = null;
var meshes: ?mesh.Renderer = null;
var overlay: ?*demo.overlay.Overlay = null;
var bot_model: sw_render.BoxModelId = undefined;
var arena_mesh: mesh.MeshId = undefined;
var rifle_mesh: mesh.MeshId = undefined;
var smg_mesh: mesh.MeshId = undefined;
var rifle: guns.Model = undefined;
var smg: guns.Model = undefined;

// The sounds.
var audio: ?sw_audio.Audio = null;
var shot_sample: ?sw_audio.Sample = null;
var bot_shot_sample: ?sw_audio.Sample = null;
var impact_samples: [5]?sw_audio.Sample = @splat(null);
var wind_sample: ?sw_audio.Sample = null;

const fog: sw_render.Fog = .{ .start = 12, .end = 70, .max = 0.9 };
const winter_palette: sw_render.SkyPalette = .{
    .day_zenith = .{ 0.30, 0.40, 0.55 },
    .day_horizon = .{ 0.75, 0.80, 0.86 },
    .twilight = .{ 0.85, 0.60, 0.50 },
};

// =============================================================================
// The arena mesh and the cloud shape
// =============================================================================

fn buildArena(allocator: std.mem.Allocator) ![]mesh.Vertex {
    var b = mesh.Builder.init(allocator);
    errdefer b.deinit();
    // The snow: a large ground, a little blue, with low drifts.
    try b.box(.{ -80, -0.3, -80 }, .{ 80, 0, 80 }, arena.color(.snow));
    var r = run.Rng.init(99);
    for (0..40) |_| {
        const x = r.range(-21, 21);
        const z = r.range(-21, 21);
        const w = r.range(0.6, 1.8);
        const p: [3]f32 = .{ x, 0, z };
        if (!arena.inside(p)) continue;
        try b.box(.{ x - w, 0, z - w * 0.6 }, .{ x + w, r.range(0.05, 0.15), z + w * 0.6 }, .{ 0.88, 0.91, 0.96 });
    }
    for (arena.boxes) |bx| {
        try b.box(bx.min, bx.max, arena.color(bx.material));
        // Snow on the top.
        if (bx.material != .metal) try b.box(.{ bx.min[0] - 0.02, bx.max[1], bx.min[2] - 0.02 }, .{ bx.max[0] + 0.02, bx.max[1] + 0.06, bx.max[2] + 0.02 }, .{ 0.9, 0.93, 0.97 });
    }
    // Pines outside the walls, in the fog.
    for (0..48) |i| {
        const a = @as(f32, @floatFromInt(i)) / 48 * std.math.tau + r.range(0, 0.1);
        const d = r.range(28, 45);
        const x = d * @cos(a);
        const z = d * @sin(a);
        const h = r.range(4, 8);
        try b.box(.{ x - 0.25, 0, z - 0.25 }, .{ x + 0.25, h * 0.3, z + 0.25 }, .{ 0.20, 0.13, 0.08 });
        for (0..3) |k| {
            const kk: f32 = @floatFromInt(k);
            const w = (1.6 - kk * 0.45) * h / 6;
            const y0 = h * (0.25 + kk * 0.22);
            try b.box(.{ x - w, y0, z - w }, .{ x + w, y0 + h * 0.3, z + w }, .{ 0.08, 0.20, 0.12 });
        }
    }
    const v = try allocator.dupe(mesh.Vertex, b.items());
    b.deinit();
    return v;
}

const shape_size = 64;
var shape_pixels: [shape_size * shape_size * 4]u8 = undefined;

fn makeShape() void {
    var r = run.Rng.init(31);
    var cells: [shape_size * shape_size]f32 = undefined;
    for (&cells) |*c| c.* = r.float();
    // Two blur passes make blobs.
    for (0..2) |_| {
        var next: [shape_size * shape_size]f32 = undefined;
        for (0..shape_size) |y| for (0..shape_size) |x| {
            var s: f32 = 0;
            for ([_]i32{ -1, 0, 1 }) |dy| for ([_]i32{ -1, 0, 1 }) |dx| {
                const xx: usize = @intCast(@mod(@as(i32, @intCast(x)) + dx, shape_size));
                const yy: usize = @intCast(@mod(@as(i32, @intCast(y)) + dy, shape_size));
                s += cells[yy * shape_size + xx];
            };
            next[y * shape_size + x] = s / 9;
        };
        cells = next;
    }
    for (cells, 0..) |c, i| shape_pixels[i * 4 ..][0..4].* = .{ 235, 238, 245, if (c > 0.52) 255 else 0 };
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
        graphics = run.graphics(options.preset);
        for (&bots, 0..) |*b, i| b.* = bots_mod.Bot.init(i);
        arena.buildHeightMap();
        makeShape();

        graph = try sw_render.FrameGraph.init(allocator, gpu, .{});
        const g = &graph.?;
        post = try sw_render.PostChain.init(allocator, g, .{ .fxaa = if (graphics.anti_aliasing == .fxaa) graphics.fxaa_quality else null });
        const p = &post.?;
        sky = try sw_render.Sky.init(allocator, g, p.hdr, .{ .time = 0.40, .fog = fog, .settings = .{ .palette = winter_palette } });
        lighting = try sw_render.Lighting.init(allocator, g, .{
            .cascades = graphics.shadow_cascades,
            .map_size = graphics.shadow_map_size,
            .shadows = .{ .enabled = graphics.shadows, .distance = 45 },
        });
        const depth = try g.addTarget(.{ .name = "depth", .format = .depth24plus, .usage = .{ .render_attachment = true } });
        try g.addPass(.{
            .name = "scene",
            .attachments = .{ .colors = &.{.{ .target = p.hdr, .load_op = .load }}, .depth = .{ .target = depth } },
            .callback = .plain(drawScene),
        });
        models = try sw_render.BoxModels.init(allocator, g, .{ .color_format = p.hdr_format, .lighting = lighting.? });
        bot_model = try models.?.addModel(.{ .parts = &bots_mod.parts });
        meshes = try mesh.Renderer.init(allocator, g, .{ .color_format = p.hdr_format, .lighting = lighting.? });
        const m = &meshes.?;
        const arena_vertices = try buildArena(allocator);
        defer allocator.free(arena_vertices);
        arena_mesh = try m.addMesh(arena_vertices, .triangles);
        rifle = try guns.load(allocator, "AssaultRifle_1");
        smg = try guns.load(allocator, "SubmachineGun_2");
        rifle_mesh = try m.addMesh(rifle.vertices, .triangles);
        smg_mesh = try m.addMesh(smg.vertices, .triangles);
        try m.addFirstPersonPass(p.hdr, 70);

        clouds = try sw_render.Clouds.init(allocator, g, p.hdr, .{
            .depth = depth,
            .shape = .{ .width = shape_size, .height = shape_size, .pixels = &shape_pixels },
            .settings = .{ .bottom = 60, .thickness = 6, .cell_size = 10, .wind = .{ 2.5, 0.8 }, .color = .{ 0.92, 0.94, 0.98 }, .soft = true },
        });
        system = try sw_render.ParticleSystem.init(allocator, 2048);
        particles = try sw_render.Particles.init(allocator, g, .{ .color_format = p.hdr_format, .capacity = 2048 });
        try particles.?.addPass(.{ .color = p.hdr, .depth = depth });
        snow = try sw_render.Precipitation.init(allocator, g, p.hdr, .{ .depth = depth, .settings = .{ .count = if (options.preset == .low) 5000 else 12000, .radius = 22, .fall_speed = 1.4, .wind = .{ 0.6, 0.2 } } });
        try snow.?.setHeightMap(arena.heightMap());
        overlay = try demo.overlay.Overlay.create(allocator, g, options.offline(), null, drawHud);

        if (!options.offline()) {
            audio = sw_audio.Audio.init();
            shot_sample = try sound.shot(allocator, 11, 0.25);
            bot_shot_sample = try sound.shot(allocator, 23, 0.15);
            wind_sample = try sound.wind(allocator, 8);
            var r = dsp.Rng.init(5);
            const mats = [_]impact.Material{ .earth, .wood, .concrete, .metal, .sheet_metal };
            for (mats, 0..) |mt, i| {
                const buf = try allocator.alloc(f32, @intFromFloat(dsp.rate * 0.7));
                const n = impact.strike(buf, mt, 1.0, &r);
                impact_samples[i] = .{ .data = try allocator.realloc(buf, @max(n, 1)), .channels = 1, .rate = @intFromFloat(dsp.rate) };
            }
            if (audio) |*a| {
                _ = a.playSample(&wind_sample.?, .{ .group = sound.group_ambience, .looping = true, .volume = 0.35 });
                a.setGroupVolume(sound.group_weapons, 0.9);
            }
        }

        const source = try run.loadScript(ctx, options, script_source);
        tas = try run.Player.init(allocator, source, tick_hz);
        camera.setTarget(eyeVec());
        std.log.info("shooter: GPU ready. {d} bots. Rifle {d} triangles, muzzle {any}.", .{ bot_count, rifle.vertices.len / 3, rifle.muzzle });
    }

    pub fn preTick(ctx: *sw.Context) !void {
        if (!options.offline() and options.tas_path == null) return;
        if (tas) |*t| try t.feed(ctx);
    }

    pub fn tick(ctx: *sw.Context) !void {
        if (graph == null) return;
        try gameTick(ctx);
    }

    pub fn render(ctx: *sw.Context) !void {
        const gpu = ctx.gpu();
        if (!gpu.isReady()) return;
        if (graph == null) return;
        const t = tas.?.tasTick(ctx.tickId());
        if (frames.wanted(t) and try renderFrame(ctx)) {
            try frames.frame(ctx, t);
            gpu.present();
        }
        if (options.offline() and tas.?.done(ctx.tickId())) finishOffline(ctx);
    }

    pub fn shutdown(ctx: *sw.Context) !void {
        const allocator = ctx.allocator();
        if (audio) |*a| a.stopAll();
        if (overlay) |o| o.destroy();
        if (snow) |*s| s.deinit();
        if (particles) |*s| s.deinit();
        if (system) |*s| s.deinit(allocator);
        if (clouds) |*c| c.deinit();
        if (meshes) |*m| m.deinit();
        if (models) |*m| m.deinit();
        if (lighting) |*l| l.deinit();
        if (sky) |*s| s.deinit();
        if (post) |*p| p.deinit();
        if (graph) |*g| g.deinit();
        graph = null;
        if (meshes != null) {
            allocator.free(rifle.vertices);
            allocator.free(smg.vertices);
        }
        for ([_]*?sw_audio.Sample{ &shot_sample, &bot_shot_sample, &wind_sample, &impact_samples[0], &impact_samples[1], &impact_samples[2], &impact_samples[3], &impact_samples[4] }) |s| {
            if (s.*) |*v| sound.free(allocator, v);
            s.* = null;
        }
        events.deinit(allocator);
        if (tas) |*t| t.deinit();
        frames.hashes.deinit(allocator);
    }
};

// =============================================================================
// The game
// =============================================================================

fn eye() [3]f32 {
    const p = player.body.pos;
    return .{ p[0], p[1] + eye_height, p[2] };
}

fn eyeVec() Vec3 {
    return arena.v3(eye());
}

fn horizontalSpeed() f32 {
    const v = player.body.vel;
    return @sqrt(v[0] * v[0] + v[2] * v[2]);
}

fn gameTick(ctx: *sw.Context) !void {
    const allocator = ctx.allocator();
    const in = ctx.input();
    seconds += dt;
    actions.update(in);

    // The mouse locks on a click in a window. Escape unlocks it.
    if (!options.offline()) {
        if (in.buttonPressed(.left) and !ctx.isCursorLocked()) ctx.setCursorMode(.locked);
        if (in.keyPressed(.Escape)) ctx.setCursorMode(.normal);
    }

    // Look: the mouse, and the right stick at 180 pixels each second.
    var look = actions.mouse.look(in);
    for (&in.gamepads) |*gp| {
        const s = gp.stick(.right, actions.gamepad);
        look.dx += s.x * 600 * dt;
        look.dy += s.y * 400 * dt;
    }
    camera.setTarget(eyeVec());
    const w: f32 = @floatFromInt(@max(ctx.gpu().getSurfaceWidth(), 1));
    const h: f32 = @floatFromInt(@max(ctx.gpu().getSurfaceHeight(), 1));
    cam_out = camera.update(.{ .look = .{ .x = look.dx, .y = look.dy }, .aspect = w / h }, dt, null);

    // Move on the ground, relative to the view.
    const fwd = sw_math.camera.Controller.forwardOf(camera.yaw, 0);
    const right: [2]f32 = .{ -fwd.z, fwd.x };
    const mf = actions.value(.forward) - actions.value(.back);
    const mr = actions.value(.right) - actions.value(.left);
    for (&in.gamepads) |*gp| {
        const s = gp.stick(.left, actions.gamepad);
        if (@abs(s.x) + @abs(s.y) > 0.1) stats.gamepad_moves += 1;
    }
    const speed: f32 = 4.5;
    var vx = (fwd.x * mf + right[0] * mr) * speed;
    var vz = (fwd.z * mf + right[1] * mr) * speed;
    const l = @sqrt(vx * vx + vz * vz);
    if (l > speed) {
        vx = vx / l * speed;
        vz = vz / l * speed;
    }
    player.body.vel[0] = vx;
    player.body.vel[2] = vz;
    if (actions.pressed(.jump) and player.body.on_ground) {
        player.body.vel[1] = 6;
        stats.jumps += 1;
        snowPuff(player.body.pos, 6);
    }
    player.body.step(dt, 18);

    // The gun.
    player.cooldown = @max(0, player.cooldown - dt);
    player.kick = @max(0, player.kick - dt * 6);
    player.flash = @max(0, player.flash - dt);
    player.hit_marker = @max(0, player.hit_marker - dt);
    player.hurt_flash = @max(0, player.hurt_flash - dt * 2);
    if (player.reload > 0) {
        player.reload -= dt;
        if (player.reload <= 0) {
            const n = @min(mag_size - player.ammo, player.reserve);
            player.ammo += n;
            player.reserve -= n;
        }
    } else if ((actions.pressed(.reload) and player.ammo < mag_size) or (player.ammo == 0 and player.reserve > 0)) {
        player.reload = reload_time;
        stats.reloads += 1;
    } else if (actions.down(.fire) and player.cooldown <= 0 and player.ammo > 0) {
        try playerShot();
    }

    // The bots.
    const world: bots_mod.World = .{ .player_eye = eye(), .player_speed = horizontalSpeed() };
    for (0..bot_count) |i| try bots_mod.update(&bots, i, world, dt, &events, allocator);
    for (events.items) |e| switch (e) {
        .shot => |s| botShot(s.bot, s.from, s.to, s.hit),
        .step => |p| snowPuff(p, 2),
    };
    events.clearRetainingCapacity();

    // The health comes back after 3 seconds with no hit.
    player.since_hurt += dt;
    if (player.since_hurt > 3) player.health = @min(100, player.health + 12 * dt);
    if (player.health <= 0) {
        stats.deaths += 1;
        player = .{};
        camera.setRotation(0, 0);
    }
    for (&flashes) |*f| f.life = @max(0, f.life - dt);

    // The particles.
    const sys = &system.?;
    sys.step(dt);
    stats.max_particles = @max(stats.max_particles, sys.count());

    if (audio) |*a| {
        const o = cam_out.?;
        a.setListener(.{ .position = arena.arr(o.eye), .forward = arena.arr(o.forward) });
    }
}

fn spread(amount: f32) [3]f32 {
    return .{ rng.range(-amount, amount), rng.range(-amount, amount), rng.range(-amount, amount) };
}

fn normalize(v: [3]f32) [3]f32 {
    const l = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    return .{ v[0] / l, v[1] / l, v[2] / l };
}

/// The world point of the player muzzle.
fn playerMuzzle() [3]f32 {
    const o = cam_out.?;
    const f = arena.arr(o.forward);
    const r = normalize(.{ -f[2], 0, f[0] });
    const u: [3]f32 = .{ r[1] * f[2] - r[2] * f[1], r[2] * f[0] - r[0] * f[2], r[0] * f[1] - r[1] * f[0] };
    const e = eye();
    var p: [3]f32 = undefined;
    for (0..3) |i| p[i] = e[i] + f[i] * 0.85 + r[i] * 0.2 - u[i] * 0.12;
    return p;
}

fn playerShot() !void {
    const o = cam_out.?;
    player.cooldown = fire_interval;
    player.ammo -= 1;
    player.kick = 1;
    player.flash = 0.05;
    stats.shots += 1;
    const moving = horizontalSpeed() > 0.5;
    const s = spread(if (moving) 0.012 else 0.004);
    const from = eye();
    const dir = assist(from, normalize(.{ o.forward.x + s[0], o.forward.y + s[1], o.forward.z + s[2] }));
    const muzzle = playerMuzzle();
    muzzleFlash(muzzle);
    if (audio) |*a| {
        if (shot_sample) |*smp| _ = a.playSample(smp, .{ .group = sound.group_weapons, .position = .{ 0.2, -0.1, -0.5 }, .relative = true, .volume = 0.7, .pitch = rng.range(0.95, 1.05) });
    }
    // The nearest of the world and the bot hit boxes.
    var best_t: f32 = 200;
    var best_bot: ?usize = null;
    var head = false;
    const ray = sw_math.Ray.init(arena.v3(from), arena.v3(dir));
    for (&bots, 0..) |*b, i| {
        if (!b.alive()) continue;
        for (b.hitBoxes(), 0..) |hb, k| {
            const hit = ray.intersectAabb(arena.aabb(hb)) orelse continue;
            if (hit.t_enter > 0 and hit.t_enter < best_t) {
                best_t = hit.t_enter;
                best_bot = i;
                head = k == 1;
            }
        }
    }
    const world_hit = arena.cast(from, dir, 200);
    if (world_hit) |wh| {
        if (wh.t < best_t) best_bot = null;
    }
    var end: [3]f32 = undefined;
    if (best_bot) |i| {
        for (0..3) |k| end[k] = from[k] + dir[k] * best_t;
        stats.bot_hits += 1;
        player.hit_marker = 0.15;
        if (bots_mod.damage(&bots[i], if (head) 100 else 34)) stats.bot_kills += 1;
        sparks(end, normalize(.{ -dir[0], -dir[1], -dir[2] }));
        impactSound(end, 4);
    } else if (world_hit) |wh| {
        end = wh.point;
        impactFx(wh);
    } else {
        for (0..3) |k| end[k] = from[k] + dir[k] * 200;
    }
    tracer(muzzle, end);
}

/// The aim assist: a shot that passes within 3 degrees of the chest of a
/// bot that the player can see goes to that chest.
fn assist(from: [3]f32, dir: [3]f32) [3]f32 {
    var best = dir;
    var best_cos: f32 = @cos(3.0 * std.math.pi / 180.0);
    for (&bots) |*b| {
        if (!b.alive()) continue;
        const e = b.eye();
        const chest: [3]f32 = .{ e[0], e[1] - 0.45, e[2] };
        const to = normalize(.{ chest[0] - from[0], chest[1] - from[1], chest[2] - from[2] });
        const c = to[0] * dir[0] + to[1] * dir[1] + to[2] * dir[2];
        if (c > best_cos and arena.clear(from, chest)) {
            best_cos = c;
            best = to;
        }
    }
    return best;
}

fn botShot(index: usize, from: [3]f32, to: [3]f32, hit: bool) void {
    stats.bot_shots += 1;
    const b = &bots[index];
    const dir = normalize(.{ to[0] - from[0], to[1] - from[1], to[2] - from[2] });
    const muzzle: [3]f32 = .{ from[0] + dir[0] * 0.6, from[1] - 0.45, from[2] + dir[2] * 0.6 };
    muzzleFlash(muzzle);
    if (audio) |*a| {
        if (bot_shot_sample) |*smp| _ = a.playSample(smp, .{ .group = sound.group_weapons, .position = b.eye(), .attenuation = .{ .inverse = .{ .min_distance = 3, .max_distance = 80 } }, .pitch = 0.9 + 0.05 * @as(f32, @floatFromInt(index)) });
    }
    if (hit) {
        stats.player_hits += 1;
        player.health -= 6;
        player.since_hurt = 0;
        player.hurt_flash = 1;
        tracer(muzzle, to);
        return;
    }
    // A miss goes on until it hits the world.
    const wh = arena.cast(from, dir, 120) orelse {
        tracer(muzzle, .{ from[0] + dir[0] * 120, from[1] + dir[1] * 120, from[2] + dir[2] * 120 });
        return;
    };
    tracer(muzzle, wh.point);
    impactFx(wh);
}

// =============================================================================
// The particles and the impact sounds
// =============================================================================

fn muzzleFlash(p: [3]f32) void {
    const sys = &system.?;
    for (0..4) |_| sys.spawn(.{ .pos = p, .vel = spread(1.5), .life = 0.05, .size = rng.range(0.12, 0.22), .color = .{ 6, 4, 1.2, 1 }, .fade = true });
    for (&flashes) |*f| {
        if (f.life > 0) continue;
        f.* = .{ .pos = p, .life = 0.06 };
        break;
    }
}

fn tracer(a: [3]f32, b: [3]f32) void {
    const d: [3]f32 = .{ b[0] - a[0], b[1] - a[1], b[2] - a[2] };
    const len = @sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
    if (len < 0.5) return;
    const speed: f32 = 160;
    const v: [3]f32 = .{ d[0] / len * speed, d[1] / len * speed, d[2] / len * speed };
    system.?.spawn(.{ .pos = a, .vel = v, .life = len / speed, .size = 0.05, .color = .{ 4, 3, 1.5, 0.9 } });
}

fn snowPuff(p: [3]f32, n: usize) void {
    const sys = &system.?;
    for (0..n) |_| {
        sys.spawn(.{
            .pos = .{ p[0] + rng.range(-0.15, 0.15), p[1] + 0.05, p[2] + rng.range(-0.15, 0.15) },
            .vel = .{ rng.range(-0.6, 0.6), rng.range(0.4, 1.2), rng.range(-0.6, 0.6) },
            .life = rng.range(0.4, 0.8),
            .size = rng.range(0.08, 0.16),
            .color = .{ 0.9, 0.93, 1.0, 0.8 },
            .fade = true,
            .gravity = 2.5,
            .drag = 2,
        });
    }
}

fn sparks(p: [3]f32, n: [3]f32) void {
    const sys = &system.?;
    for (0..10) |_| {
        const s = spread(2.5);
        sys.spawn(.{ .pos = p, .vel = .{ n[0] * 3 + s[0], n[1] * 3 + s[1] + 1, n[2] * 3 + s[2] }, .life = rng.range(0.2, 0.5), .size = 0.04, .color = .{ 5, 2.2, 0.4, 1 }, .fade = true, .gravity = 9.8 });
    }
}

fn impactFx(h: arena.Hit) void {
    const sys = &system.?;
    const c = arena.color(h.material);
    const count: usize = if (h.material == .snow) 12 else 8;
    for (0..count) |_| {
        const s = spread(1.5);
        sys.spawn(.{
            .pos = h.point,
            .vel = .{ h.normal[0] * 2 + s[0], h.normal[1] * 2 + s[1] + 0.5, h.normal[2] * 2 + s[2] },
            .life = rng.range(0.3, 0.9),
            .size = rng.range(0.05, 0.14),
            .color = .{ c[0], c[1], c[2], 0.9 },
            .fade = true,
            .gravity = if (h.material == .snow) 3 else 9.8,
            .drag = 1.5,
        });
    }
    if (h.material == .metal) sparks(h.point, h.normal);
    impactSound(h.point, switch (h.material) {
        .snow => 0,
        .wood => 1,
        .concrete => 2,
        .metal => 3,
        .bot => 4,
    });
}

fn impactSound(p: [3]f32, which: usize) void {
    const a = if (audio) |*x| x else return;
    const s = if (impact_samples[which]) |*x| x else return;
    _ = a.playSample(s, .{ .group = sound.group_weapons, .position = p, .volume = 0.8, .attenuation = .{ .inverse = .{ .min_distance = 2, .max_distance = 60 } } });
}

// =============================================================================
// The frame
// =============================================================================

fn drawScene(pass: *sw_render.Pass) !void {
    try meshes.?.draw(pass);
    try models.?.draw(pass, .world, .{});
}

fn renderFrame(ctx: *sw.Context) !bool {
    const gpu = ctx.gpu();
    const g = &graph.?;
    const w: f32 = @floatFromInt(@max(gpu.getSurfaceWidth(), 1));
    const h: f32 = @floatFromInt(@max(gpu.getSurfaceHeight(), 1));
    const o = cam_out orelse camera.update(.{ .aspect = w / h }, 0, null);
    const proj = sw_math.perspective(camera.fov, w / h, 0.05, 400);
    const e = arena.arr(o.eye);
    var frame: sw_render.FrameUniforms = .{
        .view = o.view.data,
        .proj = proj.data,
        .view_proj = proj.mul(o.view).data,
        .camera_pos = .{ e[0], e[1], e[2], 1 },
        .time = @floatCast(seconds),
    };
    frame.sky = try sky.?.update();
    const light = sw_render.weather.skyLight(sky.?.state());

    // The bots and their guns.
    const bm = &models.?;
    bm.clear();
    const m = &meshes.?;
    m.clear();
    try m.add(.world, .{ .mesh = arena_mesh, .ao = false });
    for (&bots) |*b| {
        const root = b.root();
        const pose = b.pose();
        try bm.add(.world, bot_model, .{ .transform = root, .rotations = &pose });
        var mats: [bots_mod.Part.count]Mat4 = undefined;
        try sw_render.box_model.pose(&bots_mod.parts, root, &pose, &mats);
        const hand = bots_mod.hand;
        const gun = mats[bots_mod.Part.arm_r].mul(Mat4.translation(hand[0], hand[1], hand[2])).mul(Quat.fromAxisAngle(.{ .x = 1, .y = 0, .z = 0 }, -std.math.pi / 2.0).toMat4());
        try m.add(.world, .{ .mesh = smg_mesh, .model = gun, .ao = false });
    }
    // The held rifle, in view space: it kicks back at each shot, and it
    // moves down while it reloads.
    const reload_dip: f32 = if (player.reload > 0) @sin(std.math.pi * player.reload / reload_time) * 0.25 else 0;
    const held = Mat4.translation(0.25, -0.26 - reload_dip, -0.36 + player.kick * 0.05)
        .mul(Quat.fromAxisAngle(.{ .x = 1, .y = 0, .z = 0 }, player.kick * 0.06 + reload_dip).toMat4());
    try m.add(.first_person, .{ .mesh = rifle_mesh, .model = held, .ao = false, .cast_shadow = false });
    m.setLight(light);
    m.setFrame(frame);

    // A point light at each muzzle flash.
    var points: [4]sw_render.PointLight = undefined;
    var n: usize = 0;
    for (flashes) |f| {
        if (f.life <= 0) continue;
        points[n] = .{ .position = f.pos, .color = .{ 1.0, 0.7, 0.3 }, .intensity = 4, .radius = 6 };
        n += 1;
    }
    const l = &lighting.?;
    try l.setPointLights(points[0..n]);
    try l.update(frame);

    const input: sw_render.WeatherInput = .{ .camera = e, .seconds = seconds, .light = light };
    try clouds.?.update(input);
    try snow.?.update(input);
    try particles.?.update(&system.?, sw_render.ParticleCamera.fromView(frame.view, e));
    overlay.?.frameDone(ctx);
    return try g.execute(frame);
}

fn drawHud(_: ?*anyopaque, o: *demo.overlay.Overlay) anyerror!void {
    const r = &o.renderer;
    const white = gfx.Color.rgba8(240, 240, 240, 255);
    const cx = o.width / 2;
    const cy = o.height / 2;
    // The crosshair, and the hit marker.
    const ch = if (player.hit_marker > 0) gfx.Color.rgba8(255, 80, 60, 255) else gfx.Color.rgba8(255, 255, 255, 220);
    try r.fillRect(.{ .x = cx - 12, .y = cy - 1, .w = 8, .h = 2 }, ch);
    try r.fillRect(.{ .x = cx + 4, .y = cy - 1, .w = 8, .h = 2 }, ch);
    try r.fillRect(.{ .x = cx - 1, .y = cy - 12, .w = 2, .h = 8 }, ch);
    try r.fillRect(.{ .x = cx - 1, .y = cy + 4, .w = 2, .h = 8 }, ch);
    // A red edge when a shot hits the player.
    if (player.hurt_flash > 0) {
        const a: u8 = @intFromFloat(player.hurt_flash * 120);
        const red = gfx.Color.rgba8(200, 20, 10, a);
        try r.fillRect(.{ .x = 0, .y = 0, .w = o.width, .h = 18 }, red);
        try r.fillRect(.{ .x = 0, .y = o.height - 18, .w = o.width, .h = 18 }, red);
        try r.fillRect(.{ .x = 0, .y = 0, .w = 18, .h = o.height }, red);
        try r.fillRect(.{ .x = o.width - 18, .y = 0, .w = 18, .h = o.height }, red);
    }
    // The health and the ammunition.
    try r.fillRect(.{ .x = 20, .y = o.height - 44, .w = 204, .h = 24 }, gfx.Color.rgba8(0, 0, 0, 150));
    try r.fillRect(.{ .x = 22, .y = o.height - 42, .w = 2 * @max(player.health, 0), .h = 20 }, gfx.Color.rgba8(230, 70, 50, 230));
    try o.print(28, o.height - 41, 16, white, "{d:.0}", .{@max(player.health, 0)});
    if (player.reload > 0) {
        try o.print(o.width - 170, o.height - 44, 20, white, "reloading", .{});
    } else {
        try o.print(o.width - 170, o.height - 44, 22, white, "{d} / {d}", .{ player.ammo, player.reserve });
    }
    // The score and the frame time.
    try r.fillRect(.{ .x = 8, .y = 8, .w = 300, .h = 70 }, gfx.Color.rgba8(0, 0, 0, 120));
    try o.chart(14, 14);
    try o.print(184, 14, 16, white, "{d:.1} ms", .{o.frameMs()});
    try o.print(184, 34, 14, white, "preset {s}", .{@tagName(options.preset)});
    try o.print(14, 58, 14, white, "bots down {d}   hits taken {d}", .{ stats.bot_kills, stats.player_hits });
}

fn finishOffline(ctx: *sw.Context) noreturn {
    var ok = true;
    std.log.info("shooter: shots {d}, bot hits {d}, kills {d}, bot shots {d}, player hits {d}, deaths {d}, particles {d}, gamepad moves {d}, jumps {d}, reloads {d}", .{
        stats.shots, stats.bot_hits, stats.bot_kills, stats.bot_shots, stats.player_hits, stats.deaths, stats.max_particles, stats.gamepad_moves, stats.jumps, stats.reloads,
    });
    if (options.check) {
        const want = [_]struct { bool, []const u8 }{
            .{ stats.shots >= 20, "the player fired" },
            .{ stats.bot_hits >= 1, "the player hit a bot" },
            .{ stats.bot_shots >= 5, "the bots fired back" },
            .{ stats.player_hits >= 1, "a bot hit the player" },
            .{ stats.max_particles >= 20, "the particles" },
            .{ stats.gamepad_moves > 0, "a gamepad move" },
            .{ stats.jumps > 0, "a jump" },
            .{ stats.reloads > 0, "a reload" },
            .{ snow.?.settings.count > 0, "the snow" },
        };
        for (want) |w| {
            if (!w[0]) {
                std.log.err("shooter: the script did not give: {s}", .{w[1]});
                ok = false;
            }
        }
        std.log.info("shooter: check {s}", .{if (ok) "passed" else "FAILED"});
    }
    run.exitOffline(ctx, &frames, "shooter", if (ok) 0 else 1);
}
