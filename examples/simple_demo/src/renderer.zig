const std = @import("std");
const sw = @import("sw_app");
const game = @import("game.zig");

pub const Renderer = struct {
    width: f32,
    height: f32,

    pub fn init(width: f32, height: f32) Renderer {
        return .{
            .width = width,
            .height = height,
        };
    }

    pub fn setDimensions(self: *Renderer, width: f32, height: f32) void {
        self.width = width;
        self.height = height;
    }

    pub fn draw(self: *Renderer, ctx: *sw.Context, g: *const game.Game) !void {
        if (!ctx.gpu().isReady()) return;

        // Clear to black space
        ctx.gpu().clearScreen(0.0, 0.0, 0.0, 1.0);

        // Begin frame
        ctx.gpu().beginFrame();

        // Draw ship
        if (g.ship.alive) {
            self.drawShip(ctx, g.ship);
        }

        // Draw bullets
        for (g.bullets) |bullet| {
            if (bullet.active) {
                self.drawBullet(ctx, bullet);
            }
        }

        // Draw asteroids
        for (g.asteroids) |asteroid| {
            if (asteroid.active) {
                self.drawAsteroid(ctx, asteroid);
            }
        }

        // End frame
        ctx.gpu().endFrame();
    }

    fn drawShip(self: *Renderer, ctx: *sw.Context, ship: game.Ship) void {
        _ = self;
        const gpu = ctx.gpu();

        // Ship is a triangle
        const size: f32 = 15.0;
        const cos = @cos(ship.angle);
        const sin = @sin(ship.angle);

        // Front point
        const fx = ship.pos.x + cos * size;
        const fy = ship.pos.y + sin * size;

        // Back left
        const blx = ship.pos.x + @cos(ship.angle + 2.5) * size;
        const bly = ship.pos.y + @sin(ship.angle + 2.5) * size;

        // Back right
        const brx = ship.pos.x + @cos(ship.angle - 2.5) * size;
        const bry = ship.pos.y + @sin(ship.angle - 2.5) * size;

        // Draw triangle
        gpu.drawLine(fx, fy, blx, bly, 0.0, 1.0, 0.0, 1.0); // Green
        gpu.drawLine(blx, bly, brx, bry, 0.0, 1.0, 0.0, 1.0);
        gpu.drawLine(brx, bry, fx, fy, 0.0, 1.0, 0.0, 1.0);
    }

    fn drawBullet(self: *Renderer, ctx: *sw.Context, bullet: game.Bullet) void {
        _ = self;
        const gpu = ctx.gpu();

        // Draw small circle for bullet
        gpu.drawCircle(bullet.pos.x, bullet.pos.y, 3.0, 1.0, 1.0, 1.0, 1.0); // White
    }

    fn drawAsteroid(self: *Renderer, ctx: *sw.Context, asteroid: game.Asteroid) void {
        _ = self;
        const gpu = ctx.gpu();

        // Draw circle for asteroid
        const radius = asteroid.size.radius();
        gpu.drawCircle(asteroid.pos.x, asteroid.pos.y, radius, 0.7, 0.7, 0.7, 1.0); // Gray
    }
};
