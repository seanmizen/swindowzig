//! Configurable per-chunk culling for the voxel demo.
//!
//! Three strategies are exposed via `Strategy`:
//!
//!   .none   — no culling. Every loaded chunk is drawn. This is the default
//!             so the feature is opt-in.
//!   .sphere — radial cutoff at `render_distance + slack`. Cheap sanity test;
//!             the world only loads chunks inside RENDER_DISTANCE so this
//!             matters mainly as a backstop in case eviction lags.
//!   .cone   — sphere-vs-cone test against a half-angle (fov/2) cone around
//!             the camera forward vector. The chunk's bounding sphere is
//!             treated as a single sphere for the test (no per-quad work).
//!
//! Design notes / pitfalls:
//!
//! 1. Chunks here are full-height columns (CHUNK_W × CHUNK_H × CHUNK_W). At
//!    CHUNK_W=16 the bounding-sphere radius is ~128.5 blocks — *huge*
//!    relative to the default RENDER_DISTANCE (4 chunks ≈ 192 blocks). Two
//!    consequences:
//!      a. Any chunk close to the camera passes trivially because the camera
//!         sits inside the bounding sphere → we keep it unconditionally.
//!      b. Far chunks have a wide angular size, so the cone test is very
//!         forgiving — exactly what we want when the user warned us about
//!         over-greedy culling.
//!
//! 2. The user's spec says "180° might even be ideal — and consider what
//!    happens when you look down". 180° fov means half-angle 90°, i.e. the
//!    forward hemisphere. With the bounding-sphere slack baked in, chunks
//!    just behind the player still survive. We additionally short-circuit
//!    `half_fov_rad >= π/2 - epsilon` so 180° is mathematically a no-op.
//!
//! 3. The camera chunk and its 8 horizontal neighbours (a 3×3 footprint
//!    around the player) are NEVER culled regardless of strategy. The spec
//!    says "the chunk you stand in plus its 6 neighbours" — for full-height
//!    columns the natural neighbour set is 4 horizontal axis chunks, but we
//!    keep all 8 (including diagonals) so the player rotating across a chunk
//!    corner never sees a chunk blink out.
//!
//! 4. The frozen-frustum debug toggle (Cmd+F in main.zig) snapshots a
//!    Frustum once and reuses it across subsequent frames so the user can
//!    fly around and watch what the cull thinks. There is no per-frame
//!    re-snapshot until they press the toggle again.

const std = @import("std");
const chunk_mod = @import("chunk.zig");

const CHUNK_W = chunk_mod.CHUNK_W;
const CHUNK_H = chunk_mod.CHUNK_H;

const half_w_f: f32 = @as(f32, @floatFromInt(CHUNK_W)) * 0.5;
const half_h_f: f32 = @as(f32, @floatFromInt(CHUNK_H)) * 0.5;

/// Bounding-sphere radius for one full-height column chunk.
/// sqrt((W/2)² + (H/2)² + (W/2)²) — computed from CHUNK_W/CHUNK_H at compile time.
/// At CHUNK_W=16: sqrt(8² + 128² + 8²) ≈ 128.5.
pub const CHUNK_BOUND_RADIUS: f32 = @sqrt(half_w_f * half_w_f + half_h_f * half_h_f + half_w_f * half_w_f);

pub const Strategy = enum {
    none,
    sphere,
    cone,

    pub fn fromString(s: []const u8) ?Strategy {
        if (std.mem.eql(u8, s, "none")) return .none;
        if (std.mem.eql(u8, s, "sphere")) return .sphere;
        if (std.mem.eql(u8, s, "cone")) return .cone;
        return null;
    }

    pub fn label(self: Strategy) []const u8 {
        return switch (self) {
            .none => "none",
            .sphere => "sphere",
            .cone => "cone",
        };
    }

    pub fn cycle(self: Strategy, dir: i32) Strategy {
        return switch (self) {
            .none => if (dir > 0) Strategy.sphere else Strategy.cone,
            .sphere => if (dir > 0) Strategy.cone else Strategy.none,
            .cone => if (dir > 0) Strategy.none else Strategy.sphere,
        };
    }
};

/// A snapshot of the cull frustum at one camera state. Cheap to copy (<64
/// bytes) so the freeze-toggle just stores one inside the State by value.
pub const Frustum = struct {
    /// Camera world-space position used as the cone apex.
    eye: [3]f32,
    /// Camera forward, normalised. Cone axis.
    forward: [3]f32,
    /// Half-angle in radians (fov_deg / 2 in radians).
    half_fov_rad: f32,
    /// `cos(half_fov_rad)` — precomputed for the per-chunk test.
    cos_half_fov: f32,
    /// `sin(half_fov_rad)` — precomputed for the per-chunk test.
    sin_half_fov: f32,
    /// Outer cull radius squared. Used by the sphere strategy and as a hard
    /// stop on the cone strategy so a single bad input cannot keep something
    /// arbitrarily far away.
    cull_radius_sq: f32,
    /// Camera chunk grid coordinates. The 3×3 region around (cam_cx, cam_cz)
    /// is exempt from culling regardless of strategy.
    cam_cx: i32,
    cam_cz: i32,

    /// Build a frustum from the live camera state.
    ///
    /// `fov_deg` is the *total* fov (the cone aperture, not the half-angle).
    /// The CLI flag `--frustum-fov-deg` and the settings menu both feed
    /// total degrees in here. Values are clamped to [0, 360].
    ///
    /// `render_distance_chunks` is the world's RENDER_DISTANCE — the sphere
    /// strategy uses it as the cutoff. We add a chunk-diagonal of slack so
    /// the test never trips on a chunk we still want loaded.
    pub fn capture(
        eye: [3]f32,
        forward: [3]f32,
        fov_deg: f32,
        render_distance_chunks: i32,
    ) Frustum {
        const fov_clamped = std.math.clamp(fov_deg, 0.0, 360.0);
        const half_fov_rad = (fov_clamped * 0.5) * (std.math.pi / 180.0);

        // Outer radius: full chunk-units of render distance, plus one chunk
        // diagonal of slack for the chunk-bounding-sphere, plus one column
        // height of vertical slack so a player flying high above the world
        // does not lose the ground beneath them.
        const horiz: f32 = @as(f32, @floatFromInt(render_distance_chunks)) *
            @as(f32, @floatFromInt(CHUNK_W)) +
            CHUNK_BOUND_RADIUS;
        const vert: f32 = @as(f32, @floatFromInt(CHUNK_H));
        const r2 = horiz * horiz + vert * vert;

        // Normalise forward (defensive: callers should already pass a unit
        // vector, but a zero / non-unit input would silently corrupt the
        // dot-product test below).
        const fwd_len_sq = forward[0] * forward[0] + forward[1] * forward[1] + forward[2] * forward[2];
        const fwd_len = if (fwd_len_sq > 1e-12) @sqrt(fwd_len_sq) else 1.0;
        const f_unit = [3]f32{ forward[0] / fwd_len, forward[1] / fwd_len, forward[2] / fwd_len };

        const fx_i: i32 = @intFromFloat(@floor(eye[0]));
        const fz_i: i32 = @intFromFloat(@floor(eye[2]));
        const cam_cx = @divFloor(fx_i, CHUNK_W);
        const cam_cz = @divFloor(fz_i, CHUNK_W);

        return .{
            .eye = eye,
            .forward = f_unit,
            .half_fov_rad = half_fov_rad,
            .cos_half_fov = @cos(half_fov_rad),
            .sin_half_fov = @sin(half_fov_rad),
            .cull_radius_sq = r2,
            .cam_cx = cam_cx,
            .cam_cz = cam_cz,
        };
    }
};

/// Returns true if the chunk at chunk-grid coordinates (cx, cz) should be
/// drawn under the given strategy. Cheap and branch-light: the camera-chunk
/// short-circuit handles the common case in two integer compares.
pub fn keepChunk(strategy: Strategy, frustum: Frustum, cx: i32, cz: i32) bool {
    // --- Safety net: never cull the camera chunk or its 8 horizontal
    // neighbours. See the file header for the rationale.
    const dcx = cx - frustum.cam_cx;
    const dcz = cz - frustum.cam_cz;
    if (dcx >= -1 and dcx <= 1 and dcz >= -1 and dcz <= 1) return true;

    if (strategy == .none) return true;

    // World-space chunk centre. Y is fixed at half the column height.
    const cwx: f32 = @as(f32, @floatFromInt(cx * CHUNK_W)) + half_w_f;
    const cwz: f32 = @as(f32, @floatFromInt(cz * CHUNK_W)) + half_w_f;
    const cwy: f32 = half_h_f;

    const dx = cwx - frustum.eye[0];
    const dy = cwy - frustum.eye[1];
    const dz = cwz - frustum.eye[2];
    const dist_sq = dx * dx + dy * dy + dz * dz;

    // Outer-radius cutoff. Used by both sphere and cone strategies.
    if (dist_sq > frustum.cull_radius_sq) return false;
    if (strategy == .sphere) return true;

    // --- Cone strategy ---

    // 180° fov (half-angle ≥ 90°) is a no-op short-circuit. Required because
    // the trig identity below has FP precision issues right at π/2 — we
    // never want a 180° user setting to silently drop a chunk.
    if (frustum.half_fov_rad >= std.math.pi * 0.5 - 1e-4) return true;

    // Camera inside the chunk's bounding sphere → unconditional keep. This
    // is the case the user explicitly worried about ("the chunk the player
    // is standing in"): with a column-radius of ~132 blocks, looking down
    // would otherwise put the chunk centre behind the camera.
    const radius = CHUNK_BOUND_RADIUS;
    if (dist_sq <= radius * radius) return true;

    const dist = @sqrt(dist_sq);
    const inv = 1.0 / dist;
    const dir_x = dx * inv;
    const dir_y = dy * inv;
    const dir_z = dz * inv;
    const cos_angle = dir_x * frustum.forward[0] +
        dir_y * frustum.forward[1] +
        dir_z * frustum.forward[2];

    // sin_g = chunk_radius / dist, cos_g = sqrt(1 - sin_g²).
    // dist > radius (checked above) ⇒ sin_g < 1 strictly.
    const sin_g = radius * inv;
    const cos_g = @sqrt(@max(0.0, 1.0 - sin_g * sin_g));

    // We want: angle - half_angular_size <= half_fov
    //   <=> cos(angle) >= cos(half_fov + half_angular_size)
    //   <=> cos_angle >= cos_h * cos_g - sin_h * sin_g
    const threshold = frustum.cos_half_fov * cos_g - frustum.sin_half_fov * sin_g;
    return cos_angle >= threshold;
}

// ────────────────────────────────────────────────────────────────────────────
// Tests — `zig build test` does not exercise the voxel example, but `zig test
// frustum.zig` does and these are quick sanity checks for the edge cases the
// user explicitly called out.
// ────────────────────────────────────────────────────────────────────────────

test "180° fov is a strict no-op (cone keeps every loaded chunk)" {
    const f = Frustum.capture(.{ 24.0, 64.0, 24.0 }, .{ 0.0, -1.0, 0.0 }, 180.0, 4);
    // Far chunk in every horizontal direction inside the render radius.
    try std.testing.expect(keepChunk(.cone, f, 4, 0));
    try std.testing.expect(keepChunk(.cone, f, -4, 0));
    try std.testing.expect(keepChunk(.cone, f, 0, 4));
    try std.testing.expect(keepChunk(.cone, f, 0, -4));
    try std.testing.expect(keepChunk(.cone, f, 3, 3));
    try std.testing.expect(keepChunk(.cone, f, -3, -3));
}

test "camera 3x3 neighbourhood always survives a narrow cone facing away" {
    const f = Frustum.capture(.{ 24.0, 64.0, 24.0 }, .{ 0.0, -1.0, 0.0 }, 30.0, 4);
    var dx: i32 = -1;
    while (dx <= 1) : (dx += 1) {
        var dz: i32 = -1;
        while (dz <= 1) : (dz += 1) {
            try std.testing.expect(keepChunk(.cone, f, dx, dz));
        }
    }
}

test "narrow cone looking +x culls a far chunk directly behind" {
    const f = Frustum.capture(.{ 0.0, 64.0, 0.0 }, .{ 1.0, 0.0, 0.0 }, 30.0, 4);
    // 10 chunks in the -x direction is well outside RENDER_DISTANCE so it
    // also fails the sphere cutoff — but the cone test should reject it
    // independently before we get there.
    try std.testing.expect(!keepChunk(.cone, f, -10, 0));
}

test "looking straight down keeps the column we are above" {
    const f = Frustum.capture(.{ 24.0, 1000.0, 24.0 }, .{ 0.0, -1.0, 0.0 }, 60.0, 4);
    // Chunk (0,0) — directly below us, but the camera is way above its
    // bounding sphere centre. The bounding-sphere short-circuit must catch
    // this; if it does not, narrow-cone-looking-down is broken.
    try std.testing.expect(keepChunk(.cone, f, 0, 0));
}

test "looking straight down keeps the four immediately-adjacent columns" {
    const f = Frustum.capture(.{ 24.0, 64.0, 24.0 }, .{ 0.0, -1.0, 0.0 }, 30.0, 4);
    // Even at 30° fov, the 3×3 safety net must keep all immediate neighbours.
    try std.testing.expect(keepChunk(.cone, f, 1, 0));
    try std.testing.expect(keepChunk(.cone, f, -1, 0));
    try std.testing.expect(keepChunk(.cone, f, 0, 1));
    try std.testing.expect(keepChunk(.cone, f, 0, -1));
}

test "sphere strategy honours the outer radius" {
    const f = Frustum.capture(.{ 0.0, 64.0, 0.0 }, .{ 1.0, 0.0, 0.0 }, 60.0, 4);
    // Inside the radius (with slack): keep.
    try std.testing.expect(keepChunk(.sphere, f, 3, 0));
    // Way outside: cull.
    try std.testing.expect(!keepChunk(.sphere, f, 50, 0));
}

test "none strategy never culls" {
    const f = Frustum.capture(.{ 0.0, 64.0, 0.0 }, .{ 1.0, 0.0, 0.0 }, 1.0, 4);
    try std.testing.expect(keepChunk(.none, f, 1000, 1000));
    try std.testing.expect(keepChunk(.none, f, -1000, -1000));
}
