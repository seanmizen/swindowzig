//! Particles with no GPU code (REQ-GPU-024, REQ-GPU-025): the particle
//! state, the emitter, the step with gravity and drag, the cap that drops
//! the oldest particle, and the camera-facing quads sorted from far to
//! near. `particles.zig` draws the quads in one draw call.
//!
//! The step is a pure function of the particles and the time step, and an
//! emitter takes its random values from its own seed. The same inputs give
//! the same particles on each platform.
//!
//! The technique follows the particle system of horizon (MIT). No code of
//! horizon is in this file.
const std = @import("std");
const wgsl = @import("wgsl.zig");
const layout = @import("layout.zig");

pub const UvRect = layout.UvRect;

/// The texture rectangle of the full texture.
pub const full_uv: UvRect = .{ .u0 = 0, .v0 = 0, .u1 = 1, .v1 = 1 };

/// One particle.
pub const Particle = struct {
    pos: [3]f32,
    /// The velocity, in units per second.
    vel: [3]f32 = .{ 0, 0, 0 },
    /// The time since the particle started, in seconds.
    age: f32 = 0,
    /// The particle stops when `age` reaches `life`.
    life: f32 = 1,
    /// The side of the quad, in world units.
    size: f32 = 0.1,
    /// Straight alpha. With `fade`, the alpha goes down to 0 at the end
    /// of the life.
    color: [4]f32 = .{ 1, 1, 1, 1 },
    fade: bool = false,
    /// The acceleration down, in units per second squared.
    gravity: f32 = 0,
    /// The velocity loss: each second keeps exp(-drag) of the velocity.
    drag: f32 = 0,
    /// The sprite in the texture, for example `Atlas.uv(id)`.
    sprite: UvRect = full_uv,

    /// The alpha after the fade.
    pub fn alpha(p: Particle) f32 {
        if (!p.fade or p.life <= 0) return p.color[3];
        return p.color[3] * @max(0, 1 - p.age / p.life);
    }
};

/// A fixed number of particles. When the system is full, a new particle
/// takes the place of the oldest particle (REQ-GPU-025).
pub const System = struct {
    items: []Particle,
    /// The index of the oldest particle.
    head: usize = 0,
    len: usize = 0,
    /// The particles that the cap dropped since `init`.
    dropped: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !System {
        if (capacity == 0) return error.NoCapacity;
        return .{ .items = try allocator.alloc(Particle, capacity) };
    }

    pub fn deinit(self: *System, allocator: std.mem.Allocator) void {
        allocator.free(self.items);
        self.* = undefined;
    }

    pub fn count(self: *const System) usize {
        return self.len;
    }

    /// Particle `i`, from the oldest (0) to the newest.
    pub fn get(self: *const System, i: usize) *const Particle {
        return &self.items[(self.head + i) % self.items.len];
    }

    pub fn clear(self: *System) void {
        self.head = 0;
        self.len = 0;
    }

    /// Add a particle. A full system drops its oldest particle.
    pub fn spawn(self: *System, p: Particle) void {
        const cap = self.items.len;
        if (self.len < cap) {
            self.items[(self.head + self.len) % cap] = p;
            self.len += 1;
            return;
        }
        self.items[self.head] = p;
        self.head = (self.head + 1) % cap;
        self.dropped += 1;
    }

    /// Move each particle by `dt` seconds: the gravity, then the drag,
    /// then the position. A particle at the end of its life goes. The
    /// other particles keep their order.
    pub fn step(self: *System, dt: f32) void {
        const cap = self.items.len;
        var out: usize = 0;
        for (0..self.len) |i| {
            var p = self.items[(self.head + i) % cap];
            p.age += dt;
            if (p.age >= p.life) continue;
            p.vel[1] -= p.gravity * dt;
            const k = @exp(-p.drag * dt);
            for (0..3) |a| {
                p.vel[a] *= k;
                p.pos[a] += p.vel[a] * dt;
            }
            self.items[(self.head + out) % cap] = p;
            out += 1;
        }
        self.len = out;
    }
};

/// An emitter: it makes particles at a rate, with random speeds and lives
/// in the given ranges.
pub const Emitter = struct {
    position: [3]f32,
    /// The mean direction of the particles. It need not be a unit vector.
    direction: [3]f32 = .{ 0, 1, 0 },
    /// The half angle of the cone of directions, in radians.
    spread: f32 = 0.3,
    /// The speed range, in units per second.
    speed: [2]f32 = .{ 1, 2 },
    /// The life range, in seconds.
    life: [2]f32 = .{ 1, 2 },
    /// The particles per second.
    rate: f32 = 10,
    gravity: f32 = 9.8,
    drag: f32 = 0,
    size: f32 = 0.1,
    color: [4]f32 = .{ 1, 1, 1, 1 },
    fade: bool = true,
    sprite: UvRect = full_uv,
    seed: u64 = 0,

    /// The time that the emitter has not used yet, in seconds.
    pending: f32 = 0,
    prng: ?std.Random.DefaultPrng = null,

    /// Make the particles of `dt` seconds into `system`. Give the count.
    pub fn emit(self: *Emitter, system: *System, dt: f32) usize {
        if (self.rate <= 0) return 0;
        if (self.prng == null) self.prng = std.Random.DefaultPrng.init(self.seed);
        const r = self.prng.?.random();
        self.pending += dt;
        const n: usize = @intFromFloat(@floor(self.pending * self.rate));
        self.pending -= @as(f32, @floatFromInt(n)) / self.rate;
        for (0..n) |_| {
            const dir = coneDirection(self.direction, self.spread, r.float(f32), r.float(f32));
            const speed = lerp(self.speed[0], self.speed[1], r.float(f32));
            system.spawn(.{
                .pos = self.position,
                .vel = .{ dir[0] * speed, dir[1] * speed, dir[2] * speed },
                .life = lerp(self.life[0], self.life[1], r.float(f32)),
                .size = self.size,
                .color = self.color,
                .fade = self.fade,
                .gravity = self.gravity,
                .drag = self.drag,
                .sprite = self.sprite,
            });
        }
        return n;
    }
};

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn normalize(v: [3]f32) [3]f32 {
    const len = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    if (len < 1e-9) return .{ 0, 1, 0 };
    return .{ v[0] / len, v[1] / len, v[2] / len };
}

fn cross(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

/// A unit direction in the cone of half angle `spread` about `axis`, from
/// two random values u and v in [0, 1). The directions have the same
/// density over the cap of the cone.
pub fn coneDirection(axis: [3]f32, spread: f32, u: f32, v: f32) [3]f32 {
    const a = normalize(axis);
    const cos_max = @cos(@min(spread, std.math.pi));
    const z = 1 - u * (1 - cos_max);
    const s = @sqrt(@max(0, 1 - z * z));
    const phi = v * 2 * std.math.pi;
    // Two unit vectors at right angles to the axis.
    const ref: [3]f32 = if (@abs(a[1]) < 0.9) .{ 0, 1, 0 } else .{ 1, 0, 0 };
    const t = normalize(cross(a, ref));
    const b = cross(a, t);
    var out: [3]f32 = undefined;
    for (0..3) |i| out[i] = a[i] * z + (t[i] * @cos(phi) + b[i] * @sin(phi)) * s;
    return out;
}

/// One corner of a particle quad.
pub const Vertex = extern struct {
    pos: [3]f32,
    uv: [2]f32,
    color: [4]f32,
};

/// The camera for the quads: its position and its right and up axes in
/// world space.
pub const Camera = struct {
    pos: [3]f32,
    right: [3]f32,
    up: [3]f32,

    /// The camera of a view matrix (`FrameUniforms.view`, column-major).
    pub fn fromView(view: [16]f32, pos: [3]f32) Camera {
        return .{ .pos = pos, .right = .{ view[0], view[4], view[8] }, .up = .{ view[1], view[5], view[9] } };
    }
};

/// Write 6 vertices (two triangles) for each particle into `out`, the
/// furthest particle first (REQ-GPU-024). Each quad faces the camera.
/// `order` is a scratch list. Give the vertex count.
pub fn buildQuads(allocator: std.mem.Allocator, system: *const System, camera: Camera, order: *std.ArrayList(Key), out: []Vertex) !usize {
    const n = system.count();
    std.debug.assert(out.len >= n * 6);
    order.clearRetainingCapacity();
    try order.ensureTotalCapacity(allocator, n);
    for (0..n) |i| {
        const p = system.get(i);
        var d: f32 = 0;
        for (0..3) |a| d += (p.pos[a] - camera.pos[a]) * (p.pos[a] - camera.pos[a]);
        order.appendAssumeCapacity(.{ .index = @intCast(i), .dist = d });
    }
    std.sort.block(Key, order.items, {}, Key.further);
    for (order.items, 0..) |k, qi| {
        const p = system.get(k.index);
        const h = p.size * 0.5;
        const color: [4]f32 = .{ p.color[0], p.color[1], p.color[2], p.alpha() };
        var corner: [4][3]f32 = undefined;
        const signs = [4][2]f32{ .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 }, .{ -1, 1 } };
        for (signs, 0..) |sg, c| {
            for (0..3) |a| corner[c][a] = p.pos[a] + (camera.right[a] * sg[0] + camera.up[a] * sg[1]) * h;
        }
        const s = p.sprite;
        // The texture v axis goes down: the bottom corners take v1.
        const uv = [4][2]f32{ .{ s.u0, s.v1 }, .{ s.u1, s.v1 }, .{ s.u1, s.v0 }, .{ s.u0, s.v0 } };
        const tri = [6]usize{ 0, 1, 2, 0, 2, 3 };
        for (tri, 0..) |c, j| out[qi * 6 + j] = .{ .pos = corner[c], .uv = uv[c], .color = color };
    }
    return n * 6;
}

/// The sort key of one particle.
pub const Key = struct {
    index: u32,
    dist: f32,

    fn further(_: void, a: Key, b: Key) bool {
        return a.dist > b.dist;
    }
};

/// The WGSL of the particle pass. Group 0 is the frame, group 1 the
/// texture (binding 0) and its sampler (binding 1).
pub const shader = wgsl.shader(
    \\@group(1) @binding(0) var sw_particle_tex: texture_2d<f32>;
    \\@group(1) @binding(1) var sw_particle_sampler: sampler;
    \\
    \\struct SwParticleOut {
    \\    @builtin(position) pos: vec4<f32>,
    \\    @location(0) uv: vec2<f32>,
    \\    @location(1) color: vec4<f32>,
    \\}
    \\
    \\@vertex fn vs_main(@location(0) pos: vec3<f32>, @location(1) uv: vec2<f32>, @location(2) color: vec4<f32>) -> SwParticleOut {
    \\    var out: SwParticleOut;
    \\    out.pos = sw_frame.view_proj * vec4<f32>(pos, 1.0);
    \\    out.uv = uv;
    \\    out.color = color;
    \\    return out;
    \\}
    \\
    \\@fragment fn fs_main(in: SwParticleOut) -> @location(0) vec4<f32> {
    \\    return in.color * textureSample(sw_particle_tex, sw_particle_sampler, in.uv);
    \\}
    \\
);

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "particles: gravity, drag and life move a particle (REQ-GPU-024)" {
    var sys = try System.init(testing.allocator, 4);
    defer sys.deinit(testing.allocator);
    sys.spawn(.{ .pos = .{ 0, 10, 0 }, .vel = .{ 2, 0, 0 }, .gravity = 10, .drag = 0, .life = 1 });
    sys.step(0.5);
    const p = sys.get(0);
    try testing.expectApproxEqAbs(@as(f32, -5), p.vel[1], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1), p.pos[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 7.5), p.pos[1], 1e-5);
    // Drag: one second keeps exp(-drag) of the speed.
    sys.clear();
    sys.spawn(.{ .pos = .{ 0, 0, 0 }, .vel = .{ 4, 0, 0 }, .drag = 2, .life = 5 });
    for (0..10) |_| sys.step(0.1);
    try testing.expectApproxEqAbs(4 * @exp(@as(f32, -2)), sys.get(0).vel[0], 1e-4);
    // The end of the life removes the particle.
    sys.step(4.0);
    try testing.expectEqual(@as(usize, 0), sys.count());
}

test "particles: the cap drops the oldest particle (REQ-GPU-025)" {
    var sys = try System.init(testing.allocator, 3);
    defer sys.deinit(testing.allocator);
    for (0..5) |i| sys.spawn(.{ .pos = .{ @floatFromInt(i), 0, 0 }, .life = 10 });
    try testing.expectEqual(@as(usize, 3), sys.count());
    try testing.expectEqual(@as(u64, 2), sys.dropped);
    for (0..3) |i| try testing.expectEqual(@as(f32, @floatFromInt(i + 2)), sys.get(i).pos[0]);
    // A step that removes a particle keeps the order of the others.
    sys.items[(sys.head + 1) % 3].life = 0;
    sys.step(0.01);
    try testing.expectEqual(@as(usize, 2), sys.count());
    try testing.expectEqual(@as(f32, 2), sys.get(0).pos[0]);
    try testing.expectEqual(@as(f32, 4), sys.get(1).pos[0]);
    sys.spawn(.{ .pos = .{ 5, 0, 0 }, .life = 10 });
    sys.spawn(.{ .pos = .{ 6, 0, 0 }, .life = 10 });
    try testing.expectEqual(@as(f32, 4), sys.get(0).pos[0]);
    try testing.expectEqual(@as(f32, 6), sys.get(2).pos[0]);
}

test "particles: an emitter makes particles at its rate, in its ranges (REQ-GPU-024)" {
    var sys = try System.init(testing.allocator, 100);
    defer sys.deinit(testing.allocator);
    var e: Emitter = .{ .position = .{ 1, 2, 3 }, .rate = 20, .speed = .{ 2, 3 }, .life = .{ 0.5, 1 }, .spread = 0.2, .seed = 7 };
    var total: usize = 0;
    for (0..10) |_| total += e.emit(&sys, 0.1);
    try testing.expectEqual(@as(usize, 20), total);
    for (0..sys.count()) |i| {
        const p = sys.get(i);
        const s = @sqrt(p.vel[0] * p.vel[0] + p.vel[1] * p.vel[1] + p.vel[2] * p.vel[2]);
        try testing.expect(s >= 2 - 1e-4 and s <= 3 + 1e-4);
        try testing.expect(p.life >= 0.5 and p.life <= 1);
        // In the cone about +Y.
        try testing.expect(p.vel[1] / s >= @cos(@as(f32, 0.2)) - 1e-4);
        try testing.expectEqual([3]f32{ 1, 2, 3 }, p.pos);
    }
    // The same seed gives the same particles.
    var sys2 = try System.init(testing.allocator, 100);
    defer sys2.deinit(testing.allocator);
    var e2: Emitter = .{ .position = .{ 1, 2, 3 }, .rate = 20, .speed = .{ 2, 3 }, .life = .{ 0.5, 1 }, .spread = 0.2, .seed = 7 };
    for (0..10) |_| _ = e2.emit(&sys2, 0.1);
    try testing.expectEqual(sys.get(5).vel, sys2.get(5).vel);
}

test "particles: the quads face the camera and go from far to near (REQ-GPU-024)" {
    var sys = try System.init(testing.allocator, 4);
    defer sys.deinit(testing.allocator);
    sys.spawn(.{ .pos = .{ 0, 0, -1 }, .size = 2, .color = .{ 1, 0, 0, 1 } });
    sys.spawn(.{ .pos = .{ 0, 0, -5 }, .size = 2, .color = .{ 0, 1, 0, 1 } });
    sys.spawn(.{ .pos = .{ 0, 0, -3 }, .size = 2, .color = .{ 0, 0, 1, 1 } });
    var order: std.ArrayList(Key) = .empty;
    defer order.deinit(testing.allocator);
    var out: [18]Vertex = undefined;
    const cam: Camera = .{ .pos = .{ 0, 0, 0 }, .right = .{ 1, 0, 0 }, .up = .{ 0, 1, 0 } };
    const n = try buildQuads(testing.allocator, &sys, cam, &order, &out);
    try testing.expectEqual(@as(usize, 18), n);
    // Green (z -5), then blue (z -3), then red (z -1).
    try testing.expectEqual(@as(f32, 1), out[0].color[1]);
    try testing.expectEqual(@as(f32, 1), out[6].color[2]);
    try testing.expectEqual(@as(f32, 1), out[12].color[0]);
    // Each corner is in the plane of the camera axes, at the size.
    for (out[0..6]) |v| {
        try testing.expectEqual(@as(f32, -5), v.pos[2]);
        try testing.expectEqual(@as(f32, 1), @abs(v.pos[0]));
        try testing.expectEqual(@as(f32, 1), @abs(v.pos[1]));
    }
    // A camera that looks along +X: the quads are in the y-z plane.
    const side: Camera = .{ .pos = .{ -10, 0, 0 }, .right = .{ 0, 0, 1 }, .up = .{ 0, 1, 0 } };
    _ = try buildQuads(testing.allocator, &sys, side, &order, &out);
    for (out) |v| try testing.expectEqual(@as(f32, 0), v.pos[0]);
}

test "particles: the camera of a lookAt view matrix" {
    // A view from (0, 0, 5) toward the origin: right +X, up +Y.
    const view = [16]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, -5, 1 };
    const c = Camera.fromView(view, .{ 0, 0, 5 });
    try testing.expectEqual([3]f32{ 1, 0, 0 }, c.right);
    try testing.expectEqual([3]f32{ 0, 1, 0 }, c.up);
}

test "particles: the fade takes the alpha to 0 at the end of the life" {
    const p: Particle = .{ .pos = .{ 0, 0, 0 }, .life = 2, .age = 1, .color = .{ 1, 1, 1, 0.8 }, .fade = true };
    try testing.expectApproxEqAbs(@as(f32, 0.4), p.alpha(), 1e-6);
    try testing.expect(std.mem.startsWith(u8, shader, wgsl.prefix));
}
