// The weapons: the models, the classes and their stats, the items that a
// player carries, and the hands (the fire, the reload, the switch and the
// view-model pose).
//
// - Models: guns.bin (seanorepo apps/action scripts/convert-gun.ts). Every gun of the
//   Quaternius Ultimate Gun Pack except the sniper rifles, and a bayonet as
//   the knife. The name of a model gives its class.
// - Classes: each class has its reference stats (`table`): the action, the
//   magazine, the cone and the hands.
// - Guns: each gun has its own stats from its calibre and its build
//   (guns.zig).
// - Items: a weapon as a thing: its class, its model and its rounds. A slot
//   holds one. An item does not know who holds it, so it can also lie in
//   the world.
// - Loadout: the four slots (1 primary, 2 secondary, 3 knife, 4 grenade),
//   the held slot and the hands. A change of slot takes the draw time of
//   the new weapon. It cannot fire before the draw ends.
const std = @import("std");
const guns = @import("guns.zig");
const vec = @import("vec.zig");
const mesh = @import("mesh.zig");
const V3 = vec.V3;
const v3 = vec.v3;
const Mat4 = vec.Mat4;

const guns_bin = @embedFile("guns.bin");

/// The weapon classes.
pub const Class = enum(u8) { rifle, carbine, bullpup, smg, shotgun, sawn_off, pistol, revolver, knife, grenade };
pub const class_count = @typeInfo(Class).@"enum".field_names.len;

pub const Slot = enum(u8) { primary, secondary, knife, grenade };

pub const Stats = struct {
    /// The name in the menu and on the HUD.
    label: []const u8,
    /// One line about the class, for the weapon menu.
    blurb: []const u8,
    slot: Slot,
    /// The calibre name ("5.56x45 mm"), for the menu. Empty for the knife
    /// and the grenade.
    calibre: []const u8 = "",
    /// The damage of one hit (one pellet) at full power, to the body and to
    /// the head. Whole numbers. The gun model sets them (guns.zig).
    body: f32 = 0,
    head: f32 = 0,
    pellets: u32 = 1,
    /// The time from one shot (or one burst) to the next.
    interval: f32 = 1,
    /// Hold to fire (true), or one shot (or one burst) for each click.
    auto: bool = false,
    /// The rounds of one click, and the time between them.
    burst: u32 = 1,
    burst_gap: f32 = 0,
    mag: u32 = 0,
    reserve: u32 = 0,
    reload: f32 = 1,
    /// The cone half angle at the hip, in radians: the base, the extra at a
    /// full run, and the extra at full heat (the trigger held).
    spread: f32 = 0,
    move_spread: f32 = 0,
    bloom: f32 = 0,
    /// The heat that one shot adds. The heat is 0 to 1.
    heat: f32 = 0,
    /// How much the sights make the cone smaller (0 to 1).
    ads_tight: f32 = 0.75,
    /// The recoil pattern (Hands.kickShot). The camera kick up of the first
    /// shot of a string, in radians. It grows by the part `ramp` over the
    /// first 8 shots.
    kick: f32 = 0,
    ramp: f32 = 0,
    /// The side kick of shot n of a string, in radians to the right:
    /// sway * (bias + wobble * sin(freq * n + phase)), and a small random
    /// part.
    sway: f32 = 0,
    bias: f32 = 0,
    wobble: f32 = 0,
    freq: f32 = 1,
    phase: f32 = 0,
    /// The rate (1/s) at which the camera goes back to the aim after a
    /// shot (Hands.recover).
    recovery: f32 = 6,
    /// The kick of the view-model, a multiplier.
    shove: f32 = 1,
    /// The reach of a hit, in metres.
    range: f32 = 200,
    /// The damage fall-off: full damage to `near` m, then a straight line
    /// down to the fraction `min_dmg` at `far` m. Past `far` the damage
    /// stays at `min_dmg`.
    near: f32 = 1e6,
    far: f32 = 2e6,
    min_dmg: f32 = 1,
    /// The muzzle velocity in m/s. Over guns.sound_speed the bullet is
    /// supersonic.
    velocity: f32 = 0,
    /// The bullet diameter and length in mm (guns.zig Round). 0 for the
    /// knife and the grenade.
    bullet_d: f32 = 0,
    bullet_l: f32 = 0,
    /// The walk speed multiplier while it is held.
    speed: f32 = 1,
    /// The time to take it out, in seconds.
    draw: f32,
    /// The rate (1/s) to go to the sights and back.
    aim_speed: f32 = 14,
    /// The view-model grip at the hip, and its distance at the sights.
    hip: V3 = v3(0.15, -0.18, -0.38),
    ads_z: f32 = -0.3,
    /// The player can aim down the sights.
    sights: bool = true,

    /// The damage multiplier at `dist` m: 1 near, `min_dmg` far.
    /// The math is in f64, so a hit rounds to the same whole number on
    /// each platform.
    pub fn falloff(st: *const Stats, dist: f32) f64 {
        const d: f64 = dist;
        const near: f64 = st.near;
        const far: f64 = st.far;
        const min: f64 = st.min_dmg;
        if (d <= near) return 1;
        if (d >= far) return min;
        return 1 - ((1 - min) * (d - near)) / (far - near);
    }

    /// The damage of one hit (one pellet) at `dist` m, a whole number.
    pub fn damageAt(st: *const Stats, head: bool, dist: f32) f32 {
        const base: f64 = if (head) st.head else st.body;
        return @floatCast(@round(base * st.falloff(dist)));
    }

    /// True when the bullet is faster than sound (a crack, not a whiz).
    pub fn supersonic(st: *const Stats) bool {
        return st.velocity > guns.sound_speed;
    }
};

/// The stats of each class, in the order of Class. For a gun class they are
/// the reference of the gun model (guns.zig): the action, the magazine, the
/// cone and the hands, with the interval and the kick for the reference
/// calibre of the class. The calibre and the build of each gun change them.
/// The knife and the grenade use these stats as they are.
///
/// Balance notes: 100 health. Each primary kills in about 0.3 s up close
/// when all hits land. Hipfire on a laptop: the first shot is accurate, the
/// cone grows with the heat and the movement, and the sights make it
/// smaller.
pub const table = [class_count]Stats{
    .{ // rifle: the reference is 7.62x39 mm
        .label = "RIFLE",
        .blurb = "AK pattern, full auto",
        .slot = .primary,
        .interval = 0.107,
        .auto = true,
        .mag = 30,
        .reserve = 90,
        .reload = 2.3,
        .spread = 0.006,
        .move_spread = 0.02,
        .bloom = 0.032,
        .heat = 0.13,
        .kick = 0.013,
        .speed = 0.93,
        .draw = 0.45,
    },
    .{ // carbine: the reference is 5.56x45 mm
        .label = "CARBINE",
        .blurb = "AR pattern, full auto",
        .slot = .primary,
        .interval = 0.082,
        .auto = true,
        .mag = 30,
        .reserve = 120,
        .reload = 2.1,
        .spread = 0.005,
        .move_spread = 0.016,
        .bloom = 0.024,
        .heat = 0.1,
        .kick = 0.009,
        .shove = 0.8,
        .speed = 0.96,
        .draw = 0.4,
    },
    .{ // bullpup: the reference is 5.56x45 mm
        .label = "BULLPUP",
        .blurb = "3-round burst, the action behind the grip",
        .slot = .primary,
        .interval = 0.3,
        .burst = 3,
        .burst_gap = 0.05,
        .mag = 30,
        .reserve = 90,
        .reload = 2.2,
        .spread = 0.003,
        .move_spread = 0.014,
        .bloom = 0.012,
        .heat = 0.06,
        .kick = 0.008,
        .shove = 0.8,
        .speed = 0.94,
        .draw = 0.5,
    },
    .{ // smg: the reference is 9x19 mm
        .label = "SMG",
        .blurb = "full auto, pistol rounds",
        .slot = .primary,
        .interval = 0.075,
        .auto = true,
        .mag = 35,
        .reserve = 140,
        .reload = 1.8,
        .spread = 0.012,
        .move_spread = 0.008,
        .bloom = 0.04,
        .heat = 0.08,
        .kick = 0.006,
        .shove = 0.6,
        .speed = 1.04,
        .draw = 0.3,
        .hip = v3(0.14, -0.17, -0.36),
    },
    .{ // shotgun: the reference is 12 gauge
        .label = "SHOTGUN",
        .blurb = "pump, buckshot or slug, one shot up close",
        .slot = .primary,
        .interval = 0.85,
        .mag = 6,
        .reserve = 24,
        .reload = 2.6,
        .spread = 0.06,
        .move_spread = 0.01,
        .ads_tight = 0.3,
        .kick = 0.045,
        .shove = 1.8,
        .speed = 0.95,
        .draw = 0.45,
    },
    .{ // sawn_off: the reference is 12 gauge
        .label = "SAWN-OFF",
        .blurb = "2 barrels, wide spread, very close range",
        .slot = .primary,
        .interval = 0.25,
        .mag = 2,
        .reserve = 20,
        .reload = 2.0,
        .spread = 0.075,
        .move_spread = 0.01,
        .ads_tight = 0.3,
        .kick = 0.06,
        .shove = 2,
        .speed = 1.0,
        .draw = 0.35,
        .hip = v3(0.14, -0.18, -0.36),
    },
    .{ // pistol: the reference is 9x19 mm
        .label = "PISTOL",
        .blurb = "semi-auto, quick to draw",
        .slot = .secondary,
        .interval = 0.12,
        .mag = 12,
        .reserve = 48,
        .reload = 1.4,
        .spread = 0.005,
        .move_spread = 0.012,
        .bloom = 0.02,
        .heat = 0.15,
        .kick = 0.016,
        .speed = 1.06,
        .draw = 0.25,
        .hip = v3(0.13, -0.15, -0.4),
        .ads_z = -0.42,
    },
    .{ // revolver: the reference is .357 Magnum
        .label = "REVOLVER",
        .blurb = "double action, 6 rounds",
        .slot = .secondary,
        .interval = 0.46,
        .mag = 6,
        .reserve = 30,
        .reload = 2.4,
        .spread = 0.003,
        .move_spread = 0.016,
        .bloom = 0.03,
        .heat = 0.6,
        .kick = 0.04,
        .shove = 1.6,
        .speed = 1.04,
        .draw = 0.35,
        .hip = v3(0.13, -0.15, -0.4),
        .ads_z = -0.42,
    },
    .{ // knife
        .label = "KNIFE",
        .blurb = "2 hits, short reach, fastest feet",
        .slot = .knife,
        .body = 55,
        .head = 55,
        .interval = 0.45,
        .auto = true,
        .range = 1.6,
        .speed = 1.1,
        .draw = 0.2,
        .hip = v3(0.2, -0.22, -0.38),
        .sights = false,
    },
    .{ // grenade
        .label = "GRENADE",
        .blurb = "impact, 8 m blast",
        .slot = .grenade,
        .speed = 1.0,
        .draw = 0.5,
        .hip = v3(0.16, -0.17, -0.42),
        .sights = false,
    },
};

/// The stats of a class: the reference of its guns, and the stats of the
/// knife and the grenade.
pub fn stats(c: Class) *const Stats {
    return &table[@backingInt(c)];
}

/// The stats of a model: its gun stats (guns.zig), or the class stats for
/// the knife.
pub fn gunStats(model: u8) *const Stats {
    if (model < guns.gun_count) return &guns.table[model];
    return stats(models[model].class);
}

/// The stats of an item: the gun stats of its model, or the class stats for
/// the knife and the grenade.
pub fn statsOf(it: Item) *const Stats {
    if (it.class == .knife or it.class == .grenade) return stats(it.class);
    return gunStats(it.model);
}

// ---- Models ----------------------------------------------------------------

pub const Model = struct {
    /// The source name ("AssaultRifle_1").
    name: []const u8,
    class: Class,
    /// The number in its class, from 1: "RIFLE 3".
    number: u8,
    /// The triangles. `mat` holds the part: 0 the body, 1 the magazine.
    verts: []mesh.Vertex,
    muzzle: V3,
    /// The y of the top of the sights.
    sight: f32,
    /// The magazine pivot: its top front corner.
    pivot: V3,
    has_mag: bool,
    min: V3,
    max: V3,
};

pub var models: []Model = &.{};
pub var knife_model: u8 = 0;

fn rd(comptime T: type, b: []const u8, at: usize) T {
    return std.mem.readInt(T, b[at..][0..@sizeOf(T)], .little);
}

fn rf(b: []const u8, at: usize) f32 {
    return @bitCast(rd(u32, b, at));
}

fn rv(b: []const u8, at: usize) V3 {
    return v3(rf(b, at), rf(b, at + 4), rf(b, at + 8));
}

/// Read guns.bin (the layout is in scripts/convert-gun.ts) and make the
/// triangles of each model. The guns must be in the order of guns.builds.
pub fn loadModels(alloc: std.mem.Allocator) !void {
    const b: []const u8 = guns_bin;
    if (!std.mem.eql(u8, b[0..4], "GUN1")) return error.BadGunFile;
    const np = rd(u16, b, 4);
    const nm = rd(u16, b, 6);
    var at: usize = 8;
    const palette = try alloc.alloc(V3, np);
    defer alloc.free(palette);
    for (palette) |*c| {
        c.* = rv(b, at);
        at += 12;
    }
    const header_len = 20 + 8 + 2 + 28;
    const headers = at;
    at += nm * header_len;
    models = try alloc.alloc(Model, nm);
    var counts: [class_count]u8 = @splat(0);
    for (models, 0..) |*m, i| {
        const h = headers + i * header_len;
        const name = std.mem.sliceTo(b[h .. h + 20], 0);
        const nv = rd(u16, b, h + 20);
        const nf = rd(u16, b, h + 22);
        const nr = rd(u16, b, h + 24);
        const nt = rd(u16, b, h + 26);
        const class = guns.classOf(name) orelse return error.BadGunFile;
        if (i < guns.gun_count and !std.mem.eql(u8, name, guns.builds[i].name)) return error.BadGunFile;
        if (i >= guns.gun_count and class != .knife) return error.BadGunFile;
        counts[@backingInt(class)] += 1;
        if (class == .knife) knife_model = @intCast(i);
        m.* = .{
            .name = name,
            .class = class,
            .number = counts[@backingInt(class)],
            .verts = try alloc.alloc(mesh.Vertex, @as(usize, nt) * 3),
            .muzzle = rv(b, h + 30),
            .sight = rf(b, h + 42),
            .pivot = rv(b, h + 46),
            .has_mag = b[h + 28] != 0,
            .min = vec.s(1e9),
            .max = vec.s(-1e9),
        };
        const pos = b[at .. at + @as(usize, nv) * 6];
        at += pos.len;
        const corner = struct {
            fn get(p: []const u8, k: u16) V3 {
                const o = @as(usize, k) * 6;
                return v3(
                    @as(f32, @floatFromInt(rd(i16, p, o))),
                    @as(f32, @floatFromInt(rd(i16, p, o + 2))),
                    @as(f32, @floatFromInt(rd(i16, p, o + 4))),
                ) / vec.s(8192);
            }
        }.get;
        // The faces come first, then the runs that give their materials.
        var runs = at;
        for (0..nf) |_| runs += 1 + 2 * @as(usize, b[runs]);
        var face = at;
        var out: usize = 0;
        for (0..nr) |r| {
            const count = rd(u16, b, runs + r * 4);
            const col = palette[b[runs + r * 4 + 2]];
            const part: f32 = @floatFromInt(b[runs + r * 4 + 3]);
            for (0..count) |_| {
                const n = b[face];
                const idx = b[face + 1 .. face + 1 + 2 * @as(usize, n)];
                face += 1 + 2 * @as(usize, n);
                const p0 = corner(pos, rd(u16, idx, 0));
                for (1..n - 1) |k| {
                    const p1 = corner(pos, rd(u16, idx, k * 2));
                    const p2 = corner(pos, rd(u16, idx, k * 2 + 2));
                    const nrm = vec.norm(vec.cross(p1 - p0, p2 - p0));
                    for ([3]V3{ p0, p1, p2 }) |p| {
                        m.verts[out] = .{
                            .pos = .{ p[0], p[1], p[2] },
                            .nrm = .{ nrm[0], nrm[1], nrm[2] },
                            .col = .{ col[0], col[1], col[2] },
                            .mat = part,
                        };
                        out += 1;
                        m.min = @min(m.min, p);
                        m.max = @max(m.max, p);
                    }
                }
            }
        }
        if (face != runs or out != m.verts.len) return error.BadGunFile;
        at = runs + @as(usize, nr) * 4;
    }
    if (at != b.len) return error.BadGunFile;
}

/// The first model of a class (the default of the class).
pub fn firstOf(c: Class) u8 {
    for (models, 0..) |m, i| if (m.class == c) return @intCast(i);
    return 0;
}

/// The model with this source name, or null.
pub fn byName(name: []const u8) ?u8 {
    for (models, 0..) |m, i| if (std.mem.eql(u8, m.name, name)) return @intCast(i);
    return null;
}

/// The name of a model on the HUD and in the menu: "RIFLE 3".
pub fn label(buf: []u8, model: u8) []const u8 {
    const m = models[model];
    const st = stats(m.class);
    if (m.class == .knife) return st.label;
    return std.fmt.bufPrint(buf, "{s} {d}", .{ st.label, m.number }) catch st.label;
}

/// Add a model to a mesh. `m` is the world matrix of the grip, `mag` the
/// magazine offset (relative to the gun). `mat` is the material id (100
/// for the view-model).
pub fn addModel(out: *mesh.Mesh, model: u8, m: Mat4, mag: Mat4, mat: f32) void {
    const src = models[model].verts;
    out.model(src, m, 0, mat);
    out.model(src, m.mul(mag), 1, mat);
}

// ---- Items and the loadout -------------------------------------------------

/// A weapon as a thing: what it is and the rounds in it. A grenade item
/// holds the count of grenades in `ammo`.
pub const Item = struct {
    class: Class,
    model: u8 = 0,
    ammo: u32 = 0,
    reserve: u32 = 0,

    /// A new gun of this model: a full magazine and the reserve of its
    /// class. `infinite` gives a reserve without end (practice).
    pub fn full(model: u8, infinite: bool) Item {
        const st = gunStats(model);
        return .{ .class = models[model].class, .model = model, .ammo = st.mag, .reserve = if (infinite) 9999 else st.reserve };
    }
};

/// The primary and the secondary weapon that the player picked (model ids).
pub const Choice = struct {
    primary: u8,
    secondary: u8,

    /// The default pick: the AKM (RIFLE 2) and PISTOL 1.
    pub fn default() Choice {
        return .{ .primary = byName("AssaultRifle_2") orelse firstOf(.rifle), .secondary = firstOf(.pistol) };
    }

    /// True when each model exists and is in the right slot.
    pub fn valid(c: Choice) bool {
        if (c.primary >= models.len or c.secondary >= models.len) return false;
        return stats(models[c.primary].class).slot == .primary and stats(models[c.secondary].class).slot == .secondary;
    }

    pub fn eql(a: Choice, b: Choice) bool {
        return a.primary == b.primary and a.secondary == b.secondary;
    }
};

pub const Loadout = struct {
    /// The primary, the secondary, the knife and the grenades. A slot can be
    /// empty.
    slots: [4]?Item = @splat(null),
    current: Slot = .primary,
    /// The slot before the current one. The grenade slot goes back to it.
    last: Slot = .primary,
    hands: Hands = .{},
    /// A moped thief took the primary in this life (moped.zig): a new pick
    /// does not fill the primary slot before the next life.
    primary_locked: bool = false,

    /// Fill the slots for a new life. The primary is in the hands, ready.
    pub fn equip(self: *Loadout, c: Choice, nades: u32, infinite: bool) void {
        self.* = .{};
        self.slots[0] = Item.full(c.primary, infinite);
        self.slots[1] = Item.full(c.secondary, infinite);
        self.slots[2] = .{ .class = .knife, .model = knife_model };
        self.slots[3] = .{ .class = .grenade, .ammo = nades };
    }

    /// Put new primary and secondary weapons in their slots (a change of
    /// the choice at the spawn point). The held slot stays. A locked
    /// primary slot keeps what it has.
    pub fn rearm(self: *Loadout, c: Choice, infinite: bool) void {
        if (!self.primary_locked) self.slots[0] = Item.full(c.primary, infinite);
        self.slots[1] = Item.full(c.secondary, infinite);
        if (self.current == .primary or self.current == .secondary) {
            self.hands.takeOut(self.heldStats().draw);
        }
    }

    pub fn held(self: *Loadout) ?*Item {
        if (self.slots[@backingInt(self.current)]) |*it| return it;
        return null;
    }

    pub fn heldClass(self: *const Loadout) Class {
        if (self.slots[@backingInt(self.current)]) |it| return it.class;
        return .knife;
    }

    pub fn heldModel(self: *const Loadout) u8 {
        if (self.slots[@backingInt(self.current)]) |it| return it.model;
        return knife_model;
    }

    pub fn heldStats(self: *const Loadout) *const Stats {
        if (self.slots[@backingInt(self.current)]) |it| return statsOf(it);
        return stats(.knife);
    }

    pub fn item(self: *Loadout, slot: Slot) ?*Item {
        if (self.slots[@backingInt(slot)]) |*it| return it;
        return null;
    }

    /// The grenades left.
    pub fn grenades(self: *const Loadout) u32 {
        return if (self.slots[3]) |it| it.ammo else 0;
    }

    /// A snatch: the primary leaves its slot, and the slot stays locked
    /// for the rest of the life. With the primary in the hands, the
    /// secondary comes up. Returns the gun, or null for an empty slot.
    pub fn takePrimary(self: *Loadout) ?Item {
        const it = self.slots[0] orelse return null;
        self.slots[0] = null;
        self.primary_locked = true;
        if (self.last == .primary) self.last = .secondary;
        if (self.current == .primary) {
            _ = self.select(.secondary);
            self.last = .secondary;
        }
        return it;
    }

    /// A gun back in the empty primary slot (F on a stolen gun), in the
    /// hands.
    pub fn givePrimary(self: *Loadout, it: Item) void {
        self.slots[0] = it;
        if (self.current != .primary) _ = self.select(.primary);
    }

    /// Take out the weapon of a slot. False when the slot is empty, holds
    /// no grenade, or is held already.
    pub fn select(self: *Loadout, slot: Slot) bool {
        if (slot == self.current) return false;
        const it = self.slots[@backingInt(slot)] orelse return false;
        if (it.class == .grenade and it.ammo == 0) return false;
        self.last = self.current;
        self.current = slot;
        self.hands.takeOut(statsOf(it).draw);
        return true;
    }
};

// ---- The hands -------------------------------------------------------------

pub const Event = enum { none, fired, empty, mag_out, mag_in, racked, swung, ready };

/// The reload animation is made for 2.1 s. A class with another reload
/// time plays it faster or slower.
const anim_reload: f32 = 2.1;
/// The knife swing animation time.
pub const swing_time: f32 = 0.32;
/// The sight height of the first rifle above its grip. The hip pose of each
/// gun moves it to this height.
const sight_ref: f32 = 0.085;

/// The state of the held weapon in the hands: timers, the recoil, the
/// heat, the sights, the reload and the switch.
pub const Hands = struct {
    cooldown: f32 = 0,
    recoil: f32 = 0, // the kick of the view-model, 0..1
    /// The camera recoil that the recovery has not given back yet, in
    /// radians: up, and to the right.
    kick_up: f32 = 0,
    kick_side: f32 = 0,
    /// The shots of this string (the place in the recoil pattern), and the
    /// time since the last shot.
    string: u32 = 0,
    since_shot: f32 = 10,
    heat: f32 = 0, // grows while the trigger is held, makes the cone wider
    ads: f32 = 0, // 0 hip, 1 aim down the sights
    flash: f32 = 0, // the muzzle flash time left
    sway_t: f32 = 0,
    flash_roll: f32 = 0,
    reloading: f32 = -1, // seconds into the reload, or -1
    /// The time left to take out the held weapon, and the full time.
    drawing: f32 = 0,
    draw_len: f32 = 1,
    /// Rounds left in the burst.
    burst_left: u32 = 0,
    /// A click that came near the end of the cooldown fires at its end.
    queued: bool = false,
    /// Seconds into the knife swing, or -1.
    swing: f32 = -1,

    /// Start to take out a weapon. A reload stops.
    pub fn takeOut(self: *Hands, t: f32) void {
        self.drawing = t;
        self.draw_len = @max(t, 0.01);
        self.reloading = -1;
        self.burst_left = 0;
        self.queued = false;
        self.swing = -1;
        self.heat = 0;
        self.cooldown = 0;
    }

    /// True when the held weapon is out and not busy.
    pub fn ready(self: *const Hands) bool {
        return self.drawing <= 0 and self.reloading < 0;
    }

    pub fn canReload(self: *const Hands, it: *const Item) bool {
        const st = statsOf(it.*);
        return st.mag > 0 and self.reloading < 0 and self.drawing <= 0 and it.ammo < st.mag and it.reserve > 0;
    }

    pub fn startReload(self: *Hands, it: *const Item) bool {
        if (!self.canReload(it)) return false;
        self.reloading = 0;
        self.burst_left = 0;
        return true;
    }

    fn shoot(self: *Hands, it: *Item, st: *const Stats) void {
        it.ammo -= 1;
        self.recoil = 1;
        self.heat = @min(1, self.heat + st.heat);
        self.flash = 0.05;
        self.flash_roll += 2.1;
    }

    /// Advance one step with the held item. Returns the event of this step
    /// for the sound and the shot.
    pub fn update(self: *Hands, it: *Item, dt: f32, trigger: bool, pressed: bool, aim: bool) Event {
        const st = statsOf(it.*);
        self.cooldown = @max(0, self.cooldown - dt);
        self.recoil = @max(0, self.recoil - dt * 7);
        self.flash = @max(0, self.flash - dt);
        self.heat = if (trigger) @min(1, self.heat) else @max(0, self.heat - dt * 3);
        const want_ads: f32 = if (aim and st.sights and self.ready()) 1 else 0;
        // A heavy gun goes to the sights more slowly (guns.zig weights).
        self.ads += (want_ads - self.ads) * @min(1, dt * st.aim_speed);
        self.sway_t += dt;
        if (self.swing >= 0) {
            self.swing += dt;
            if (self.swing > swing_time) self.swing = -1;
        }

        if (self.drawing > 0) {
            self.drawing -= dt;
            if (self.drawing <= 0) {
                self.drawing = 0;
                return .ready;
            }
            return .none;
        }

        if (it.class == .grenade) return .none;
        if (it.class == .knife) {
            if (trigger and self.cooldown <= 0) {
                self.cooldown = st.interval;
                self.swing = 0;
                return .swung;
            }
            return .none;
        }

        if (self.reloading >= 0) {
            const k = anim_reload / st.reload;
            const before = self.reloading * k;
            self.reloading += dt;
            const t = self.reloading * k;
            if (before < 0.45 and t >= 0.45) return .mag_out;
            if (before < 1.25 and t >= 1.25) return .mag_in;
            if (self.reloading >= st.reload) {
                const take = @min(st.mag - it.ammo, it.reserve);
                it.ammo += take;
                it.reserve -= take;
                self.reloading = -1;
                return .racked;
            }
            return .none;
        }

        // The rest of a burst.
        if (self.burst_left > 0) {
            if (self.cooldown > 0) return .none;
            if (it.ammo == 0) {
                self.burst_left = 0;
                return .none;
            }
            self.burst_left -= 1;
            self.cooldown = if (self.burst_left > 0) st.burst_gap else st.interval - st.burst_gap * @as(f32, @floatFromInt(st.burst - 1));
            self.shoot(it, st);
            return .fired;
        }

        // A click in the last 0.15 s of the cooldown waits for its end.
        if (pressed and !st.auto and self.cooldown > 0 and self.cooldown < 0.15) self.queued = true;
        const pull = if (st.auto) trigger else (pressed or (self.queued and self.cooldown <= 0));
        if (pull and self.cooldown <= 0) {
            self.queued = false;
            if (it.ammo == 0) {
                if (pressed) return .empty;
                return .none;
            }
            if (st.burst > 1) {
                self.burst_left = st.burst - 1;
                self.cooldown = st.burst_gap;
            } else {
                self.cooldown = st.interval;
            }
            self.shoot(it, st);
            return .fired;
        }
        return .none;
    }

    /// The cone half angle of the next shot, in radians.
    pub fn spread(self: *const Hands, st: *const Stats, moving: f32, airborne: bool) f32 {
        var a: f32 = st.spread + self.heat * st.bloom + moving * st.move_spread;
        if (airborne) a += 0.05;
        return a * (1 - st.ads_tight * self.ads);
    }

    /// The camera kick of one shot, in radians: up, and to the right. The
    /// recoil pattern of the gun sets it: the up kick grows over the first
    /// 8 shots of a string, and the side kick follows a wave with a drift.
    /// `jitter` is a random number from 0 to 1. The sights halve the kick.
    pub fn kickShot(self: *Hands, st: *const Stats, jitter: f32) [2]f32 {
        const n: f32 = @floatFromInt(self.string);
        const sights = 1 - 0.5 * self.ads;
        const up = st.kick * (1 + st.ramp * @min(n, 8) / 8) * sights;
        const side = st.sway * (st.bias + st.wobble * @sin(st.freq * n + st.phase) + 0.5 * (jitter - 0.5)) * sights;
        self.string += 1;
        self.since_shot = 0;
        self.kick_up += up;
        self.kick_side += side;
        return .{ up, side };
    }

    /// The camera recovery of one step, in radians: up, and to the right.
    /// The camera goes back to the aim at the recovery rate of the gun. For
    /// an automatic gun the recovery starts when the next shot does not
    /// come. For other guns it starts 0.12 s after the shot. `look_up` is
    /// the pitch change that the mouse made in this step. A pull down
    /// against the recoil counts as recovery, so the view does not go
    /// lower than the aim.
    pub fn recover(self: *Hands, st: *const Stats, dt: f32, look_up: f32) [2]f32 {
        if (look_up < 0) self.kick_up = @max(0, self.kick_up + look_up);
        self.since_shot += dt;
        const delay: f32 = if (st.auto) st.interval + 0.04 else 0.12;
        if (self.since_shot < delay) return .{ 0, 0 };
        // A pause ends the string. The next shot starts the pattern again.
        if (self.since_shot > delay + 0.15) self.string = 0;
        const k = 1 - @exp(-st.recovery * dt);
        const up = self.kick_up * k;
        const side = self.kick_side * k;
        self.kick_up -= up;
        self.kick_side -= side;
        return .{ -up, -side };
    }

    /// The view-model pose in camera space: the matrix of the grip, the
    /// magazine offset (relative to the gun), and the muzzle (in gun
    /// space).
    pub fn pose(self: *const Hands, it: Item, bob: f32, speed: f32) struct { gun: Mat4, mag: Mat4, muzzle: V3 } {
        const st = statsOf(it);
        const mdl = models[it.model];
        // Each gun at the hip has the top of its sights at one height, so a
        // low shotgun and a tall bullpup sit alike.
        const hip = if (st.mag > 0) st.hip + v3(0, sight_ref - mdl.sight, 0) else st.hip;
        // The eye goes 4 mm over the top of the sights.
        const ads_pos = v3(0.0, -(mdl.sight + 0.004), st.ads_z);
        var pos = vec.lerp(hip, ads_pos, self.ads);
        var pitch: f32 = 0;
        var roll: f32 = 0;
        var yaw: f32 = 0;

        // Walk bob and idle sway, smaller when aiming.
        const sway = (1 - 0.8 * self.ads);
        pos += v3(@sin(bob) * 0.012 * speed, -@abs(@cos(bob)) * 0.01 * speed, 0) * vec.s(sway);
        pos += v3(@sin(self.sway_t * 0.9) * 0.002, @sin(self.sway_t * 1.7) * 0.002, 0) * vec.s(sway);

        // Recoil: back and up.
        const r = self.recoil * self.recoil * st.shove;
        pos[2] += r * 0.05;
        pitch += r * 0.06;

        if (it.class == .knife) {
            // The blade points forward, up and in.
            pitch += 0.35;
            yaw += 0.3;
            roll -= 0.35;
            if (self.swing >= 0) {
                // A slash from the upper right to the lower left.
                const t = self.swing / swing_time;
                const p = vec.smooth(t * 1.4);
                const lift = @sin(std.math.pi * vec.clamp01(t));
                pos += v3(0.06 - 0.26 * p, 0.05 - 0.13 * p, -0.16 * lift);
                yaw += 0.9 * p - 0.2;
                pitch -= 0.5 * p;
                roll -= 0.6 * lift;
            }
        }

        var mag = Mat4.identity();
        if (self.reloading >= 0 and st.mag > 0) {
            const t = self.reloading * anim_reload / st.reload;
            // Tilt in, hold, tilt out.
            const tilt = vec.smooth(t / 0.3) * (1 - vec.smooth((t - 1.7) / 0.35));
            // Lift the gun to the centre and cant its top away, so the
            // underside and the magazine well turn toward the camera.
            roll -= tilt * 0.75;
            pitch += tilt * 0.12;
            yaw += tilt * 0.1;
            pos += v3(-0.08, 0.1, 0.06) * vec.s(tilt);
            if (mdl.has_mag) {
                // The magazine: out (0.3..0.65), away, in (0.95..1.3), then
                // a small seat bump.
                var drop: f32 = 0;
                var turn: f32 = 0;
                if (t < 0.95) {
                    const k = vec.smooth((t - 0.3) / 0.35);
                    drop = k * 0.35;
                    turn = k * 0.4;
                } else {
                    const k = 1 - vec.smooth((t - 0.95) / 0.35);
                    drop = k * 0.3;
                    turn = k * 0.25;
                }
                // The magazine pivots at its top front corner.
                const pivot = mdl.pivot;
                mag = vec.translate(pivot + v3(0, -drop, drop * 0.25)).mul(Mat4.rotationX(-turn).mul(vec.translate(-pivot)));
            }
            // The rack at the end pulls the gun back a little.
            const rack = vec.smooth((t - 1.55) / 0.08) * (1 - vec.smooth((t - 1.68) / 0.12));
            pos[2] += rack * 0.025;
            if (t > 1.27 and t < 1.37) pos[1] += 0.008;
        }

        // The switch: the weapon comes up from below.
        if (self.drawing > 0) {
            const k = vec.smooth(self.drawing / self.draw_len);
            pos[1] -= 0.25 * k;
            pos[2] += 0.05 * k;
            pitch -= 0.8 * k;
        }

        const gun = vec.ypr(pos, yaw, pitch, roll);
        return .{ .gun = gun, .mag = mag, .muzzle = mdl.muzzle };
    }
};
