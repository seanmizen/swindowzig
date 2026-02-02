const std = @import("std");

/// 4x4 matrix in column-major order (WebGPU/OpenGL convention)
/// Memory layout: [col0_x, col0_y, col0_z, col0_w, col1_x, col1_y, ...]
pub const Mat4 = struct {
    data: [16]f32,

    pub fn identity() Mat4 {
        return .{ .data = [_]f32{
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        } };
    }

    pub fn zero() Mat4 {
        return .{ .data = [_]f32{0} ** 16 };
    }

    /// Get element at row i, column j
    pub fn get(self: *const Mat4, row: usize, col: usize) f32 {
        return self.data[col * 4 + row];
    }

    /// Set element at row i, column j
    pub fn set(self: *Mat4, row: usize, col: usize, value: f32) void {
        self.data[col * 4 + row] = value;
    }

    /// Matrix multiplication: result = a * b
    pub fn mul(a: Mat4, b: Mat4) Mat4 {
        var result = Mat4.zero();
        var row: usize = 0;
        while (row < 4) : (row += 1) {
            var col: usize = 0;
            while (col < 4) : (col += 1) {
                var sum: f32 = 0;
                var k: usize = 0;
                while (k < 4) : (k += 1) {
                    sum += a.get(row, k) * b.get(k, col);
                }
                result.set(row, col, sum);
            }
        }
        return result;
    }

    /// Transpose matrix
    pub fn transpose(self: Mat4) Mat4 {
        var result = Mat4.zero();
        var row: usize = 0;
        while (row < 4) : (row += 1) {
            var col: usize = 0;
            while (col < 4) : (col += 1) {
                result.set(col, row, self.get(row, col));
            }
        }
        return result;
    }

    /// Create translation matrix
    pub fn translation(x: f32, y: f32, z: f32) Mat4 {
        return .{ .data = [_]f32{
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            x, y, z, 1,
        } };
    }

    /// Create uniform scale matrix
    pub fn scaling(s: f32) Mat4 {
        return .{ .data = [_]f32{
            s, 0, 0, 0,
            0, s, 0, 0,
            0, 0, s, 0,
            0, 0, 0, 1,
        } };
    }

    /// Create rotation matrix around X axis (angle in radians)
    pub fn rotationX(angle: f32) Mat4 {
        const c = @cos(angle);
        const s = @sin(angle);
        return .{ .data = [_]f32{
            1, 0,  0, 0,
            0, c,  s, 0,
            0, -s, c, 0,
            0, 0,  0, 1,
        } };
    }

    /// Create rotation matrix around Y axis (angle in radians)
    pub fn rotationY(angle: f32) Mat4 {
        const c = @cos(angle);
        const s = @sin(angle);
        return .{ .data = [_]f32{
            c, 0, -s, 0,
            0, 1, 0,  0,
            s, 0, c,  0,
            0, 0, 0,  1,
        } };
    }

    /// Create rotation matrix around Z axis (angle in radians)
    pub fn rotationZ(angle: f32) Mat4 {
        const c = @cos(angle);
        const s = @sin(angle);
        return .{ .data = [_]f32{
            c,  s, 0, 0,
            -s, c, 0, 0,
            0,  0, 1, 0,
            0,  0, 0, 1,
        } };
    }
};

test "mat4 identity" {
    const m = Mat4.identity();
    try std.testing.expectEqual(@as(f32, 1), m.get(0, 0));
    try std.testing.expectEqual(@as(f32, 1), m.get(1, 1));
    try std.testing.expectEqual(@as(f32, 1), m.get(2, 2));
    try std.testing.expectEqual(@as(f32, 1), m.get(3, 3));
    try std.testing.expectEqual(@as(f32, 0), m.get(0, 1));
}

test "mat4 multiplication" {
    const a = Mat4.identity();
    const b = Mat4.identity();
    const c = a.mul(b);

    // Identity * Identity = Identity
    try std.testing.expectEqual(@as(f32, 1), c.get(0, 0));
    try std.testing.expectEqual(@as(f32, 1), c.get(1, 1));
    try std.testing.expectEqual(@as(f32, 1), c.get(2, 2));
    try std.testing.expectEqual(@as(f32, 1), c.get(3, 3));
    try std.testing.expectEqual(@as(f32, 0), c.get(0, 1));
}

test "mat4 transpose" {
    var m = Mat4.identity();
    m.set(0, 1, 5);
    const t = m.transpose();
    try std.testing.expectEqual(@as(f32, 5), t.get(1, 0));
    try std.testing.expectEqual(@as(f32, 0), t.get(0, 1));
}
