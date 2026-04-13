const std = @import("std");

/// World generation presets. The active preset is selected by ACTIVE_PRESET.
/// Runtime/file-based selection (ZON config) will be added later.
pub const Preset = enum {
    flatland,
    hilly,
};

/// Hardcoded active preset. Change this const to switch presets.
pub const ACTIVE_PRESET: Preset = .hilly;

/// All parameters that control terrain generation.
/// Designed to map 1-to-1 with a future ZON config file:
///
///   .{
///       .preset = "hilly",
///       // all other fields are optional — override preset defaults
///   }
///
/// A .preset field selects the base defaults; any other fields override them.
pub const WorldGenConfig = struct {
    preset: Preset,
    /// Y level considered "sea level" — reference for biome/spawn logic.
    sea_level: i32,
    /// Minimum terrain surface Y (noise = 0).
    terrain_height_min: i32,
    /// Maximum terrain surface Y (noise = 1).
    terrain_height_max: i32,
    /// Base sampling frequency (lower = larger terrain features).
    noise_scale: f32,
    /// Number of noise octaves layered together. 0 = flat at terrain_height_min.
    noise_octaves: u32,
    /// Amplitude multiplier per octave (0..1 — higher = rougher high-freq detail).
    noise_persistence: f32,
    /// Frequency multiplier per octave (>1 — higher = finer detail).
    noise_lacunarity: f32,
};

/// Return the default WorldGenConfig for a preset.
pub fn presetConfig(preset: Preset) WorldGenConfig {
    return switch (preset) {
        .flatland => .{
            .preset = .flatland,
            .sea_level = 63,
            .terrain_height_min = 63,
            .terrain_height_max = 63,
            .noise_scale = 0.02,
            .noise_octaves = 0,
            .noise_persistence = 0.5,
            .noise_lacunarity = 2.0,
        },
        .hilly => .{
            .preset = .hilly,
            .sea_level = 63,
            .terrain_height_min = 55,
            .terrain_height_max = 85,
            .noise_scale = 0.025,
            .noise_octaves = 4,
            .noise_persistence = 0.5,
            .noise_lacunarity = 2.0,
        },
    };
}

// ---------------------------------------------------------------------------
// Value noise implementation
// ---------------------------------------------------------------------------

/// Integer hash — splitmix-style mixing for good avalanche.
fn hashU32(x: u32) u32 {
    var h = x;
    h ^= h >> 16;
    h *%= 0x45d9f3b;
    h ^= h >> 16;
    return h;
}

/// Hash a 2D integer grid point to a pseudo-random float in [0, 1].
fn hash2D(ix: i32, iz: i32) f32 {
    const ux: u32 = @bitCast(ix);
    const uz: u32 = @bitCast(iz);
    const h = hashU32(ux ^ hashU32(uz ^ 0xdeadbeef));
    return @as(f32, @floatFromInt(h)) / @as(f32, @floatFromInt(std.math.maxInt(u32)));
}

/// Bilinear value noise in [0, 1]. Smoothstep interpolation between grid corners.
fn valueNoise2D(x: f32, z: f32) f32 {
    const ix: i32 = @intFromFloat(@floor(x));
    const iz: i32 = @intFromFloat(@floor(z));
    const fx = x - @as(f32, @floatFromInt(ix));
    const fz = z - @as(f32, @floatFromInt(iz));

    // Smoothstep: 3t² − 2t³
    const ux = fx * fx * (3.0 - 2.0 * fx);
    const uz = fz * fz * (3.0 - 2.0 * fz);

    const v00 = hash2D(ix, iz);
    const v10 = hash2D(ix + 1, iz);
    const v01 = hash2D(ix, iz + 1);
    const v11 = hash2D(ix + 1, iz + 1);

    return std.math.lerp(
        std.math.lerp(v00, v10, ux),
        std.math.lerp(v01, v11, ux),
        uz,
    );
}

/// Hash a 3D integer grid point to a pseudo-random float in [0, 1].
fn hash3D(ix: i32, iy: i32, iz: i32) f32 {
    const ux: u32 = @bitCast(ix);
    const uy: u32 = @bitCast(iy);
    const uz: u32 = @bitCast(iz);
    const h = hashU32(ux ^ hashU32(uy ^ hashU32(uz ^ 0xdeadbeef)));
    return @as(f32, @floatFromInt(h)) / @as(f32, @floatFromInt(std.math.maxInt(u32)));
}

/// Trilinear value noise in [0, 1]. Smoothstep interpolation between 8 grid corners.
fn valueNoise3D(x: f32, y: f32, z: f32) f32 {
    const ix: i32 = @intFromFloat(@floor(x));
    const iy: i32 = @intFromFloat(@floor(y));
    const iz: i32 = @intFromFloat(@floor(z));
    const fx = x - @as(f32, @floatFromInt(ix));
    const fy = y - @as(f32, @floatFromInt(iy));
    const fz = z - @as(f32, @floatFromInt(iz));

    // Smoothstep: 3t² − 2t³
    const ux = fx * fx * (3.0 - 2.0 * fx);
    const uy = fy * fy * (3.0 - 2.0 * fy);
    const uz = fz * fz * (3.0 - 2.0 * fz);

    const v000 = hash3D(ix, iy, iz);
    const v100 = hash3D(ix + 1, iy, iz);
    const v010 = hash3D(ix, iy + 1, iz);
    const v110 = hash3D(ix + 1, iy + 1, iz);
    const v001 = hash3D(ix, iy, iz + 1);
    const v101 = hash3D(ix + 1, iy, iz + 1);
    const v011 = hash3D(ix, iy + 1, iz + 1);
    const v111 = hash3D(ix + 1, iy + 1, iz + 1);

    const x00 = std.math.lerp(v000, v100, ux);
    const x10 = std.math.lerp(v010, v110, ux);
    const x01 = std.math.lerp(v001, v101, ux);
    const x11 = std.math.lerp(v011, v111, ux);

    const y0 = std.math.lerp(x00, x10, uy);
    const y1 = std.math.lerp(x01, x11, uy);

    return std.math.lerp(y0, y1, uz);
}

// ---------------------------------------------------------------------------
// Cave carver
// ---------------------------------------------------------------------------

/// Returns true if the block at world position (wx, wy, wz) should be carved
/// to form a cave. Uses two independent 3D noise fields: where both are near
/// their midpoint (0.5), the isosurface intersection forms worm-like tunnels.
///
/// Coverage: approximately 2–3% of underground volume, producing a network of
/// connected passages with occasional wider caverns where the two fields overlap.
/// The Y axis is stretched by 0.6 to make passages taller than wide.
pub fn shouldCarve(wx: i32, wy: i32, wz: i32) bool {
    const fwx = @as(f32, @floatFromInt(wx));
    const fwy = @as(f32, @floatFromInt(wy));
    const fwz = @as(f32, @floatFromInt(wz));

    // Two noise fields at the same scale but offset so they're independent.
    // Y is scaled at 0.6× to create taller-than-wide passage cross-sections.
    const n1 = valueNoise3D(fwx * 0.016, fwy * 0.010, fwz * 0.016);
    const n2 = valueNoise3D(fwx * 0.016 + 47.3, fwy * 0.010 + 91.7, fwz * 0.016 + 23.1);

    // Carve where both noise values are near 0.5.
    // c1*c1 + c2*c2 < threshold defines a circle in (c1,c2) space;
    // threshold = 0.008 → approx 2.5% probability (area = π×r² / 1.0).
    const c1 = n1 - 0.5;
    const c2 = n2 - 0.5;
    return c1 * c1 + c2 * c2 < 0.008;
}

// ---------------------------------------------------------------------------
// Tree placement
// ---------------------------------------------------------------------------

/// Tree spacing for the local-maximum filter (Manhattan radius in blocks).
const TREE_SPACING: i32 = 3;

/// Density threshold: only columns whose tree priority exceeds this value are
/// candidates. Controls how many positions survive to the local-max check.
const TREE_DENSITY_THRESHOLD: f32 = 0.75;

/// Hash a world (wx, wz) column to a priority in [0, 1] for tree placement.
/// Uses different constants than hash2D to avoid correlation with the terrain.
fn treeHashFloat(wx: i32, wz: i32) f32 {
    const ux: u32 = @bitCast(wx);
    const uz: u32 = @bitCast(wz);
    const h = hashU32(ux *% 374761393 ^ hashU32(uz *% 668265263 ^ 0xcafebabe));
    return @as(f32, @floatFromInt(h)) / @as(f32, @floatFromInt(std.math.maxInt(u32)));
}

/// Returns true if a tree trunk should be centred at world column (wx, wz).
/// The local-maximum filter guarantees trees are at least TREE_SPACING blocks
/// apart — callers do not need to check neighbours themselves.
pub fn isTreeCenter(wx: i32, wz: i32) bool {
    const priority = treeHashFloat(wx, wz);
    if (priority < TREE_DENSITY_THRESHOLD) return false;

    // Must be the strict local maximum within TREE_SPACING radius.
    var dx: i32 = -TREE_SPACING;
    while (dx <= TREE_SPACING) : (dx += 1) {
        var dz: i32 = -TREE_SPACING;
        while (dz <= TREE_SPACING) : (dz += 1) {
            if (dx == 0 and dz == 0) continue;
            if (dx * dx + dz * dz > TREE_SPACING * TREE_SPACING) continue;
            if (treeHashFloat(wx + dx, wz + dz) >= priority) return false;
        }
    }
    return true;
}

/// Returns the trunk height (number of wood blocks above the surface) for the
/// tree centred at (wx, wz). Range: 4–7 blocks.
pub fn treeHeight(wx: i32, wz: i32) i32 {
    // XOR with constants to get a different distribution than treeHashFloat.
    const h = treeHashFloat(wx ^ 0x12345, wz ^ 0x54321);
    return 4 + @as(i32, @intFromFloat(h * 4.0));
}

/// Sample terrain surface height (Y block coordinate) at world-space (wx, wz).
/// Returns a value in [terrain_height_min, terrain_height_max].
/// When noise_octaves = 0, returns terrain_height_min (flat terrain).
pub fn sampleHeight(wx: i32, wz: i32, config: WorldGenConfig) i32 {
    if (config.noise_octaves == 0) return config.terrain_height_min;

    var amplitude: f32 = 1.0;
    var frequency: f32 = config.noise_scale;
    var total: f32 = 0.0;
    var max_value: f32 = 0.0;

    for (0..config.noise_octaves) |_| {
        const nx = @as(f32, @floatFromInt(wx)) * frequency;
        const nz = @as(f32, @floatFromInt(wz)) * frequency;
        total += valueNoise2D(nx, nz) * amplitude;
        max_value += amplitude;
        amplitude *= config.noise_persistence;
        frequency *= config.noise_lacunarity;
    }

    const normalized = total / max_value; // [0, 1]
    const height_range = config.terrain_height_max - config.terrain_height_min;
    return config.terrain_height_min + @as(i32, @intFromFloat(normalized * @as(f32, @floatFromInt(height_range))));
}
