//! Drawing for the UI tree, with sw_gfx2d and sw_text. This is the only file
//! of sw_ui that needs a GPU or a font.

const gfx = @import("sw_gfx2d");
const sw_text = @import("sw_text");
const ui = @import("ui.zig");

/// The colours of the UI. The defaults are light on dark, and the focus ring
/// is bright yellow so that it shows on every other colour here.
pub const Palette = struct {
    text: gfx.Color = gfx.Color.rgba8(236, 236, 240, 255),
    text_disabled: gfx.Color = gfx.Color.rgba8(128, 128, 140, 255),
    /// Text in composition (an IME or a dead key has not committed it).
    composition: gfx.Color = gfx.Color.rgba8(170, 190, 255, 255),
    panel: gfx.Color = gfx.Color.rgba8(28, 28, 40, 255),
    panel_edge: gfx.Color = gfx.Color.rgba8(110, 110, 140, 255),
    control: gfx.Color = gfx.Color.rgba8(52, 54, 76, 255),
    control_disabled: gfx.Color = gfx.Color.rgba8(36, 36, 48, 255),
    selected: gfx.Color = gfx.Color.rgba8(52, 98, 160, 255),
    field: gfx.Color = gfx.Color.rgba8(14, 14, 22, 255),
    field_edge: gfx.Color = gfx.Color.rgba8(120, 120, 140, 255),
    focus: gfx.Color = gfx.Color.rgba8(255, 221, 0, 255),
};

fn measureText(context: ?*const anyopaque, s: []const u8, size: f32) ui.Size {
    const renderer: *const sw_text.TextRenderer = @ptrCast(@alignCast(context.?));
    const m = renderer.measure(s, size);
    return .{ .w = m.w, .h = m.h };
}

/// A measurer for the UI that uses a `TextRenderer`. The renderer must stay at
/// the same address while the UI uses it.
pub fn measurer(renderer: *const sw_text.TextRenderer) ui.Measurer {
    return .{ .context = renderer, .measureFn = measureText };
}

fn toRect(r: ui.Rect) gfx.Rect {
    return .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
}

/// Draw the tree of the last `Ui.finish`, with the focus ring on top.
pub fn draw(
    u: *const ui.Ui,
    r: *gfx.Renderer,
    text: *sw_text.TextRenderer,
    palette: Palette,
) !void {
    const size = u.theme.text_size;
    const line = text.lineHeight(size);

    for (u.nodes.items) |n| {
        const rect = toRect(n.rect);
        const color = if (n.opts.disabled) palette.text_disabled else palette.text;
        const pad = n.opts.padding orelse u.theme.control_pad;
        switch (n.kind) {
            .row, .column, .list => {
                if (n.opts.panel) {
                    try r.fillRect(rect, palette.panel);
                    try r.strokeRect(rect, 2, palette.panel_edge);
                }
            },
            .text => {
                _ = try text.draw(r, n.text, rect.x + (n.opts.padding orelse 0), rect.y + (n.opts.padding orelse 0), .{ .size = size, .color = color });
            },
            .button => {
                try r.fillRect(rect, if (n.opts.disabled) palette.control_disabled else palette.control);
                try r.strokeRect(rect, 1, palette.panel_edge);
                _ = try text.draw(r, n.text, rect.x + pad, rect.y + (rect.h - line) / 2, .{ .size = size, .color = color });
            },
            .list_item => {
                if (n.opts.selected) try r.fillRect(rect, palette.selected);
                _ = try text.draw(r, n.text, rect.x + pad, rect.y + (rect.h - line) / 2, .{ .size = size, .color = color });
            },
            .text_field => {
                try r.fillRect(rect, palette.field);
                try r.strokeRect(rect, 1, palette.field_edge);
                const committed = if (n.value) |v| v.slice() else "";
                const ty = rect.y + (rect.h - line) / 2;
                var tx = rect.x + pad;
                if (committed.len > 0) {
                    const used = try text.draw(r, committed, tx, ty, .{ .size = size, .color = color });
                    tx += used.w;
                }
                const focused = u.focus_id == n.id;
                if (focused and u.input.composition.len > 0) {
                    const used = try text.draw(r, u.input.composition, tx, ty, .{ .size = size, .color = palette.composition });
                    tx += used.w;
                }
                if (focused) {
                    // The caret. It does not blink: a blinking caret needs a time source.
                    try r.fillRect(.{ .x = tx, .y = ty, .w = 2, .h = line }, palette.text);
                }
            },
            .image => {
                const texture: gfx.Texture = .{ .id = n.texture, .width = 1, .height = 1 };
                try r.drawTexture(texture, rect, null, gfx.Color.white);
            },
        }
    }

    // The focus ring is outside the node, so it hides no text.
    if (u.focus_id != 0) {
        if (u.indexOf(u.focus_id)) |index| {
            const rect = toRect(u.nodes.items[index].rect);
            const w = u.theme.focus_ring;
            const outer: gfx.Rect = .{ .x = rect.x - w, .y = rect.y - w, .w = rect.w + 2 * w, .h = rect.h + 2 * w };
            try r.strokeRect(outer, w, palette.focus);
        }
    }
}
