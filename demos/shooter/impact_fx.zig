// The impact effects of the shooter demo, from the action game (seanorepo
// apps/action): one recipe for each surface material, cheap enough for
// automatic fire (REQ-DEMO-023). The effects are `sw_render` particles:
// camera-facing quads in one sorted draw.
//
// - A puff is a soft quad: dust, a powder, a mist or snow. It slows and
//   fades out.
// - A bit is a small quad that flies under gravity and drag: a chip, a
//   splinter, a shard, a stone or a spark. A spark glows: its colour is
//   over 1 in the HDR target.
// - Each material has a recipe (`recipe`): dust for concrete, sparks for
//   metal, splinters for wood, and more. Snow has its own recipe.
// - `flash` is the glow of a muzzle flash, and `snowStep` the snow that a
//   running bot kicks up.
//
// The random numbers come from a seeded generator that the caller owns,
// so a replay gives the same particles (REQ-DEMO-021).
const std = @import("std");
const sw_render = @import("sw_render");
const vec = @import("vec.zig");
const Surface = @import("audio/impact.zig").Material;
const V3 = vec.V3;
const v3 = vec.v3;

pub const System = sw_render.ParticleSystem;

/// The bits of one material.
const Bits = struct {
    n: u32,
    col: V3,
    emit: f32 = 0,
    speed: [2]f32,
    life: [2]f32,
    width: f32,
    len: f32,
    gravity: f32 = 9.8,
    drag: f32 = 1.5,
    /// How much the directions lean to the normal: 0 a half sphere, more
    /// a narrow cone.
    focus: f32 = 0.6,
};

/// The puffs of one material.
const Puffs = struct {
    n: u32,
    col: V3,
    alpha: f32,
    size: [2]f32,
    life: f32,
    speed: f32,
    emit: f32 = 0,
};

const Recipe = struct { puffs: Puffs, bits: Bits };

fn recipe(s: Surface) Recipe {
    return switch (s) {
        // A grey dust cloud and grey chips.
        .concrete => .{
            .puffs = .{ .n = 3, .col = v3(0.66, 0.63, 0.58), .alpha = 0.55, .size = .{ 0.06, 0.45 }, .life = 1.1, .speed = 1.4 },
            .bits = .{ .n = 7, .col = v3(0.5, 0.49, 0.46), .speed = .{ 3, 7 }, .life = .{ 0.35, 0.7 }, .width = 0.012, .len = 0.012 },
        },
        // Red-brown dust and chips.
        .brick => .{
            .puffs = .{ .n = 3, .col = v3(0.66, 0.38, 0.27), .alpha = 0.6, .size = .{ 0.06, 0.5 }, .life = 1.2, .speed = 1.3 },
            .bits = .{ .n = 6, .col = v3(0.55, 0.26, 0.17), .speed = .{ 3, 6 }, .life = .{ 0.35, 0.7 }, .width = 0.014, .len = 0.012 },
        },
        // A white puff, larger and softer, and a few flakes.
        .plaster => .{
            .puffs = .{ .n = 4, .col = v3(0.92, 0.9, 0.86), .alpha = 0.6, .size = .{ 0.08, 0.6 }, .life = 1.3, .speed = 1.2 },
            .bits = .{ .n = 3, .col = v3(0.9, 0.88, 0.84), .speed = .{ 2, 4 }, .life = .{ 0.3, 0.6 }, .width = 0.012, .len = 0.01 },
        },
        // White shards that fly fast, and a little powder.
        .tile => .{
            .puffs = .{ .n = 1, .col = v3(0.9, 0.9, 0.88), .alpha = 0.35, .size = .{ 0.04, 0.25 }, .life = 0.7, .speed = 1 },
            .bits = .{ .n = 9, .col = v3(0.92, 0.92, 0.9), .emit = 0.0, .speed = .{ 4, 8 }, .life = .{ 0.3, 0.6 }, .width = 0.01, .len = 0.02, .focus = 0.3 },
        },
        // Sparks, and a short hot flash.
        .metal => .{
            .puffs = .{ .n = 1, .col = v3(1.0, 0.85, 0.55), .alpha = 1, .size = .{ 0.08, 0.2 }, .life = 0.05, .speed = 0, .emit = 7 },
            .bits = .{ .n = 12, .col = v3(1.0, 0.75, 0.38), .emit = 8, .speed = .{ 6, 14 }, .life = .{ 0.12, 0.35 }, .width = 0.007, .len = 0.025, .gravity = 6, .drag = 2.5, .focus = 0.25 },
        },
        // Fewer sparks, and a little paint dust.
        .sheet_metal => .{
            .puffs = .{ .n = 1, .col = v3(0.5, 0.52, 0.55), .alpha = 0.35, .size = .{ 0.04, 0.22 }, .life = 0.6, .speed = 0.8 },
            .bits = .{ .n = 8, .col = v3(1.0, 0.72, 0.35), .emit = 7, .speed = .{ 5, 11 }, .life = .{ 0.1, 0.28 }, .width = 0.006, .len = 0.022, .gravity = 6, .drag = 2.5, .focus = 0.25 },
        },
        // Shards that glint and fall, and a faint powder.
        .glass => .{
            .puffs = .{ .n = 1, .col = v3(0.85, 0.92, 0.95), .alpha = 0.25, .size = .{ 0.04, 0.3 }, .life = 0.6, .speed = 0.8 },
            .bits = .{ .n = 12, .col = v3(0.78, 0.9, 0.95), .emit = 1.3, .speed = .{ 2, 6 }, .life = .{ 0.45, 0.9 }, .width = 0.011, .len = 0.018, .focus = 0.4 },
        },
        // Long splinters, and light brown dust.
        .wood => .{
            .puffs = .{ .n = 2, .col = v3(0.66, 0.53, 0.37), .alpha = 0.4, .size = .{ 0.05, 0.32 }, .life = 0.9, .speed = 1.1 },
            .bits = .{ .n = 8, .col = v3(0.6, 0.42, 0.22), .speed = .{ 3, 6 }, .life = .{ 0.45, 0.8 }, .width = 0.009, .len = 0.03, .focus = 0.5 },
        },
        // A low cloud of grey-brown dust, and stones.
        .ballast => .{
            .puffs = .{ .n = 3, .col = v3(0.56, 0.52, 0.46), .alpha = 0.55, .size = .{ 0.08, 0.6 }, .life = 1.3, .speed = 1.0 },
            .bits = .{ .n = 6, .col = v3(0.36, 0.35, 0.33), .speed = .{ 2, 5 }, .life = .{ 0.35, 0.7 }, .width = 0.02, .len = 0.008, .focus = 0.9 },
        },
        // A spray of dirt.
        .earth => .{
            .puffs = .{ .n = 3, .col = v3(0.45, 0.35, 0.24), .alpha = 0.55, .size = .{ 0.06, 0.5 }, .life = 1.1, .speed = 1.2 },
            .bits = .{ .n = 8, .col = v3(0.3, 0.22, 0.15), .speed = .{ 2, 5 }, .life = .{ 0.35, 0.7 }, .width = 0.016, .len = 0.012, .focus = 1.0 },
        },
        // A small puff of fibres.
        .fabric => .{
            .puffs = .{ .n = 2, .col = v3(0.45, 0.46, 0.5), .alpha = 0.35, .size = .{ 0.03, 0.22 }, .life = 0.7, .speed = 0.7 },
            .bits = .{ .n = 2, .col = v3(0.35, 0.36, 0.4), .speed = .{ 1, 3 }, .life = .{ 0.3, 0.5 }, .width = 0.004, .len = 0.03 },
        },
        // A red mist and drops.
        .flesh => .{
            .puffs = .{ .n = 2, .col = v3(0.55, 0.05, 0.04), .alpha = 0.6, .size = .{ 0.04, 0.28 }, .life = 0.45, .speed = 0.9 },
            .bits = .{ .n = 4, .col = v3(0.45, 0.03, 0.02), .speed = .{ 1.5, 4 }, .life = .{ 0.25, 0.5 }, .width = 0.01, .len = 0.015 },
        },
    };
}

/// Snow: a white burst and lumps of snow.
const snow_recipe: Recipe = .{
    .puffs = .{ .n = 4, .col = v3(0.95, 0.97, 1.0), .alpha = 0.7, .size = .{ 0.1, 0.55 }, .life = 1.0, .speed = 1.6 },
    .bits = .{ .n = 8, .col = v3(0.92, 0.95, 1.0), .speed = .{ 2, 5 }, .life = .{ 0.4, 0.8 }, .width = 0.025, .len = 0.01, .focus = 1.2 },
};

const Rng = std.Random;

fn between(r: Rng, x: [2]f32) f32 {
    return x[0] + (x[1] - x[0]) * r.float(f32);
}

/// A random unit vector, with the same chance for each direction.
fn randDir(r: Rng) V3 {
    while (true) {
        const d = v3(r.float(f32) * 2 - 1, r.float(f32) * 2 - 1, r.float(f32) * 2 - 1);
        const l2 = vec.dot(d, d);
        if (l2 > 0.01 and l2 <= 1) return d / vec.s(@sqrt(l2));
    }
}

/// A direction out over the open side of a surface with normal n.
fn outward(r: Rng, n: V3, focus: f32) V3 {
    var d = randDir(r);
    const into = vec.dot(d, n);
    if (into < 0) d -= n * vec.s(2 * into);
    return vec.norm(d + n * vec.s(focus));
}

fn arr(x: V3) [3]f32 {
    return .{ x[0], x[1], x[2] };
}

/// The effect of a bullet at p, with the surface normal n: the recipe of
/// `s`, or of snow. `size` scales the number of bits (0.5 for one pellet
/// of buckshot). `light` is the light of the scene on the dust (a spark
/// glows on its own).
pub fn spawn(sys: *System, r: Rng, p: V3, n: V3, s: Surface, snow: bool, size: f32, light: V3) void {
    const rc = if (snow) snow_recipe else recipe(s);
    const k = std.math.clamp(size, 0.1, 2);
    const pf = rc.puffs;
    const n_puffs: u32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(pf.n)) * @min(k, 1)));
    for (0..n_puffs) |_| {
        const j = v3(r.float(f32) - 0.5, r.float(f32) - 0.5, r.float(f32) - 0.5);
        const v = (n * vec.s(pf.speed) + j * vec.s(pf.speed * 0.8)) * vec.s(0.5 + r.float(f32));
        const col = if (pf.emit > 0) pf.col * vec.s(pf.emit) else pf.col * light;
        sys.spawn(.{
            .pos = arr(p + n * vec.s(0.04 + 0.06 * r.float(f32))),
            .vel = arr(v),
            .life = pf.life * (0.8 + 0.4 * r.float(f32)),
            .size = (pf.size[0] + pf.size[1]) * (0.5 + 0.3 * r.float(f32)),
            .color = .{ col[0], col[1], col[2], pf.alpha },
            .fade = true,
            .gravity = -0.15,
            .drag = 3,
        });
    }
    const bt = rc.bits;
    const n_bits: u32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(bt.n)) * k));
    for (0..n_bits) |_| {
        const col = if (bt.emit > 0) bt.col * vec.s(bt.emit) else bt.col * light;
        sys.spawn(.{
            .pos = arr(p + n * vec.s(0.01)),
            .vel = arr(outward(r, n, bt.focus) * vec.s(between(r, bt.speed))),
            .life = between(r, bt.life),
            .size = @max(bt.width * 2.5, 0.02) * (0.7 + 0.6 * r.float(f32)),
            .color = .{ col[0], col[1], col[2], 1 },
            .fade = bt.emit > 2,
            .gravity = bt.gravity,
            .drag = bt.drag,
        });
    }
}

/// The glow of a muzzle flash at p: a hot quad for 0.05 s, and a few
/// sparks forward along `dir`. `scale` sets the size of the glow.
pub fn flash(sys: *System, r: Rng, p: V3, dir: V3, scale: f32) void {
    sys.spawn(.{ .pos = arr(p), .life = 0.05, .size = 0.42 * scale, .color = .{ 9, 6.5, 3.2, 1 }, .fade = true });
    sys.spawn(.{ .pos = arr(p + dir * vec.s(0.12 * scale)), .life = 0.04, .size = 0.25 * scale, .color = .{ 8, 5, 2.2, 1 }, .fade = true });
    for (0..3) |_| {
        const d = vec.norm(dir + randDir(r) * vec.s(0.35));
        sys.spawn(.{ .pos = arr(p), .vel = arr(d * vec.s(between(r, .{ 8, 16 }))), .life = between(r, .{ 0.05, 0.12 }), .size = 0.025, .color = .{ 7, 4.5, 1.8, 1 }, .fade = true, .gravity = 3, .drag = 4 });
    }
}

/// The snow that a running foot kicks up at p.
pub fn snowStep(sys: *System, r: Rng, p: V3, light: V3) void {
    for (0..2) |_| {
        const v = v3(r.float(f32) - 0.5, 0.6 + 0.6 * r.float(f32), r.float(f32) - 0.5);
        const col = v3(0.95, 0.97, 1.0) * light;
        sys.spawn(.{ .pos = arr(p + v3(0, 0.08, 0)), .vel = arr(v), .life = 0.6 + 0.3 * r.float(f32), .size = 0.22 + 0.12 * r.float(f32), .color = .{ col[0], col[1], col[2], 0.45 }, .fade = true, .gravity = 1.2, .drag = 2.5 });
    }
}

test "impact fx: one seed gives the same particles, and snow has its own recipe (REQ-DEMO-023)" {
    var a = try System.init(std.testing.allocator, 256);
    defer a.deinit(std.testing.allocator);
    var b = try System.init(std.testing.allocator, 256);
    defer b.deinit(std.testing.allocator);
    var ra: std.Random.DefaultPrng = .init(7);
    var rb: std.Random.DefaultPrng = .init(7);
    const light = v3(1, 1, 1);
    spawn(&a, ra.random(), v3(1, 1, 1), v3(0, 0, 1), .metal, false, 1, light);
    spawn(&b, rb.random(), v3(1, 1, 1), v3(0, 0, 1), .metal, false, 1, light);
    a.step(0.1);
    b.step(0.1);
    try std.testing.expectEqual(a.count(), b.count());
    for (0..a.count()) |i| try std.testing.expectEqual(a.get(i).pos, b.get(i).pos);
    // A spark of metal glows: its colour is over 1.
    var glow = false;
    for (0..a.count()) |i| glow = glow or a.get(i).color[0] > 1;
    try std.testing.expect(glow);
    // Snow throws white puffs.
    var s = try System.init(std.testing.allocator, 256);
    defer s.deinit(std.testing.allocator);
    spawn(&s, ra.random(), v3(0, 0, 0), v3(0, 1, 0), .earth, true, 1, light);
    try std.testing.expect(s.count() > 4);
    try std.testing.expect(s.get(0).color[2] > 0.9);
}
