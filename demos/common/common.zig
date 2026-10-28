//! The shared code of the showcase demos in `demos/`. The demos use the
//! engine as a game does: this code is demo code, not library code, so it
//! can use the names of the demos.
//!
//! - `run`: the command line (`--tas`, `--preset`, `--capture`,
//!   `--hashes`, `--check`), the TAS player and the frame capture
//!   (REQ-DEMO-001, REQ-DEMO-002).
//! - `mesh`: a triangle mesh renderer on the frame graph, with the shadows,
//!   the point lights, the fog, a wireframe and a first-person pass.
//! - `cow`: the voxel cow, and the naive and greedy meshers with AO.
//! - `cow_scene`: the turning cow on its stand, with each setting that the
//!   cow demo and the menu demo change.
//! - `overlay`: the text and the frame-time chart over the post chain.
//! - `fonts` and `bitmap_font`: the fonts of the demo text.
//! - `sound`: the sounds that the demos make in code.

pub const run = @import("run.zig");
pub const mesh = @import("mesh.zig");
pub const cow = @import("cow.zig");
pub const cow_scene = @import("cow_scene.zig");
pub const overlay = @import("overlay.zig");
pub const fonts = @import("fonts.zig");
pub const bitmap_font = @import("bitmap_font.zig");
pub const sound = @import("sound.zig");
