// The tests of the shooter demo that need no GPU (zig build test).
test {
    _ = @import("vec.zig");
    _ = @import("arena.zig");
    _ = @import("npc.zig");
    _ = @import("body_model.zig");
    _ = @import("guns_test.zig");
    _ = @import("game.zig");
}
