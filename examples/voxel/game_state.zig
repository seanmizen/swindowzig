const std = @import("std");

pub const LayerTag = enum {
    gameplay,
    hud,
    debug_overlay,
    pause_menu,
};

pub const InputMode = enum {
    captures_all, // blocks all input to layers below
    overlay, // consumes only specific keys, passes rest through
    passthrough, // all input passes through
};

pub const Layer = struct {
    tag: LayerTag,
    input_mode: InputMode,
    pauses_world: bool,
    active: bool,
};

pub const GameState = struct {
    layers: [8]Layer,
    layer_count: u8,

    pub fn init() GameState {
        var gs = GameState{
            .layers = undefined,
            .layer_count = 2,
        };
        gs.layers[0] = .{
            .tag = .gameplay,
            .input_mode = .captures_all,
            .pauses_world = false,
            .active = true,
        };
        gs.layers[1] = .{
            .tag = .hud,
            .input_mode = .passthrough,
            .pauses_world = false,
            .active = true,
        };
        return gs;
    }

    pub fn isWorldPaused(self: *const GameState) bool {
        for (self.layers[0..self.layer_count]) |layer| {
            if (layer.active and layer.pauses_world) return true;
        }
        return false;
    }

    /// Returns false if any active layer above gameplay has captures_all
    pub fn gameplayReceivesInput(self: *const GameState) bool {
        var gameplay_idx: ?usize = null;
        for (self.layers[0..self.layer_count], 0..) |layer, i| {
            if (layer.tag == .gameplay) {
                gameplay_idx = i;
                break;
            }
        }
        const gi = gameplay_idx orelse return true;
        for (self.layers[gi + 1 .. self.layer_count]) |layer| {
            if (layer.active and layer.input_mode == .captures_all) return false;
        }
        return true;
    }

    pub fn isLayerActive(self: *const GameState, tag: LayerTag) bool {
        for (self.layers[0..self.layer_count]) |layer| {
            if (layer.tag == tag) return layer.active;
        }
        return false;
    }

    pub fn findLayer(self: *GameState, tag: LayerTag) ?*Layer {
        for (self.layers[0..self.layer_count]) |*layer| {
            if (layer.tag == tag) return layer;
        }
        return null;
    }

    pub fn togglePauseMenu(self: *GameState) void {
        if (self.findLayer(.pause_menu)) |layer| {
            layer.active = !layer.active;
        } else {
            if (self.layer_count < self.layers.len) {
                self.layers[self.layer_count] = .{
                    .tag = .pause_menu,
                    .input_mode = .captures_all,
                    .pauses_world = true,
                    .active = true,
                };
                self.layer_count += 1;
            }
        }
    }

    pub fn toggleDebugOverlay(self: *GameState) void {
        if (self.findLayer(.debug_overlay)) |layer| {
            layer.active = !layer.active;
        } else {
            if (self.layer_count < self.layers.len) {
                self.layers[self.layer_count] = .{
                    .tag = .debug_overlay,
                    .input_mode = .overlay,
                    .pauses_world = false,
                    .active = true,
                };
                self.layer_count += 1;
            }
        }
    }
};
