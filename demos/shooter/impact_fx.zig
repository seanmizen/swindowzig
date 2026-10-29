// Where: apps/action/game/src/impact_fx.zig
// When: each bullet that hits the map (main.zig fire, the shots of other
// players, and the NPC shooter of the range), and each muzzle flash of the
// NPC.
// Why: a simple impact effect for each surface material, cheap enough for
// automatic fire. It uses the method of the grenade blast (grenade.zig):
// translucent billboards in the translucent pass, with no new pipeline and
// no texture.
//
// - A puff is a soft camera-facing quad: dust, a powder or a mist. It grows,
//   slows, and fades out.
// - A bit is a thin quad along its velocity: a chip, a splinter, a shard, a
//   stone or a spark. It flies under gravity and drag. A spark glows (it
//   has an emission), so the shader skips the lights for it. The other bits
//   take the light of the scene.
// - Each material has a recipe (`recipe`): dust for concrete, red dust for
//   brick, sparks for metal, splinters for wood, a puff and stones for
//   ballast, and more.
// - An effect can wait (`delay`): it starts when the bullet arrives.
// - The pools are rings. A new effect takes the place of the oldest one, so
//   the cost has a fixed limit: 160 puffs and 480 bits, 6 vertices each.
//
// Translucent vertex encoding (scene.wgsl fs_trans), as in grenade.zig:
// nrm.xy the quad UV in [-1, 1], nrm.z the emission, mat = -alpha.
const std = @import("std");
const vec = @import("vec.zig");
const mesh = @import("mesh.zig");
const Surface = @import("audio/impact.zig").Material;
const V3 = vec.V3;
const v3 = vec.v3;

const Puff = struct {
    p: V3,
    v: V3,
    /// Less than 0 while the effect waits.
    age: f32,
    life: f32,
    size0: f32,
    size1: f32,
    alpha: f32,
    col: V3,
    emit: f32,
};

const Bit = struct {
    p: V3,
    v: V3,
    age: f32,
    life: f32,
    /// The half width, and the length as the distance of `len` s of flight.
    width: f32,
    len: f32,
    col: V3,
    emit: f32,
    gravity: f32,
    drag: f32,
};

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

var puffs: [160]Puff = undefined;
var puff_n: usize = 0;
var bits: [480]Bit = undefined;
var bit_n: usize = 0;
var rng: std.Random.DefaultPrng = .init(818);

fn rand() f32 {
    return rng.random().float(f32);
}

fn between(r: [2]f32) f32 {
    return r[0] + (r[1] - r[0]) * rand();
}

/// A random unit vector, with the same chance for each direction.
fn randDir() V3 {
    while (true) {
        const r = v3(rand() * 2 - 1, rand() * 2 - 1, rand() * 2 - 1);
        const l2 = vec.dot(r, r);
        if (l2 > 0.01 and l2 <= 1) return r / vec.s(@sqrt(l2));
    }
}

/// A direction out over the open side of a surface with normal n.
fn outward(n: V3, focus: f32) V3 {
    var r = randDir();
    const into = vec.dot(r, n);
    if (into < 0) r -= n * vec.s(2 * into);
    return vec.norm(r + n * vec.s(focus));
}

fn addPuff(p: Puff) void {
    puffs[puff_n % puffs.len] = p;
    puff_n += 1;
}

fn addBit(b: Bit) void {
    bits[bit_n % bits.len] = b;
    bit_n += 1;
}

/// Remove every effect (a mode or a map change).
pub fn reset() void {
    puff_n = 0;
    bit_n = 0;
}

/// The effect of a bullet on surface `s` at p, with the surface normal n.
/// `size` scales the number of bits, and of puffs up to 1 (0.5 for one
/// pellet of buckshot).
/// `delay`: the effect starts after this many seconds (the flight of the
/// bullet).
pub fn spawn(p: V3, n: V3, s: Surface, size: f32, delay: f32) void {
    const rc = recipe(s);
    const age = -@max(0, delay);
    const pf = rc.puffs;
    const k = std.math.clamp(size, 0.1, 2);
    const n_puffs: u32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(pf.n)) * @min(k, 1)));
    for (0..n_puffs) |_| {
        const r = v3(rand() - 0.5, rand() - 0.5, rand() - 0.5);
        addPuff(.{
            .p = p + n * vec.s(0.04 + 0.06 * rand()),
            .v = (n * vec.s(pf.speed) + r * vec.s(pf.speed * 0.8)) * vec.s(0.5 + rand()),
            .age = age,
            .life = pf.life * (0.8 + 0.4 * rand()),
            .size0 = pf.size[0],
            .size1 = pf.size[1] * (0.8 + 0.4 * rand()),
            .alpha = pf.alpha,
            .col = pf.col * vec.s(0.9 + 0.2 * rand()),
            .emit = pf.emit,
        });
    }
    const bt = rc.bits;
    const n_bits: u32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(bt.n)) * k));
    for (0..n_bits) |_| {
        addBit(.{
            .p = p + n * vec.s(0.01),
            .v = outward(n, bt.focus) * vec.s(between(bt.speed)),
            .age = age,
            .life = between(bt.life),
            .width = bt.width * (0.7 + 0.6 * rand()),
            .len = bt.len,
            .col = bt.col * vec.s(0.85 + 0.3 * rand()),
            .emit = bt.emit,
            .gravity = bt.gravity,
            .drag = bt.drag,
        });
    }
}

/// The glow of a muzzle flash at p: a hot billboard for 0.05 s. It reads
/// at a distance, where the flash star of the gun is a pixel or less.
pub fn flash(p: V3) void {
    addPuff(.{ .p = p, .v = v3(0, 0, 0), .age = 0, .life = 0.05, .size0 = 0.18, .size1 = 0.3, .alpha = 1, .col = v3(1.0, 0.72, 0.35), .emit = 9 });
}

pub fn step(dt: f32) void {
    for (puffs[0..@min(puff_n, puffs.len)]) |*p| {
        if (p.age >= p.life) continue;
        p.age += dt;
        if (p.age < 0) continue;
        p.p += p.v * vec.s(dt);
        // The dust slows fast and rises a little.
        p.v = p.v * vec.s(@max(0, 1 - 3 * dt)) + v3(0, 0.15 * dt, 0);
    }
    for (bits[0..@min(bit_n, bits.len)]) |*b| {
        if (b.age >= b.life) continue;
        b.age += dt;
        if (b.age < 0) continue;
        b.v = b.v * vec.s(@max(0, 1 - b.drag * dt)) - v3(0, b.gravity * dt, 0);
        b.p += b.v * vec.s(dt);
    }
}

/// The number of live puffs and bits, the waiting ones too.
pub fn count() usize {
    var n: usize = 0;
    for (puffs[0..@min(puff_n, puffs.len)]) |p| {
        if (p.age < p.life) n += 1;
    }
    for (bits[0..@min(bit_n, bits.len)]) |b| {
        if (b.age < b.life) n += 1;
    }
    return n;
}

/// The puffs as camera-facing quads, and the bits as thin quads along their
/// velocity that turn about their own axis to face the camera.
pub fn buildTranslucent(trans: *mesh.Mesh, right: V3, up: V3) void {
    const uv = [4][2]f32{ .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 }, .{ -1, 1 } };
    const tris = [6]usize{ 0, 1, 2, 0, 2, 3 };
    for (puffs[0..@min(puff_n, puffs.len)]) |p| {
        if (p.age < 0 or p.age >= p.life) continue;
        const k = p.age / p.life;
        const size = p.size0 + (p.size1 - p.size0) * (1 - (1 - k) * (1 - k));
        const a = p.alpha * vec.smooth(k * 12) * std.math.pow(f32, 1 - k, 1.4);
        if (a < 0.005) continue;
        const r = right * vec.s(size);
        const u = up * vec.s(size);
        const corners = [4]V3{ p.p - r - u, p.p + r - u, p.p + r + u, p.p - r + u };
        for (tris) |ci| trans.push(corners[ci], v3(uv[ci][0], uv[ci][1], p.emit), p.col, -a);
    }
    const fwd = vec.cross(up, right);
    for (bits[0..@min(bit_n, bits.len)]) |b| {
        if (b.age < 0 or b.age >= b.life) continue;
        const k = b.age / b.life;
        const speed = vec.len(b.v);
        const along = if (speed > 1e-3) b.v / vec.s(speed) else up;
        const l = @max(b.width * 2, speed * b.len);
        var side = vec.cross(along, fwd);
        const sl = vec.len(side);
        side = if (sl > 0.05) side / vec.s(sl) else right;
        const s = side * vec.s(b.width);
        const head = b.p + along * vec.s(b.width);
        const tail = b.p - along * vec.s(l);
        const corners = [4]V3{ tail - s, head - s, head + s, tail + s };
        // A spark cools and fades. The other bits fade at the end only.
        const fade = if (b.emit > 2) std.math.pow(f32, 1 - k, 1.2) else 1 - vec.smooth((k - 0.75) * 4);
        const emit = b.emit * (1 - 0.5 * k);
        for (tris) |ci| {
            const at_head = ci == 1 or ci == 2;
            trans.push(corners[ci], v3(if (at_head) -0.3 else 1, uv[ci][1], emit), b.col, -(if (at_head) fade else 0.6 * fade));
        }
    }
}
