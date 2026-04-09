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
