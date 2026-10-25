//! sw_ui - a UI tree for swindowzig: immediate mode, keyboard focus, and a
//! semantic tree for assistive technology. Import it as
//! `const ui = @import("sw_ui");`.
//!
//! The app builds the tree each frame and calls `finish`. The same tree then
//! gives three things:
//!
//! - events (`frameEvents`): activations, cancel, text changes;
//! - drawing (`draw.draw`): sw_gfx2d shapes and sw_text text, with a focus ring;
//! - the semantic tree (`semanticTree`): plain data for a backend, such as a
//!   web screen-reader mirror.
//!
//! `ui.zig` holds the tree, the layout and the focus rules. It has no GPU or
//! font code. `draw.zig` is the only part that uses sw_gfx2d and sw_text.

const ui_mod = @import("ui.zig");

pub const semantic = @import("semantic.zig");
pub const draw = @import("draw.zig");

pub const Ui = ui_mod.Ui;
pub const Opts = ui_mod.Opts;
pub const Dim = ui_mod.Dim;
pub const Align = ui_mod.Align;
pub const Theme = ui_mod.Theme;
pub const Kind = ui_mod.Kind;
pub const Size = ui_mod.Size;
pub const Measurer = ui_mod.Measurer;
pub const Input = ui_mod.Input;
pub const Keys = ui_mod.Keys;
pub const Event = ui_mod.Event;
pub const EventKind = ui_mod.EventKind;
pub const TextValue = ui_mod.TextValue;
pub const Error = ui_mod.Error;
pub const root_id = ui_mod.root_id;

pub const Rect = semantic.Rect;
pub const Role = semantic.Role;
pub const SemanticNode = semantic.SemanticNode;
pub const SemanticTree = semantic.SemanticTree;
