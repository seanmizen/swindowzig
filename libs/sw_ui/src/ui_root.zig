//! sw_ui - a UI tree for swindowzig: immediate mode, keyboard focus, and a
//! semantic tree for assistive technology. Import it as
//! `const ui = @import("sw_ui");`.
//!
//! The app builds the tree each frame and calls `finish`. The same tree then
//! gives three things:
//!
//! - events (`frameEvents`): activations, cancel, text and value changes;
//! - drawing (`draw.draw`): sw_gfx2d shapes and sw_text text, with a focus ring;
//! - the semantic tree (`semanticTree`): plain data for a backend. The web
//!   build sends it to the screen-reader mirror (`web_mirror.zig`).
//!
//! The widgets: text, button, list, scroll list, text field (caret,
//! selection, clipboard), slider, image, tooltip (`Opts.tooltip`) and screen.
//! `ScreenStack` keeps a stack of screens, and `osk.Keyboard` is an
//! on-screen keyboard that fills a text field.
//!
//! `ui.zig` holds the tree, the layout and the focus rules. It has no GPU or
//! font code. `draw.zig` is the only part that uses sw_gfx2d and sw_text.

const ui_mod = @import("ui.zig");

pub const semantic = @import("semantic.zig");
pub const draw = @import("draw.zig");
pub const web_mirror = @import("web_mirror.zig");
pub const osk = @import("osk.zig");
pub const ScreenStack = @import("screen.zig").ScreenStack;

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
pub const SliderOpts = ui_mod.SliderOpts;
pub const Clipboard = ui_mod.Clipboard;
pub const Tooltip = ui_mod.Tooltip;
pub const SliderParts = ui_mod.SliderParts;
pub const ScrollBar = ui_mod.ScrollBar;
pub const Node = ui_mod.Node;
pub const Error = ui_mod.Error;
pub const root_id = ui_mod.root_id;
pub const tooltip_id = ui_mod.tooltip_id;

pub const Rect = semantic.Rect;
pub const Role = semantic.Role;
pub const SemanticNode = semantic.SemanticNode;
pub const SemanticTree = semantic.SemanticTree;
pub const Range = semantic.Range;
