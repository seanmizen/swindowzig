const std = @import("std");
const sw = @import("sw_app");

pub const Vec2 = struct {
    x: f32,
    y: f32,

    pub fn add(self: Vec2, other: Vec2) Vec2 {
        return .{ .x = self.x + other.x, .y = self.y + other.y };
    }

    pub fn scale(self: Vec2, s: f32) Vec2 {
        return .{ .x = self.x * s, .y = self.y * s };
    }

    pub fn length(self: Vec2) f32 {
        return @sqrt(self.x * self.x + self.y * self.y);
    }

    pub fn normalize(self: Vec2) Vec2 {
        const len = self.length();
        if (len == 0) return .{ .x = 0, .y = 0 };
        return .{ .x = self.x / len, .y = self.y / len };
    }
};

pub const Ship = struct {
    pos: Vec2,
    vel: Vec2,
    angle: f32, // radians
    alive: bool,
    respawn_timer: f32,

    pub fn init() Ship {
        return .{
            .pos = .{ .x = 640, .y = 360 },
            .vel = .{ .x = 0, .y = 0 },
            .angle = -std.math.pi / 2.0, // Point up
            .alive = true,
            .respawn_timer = 0,
        };
    }

    pub fn update(self: *Ship, input: Input, dt: f32, width: f32, height: f32) void {
        if (!self.alive) {
            self.respawn_timer -= dt;
            if (self.respawn_timer <= 0) {
                self.* = Ship.init();
            }
            return;
        }

        // Rotation
        if (input.turn_left) {
            self.angle -= 3.0 * dt;
        }
        if (input.turn_right) {
            self.angle += 3.0 * dt;
        }

        // Thrust
        if (input.thrust) {
            const thrust_power: f32 = 200.0;
            self.vel.x += @cos(self.angle) * thrust_power * dt;
            self.vel.y += @sin(self.angle) * thrust_power * dt;
        }

        // Apply drag
        self.vel = self.vel.scale(0.99);

        // Update position
        self.pos = self.pos.add(self.vel.scale(dt));

        // Wrap around screen
        if (self.pos.x < 0) self.pos.x += width;
        if (self.pos.x > width) self.pos.x -= width;
        if (self.pos.y < 0) self.pos.y += height;
        if (self.pos.y > height) self.pos.y -= height;
    }

    pub fn die(self: *Ship) void {
        self.alive = false;
        self.respawn_timer = 3.0; // 3 seconds to respawn
    }
};

pub const Bullet = struct {
    pos: Vec2,
    vel: Vec2,
    lifetime: f32,
    active: bool,

    pub fn init(pos: Vec2, angle: f32) Bullet {
        const speed: f32 = 400.0;
        return .{
            .pos = pos,
            .vel = .{
                .x = @cos(angle) * speed,
                .y = @sin(angle) * speed,
            },
            .lifetime = 1.5,
            .active = true,
        };
    }

    pub fn update(self: *Bullet, dt: f32, width: f32, height: f32) void {
        if (!self.active) return;

        self.lifetime -= dt;
        if (self.lifetime <= 0) {
            self.active = false;
            return;
        }

        self.pos = self.pos.add(self.vel.scale(dt));

        // Wrap around screen
        if (self.pos.x < 0) self.pos.x += width;
        if (self.pos.x > width) self.pos.x -= width;
        if (self.pos.y < 0) self.pos.y += height;
        if (self.pos.y > height) self.pos.y -= height;
    }
};

pub const AsteroidSize = enum {
    large,
    medium,
    small,

    pub fn radius(self: AsteroidSize) f32 {
        return switch (self) {
            .large => 40,
            .medium => 25,
            .small => 15,
        };
    }

    pub fn split(self: AsteroidSize) ?AsteroidSize {
        return switch (self) {
            .large => .medium,
            .medium => .small,
            .small => null,
        };
    }
};

pub const Asteroid = struct {
    pos: Vec2,
    vel: Vec2,
    size: AsteroidSize,
    active: bool,

    pub fn init(pos: Vec2, vel: Vec2, size: AsteroidSize) Asteroid {
        return .{
            .pos = pos,
            .vel = vel,
            .size = size,
            .active = true,
        };
    }

    pub fn update(self: *Asteroid, dt: f32, width: f32, height: f32) void {
        if (!self.active) return;

        self.pos = self.pos.add(self.vel.scale(dt));

        // Wrap around screen
        if (self.pos.x < 0) self.pos.x += width;
        if (self.pos.x > width) self.pos.x -= width;
        if (self.pos.y < 0) self.pos.y += height;
        if (self.pos.y > height) self.pos.y -= height;
    }
};

pub const Input = struct {
    thrust: bool,
    turn_left: bool,
    turn_right: bool,
    fire: bool,
};

// Events that occurred this tick (for audio/effects)
pub const Events = struct {
    fired: bool = false,
    asteroid_hit: bool = false,
    ship_died: bool = false,
    thrust: bool = false,
};

pub const Game = struct {
    ship: Ship,
    bullets: [32]Bullet,
    asteroids: [64]Asteroid,
    score: u32,
    lives: u32,
    width: f32,
    height: f32,
    fire_cooldown: f32,
    tick_count: u64,
    last_input: Input,
    events: Events,

    pub fn init(width: f32, height: f32) Game {
        var game = Game{
            .ship = Ship.init(),
            .bullets = undefined,
            .asteroids = undefined,
            .score = 0,
            .lives = 3,
            .width = width,
            .height = height,
            .fire_cooldown = 0,
            .tick_count = 0,
            .last_input = .{
                .thrust = false,
                .turn_left = false,
                .turn_right = false,
                .fire = false,
            },
            .events = .{},
        };

        // Initialize bullets as inactive
        for (&game.bullets) |*bullet| {
            bullet.* = .{
                .pos = .{ .x = 0, .y = 0 },
                .vel = .{ .x = 0, .y = 0 },
                .lifetime = 0,
                .active = false,
            };
        }

        // Initialize asteroids as inactive
        for (&game.asteroids) |*asteroid| {
            asteroid.* = .{
                .pos = .{ .x = 0, .y = 0 },
                .vel = .{ .x = 0, .y = 0 },
                .size = .small,
                .active = false,
            };
        }

        // Spawn initial asteroids
        game.spawnInitialAsteroids();

        return game;
    }

    fn spawnInitialAsteroids(self: *Game) void {
        var prng = std.Random.DefaultPrng.init(42);
        const random = prng.random();

        var i: usize = 0;
        while (i < 5) : (i += 1) {
            const angle = random.float(f32) * std.math.pi * 2.0;
            const distance: f32 = 300.0 + random.float(f32) * 200.0; // Spawn further away
            const pos = Vec2{
                .x = self.width / 2.0 + @cos(angle) * distance,
                .y = self.height / 2.0 + @sin(angle) * distance,
            };
            const vel_angle = random.float(f32) * std.math.pi * 2.0;
            const speed = 50.0 + random.float(f32) * 50.0;
            const vel = Vec2{
                .x = @cos(vel_angle) * speed,
                .y = @sin(vel_angle) * speed,
            };
            self.asteroids[i] = Asteroid.init(pos, vel, .large);
        }
    }

    pub fn setDimensions(self: *Game, width: f32, height: f32) void {
        self.width = width;
        self.height = height;
    }

    pub fn update(self: *Game, input: Input, dt: f32) void {
        self.tick_count += 1;
        self.last_input = input;

        // Clear events from previous tick
        self.events = .{};

        // Track thrust for audio
        self.events.thrust = input.thrust and self.ship.alive;

        // Update fire cooldown
        if (self.fire_cooldown > 0) {
            self.fire_cooldown -= dt;
        }

        // Update ship
        self.ship.update(input, dt, self.width, self.height);

        // Fire bullet
        if (input.fire and self.fire_cooldown <= 0 and self.ship.alive) {
            self.fire_cooldown = 0.16; // 160ms between shots (~16/sec)
            for (&self.bullets) |*bullet| {
                if (!bullet.active) {
                    bullet.* = Bullet.init(self.ship.pos, self.ship.angle);
                    self.events.fired = true;
                    break;
                }
            }
        }

        // Update bullets
        for (&self.bullets) |*bullet| {
            bullet.update(dt, self.width, self.height);
        }

        // Update asteroids
        for (&self.asteroids) |*asteroid| {
            asteroid.update(dt, self.width, self.height);
        }

        // Check bullet-asteroid collisions
        for (&self.bullets) |*bullet| {
            if (!bullet.active) continue;

            for (&self.asteroids) |*asteroid| {
                if (!asteroid.active) continue;

                const dx = bullet.pos.x - asteroid.pos.x;
                const dy = bullet.pos.y - asteroid.pos.y;
                const dist_sq = dx * dx + dy * dy;
                const radius = asteroid.size.radius();

                if (dist_sq < radius * radius) {
                    // Hit!
                    bullet.active = false;
                    asteroid.active = false;
                    self.score += 100;
                    self.events.asteroid_hit = true;

                    // Split asteroid
                    if (asteroid.size.split()) |smaller_size| {
                        var prng = std.Random.DefaultPrng.init(@intCast(self.score));
                        const random = prng.random();

                        // Create two smaller asteroids
                        var count: usize = 0;
                        for (&self.asteroids) |*new_asteroid| {
                            if (!new_asteroid.active and count < 2) {
                                const angle = random.float(f32) * std.math.pi * 2.0;
                                const speed = 100.0 + random.float(f32) * 50.0;
                                const vel = Vec2{
                                    .x = @cos(angle) * speed,
                                    .y = @sin(angle) * speed,
                                };
                                new_asteroid.* = Asteroid.init(asteroid.pos, vel, smaller_size);
                                count += 1;
                            }
                        }
                    }

                    break;
                }
            }
        }

        // Check ship-asteroid collisions (using smaller radius for ship)
        if (self.ship.alive) {
            for (self.asteroids) |asteroid| {
                if (!asteroid.active) continue;

                const dx = self.ship.pos.x - asteroid.pos.x;
                const dy = self.ship.pos.y - asteroid.pos.y;
                const dist_sq = dx * dx + dy * dy;
                const ship_radius: f32 = 10.0; // Smaller hitbox for ship
                const total_radius = asteroid.size.radius() + ship_radius;

                if (dist_sq < total_radius * total_radius) {
                    // Ship hit!
                    self.ship.die();
                    self.events.ship_died = true;
                    if (self.lives > 0) {
                        self.lives -= 1;
                    }
                    break;
                }
            }
        }
    }
};
