//! World tests on the terrain of the demo (sw_voxel World with the demo
//! content). `zig build test` runs them.
const std = @import("std");
const sw_voxel = @import("sw_voxel");
const content = @import("voxel_content");

const chunk_mod = sw_voxel.chunk;
const World = sw_voxel.world.World;
const buildSpiralOffsets = sw_voxel.world.buildSpiralOffsets;

test "world: a shaft dug into a cave lights the cave across the chunk border" {
    // Sean's repro: at (14, 15) on the hilly world, a shaft from the
    // surface down to y=60 opens into a cave at y <= 66. x=15 and z=15 are
    // the last cells before the borders with chunks (1,0) and (0,1).
    var world = try World.init(std.testing.allocator, content.world_gen.presetConfig(.hilly), 4);
    defer world.deinit();
    const offsets = try buildSpiralOffsets(std.testing.allocator, 3);
    defer std.testing.allocator.free(offsets);
    for (offsets) |off| _ = try world.generateChunk(off.dx, off.dz);
    var y: i32 = chunk_mod.CHUNK_H - 1;
    while (y > 60 and world.getBlock(14, y, 15) == .air) y -= 1;
    while (y >= 60) : (y -= 1) _ = try world.setBlock(14, y, 15, .air);

    // The shaft is open to the sky, and the cave next to it gets 14.
    try std.testing.expectEqual(@as(u8, 15), world.getSkylight(14, 60, 15));
    try std.testing.expectEqual(.air, world.getBlock(15, 62, 15));
    try std.testing.expectEqual(@as(u8, 14), world.getSkylight(15, 62, 15));
    // Across the borders the cave gets light, not 0. (16, 62, 15) is two
    // steps from the shaft. (14, 62, 16) is next to the shaft.
    try std.testing.expectEqual(.air, world.getBlock(16, 62, 15));
    try std.testing.expectEqual(@as(u8, 13), world.getSkylight(16, 62, 15));
    try std.testing.expectEqual(.air, world.getBlock(14, 62, 16));
    try std.testing.expectEqual(@as(u8, 14), world.getSkylight(14, 62, 16));
}
