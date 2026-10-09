//! CPU side of the 2D renderer. Shapes become triangles in a vertex list and
//! an index list. Neighbouring shapes that use the same texture share one draw
//! call, so there is one draw call for each texture change and not one for
//! each quad. This file has no GPU code.

const std = @import("std");

/// Straight (not premultiplied) RGBA, each channel 0..1.
pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32 = 1.0,

    pub const white: Color = .{ .r = 1, .g = 1, .b = 1 };

    pub fn rgba8(r: u8, g: u8, b: u8, a: u8) Color {
        return .{
            .r = @as(f32, @floatFromInt(r)) / 255.0,
            .g = @as(f32, @floatFromInt(g)) / 255.0,
            .b = @as(f32, @floatFromInt(b)) / 255.0,
            .a = @as(f32, @floatFromInt(a)) / 255.0,
        };
    }
};

/// A rectangle in logical pixels. (x, y) is the top left corner.
pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

/// A texture handle from `Renderer.createTexture`. Id 0 is the built-in white
/// texture that solid shapes use.
pub const Texture = struct {
    id: u32,
    width: u32,
    height: u32,
};

pub const white_texture: Texture = .{ .id = 0, .width = 1, .height = 1 };

/// One vertex. The layout matches the vertex buffer description in
/// renderer.zig and the WGSL shader.
pub const Vertex = extern struct {
    pos: [2]f32,
    uv: [2]f32,
    color: [4]f32,
};

/// One indexed draw: `index_count` indices from `first_index`, all with the
/// same texture.
pub const DrawCall = struct {
    texture: u32,
    first_index: u32,
    index_count: u32,
};

pub const Batch = struct {
    vertices: std.ArrayList(Vertex) = .empty,
    indices: std.ArrayList(u32) = .empty,
    calls: std.ArrayList(DrawCall) = .empty,

    pub fn deinit(self: *Batch, alloc: std.mem.Allocator) void {
        self.vertices.deinit(alloc);
        self.indices.deinit(alloc);
        self.calls.deinit(alloc);
        self.* = .{};
    }

    /// Drop all shapes. Keep the memory for the next frame.
    pub fn reset(self: *Batch) void {
        self.vertices.clearRetainingCapacity();
        self.indices.clearRetainingCapacity();
        self.calls.clearRetainingCapacity();
    }

    /// A filled rectangle.
    pub fn fillRect(self: *Batch, alloc: std.mem.Allocator, rect: Rect, color: Color) !void {
        try self.pushQuad(alloc, 0, rect, .{ 0, 0 }, .{ 0, 0 }, color);
    }

    /// A rectangle outline. The line is `line_width` wide and lies inside
    /// `rect`. The four sides do not overlap, so a translucent outline has an
    /// even colour. A line wide enough to fill the rectangle gives a filled
    /// rectangle. A line width of 0 or less draws nothing.
    pub fn strokeRect(
        self: *Batch,
        alloc: std.mem.Allocator,
        rect: Rect,
        line_width: f32,
        color: Color,
    ) !void {
        if (line_width <= 0 or rect.w <= 0 or rect.h <= 0) return;
        const lw = line_width;
        if (lw * 2 >= rect.w or lw * 2 >= rect.h) {
            return self.fillRect(alloc, rect, color);
        }
        const inner_h = rect.h - 2 * lw;
        try self.fillRect(alloc, .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = lw }, color);
        try self.fillRect(alloc, .{ .x = rect.x, .y = rect.y + rect.h - lw, .w = rect.w, .h = lw }, color);
        try self.fillRect(alloc, .{ .x = rect.x, .y = rect.y + lw, .w = lw, .h = inner_h }, color);
        try self.fillRect(alloc, .{ .x = rect.x + rect.w - lw, .y = rect.y + lw, .w = lw, .h = inner_h }, color);
    }

    /// A textured quad. `src` is the part of the texture to draw, in texels.
    /// Null draws the whole texture. `tint` multiplies the texel colour. A
    /// negative `src.w` or `src.h` flips the image.
    pub fn drawTexture(
        self: *Batch,
        alloc: std.mem.Allocator,
        texture: Texture,
        dst: Rect,
        src: ?Rect,
        tint: Color,
    ) !void {
        const tw: f32 = @floatFromInt(@max(texture.width, 1));
        const th: f32 = @floatFromInt(@max(texture.height, 1));
        const s = src orelse Rect{ .x = 0, .y = 0, .w = tw, .h = th };
        try self.pushQuad(
            alloc,
            texture.id,
            dst,
            .{ s.x / tw, s.y / th },
            .{ (s.x + s.w) / tw, (s.y + s.h) / th },
            tint,
        );
    }

    /// Number of quads in the batch.
    pub fn quadCount(self: *const Batch) usize {
        return self.indices.items.len / 6;
    }

    fn pushQuad(
        self: *Batch,
        alloc: std.mem.Allocator,
        texture: u32,
        r: Rect,
        uv0: [2]f32,
        uv1: [2]f32,
        c: Color,
    ) !void {
        const color = [4]f32{ c.r, c.g, c.b, c.a };
        const base: u32 = @intCast(self.vertices.items.len);
        const first_index: u32 = @intCast(self.indices.items.len);

        try self.vertices.appendSlice(alloc, &[4]Vertex{
            .{ .pos = .{ r.x, r.y }, .uv = .{ uv0[0], uv0[1] }, .color = color },
            .{ .pos = .{ r.x + r.w, r.y }, .uv = .{ uv1[0], uv0[1] }, .color = color },
            .{ .pos = .{ r.x + r.w, r.y + r.h }, .uv = .{ uv1[0], uv1[1] }, .color = color },
            .{ .pos = .{ r.x, r.y + r.h }, .uv = .{ uv0[0], uv1[1] }, .color = color },
        });
        try self.indices.appendSlice(alloc, &[6]u32{ base, base + 1, base + 2, base, base + 2, base + 3 });

        if (self.calls.items.len > 0) {
            const last = &self.calls.items[self.calls.items.len - 1];
            if (last.texture == texture) {
                last.index_count += 6;
                return;
            }
        }
        try self.calls.append(alloc, .{ .texture = texture, .first_index = first_index, .index_count = 6 });
    }
};

const testing = std.testing;

test "fillRect makes one quad with the corners in order" {
    var b: Batch = .{};
    defer b.deinit(testing.allocator);
    try b.fillRect(testing.allocator, .{ .x = 10, .y = 20, .w = 30, .h = 40 }, .{ .r = 1, .g = 0, .b = 0 });

    try testing.expectEqual(@as(usize, 4), b.vertices.items.len);
    try testing.expectEqual(@as(usize, 6), b.indices.items.len);
    try testing.expectEqual([2]f32{ 10, 20 }, b.vertices.items[0].pos);
    try testing.expectEqual([2]f32{ 40, 20 }, b.vertices.items[1].pos);
    try testing.expectEqual([2]f32{ 40, 60 }, b.vertices.items[2].pos);
    try testing.expectEqual([2]f32{ 10, 60 }, b.vertices.items[3].pos);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 0, 2, 3 }, b.indices.items);
    try testing.expectEqual([4]f32{ 1, 0, 0, 1 }, b.vertices.items[0].color);
}

test "the second quad indexes its own vertices" {
    var b: Batch = .{};
    defer b.deinit(testing.allocator);
    try b.fillRect(testing.allocator, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, Color.white);
    try b.fillRect(testing.allocator, .{ .x = 5, .y = 5, .w = 1, .h = 1 }, Color.white);
    try testing.expectEqualSlices(u32, &.{ 4, 5, 6, 4, 6, 7 }, b.indices.items[6..12]);
}

test "solid shapes in a row make one draw call" {
    var b: Batch = .{};
    defer b.deinit(testing.allocator);
    const r: Rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 };
    try b.fillRect(testing.allocator, r, Color.white);
    try b.fillRect(testing.allocator, r, Color.white);
    try b.strokeRect(testing.allocator, r, 2, Color.white);

    try testing.expectEqual(@as(usize, 1), b.calls.items.len);
    try testing.expectEqual(@as(u32, 0), b.calls.items[0].texture);
    try testing.expectEqual(@as(u32, 0), b.calls.items[0].first_index);
    try testing.expectEqual(@as(u32, 36), b.calls.items[0].index_count);
}

test "a draw call starts at each texture change" {
    var b: Batch = .{};
    defer b.deinit(testing.allocator);
    const r: Rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const a: Texture = .{ .id = 1, .width = 8, .height = 8 };
    const c: Texture = .{ .id = 2, .width = 8, .height = 8 };

    try b.fillRect(testing.allocator, r, Color.white);
    try b.drawTexture(testing.allocator, a, r, null, Color.white);
    try b.drawTexture(testing.allocator, a, r, null, Color.white);
    try b.drawTexture(testing.allocator, a, r, null, Color.white);
    try b.drawTexture(testing.allocator, c, r, null, Color.white);
    try b.fillRect(testing.allocator, r, Color.white);

    try testing.expectEqual(@as(usize, 6), b.quadCount());
    try testing.expectEqual(@as(usize, 4), b.calls.items.len);
    const calls = b.calls.items;
    try testing.expectEqual(DrawCall{ .texture = 0, .first_index = 0, .index_count = 6 }, calls[0]);
    try testing.expectEqual(DrawCall{ .texture = 1, .first_index = 6, .index_count = 18 }, calls[1]);
    try testing.expectEqual(DrawCall{ .texture = 2, .first_index = 24, .index_count = 6 }, calls[2]);
    try testing.expectEqual(DrawCall{ .texture = 0, .first_index = 30, .index_count = 6 }, calls[3]);
}

test "draw calls cover every index exactly once" {
    var b: Batch = .{};
    defer b.deinit(testing.allocator);
    const r: Rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 };
    for (0..20) |i| {
        const t: Texture = .{ .id = @intCast(i % 3), .width = 4, .height = 4 };
        try b.drawTexture(testing.allocator, t, r, null, Color.white);
    }
    var next: u32 = 0;
    for (b.calls.items) |call| {
        try testing.expectEqual(next, call.first_index);
        next += call.index_count;
    }
    try testing.expectEqual(@as(u32, @intCast(b.indices.items.len)), next);
}

test "strokeRect makes four sides that do not overlap" {
    var b: Batch = .{};
    defer b.deinit(testing.allocator);
    try b.strokeRect(testing.allocator, .{ .x = 0, .y = 0, .w = 100, .h = 50 }, 4, Color.white);
    try testing.expectEqual(@as(usize, 4), b.quadCount());

    var area: f32 = 0;
    var q: usize = 0;
    while (q < 4) : (q += 1) {
        const tl = b.vertices.items[q * 4].pos;
        const br = b.vertices.items[q * 4 + 2].pos;
        area += (br[0] - tl[0]) * (br[1] - tl[1]);
    }
    // Outer 100x50 minus inner 92x42.
    try testing.expectApproxEqAbs(@as(f32, 100 * 50 - 92 * 42), area, 1e-3);
}

test "strokeRect with a thick line fills the rectangle" {
    var b: Batch = .{};
    defer b.deinit(testing.allocator);
    try b.strokeRect(testing.allocator, .{ .x = 0, .y = 0, .w = 10, .h = 10 }, 5, Color.white);
    try testing.expectEqual(@as(usize, 1), b.quadCount());
}

test "strokeRect with no line draws nothing" {
    var b: Batch = .{};
    defer b.deinit(testing.allocator);
    try b.strokeRect(testing.allocator, .{ .x = 0, .y = 0, .w = 10, .h = 10 }, 0, Color.white);
    try testing.expectEqual(@as(usize, 0), b.quadCount());
    try testing.expectEqual(@as(usize, 0), b.calls.items.len);
}

test "drawTexture maps the source rectangle to uv" {
    var b: Batch = .{};
    defer b.deinit(testing.allocator);
    const t: Texture = .{ .id = 1, .width = 64, .height = 32 };
    try b.drawTexture(
        testing.allocator,
        t,
        .{ .x = 0, .y = 0, .w = 16, .h = 16 },
        .{ .x = 16, .y = 8, .w = 32, .h = 16 },
        .{ .r = 1, .g = 0.5, .b = 0.25, .a = 0.5 },
    );
    const v = b.vertices.items;
    try testing.expectEqual([2]f32{ 0.25, 0.25 }, v[0].uv);
    try testing.expectEqual([2]f32{ 0.75, 0.25 }, v[1].uv);
    try testing.expectEqual([2]f32{ 0.75, 0.75 }, v[2].uv);
    try testing.expectEqual([2]f32{ 0.25, 0.75 }, v[3].uv);
    try testing.expectEqual([4]f32{ 1, 0.5, 0.25, 0.5 }, v[0].color);
}

test "drawTexture without a source uses the whole texture" {
    var b: Batch = .{};
    defer b.deinit(testing.allocator);
    const t: Texture = .{ .id = 1, .width = 10, .height = 10 };
    try b.drawTexture(testing.allocator, t, .{ .x = 0, .y = 0, .w = 5, .h = 5 }, null, Color.white);
    try testing.expectEqual([2]f32{ 0, 0 }, b.vertices.items[0].uv);
    try testing.expectEqual([2]f32{ 1, 1 }, b.vertices.items[2].uv);
}

test "reset keeps no shapes" {
    var b: Batch = .{};
    defer b.deinit(testing.allocator);
    try b.fillRect(testing.allocator, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, Color.white);
    b.reset();
    try testing.expectEqual(@as(usize, 0), b.quadCount());
    try testing.expectEqual(@as(usize, 0), b.calls.items.len);
    try b.fillRect(testing.allocator, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, Color.white);
    try testing.expectEqual(@as(u32, 0), b.calls.items[0].first_index);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 0, 2, 3 }, b.indices.items);
}

test "rgba8 converts to 0..1" {
    const c = Color.rgba8(255, 0, 51, 255);
    try testing.expectApproxEqAbs(@as(f32, 1), c.r, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.2), c.b, 1e-6);
}
