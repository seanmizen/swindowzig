// The sound of a bullet that goes past the listener: a near miss.
//
// Supersonic (v > c): the bullet pulls a conical shock wave, the Mach
// cone, with the half angle asin(1/M), M = v / c. The listener hears the
// shock as a crack: an N-wave, a sudden rise of pressure, a straight fall
// to the same depth below the air pressure, and a sudden return. The shock
// that the listener hears leaves the path where the angle between the path
// and the line to the listener is acos(1/M). That point is before the
// nearest point. So the crack comes from a point of the path between the
// shooter and the nearest point. It never arrives after the muzzle report:
// the two arrive together at the edge of the cone, and downrange the crack
// comes first.
//
// Subsonic (v < c): there is no shock wave. The listener hears the noise
// of the turbulent wake of the bullet as a whiz, with a Doppler shift:
// high and loud while the bullet comes, low after it goes. The muzzle
// report arrives first.
//
// The geometry. x is the distance along the path from the muzzle to the
// point nearest the listener, b the miss distance, d the bullet diameter
// and l its length, p0 the air pressure:
//   emission point     s* = x - b / sqrt(M^2 - 1), on the path or no crack
//   crack arrival      t  = s* / v + |listener - point(s*)| / c
//                         = (x + b sqrt(M^2 - 1)) / v
//   muzzle arrival     t  = |listener - muzzle| / c
//   N-wave peak (Pa)   dp = 0.53 p0 (M^2 - 1)^(1/8) d / (b^(3/4) l^(1/4))
//   N-wave length (s)  T  = 1.82 M b^(1/4) d / (c (M^2 - 1)^(3/8) l^(1/4))
// The N-wave formulas are Whitham's far-field result (G. B. Whitham, "The
// flow pattern of a supersonic projectile", Comm. Pure Appl. Math. 5,
// 1952). R. Stoughton ("Measurements of small-caliber ballistic shock waves
// in air", J. Acoust. Soc. Am. 102, 1997) measured them for small arms, and
// R. C. Maher ("Acoustical characterization of gunshots", IEEE SAFE 2007)
// uses them for the shot geometry. Close to M = 1 the far-field formulas do
// not hold, so M^2 - 1 is at least 0.09 here.
//
// The whiz is an aeroacoustic estimate, not a measurement: band-passed
// noise at the vortex shedding frequency St v / d (St about 0.2), a level
// in proportion to v^3 (a dipole source: the power goes as v^6, Curle and
// Lighthill), 1 / r spreading, and the Doppler factor
// D = 1 / (1 - M cos(phi)) with the convective gain D^2 (A. P. Dowling and
// J. E. Ffowcs Williams, "Sound and Sources of Sound", 1983). A moving
// source read through a delay line gives the Doppler shift by itself.
//
// The bullet keeps its speed over the path: the ranges of a game are short.
const std = @import("std");
const dsp = @import("dsp.zig");
const space = @import("space.zig");
const V3 = space.V3;
const dot = space.dot;
const len = space.len;
const scale = space.scale;
const norm = space.norm;

/// The air pressure, Pa.
pub const p0: f32 = 101325;
/// The smallest miss distance of the model, m: about the radius of a head.
pub const min_miss: f32 = 0.15;

pub const Bullet = struct {
    /// The muzzle.
    from: V3,
    /// The direction of flight (unit).
    dir: V3,
    /// The path from the muzzle to its end (a hit, or the reach), m.
    length: f32,
    /// m/s.
    speed: f32,
    /// The diameter and the length of the bullet, m.
    diameter: f32,
    body: f32,
};

pub const Crack = struct {
    /// The arrival time, s after the shot.
    time: f32,
    /// The point on the path where the heard shock leaves it.
    from: V3,
    /// The peak overpressure (Pa) and the length (s) of the N-wave.
    peak: f32,
    width: f32,
};

/// The geometry of one bullet and one listener.
pub const Pass = struct {
    /// The distance along the path to the point nearest the listener, and
    /// the miss distance (at least min_miss).
    along: f32,
    miss: f32,
    mach: f32,
    /// The arrival time of the muzzle report, s after the shot.
    muzzle: f32,
    /// The time when the bullet is at the nearest point.
    nearest: f32,
    /// The crack, or null: a subsonic bullet, a listener behind the Mach
    /// cone of the muzzle, or a path that ends before the emission point.
    crack: ?Crack,
};

/// Whitham's N-wave at the miss distance `miss` (see the top of the file).
pub fn nwave(mach: f32, miss: f32, d: f32, l: f32, c: f32) struct { peak: f32, width: f32 } {
    const k2 = @max(mach * mach - 1, 0.09);
    const l4 = std.math.pow(f32, @max(l, d), 0.25);
    const b = @max(miss, min_miss);
    return .{
        .peak = 0.53 * p0 * std.math.pow(f32, k2, 0.125) * d / (std.math.pow(f32, b, 0.75) * l4),
        .width = 1.82 * @max(mach, 1) * std.math.pow(f32, b, 0.25) * d / (c * std.math.pow(f32, k2, 0.375) * l4),
    };
}

/// The geometry of bullet `b` for a listener at `p`. c: the speed of sound.
pub fn pass(b: Bullet, p: V3, c: f32) Pass {
    const w = p - b.from;
    const x = dot(w, b.dir);
    const miss = @max(min_miss, len(w - scale(b.dir, x)));
    const mach = b.speed / c;
    var out: Pass = .{ .along = x, .miss = miss, .mach = mach, .muzzle = len(w) / c, .nearest = x / b.speed, .crack = null };
    if (mach <= 1) return out;
    const k = @sqrt(mach * mach - 1);
    const s = x - miss / k;
    if (s < 0 or s > b.length) return out;
    const from = b.from + scale(b.dir, s);
    const n = nwave(mach, miss, b.diameter, b.body, c);
    out.crack = .{ .time = s / b.speed + len(p - from) / c, .from = from, .peak = n.peak, .width = n.width };
    return out;
}

/// Add an N-wave from time t (s, in the buffer): +peak, a straight fall to
/// -peak over `width` s, then 0. Each sample is the mean of the wave over
/// the sample time (a box filter), so a wave of a few samples does not
/// alias.
pub fn addNWave(buf: []f32, t: f32, width: f32, peak: f32) void {
    const dt = 1 / dsp.rate;
    const t1 = t + width;
    const first: usize = @intFromFloat(@floor(@max(0, t) * dsp.rate));
    const last: usize = @min(buf.len, @as(usize, @intFromFloat(@ceil(t1 * dsp.rate))) + 1);
    var i = first;
    while (i < last) : (i += 1) {
        const fi: f32 = @floatFromInt(i);
        const a = @max(fi * dt, t);
        const b = @min((fi + 1) * dt, t1);
        if (b <= a) continue;
        // The integral of peak (1 - 2 (u - t) / width) from a to b.
        const area = (b - a) - ((b - t) * (b - t) - (a - t) * (a - t)) / width;
        buf[i] += peak * area * dsp.rate;
    }
}

pub const Options = struct {
    c: f32 = space.sound_speed,
    /// The largest miss distance that makes a sound, m.
    max_miss: f32 = 25,
    /// The sample value of 1000 Pa of crack overpressure.
    crack_level: f32 = 1,
    /// The peak level of the whiz at a 1 m miss, for a 9 mm bullet at
    /// 300 m/s.
    whiz_level: f32 = 0.45,
    /// A blocked path (a wall between the path and the listener): the
    /// gain and the cutoff of the direct sound.
    occlusion: f32 = 1,
    occlusion_cutoff: f32 = 20000,
};

/// Render the near miss of bullet `b` into `out`, from `out.t0`. `mono`
/// is scratch memory. Returns false when the listener hears no crack and
/// no whiz: the miss is too far, the listener is behind the Mach cone of
/// the muzzle, or the path ends first.
pub fn render(out: *space.Out, mono: []f32, b: Bullet, lis: space.Listener, room: *const space.Room, rng: *dsp.Rng, opt: Options) bool {
    const p = pass(b, lis.pos, opt.c);
    if (p.miss > opt.max_miss) return false;
    if (p.mach > 1) {
        const cr = p.crack orelse return false;
        renderCrack(out, mono, b, p, cr, lis, room, rng, opt);
        return true;
    }
    return renderWhiz(out, mono, b, p, lis, room, rng, opt);
}

/// The vortex shedding frequency of the wake, Hz.
fn wakeFreq(b: Bullet) f32 {
    return std.math.clamp(0.2 * b.speed / @max(b.diameter, 1e-3), 600, 7000);
}

/// One N-wave with the scatter after it, into `mono` from 1 ms. Returns
/// the samples in use.
fn crackSignal(mono: []f32, rng: *dsp.Rng, width: f32, amp: f32, wake: f32, wake_freq: f32) []f32 {
    const n = @min(mono.len, dsp.at(0.001 + width + 0.08));
    const m = mono[0..n];
    @memset(m, 0);
    addNWave(m, 0.001, width, amp);
    // An estimate, not a measured part: bright scatter from the near
    // surfaces for a few ms after the shock. It makes a wave of a few
    // samples read as a crack on small speakers.
    dsp.addNoise(m, rng, dsp.at(0.001 + width), .{ .kind = .highpass, .freq = 2500, .then = .{ .kind = .lowpass, .freq = 12000 } }, 0.0002, 0.006, amp * 0.3);
    // The wake of a close bullet: a short hiss after the crack.
    if (wake > 0) dsp.addNoise(m, rng, dsp.at(0.0015), .{ .kind = .bandpass, .freq = wake_freq, .q = 1 }, 0.002, 0.05, wake);
    return m;
}

fn renderCrack(out: *space.Out, mono: []f32, b: Bullet, p: Pass, cr: Crack, lis: space.Listener, room: *const space.Room, rng: *dsp.Rng, opt: Options) void {
    out.begin(cr.time - 0.003);
    const amp = @min(1.2, cr.peak / 1000 * opt.crack_level);
    const wake = if (p.miss < 4) amp * 0.15 / @max(p.miss, 0.5) else 0;
    const direct = crackSignal(mono, rng, cr.width, amp, wake, wakeFreq(b));
    const dry = space.energy(direct);
    const r_from = len(cr.from - lis.pos);
    space.place(out, direct, .{
        .time = cr.time - 0.001,
        .gain = opt.occlusion,
        .dir = norm(cr.from - lis.pos),
        .cutoff = @min(space.airCutoff(r_from), opt.occlusion_cutoff),
    }, lis);

    // The reflections: the crack that an image listener in each reflector
    // would hear, with its own geometry, comes back from the image of its
    // emission point.
    for (room.reflectors()) |pl| {
        if (space.front(lis.pos, pl) <= 0.01) continue;
        const pm = pass(b, space.mirror(lis.pos, pl), opt.c);
        const rc = pm.crack orelse continue;
        if (space.front(rc.from, pl) <= 0.01) continue;
        const ra = @min(1.2, rc.peak / 1000 * opt.crack_level);
        const sig = crackSignal(mono, rng, rc.width, ra, 0, 0);
        const img = space.mirror(rc.from, pl);
        space.place(out, sig, .{
            .time = rc.time - 0.001,
            .gain = pl.k,
            .dir = norm(img - lis.pos),
            .cutoff = space.airCutoff(len(img - lis.pos)),
        }, lis);
    }

    // The tail. The energy of an N-wave falls as b^-1.25 (peak^2 times
    // length), so this is the energy at a 1 m miss.
    const b1 = std.math.pow(f32, std.math.clamp(p.miss, 1, 6), 1.25);
    space.addTail(out, rng, cr.time + 0.006, dry * b1, room, 7000);
}

fn renderWhiz(out: *space.Out, mono: []f32, b: Bullet, p: Pass, lis: space.Listener, room: *const space.Room, rng: *dsp.Rng, opt: Options) bool {
    const v = b.speed;
    const mach = p.mach;
    // The part of the path that the listener can hear: 15 m each way from
    // the nearest point.
    const s_a = std.math.clamp(p.along - 15, 0, b.length);
    const s_b = std.math.clamp(p.along + 15, 0, b.length);
    if (s_b - s_a < 0.05) return false;
    const tau_a = s_a / v;
    const tau_b = s_b / v;
    const t_a = tau_a + len(lis.pos - (b.from + scale(b.dir, s_a))) / opt.c;
    const t_b = tau_b + len(lis.pos - (b.from + scale(b.dir, s_b))) / opt.c;

    // The source: the wake noise in the frame of the bullet, one sample
    // for each 1 / rate s of flight. A broad band and a narrow band (a
    // whistle) at the shedding frequency, under 8 kHz so the Doppler
    // shift stays under the Nyquist frequency.
    const n_src = @min(mono.len, @as(usize, @intFromFloat((tau_b - tau_a) * dsp.rate)) + 2);
    const src = mono[0..n_src];
    const f0 = wakeFreq(b);
    var broad = dsp.Biquad.init(.bandpass, f0, 1.2);
    var narrow = dsp.Biquad.init(.bandpass, f0, 6);
    var lp = dsp.Biquad.init(.lowpass, 8000, 0.707);
    for (src) |*x| {
        const w = rng.white();
        x.* = lp.process(broad.process(w) + 0.6 * narrow.process(w));
    }
    dsp.normalise(src, 1);

    // The level: v^3 and the diameter. At a 1 m miss the peak is about
    // whiz_level for a 9 mm bullet at 300 m/s. The factor 0.46 comes from
    // a render of that pass.
    const level = opt.whiz_level * 0.46 * std.math.pow(f32, v / 300, 3) * (b.diameter / 0.009) * opt.occlusion;

    out.begin(t_a);
    const n_out = @as(usize, @intFromFloat((t_b - t_a) * dsp.rate)) + 1;
    const end = out.reserve(n_out);
    var occ = dsp.OnePole.init(opt.occlusion_cutoff);
    var tau = tau_a;
    var e: f32 = 0;
    for (0..end) |j| {
        const t = t_a + @as(f32, @floatFromInt(j)) / dsp.rate;
        // Solve tau + R(tau) / c = t (Newton). It has one root: below
        // M = 1 the left side always grows.
        var pos: V3 = undefined;
        var r: f32 = 1;
        var cos_phi: f32 = 0;
        for (0..3) |_| {
            pos = b.from + scale(b.dir, v * tau);
            const w = lis.pos - pos;
            r = @max(len(w), 1e-3);
            cos_phi = dot(b.dir, w) / r;
            const f = tau + r / opt.c - t;
            tau = std.math.clamp(tau - f / (1 - mach * cos_phi), tau_a, tau_b);
        }
        const dop = 1 / @max(1 - mach * cos_phi, 0.4);
        const gain = level * dop * dop / @max(r, 0.3);
        const fi = (tau - tau_a) * dsp.rate;
        const k: usize = @min(src.len - 2, @as(usize, @intFromFloat(fi)));
        const frac = fi - @as(f32, @floatFromInt(k));
        const x = occ.process(gain * (src[k] + (src[k + 1] - src[k]) * frac));
        // Equal-power pan toward the bullet: it moves across the head.
        const side = std.math.clamp(dot(norm(pos - lis.pos), lis.right), -1, 1);
        out.l[j] += x * @sqrt((1 - side) / 2);
        out.r[j] += x * @sqrt((1 + side) / 2);
        e += x * x;
    }
    const dry = e / dsp.rate;
    space.addTail(out, rng, p.nearest + p.miss / opt.c, dry, room, 4000);
    return true;
}
