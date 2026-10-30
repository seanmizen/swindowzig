// The DSP parts of the procedural sounds: a seeded noise source, biquad and
// one-pole filters, decaying modes, noise bursts and grains. The methods
// are the buffer synthesis of utils/tube-sounds (core/synth.ts and
// core/filters.ts), in Zig: modal synthesis (a strike excites resonant
// modes, and each mode is a decaying sine), band-passed noise bursts with
// an attack and an exponential decay, and RBJ cookbook biquads.
//
// Every function writes into a caller buffer of f32 samples at `rate`.
const std = @import("std");

/// The sample rate of every buffer. The browser resamples it to the rate of
/// the audio device.
pub const rate: f32 = 48000;

/// A small, fast, seeded random source (xorshift64*).
pub const Rng = struct {
    state: u64,

    pub fn init(seed: u64) Rng {
        return .{ .state = (seed *% 0x9E37_79B9_7F4A_7C15) | 1 };
    }

    pub fn next(r: *Rng) u64 {
        r.state ^= r.state >> 12;
        r.state ^= r.state << 25;
        r.state ^= r.state >> 27;
        return r.state *% 0x2545_F491_4F6C_DD1D;
    }

    /// A number in [0, 1).
    pub fn float(r: *Rng) f32 {
        return @as(f32, @floatFromInt(r.next() >> 40)) / 16777216.0;
    }

    /// White noise in [-1, 1).
    pub fn white(r: *Rng) f32 {
        return r.float() * 2 - 1;
    }

    /// A number from lo to hi.
    pub fn range(r: *Rng, lo: f32, hi: f32) f32 {
        return lo + (hi - lo) * r.float();
    }

    /// x times (1 +- spread), at random.
    pub fn jitter(r: *Rng, x: f32, spread: f32) f32 {
        return x * (1 + r.white() * spread);
    }
};

pub const Kind = enum { lowpass, highpass, bandpass };

/// A biquad filter (RBJ audio EQ cookbook), transposed direct form II. The
/// band-pass has a peak gain of 0 dB.
pub const Biquad = struct {
    b0: f32,
    b1: f32,
    b2: f32,
    a1: f32,
    a2: f32,
    z1: f32 = 0,
    z2: f32 = 0,

    pub fn init(kind: Kind, freq: f32, q: f32) Biquad {
        const f = std.math.clamp(freq, 10, rate * 0.45);
        const w = 2 * std.math.pi * f / rate;
        const cw = @cos(w);
        const alpha = @sin(w) / (2 * @max(q, 0.05));
        const a0 = 1 + alpha;
        const b: [3]f32 = switch (kind) {
            .lowpass => .{ (1 - cw) / 2, 1 - cw, (1 - cw) / 2 },
            .highpass => .{ (1 + cw) / 2, -(1 + cw), (1 + cw) / 2 },
            .bandpass => .{ alpha, 0, -alpha },
        };
        return .{ .b0 = b[0] / a0, .b1 = b[1] / a0, .b2 = b[2] / a0, .a1 = -2 * cw / a0, .a2 = (1 - alpha) / a0 };
    }

    pub fn process(f: *Biquad, x: f32) f32 {
        const y = f.b0 * x + f.z1;
        f.z1 = f.b1 * x - f.a1 * y + f.z2;
        f.z2 = f.b2 * x - f.a2 * y;
        return y;
    }
};

/// A one-pole low-pass (6 dB an octave): y += k (x - y). A cutoff at or
/// over the Nyquist frequency lets the signal through.
pub const OnePole = struct {
    k: f32,
    y: f32 = 0,

    pub fn init(cutoff: f32) OnePole {
        if (cutoff >= rate * 0.45) return .{ .k = 1 };
        return .{ .k = 1 - @exp(-2 * std.math.pi * @max(cutoff, 10) / rate) };
    }

    pub fn process(f: *OnePole, x: f32) f32 {
        f.y += f.k * (x - f.y);
        return f.y;
    }
};

/// The decay rate (1/s) of an amplitude that falls by 60 dB in t60 s.
pub fn decayRate(t60: f32) f32 {
    return @log(@as(f32, 1000)) / @max(t60, 1e-4);
}

/// The t60 of a mode of frequency `freq` in a material with the loss
/// factor `eta` (the internal friction, tan phi). The amplitude decays as
/// exp(-pi f eta t) (Klatzky, Pai and Krotkov 2000; van den Doel and Pai
/// 1998).
pub fn modeT60(freq: f32, eta: f32) f32 {
    return @log(@as(f32, 1000)) / (std.math.pi * freq * @max(eta, 1e-6));
}

/// The sample index of a time in seconds.
pub fn at(t: f32) usize {
    return @intFromFloat(@max(0, t) * rate);
}

/// Add one mode of a struck object from sample `start`: amp * e^(-t/tau)
/// * sin(2 pi f t + phase). It stops at -60 dB.
pub fn addMode(buf: []f32, start: usize, freq: f32, t60: f32, amp: f32, phase: f32) void {
    if (freq <= 0 or freq >= rate * 0.47 or start >= buf.len) return;
    const k = @exp(-decayRate(t60) / rate);
    const w = 2 * std.math.pi * freq / rate;
    const cr = @cos(w);
    const sr = @sin(w);
    var c = @cos(phase);
    var s = @sin(phase);
    var g = amp;
    const floor = @abs(amp) * 1e-3;
    var i = start;
    var n: usize = 0;
    while (i < buf.len and @abs(g) > floor) : (i += 1) {
        buf[i] += g * s;
        const ns = s * cr + c * sr;
        c = c * cr - s * sr;
        s = ns;
        g *= k;
        n += 1;
        // Keep the phasor on the unit circle.
        if (n % 1024 == 0) {
            const m = 1 / @sqrt(c * c + s * s);
            c *= m;
            s *= m;
        }
    }
}

/// Filtered noise for a burst: one filter, or two in series.
pub const Shape = struct {
    kind: Kind,
    freq: f32,
    q: f32 = 0.707,
    /// A second filter after the first, or null.
    then: ?struct { kind: Kind, freq: f32, q: f32 = 0.707 } = null,
};

/// Add a burst of filtered noise from sample `start`: a linear attack, then
/// an exponential decay to -60 dB in t60.
pub fn addNoise(buf: []f32, rng: *Rng, start: usize, shape: Shape, attack: f32, t60: f32, amp: f32) void {
    if (start >= buf.len) return;
    var f1 = Biquad.init(shape.kind, shape.freq, shape.q);
    var f2: ?Biquad = if (shape.then) |t| Biquad.init(t.kind, t.freq, t.q) else null;
    const k = @exp(-decayRate(t60) / rate);
    const a_n = @max(1, attack * rate);
    const total = @min(buf.len - start, at(attack + t60 * 1.1) + 1);
    var g: f32 = 1;
    for (0..total) |i| {
        var x = f1.process(rng.white());
        if (f2) |*f| x = f.process(x);
        const fi: f32 = @floatFromInt(i);
        const env = if (fi < a_n) fi / a_n else g;
        if (fi >= a_n) g *= k;
        buf[start + i] += amp * env * x;
    }
}

/// Grains: short decaying modes at random times, as fragments that fall
/// or stones that click. The level falls over the spread, with half-life
/// `spread / 2`.
pub const Grains = struct {
    count: usize,
    /// The first grain is at `from` s, and the last before `from + spread`.
    from: f32 = 0,
    spread: f32,
    freq_lo: f32,
    freq_hi: f32,
    t60_lo: f32,
    t60_hi: f32,
    amp: f32,
};

pub fn addGrains(buf: []f32, rng: *Rng, g: Grains) void {
    for (0..g.count) |_| {
        // More grains early: the square of a uniform number.
        const u = rng.float();
        const t = g.from + g.spread * u * u;
        const level = g.amp * rng.range(0.4, 1) * std.math.pow(f32, 0.5, (t - g.from) / @max(g.spread * 0.5, 1e-3));
        const f = @exp(rng.range(@log(g.freq_lo), @log(g.freq_hi)));
        addMode(buf, at(t), f, rng.range(g.t60_lo, g.t60_hi), level, rng.float() * std.math.tau);
    }
}

/// The largest absolute sample.
pub fn peak(buf: []const f32) f32 {
    var m: f32 = 0;
    for (buf) |x| m = @max(m, @abs(x));
    return m;
}

/// Scale `buf` so its peak is `to`. A silent buffer stays silent.
pub fn normalise(buf: []f32, to: f32) void {
    const m = peak(buf);
    if (m <= 1e-9) return;
    const k = to / m;
    for (buf) |*x| x.* *= k;
}

/// The length of `buf` up to the last sample above `floor`.
pub fn trimmed(buf: []const f32, floor: f32) usize {
    var n = buf.len;
    while (n > 0 and @abs(buf[n - 1]) < floor) n -= 1;
    return n;
}
