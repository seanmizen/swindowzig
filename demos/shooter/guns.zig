// The gun model: the stats of each gun come from its calibre and its build.
// There is no hand-typed stat table for each gun. The README has the
// formulas, the build of each gun and the time to kill.
//
// - The calibre (`rounds`) sets the damage, the damage fall-off with the
//   distance, the bullet speed and the recoil impulse.
// - The class (weapon.zig `table`) sets the action: the fire mode, the time
//   between shots for the reference calibre of the class, the magazine, the
//   cone and the hands.
// - The build (`builds`) changes them: the barrel length, a stock or no
//   stock, the weight and the bullpup layout.
//
// The formulas, with r = barrel / the reference barrel of the calibre
// (0.4 to 4):
//   damage    = calibre damage * r^0.1 (0.9 to 1.1), rounded
//   velocity  = calibre velocity * r^0.2
//   fall-off  = calibre near and far * r^0.35 (0.75 to 1.3), buckshot
//               r^0.8 (0.75 to 1.6)
//   cone      = buckshot: class cone * (1 / r)^2.5 (0.35 to 1). A slug:
//               class cone * 0.12
//   interval  = class interval * calibre shot damage / reference shot damage
//   kick      = class kick * (impulse / reference impulse)^0.85 * weight
//               * 1.4 with no stock
//   sway      = kick * class sway * 1.3 with no stock
//   recovery  = class recovery * weight * 0.6 with no stock
//   speed     = class speed + weight (+0.02 with no stock)
//   draw, aim = class time * weight (* 0.9 and / 1.15 for a bullpup or a
//               gun with no stock: a short gun)
//   reload    = class reload (* 1.14 for a bullpup)
const std = @import("std");
const weapon = @import("weapon.zig");
const Class = weapon.Class;
const Stats = weapon.Stats;

/// The speed of sound in m/s. A faster bullet is supersonic.
pub const sound_speed: f32 = 343;

pub const Calibre = enum {
    c4_6x30,
    c9x19,
    c40sw,
    c10mm,
    c45acp,
    c50ae,
    c38spl,
    c357mag,
    c44mag,
    c5_45x39,
    c5_56x45,
    c7_62x39,
    c300blk_sub,
    g12,
    g12_mag,
    g20,
    g12_slug,
};

/// The data of a calibre, for its reference barrel.
pub const Round = struct {
    label: []const u8,
    /// The damage of one bullet (one pellet) to the body at full power, and
    /// the head damage as a multiple of it.
    body: f32,
    head: f32,
    pellets: u32 = 1,
    /// The muzzle velocity in m/s from the reference barrel, and the length
    /// of that barrel in cm.
    velocity: f32,
    barrel: f32,
    /// The fall-off: full damage to `near` m, then a straight line down to
    /// the fraction `min` at `far` m. Past `far` the damage stays at `min`.
    near: f32,
    far: f32,
    min: f32,
    /// The reach in metres. Buckshot does no damage past it. The barrel
    /// changes it as the fall-off.
    reach: f32 = 200,
    /// The recoil impulse in N s: the momentum of the bullet and the gas.
    impulse: f32,
    /// The bullet (or pellet) diameter and length in mm. The crack of a
    /// supersonic bullet comes from them (audio/near_miss.zig). Buckshot
    /// is a ball: the length is the diameter.
    bullet_d: f32,
    bullet_l: f32,
};

pub const rounds = std.enums.EnumArray(Calibre, Round).init(.{
    .c4_6x30 = .{ .label = "4.6x30 mm", .body = 22, .head = 2.3, .velocity = 720, .barrel = 18, .near = 23, .far = 72, .min = 0.75, .impulse = 2.3, .bullet_d = 4.65, .bullet_l = 16 },
    .c9x19 = .{ .label = "9x19 mm", .body = 27, .head = 2.3, .velocity = 360, .barrel = 11, .near = 16, .far = 52, .min = 0.65, .impulse = 3.4, .bullet_d = 9.02, .bullet_l = 15.5 },
    .c40sw = .{ .label = ".40 S&W", .body = 32, .head = 2.3, .velocity = 330, .barrel = 11, .near = 16, .far = 50, .min = 0.65, .impulse = 4.3, .bullet_d = 10.17, .bullet_l = 14 },
    .c10mm = .{ .label = "10 mm Auto", .body = 36, .head = 2.3, .velocity = 380, .barrel = 12, .near = 20, .far = 58, .min = 0.7, .impulse = 5.3, .bullet_d = 10.17, .bullet_l = 15.5 },
    .c45acp = .{ .label = ".45 ACP", .body = 35, .head = 2.3, .velocity = 255, .barrel = 13, .near = 13, .far = 46, .min = 0.6, .impulse = 4.2, .bullet_d = 11.48, .bullet_l = 17 },
    .c50ae = .{ .label = ".50 AE", .body = 58, .head = 2.0, .velocity = 450, .barrel = 15, .near = 20, .far = 60, .min = 0.7, .impulse = 10.3, .bullet_d = 12.7, .bullet_l = 22 },
    .c38spl = .{ .label = ".38 Special", .body = 45, .head = 2.5, .velocity = 265, .barrel = 10, .near = 13, .far = 46, .min = 0.6, .impulse = 3.1, .bullet_d = 9.07, .bullet_l = 18 },
    .c357mag = .{ .label = ".357 Magnum", .body = 69, .head = 2.0, .velocity = 425, .barrel = 10, .near = 20, .far = 58, .min = 0.7, .impulse = 5.5, .bullet_d = 9.07, .bullet_l = 17 },
    .c44mag = .{ .label = ".44 Magnum", .body = 83, .head = 2.0, .velocity = 440, .barrel = 15, .near = 29, .far = 78, .min = 0.7, .impulse = 8.2, .bullet_d = 10.9, .bullet_l = 19 },
    .c5_45x39 = .{ .label = "5.45x39 mm", .body = 30, .head = 2.5, .velocity = 880, .barrel = 41, .near = 26, .far = 78, .min = 0.75, .impulse = 4.4, .bullet_d = 5.6, .bullet_l = 25.5 },
    .c5_56x45 = .{ .label = "5.56x45 mm", .body = 30, .head = 2.5, .velocity = 900, .barrel = 37, .near = 23, .far = 72, .min = 0.72, .impulse = 5.9, .bullet_d = 5.7, .bullet_l = 23 },
    .c7_62x39 = .{ .label = "7.62x39 mm", .body = 39, .head = 2.6, .velocity = 715, .barrel = 41, .near = 33, .far = 90, .min = 0.8, .impulse = 7.8, .bullet_d = 7.92, .bullet_l = 26.8 },
    .c300blk_sub = .{ .label = ".300 BLK subsonic", .body = 42, .head = 2.5, .velocity = 305, .barrel = 23, .near = 20, .far = 58, .min = 0.7, .impulse = 5.1, .bullet_d = 7.82, .bullet_l = 38 },
    .g12 = .{ .label = "12 gauge", .body = 16, .head = 1.25, .pellets = 9, .velocity = 400, .barrel = 47, .near = 9, .far = 40, .min = 0.35, .reach = 48, .impulse = 17, .bullet_d = 8.38, .bullet_l = 8.38 },
    .g12_mag = .{ .label = "12 gauge magnum", .body = 15, .head = 1.25, .pellets = 12, .velocity = 410, .barrel = 47, .near = 10, .far = 44, .min = 0.35, .reach = 54, .impulse = 23, .bullet_d = 8.38, .bullet_l = 8.38 },
    .g20 = .{ .label = "20 gauge", .body = 16, .head = 1.25, .pellets = 8, .velocity = 400, .barrel = 47, .near = 8, .far = 36, .min = 0.35, .reach = 44, .impulse = 12, .bullet_d = 6.1, .bullet_l = 6.1 },
    .g12_slug = .{ .label = "12 gauge slug", .body = 100, .head = 1.6, .velocity = 480, .barrel = 47, .near = 20, .far = 70, .min = 0.55, .impulse = 27, .bullet_d = 18.5, .bullet_l = 22 },
});

pub const Weight = enum { light, medium, heavy };

/// The change that a weight class gives, against medium.
const WeightK = struct { kick: f32, recovery: f32, speed: f32, draw: f32, aim: f32 };

const weights = std.enums.EnumArray(Weight, WeightK).init(.{
    .light = .{ .kick = 1.2, .recovery = 1.1, .speed = 0.03, .draw = 0.85, .aim = 1.2 },
    .medium = .{ .kick = 1, .recovery = 1, .speed = 0, .draw = 1, .aim = 1 },
    .heavy = .{ .kick = 0.82, .recovery = 0.9, .speed = -0.04, .draw = 1.2, .aim = 0.8 },
});

/// The build of one gun: what the model shows.
pub const Build = struct {
    /// The source model name in guns.bin.
    name: []const u8,
    calibre: Calibre,
    /// The barrel length in cm.
    barrel: f32,
    stock: bool,
    weight: Weight,
    /// The action is behind the grip: a long barrel in a short gun.
    bullpup: bool = false,
    /// The rounds in the magazine. 0: the magazine of the class.
    mag: u32 = 0,
    /// Why this calibre: what the model shows (the README table).
    why: []const u8,
};

pub const BarrelClass = enum { snub, short, standard, long };

/// The barrel length class: the length against a usual barrel for the type
/// of gun. The usual barrel is 12 cm for a handgun, 20 cm for a long gun
/// for pistol rounds, 40 cm for a rifle and 50 cm for a shotgun. Under 0.65
/// of it is snub, under 0.9 short, under 1.15 standard (1.25 for a pistol
/// round in a long gun), and longer is long. The class is a name only. The
/// formulas use the length.
pub fn barrelClass(b: Build) BarrelClass {
    const class = classOf(b.name).?;
    const cal = rounds.get(b.calibre);
    const handgun = class == .pistol or class == .revolver;
    const pistol_round = !handgun and cal.pellets == 1 and cal.barrel < 20;
    const usual: f32 = if (handgun) 12 else if (cal.pellets > 1) 50 else if (pistol_round) 20 else 40;
    const k = b.barrel / usual;
    if (k < 0.65) return .snub;
    if (k < 0.9) return .short;
    if (k < (if (pistol_round) @as(f32, 1.25) else 1.15)) return .standard;
    return .long;
}

/// The build of each gun, in the order of guns.bin (scripts/convert-gun.ts
/// MODELS). The README has the reason for each calibre.
pub const builds = [_]Build{
    .{
        .name = "AssaultRifle_1",
        .calibre = .c9x19,
        .barrel = 24,
        .stock = false,
        .weight = .light,
        .why = "A straight, thin magazine on a short AK with no stock: an AK in 9 mm, as the Vityaz.",
    },
    .{
        .name = "AssaultRifle_2",
        .calibre = .c7_62x39,
        .barrel = 41,
        .stock = true,
        .weight = .medium,
        .why = "A wood stock, a curved magazine and a full barrel: the AKM.",
    },
    .{
        .name = "AssaultRifle_3",
        .calibre = .c7_62x39,
        .barrel = 31,
        .stock = false,
        .weight = .light,
        .why = "An AK with no stock and a short barrel: an AK pistol.",
    },
    .{
        .name = "AssaultRifle_4",
        .calibre = .c7_62x39,
        .barrel = 41,
        .stock = true,
        .weight = .light,
        .why = "A steel folding stock and a full barrel: the AKMS.",
    },
    .{
        .name = "AssaultRifle_5",
        .calibre = .c5_45x39,
        .barrel = 41,
        .stock = true,
        .weight = .medium,
        .why = "A black polymer stock and fore-end: the AK-74.",
    },
    .{
        .name = "AssaultRifle2_1",
        .calibre = .c5_56x45,
        .barrel = 51,
        .stock = true,
        .weight = .heavy,
        .why = "A fixed A2 stock and the longest barrel: an M16A4.",
    },
    .{
        .name = "AssaultRifle2_2",
        .calibre = .c5_56x45,
        .barrel = 37,
        .stock = true,
        .weight = .medium,
        .why = "A fixed stock and a carbine barrel: an M4.",
    },
    .{
        .name = "AssaultRifle2_3",
        .calibre = .c5_56x45,
        .barrel = 41,
        .stock = false,
        .weight = .light,
        .mag = 20,
        .why = "An AR-15 with no stock and a short, straight 20-round magazine.",
    },
    .{
        .name = "AssaultRifle2_4",
        .calibre = .c300blk_sub,
        .barrel = 18,
        .stock = true,
        .weight = .light,
        .why = "A very short barrel and a short stock on an AR: a Honey Badger, made for subsonic .300 Blackout.",
    },
    .{
        .name = "Bullpup_1",
        .calibre = .c5_56x45,
        .barrel = 51,
        .stock = true,
        .weight = .heavy,
        .bullpup = true,
        .why = "A long body, a vertical front grip and a straight box magazine: a Steyr AUG.",
    },
    .{
        .name = "Bullpup_2",
        .calibre = .c5_56x45,
        .barrel = 41,
        .stock = true,
        .weight = .medium,
        .bullpup = true,
        .why = "Bullpup 1 with a shorter body, so a shorter barrel.",
    },
    .{
        .name = "Bullpup_3",
        .calibre = .c7_62x39,
        .barrel = 41,
        .stock = true,
        .weight = .heavy,
        .bullpup = true,
        .why = "A curved AK magazine behind the grip: an AK bullpup, as the Valmet M82.",
    },
    .{
        .name = "SubmachineGun_1",
        .calibre = .c45acp,
        .barrel = 14,
        .stock = false,
        .weight = .light,
        .mag = 25,
        .why = "A straight magazine for a straight-walled case, and no stock.",
    },
    .{
        .name = "SubmachineGun_2",
        .calibre = .c9x19,
        .barrel = 20,
        .stock = true,
        .weight = .medium,
        .why = "A skeleton side-folding stock, as the UMP 9.",
    },
    .{
        .name = "SubmachineGun_3",
        .calibre = .c4_6x30,
        .barrel = 18,
        .stock = true,
        .weight = .light,
        .mag = 40,
        .why = "A sliding rod stock and a vertical front grip: an MP7.",
    },
    .{
        .name = "SubmachineGun_4",
        .calibre = .c9x19,
        .barrel = 11,
        .stock = false,
        .weight = .light,
        .mag = 30,
        .why = "A curved magazine for the tapered 9 mm case, and no stock: an MP5K.",
    },
    .{
        .name = "SubmachineGun_5",
        .calibre = .c9x19,
        .barrel = 40,
        .stock = true,
        .weight = .heavy,
        .mag = 30,
        .why = "SMG 2 with a long barrel: a pistol-calibre carbine.",
    },
    .{
        .name = "Shotgun_1",
        .calibre = .g12,
        .barrel = 47,
        .stock = true,
        .weight = .medium,
        .why = "A grey synthetic stock and an 18.5-inch barrel: a police pump gun.",
    },
    .{
        .name = "Shotgun_2",
        .calibre = .g12,
        .barrel = 61,
        .stock = true,
        .weight = .heavy,
        .mag = 7,
        .why = "A long barrel, a full-length tube magazine and a wood stock: a field gun.",
    },
    .{
        .name = "Shotgun_3",
        .calibre = .g12_mag,
        .barrel = 61,
        .stock = true,
        .weight = .heavy,
        .mag = 5,
        .why = "The longest barrel and a short tube magazine: a waterfowl gun for 3-inch magnum shells.",
    },
    .{
        .name = "Shotgun_4",
        .calibre = .g12_slug,
        .barrel = 56,
        .stock = true,
        .weight = .light,
        .mag = 4,
        .why = "A thin single barrel, a short fore-end and a light frame: a slug gun with a rifled barrel. It fires one heavy slug, not shot.",
    },
    .{
        .name = "Shotgun_ShortStock",
        .calibre = .g12,
        .barrel = 36,
        .stock = false,
        .weight = .light,
        .mag = 5,
        .why = "A pump with a bird's-head grip and no stock, as the Shockwave.",
    },
    .{
        .name = "Shotgun_SawedOff",
        .calibre = .g12,
        .barrel = 30,
        .stock = false,
        .weight = .light,
        .why = "A double-barrel 12 gauge with the barrels and the stock cut down.",
    },
    .{
        .name = "Pistol_1",
        .calibre = .c45acp,
        .barrel = 13,
        .stock = false,
        .weight = .heavy,
        .mag = 8,
        .why = "A black 1911 with wood grips.",
    },
    .{
        .name = "Pistol_2",
        .calibre = .c9x19,
        .barrel = 13,
        .stock = false,
        .weight = .heavy,
        .mag = 9,
        .why = "A two-tone 1911 pattern: a steel 9 mm pistol.",
    },
    .{
        .name = "Pistol_3",
        .calibre = .c40sw,
        .barrel = 11,
        .stock = false,
        .weight = .medium,
        .mag = 14,
        .why = "A service pistol with a rail and a heavy slide.",
    },
    .{
        .name = "Pistol_4",
        .calibre = .c50ae,
        .barrel = 15,
        .stock = false,
        .weight = .heavy,
        .mag = 7,
        .why = "A tall slide and a long grip: a big-frame pistol, as the Desert Eagle.",
    },
    .{
        .name = "Pistol_5",
        .calibre = .c9x19,
        .barrel = 10,
        .stock = false,
        .weight = .light,
        .mag = 15,
        .why = "A compact polymer pistol, as the Glock 19.",
    },
    .{
        .name = "Pistol_6",
        .calibre = .c10mm,
        .barrel = 15,
        .stock = false,
        .weight = .medium,
        .mag = 15,
        .why = "A long slide and a full rail: a long-slide hunting pistol.",
    },
    .{
        .name = "Revolver_1",
        .calibre = .c357mag,
        .barrel = 10,
        .stock = false,
        .weight = .medium,
        .why = "A medium frame and a 4-inch barrel: a service .357.",
    },
    .{
        .name = "Revolver_2",
        .calibre = .c44mag,
        .barrel = 15,
        .stock = false,
        .weight = .heavy,
        .why = "A large frame and a heavy barrel with a full under-lug.",
    },
    .{
        .name = "Revolver_3",
        .calibre = .c357mag,
        .barrel = 15,
        .stock = false,
        .weight = .heavy,
        .why = "A vent rib and a full under-lug, as the Colt Python.",
    },
    .{
        .name = "Revolver_4",
        .calibre = .c357mag,
        .barrel = 6,
        .stock = false,
        .weight = .light,
        .why = "A snub barrel with a full under-lug: a .357 for carry.",
    },
    .{
        .name = "Revolver_5",
        .calibre = .c38spl,
        .barrel = 15,
        .stock = false,
        .weight = .light,
        .why = "A slim frame and a thin barrel: a .38 target revolver.",
    },
};
pub const gun_count = builds.len;

/// The recoil feel of a class: the reference of its numbers, and the shape
/// of its recoil pattern.
const Feel = struct {
    /// The calibre of the class reference. weapon.zig `table` has the
    /// interval and the kick of a gun of this calibre with the reference
    /// barrel, a medium weight and `stocked`.
    ref: Calibre,
    stocked: bool = true,
    /// The side kick against the up kick.
    sway: f32,
    /// The pattern of the side kick: a drift to one side (+ right), and a
    /// wave of `wobble` that moves `freq` radians a shot.
    bias: f32,
    wobble: f32,
    freq: f32,
    /// The up kick grows by this part over the first 8 shots of a string.
    ramp: f32,
    /// The camera goes back to the aim at this rate (1/s).
    recovery: f32,
    /// The head damage of a gun of the class is at least this. 100: a head
    /// hit kills inside `near`.
    head_min: f32 = 0,
};

fn feel(c: Class) Feel {
    return switch (c) {
        // The AK pattern climbs and drifts to the right in a slow wave.
        // A head hit from an AK kills at short range.
        .rifle => .{ .ref = .c7_62x39, .sway = 0.45, .bias = 0.35, .wobble = 0.7, .freq = 0.55, .ramp = 0.6, .recovery = 6, .head_min = 100 },
        // The AR pattern climbs straight, with a small drift to the left.
        .carbine => .{ .ref = .c5_56x45, .sway = 0.35, .bias = -0.15, .wobble = 0.6, .freq = 0.8, .ramp = 0.4, .recovery = 7 },
        // The bullpup kicks straight back into the shoulder.
        .bullpup => .{ .ref = .c5_56x45, .sway = 0.25, .bias = 0.05, .wobble = 0.5, .freq = 1.4, .ramp = 0.3, .recovery = 7 },
        // The SMG shakes fast from side to side.
        .smg => .{ .ref = .c9x19, .sway = 0.6, .bias = 0.15, .wobble = 0.9, .freq = 1.7, .ramp = 0.5, .recovery = 8 },
        .shotgun => .{ .ref = .g12, .sway = 0.4, .bias = 0.2, .wobble = 0.7, .freq = 2.3, .ramp = 0, .recovery = 4.5 },
        .sawn_off => .{ .ref = .g12, .stocked = false, .sway = 0.6, .bias = 0.3, .wobble = 0.8, .freq = 2.9, .ramp = 0, .recovery = 4 },
        // A handgun has no stock. Its class kick is for a two-hand grip.
        .pistol => .{ .ref = .c9x19, .stocked = false, .sway = 0.35, .bias = 0, .wobble = 0.8, .freq = 2.2, .ramp = 0.25, .recovery = 9 },
        .revolver => .{ .ref = .c357mag, .stocked = false, .sway = 0.3, .bias = 0.3, .wobble = 0.6, .freq = 1.2, .ramp = 0, .recovery = 5 },
        .knife, .grenade => unreachable,
    };
}

/// The class of a source model name, or null.
pub fn classOf(name: []const u8) ?Class {
    const prefixes = [_]struct { []const u8, Class }{
        .{ "AssaultRifle2_", .carbine },
        .{ "AssaultRifle_", .rifle },
        .{ "Bullpup_", .bullpup },
        .{ "SubmachineGun_", .smg },
        .{ "Shotgun_SawedOff", .sawn_off },
        .{ "Shotgun_", .shotgun },
        .{ "Pistol_", .pistol },
        .{ "Revolver_", .revolver },
        .{ "Bayonet", .knife },
    };
    for (prefixes) |p| if (std.mem.startsWith(u8, name, p[0])) return p[1];
    return null;
}

fn pow(x: f32, y: f32) f32 {
    return std.math.pow(f32, x, y);
}

/// The stats of one gun from its build.
pub fn derive(b: Build, number: u32) Stats {
    @setEvalBranchQuota(100_000);
    const class = classOf(b.name).?;
    const base = weapon.table[@backingInt(class)];
    const f = feel(class);
    const cal = rounds.get(b.calibre);
    const ref = rounds.get(f.ref);
    const wk = weights.get(b.weight);
    const r = std.math.clamp(b.barrel / cal.barrel, 0.4, 4);
    const no_stock = f.stocked and !b.stock;

    var st = base;
    st.calibre = cal.label;
    st.body = @round(cal.body * std.math.clamp(pow(r, 0.1), 0.9, 1.1));
    st.head = @max(@round(st.body * cal.head), f.head_min);
    st.pellets = cal.pellets;
    st.velocity = cal.velocity * pow(r, 0.2);
    st.bullet_d = cal.bullet_d;
    st.bullet_l = cal.bullet_l;
    // Buckshot: a longer barrel keeps the pellets together for longer, so
    // the barrel changes its fall-off and reach more.
    const buckshot = cal.pellets > 1;
    const reach = if (buckshot)
        std.math.clamp(pow(r, 0.8), 0.75, 1.6)
    else
        std.math.clamp(pow(r, 0.35), 0.75, 1.3);
    st.near = cal.near * reach;
    st.far = cal.far * reach;
    st.min_dmg = cal.min;
    // Only buckshot has a short reach. It grows with the barrel.
    st.range = if (buckshot) cal.reach * reach else cal.reach;

    // The cone. A barrel longer than the reference is a choke: the cone of
    // the buckshot is smaller, and the sights make it smaller again. A
    // slug in a shotgun is one bullet: a small cone, as a rifle.
    if (buckshot) {
        const choke = std.math.clamp(pow(cal.barrel / b.barrel, 2.5), 0.35, 1);
        st.spread = base.spread * choke;
        st.ads_tight = 1 - (1 - base.ads_tight) * choke;
    } else if (class == .shotgun or class == .sawn_off) {
        st.spread = base.spread * 0.12;
        st.ads_tight = 0.8;
    }

    // The time between shots keeps the damage a second of the class for
    // each calibre. A bigger round cycles more slowly. The barrel does not
    // change the rate.
    const shot = cal.body * @as(f32, @floatFromInt(cal.pellets));
    const ref_shot = ref.body * @as(f32, @floatFromInt(ref.pellets));
    st.interval = base.interval * shot / ref_shot;
    st.burst_gap = base.burst_gap * shot / ref_shot;

    // The recoil pattern.
    st.kick = base.kick * pow(cal.impulse / ref.impulse, 0.85) * wk.kick * (if (no_stock) @as(f32, 1.4) else 1);
    st.sway = st.kick * f.sway * (if (no_stock) @as(f32, 1.3) else 1);
    st.bias = f.bias;
    st.wobble = f.wobble;
    st.freq = f.freq;
    st.phase = 1.7 * @as(f32, @floatFromInt(number));
    st.ramp = f.ramp;
    st.recovery = f.recovery * wk.recovery * (if (no_stock) @as(f32, 0.6) else 1);
    st.bloom = base.bloom * (if (no_stock) @as(f32, 1.3) else 1);
    st.shove = base.shove * pow(cal.impulse / ref.impulse, 0.5) * (if (no_stock) @as(f32, 1.3) else 1);

    // The handling. A gun with no stock is shorter: quicker to take out
    // and to aim, and a little faster to carry.
    const short = b.bullpup or no_stock;
    st.speed = base.speed + wk.speed + (if (no_stock) @as(f32, 0.02) else 0);
    st.draw = base.draw * wk.draw * (if (short) @as(f32, 0.9) else 1);
    st.aim_speed = base.aim_speed * wk.aim * (if (short) @as(f32, 1.15) else 1);
    st.reload = base.reload * (if (b.bullpup) @as(f32, 1.14) else 1);
    if (b.mag > 0) {
        st.reserve = base.reserve / base.mag * b.mag;
        st.mag = b.mag;
    }
    return st;
}

/// The stats of each gun, in the order of `builds`.
pub const table: [gun_count]Stats = blk: {
    @setEvalBranchQuota(1_000_000);
    var t: [gun_count]Stats = undefined;
    var counts: [weapon.class_count]u32 = @splat(0);
    for (builds, 0..) |b, i| {
        const c = @backingInt(classOf(b.name).?);
        counts[c] += 1;
        t[i] = derive(b, counts[c]);
    }
    break :blk t;
};

// ---- Time to kill ------------------------------------------------------------

/// The share of the pellets that hit the body and the head of a player at
/// `dist` m, with a cone of half angle `cone`, aimed at the chest. The
/// pellets fall evenly in the cone (main.zig fire). The body is the legs
/// and the torso hit boxes (0.6 m wide, 1.2 m below the chest to 0.26 m
/// above it). The head box is 0.32 m.
pub fn pelletShare(dist: f32, cone: f32) struct { body: f32, head: f32 } {
    const n = 512;
    const radius = dist * @tan(cone);
    const golden = std.math.pi * (3 - @sqrt(5.0));
    var body: f32 = 0;
    var head: f32 = 0;
    for (0..n) |i| {
        const k: f32 = @floatFromInt(i);
        const rr = radius * @sqrt((k + 0.5) / n);
        const x = rr * @cos(k * golden);
        const y = rr * @sin(k * golden);
        if (@abs(x) <= 0.3 and y >= -1.2 and y <= 0.26) body += 1;
        if (@abs(x) <= 0.16 and y > 0.26 and y <= 0.58) head += 1;
    }
    return .{ .body = body / n, .head = head / n };
}

/// The time from the first shot to the shot that kills a player of 100
/// health at `dist` m: every bullet hits the body. Buckshot: the share of
/// the pellets that hit with the hip cone (`pelletShare`). Null when the gun
/// cannot kill at that distance with one magazine.
pub fn ttk(st: *const Stats, dist: f32) ?f32 {
    var per_shot: f32 = 0;
    if (st.pellets > 1) {
        if (dist > st.range) return null;
        const sh = pelletShare(dist, st.spread);
        const p: f32 = @floatFromInt(st.pellets);
        per_shot = p * (sh.body * st.damageAt(false, dist) + sh.head * st.damageAt(true, dist));
    } else per_shot = st.damageAt(false, dist);
    if (per_shot <= 0) return null;
    const shots: u32 = @intFromFloat(@min(1000, @ceil(100 / per_shot - 1e-4)));
    // A kill must come from one magazine.
    if (shots > st.mag) return null;
    const k = shots - 1;
    // The burst: `burst` rounds `burst_gap` apart, a burst each interval.
    const b = k / st.burst;
    const j = k % st.burst;
    return @as(f32, @floatFromInt(b)) * st.interval + @as(f32, @floatFromInt(j)) * st.burst_gap;
}

// ---- Compare ---------------------------------------------------------------

/// The stats on the compare bars (gun_compare.zig).
pub const Stat = enum { damage, rate, range, recoil, mobility, reload };
pub const stat_labels = std.enums.EnumArray(Stat, []const u8).init(.{
    .damage = "DAMAGE",
    .rate = "FIRE RATE",
    .range = "RANGE",
    .recoil = "RECOIL",
    .mobility = "MOBILITY",
    .reload = "RELOAD",
});

/// True when a higher value of the stat is better.
pub fn higherIsBetter(s: Stat) bool {
    return switch (s) {
        .recoil, .reload => false,
        else => true,
    };
}

/// The rounds a minute.
pub fn rpm(st: *const Stats) f32 {
    return 60 / st.interval * @as(f32, @floatFromInt(st.burst));
}

/// The distance in metres at which a hit does 75% of its full damage, or
/// the reach.
pub fn effectiveRange(st: *const Stats) f32 {
    if (st.min_dmg >= 0.75) return st.range;
    const d = st.near + (st.far - st.near) * 0.25 / (1 - st.min_dmg);
    return @min(d, st.range);
}

/// The recoil of one shot, in radians: the up kick and half the side kick.
pub fn recoilOf(st: *const Stats) f32 {
    return st.kick + 0.5 * st.sway;
}

/// The value of a stat: damage a shot (all the pellets), rounds a minute,
/// the range in m, the recoil in radians, the walk speed (1 = 100%) and the
/// reload in seconds.
pub fn value(st: *const Stats, s: Stat) f32 {
    return switch (s) {
        .damage => st.body * @as(f32, @floatFromInt(st.pellets)),
        .rate => rpm(st),
        .range => effectiveRange(st),
        .recoil => recoilOf(st),
        .mobility => st.speed,
        .reload => st.reload,
    };
}

/// The length of a bar, 0 to 1. The scale is for the slot, so that the
/// guns of one slot fill the bar. A value past the scale fills it.
pub fn bar(slot: weapon.Slot, s: Stat, v: f32) f32 {
    const primary = slot == .primary;
    const x = switch (s) {
        .damage => v / (if (primary) @as(f32, 65) else 80),
        .rate => v / (if (primary) @as(f32, 1000) else 600),
        .range => v / (if (primary) @as(f32, 80) else 50),
        .recoil => v / (if (primary) @as(f32, 0.03) else 0.1),
        .mobility => (v - 0.85) / 0.27,
        .reload => v / 3.5,
    };
    return std.math.clamp(x, 0.02, 1);
}
