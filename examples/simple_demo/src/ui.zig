// Simple UI components for canvas-rendered game UI
const std = @import("std");
const sw = @import("sw_app");

/// Color type for UI elements
pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,

    pub const white = Color{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 };
    pub const gray = Color{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 1.0 };
    pub const dark_gray = Color{ .r = 0.3, .g = 0.3, .b = 0.3, .a = 1.0 };
    pub const light_gray = Color{ .r = 0.7, .g = 0.7, .b = 0.7, .a = 1.0 };
    pub const accent = Color{ .r = 0.2, .g = 0.8, .b = 0.4, .a = 1.0 };
};

/// Horizontal slider component
pub const Slider = struct {
    // Layout
    x: f32,
    y: f32,
    width: f32,
    height: f32,

    // State
    value: f32, // 0.0 - 1.0
    dragging: bool,

    // Appearance
    track_color: Color,
    fill_color: Color,
    handle_color: Color,
    handle_radius: f32,

    pub fn init(x: f32, y: f32, width: f32, height: f32) Slider {
        return .{
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .value = 0.5,
            .dragging = false,
            .track_color = Color.dark_gray,
            .fill_color = Color.accent,
            .handle_color = Color.white,
            .handle_radius = 10,
        };
    }

    /// Handle mouse input. Returns true if value changed.
    pub fn handleMouse(self: *Slider, mouse_x: f32, mouse_y: f32, mouse_down: bool) bool {
        const old_value = self.value;

        // Expand hit area vertically for easier interaction
        const hit_padding: f32 = 15;
        const in_bounds = mouse_x >= self.x and mouse_x <= self.x + self.width and
            mouse_y >= self.y - hit_padding and mouse_y <= self.y + self.height + hit_padding;

        // Start dragging on click within bounds
        if (mouse_down and in_bounds and !self.dragging) {
            self.dragging = true;
        }

        // Stop dragging when mouse released
        if (!mouse_down) {
            self.dragging = false;
        }

        // Update value while dragging
        if (self.dragging) {
            const normalized = (mouse_x - self.x) / self.width;
            self.value = std.math.clamp(normalized, 0.0, 1.0);
        }

        return self.value != old_value;
    }

    /// Draw the slider using GPU context
    pub fn draw(self: *const Slider, gpu: *sw.gpu_types.GPU) void {
        const track_height: f32 = 6;
        const track_y = self.y + (self.height - track_height) / 2;

        // Draw track background (rounded rect)
        gpu.drawRoundedRect(
            self.x,
            track_y,
            self.width,
            track_height,
            track_height / 2,
            self.track_color.r,
            self.track_color.g,
            self.track_color.b,
            self.track_color.a,
        );

        // Draw filled portion
        const fill_width = self.width * self.value;
        if (fill_width > 0) {
            gpu.drawRoundedRect(
                self.x,
                track_y,
                fill_width,
                track_height,
                track_height / 2,
                self.fill_color.r,
                self.fill_color.g,
                self.fill_color.b,
                self.fill_color.a,
            );
        }

        // Draw handle (circle at current value position)
        const handle_x = self.x + fill_width;
        const handle_y = self.y + self.height / 2;

        // Handle glow when dragging
        if (self.dragging) {
            gpu.drawFilledCircle(
                handle_x,
                handle_y,
                self.handle_radius + 4,
                self.fill_color.r,
                self.fill_color.g,
                self.fill_color.b,
                0.3,
            );
        }

        // Handle circle
        gpu.drawFilledCircle(
            handle_x,
            handle_y,
            self.handle_radius,
            self.handle_color.r,
            self.handle_color.g,
            self.handle_color.b,
            self.handle_color.a,
        );
    }

    /// Set position (for responsive layout)
    pub fn setPosition(self: *Slider, x: f32, y: f32) void {
        self.x = x;
        self.y = y;
    }
};
