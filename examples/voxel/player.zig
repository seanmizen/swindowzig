const std = @import("std");
const chunk_mod = @import("chunk.zig");
const Chunk = chunk_mod.Chunk;
const BlockGetter = chunk_mod.BlockGetter;
const mesher_mod = @import("mesher.zig");
const VoxelVertex = mesher_mod.VoxelVertex;

pub const PLAYER_RADIUS: f32 = 0.3;
pub const PLAYER_HEIGHT: f32 = 1.8;
pub const EYE_HEIGHT: f32 = 1.6;
pub const GRAVITY: f32 = 28.0; // m/s², 1 block = 1 metre
pub const JUMP_SPEED: f32 = 8.0;
pub const BASE_SPEED: f32 = 5.0;
pub const SPRINT_SPEED: f32 = 9.0;

pub const CYLINDER_SEGS: usize = 16;
// N=16: sides = N*4 verts + N*6 idx; each cap = (1+N) verts + N*3 idx
// Each cap: 1 center + N*2 edge verts (2 per segment, both arc endpoints, unshared)
pub const CYLINDER_VERT_COUNT: usize = CYLINDER_SEGS * 4 + 2 * (1 + CYLINDER_SEGS * 2);
pub const CYLINDER_IDX_COUNT: usize = CYLINDER_SEGS * 6 + 2 * CYLINDER_SEGS * 3;

pub const FLY_SPEED: f32 = 10.0;
const DOUBLE_TAP_WINDOW: f32 = 0.3; // seconds

pub const Player = struct {
    feet_pos: [3]f32,
    velocity: [3]f32,
    on_ground: bool,
    fly_mode: bool,
    space_tap_pending: bool,
    space_tap_timer: f32,

    pub fn init(x: f32, y: f32, z: f32) Player {
        return .{
            .feet_pos = .{ x, y, z },
            .velocity = .{ 0, 0, 0 },
            .on_ground = false,
            .fly_mode = false,
            .space_tap_pending = false,
            .space_tap_timer = 0,
        };
    }

    /// Eye position = feet + EYE_HEIGHT
    pub fn eyePos(self: *const Player) [3]f32 {
        return .{ self.feet_pos[0], self.feet_pos[1] + EYE_HEIGHT, self.feet_pos[2] };
    }

    /// Physics tick: apply gravity, move with WASD in horizontal plane, resolve AABB collisions.
    /// cam_yaw is the camera yaw so horizontal movement aligns with where you're looking.
    pub fn tick(
        self: *Player,
        getter: BlockGetter,
        dt: f32,
        cam_yaw: f32,
        forward_input: f32,
        right_input: f32,
        jump: bool, // keyPressed — one-shot (jump trigger + double-tap detection)
        space_held: bool, // keyDown   — continuous (fly-up while held)
        sprint: bool,
    ) void {
        // Double-tap Space detection: toggle fly mode.
        // First tap arms the timer; second tap within the window flips fly_mode.
        if (jump) {
            if (self.space_tap_pending and self.space_tap_timer > 0) {
                self.fly_mode = !self.fly_mode;
                self.velocity[1] = 0;
                self.space_tap_pending = false;
                self.space_tap_timer = 0;
            } else {
                self.space_tap_pending = true;
                self.space_tap_timer = DOUBLE_TAP_WINDOW;
            }
        }
        // Decay the double-tap window.
        if (self.space_tap_timer > 0) {
            self.space_tap_timer -= dt;
            if (self.space_tap_timer <= 0) {
                self.space_tap_pending = false;
            }
        }

        const cy = @cos(cam_yaw);
        const sy = @sin(cam_yaw);

        if (self.fly_mode) {
            // Flying: no gravity, Space = up, Shift = down.
            const spd = FLY_SPEED;
            const dx = (cy * forward_input + (-sy) * right_input) * spd * dt;
            const dz = (sy * forward_input + cy * right_input) * spd * dt;
            const dy: f32 = if (space_held) spd * dt else if (sprint) -spd * dt else 0;

            self.feet_pos[0] = resolveX(getter, self.feet_pos, self.feet_pos[0] + dx);
            self.feet_pos[2] = resolveZ(getter, self.feet_pos, self.feet_pos[2] + dz);
            const new_y = self.feet_pos[1] + dy;
            self.feet_pos[1] = resolveY(getter, self.feet_pos, new_y);
            self.on_ground = isOnGround(getter, self.feet_pos);

            // Land on solid ground → exit fly mode automatically.
            if (self.on_ground and !space_held) {
                self.fly_mode = false;
                self.velocity[1] = 0;
            }
        } else {
            // Normal physics mode.

            // Reset accumulated downward velocity when grounded.
            if (self.on_ground and self.velocity[1] < 0) {
                self.velocity[1] = 0;
            }

            // Jump (uses on_ground from end of last tick).
            if (jump and self.on_ground) {
                self.velocity[1] = JUMP_SPEED;
            }

            // Gravity when airborne.
            if (!self.on_ground) {
                self.velocity[1] -= GRAVITY * dt;
                if (self.velocity[1] < -50.0) self.velocity[1] = -50.0;
            }

            // Horizontal movement aligned to camera yaw.
            const spd = if (sprint) SPRINT_SPEED else BASE_SPEED;
            const dx = (cy * forward_input + (-sy) * right_input) * spd * dt;
            const dz = (sy * forward_input + cy * right_input) * spd * dt;
            const dy = self.velocity[1] * dt;

            // Resolve Y first (ground/ceiling), then X/Z.
            const new_y = self.feet_pos[1] + dy;
            const resolved_y = resolveY(getter, self.feet_pos, new_y);
            if (dy > 0 and resolved_y < new_y - 0.001) {
                self.velocity[1] = 0; // hit ceiling
            }
            self.feet_pos[1] = resolved_y;

            self.feet_pos[0] = resolveX(getter, self.feet_pos, self.feet_pos[0] + dx);
            self.feet_pos[2] = resolveZ(getter, self.feet_pos, self.feet_pos[2] + dz);

            self.on_ground = isOnGround(getter, self.feet_pos);
        }
    }
};

// ---------------------------------------------------------------------------
// Collision helpers
// ---------------------------------------------------------------------------

const EPS: f32 = 0.001;

/// True when there is a solid block in the column directly below the player's feet.
fn isOnGround(getter: BlockGetter, pos: [3]f32) bool {
    const x0: i32 = @intFromFloat(std.math.floor(pos[0] - PLAYER_RADIUS + EPS));
    const x1: i32 = @intFromFloat(std.math.floor(pos[0] + PLAYER_RADIUS - EPS));
    const z0: i32 = @intFromFloat(std.math.floor(pos[2] - PLAYER_RADIUS + EPS));
    const z1: i32 = @intFromFloat(std.math.floor(pos[2] + PLAYER_RADIUS - EPS));
    // The block just below feet: floor(feet_y - eps).
    // At feet_y=8.0 (standing on top of y=7 block): floor(7.999) = 7 → solid ✓
    const by: i32 = @intFromFloat(std.math.floor(pos[1] - EPS));
    var xi = x0;
    while (xi <= x1) : (xi += 1) {
        var zi = z0;
        while (zi <= z1) : (zi += 1) {
            if (getter.getBlock(xi, by, zi) != .air) return true;
        }
    }
    return false;
}

/// Resolve Y movement: sweep feet (moving down) or head (moving up) against blocks.
fn resolveY(getter: BlockGetter, pos: [3]f32, new_y: f32) f32 {
    if (new_y == pos[1]) return new_y;

    const x0: i32 = @intFromFloat(std.math.floor(pos[0] - PLAYER_RADIUS + EPS));
    const x1: i32 = @intFromFloat(std.math.floor(pos[0] + PLAYER_RADIUS - EPS));
    const z0: i32 = @intFromFloat(std.math.floor(pos[2] - PLAYER_RADIUS + EPS));
    const z1: i32 = @intFromFloat(std.math.floor(pos[2] + PLAYER_RADIUS - EPS));

    if (new_y < pos[1]) {
        // Moving down: check block at new feet level.
        const by: i32 = @intFromFloat(std.math.floor(new_y));
        var xi = x0;
        while (xi <= x1) : (xi += 1) {
            var zi = z0;
            while (zi <= z1) : (zi += 1) {
                if (getter.getBlock(xi, by, zi) != .air) {
                    // Block top is at by+1; stand feet there.
                    return @as(f32, @floatFromInt(by)) + 1.0;
                }
            }
        }
    } else {
        // Moving up: check block at new head level.
        const head_y: i32 = @intFromFloat(std.math.floor(new_y + PLAYER_HEIGHT));
        var xi = x0;
        while (xi <= x1) : (xi += 1) {
            var zi = z0;
            while (zi <= z1) : (zi += 1) {
                if (getter.getBlock(xi, head_y, zi) != .air) {
                    // Block bottom is at head_y; feet go to head_y - HEIGHT.
                    return @as(f32, @floatFromInt(head_y)) - PLAYER_HEIGHT;
                }
            }
        }
    }
    return new_y;
}

/// Resolve X movement: sweep the leading edge against blocks.
fn resolveX(getter: BlockGetter, pos: [3]f32, new_x: f32) f32 {
    if (new_x == pos[0]) return new_x;

    const y0: i32 = @intFromFloat(std.math.floor(pos[1] + EPS));
    const y1: i32 = @intFromFloat(std.math.floor(pos[1] + PLAYER_HEIGHT - EPS));
    const z0: i32 = @intFromFloat(std.math.floor(pos[2] - PLAYER_RADIUS + EPS));
    const z1: i32 = @intFromFloat(std.math.floor(pos[2] + PLAYER_RADIUS - EPS));

    if (new_x > pos[0]) {
        const bx: i32 = @intFromFloat(std.math.floor(new_x + PLAYER_RADIUS));
        var yi = y0;
        while (yi <= y1) : (yi += 1) {
            var zi = z0;
            while (zi <= z1) : (zi += 1) {
                if (getter.getBlock(bx, yi, zi) != .air) {
                    return @as(f32, @floatFromInt(bx)) - PLAYER_RADIUS;
                }
            }
        }
    } else {
        const bx: i32 = @intFromFloat(std.math.floor(new_x - PLAYER_RADIUS));
        var yi = y0;
        while (yi <= y1) : (yi += 1) {
            var zi = z0;
            while (zi <= z1) : (zi += 1) {
                if (getter.getBlock(bx, yi, zi) != .air) {
                    return @as(f32, @floatFromInt(bx + 1)) + PLAYER_RADIUS;
                }
            }
        }
    }
    return new_x;
}

/// Resolve Z movement: sweep the leading edge against blocks.
fn resolveZ(getter: BlockGetter, pos: [3]f32, new_z: f32) f32 {
    if (new_z == pos[2]) return new_z;

    const y0: i32 = @intFromFloat(std.math.floor(pos[1] + EPS));
    const y1: i32 = @intFromFloat(std.math.floor(pos[1] + PLAYER_HEIGHT - EPS));
    const x0: i32 = @intFromFloat(std.math.floor(pos[0] - PLAYER_RADIUS + EPS));
    const x1: i32 = @intFromFloat(std.math.floor(pos[0] + PLAYER_RADIUS - EPS));

    if (new_z > pos[2]) {
        const bz: i32 = @intFromFloat(std.math.floor(new_z + PLAYER_RADIUS));
        var yi = y0;
        while (yi <= y1) : (yi += 1) {
            var xi = x0;
            while (xi <= x1) : (xi += 1) {
                if (getter.getBlock(xi, yi, bz) != .air) {
                    return @as(f32, @floatFromInt(bz)) - PLAYER_RADIUS;
                }
            }
        }
    } else {
        const bz: i32 = @intFromFloat(std.math.floor(new_z - PLAYER_RADIUS));
        var yi = y0;
        while (yi <= y1) : (yi += 1) {
            var xi = x0;
            while (xi <= x1) : (xi += 1) {
                if (getter.getBlock(xi, yi, bz) != .air) {
                    return @as(f32, @floatFromInt(bz + 1)) + PLAYER_RADIUS;
                }
            }
        }
    }
    return new_z;
}

// ---------------------------------------------------------------------------
// Cylinder mesh generation
// ---------------------------------------------------------------------------

/// Write the player's hitbox cylinder into scratch ArrayList buffers.
/// Uses clearRetainingCapacity so after the first frame there are no allocations.
/// block_type=100 maps to a distinct cyan color in the shader.
pub fn buildCylinderMesh(
    feet: [3]f32,
    allocator: std.mem.Allocator,
    verts: *std.ArrayList(VoxelVertex),
    idx: *std.ArrayList(u32),
) !void {
    verts.clearRetainingCapacity();
    idx.clearRetainingCapacity();

    const N = CYLINDER_SEGS;
    const r = PLAYER_RADIUS;
    const cx = feet[0];
    const cz = feet[2];
    const cy_bot = feet[1];
    const cy_top = feet[1] + PLAYER_HEIGHT;
    const bt: u32 = 100; // player hitbox block type → cyan in shader
    const tau = 2.0 * std.math.pi;

    // Side panels: N quads
    for (0..N) |i| {
        const a0 = tau * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(N));
        const a1 = tau * @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(N));
        const c0 = @cos(a0);
        const s0 = @sin(a0);
        const c1 = @cos(a1);
        const s1 = @sin(a1);
        // Face normal at midpoint angle
        const am = a0 + (a1 - a0) * 0.5;
        const nx = @cos(am);
        const nz = @sin(am);

        const base: u32 = @intCast(verts.items.len);
        try verts.appendSlice(allocator, &[_]VoxelVertex{
            .{ .pos = .{ cx + r * c0, cy_bot, cz + r * s0 }, .normal = .{ nx, 0, nz }, .block_type = bt, .uv = .{ 0, 0 } },
            .{ .pos = .{ cx + r * c0, cy_top, cz + r * s0 }, .normal = .{ nx, 0, nz }, .block_type = bt, .uv = .{ 0, 1 } },
            .{ .pos = .{ cx + r * c1, cy_top, cz + r * s1 }, .normal = .{ nx, 0, nz }, .block_type = bt, .uv = .{ 1, 1 } },
            .{ .pos = .{ cx + r * c1, cy_bot, cz + r * s1 }, .normal = .{ nx, 0, nz }, .block_type = bt, .uv = .{ 1, 0 } },
        });
        try idx.appendSlice(allocator, &[_]u32{ base, base + 1, base + 2, base, base + 2, base + 3 });
    }

    // Top cap: center vertex + N triangle fan
    const top_center: u32 = @intCast(verts.items.len);
    try verts.append(allocator, .{ .pos = .{ cx, cy_top, cz }, .normal = .{ 0, 1, 0 }, .block_type = bt, .uv = .{ 0.5, 0.5 } });
    for (0..N) |i| {
        const a0 = tau * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(N));
        const a1 = tau * @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(N));
        const base: u32 = @intCast(verts.items.len);
        try verts.appendSlice(allocator, &[_]VoxelVertex{
            .{ .pos = .{ cx + r * @cos(a0), cy_top, cz + r * @sin(a0) }, .normal = .{ 0, 1, 0 }, .block_type = bt, .uv = .{ 0, 0 } },
            .{ .pos = .{ cx + r * @cos(a1), cy_top, cz + r * @sin(a1) }, .normal = .{ 0, 1, 0 }, .block_type = bt, .uv = .{ 1, 0 } },
        });
        // CCW winding viewed from above (+Y)
        try idx.appendSlice(allocator, &[_]u32{ top_center, base, base + 1 });
    }

    // Bottom cap: reverse winding
    const bot_center: u32 = @intCast(verts.items.len);
    try verts.append(allocator, .{ .pos = .{ cx, cy_bot, cz }, .normal = .{ 0, -1, 0 }, .block_type = bt, .uv = .{ 0.5, 0.5 } });
    for (0..N) |i| {
        const a0 = tau * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(N));
        const a1 = tau * @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(N));
        const base: u32 = @intCast(verts.items.len);
        try verts.appendSlice(allocator, &[_]VoxelVertex{
            .{ .pos = .{ cx + r * @cos(a0), cy_bot, cz + r * @sin(a0) }, .normal = .{ 0, -1, 0 }, .block_type = bt, .uv = .{ 0, 0 } },
            .{ .pos = .{ cx + r * @cos(a1), cy_bot, cz + r * @sin(a1) }, .normal = .{ 0, -1, 0 }, .block_type = bt, .uv = .{ 1, 0 } },
        });
        // Reverse winding for bottom cap (CCW viewed from below)
        try idx.appendSlice(allocator, &[_]u32{ bot_center, base + 1, base });
    }
}
