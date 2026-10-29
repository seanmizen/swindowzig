// The fight of the shooter demo: the player, the gun in the hands, and the
// bots that move, take cover and fire back (REQ-DEMO-021).
//
// The fight has no clock and no GPU. `step` moves it by one fixed tick
// from the input of that tick. Each random choice comes from a seeded
// random number generator, so one script of input gives the same fight
// on each run (REQ-DEMO-021).
//
// - The player: player.zig moves the body. weapon.zig `Hands` fires,
//   reloads and kicks the gun. A shot is a ray against the arena and the
//   hit boxes of the bots (npc.zig).
// - The bots: a simple plan for each bot. Seek a cover point that hides it
//   from the player (arena.zig), hide, step out, wait for the reaction
//   time, fire a burst, and go back. A bot that the player flanks, or
//   that took much damage, goes to new cover. A dead bot falls as a
//   ragdoll (ragdoll.zig). When all the bots are dead, a new wave comes.
// - The events: each shot and each hit goes into `events`, so the demo
//   can play the sounds and the particles of the tick.
const std = @import("std");
const vec = @import("vec.zig");
const arena = @import("arena.zig");
const player_mod = @import("player.zig");
const weapon = @import("weapon.zig");
const guns = @import("guns.zig");
const npc = @import("npc.zig");
const ragdoll = @import("ragdoll.zig");
const Surface = @import("audio/impact.zig").Material;
const V3 = vec.V3;
const v3 = vec.v3;
const Mat4 = vec.Mat4;

/// The input of one tick, after the bindings.
pub const Input = struct {
    /// -1 to 1: right and forward.
    move_x: f32 = 0,
    move_y: f32 = 0,
    /// The look change of this tick, radians: yaw to the right, pitch up.
    look_yaw: f32 = 0,
    look_pitch: f32 = 0,
    fire: bool = false,
    fire_pressed: bool = false,
    aim: bool = false,
    jump: bool = false,
    reload: bool = false,
    /// -1 lean left, 0, 1 lean right.
    lean: f32 = 0,
};

/// The settings that a script can change (`set <name> <value>`).
pub const Settings = struct {
    /// The damage of a bot round, as a part of the gun damage.
    bot_damage: f32 = 0.35,
    /// The aim error of the bots, radians.
    bot_error: f32 = 0.045,
    /// The bots do not fire.
    bots_hold: bool = false,
    /// The player takes no damage.
    god: bool = false,
    /// The number of bots in each wave, 1 to `max_bots`.
    bots: u32 = 3,
};

pub const max_bots = 3;
pub const max_hp: f32 = 100;
/// The eye of a standing body over its feet.
const eye_h: f32 = player_mod.eye;
/// The chest: where a bot aims.
const chest_h: f32 = 1.25;
const bot_speed: f32 = 0.7;
const respawn_time: f32 = 2.5;
const wave_gap: f32 = 3.0;

pub const BotState = enum { seek, hide, peek, aim, fire, back, dead };

pub const Bot = struct {
    body: player_mod.Player = .{},
    hp: f32 = max_hp,
    state: BotState = .seek,
    /// The cover point (arena.cover_points) and the peek point.
    cover: ?usize = null,
    peek: ?usize = null,
    timer: f32 = 0,
    /// The time left in this plan before the bot gives it up.
    patience: f32 = 0,
    cycles: u32 = 0,
    burst: u32 = 0,
    cooldown: f32 = 0,
    ammo: u32 = 0,
    reload: f32 = -1,
    gun: u8 = 0,
    aim: f32 = 0,
    aim_pitch: f32 = 0,
    flinch: f32 = 0,
    flinch_dir: V3 = v3(0, 0, -1),
    /// The red tint of a hit, 1 to 0.
    hurt: f32 = 0,
    flash: f32 = 0,
    rag: ragdoll.Body = .{},
    /// The last place where the stride gave a snow puff.
    puff_stride: f32 = 0,
    rng: std.Random.DefaultPrng = .init(0),

    pub fn alive(self: *const Bot) bool {
        return self.state != .dead;
    }

    pub fn pose(self: *const Bot) npc.Pose {
        const sp = @sqrt(self.body.vel[0] * self.body.vel[0] + self.body.vel[2] * self.body.vel[2]);
        return .{
            .pos = self.body.pos,
            .yaw = self.body.yaw,
            .action = if (sp > 3) .run else if (sp > 0.3) .walk else .stand,
            .stride = self.body.stride,
            .flinch = self.flinch,
            .flinch_dir = self.flinch_dir,
            .aim = self.aim,
            .aim_pitch = self.aim_pitch,
        };
    }

    pub fn skeleton(self: *const Bot) npc.Skeleton {
        if (self.state == .dead) return self.rag.skeleton();
        return npc.skeleton(self.pose());
    }

    /// The world matrix of the gun grip.
    pub fn gunMatrix(self: *const Bot, sk: npc.Skeleton) Mat4 {
        _ = self;
        return npc.handFrame(sk, true);
    }

    pub fn muzzle(self: *const Bot, sk: npc.Skeleton) V3 {
        return vec.xform(self.gunMatrix(sk), weapon.models[self.gun].muzzle);
    }

    pub fn eye(self: *const Bot) V3 {
        return self.body.pos + v3(0, eye_h, 0);
    }
};

/// A shot of the tick: for the sounds and the particles.
pub const Shot = struct {
    o: V3,
    e: V3,
    normal: V3,
    /// The material at the end, or null: the round flew on in the open.
    surface: ?Surface,
    snow: bool = false,
    /// The bot that fired, or null: the player.
    bot: ?usize,
    model: u8,
    /// The round hit a body: a bot, or the player (`hit_player`).
    flesh: bool = false,
    hit_player: bool = false,
    /// The first pellet of a shot. The others make no muzzle sound.
    first: bool = true,
};

pub const Kill = struct { bot: usize, head: bool };

/// What happened in the last tick.
pub const Events = struct {
    shots: [32]Shot = undefined,
    shot_n: usize = 0,
    kills: [max_bots]Kill = undefined,
    kill_n: usize = 0,
    /// The weapon event of the player (a reload sound).
    hands: weapon.Event = .none,
    /// The snow that the bots kick up, at the feet.
    steps: [max_bots]V3 = undefined,
    step_n: usize = 0,

    fn addShot(self: *Events, s: Shot) void {
        if (self.shot_n < self.shots.len) {
            self.shots[self.shot_n] = s;
            self.shot_n += 1;
        }
    }
};

/// A damage number near the crosshair (from the range of the action game).
pub const Number = struct { dmg: f32, head: bool, kill: bool, age: f32 = 0 };

pub const Game = struct {
    settings: Settings = .{},
    you: player_mod.Player = .{},
    hp: f32 = max_hp,
    dead_t: f32 = 0,
    item: weapon.Item = undefined,
    hands: weapon.Hands = .{},
    bots: [max_bots]Bot = @splat(.{}),
    bot_n: usize = max_bots,
    wave: u32 = 0,
    wave_t: f32 = 0,
    kills: u32 = 0,
    shots_fired: u32 = 0,
    hits: u32 = 0,
    /// The time since the last hit on the player, and its direction (from
    /// the bot), for the HUD.
    hurt: f32 = 0,
    hurt_dir: V3 = v3(0, 0, -1),
    /// The hit marker time left.
    marker: f32 = 0,
    numbers: [6]Number = undefined,
    number_n: usize = 0,
    events: Events = .{},
    rng: std.Random.DefaultPrng = .init(79),
    seed: u64 = 79,
    ticks: u64 = 0,

    /// Start the fight. weapon.loadModels and arena.build must have run.
    pub fn init(seed: u64, settings: Settings) Game {
        var g: Game = .{ .settings = settings, .seed = seed, .rng = .init(seed) };
        g.respawnPlayer();
        g.newWave();
        return g;
    }

    fn rand(self: *Game) f32 {
        return self.rng.random().float(f32);
    }

    fn respawnPlayer(self: *Game) void {
        self.you = .{ .pos = arena.player_spawn.pos, .yaw = arena.player_spawn.yaw };
        self.hp = max_hp;
        self.dead_t = 0;
        self.item = weapon.Item.full(weapon.byName("AssaultRifle_2") orelse 0, true);
        self.hands = .{};
        self.hands.takeOut(0.2);
    }

    const bot_guns = [_][]const u8{ "AssaultRifle_5", "SubmachineGun_2", "AssaultRifle2_2" };

    fn newWave(self: *Game) void {
        self.wave += 1;
        self.wave_t = 0;
        self.bot_n = std.math.clamp(self.settings.bots, 1, max_bots);
        for (self.bots[0..self.bot_n], 0..) |*b, i| {
            const sp = arena.bot_spawns[i];
            b.* = .{ .rng = .init(self.seed *% 31 +% self.wave *% 977 +% i) };
            b.body = .{ .pos = sp, .yaw = std.math.pi };
            b.gun = weapon.byName(bot_guns[i % bot_guns.len]) orelse 0;
            b.ammo = guns.table[b.gun].mag;
            b.timer = 0.4 + 0.5 * @as(f32, @floatFromInt(i));
        }
    }

    pub fn eye(self: *const Game) V3 {
        return self.you.eyePos();
    }

    pub fn alive(self: *const Game) bool {
        return self.hp > 0;
    }

    pub fn liveBots(self: *const Game) u32 {
        var n: u32 = 0;
        for (self.bots[0..self.bot_n]) |*b| {
            if (b.alive()) n += 1;
        }
        return n;
    }

    /// The camera roll of the lean.
    pub fn roll(self: *const Game) f32 {
        return self.you.lean * player_mod.lean_roll;
    }

    /// One fixed tick of dt seconds.
    pub fn step(self: *Game, dt: f32, in: Input) void {
        self.events = .{};
        self.ticks += 1;
        self.hurt += dt;
        self.marker = @max(0, self.marker - dt);
        self.stepNumbers(dt);
        self.stepPlayer(dt, in);
        for (self.bots[0..self.bot_n], 0..) |*b, i| self.stepBot(b, i, dt);
        if (self.liveBots() == 0) {
            self.wave_t += dt;
            if (self.wave_t > wave_gap) self.newWave();
        }
    }

    // ---- The player --------------------------------------------------------

    fn stepPlayer(self: *Game, dt: f32, in: Input) void {
        if (!self.alive()) {
            self.dead_t += dt;
            if (self.dead_t > respawn_time) self.respawnPlayer();
            return;
        }
        const p = &self.you;
        p.yaw -= in.look_yaw;
        p.pitch = std.math.clamp(p.pitch + in.look_pitch, -1.45, 1.45);
        // The wish direction in the world: yaw 0 looks to -Z.
        const fwd = v3(-@sin(p.yaw), 0, -@cos(p.yaw));
        const right = v3(@cos(p.yaw), 0, -@sin(p.yaw));
        var wish = fwd * vec.s(in.move_y) + right * vec.s(in.move_x);
        const wl = vec.len(wish);
        if (wl > 1) wish /= vec.s(wl);
        const st = weapon.statsOf(self.item);
        const ads_slow: f32 = 1 - 0.45 * self.hands.ads;
        p.step(dt, wish, in.jump, st.speed * ads_slow);
        p.updateLean(dt, in.lean);

        if (in.reload) _ = self.hands.startReload(&self.item);
        const ev = self.hands.update(&self.item, dt, in.fire, in.fire_pressed, in.aim);
        self.events.hands = ev;
        // An empty magazine reloads by itself.
        if (self.item.ammo == 0 and self.hands.ready()) _ = self.hands.startReload(&self.item);
        if (ev == .fired) self.playerShot(st);
        const rec = self.hands.recover(st, dt, in.look_pitch);
        p.pitch += rec[0];
        p.yaw -= rec[1];
    }

    fn playerShot(self: *Game, st: *const weapon.Stats) void {
        const p = &self.you;
        const sp = @sqrt(p.vel[0] * p.vel[0] + p.vel[2] * p.vel[2]);
        const cone = self.hands.spread(st, @min(1, sp / player_mod.walk_speed), !p.grounded);
        const o = self.eye();
        const f = vec.forward(p.yaw, p.pitch);
        const right = vec.norm(vec.cross(f, v3(0, 1, 0)));
        const up = vec.cross(right, f);
        self.shots_fired += 1;
        var body_dmg: [max_bots]f32 = @splat(0);
        var head_dmg: [max_bots]f32 = @splat(0);
        var dirs: [max_bots]V3 = @splat(f);
        for (0..st.pellets) |k| {
            const r = cone * @sqrt(self.rand());
            const a = self.rand() * std.math.tau;
            const d = vec.norm(f + right * vec.s(@cos(a) * r) + up * vec.s(@sin(a) * r));
            var shot: Shot = .{ .o = o, .e = o + d * vec.s(st.range), .normal = -d, .surface = null, .bot = null, .model = self.item.model, .first = k == 0 };
            var t_best = st.range;
            if (arena.raycast(o, d, st.range)) |h| {
                t_best = h.t;
                shot.e = o + d * vec.s(h.t);
                shot.normal = h.normal;
                shot.surface = arena.surfaceAt(shot.e, h.box);
                shot.snow = arena.snowAt(shot.e, h.box);
            }
            var hit_bot: ?usize = null;
            var head = false;
            for (self.bots[0..self.bot_n], 0..) |*b, i| {
                if (!b.alive()) continue;
                const boxes = npc.hitBoxes(b.skeleton());
                for (boxes, 0..) |hb, bi| {
                    const h = arena.rayBox(o, d, hb.min, hb.max) orelse continue;
                    if (h.t < t_best) {
                        t_best = h.t;
                        hit_bot = i;
                        head = bi == 2;
                    }
                }
            }
            if (hit_bot) |i| {
                shot.e = o + d * vec.s(t_best);
                shot.surface = .flesh;
                shot.snow = false;
                shot.flesh = true;
                const dmg = st.damageAt(head, t_best);
                if (head) head_dmg[i] += dmg else body_dmg[i] += dmg;
                dirs[i] = d;
            }
            self.events.addShot(shot);
        }
        for (self.bots[0..self.bot_n], 0..) |*b, i| {
            const total = body_dmg[i] + head_dmg[i];
            if (total <= 0) continue;
            self.hits += 1;
            self.marker = 0.18;
            const killed = self.damageBot(b, i, total, dirs[i], head_dmg[i] > 0);
            if (head_dmg[i] > 0) self.addNumber(head_dmg[i], true, killed and body_dmg[i] == 0);
            if (body_dmg[i] > 0) self.addNumber(body_dmg[i], false, killed);
        }
    }

    fn damageBot(self: *Game, b: *Bot, i: usize, dmg: f32, dir: V3, head: bool) bool {
        b.hp -= dmg;
        b.flinch = 1;
        b.flinch_dir = dir;
        b.hurt = 1;
        if (b.hp > 0) {
            // A hurt bot in the open goes back to cover.
            if ((b.state == .aim or b.state == .fire or b.state == .peek) and b.hp < 55) b.state = .back;
            return false;
        }
        const sk = b.skeleton();
        b.rag = ragdoll.Body.start(sk, b.body.vel, dir * vec.s(4.5));
        b.state = .dead;
        b.hp = 0;
        b.flash = 0;
        self.kills += 1;
        if (self.events.kill_n < self.events.kills.len) {
            self.events.kills[self.events.kill_n] = .{ .bot = i, .head = head };
            self.events.kill_n += 1;
        }
        return true;
    }

    fn addNumber(self: *Game, dmg: f32, head: bool, kill: bool) void {
        var k = @min(self.number_n, self.numbers.len - 1);
        while (k > 0) : (k -= 1) self.numbers[k] = self.numbers[k - 1];
        self.numbers[0] = .{ .dmg = dmg, .head = head, .kill = kill };
        self.number_n = @min(self.number_n + 1, self.numbers.len);
    }

    fn stepNumbers(self: *Game, dt: f32) void {
        var n: usize = 0;
        for (self.numbers[0..self.number_n], 0..) |*p, slot| {
            p.age += dt;
            if (p.age < 1.3) n = slot + 1;
        }
        self.number_n = n;
    }

    // ---- The bots ----------------------------------------------------------

    fn hidden(self: *const Game, c: usize) bool {
        const p = arena.cover_points[c].pos;
        return !arena.clear(p + v3(0, 1.5, 0), self.eye());
    }

    fn sees(self: *const Game, from: V3) bool {
        if (!self.alive()) return false;
        const e = self.eye();
        return arena.clear(from, e) or arena.clear(from, self.you.pos + v3(0, chest_h, 0));
    }

    /// True when another bot holds a point near c.
    fn taken(self: *const Game, me: usize, c: usize) bool {
        const p = arena.cover_points[c].pos;
        for (self.bots[0..self.bot_n], 0..) |*o, i| {
            if (i == me or !o.alive()) continue;
            for ([_]?usize{ o.cover, o.peek }) |q| {
                if (q) |qi| {
                    if (vec.len(arena.cover_points[qi].pos - p) < 2.0) return true;
                }
            }
            if (vec.len(o.body.pos - p) < 1.2) return true;
        }
        return false;
    }

    fn pickCover(self: *Game, b: *Bot, i: usize) void {
        var best: ?usize = null;
        var best_cost: f32 = 1e9;
        for (0..arena.cover_count) |c| {
            if (b.cover != null and b.cover.? == c) continue;
            if (!self.hidden(c) or self.taken(i, c)) continue;
            const p = arena.cover_points[c].pos;
            const to_me = vec.len(p - b.body.pos);
            const to_you = vec.len(p - self.you.pos);
            // A fight at 9 to 18 m, near the bot.
            const range_cost = if (to_you < 9) (9 - to_you) * 2 else if (to_you > 18) (to_you - 18) * 0.6 else 0;
            const cost = to_me + range_cost + 3 * b.rng.random().float(f32);
            if (cost < best_cost) {
                best_cost = cost;
                best = c;
            }
        }
        b.cover = best;
        b.peek = null;
        b.state = .seek;
        b.patience = 6;
        b.cycles = 0;
    }

    fn pickPeek(self: *Game, b: *Bot) ?usize {
        const home = arena.cover_points[b.cover orelse return null].pos;
        var best: ?usize = null;
        var best_d: f32 = 3.6;
        for (0..arena.cover_count) |c| {
            const p = arena.cover_points[c].pos;
            const d = vec.len(p - home);
            if (d >= best_d or d < 0.4) continue;
            if (!self.sees(p + v3(0, eye_h, 0))) continue;
            best_d = d;
            best = c;
        }
        return best;
    }

    /// Walk the body toward `to`. Returns true on arrival.
    fn moveTo(b: *Bot, to: V3, dt: f32, face: bool) bool {
        var d = to - b.body.pos;
        d[1] = 0;
        const l = vec.len(d);
        if (l < 0.25) {
            b.body.step(dt, v3(0, 0, 0), false, bot_speed);
            return true;
        }
        const wish = d / vec.s(l);
        b.body.step(dt, wish * vec.s(@min(1, l / 0.6)), false, bot_speed);
        if (face) turnTo(b, std.math.atan2(-wish[0], -wish[2]), dt);
        return false;
    }

    fn turnTo(b: *Bot, yaw: f32, dt: f32) void {
        var dy = yaw - b.body.yaw;
        while (dy > std.math.pi) dy -= std.math.tau;
        while (dy < -std.math.pi) dy += std.math.tau;
        const k = 9 * dt;
        b.body.yaw += std.math.clamp(dy, -k, k);
    }

    fn facePlayer(self: *const Game, b: *Bot, dt: f32) void {
        const d = self.you.pos + v3(0, chest_h, 0) - (b.body.pos + v3(0, 1.38, 0));
        turnTo(b, std.math.atan2(-d[0], -d[2]), dt);
        const want = std.math.atan2(d[1], @sqrt(d[0] * d[0] + d[2] * d[2]));
        b.aim_pitch += (want - b.aim_pitch) * @min(1, dt * 8);
    }

    fn stepBot(self: *Game, b: *Bot, i: usize, dt: f32) void {
        b.flinch = @max(0, b.flinch - dt * 3);
        b.hurt = @max(0, b.hurt - dt * 4);
        b.flash = @max(0, b.flash - dt);
        if (b.state == .dead) {
            b.rag.step(dt);
            return;
        }
        const st = &guns.table[b.gun];
        const aiming = b.state == .aim or b.state == .fire;
        b.aim += ((if (aiming) @as(f32, 1) else 0.25) - b.aim) * @min(1, dt * 10);
        if (b.reload >= 0) {
            b.reload += dt;
            if (b.reload >= st.reload) {
                b.reload = -1;
                b.ammo = st.mag;
            }
        }
        b.cooldown = @max(0, b.cooldown - dt);
        b.patience -= dt;
        const stride0 = b.body.stride;
        switch (b.state) {
            .dead => {},
            .seek => {
                if (b.cover == null or b.patience < 0) self.pickCover(b, i);
                if (b.cover) |c| {
                    if (moveTo(b, arena.cover_points[c].pos, dt, true)) {
                        b.state = .hide;
                        b.timer = 0.7 + 1.1 * b.rng.random().float(f32);
                    }
                } else {
                    // No cover hides the bot: it holds and fires.
                    b.state = .aim;
                    b.timer = 0.5;
                }
            },
            .hide => {
                _ = moveTo(b, arena.cover_points[b.cover.?].pos, dt, false);
                self.facePlayer(b, dt);
                b.timer -= dt;
                if (!self.hidden(b.cover.?)) {
                    // The player flanked the cover.
                    self.pickCover(b, i);
                } else if (b.timer <= 0 and b.reload < 0) {
                    if (b.cycles >= 3) {
                        self.pickCover(b, i);
                    } else if (self.pickPeek(b)) |pk| {
                        b.peek = pk;
                        b.state = .peek;
                        b.patience = 3;
                    } else {
                        self.pickCover(b, i);
                    }
                }
            },
            .peek => {
                const arrived = moveTo(b, arena.cover_points[b.peek.?].pos, dt, false);
                self.facePlayer(b, dt);
                if (self.sees(b.eye()) or arrived) {
                    b.state = .aim;
                    b.timer = 0.3 + 0.35 * b.rng.random().float(f32);
                }
                if (b.patience < 0) b.state = .back;
            },
            .aim => {
                b.body.step(dt, v3(0, 0, 0), false, bot_speed);
                self.facePlayer(b, dt);
                b.timer -= dt;
                if (!self.sees(b.eye())) {
                    if (b.timer < -0.8) b.state = .back;
                } else if (b.timer <= 0) {
                    b.state = .fire;
                    b.burst = 3 + b.rng.random().uintLessThan(u32, 4);
                }
            },
            .fire => {
                b.body.step(dt, v3(0, 0, 0), false, bot_speed);
                self.facePlayer(b, dt);
                if (b.burst == 0 or b.ammo == 0 or !self.alive()) {
                    if (b.ammo == 0) b.reload = 0;
                    b.state = .back;
                } else if (b.cooldown <= 0) {
                    if (!self.settings.bots_hold and self.sees(b.eye())) self.botShot(b, i, st);
                    b.burst -= 1;
                    b.cooldown += @max(st.interval, 0.09);
                }
            },
            .back => {
                if (b.cover) |c| {
                    if (moveTo(b, arena.cover_points[c].pos, dt, false)) {
                        b.state = .hide;
                        b.cycles += 1;
                        b.timer = 0.9 + 1.4 * b.rng.random().float(f32);
                    }
                    self.facePlayer(b, dt);
                } else b.state = .seek;
            },
        }
        // A run kicks up snow.
        if (b.body.stride - stride0 > 0 and b.body.stride - b.puff_stride > 0.75) {
            b.puff_stride = b.body.stride;
            if (self.events.step_n < self.events.steps.len) {
                self.events.steps[self.events.step_n] = b.body.pos;
                self.events.step_n += 1;
            }
        }
    }

    fn botShot(self: *Game, b: *Bot, i: usize, st: *const weapon.Stats) void {
        const sk = b.skeleton();
        const o = b.muzzle(sk);
        const target = self.you.pos + v3(0, chest_h, 0);
        const to = target - o;
        const dist = vec.len(to);
        const f = to / vec.s(dist);
        const right = vec.norm(vec.cross(f, v3(0, 1, 0)));
        const up = vec.cross(right, f);
        // The error grows when the player moves.
        const sp = @sqrt(self.you.vel[0] * self.you.vel[0] + self.you.vel[2] * self.you.vel[2]);
        const err = self.settings.bot_error * (1 + 0.6 * sp / player_mod.walk_speed);
        const r = err * @sqrt(b.rng.random().float(f32));
        const a = b.rng.random().float(f32) * std.math.tau;
        const d = vec.norm(f + right * vec.s(@cos(a) * r) + up * vec.s(@sin(a) * r));
        b.ammo -= 1;
        b.flash = 0.05;
        var shot: Shot = .{ .o = o, .e = o + d * vec.s(st.range), .normal = -d, .surface = null, .bot = i, .model = b.gun };
        var t_best = st.range;
        if (arena.raycast(o, d, st.range)) |h| {
            t_best = h.t;
            shot.e = o + d * vec.s(h.t);
            shot.normal = h.normal;
            shot.surface = arena.surfaceAt(shot.e, h.box);
            shot.snow = arena.snowAt(shot.e, h.box);
        }
        for (player_mod.hitBoxes(self.you.pos, self.you.yaw, self.you.lean), 0..) |hb, k| {
            const h = arena.rayBox(o, d, hb.min, hb.max) orelse continue;
            if (h.t < t_best) {
                t_best = h.t;
                shot.e = o + d * vec.s(h.t);
                shot.surface = .flesh;
                shot.snow = false;
                shot.flesh = true;
                shot.hit_player = true;
                shot.normal = -d;
                _ = k;
            }
        }
        if (shot.hit_player) {
            self.hurt = 0;
            self.hurt_dir = -d;
            if (!self.settings.god) {
                self.hp -= st.damageAt(false, t_best) * self.settings.bot_damage;
                if (self.hp <= 0) {
                    self.hp = 0;
                    self.dead_t = 0;
                }
            }
        }
        self.events.addShot(shot);
    }
};

// =============================================================================
// Tests
// =============================================================================

fn testFight(seed: u64, ticks: usize) Game {
    var g = Game.init(seed, .{});
    for (0..ticks) |t| {
        // Hold fire in bursts and turn a little.
        const ti: u32 = @intCast(t);
        g.step(1.0 / 60.0, .{ .fire = (ti / 30) % 3 == 0, .fire_pressed = ti % 90 == 0, .look_yaw = if ((ti / 120) % 2 == 0) 0.004 else -0.004, .move_x = if ((ti / 200) % 2 == 0) 0.6 else -0.6 });
    }
    return g;
}

test "game: the same seed and input give the same fight (REQ-DEMO-021)" {
    try weapon.loadModels(std.testing.allocator);
    defer {
        for (weapon.models) |m| std.testing.allocator.free(m.verts);
        std.testing.allocator.free(weapon.models);
        weapon.models = &.{};
    }
    arena.build();
    const a = testFight(5, 1500);
    const b = testFight(5, 1500);
    try std.testing.expectEqual(a.hp, b.hp);
    try std.testing.expectEqual(a.shots_fired, b.shots_fired);
    for (a.bots, b.bots) |x, y| {
        try std.testing.expectEqual(x.body.pos, y.body.pos);
        try std.testing.expectEqual(x.state, y.state);
        try std.testing.expectEqual(x.hp, y.hp);
    }
}

test "game: the bots take cover and fire back (REQ-DEMO-021)" {
    try weapon.loadModels(std.testing.allocator);
    defer {
        for (weapon.models) |m| std.testing.allocator.free(m.verts);
        std.testing.allocator.free(weapon.models);
        weapon.models = &.{};
    }
    arena.build();
    var g = Game.init(11, .{ .god = true });
    var hidden_ticks: u32 = 0;
    var bot_shots: u32 = 0;
    var player_hit = false;
    for (0..1200) |_| {
        g.step(1.0 / 60.0, .{});
        for (g.bots[0..g.bot_n]) |*b| {
            if (b.state == .hide) hidden_ticks += 1;
        }
        for (g.events.shots[0..g.events.shot_n]) |s| {
            if (s.bot != null) bot_shots += 1;
            if (s.hit_player) player_hit = true;
        }
    }
    try std.testing.expect(hidden_ticks > 300);
    try std.testing.expect(bot_shots > 5);
    try std.testing.expect(player_hit);
}
