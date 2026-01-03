//! VMware SVGA Hardware Cursor
//!
//! Implements hardware cursor support for the VMware SVGA II driver.
//! Supports both legacy monochrome and ARGB alpha cursors.

const std = @import("std");
const hw = @import("hardware.zig");
const fifo = @import("fifo.zig");
const caps = @import("caps.zig");

/// Hardware cursor manager
pub const HardwareCursor = struct {
    /// Register write function (from driver)
    write_reg: *const fn (hw.Registers, u32) void,
    /// FIFO manager for cursor commands
    fifo_mgr: *fifo.FifoManager,
    /// Device capabilities
    capabilities: caps.Capabilities,

    /// Current cursor state
    enabled: bool = false,
    visible: bool = false,
    current_id: u32 = 0,
    x: u32 = 0,
    y: u32 = 0,
    hotspot_x: u16 = 0,
    hotspot_y: u16 = 0,

    /// Screen dimensions for bounds checking
    screen_width: u32 = 0,
    screen_height: u32 = 0,

    const Self = @This();

    /// Initialize hardware cursor
    pub fn init(
        write_reg: *const fn (hw.Registers, u32) void,
        fifo_mgr: *fifo.FifoManager,
        capabilities: caps.Capabilities,
    ) Self {
        return .{
            .write_reg = write_reg,
            .fifo_mgr = fifo_mgr,
            .capabilities = capabilities,
            .enabled = capabilities.hasHardwareCursor(),
        };
    }

    /// Check if hardware cursor is available
    pub fn isAvailable(self: *const Self) bool {
        return self.enabled;
    }

    /// Check if alpha cursor (ARGB) is available
    pub fn hasAlphaSupport(self: *const Self) bool {
        return self.capabilities.hasAlphaCursor();
    }

    /// Update screen dimensions (call when mode changes)
    pub fn setScreenSize(self: *Self, width: u32, height: u32) void {
        self.screen_width = width;
        self.screen_height = height;
    }

    /// Define an ARGB alpha cursor
    /// pixels: ARGB8888 pixel data (width * height u32s)
    /// Returns true on success
    pub fn defineAlphaCursor(
        self: *Self,
        id: u32,
        width: u16,
        height: u16,
        hotspot_x: u16,
        hotspot_y: u16,
        pixels: []const u32,
    ) bool {
        if (!self.enabled) return false;
        if (!self.hasAlphaSupport()) return false;

        // Validate dimensions
        if (width == 0 or height == 0) return false;
        if (width > hw.MAX_CURSOR_WIDTH or height > hw.MAX_CURSOR_HEIGHT) return false;

        // Validate hotspot is within cursor bounds
        if (hotspot_x >= width or hotspot_y >= height) return false;

        // Validate pixel buffer size
        const pixel_count = std.math.mul(u32, width, height) catch return false;
        if (pixels.len < pixel_count) return false;

        // Write cursor definition to FIFO
        if (!self.fifo_mgr.writeDefineAlphaCursor(
            id,
            hotspot_x,
            hotspot_y,
            width,
            height,
            pixels,
        )) {
            return false;
        }

        // Update state
        self.current_id = id;
        self.hotspot_x = hotspot_x;
        self.hotspot_y = hotspot_y;

        return true;
    }

    /// Define a simple colored cursor (solid color square)
    /// Useful as a fallback when alpha cursor is not available
    pub fn defineSimpleCursor(
        self: *Self,
        id: u32,
        size: u8,
        color: u32,
    ) bool {
        if (!self.enabled) return false;

        const safe_size: u16 = if (size > 32) 32 else size;
        const pixel_count: u32 = @as(u32, safe_size) * @as(u32, safe_size);

        // Allocate temporary buffer for cursor pixels
        var pixels: [32 * 32]u32 = undefined;
        @memset(pixels[0..pixel_count], color);

        return self.defineAlphaCursor(
            id,
            safe_size,
            safe_size,
            0,
            0,
            pixels[0..pixel_count],
        );
    }

    /// Define a standard arrow cursor
    pub fn defineArrowCursor(self: *Self, id: u32) bool {
        if (!self.enabled) return false;

        // 16x16 arrow cursor (simplified)
        const width: u16 = 16;
        const height: u16 = 16;

        // Arrow cursor bitmap (1 = white, 0 = transparent)
        // First pixel is hotspot
        const arrow_mask = [_]u16{
            0b1000000000000000,
            0b1100000000000000,
            0b1110000000000000,
            0b1111000000000000,
            0b1111100000000000,
            0b1111110000000000,
            0b1111111000000000,
            0b1111111100000000,
            0b1111111110000000,
            0b1111100000000000,
            0b1101100000000000,
            0b1000110000000000,
            0b0000110000000000,
            0b0000011000000000,
            0b0000011000000000,
            0b0000000000000000,
        };

        // Border mask (black outline)
        const border_mask = [_]u16{
            0b0100000000000000,
            0b0010000000000000,
            0b0001000000000000,
            0b0000100000000000,
            0b0000010000000000,
            0b0000001000000000,
            0b0000000100000000,
            0b0000000010000000,
            0b0000000001000000,
            0b0000011110000000,
            0b0010010000000000,
            0b0111001000000000,
            0b0000001000000000,
            0b0000100100000000,
            0b0000100100000000,
            0b0000011000000000,
        };

        var pixels: [16 * 16]u32 = undefined;

        for (0..16) |y| {
            const arrow_row = arrow_mask[y];
            const border_row = border_mask[y];

            for (0..16) |x| {
                const bit: u4 = @intCast(15 - x);
                const idx = y * 16 + x;

                if ((arrow_row >> bit) & 1 != 0) {
                    // White fill with full opacity
                    pixels[idx] = 0xFFFFFFFF;
                } else if ((border_row >> bit) & 1 != 0) {
                    // Black border with full opacity
                    pixels[idx] = 0xFF000000;
                } else {
                    // Transparent
                    pixels[idx] = 0x00000000;
                }
            }
        }

        return self.defineAlphaCursor(id, width, height, 0, 0, &pixels);
    }

    /// Set cursor position (screen coordinates)
    pub fn setPosition(self: *Self, x: u32, y: u32) void {
        if (!self.enabled) return;

        // Clamp to screen bounds (allow negative via wrapping for partial visibility)
        const clamped_x = if (self.screen_width > 0 and x > self.screen_width + hw.MAX_CURSOR_WIDTH)
            0
        else
            x;

        const clamped_y = if (self.screen_height > 0 and y > self.screen_height + hw.MAX_CURSOR_HEIGHT)
            0
        else
            y;

        self.x = clamped_x;
        self.y = clamped_y;

        // Update hardware registers
        self.write_reg(.CURSOR_X, clamped_x);
        self.write_reg(.CURSOR_Y, clamped_y);
    }

    /// Move cursor by delta
    pub fn moveBy(self: *Self, dx: i32, dy: i32) void {
        const new_x = @as(i64, self.x) + dx;
        const new_y = @as(i64, self.y) + dy;

        // Clamp to valid range
        const clamped_x: u32 = if (new_x < 0) 0 else @intCast(@min(new_x, 0xFFFFFFFF));
        const clamped_y: u32 = if (new_y < 0) 0 else @intCast(@min(new_y, 0xFFFFFFFF));

        self.setPosition(clamped_x, clamped_y);
    }

    /// Get current cursor position
    pub fn getPosition(self: *const Self) struct { x: u32, y: u32 } {
        return .{ .x = self.x, .y = self.y };
    }

    /// Show cursor
    pub fn show(self: *Self) void {
        if (!self.enabled) return;

        self.visible = true;
        self.write_reg(.CURSOR_ON, self.current_id);
    }

    /// Hide cursor
    pub fn hide(self: *Self) void {
        if (!self.enabled) return;

        self.visible = false;
        self.write_reg(.CURSOR_ON, 0);
    }

    /// Set cursor visibility
    pub fn setVisible(self: *Self, visible: bool) void {
        if (visible) {
            self.show();
        } else {
            self.hide();
        }
    }

    /// Check if cursor is currently visible
    pub fn isVisible(self: *const Self) bool {
        return self.visible;
    }

    /// Switch to a different cursor by ID
    /// The cursor must have been previously defined
    pub fn setCursor(self: *Self, id: u32) void {
        if (!self.enabled) return;

        self.current_id = id;
        if (self.visible) {
            self.write_reg(.CURSOR_ON, id);
        }
    }
};

/// Standard cursor IDs
pub const CursorId = enum(u32) {
    arrow = 0,
    ibeam = 1,
    wait = 2,
    crosshair = 3,
    hand = 4,
    resize_ns = 5,
    resize_ew = 6,
    resize_nwse = 7,
    resize_nesw = 8,
    move = 9,
    not_allowed = 10,
    user_base = 100, // User-defined cursors start here
};

/// Callback type for cursor position updates
pub const CursorPositionCallback = *const fn (x: u32, y: u32) void;

/// Global cursor position callback (for VMMouse integration)
var cursor_callback: ?CursorPositionCallback = null;

/// Register a callback for cursor position updates
pub fn registerCursorCallback(callback: CursorPositionCallback) void {
    cursor_callback = callback;
}

/// Unregister cursor callback
pub fn unregisterCursorCallback() void {
    cursor_callback = null;
}

/// Notify callback of cursor position change
pub fn notifyCursorPosition(x: u32, y: u32) void {
    if (cursor_callback) |cb| {
        cb(x, y);
    }
}
