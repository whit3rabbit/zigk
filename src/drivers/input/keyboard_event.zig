//! Keyboard Event Types
//!
//! Public type definitions for keyboard events.
//! Provides a rich tagged union for type-safe key event handling.

// =============================================================================
// KeyEvent Tagged Union
// =============================================================================

/// Rich key event type providing type-safe access to different key categories
/// Inspired by Linux input subsystem but using Zig tagged unions
pub const KeyEvent = union(enum) {
    /// Printable ASCII character
    char: u8,
    /// Control keys (Escape, Backspace, Tab, Enter, Delete)
    control: ControlKey,
    /// Navigation keys (arrows, Home, End, Page Up/Down, Insert)
    navigation: NavigationKey,
    /// Function keys (F1-F12)
    function: FunctionKey,
    /// Modifier key state change
    modifier: ModifierEvent,

    pub const ControlKey = enum(u8) {
        escape = 0x1B,
        backspace = 0x08,
        tab = '\t',
        enter = '\n',
        delete = 0x7F,
    };

    pub const NavigationKey = enum(u8) {
        up = 0x80,
        down = 0x81,
        left = 0x82,
        right = 0x83,
        home = 0x84,
        end = 0x85,
        page_up = 0x86,
        page_down = 0x87,
        insert = 0x88,
    };

    pub const FunctionKey = enum(u4) {
        f1 = 1,
        f2 = 2,
        f3 = 3,
        f4 = 4,
        f5 = 5,
        f6 = 6,
        f7 = 7,
        f8 = 8,
        f9 = 9,
        f10 = 10,
        f11 = 11,
        f12 = 12,
    };

    pub const ModifierEvent = struct {
        key: ModifierKey,
        pressed: bool,
    };

    pub const ModifierKey = enum {
        shift_left,
        shift_right,
        ctrl,
        alt,
        caps_lock,
    };

    /// Convert to shell-compatible ASCII byte (for backward compatibility)
    /// Returns null for events that don't have ASCII representation
    pub fn toAscii(self: KeyEvent) ?u8 {
        return switch (self) {
            .char => |c| c,
            .control => |ctrl| @intFromEnum(ctrl),
            .navigation => |nav| @intFromEnum(nav),
            .function => null,
            .modifier => null,
        };
    }

    /// Check if this is a printable character
    pub fn isPrintable(self: KeyEvent) bool {
        return switch (self) {
            .char => true,
            else => false,
        };
    }
};

// =============================================================================
// Error Statistics
// =============================================================================

/// Error statistics for debugging hardware issues
pub const ErrorStats = struct {
    parity_errors: u32 = 0,
    timeout_errors: u32 = 0,
    spurious_irqs: u32 = 0,
    buffer_overruns: u32 = 0,
};

// =============================================================================
// Unit Tests
// =============================================================================

test "KeyEvent toAscii" {
    const std = @import("std");

    const char_event = KeyEvent{ .char = 'x' };
    try std.testing.expectEqual(@as(?u8, 'x'), char_event.toAscii());

    const ctrl_event = KeyEvent{ .control = .escape };
    try std.testing.expectEqual(@as(?u8, 0x1B), ctrl_event.toAscii());

    const nav_event = KeyEvent{ .navigation = .up };
    try std.testing.expectEqual(@as(?u8, 0x80), nav_event.toAscii());

    const func_event = KeyEvent{ .function = .f1 };
    try std.testing.expectEqual(@as(?u8, null), func_event.toAscii());
}
