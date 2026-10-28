// The sound of a bullet that hits a surface: one recipe for each material.
//
// Each recipe is modal synthesis with noise (the methods of
// utils/tube-sounds core/synth.ts):
//   - the strike: a short burst of filtered noise. A hard material gives a
//     bright, short burst, a soft one a dull, longer burst.
//   - the modes: decaying sines. The loss factor eta of the material sets
//     the decay of a mode at f: e^(-pi f eta t). Glass has a small loss
//     and rings. Wood and stone have a large loss. Bolts and frames hold
//     the steel of a map, or the ground holds it. The structure damps the
//     steel a lot, so it rings only for a short time. The decay against
//     the frequency is the strongest cue to a material (R. L. Klatzky,
//     D. K. Pai and E. P. Krotkov, "Perception of material from contact
//     sounds", Presence 9, 2000; K. van den Doel, P. G. Kry and D. K. Pai,
//     "FoleyAutomatic", SIGGRAPH 2001).
//   - the debris: grains, as fragments of concrete, brick, tile and glass,
//     or stones of the track ballast, that click and fall.
//   - the body: a low thud of the mass that takes the hit (flesh, earth,
//     steel). Low-passed noise gives a thud with no pitch.
//
// The levels and the frequencies are estimates from the character of each
// material, not measurements of bullet hits.
const std = @import("std");
const dsp = @import("dsp.zig");
const space = @import("space.zig");
const V3 = space.V3;

/// The material of a surface. Each one has its own impact sound.
pub const Material = enum {
    concrete,
    brick,
    plaster,
    tile,
    metal,
    sheet_metal,
    glass,
    wood,
    ballast,
    earth,
    fabric,
    flesh,
};

pub const Info = struct {
    /// What the material is.
    what: []const u8,
    /// The pressure reflection coefficient of a wall of it.
    reflect: f32,
    /// The low-pass cutoff of its room tail, Hz.
    bright: f32,
    /// The peak level at 1 m for a rifle bullet (energy 1).
    loud: f32,
    /// The length of the strike, s.
    length: f32,
};

pub const info = std.enums.EnumArray(Material, Info).init(.{
    .concrete = .{ .what = "concrete, stone and paving: a sharp crack, a thud and grit", .reflect = 0.9, .bright = 5000, .loud = 0.9, .length = 0.35 },
    .brick = .{ .what = "brick: a duller crack and more crumble", .reflect = 0.85, .bright = 3500, .loud = 0.85, .length = 0.4 },
    .plaster = .{ .what = "painted plaster and render: a soft crack and a puff", .reflect = 0.8, .bright = 3000, .loud = 0.7, .length = 0.3 },
    .tile = .{ .what = "ceramic tile and slate: a brittle tink and shards", .reflect = 0.95, .bright = 7000, .loud = 0.95, .length = 0.35 },
    .metal = .{ .what = "solid steel and iron (rails, posts, frames): a click, a heavy thud and a short low ring", .reflect = 0.95, .bright = 4000, .loud = 0.9, .length = 0.6 },
    .sheet_metal = .{ .what = "hollow steel panels (containers, trains, doors, signs): a hollow doof and a low boom", .reflect = 0.9, .bright = 3000, .loud = 1.0, .length = 0.6 },
    .glass = .{ .what = "glass: a bright crack and falling shards", .reflect = 0.95, .bright = 9000, .loud = 0.95, .length = 0.6 },
    .wood = .{ .what = "wood: a hollow knock and splinters", .reflect = 0.75, .bright = 3000, .loud = 0.8, .length = 0.4 },
    .ballast = .{ .what = "track ballast (loose stones): a chuff and a clatter of stones", .reflect = 0.5, .bright = 5000, .loud = 0.75, .length = 0.45 },
    .earth = .{ .what = "soil and grass: a dull thup and a spray of dirt", .reflect = 0.45, .bright = 1500, .loud = 0.55, .length = 0.4 },
    .fabric = .{ .what = "cloth and rubber: a soft thup", .reflect = 0.25, .bright = 1000, .loud = 0.3, .length = 0.12 },
    .flesh = .{ .what = "a body: a wet slap and a thud", .reflect = 0.4, .bright = 1200, .loud = 0.6, .length = 0.25 },
});

/// Render the dry sound of a bullet strike on `m` into `buf` (mono, from
/// sample 0). `energy` is about 0.4 for a buckshot pellet, 1 for a rifle
/// bullet, and at most 2: the level goes as its square root. Returns the
/// number of samples in use.
pub fn strike(buf: []f32, m: Material, energy: f32, rng: *dsp.Rng) usize {
    const in = info.get(m);
    const n = @min(buf.len, dsp.at(in.length));
    const b = buf[0..n];
    @memset(b, 0);
    const R = struct {
        b: []f32,
        rng: *dsp.Rng,
        fn noise(s: @This(), at: f32, shape: dsp.Shape, attack: f32, t60: f32, amp: f32) void {
            var sh = shape;
            sh.freq = s.rng.jitter(sh.freq, 0.08);
            dsp.addNoise(s.b, s.rng, dsp.at(at), sh, attack, t60, amp);
        }
        fn mode(s: @This(), at: f32, freq: f32, t60: f32, amp: f32) void {
            dsp.addMode(s.b, dsp.at(at), freq, t60, amp, s.rng.float() * std.math.tau);
        }
        /// A mode with the decay of the loss factor eta.
        fn ring(s: @This(), freq: f32, eta: f32, amp: f32) void {
            s.mode(0, freq, dsp.modeT60(freq, eta), amp);
        }
        /// `count` modes at random frequencies from lo to hi (log-uniform),
        /// with the decay of the loss factor eta.
        fn cluster(s: @This(), count: usize, lo: f32, hi: f32, eta: f32, amp: f32) void {
            for (0..count) |_| s.ring(@exp(s.rng.range(@log(lo), @log(hi))), eta, amp * s.rng.range(0.5, 1));
        }
        fn grains(s: @This(), g: dsp.Grains) void {
            dsp.addGrains(s.b, s.rng, g);
        }
    };
    const r: R = .{ .b = b, .rng = rng };
    switch (m) {
        .concrete => {
            r.noise(0, .{ .kind = .bandpass, .freq = 3500, .q = 0.9 }, 0.0002, 0.008, 1.0);
            r.noise(0, .{ .kind = .highpass, .freq = 6000 }, 0.0001, 0.003, 0.5);
            r.mode(0, rng.jitter(160, 0.1), 0.045, 0.5);
            r.mode(0, rng.jitter(340, 0.1), 0.03, 0.25);
            r.grains(.{ .count = 14, .from = 0.004, .spread = 0.16, .freq_lo = 1800, .freq_hi = 6000, .t60_lo = 0.004, .t60_hi = 0.012, .amp = 0.18 });
            r.noise(0.003, .{ .kind = .bandpass, .freq = 1800, .q = 0.7 }, 0.005, 0.18, 0.06);
        },
        .brick => {
            r.noise(0, .{ .kind = .bandpass, .freq = 2400, .q = 0.8 }, 0.0002, 0.01, 1.0);
            r.mode(0, rng.jitter(120, 0.1), 0.055, 0.6);
            r.mode(0, rng.jitter(260, 0.1), 0.035, 0.3);
            r.grains(.{ .count = 18, .from = 0.004, .spread = 0.22, .freq_lo = 1000, .freq_hi = 3800, .t60_lo = 0.004, .t60_hi = 0.014, .amp = 0.2 });
            r.noise(0.004, .{ .kind = .bandpass, .freq = 1200, .q = 0.7 }, 0.005, 0.25, 0.08);
        },
        .plaster => {
            r.noise(0, .{ .kind = .bandpass, .freq = 1600, .q = 0.7 }, 0.0003, 0.007, 0.8);
            r.noise(0, .{ .kind = .lowpass, .freq = 900 }, 0.001, 0.06, 0.3);
            r.mode(0, rng.jitter(180, 0.1), 0.035, 0.45);
            r.grains(.{ .count = 6, .from = 0.003, .spread = 0.12, .freq_lo = 900, .freq_hi = 2500, .t60_lo = 0.004, .t60_hi = 0.01, .amp = 0.1 });
            r.noise(0.004, .{ .kind = .bandpass, .freq = 1500, .q = 0.7 }, 0.006, 0.2, 0.08);
        },
        .tile => {
            r.noise(0, .{ .kind = .bandpass, .freq = 5500, .q = 1.2 }, 0.0001, 0.005, 1.0);
            for ([_]f32{ 2600, 4300, 6900 }, [_]f32{ 0.025, 0.018, 0.012 }, [_]f32{ 0.4, 0.3, 0.2 }) |f, t, a| r.mode(0, rng.jitter(f, 0.1), t, a);
            r.grains(.{ .count = 16, .from = 0.002, .spread = 0.2, .freq_lo = 3000, .freq_hi = 9000, .t60_lo = 0.006, .t60_hi = 0.02, .amp = 0.25 });
            r.mode(0, rng.jitter(200, 0.1), 0.03, 0.35);
        },
        .metal => {
            // A post, a rail or a frame: a heavy thud and a short, low
            // ring. The frame, the bolts and the ground take most of the
            // energy. A free bar with a small loss rings for a long time
            // at one pitch, and a burst of fire on it sounds like a
            // xylophone.
            // The click of the strike.
            r.noise(0, .{ .kind = .highpass, .freq = 4000 }, 0.0001, 0.0015, 0.5);
            // The thud: the mass of the steel.
            r.noise(0, .{ .kind = .lowpass, .freq = 700 }, 0.0004, 0.035, 2.5);
            r.noise(0, .{ .kind = .bandpass, .freq = 150, .q = 1.2, .then = .{ .kind = .lowpass, .freq = 400 } }, 0.001, 0.09, 3.0);
            for (0..3) |_| r.mode(0, rng.range(90, 220), rng.range(0.05, 0.09), 0.22);
            // The ring: 12 modes at random frequencies from 350 to 2000 Hz,
            // with the loss of steel in a structure (eta about 0.012). The
            // modes are dense and change at each hit, so no mode sets a
            // pitch and the hits make no melody.
            r.cluster(12, 350, 2000, 0.012, 0.06);
        },
        .sheet_metal => {
            // A hollow panel: a dull pank, a boom of the panel and the air
            // behind it, and the modes of a plate, f0 (m^2 + 1.7 n^2). The
            // frame and the lining damp the panel (eta about 0.07). Each
            // mode has its own jitter, so the hits do not move up and down
            // together.
            r.noise(0, .{ .kind = .bandpass, .freq = 1200, .q = 0.8 }, 0.0002, 0.005, 0.4);
            r.noise(0, .{ .kind = .lowpass, .freq = 500 }, 0.0005, 0.05, 3.5);
            r.noise(0, .{ .kind = .bandpass, .freq = 100, .q = 1.0, .then = .{ .kind = .lowpass, .freq = 300 } }, 0.002, 0.32, 7.0);
            const f0 = rng.jitter(45, 0.05);
            for (1..4) |mi| {
                for (1..4) |ni| {
                    const mf: f32 = @floatFromInt(mi);
                    const nf: f32 = @floatFromInt(ni);
                    r.ring(rng.jitter(f0 * (mf * mf + 1.7 * nf * nf), 0.12), 0.07, rng.range(0.04, 0.14));
                }
            }
        },
        .glass => {
            r.noise(0, .{ .kind = .highpass, .freq = 7000 }, 0.0001, 0.003, 1.0);
            for ([_]f32{ 3200, 5100, 7900, 10800 }, [_]f32{ 0.25, 0.2, 0.15, 0.1 }) |f, a| r.ring(rng.jitter(f, 0.1), 0.002, a);
            r.grains(.{ .count = 18, .from = 0.001, .spread = 0.06, .freq_lo = 4000, .freq_hi = 12000, .t60_lo = 0.015, .t60_hi = 0.06, .amp = 0.35 });
            // The shards land.
            r.grains(.{ .count = 12, .from = 0.18, .spread = 0.27, .freq_lo = 4000, .freq_hi = 11000, .t60_lo = 0.01, .t60_hi = 0.04, .amp = 0.18 });
            r.noise(0, .{ .kind = .bandpass, .freq = 6000, .q = 0.7 }, 0.0005, 0.04, 0.3);
        },
        .wood => {
            r.noise(0, .{ .kind = .bandpass, .freq = 1300, .q = 1.1 }, 0.0002, 0.006, 0.8);
            for ([_]f32{ 280, 610, 1050, 1700 }, [_]f32{ 0.5, 0.4, 0.25, 0.15 }) |f, a| r.ring(rng.jitter(f, 0.1), 0.03, a);
            r.grains(.{ .count = 6, .from = 0.002, .spread = 0.06, .freq_lo = 1200, .freq_hi = 3500, .t60_lo = 0.003, .t60_hi = 0.008, .amp = 0.15 });
        },
        .ballast => {
            r.noise(0, .{ .kind = .lowpass, .freq = 2500 }, 0.0005, 0.012, 0.6);
            r.grains(.{ .count = 30, .from = 0.001, .spread = 0.09, .freq_lo = 1500, .freq_hi = 5500, .t60_lo = 0.003, .t60_hi = 0.009, .amp = 0.5 });
            // The stones fall back.
            r.grains(.{ .count = 14, .from = 0.12, .spread = 0.26, .freq_lo = 2000, .freq_hi = 6000, .t60_lo = 0.003, .t60_hi = 0.008, .amp = 0.22 });
            r.mode(0, rng.jitter(90, 0.1), 0.05, 0.4);
            r.noise(0.002, .{ .kind = .bandpass, .freq = 3000, .q = 0.6 }, 0.003, 0.12, 0.08);
        },
        .earth => {
            r.noise(0, .{ .kind = .lowpass, .freq = 700 }, 0.0008, 0.025, 0.8);
            r.mode(0, rng.jitter(75, 0.1), 0.06, 0.6);
            r.noise(0.003, .{ .kind = .lowpass, .freq = 1800 }, 0.01, 0.2, 0.15);
            r.grains(.{ .count = 4, .from = 0.01, .spread = 0.1, .freq_lo = 800, .freq_hi = 2000, .t60_lo = 0.003, .t60_hi = 0.006, .amp = 0.06 });
        },
        .fabric => {
            r.noise(0, .{ .kind = .lowpass, .freq = 900 }, 0.0008, 0.015, 0.6);
            r.noise(0, .{ .kind = .bandpass, .freq = 400, .q = 1 }, 0.0008, 0.01, 0.3);
            r.mode(0, rng.jitter(110, 0.1), 0.025, 0.25);
        },
        .flesh => {
            r.noise(0, .{ .kind = .lowpass, .freq = 1400 }, 0.0005, 0.014, 0.9);
            r.noise(0.001, .{ .kind = .bandpass, .freq = 450, .q = 1.3 }, 0.002, 0.03, 0.35);
            r.mode(0, rng.jitter(95, 0.1), 0.07, 0.6);
            r.mode(0, rng.jitter(160, 0.1), 0.04, 0.3);
        },
    }
    dsp.normalise(b, in.loud * @sqrt(std.math.clamp(energy, 0.1, 2)));
    return @max(1, dsp.trimmed(b, 1e-4));
}

pub const Hit = struct {
    pos: V3,
    material: Material,
    /// See `strike`.
    energy: f32 = 1,
    /// The time of the hit, s after the shot: the flight of the bullet.
    time: f32 = 0,
    /// A blocked path: the gain and the cutoff of the sound.
    occlusion: f32 = 1,
    occlusion_cutoff: f32 = 20000,
};

/// Render an impact into `out` (from its direct arrival): the direct
/// sound, the reflections of the room and its tail. `mono` is scratch
/// memory.
pub fn render(out: *space.Out, mono: []f32, hit: Hit, lis: space.Listener, room: *const space.Room, rng: *dsp.Rng, c: f32) void {
    const sig = mono[0..strike(mono, hit.material, hit.energy, rng)];
    var d = space.direct(lis, hit.pos, hit.time, c, 1);
    out.begin(d.time);
    d.gain *= hit.occlusion;
    d.cutoff = @min(d.cutoff, hit.occlusion_cutoff);
    space.place(out, sig, d, lis);
    var buf: [4]space.Arrival = undefined;
    for (space.reflections(&buf, lis, room, hit.pos, hit.time, c, 1)) |a| {
        var r = a;
        r.gain *= @sqrt(hit.occlusion);
        space.place(out, sig, r, lis);
    }
    space.addTail(out, rng, d.time + 0.004, space.energy(sig), room, info.get(hit.material).bright);
}
