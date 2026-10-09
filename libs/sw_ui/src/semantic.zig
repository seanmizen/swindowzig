//! The semantic tree: what assistive technology needs to know about the UI.
//! It is plain data with no pointer to the UI. A backend (for example the web
//! screen-reader mirror) reads it each frame and does not need the layout or
//! the drawing code.
//!
//! The tree is a flat array in tree order. `nodes[0]` is the root.
//! `children` holds indices into `nodes`.

/// A rectangle in logical pixels. (x, y) is the top left corner.
pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn contains(self: Rect, px: f32, py: f32) bool {
        return px >= self.x and px < self.x + self.w and py >= self.y and py < self.y + self.h;
    }
};

/// What a node is, for assistive technology. The names follow the ARIA roles
/// that a web mirror would use.
pub const Role = enum {
    /// A row or a column. The name is the label of the group, or empty.
    group,
    /// Text. The name is the text.
    text,
    /// A button. The name is its label.
    button,
    /// A list. The name is the label of the list.
    list,
    /// An item of a list. The name is its label.
    list_item,
    /// A text field. The name is its label and the value is its text.
    text_field,
    /// An image. The name is its description.
    image,
};

pub const SemanticNode = struct {
    /// The ID that the app gave the node. The root has `root_id` (0).
    id: u32,
    role: Role,
    /// The accessible name. It points into memory that the app gave to the UI
    /// and is valid until the next `Ui.begin`.
    name: []const u8,
    /// The value of a text field. Empty for other roles.
    value: []const u8,
    focused: bool,
    disabled: bool,
    /// A list item that the app marked as selected.
    selected: bool,
    /// The node is a live region: assistive technology announces a change of
    /// its text.
    live: bool,
    /// A live region whose text is not the text of the last frame. Always
    /// false for a node that is not live, and for the first frame of a node.
    changed: bool,
    bounds: Rect,
    /// Indices into `SemanticTree.nodes`, in tree order.
    children: []const u32,
};

pub const SemanticTree = struct {
    nodes: []const SemanticNode,

    /// The node with this app ID, or null.
    pub fn find(self: SemanticTree, id: u32) ?*const SemanticNode {
        for (self.nodes) |*n| {
            if (n.id == id) return n;
        }
        return null;
    }

    /// The node that has focus, or null.
    pub fn focusedNode(self: SemanticTree) ?*const SemanticNode {
        for (self.nodes) |*n| {
            if (n.focused) return n;
        }
        return null;
    }
};
