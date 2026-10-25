// keyboard_hud.zig
// British English Mac ISO keyboard layout rendered as a debug overlay.
// All measurements are integer pixels — S=16 ensures every key boundary lands
// on a whole pixel, eliminating gap-width jitter from fractional rounding.

const std = @import("std");
const KC = @import("sw_core").KeyCode;
const OverlayRenderer = @import("overlay.zig").OverlayRenderer;

// ─── Grid constants (all integers) ──────────────────────────────────────────
const S: f32 = 16; // step per 1u (key body + gap)
const U: f32 = 14; // 1u key body width  (S - G = 16 - 2 = 14) ✓
const G: f32 = 2; // gap between keys
const KH: f32 = 13; // key height
const RS: f32 = 15; // row step  (KH + G)

// ─── Key widths — all resolve to integers with S=16 ─────────────────────────
const W1: f32 = U; //  1.00u = 14
const W1q: f32 = 1.25 * S - G; //  1.25u = 18
const W1h: f32 = 1.5 * S - G; //  1.50u = 22
const W1t: f32 = 1.75 * S - G; //  1.75u = 26
const W2: f32 = 2.0 * S - G; //  2.00u = 30
const W2t: f32 = 2.75 * S - G; //  2.75u = 42
const WSP: f32 = 6.0 * S - G; //  6.00u = 94  (space bar)

// ─── Row Y offsets (no function row) ────────────────────────────────────────
const r1: f32 = 0; // number row
const r2: f32 = RS; // QWERTY row  = 15
const r3: f32 = RS * 2; // ASDF row    = 30
const r4: f32 = RS * 3; // ZXCV row    = 45
const r5: f32 = RS * 4; // space bar   = 60

// ─── Stacked arrow half-heights ─────────────────────────────────────────────
const AH: f32 = 6; // each half-arrow height
const AG: f32 = KH - AH * 2; // gap between them = 1

// ─── Colour kinds ────────────────────────────────────────────────────────────
const C_NORM: u8 = 0; // normal detectable key
const C_UNKN: u8 = 1; // undetectable (punctuation / caps / fn)
const C_SHFT: u8 = 2; // Shift — yellow
const C_CTRL: u8 = 3; // Ctrl/^ — blue
const C_ALT: u8 = 4; // Alt/⌥ — green
const C_SUPR: u8 = 5; // Cmd/⌘ / Win — orange
const C_SPC: u8 = 6; // Space — light blue
const C_ENT: u8 = 7; // Return — green tint
const C_BSP: u8 = 8; // Backspace/Delete — red tint

// ─── Key descriptor ──────────────────────────────────────────────────────────
const K = struct {
    x: f32,
    y: f32,
    w: f32 = W1,
    h: f32 = KH,
    code: ?KC = null,
    clr: u8 = C_NORM,
};

// ─── British Mac ISO layout (no function row) ─────────────────────────────────
//
// All x positions are n * S — integer multiples of 16.
// Key widths are nU * S - G — always integers.
// Every gap is exactly G = 2px. No fractional pixels anywhere.
//
// Right edge of main block (excl. arrow cluster): 13*S + W2 = 208 + 30 = 238 px
// Arrow cluster right edge: 15.75*S + W1 = 252 + 14 = 266 px  → KB_W
//
// British ISO specifics:
//   • §/` key left of 1 (physical key has § printed; ` is an alt combo)
//   • Short L-Shift + extra \ | key before Z
//   • ISO Enter: tall L-shape spanning QWERTY + ASDF rows
//   • # / ~ key right of ' (before Return bottom)
//   • No right-hand Alt label (it's Option on Mac)

const keys = [_]K{
    // ── Number row ───────────────────────────────────────────────────────────
    // §/` key (left of 1 on British Mac; ` accessed via opt+§)
    .{ .x = 0 * S, .y = r1, .clr = C_UNKN }, // §  `
    .{ .x = 1 * S, .y = r1, .code = KC.Num1 },
    .{ .x = 2 * S, .y = r1, .code = KC.Num2 },
    .{ .x = 3 * S, .y = r1, .code = KC.Num3 },
    .{ .x = 4 * S, .y = r1, .code = KC.Num4 },
    .{ .x = 5 * S, .y = r1, .code = KC.Num5 },
    .{ .x = 6 * S, .y = r1, .code = KC.Num6 },
    .{ .x = 7 * S, .y = r1, .code = KC.Num7 },
    .{ .x = 8 * S, .y = r1, .code = KC.Num8 },
    .{ .x = 9 * S, .y = r1, .code = KC.Num9 },
    .{ .x = 10 * S, .y = r1, .code = KC.Num0 },
    .{ .x = 11 * S, .y = r1, .clr = C_UNKN }, // -  _
    .{ .x = 12 * S, .y = r1, .clr = C_UNKN }, // =  +
    .{ .x = 13 * S, .y = r1, .w = W2, .code = KC.Backspace, .clr = C_BSP }, // Delete

    // ── QWERTY row ───────────────────────────────────────────────────────────
    .{ .x = 0, .y = r2, .w = W1h }, // Tab (undetectable)
    .{ .x = 1.5 * S, .y = r2, .code = KC.Q },
    .{ .x = 2.5 * S, .y = r2, .code = KC.W },
    .{ .x = 3.5 * S, .y = r2, .code = KC.E },
    .{ .x = 4.5 * S, .y = r2, .code = KC.R },
    .{ .x = 5.5 * S, .y = r2, .code = KC.T },
    .{ .x = 6.5 * S, .y = r2, .code = KC.Y },
    .{ .x = 7.5 * S, .y = r2, .code = KC.U },
    .{ .x = 8.5 * S, .y = r2, .code = KC.I },
    .{ .x = 9.5 * S, .y = r2, .code = KC.O },
    .{ .x = 10.5 * S, .y = r2, .code = KC.P },
    .{ .x = 11.5 * S, .y = r2, .clr = C_UNKN }, // [  {
    .{ .x = 12.5 * S, .y = r2, .clr = C_UNKN }, // ]  }
    // Return top — ISO L-shape upper portion (1.5u wide, right edge = 238)
    .{ .x = 13.5 * S, .y = r2, .w = W1h, .h = KH, .code = KC.Enter, .clr = C_ENT },

    // ── ASDF row ─────────────────────────────────────────────────────────────
    .{ .x = 0, .y = r3, .w = W1t, .clr = C_UNKN }, // Caps Lock
    .{ .x = 1.75 * S, .y = r3, .code = KC.A },
    .{ .x = 2.75 * S, .y = r3, .code = KC.S },
    .{ .x = 3.75 * S, .y = r3, .code = KC.D },
    .{ .x = 4.75 * S, .y = r3, .code = KC.F },
    .{ .x = 5.75 * S, .y = r3, .code = KC.G },
    .{ .x = 6.75 * S, .y = r3, .code = KC.H },
    .{ .x = 7.75 * S, .y = r3, .code = KC.J },
    .{ .x = 8.75 * S, .y = r3, .code = KC.K },
    .{ .x = 9.75 * S, .y = r3, .code = KC.L },
    .{ .x = 10.75 * S, .y = r3, .clr = C_UNKN }, // ;  :
    .{ .x = 11.75 * S, .y = r3, .clr = C_UNKN }, // '  @
    .{ .x = 12.75 * S, .y = r3, .clr = C_UNKN }, // #  ~ (British ISO)
    // Return bottom — ISO L-shape lower portion (1.25u wide, right edge = 238)
    .{ .x = 13.75 * S, .y = r3 - G, .w = W1q, .h = KH + G, .code = KC.Enter, .clr = C_ENT },

    // ── ZXCV row ─────────────────────────────────────────────────────────────
    // British ISO: short L-Shift (1.25u) + extra \ | key before Z
    .{ .x = 0, .y = r4, .w = W1q, .code = KC.Shift, .clr = C_SHFT }, // L-Shift
    .{ .x = 1.25 * S, .y = r4, .clr = C_UNKN }, // \  |
    .{ .x = 2.25 * S, .y = r4, .code = KC.Z },
    .{ .x = 3.25 * S, .y = r4, .code = KC.X },
    .{ .x = 4.25 * S, .y = r4, .code = KC.C },
    .{ .x = 5.25 * S, .y = r4, .code = KC.V },
    .{ .x = 6.25 * S, .y = r4, .code = KC.B },
    .{ .x = 7.25 * S, .y = r4, .code = KC.N },
    .{ .x = 8.25 * S, .y = r4, .code = KC.M },
    .{ .x = 9.25 * S, .y = r4, .clr = C_UNKN }, // ,  <
    .{ .x = 10.25 * S, .y = r4, .clr = C_UNKN }, // .  >
    .{ .x = 11.25 * S, .y = r4, .clr = C_UNKN }, // /  ?
    // R-Shift: 2.75u, right edge = 12.25*S + W2t = 196 + 42 = 238 ✓
    .{ .x = 12.25 * S, .y = r4, .w = W2t, .code = KC.Shift, .clr = C_SHFT },

    // ── Space bar row ─────────────────────────────────────────────────────────
    .{ .x = 0, .y = r5, .clr = C_UNKN }, // fn
    .{ .x = 1.0 * S, .y = r5, .w = W1q, .code = KC.Ctrl, .clr = C_CTRL }, // Control
    .{ .x = 2.25 * S, .y = r5, .w = W1q, .code = KC.Alt, .clr = C_ALT }, // Option ⌥
    .{ .x = 3.5 * S, .y = r5, .w = W1h, .code = KC.Super, .clr = C_SUPR }, // Cmd ⌘
    // Space: 6u, starts at 5*S=80, ends at 80+94=174
    .{ .x = 5.0 * S, .y = r5, .w = WSP, .code = KC.Space, .clr = C_SPC },
    // R-Cmd: starts at 11*S=176, right edge = 176+22=198
    .{ .x = 11.0 * S, .y = r5, .w = W1h, .code = KC.Super, .clr = C_SUPR }, // Cmd ⌘
    // R-Option: starts at 12.5*S=200, right edge = 200+18=218
    .{ .x = 12.5 * S, .y = r5, .w = W1q, .code = KC.Alt, .clr = C_ALT }, // Option ⌥

    // ── Arrow cluster — inverted T ────────────────────────────────────────────
    // Left edge of cluster: 13.75*S = 220 (gap of 2 from R-Option end 218 ✓)
    .{ .x = 13.75 * S, .y = r5, .code = KC.Left },
    .{ .x = 14.75 * S, .y = r5, .h = AH, .code = KC.Up },
    .{ .x = 14.75 * S, .y = r5 + AH + AG, .h = AH, .code = KC.Down },
    .{ .x = 15.75 * S, .y = r5, .code = KC.Right },
};

// Total bounding box
pub const KB_W: f32 = 15.75 * S + W1; // 252 + 14 = 266
pub const KB_H: f32 = r5 + KH; //  60 + 13 =  73

// ─── Colour palette ──────────────────────────────────────────────────────────
// Index [clr][pressed: 0/1] → RGBA
const palette = [9][2][4]f32{
    // C_NORM — dark grey / bright white
    .{ .{ 0.28, 0.28, 0.32, 0.82 }, .{ 0.96, 0.96, 0.96, 0.98 } },
    // C_UNKN — fixed dim (can't detect state)
    .{ .{ 0.18, 0.18, 0.20, 0.70 }, .{ 0.18, 0.18, 0.20, 0.70 } },
    // C_SHFT — yellow
    .{ .{ 0.52, 0.46, 0.06, 0.78 }, .{ 0.98, 0.90, 0.15, 0.98 } },
    // C_CTRL — blue
    .{ .{ 0.12, 0.26, 0.52, 0.78 }, .{ 0.28, 0.58, 1.00, 0.98 } },
    // C_ALT — green
    .{ .{ 0.08, 0.38, 0.20, 0.78 }, .{ 0.20, 0.88, 0.48, 0.98 } },
    // C_SUPR — orange
    .{ .{ 0.46, 0.26, 0.05, 0.78 }, .{ 1.00, 0.58, 0.18, 0.98 } },
    // C_SPC — steel blue tint
    .{ .{ 0.20, 0.24, 0.36, 0.82 }, .{ 0.72, 0.78, 1.00, 0.98 } },
    // C_ENT — green tint
    .{ .{ 0.12, 0.30, 0.15, 0.82 }, .{ 0.35, 0.92, 0.42, 0.98 } },
    // C_BSP — red tint
    .{ .{ 0.34, 0.11, 0.11, 0.82 }, .{ 1.00, 0.38, 0.38, 0.98 } },
};

/// Draw the full keyboard HUD. Call only when debug_mode is active.
pub fn draw(
    overlay: *OverlayRenderer,
    input: anytype,
    overlay_w: f32,
    overlay_h: f32,
) void {
    const pad: f32 = 6;
    const kb_x = overlay_w - KB_W - pad * 2;
    const kb_y: f32 = pad;

    // Background panel
    overlay.rect(
        kb_x - pad,
        kb_y - pad,
        KB_W + pad * 2,
        KB_H + pad * 2,
        .{ 0.04, 0.04, 0.06, 0.85 },
        overlay_w,
        overlay_h,
    ) catch {};

    for (keys) |k| {
        const pressed = if (k.code) |c| input.keyDown(c) else false;
        const col = palette[k.clr][@intFromBool(pressed)];
        overlay.rect(
            kb_x + k.x,
            kb_y + k.y,
            k.w,
            k.h,
            col,
            overlay_w,
            overlay_h,
        ) catch {};
    }
}
