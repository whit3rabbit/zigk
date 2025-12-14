// Cursor Position Manager
//
// Tracks absolute cursor position with bounds clamping.
// Supports both relative (mouse delta) and absolute (tablet) input.
//
// Features:
//   - Absolute position tracking within screen bounds
//   - Relative delta application with sensitivity scaling
//   - Absolute input normalization from tablet coordinates
//   - Thread-safe via external locking (caller's responsibility)

const std = @import("std");

// =============================================================================
// CursorManager
// =============================================================================

/// Manages cursor position with bounds clamping
pub const CursorManager = struct {
    /// Current X position (0 to width-1)
    x: i32 = 0,
    /// Current Y position (0 to height-1)
    y: i32 = 0,
    /// Screen width in pixels
    width: u32 = 1920,
    /// Screen height in pixels
    height: u32 = 1080,
    /// Sensitivity multiplier for relative movement (fixed-point: 256 = 1.0)
    sensitivity: u16 = 256,
    /// Accumulated fractional movement (for sub-pixel precision)
    frac_x: i16 = 0,
    frac_y: i16 = 0,

    const Self = @This();

    /// Default cursor manager with HD resolution
    pub const default: Self = .{};

    /// Initialize with specific screen dimensions
    pub fn init(width: u32, height: u32) Self {
        return .{
            .x = 0,
            .y = 0,
            .width = width,
            .height = height,
            .sensitivity = 256,
            .frac_x = 0,
            .frac_y = 0,
        };
    }

    /// Apply relative movement (from mouse deltas)
    /// dx/dy are raw device units, positive X = right, positive Y = up
    pub fn applyDelta(self: *Self, dx: i16, dy: i16) void {
        // Apply sensitivity (fixed-point multiplication)
        // sensitivity 256 = 1.0x, 512 = 2.0x, 128 = 0.5x
        const scaled_dx = (@as(i32, dx) * @as(i32, self.sensitivity)) + @as(i32, self.frac_x);
        const scaled_dy = (@as(i32, dy) * @as(i32, self.sensitivity)) + @as(i32, self.frac_y);

        // Extract integer and fractional parts
        const int_dx = @divTrunc(scaled_dx, 256);
        const int_dy = @divTrunc(scaled_dy, 256);
        self.frac_x = @truncate(@rem(scaled_dx, 256));
        self.frac_y = @truncate(@rem(scaled_dy, 256));

        // Apply movement with clamping
        self.x = clampPosition(self.x + int_dx, self.width);
        // Note: Y is typically inverted (positive dy = cursor moves up = y decreases)
        // The PS/2 driver already handles this inversion, so we subtract here
        self.y = clampPosition(self.y - int_dy, self.height);
    }

    /// Set absolute position from tablet coordinates
    /// Scales from device coordinate space to screen space
    /// abs_x/abs_y: device coordinates (0 to max_x/max_y)
    /// max_x/max_y: maximum device coordinates (e.g., 32767 for USB tablets)
    pub fn setAbsolute(self: *Self, abs_x: u32, abs_y: u32, max_x: u32, max_y: u32) void {
        if (max_x == 0 or max_y == 0) return;

        // Scale device coordinates to screen coordinates
        // Use u64 to avoid overflow in multiplication
        self.x = @intCast((@as(u64, abs_x) * @as(u64, self.width)) / @as(u64, max_x));
        self.y = @intCast((@as(u64, abs_y) * @as(u64, self.height)) / @as(u64, max_y));

        // Clamp to valid range
        self.x = clampPosition(self.x, self.width);
        self.y = clampPosition(self.y, self.height);

        // Clear fractional accumulator on absolute positioning
        self.frac_x = 0;
        self.frac_y = 0;
    }

    /// Set absolute position directly (already in screen coordinates)
    pub fn setPosition(self: *Self, x: i32, y: i32) void {
        self.x = clampPosition(x, self.width);
        self.y = clampPosition(y, self.height);
        self.frac_x = 0;
        self.frac_y = 0;
    }

    /// Get current position
    pub fn getPosition(self: *const Self) struct { x: i32, y: i32 } {
        return .{ .x = self.x, .y = self.y };
    }

    /// Set screen bounds
    /// Cursor will be clamped to new bounds if outside
    pub fn setBounds(self: *Self, width: u32, height: u32) void {
        if (width == 0 or height == 0) return;

        self.width = width;
        self.height = height;

        // Clamp current position to new bounds
        self.x = clampPosition(self.x, width);
        self.y = clampPosition(self.y, height);
    }

    /// Set sensitivity multiplier
    /// 256 = 1.0x (default), 512 = 2.0x, 128 = 0.5x
    pub fn setSensitivity(self: *Self, sensitivity: u16) void {
        self.sensitivity = if (sensitivity == 0) 256 else sensitivity;
    }

    /// Center cursor on screen
    pub fn center(self: *Self) void {
        self.x = @intCast(self.width / 2);
        self.y = @intCast(self.height / 2);
        self.frac_x = 0;
        self.frac_y = 0;
    }

    /// Check if position is at screen edge
    pub fn isAtEdge(self: *const Self) struct { left: bool, right: bool, top: bool, bottom: bool } {
        return .{
            .left = self.x == 0,
            .right = self.x >= @as(i32, @intCast(self.width)) - 1,
            .top = self.y == 0,
            .bottom = self.y >= @as(i32, @intCast(self.height)) - 1,
        };
    }
};

// =============================================================================
// Helper Functions
// =============================================================================

/// Clamp position to valid range [0, dimension-1]
fn clampPosition(pos: i32, dimension: u32) i32 {
    const max_pos: i32 = @intCast(dimension -| 1);
    return std.math.clamp(pos, 0, max_pos);
}

// =============================================================================
// Unit Tests
// =============================================================================

test "CursorManager basic movement" {
    var cursor = CursorManager.init(100, 100);

    // Start at origin
    try std.testing.expectEqual(@as(i32, 0), cursor.x);
    try std.testing.expectEqual(@as(i32, 0), cursor.y);

    // Move right and down (negative dy = down because of inversion)
    cursor.applyDelta(10, -10);
    try std.testing.expectEqual(@as(i32, 10), cursor.x);
    try std.testing.expectEqual(@as(i32, 10), cursor.y);
}

test "CursorManager bounds clamping" {
    var cursor = CursorManager.init(100, 100);
    cursor.setPosition(50, 50);

    // Try to move past right edge
    cursor.applyDelta(100, 0);
    try std.testing.expectEqual(@as(i32, 99), cursor.x);

    // Try to move past left edge
    cursor.applyDelta(-200, 0);
    try std.testing.expectEqual(@as(i32, 0), cursor.x);
}

test "CursorManager absolute positioning" {
    var cursor = CursorManager.init(1920, 1080);

    // Set to center using tablet coordinates (0-32767)
    cursor.setAbsolute(16384, 16384, 32768, 32768);
    try std.testing.expectEqual(@as(i32, 960), cursor.x);
    try std.testing.expectEqual(@as(i32, 540), cursor.y);
}

test "CursorManager sensitivity" {
    var cursor = CursorManager.init(1000, 1000);
    cursor.setPosition(500, 500);

    // Default sensitivity (1.0x)
    cursor.applyDelta(10, 0);
    try std.testing.expectEqual(@as(i32, 510), cursor.x);

    // Double sensitivity (2.0x)
    cursor.setSensitivity(512);
    cursor.applyDelta(10, 0);
    try std.testing.expectEqual(@as(i32, 530), cursor.x);
}

test "CursorManager center" {
    var cursor = CursorManager.init(1920, 1080);
    cursor.center();
    try std.testing.expectEqual(@as(i32, 960), cursor.x);
    try std.testing.expectEqual(@as(i32, 540), cursor.y);
}
