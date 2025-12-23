// Input Event ABI Definitions
//
// Unified input event format for userspace consumption.
// Compatible with Linux struct input_event layout where practical.
//
// Reference: Linux include/uapi/linux/input-event-codes.h

// =============================================================================
// Event Types
// =============================================================================

/// Event type enumeration (matches Linux EV_* values)
pub const EventType = enum(u16) {
    /// Synchronization event - marks end of a set of events
    EV_SYN = 0x00,
    /// Key/button press event
    EV_KEY = 0x01,
    /// Relative axis movement (mouse dx/dy)
    EV_REL = 0x02,
    /// Absolute axis position (tablet x/y)
    EV_ABS = 0x03,
    /// Miscellaneous events
    EV_MSC = 0x04,
    _,
};

// =============================================================================
// Event Codes - Relative Axes
// =============================================================================

/// Relative axis codes (REL_*)
pub const RelCode = struct {
    pub const X: u16 = 0x00;
    pub const Y: u16 = 0x01;
    pub const Z: u16 = 0x02;
    pub const RX: u16 = 0x03;
    pub const RY: u16 = 0x04;
    pub const RZ: u16 = 0x05;
    pub const HWHEEL: u16 = 0x06;
    pub const DIAL: u16 = 0x07;
    pub const WHEEL: u16 = 0x08;
    pub const MISC: u16 = 0x09;
    pub const WHEEL_HI_RES: u16 = 0x0B;
    pub const HWHEEL_HI_RES: u16 = 0x0C;
};

// =============================================================================
// Event Codes - Absolute Axes
// =============================================================================

/// Absolute axis codes (ABS_*)
pub const AbsCode = struct {
    pub const X: u16 = 0x00;
    pub const Y: u16 = 0x01;
    pub const Z: u16 = 0x02;
    pub const RX: u16 = 0x03;
    pub const RY: u16 = 0x04;
    pub const RZ: u16 = 0x05;
    pub const THROTTLE: u16 = 0x06;
    pub const RUDDER: u16 = 0x07;
    pub const WHEEL: u16 = 0x08;
    pub const GAS: u16 = 0x09;
    pub const BRAKE: u16 = 0x0A;
    pub const PRESSURE: u16 = 0x18;
    pub const DISTANCE: u16 = 0x19;
    pub const TILT_X: u16 = 0x1A;
    pub const TILT_Y: u16 = 0x1B;
};

// =============================================================================
// Event Codes - Buttons/Keys
// =============================================================================

/// Button codes for mouse (BTN_*)
/// Linux uses 0x110-0x11F for mouse buttons
pub const BtnCode = struct {
    pub const MOUSE: u16 = 0x110;
    pub const LEFT: u16 = 0x110;
    pub const RIGHT: u16 = 0x111;
    pub const MIDDLE: u16 = 0x112;
    pub const SIDE: u16 = 0x113;
    pub const EXTRA: u16 = 0x114;
    pub const FORWARD: u16 = 0x115;
    pub const BACK: u16 = 0x116;
    pub const TASK: u16 = 0x117;
};

// =============================================================================
// Synchronization Codes
// =============================================================================

/// Synchronization codes (SYN_*)
pub const SynCode = struct {
    pub const REPORT: u16 = 0;
    pub const CONFIG: u16 = 1;
    pub const MT_REPORT: u16 = 2;
    pub const DROPPED: u16 = 3;
};

// =============================================================================
// Input Event Structure
// =============================================================================

/// Unified input event for userspace consumption
/// Layout is ABI-stable for syscall interface
pub const InputEvent = extern struct {
    /// Event timestamp (nanoseconds since boot)
    timestamp_ns: u64,
    /// Event type (EV_REL, EV_ABS, EV_KEY, etc.)
    event_type: EventType,
    /// Event code (REL_X, ABS_X, BTN_LEFT, etc.)
    code: u16,
    /// Event value (delta for relative, position for absolute, 0/1 for buttons)
    value: i32,
    /// Input device identifier (assigned by kernel)
    device_id: u16,
    /// Reserved for future extensions
    _reserved: u16 = 0,

    comptime {
        // Verify struct is 24 bytes (expected ABI)
        if (@sizeOf(@This()) != 24) @compileError("InputEvent must be 24 bytes");
    }

    /// Create a relative movement event
    pub fn rel(code: u16, value: i32) InputEvent {
        return .{
            .timestamp_ns = 0, // Caller should set timestamp
            .event_type = .EV_REL,
            .code = code,
            .value = value,
            .device_id = 0,
            ._reserved = 0,
        };
    }

    /// Create an absolute position event
    pub fn abs(code: u16, value: i32) InputEvent {
        return .{
            .timestamp_ns = 0,
            .event_type = .EV_ABS,
            .code = code,
            .value = value,
            .device_id = 0,
            ._reserved = 0,
        };
    }

    /// Create a button event
    pub fn button(code: u16, pressed: bool) InputEvent {
        return .{
            .timestamp_ns = 0,
            .event_type = .EV_KEY,
            .code = code,
            .value = if (pressed) 1 else 0,
            .device_id = 0,
            ._reserved = 0,
        };
    }

    /// Create a synchronization event
    pub fn sync() InputEvent {
        return .{
            .timestamp_ns = 0,
            .event_type = .EV_SYN,
            .code = SynCode.REPORT,
            .value = 0,
            .device_id = 0,
            ._reserved = 0,
        };
    }
};

// =============================================================================
// Cursor Position (for sys_get_cursor_position)
// =============================================================================

/// Current cursor position and button state
/// Returned by sys_get_cursor_position syscall
pub const CursorPosition = extern struct {
    /// Absolute X position (0 to width-1)
    x: i32,
    /// Absolute Y position (0 to height-1)
    y: i32,
    /// Button state bitmask
    /// Bit 0: left, Bit 1: right, Bit 2: middle
    buttons: u8,
    /// Reserved for alignment and future use
    _reserved: [3]u8 = .{ 0, 0, 0 },

    comptime {
        if (@sizeOf(@This()) != 12) @compileError("CursorPosition must be 12 bytes");
    }

    pub fn isLeftPressed(self: CursorPosition) bool {
        return (self.buttons & 0x01) != 0;
    }

    pub fn isRightPressed(self: CursorPosition) bool {
        return (self.buttons & 0x02) != 0;
    }

    pub fn isMiddlePressed(self: CursorPosition) bool {
        return (self.buttons & 0x04) != 0;
    }
};

// =============================================================================
// Cursor Bounds (for sys_set_cursor_bounds)
// =============================================================================

/// Screen dimensions for cursor clamping
/// Used by sys_set_cursor_bounds syscall
pub const CursorBounds = extern struct {
    /// Screen width in pixels
    width: u32,
    /// Screen height in pixels
    height: u32,

    comptime {
        if (@sizeOf(@This()) != 8) @compileError("CursorBounds must be 8 bytes");
    }
};

// =============================================================================
// Input Mode
// =============================================================================

/// Input mode for sys_set_input_mode
pub const InputMode = enum(u32) {
    /// Relative mode - events contain deltas
    relative = 0,
    /// Absolute mode - events contain absolute positions
    absolute = 1,
    /// Raw mode - no cursor tracking, just raw events
    raw = 2,
};

// =============================================================================
// Device Capabilities
// =============================================================================

/// Input device capability flags
pub const Capabilities = packed struct(u32) {
    /// Device supports relative movement
    has_rel: bool = false,
    /// Device supports absolute positioning
    has_abs: bool = false,
    /// Device has left button
    has_left: bool = false,
    /// Device has right button
    has_right: bool = false,
    /// Device has middle button
    has_middle: bool = false,
    /// Device has scroll wheel
    has_wheel: bool = false,
    /// Device has horizontal scroll
    has_hwheel: bool = false,
    /// Device has extra buttons (side, forward, back)
    has_extra_buttons: bool = false,
    _reserved: u24 = 0,
};

// =============================================================================
// Unit Tests
// =============================================================================

test "InputEvent size" {
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(InputEvent));
}

test "CursorPosition size" {
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(CursorPosition));
}

test "CursorBounds size" {
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(CursorBounds));
}

test "InputEvent helpers" {
    const std = @import("std");
    const rel_event = InputEvent.rel(RelCode.X, 10);
    try std.testing.expectEqual(EventType.EV_REL, rel_event.event_type);
    try std.testing.expectEqual(RelCode.X, rel_event.code);
    try std.testing.expectEqual(@as(i32, 10), rel_event.value);

    const btn_event = InputEvent.button(BtnCode.LEFT, true);
    try std.testing.expectEqual(EventType.EV_KEY, btn_event.event_type);
    try std.testing.expectEqual(BtnCode.LEFT, btn_event.code);
    try std.testing.expectEqual(@as(i32, 1), btn_event.value);
}
