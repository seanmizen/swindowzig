// The bots of the shooter: snow drones in white suits with an orange chest
// panel and a cyan visor. Each bot is a sw_render box model: a tree of
// boxes that this file poses part by part.
//
// A bot moves to a cover point that the player cannot see, waits there
// crouched, then stands up and fires bursts while it can see the player.
// A hit makes it flinch, and a bot with low health moves to other cover.
// A dead bot falls over and comes back after a few seconds.
//
// All the choices use the seeded random numbers of `run.Rng` on the fixed
// timestep, so a replay of one TAS script gives the same fight
// (REQ-DEMO-001).
const std = @import("std");
const sw_math = @import("sw_math");
const sw_render = @import("sw_render");
const run = @import("demo_common").run;
const arena = @import("arena.zig");

const Mat4 = sw_math.Mat4;
const Quat = sw_math.Quat;

pub const Part = struct {
    pub const hips = 0;
    pub const torso = 1;
    pub const head = 2;
    pub const arm_r = 3;
    pub const arm_l = 4;
    pub const leg_r = 5;
    pub const leg_l = 6;
    pub const count = 7;
};

const white: [3]f32 = .{ 0.85, 0.87, 0.90 };
const grey: [3]f32 = .{ 0.22, 0.24, 0.28 };
const dark: [3]f32 = .{ 0.06, 0.06, 0.07 };
const orange: [3]f32 = .{ 1.0, 0.42, 0.06 };
const cyan: [3]f32 = .{ 0.3, 2.5, 3.0 };

fn box(min: [3]f32, max: [3]f32, c: [3]f32) sw_render.BoxModelBox {
    return .{ .min = min, .max = max, .color = c };
}

pub const parts = [Part.count]sw_render.BoxModelPart{
    .{ .pivot = .{ 0, 0.95, 0 }, .boxes = &.{box(.{ -0.2, 0.85, -0.13 }, .{ 0.2, 1.0, 0.13 }, grey)} },
    .{ .parent = Part.hips, .pivot = .{ 0, 1.0, 0 }, .boxes = &.{
        box(.{ -0.26, 1.0, -0.16 }, .{ 0.26, 1.5, 0.16 }, white),
        box(.{ -0.18, 1.12, -0.18 }, .{ 0.18, 1.38, -0.16 }, orange),
        box(.{ -0.18, 1.05, 0.16 }, .{ 0.18, 1.42, 0.28 }, grey),
    } },
    .{ .parent = Part.torso, .pivot = .{ 0, 1.5, 0 }, .boxes = &.{
        box(.{ -0.13, 1.5, -0.13 }, .{ 0.13, 1.78, 0.13 }, white),
        box(.{ -0.11, 1.6, -0.15 }, .{ 0.11, 1.68, -0.13 }, cyan),
    } },
    .{ .parent = Part.torso, .pivot = .{ 0.32, 1.45, 0 }, .boxes = &.{box(.{ 0.26, 1.0, -0.07 }, .{ 0.38, 1.48, 0.07 }, grey)} },
    .{ .parent = Part.torso, .pivot = .{ -0.32, 1.45, 0 }, .boxes = &.{box(.{ -0.38, 1.0, -0.07 }, .{ -0.26, 1.48, 0.07 }, grey)} },
    .{ .parent = Part.hips, .pivot = .{ 0.1, 0.9, 0 }, .boxes = &.{
        box(.{ 0.02, 0.1, -0.08 }, .{ 0.18, 0.92, 0.08 }, white),
        box(.{ 0.02, 0, -0.13 }, .{ 0.18, 0.1, 0.08 }, dark),
    } },
    .{ .parent = Part.hips, .pivot = .{ -0.1, 0.9, 0 }, .boxes = &.{
        box(.{ -0.18, 0.1, -0.08 }, .{ -0.02, 0.92, 0.08 }, white),
        box(.{ -0.18, 0, -0.13 }, .{ -0.02, 0.1, 0.08 }, dark),
    } },
};

/// The hand of the right arm, in the frame of the arm part.
pub const hand: [3]f32 = .{ 0.32, 1.03, 0 };

pub const State = enum { advance, cover, peek, dead };

pub const max_health: f32 = 100;
const walk_speed: f32 = 2.6;
const crouch_drop: f32 = 0.42;
const respawn_time: f32 = 5;
const spawns = [_][3]f32{ .{ -9, 0, -20 }, .{ 9, 0, -20 }, .{ 0, 0, -20 }, .{ -16, 0, -16 }, .{ 16, 0, -17 } };

pub const Bot = struct {
    pos: [3]f32,
    yaw: f32 = 0,
    state: State = .advance,
    health: f32 = max_health,
    /// The cover point (`arena.coverPoint`) that the bot goes to or holds.
    cover: ?usize = null,
    timer: f32 = 0,
    burst_left: u32 = 0,
    shot_timer: f32 = 0,
    /// 1 at a hit, then it goes to 0.
    flinch: f32 = 0,
    /// The walk phase, in radians.
    stride: f32 = 0,
    /// 0 standing to 1 crouched.
    crouch: f32 = 0,
    /// The fall after death, 0 to 1.
    fall: f32 = 0,
    rng: run.Rng,
    /// The distance walked since the last foot puff of snow.
    step_dist: f32 = 0,

    pub fn init(index: usize) Bot {
        return .{ .pos = spawns[index % spawns.len], .rng = run.Rng.init(0xB07 + index * 7919) };
    }

    pub fn alive(self: *const Bot) bool {
        return self.state != .dead;
    }

    /// The eye of the bot, where its shots start.
    pub fn eye(self: *const Bot) [3]f32 {
        return .{ self.pos[0], self.pos[1] + 1.62 - self.crouch * crouch_drop, self.pos[2] };
    }

    /// The body hit box and the head hit box.
    pub fn hitBoxes(self: *const Bot) [2]arena.Box {
        const top = 1.5 - self.crouch * crouch_drop;
        const r: f32 = 0.32;
        const p = self.pos;
        return .{
            .{ .min = .{ p[0] - r, p[1], p[2] - r }, .max = .{ p[0] + r, p[1] + top, p[2] + r }, .material = .bot },
            .{ .min = .{ p[0] - 0.15, p[1] + top, p[2] - 0.15 }, .max = .{ p[0] + 0.15, p[1] + top + 0.3, p[2] + 0.15 }, .material = .bot },
        };
    }

    /// The root transform of the model.
    pub fn root(self: *const Bot) Mat4 {
        const fall = Quat.fromAxisAngle(.{ .x = 1, .y = 0, .z = 0 }, self.fall * 1.45).toMat4();
        return Mat4.translation(self.pos[0], self.pos[1] - self.crouch * crouch_drop, self.pos[2]).mul(Mat4.rotationY(self.yaw)).mul(fall);
    }

    /// The rotation of each part for this frame.
    pub fn pose(self: *const Bot) [Part.count]Quat {
        var q: [Part.count]Quat = @splat(Quat.identity());
        const x: sw_math.Vec3 = .{ .x = 1, .y = 0, .z = 0 };
        const swing = if (self.state == .advance) 0.6 * @sin(self.stride) else 0;
        q[Part.leg_r] = Quat.fromAxisAngle(x, swing + self.crouch * 1.0);
        q[Part.leg_l] = Quat.fromAxisAngle(x, -swing + self.crouch * 1.0);
        // The arms hold the gun forward. The flinch throws them up.
        const aim: f32 = std.math.pi / 2.0 - self.flinch * 0.5;
        q[Part.arm_r] = Quat.fromAxisAngle(x, aim);
        q[Part.arm_l] = Quat.fromAxisAngle(x, aim - 0.1).mul(Quat.fromAxisAngle(.{ .x = 0, .y = 0, .z = 1 }, -0.35));
        q[Part.torso] = Quat.fromAxisAngle(x, -self.flinch * 0.35 - self.crouch * 0.25);
        q[Part.head] = Quat.fromAxisAngle(x, self.flinch * 0.3);
        return q;
    }
};

/// What a bot did in one tick: the main loop makes the sound, the
/// particles and the damage.
pub const Event = union(enum) {
    /// A shot from `from` to `to`. `hit`: it hit the player.
    shot: struct { bot: usize, from: [3]f32, to: [3]f32, hit: bool },
    /// A foot of a walking bot made a puff of snow.
    step: [3]f32,
};

pub const World = struct {
    player_eye: [3]f32,
    /// The speed of the player on the ground, in metres each second.
    player_speed: f32,
};

fn dist2(a: [3]f32, b: [3]f32) f32 {
    const dx = a[0] - b[0];
    const dz = a[2] - b[2];
    return @sqrt(dx * dx + dz * dz);
}

fn yawTo(from: [3]f32, to: [3]f32) f32 {
    return std.math.atan2(-(to[0] - from[0]), -(to[2] - from[2]));
}

/// Turn `a` toward `b` by at most `step` radians.
fn turnToward(a: f32, b: f32, step: f32) f32 {
    var d = b - a;
    while (d > std.math.pi) d -= std.math.tau;
    while (d < -std.math.pi) d += std.math.tau;
    return a + std.math.clamp(d, -step, step);
}

/// Choose a cover point that the player cannot see, 5 to 13 metres from
/// the player, that no other bot holds. Give null when there is none.
fn chooseCover(bots: []const Bot, self_index: usize, w: World) ?usize {
    const me = bots[self_index];
    var best: ?usize = null;
    var best_score: f32 = std.math.inf(f32);
    for (0..arena.cover_count) |i| {
        const p = arena.coverPoint(i);
        if (!arena.inside(p)) continue;
        const d_player = dist2(p, w.player_eye);
        if (d_player < 5 or d_player > 13) continue;
        if (!arena.hidden(p, w.player_eye)) continue;
        var taken = false;
        for (bots, 0..) |b, j| {
            if (j != self_index and b.cover == i) taken = true;
        }
        if (taken) continue;
        // Near the bot, with a little random choice.
        var rng = me.rng;
        const score = dist2(p, me.pos) + rng.float() * 4;
        if (score < best_score) {
            best_score = score;
            best = i;
        }
    }
    return best;
}

/// Step one bot for one tick.
pub fn update(bots: []Bot, index: usize, w: World, dt: f32, events: *std.ArrayList(Event), allocator: std.mem.Allocator) !void {
    const b = &bots[index];
    b.flinch = @max(0, b.flinch - dt * 3);
    switch (b.state) {
        .dead => {
            b.fall = @min(1, b.fall + dt * 2.5);
            b.timer -= dt;
            if (b.timer <= 0) {
                const spawn = spawns[@intCast(b.rng.next() % spawns.len)];
                b.* = .{ .pos = spawn, .rng = b.rng };
            }
            return;
        },
        .advance => {
            b.crouch = @max(0, b.crouch - dt * 4);
            if (b.cover == null) b.cover = chooseCover(bots, index, w);
            const target = if (b.cover) |c| arena.coverPoint(c) else w.player_eye;
            const d = dist2(b.pos, target);
            if (d < 0.25 or (b.cover == null and d < 8)) {
                b.state = .cover;
                b.timer = b.rng.range(0.8, 2.0);
                return;
            }
            const dir: [2]f32 = .{ (target[0] - b.pos[0]) / d, (target[2] - b.pos[2]) / d };
            b.yaw = turnToward(b.yaw, std.math.atan2(-dir[0], -dir[1]), dt * 6);
            var body: arena.Body = .{ .pos = b.pos, .vel = .{ dir[0] * walk_speed, 0, dir[1] * walk_speed } };
            body.step(dt, 20);
            const moved = dist2(body.pos, b.pos);
            b.pos = body.pos;
            b.stride += moved * 3.2;
            b.step_dist += moved;
            if (b.step_dist > 0.7) {
                b.step_dist = 0;
                try events.append(allocator, .{ .step = b.pos });
            }
            // A bot that cannot move (a crate in the way) takes another
            // cover point.
            if (moved < walk_speed * dt * 0.2) {
                b.cover = null;
                b.timer += dt;
                if (b.timer > 0.5) {
                    b.state = .peek;
                    b.timer = 1.5;
                }
            }
        },
        .cover => {
            b.crouch = @min(1, b.crouch + dt * 4);
            b.yaw = turnToward(b.yaw, yawTo(b.pos, w.player_eye), dt * 4);
            b.timer -= dt;
            if (b.timer <= 0) {
                b.state = .peek;
                b.timer = b.rng.range(1.6, 3.0);
                b.burst_left = 0;
                b.shot_timer = b.rng.range(0.2, 0.5);
            }
        },
        .peek => {
            b.crouch = @max(0, b.crouch - dt * 4);
            b.yaw = turnToward(b.yaw, yawTo(b.pos, w.player_eye), dt * 5);
            b.timer -= dt;
            const sees = arena.clear(b.eye(), w.player_eye);
            if (sees and b.crouch < 0.2) {
                b.shot_timer -= dt;
                if (b.shot_timer <= 0) {
                    if (b.burst_left == 0) b.burst_left = 3;
                    b.burst_left -= 1;
                    b.shot_timer = if (b.burst_left == 0) b.rng.range(0.7, 1.3) else 0.12;
                    try fire(b, index, w, events, allocator);
                }
            }
            if (b.timer <= 0) {
                // Back down, or to new cover.
                if (b.rng.float() < 0.4 or !sees) {
                    b.cover = null;
                    b.state = .advance;
                    b.timer = 0;
                } else {
                    b.state = .cover;
                    b.timer = b.rng.range(0.8, 1.8);
                }
            }
        },
    }
}

fn fire(b: *Bot, index: usize, w: World, events: *std.ArrayList(Event), allocator: std.mem.Allocator) !void {
    const from = b.eye();
    const d = dist2(from, w.player_eye);
    const p = std.math.clamp(0.35 - d * 0.012 - w.player_speed * 0.04, 0.05, 0.35);
    const hit = b.rng.float() < p;
    var to = w.player_eye;
    if (!hit) {
        // A miss: a point near the player, often in the snow at the feet.
        to[0] += b.rng.range(-1.2, 1.2);
        to[1] = b.rng.range(-0.4, 2.2);
        to[2] += b.rng.range(-1.2, 1.2);
    } else {
        to[1] -= 0.4;
    }
    try events.append(allocator, .{ .shot = .{ .bot = index, .from = from, .to = to, .hit = hit } });
}

/// A hit on a bot. Give true when it dies.
pub fn damage(b: *Bot, amount: f32) bool {
    if (!b.alive()) return false;
    b.health -= amount;
    b.flinch = 1;
    if (b.health <= 0) {
        b.state = .dead;
        b.timer = respawn_time;
        b.cover = null;
        b.crouch = 0;
        return true;
    }
    // A hurt bot in the open moves to cover.
    if (b.health < 50 and b.state == .peek) {
        b.state = .advance;
        b.cover = null;
        b.timer = 0;
    }
    return false;
}

test "bots: a bot walks to cover and fires at the player" {
    var bots = [_]Bot{ Bot.init(0), Bot.init(1) };
    var events: std.ArrayList(Event) = .empty;
    defer events.deinit(std.testing.allocator);
    const w: World = .{ .player_eye = .{ 0, 1.6, 16 }, .player_speed = 0 };
    var shots: usize = 0;
    for (0..60 * 30) |_| {
        for (0..bots.len) |i| try update(&bots, i, w, 1.0 / 60.0, &events, std.testing.allocator);
        for (events.items) |e| if (e == .shot) {
            shots += 1;
        };
        events.clearRetainingCapacity();
    }
    try std.testing.expect(shots > 0);
}
