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
    /// The selected text of a text field.
    selection: gfx.Color = gfx.Color.rgba8(60, 90, 150, 255),
    /// The track of a slider and of a scroll bar.
    track: gfx.Color = gfx.Color.rgba8(70, 70, 92, 255),
    /// The part of a slider track from its minimum to its value.
    track_fill: gfx.Color = gfx.Color.rgba8(90, 140, 220, 255),
    /// The thumb of a slider and of a scroll bar.
    thumb: gfx.Color = gfx.Color.rgba8(220, 220, 232, 255),
    tooltip: gfx.Color = gfx.Color.rgba8(250, 246, 220, 255),
    tooltip_text: gfx.Color = gfx.Color.rgba8(24, 24, 32, 255),
    /// The layer under the top screen, over the other nodes.
    scrim: gfx.Color = gfx.Color.rgba8(0, 0, 0, 150),
};

fn measureText(context: ?*const anyopaque, s: []const u8, size: f32) ui.Size {
    const renderer: *const sw_text.TextRenderer = @ptrCast(@alignCast(context.?));
    const m = renderer.measure(s, size);
    return .{ .w = m.w, .h = m.h };
}

fn caretX(context: ?*const anyopaque, s: []const u8, size: f32, offset: usize) f32 {
    const renderer: *const sw_text.TextRenderer = @ptrCast(@alignCast(context.?));
    var c = renderer.caretLayout(s, size, .auto) catch {
        // No memory: the width of the bytes before the caret.
        return renderer.measure(s[0..@min(offset, s.len)], size).w;
    };
    defer c.deinit();
    return c.caretX(offset);
}

/// A measurer for the UI that uses a `TextRenderer`. The caret positions come
/// from the bidi caret layout of sw_text. The renderer must stay at the same
/// address while the UI uses it.
pub fn measurer(renderer: *const sw_text.TextRenderer) ui.Measurer {
    return .{ .context = renderer, .measureFn = measureText, .caretFn = caretX };
}

fn toRect(r: ui.Rect) gfx.Rect {
    return .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
}

fn fromRect(r: gfx.Rect) ui.Rect {
    return .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
}

/// `r` cut by the clip that the app set.
fn cutToApp(app_clip: ?gfx.Rect, r: ui.Rect) gfx.Rect {
    const a = app_clip orelse return toRect(r);
    return toRect(ui.intersect(fromRect(a), r));
}

fn drawTextField(
    u: *const ui.Ui,
    n: *const ui.Node,
    r: *gfx.Renderer,
    text: *sw_text.TextRenderer,
    palette: Palette,
    color: gfx.Color,
    clip: gfx.Rect,
) !void {
    const size = u.theme.text_size;
    const line = text.lineHeight(size);
    const rect = toRect(n.rect);
    try r.fillRect(rect, palette.field);
    try r.strokeRect(rect, 1, palette.field_edge);

    // The text scrolls inside the padding of the field.
    const inner = u.innerRect(n);
    r.setClip(toRect(ui.intersect(fromRect(clip), inner)));
    defer r.setClip(clip);

    const value = n.value orelse return;
    const committed = value.slice();
    const focused = u.focus_id == n.id;
    const ty = rect.y + (rect.h - line) / 2;
    const tx = inner.x - u.scrollOf(n.id);

    var layout = try text.caretLayout(committed, size, .auto);
    defer layout.deinit();

    // The selection: one box for each selected code point, so each part of
    // mixed text shows where it is drawn.
    const sel = value.selection();
    if (focused and sel.end > sel.start) {
        var i = layout.indexOf(sel.start);
        const end = layout.indexOf(sel.end);
        while (i < end) : (i += 1) {
            try r.fillRect(.{ .x = tx + layout.left[i], .y = ty, .w = layout.width[i], .h = line }, palette.selection);
        }
    }
    if (committed.len > 0) _ = try text.draw(r, committed, tx, ty, .{ .size = size, .color = color });

    if (focused) {
        var cx = tx + layout.caretX(value.caretPos());
        if (u.input.composition.len > 0) {
            // The text in composition goes at the caret, over the text.
            const m = text.measure(u.input.composition, size);
            try r.fillRect(.{ .x = cx, .y = ty, .w = m.w, .h = line }, palette.field);
            const used = try text.draw(r, u.input.composition, cx, ty, .{ .size = size, .color = palette.composition });
            cx += used.w;
        }
        // The caret. It does not blink: a blinking caret needs a time source.
        try r.fillRect(.{ .x = cx, .y = ty, .w = 2, .h = line }, palette.text);
    }
}

/// Draw the tree of the last `Ui.finish`, with the focus ring and the
/// tooltip on top. Each node is cut to its clip (a scroll list cuts its
/// children) and to the clip that the app set, which stays in place.
pub fn draw(
    u: *const ui.Ui,
    r: *gfx.Renderer,
    text: *sw_text.TextRenderer,
    palette: Palette,
) !void {
    const size = u.theme.text_size;
    const line = text.lineHeight(size);
    const app_clip = r.getClip();
    defer r.setClip(app_clip);

    for (u.nodes.items, 0..) |*n, index| {
        const clip = cutToApp(app_clip, n.clip);
        r.setClip(clip);
        const rect = toRect(n.rect);
        const color = if (n.opts.disabled) palette.text_disabled else palette.text;
        const pad = n.opts.padding orelse u.theme.control_pad;
        switch (n.kind) {
            .row, .column, .list, .scroll_list, .screen => {
                // The top screen covers the nodes before it with the scrim.
                if (n.kind == .screen and u.top_screen == index and index > 1) {
                    try r.fillRect(clip, palette.scrim);
                }
                if (n.opts.panel) {
                    try r.fillRect(rect, palette.panel);
                    try r.strokeRect(rect, 2, palette.panel_edge);
                }
                if (u.scrollBar(index)) |bar| {
                    try r.fillRect(toRect(bar.track), palette.track);
                    try r.fillRect(toRect(bar.thumb), palette.thumb);
                }
            },
            .text => {
                _ = try text.draw(r, n.text, rect.x + (n.opts.padding orelse 0), rect.y + (n.opts.padding orelse 0), .{ .size = size, .color = color });
            },
            .button => {
                const fill = if (n.opts.disabled)
                    palette.control_disabled
                else if (n.opts.selected) palette.selected else palette.control;
                try r.fillRect(rect, fill);
                try r.strokeRect(rect, 1, palette.panel_edge);
                _ = try text.draw(r, n.text, rect.x + pad, rect.y + (rect.h - line) / 2, .{ .size = size, .color = color });
            },
            .list_item => {
                if (n.opts.selected) try r.fillRect(rect, palette.selected);
                _ = try text.draw(r, n.text, rect.x + pad, rect.y + (rect.h - line) / 2, .{ .size = size, .color = color });
            },
            .text_field => try drawTextField(u, n, r, text, palette, color, clip),
            .slider => {
                const parts = u.sliderParts(index);
                try r.fillRect(toRect(parts.track), palette.track);
                try r.fillRect(toRect(parts.fill), if (n.opts.disabled) palette.text_disabled else palette.track_fill);
                try r.fillRect(toRect(parts.thumb), if (n.opts.disabled) palette.control_disabled else palette.thumb);
            },
            .image => {
                const texture: gfx.Texture = .{ .id = n.texture, .width = 1, .height = 1 };
                try r.drawTexture(texture, rect, null, gfx.Color.white);
            },
        }
    }

    // The focus ring is outside the node, so it hides no text. The ring of a
    // node in a scroll list is cut a ring width outside the list.
    if (u.focus_id != 0) {
        if (u.indexOf(u.focus_id)) |index| {
            const n = &u.nodes.items[index];
            const w = u.theme.focus_ring;
            const c = n.clip;
            r.setClip(cutToApp(app_clip, .{ .x = c.x - w, .y = c.y - w, .w = c.w + 2 * w, .h = c.h + 2 * w }));
            const rect = toRect(n.rect);
            const outer: gfx.Rect = .{ .x = rect.x - w, .y = rect.y - w, .w = rect.w + 2 * w, .h = rect.h + 2 * w };
            try r.strokeRect(outer, w, palette.focus);
        }
    }

    if (u.tooltip()) |tip| {
        r.setClip(app_clip);
        const rect = toRect(tip.rect);
        try r.fillRect(rect, palette.tooltip);
        try r.strokeRect(rect, 1, palette.panel_edge);
        const p = u.theme.control_pad / 2;
        _ = try text.draw(r, tip.text, rect.x + p, rect.y + p, .{ .size = size, .color = palette.tooltip_text });
    }
}
