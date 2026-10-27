const std = @import("std");
const Vec4 = @import("vec4.zig").Vec4;

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
        return .{ .data = @splat(0) };
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

    /// Matrix-vector multiplication: result = m * v (v is a column vector)
    pub fn mulVec4(m: Mat4, v: Vec4) Vec4 {
        return .{
            .x = m.get(0, 0) * v.x + m.get(0, 1) * v.y + m.get(0, 2) * v.z + m.get(0, 3) * v.w,
            .y = m.get(1, 0) * v.x + m.get(1, 1) * v.y + m.get(1, 2) * v.z + m.get(1, 3) * v.w,
            .z = m.get(2, 0) * v.x + m.get(2, 1) * v.y + m.get(2, 2) * v.z + m.get(2, 3) * v.w,
            .w = m.get(3, 0) * v.x + m.get(3, 1) * v.y + m.get(3, 2) * v.z + m.get(3, 3) * v.w,
        };
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

test "mat4 mulVec4" {
    const p = Vec4.init(1, 2, 3, 1);
    try std.testing.expectEqual(p, Mat4.identity().mulVec4(p));
    // A translation moves a point (w = 1) and does not move a direction (w = 0).
    const t = Mat4.translation(10, 20, 30);
    try std.testing.expectEqual(Vec4.init(11, 22, 33, 1), t.mulVec4(p));
    try std.testing.expectEqual(Vec4.init(1, 2, 3, 0), t.mulVec4(Vec4.init(1, 2, 3, 0)));
    // Rotate +x by 90 degrees around z: it gives +y.
    const r = Mat4.rotationZ(std.math.pi / 2.0).mulVec4(Vec4.init(1, 0, 0, 0));
    try std.testing.expectApproxEqAbs(@as(f32, 0), r.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), r.y, 0.0001);
}
