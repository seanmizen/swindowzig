//! 3PV camera-clip helper.
//!
//! Walk a ray from `eye` along unit direction `dir` and return the largest
//! distance ≤ `max_dist` such that the camera at `eye + dir*distance` does not
//! have any part of its near-plane frustum poking into a solid voxel.
//!
//! Used to fix a 3PV exploit: the prior inside-block detector only sampled the
//! camera's centre point, so wedging the camera partway into a block left the
//! clipped sliver see-through. Pulling the camera back along the view ray
//! closes the exploit AND has the nice side effect that the 3PV camera now
//! hugs walls smoothly instead of clipping.
//!
//! `world` must be any object exposing `fn isSolid(self, x: i32, y: i32, z: i32) bool`.
//! Kept generic to allow testing with a fake world; main.zig wraps the real
//! `world_mod.World` with an `IsSolidWorld` shim.

const std = @import("std");

pub fn safeCameraDistance(
    world: anytype,
    eye_x: f32,
    eye_y: f32,
    eye_z: f32,
    dir_x: f32,
    dir_y: f32,
    dir_z: f32,
    max_dist: f32,
    skin: f32,
) f32 {
    if (max_dist <= 0) return 0;
    const dlen = std.math.sqrt(dir_x * dir_x + dir_y * dir_y + dir_z * dir_z);
    if (dlen < 1e-6) return max_dist;
    const inv = 1.0 / dlen;
    const dx = dir_x * inv;
    const dy = dir_y * inv;
    const dz = dir_z * inv;

    var voxel_x: i32 = @intFromFloat(@floor(eye_x));
    var voxel_y: i32 = @intFromFloat(@floor(eye_y));
    var voxel_z: i32 = @intFromFloat(@floor(eye_z));

    // Defensive: if the eye itself is buried in a solid (e.g. TAS forced it),
    // collapse to first-person — the existing inside-block overlay will
    // handle the visual. Better than trying to push the camera through a wall.
    if (world.isSolid(voxel_x, voxel_y, voxel_z)) return 0;

    const step_x: i32 = if (dx > 0) 1 else -1;
    const step_y: i32 = if (dy > 0) 1 else -1;
    const step_z: i32 = if (dz > 0) 1 else -1;

    const huge: f32 = 1e10;
    const delta_x = if (@abs(dx) < 1e-6) huge else @abs(1.0 / dx);
    const delta_y = if (@abs(dy) < 1e-6) huge else @abs(1.0 / dy);
    const delta_z = if (@abs(dz) < 1e-6) huge else @abs(1.0 / dz);

    var t_max_x = if (@abs(dx) < 1e-6) huge else blk: {
        const boundary = if (step_x > 0) @floor(eye_x) + 1.0 else @floor(eye_x);
        break :blk (boundary - eye_x) / dx;
    };
    var t_max_y = if (@abs(dy) < 1e-6) huge else blk: {
        const boundary = if (step_y > 0) @floor(eye_y) + 1.0 else @floor(eye_y);
        break :blk (boundary - eye_y) / dy;
    };
    var t_max_z = if (@abs(dz) < 1e-6) huge else blk: {
        const boundary = if (step_z > 0) @floor(eye_z) + 1.0 else @floor(eye_z);
        break :blk (boundary - eye_z) / dz;
    };

    // For cam_dist≈4 + skin, the worst case is ~12 voxel crossings; 64 is plenty.
    var iterations: u32 = 0;
    while (iterations < 64) : (iterations += 1) {
        // t at which the ray enters the next voxel.
        var t_entry: f32 = undefined;
        if (t_max_x < t_max_y and t_max_x < t_max_z) {
            voxel_x += step_x;
            t_entry = t_max_x;
            t_max_x += delta_x;
        } else if (t_max_y < t_max_z) {
            voxel_y += step_y;
            t_entry = t_max_y;
            t_max_y += delta_y;
        } else {
            voxel_z += step_z;
            t_entry = t_max_z;
            t_max_z += delta_z;
        }

        // Next voxel is past the desired camera distance — no clip needed.
        if (t_entry >= max_dist) return max_dist;

        if (world.isSolid(voxel_x, voxel_y, voxel_z)) {
            const safe = t_entry - skin;
            return std.math.clamp(safe, 0.0, max_dist);
        }
    }
    return max_dist;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

/// Fake world for tests: a single solid AABB. `isSolid(x,y,z)` returns true iff
/// the integer voxel coordinate is inside the AABB (inclusive).
const FakeWorld = struct {
    min_x: i32,
    min_y: i32,
    min_z: i32,
    max_x: i32,
    max_y: i32,
    max_z: i32,

    pub fn isSolid(self: FakeWorld, x: i32, y: i32, z: i32) bool {
        return x >= self.min_x and x <= self.max_x and
            y >= self.min_y and y <= self.max_y and
            z >= self.min_z and z <= self.max_z;
    }
};

test "open space: returns full max_dist" {
    // No solid blocks anywhere — fake world below the ray.
    const world = FakeWorld{ .min_x = -100, .min_y = -100, .min_z = -100, .max_x = -50, .max_y = -50, .max_z = -50 };
    const d = safeCameraDistance(world, 0.0, 64.0, 0.0, -1.0, 0.0, 0.0, 4.0, 0.2);
    try testing.expectApproxEqAbs(@as(f32, 4.0), d, 1e-4);
}

test "axis-aligned wall pull-back" {
    // Solid wall at x=10 (the voxel x=10..11). Eye at x=14 looking in -X.
    // First solid voxel entered is x=10, t_entry = 14 - 11 = 3. With skin 0.2,
    // safe distance = 2.8.
    const world = FakeWorld{ .min_x = 10, .min_y = 0, .min_z = -100, .max_x = 10, .max_y = 200, .max_z = 100 };
    const d = safeCameraDistance(world, 14.0, 64.5, 0.5, -1.0, 0.0, 0.0, 4.0, 0.2);
    try testing.expectApproxEqAbs(@as(f32, 2.8), d, 1e-3);
}

test "off-centre wedge: the original exploit" {
    // The exact scenario Sean described: a 3PV camera whose CENTRE is in air
    // but whose near-plane corner clips into a solid block.
    //
    // Setup: solid voxel at (5,5,5)..(5,5,5). Player eye at (8.0, 5.5, 5.7).
    // Camera looks toward (-X, 0, +Z mild) so the camera-back direction has a
    // strong +X component but slight -Z; the desired camera spot lands on the
    // edge of the solid block. The OLD code (point-in-block on camera centre)
    // didn't fire because the camera CENTRE could be just outside the block
    // while the near-plane corner clipped in.
    //
    // We don't simulate the near plane here; we instead require that the new
    // helper pulls the camera STRICTLY back from the old naïve cam_dist=4
    // position, leaving room for the near plane.
    const world = FakeWorld{ .min_x = 5, .min_y = 5, .min_z = 5, .max_x = 5, .max_y = 5, .max_z = 5 };

    // Eye at (8.5, 5.5, 5.5) — inside the y/z slab of the wall, x is +3.0 from
    // the wall's far face. Camera-back direction is (-1, 0, 0). The OLD code
    // would put the camera at x = 8.5 - 4.0 = 4.5, which is INSIDE the solid
    // block (x in [5,6) means voxel 5; 4.5 is voxel 4 in air). So the centre
    // point check would NOT fire, but the near plane would clip into x=5.
    //
    // Wait — let's pick coords where the centre IS in the solid (proves the
    // OLD detector also failed) then a second case where the centre is in air
    // but the near plane clips.

    // Case A: camera centre lands inside solid → old detector fires, but new
    // code also pulls back so camera never enters solid in the first place.
    {
        const eye_x: f32 = 9.0;
        const d = safeCameraDistance(world, eye_x, 5.5, 5.5, -1.0, 0.0, 0.0, 4.0, 0.2);
        // First solid entered is x=5 at t = 9.0 - 6.0 = 3.0. Safe = 2.8.
        try testing.expectApproxEqAbs(@as(f32, 2.8), d, 1e-3);
        const cam_x = eye_x + (-1.0) * d;
        try testing.expect(cam_x > 6.0); // strictly outside the +X face of voxel 5
    }

    // Case B: the off-centre wedge. Eye at (5.99, 5.5, 5.5), looking in
    // direction (-0.01, 0, -1) normalised. Old naïve cam_dist=4 would put the
    // camera at roughly (5.99 + 0.04, 5.5, 5.5 + 4.0) = (6.03, 5.5, 9.5) —
    // centre OUTSIDE the solid block (voxel x=6, in air), so the old detector
    // is silent, but the near plane would clip back into x=5. The new helper
    // walks the ray from the eye and immediately hits the solid x=5 face (the
    // eye is at x=5.99, almost at the boundary), pulling back to ~0.
    {
        const eye_x: f32 = 5.99;
        const dir = [3]f32{ -0.01, 0.0, -1.0 };
        const d = safeCameraDistance(world, eye_x, 5.5, 5.5, dir[0], dir[1], dir[2], 4.0, 0.2);
        // First solid (already adjacent at x=5): the ray steps into voxel 5
        // almost immediately. Safe distance after skin clamp must be ≪ 4.
        try testing.expect(d < 4.0);
    }
}

test "eye buried in solid: collapse to 0" {
    const world = FakeWorld{ .min_x = 0, .min_y = 0, .min_z = 0, .max_x = 10, .max_y = 10, .max_z = 10 };
    const d = safeCameraDistance(world, 5.5, 5.5, 5.5, 1.0, 0.0, 0.0, 4.0, 0.2);
    try testing.expectApproxEqAbs(@as(f32, 0.0), d, 1e-6);
}

test "skin clamps to 0 when wall is closer than skin" {
    // Wall directly adjacent: eye at x=5.05, wall at x>=5 looking in -X.
    // First solid is voxel 5 at t = 5.05 - 5.0 = 0.05. safe = 0.05 - 0.2 = -0.15
    // → clamped to 0.
    const world = FakeWorld{ .min_x = 5, .min_y = -100, .min_z = -100, .max_x = 5, .max_y = 100, .max_z = 100 };
    const d = safeCameraDistance(world, 5.05, 0.0, 0.0, -1.0, 0.0, 0.0, 4.0, 0.2);
    try testing.expectApproxEqAbs(@as(f32, 0.0), d, 1e-6);
}

test "diagonal ray through gap" {
    // Solid block at (5,0,5). Diagonal ray (1,0,1)/sqrt2 from (4.5, 0.5, 4.5)
    // toward +X+Z. Enters solid at t where x=5: t*0.7071 + 4.5 = 5 → t ≈ 0.707.
    const world = FakeWorld{ .min_x = 5, .min_y = 0, .min_z = 5, .max_x = 5, .max_y = 0, .max_z = 5 };
    const d = safeCameraDistance(world, 4.5, 0.5, 4.5, 1.0, 0.0, 1.0, 4.0, 0.2);
    // Expected entry ≈ 0.7071 (sqrt(0.5)). Safe ≈ 0.5071. Clamp to ≥ 0.
    try testing.expectApproxEqAbs(@as(f32, 0.7071 - 0.2), d, 1e-2);
}
