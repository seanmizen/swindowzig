//! Pixel projection for 2D drawing. The origin is the top left corner, x grows
//! right and y grows down. One unit is one logical pixel.
//!
//! A window reports its size in device pixels. The logical size is that size
//! divided by `dpi_scale`. Code draws in logical pixels, so a 100 px wide
//! rectangle covers 100 px on a 1x screen and 200 device pixels on a 2x screen.

/// A column-major 4x4 matrix, the layout WGSL `mat4x4<f32>` expects.
pub const Matrix = [16]f32;

pub const Size = struct { w: f32, h: f32 };

/// The logical size of a surface of `width` x `height` device pixels.
/// A `dpi_scale` that is not positive counts as 1.
pub fn logicalSize(width: u32, height: u32, dpi_scale: f32) Size {
    const scale = if (dpi_scale > 0) dpi_scale else 1.0;
    return .{
        .w = @as(f32, @floatFromInt(width)) / scale,
        .h = @as(f32, @floatFromInt(height)) / scale,
    };
}

/// Orthographic projection. (0, 0) maps to the top left of clip space
/// (-1, 1) and (width, height) maps to the bottom right (1, -1). Depth is 0.
pub fn ortho(width: f32, height: f32) Matrix {
    return .{
        2.0 / width, 0,             0, 0,
        0,           -2.0 / height, 0, 0,
        0,           0,             1, 0,
        -1,          1,             0, 1,
    };
}

/// Projection for a surface of `width` x `height` device pixels.
pub fn forSurface(width: u32, height: u32, dpi_scale: f32) Matrix {
    const size = logicalSize(width, height, dpi_scale);
    return ortho(size.w, size.h);
}

/// Transform the point (x, y) by `m`. Returns the clip space x and y.
pub fn apply(m: Matrix, x: f32, y: f32) [2]f32 {
    return .{
        m[0] * x + m[4] * y + m[12],
        m[1] * x + m[5] * y + m[13],
    };
}

const std = @import("std");
const expectApproxEqAbs = std.testing.expectApproxEqAbs;

test "ortho maps the corners of the surface to clip space" {
    const m = ortho(800, 600);
    const top_left = apply(m, 0, 0);
    try expectApproxEqAbs(@as(f32, -1), top_left[0], 1e-6);
    try expectApproxEqAbs(@as(f32, 1), top_left[1], 1e-6);
    const bottom_right = apply(m, 800, 600);
    try expectApproxEqAbs(@as(f32, 1), bottom_right[0], 1e-6);
    try expectApproxEqAbs(@as(f32, -1), bottom_right[1], 1e-6);
    const centre = apply(m, 400, 300);
    try expectApproxEqAbs(@as(f32, 0), centre[0], 1e-6);
    try expectApproxEqAbs(@as(f32, 0), centre[1], 1e-6);
}

test "ortho y grows down" {
    const m = ortho(100, 100);
    const upper = apply(m, 10, 10);
    const lower = apply(m, 10, 90);
    try std.testing.expect(upper[1] > lower[1]);
}

test "logicalSize divides device pixels by dpi_scale" {
    const s = logicalSize(1600, 1200, 2.0);
    try expectApproxEqAbs(@as(f32, 800), s.w, 1e-6);
    try expectApproxEqAbs(@as(f32, 600), s.h, 1e-6);
}

test "logicalSize treats a bad dpi_scale as 1" {
    try expectApproxEqAbs(@as(f32, 640), logicalSize(640, 480, 0).w, 1e-6);
    try expectApproxEqAbs(@as(f32, 640), logicalSize(640, 480, -2).w, 1e-6);
}

test "the same logical point lands on the same clip point at any dpi_scale" {
    const at_1x = forSurface(800, 600, 1.0);
    const at_2x = forSurface(1600, 1200, 2.0);
    const a = apply(at_1x, 200, 150);
    const b = apply(at_2x, 200, 150);
    try expectApproxEqAbs(a[0], b[0], 1e-6);
    try expectApproxEqAbs(a[1], b[1], 1e-6);
}

test "the logical size, not the device size, sets the scale" {
    // 100 logical pixels cover a quarter of a 400 logical pixel wide surface,
    // so x = 100 maps to -0.5 whatever the device size is.
    const m = forSurface(800, 800, 2.0);
    try expectApproxEqAbs(@as(f32, -0.5), apply(m, 100, 0)[0], 1e-6);
}
