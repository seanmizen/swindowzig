// The space between a sound and the listener.
//
// - The head: the far ear hears a sound later (the interaural time
//   difference, from Woodworth's spherical head) and quieter and duller
//   (the head shadow). A sound from behind is a little duller in both ears.
// - The path: spherical spreading (1/r), the air absorption (ISO 9613-1:
//   the high frequencies fall first), and the delay r / c.
// - The room: image sources in up to four flat reflectors (the floor, the
//   ceiling, the nearest walls), and a diffuse tail.
const std = @import("std");
const dsp = @import("dsp.zig");

pub const V3 = @Vector(3, f32);

pub fn dot(a: V3, b: V3) f32 {
    return @reduce(.Add, a * b);
}
pub fn len(a: V3) f32 {
    return @sqrt(dot(a, a));
}
pub fn scale(a: V3, k: f32) V3 {
    return a * @as(V3, @splat(k));
}
pub fn norm(a: V3) V3 {
    const l = len(a);
    return if (l > 1e-6) scale(a, 1 / l) else a;
}

/// The speed of sound in air at 20 C, m/s.
pub const sound_speed: f32 = 343;
/// The radius of the head, m (Woodworth's spherical head).
const head_radius: f32 = 0.0875;

pub const Listener = struct {
    pos: V3,
    /// Unit vectors: the right side of the head and the facing direction.
    right: V3,
    forward: V3,
};

/// A flat reflector: the points p with dot(n, p) = d. The listener is on
/// the side that n points to. k is the pressure reflection coefficient.
pub const Plane = struct { n: V3, d: f32, k: f32 };

/// The mirror image of p in the plane.
pub fn mirror(p: V3, pl: Plane) V3 {
    return p - scale(pl.n, 2 * (dot(pl.n, p) - pl.d));
}

/// The distance of p in front of the plane (negative behind it).
pub fn front(p: V3, pl: Plane) f32 {
    return dot(pl.n, p) - pl.d;
}

/// The room around the listener.
pub const Room = struct {
    planes: [4]Plane = undefined,
    count: usize = 0,
    /// The diffuse tail: the time to fall by 60 dB, in s.
    t60: f32 = 0.3,
    /// The energy of the tail against the energy of the direct sound at
    /// 1 m. The tail stays the same with distance, as in a diffuse field,
    /// so a far sound is mostly tail.
    wet: f32 = 0.02,

    pub fn add(r: *Room, p: Plane) void {
        if (r.count == r.planes.len) return;
        r.planes[r.count] = p;
        r.count += 1;
    }

    pub fn reflectors(r: *const Room) []const Plane {
        return r.planes[0..r.count];
    }
};

/// The stereo samples of one event. The first sample is at `t0` s after
/// the event (a shot, a hit): the caller plays the buffer with that delay.
pub const Out = struct {
    l: []f32,
    r: []f32,
    /// The samples in use.
    n: usize = 0,
    t0: f32 = 0,

    pub fn begin(o: *Out, t0: f32) void {
        o.n = 0;
        o.t0 = t0;
    }

    /// Make the samples up to `end` part of the buffer (zero the new ones).
    /// Returns the new end, at most the buffer size.
    pub fn reserve(o: *Out, end: usize) usize {
        const e = @min(end, o.l.len, o.r.len);
        if (e > o.n) {
            @memset(o.l[o.n..e], 0);
            @memset(o.r[o.n..e], 0);
            o.n = e;
        }
        return e;
    }

    /// The sample index of a time after the event.
    pub fn index(o: *const Out, time: f32) usize {
        return @intFromFloat(@round(@max(0, time - o.t0) * dsp.rate));
    }
};

/// One arrival of a sound at the listener.
pub const Arrival = struct {
    /// Seconds after the event.
    time: f32,
    gain: f32,
    /// The direction from the listener to the apparent source (unit).
    dir: V3,
    /// The low-pass cutoff of the path: the air absorption, and occlusion.
    cutoff: f32 = 20000,
};

/// The air absorption as a one-pole cutoff: about 16 kHz at 10 m, 6.6 kHz
/// at 50 m and 4.5 kHz at 100 m (from the ISO 9613-1 coefficients at
/// 20 C and 50 to 70% humidity, where the loss is 3 dB).
pub fn airCutoff(dist: f32) f32 {
    return @min(20000, 16000 * std.math.pow(f32, 10 / @max(dist, 1), 0.55));
}

/// Spherical spreading: 1 out to `ref` m, then ref / r.
pub fn spreading(dist: f32, ref: f32) f32 {
    return ref / @max(dist, ref);
}

/// The direct arrival from a source at `src`, at the time `emit` after the
/// event. `ref`: the distance at which the gain is 1.
pub fn direct(lis: Listener, src: V3, emit: f32, c: f32, ref: f32) Arrival {
    const d = len(src - lis.pos);
    return .{ .time = emit + d / c, .gain = spreading(d, ref), .dir = norm(src - lis.pos), .cutoff = airCutoff(d) };
}

/// The first reflections of a source at `src` (image sources): one for
/// each reflector with the source and the listener in front of it.
pub fn reflections(buf: []Arrival, lis: Listener, room: *const Room, src: V3, emit: f32, c: f32, ref: f32) []Arrival {
    var n: usize = 0;
    for (room.reflectors()) |pl| {
        if (n == buf.len) break;
        if (front(src, pl) <= 0.01 or front(lis.pos, pl) <= 0.01) continue;
        const img = mirror(src, pl);
        const d = len(img - lis.pos);
        buf[n] = .{ .time = emit + d / c, .gain = pl.k * spreading(d, ref), .dir = norm(img - lis.pos), .cutoff = airCutoff(d) };
        n += 1;
    }
    return buf[0..n];
}

/// The interaural time difference (s) of a source at this lateral angle:
/// Woodworth, (a / c) (theta + sin theta).
pub fn itd(side: f32) f32 {
    const theta = std.math.asin(std.math.clamp(@abs(side), 0, 1));
    return head_radius / sound_speed * (theta + @sin(theta));
}

/// Add `mono` to both ears for one arrival: the near ear first, the far
/// ear later, quieter and duller.
pub fn place(out: *Out, mono: []const f32, a: Arrival, lis: Listener) void {
    const side = std.math.clamp(dot(a.dir, lis.right), -1, 1);
    const ahead = dot(a.dir, lis.forward);
    const back_cut: f32 = if (ahead < 0) 20000 - 11000 * @min(1, -ahead) else 20000;
    const near_cut = @min(a.cutoff, back_cut);
    const far_cut = @min(near_cut, 18000 - 14500 * @abs(side));
    const far_gain = a.gain * (1 - 0.45 * @abs(side));
    const near_ch = if (side >= 0) out.r else out.l;
    const far_ch = if (side >= 0) out.l else out.r;
    addEar(out, near_ch, mono, a.time, a.gain, near_cut);
    addEar(out, far_ch, mono, a.time + itd(side), far_gain, far_cut);
}

fn addEar(out: *Out, ch: []f32, mono: []const f32, time: f32, gain: f32, cutoff: f32) void {
    if (gain < 1e-5) return;
    const start = out.index(time);
    const end = out.reserve(start + mono.len);
    if (start >= end) return;
    var lp = dsp.OnePole.init(cutoff);
    for (start..end) |i| ch[i] += gain * lp.process(mono[i - start]);
}

/// The energy of a signal (the sum of the squares / rate).
pub fn energy(buf: []const f32) f32 {
    var e: f32 = 0;
    for (buf) |x| e += x * x;
    return e / dsp.rate;
}

/// Add the diffuse tail of the room, from `time` after the event: noise
/// that builds up for 10 ms, then falls by 60 dB in room.t60. The two ears
/// get different noise. `dry` is the energy of the direct sound as it
/// would be at 1 m. `bright` is the low-pass cutoff of the tail.
pub fn addTail(out: *Out, rng: *dsp.Rng, time: f32, dry: f32, room: *const Room, bright: f32) void {
    const e = dry * room.wet;
    if (e <= 1e-12 or room.t60 <= 0.01) return;
    // The integral of (a e^(-k t))^2 is a^2 / (2 k).
    const k = dsp.decayRate(room.t60);
    // White noise in [-1, 1) has a variance of 1/3, and the low-pass keeps
    // about bright / (rate / 2) of its power.
    const cut = std.math.clamp(bright, 200, dsp.rate * 0.45);
    const amp = @sqrt(e * 2 * k) * @sqrt(3 * (dsp.rate / 2) / cut);
    const start = out.index(time);
    const end = out.reserve(start + dsp.at(room.t60));
    if (start >= end) return;
    const step = @exp(-k / dsp.rate);
    var lpl = dsp.Biquad.init(.lowpass, cut, 0.707);
    var lpr = dsp.Biquad.init(.lowpass, cut, 0.707);
    var hpl = dsp.Biquad.init(.highpass, 120, 0.707);
    var hpr = dsp.Biquad.init(.highpass, 120, 0.707);
    const build: f32 = 0.01 * dsp.rate;
    var g = amp;
    for (start..end) |i| {
        const fi: f32 = @floatFromInt(i - start);
        const env = g * @min(1, fi / build);
        out.l[i] += env * hpl.process(lpl.process(rng.white()));
        out.r[i] += env * hpr.process(lpr.process(rng.white()));
        g *= step;
    }
}
