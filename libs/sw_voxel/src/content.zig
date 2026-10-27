//! The content contract of sw_voxel. The game gives its block types, the
//! light of each block and its terrain generator in a module, and sw_voxel
//! imports that module as `sw_voxel_content`. sw_voxel knows no block name
//! and no generator. The content module can import `sw_voxel` for the chunk
//! sizes and `DenseBlocks`.
//!
//! Wiring in a build.zig:
//!
//!   const voxel = dep.module("sw_voxel");
//!   const content = b.createModule(.{ .root_source_file = b.path("content.zig") });
//!   voxel.addImport("sw_voxel_content", content);
//!   content.addImport("sw_voxel", voxel);
//!
//! The content module must declare:
//!
//!   pub const Block = enum(u8) { air = 0, ... };
//!       The block types. `air` (value 0) is the empty cell: it gives no
//!       light, stops no light, and has no faces. All other blocks are
//!       solid cubes.
//!   pub fn emission(block: Block) u8
//!       The block light that `block` gives, 0 to `chunk.MAX_BLOCK_LIGHT`.
//!   pub const GenConfig = struct { seed: u64, ... };
//!       The settings of the generator. The pipeline sends it to each
//!       chunk worker in the Hello message.
//!   pub const GEN_CONFIG_LEN: usize
//!   pub fn encodeGenConfig(config: GenConfig, out: *[GEN_CONFIG_LEN]u8) void
//!   pub fn decodeGenConfig(bytes: *const [GEN_CONFIG_LEN]u8) error{BadField}!GenConfig
//!       The bytes of a GenConfig without the seed. The Hello holds the seed.
//!   pub fn generate(dense: *chunk.DenseBlocks, cx: i32, cz: i32, config: GenConfig) void
//!       Write all the blocks of chunk (cx, cz). The result must be a pure
//!       function of the arguments (P2): the chunk workers and
//!       main must make the same blocks.
const std = @import("std");
const c = @import("sw_voxel_content");

pub const Block = c.Block;
pub const GenConfig = c.GenConfig;
pub const GEN_CONFIG_LEN: usize = c.GEN_CONFIG_LEN;
pub const encodeGenConfig = c.encodeGenConfig;
pub const decodeGenConfig = c.decodeGenConfig;
pub const generate = c.generate;

/// The block light that `block` gives.
pub inline fn emission(block: Block) u8 {
    return c.emission(block);
}

comptime {
    const info = @typeInfo(Block);
    if (info != .@"enum" or info.@"enum".tag_type != u8)
        @compileError("sw_voxel_content.Block must be an enum(u8)");
    if (!@hasField(Block, "air") or @backingInt(Block.air) != 0)
        @compileError("sw_voxel_content.Block must have air = 0");
    if (!@hasField(GenConfig, "seed") or @FieldType(GenConfig, "seed") != u64)
        @compileError("sw_voxel_content.GenConfig must have a field seed: u64");
}
