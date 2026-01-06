// VirtIO-Input Configuration Structures and Constants
//
// Defines the wire format structures and constants for VirtIO-Input devices.
// All structures are designed to match the VirtIO 1.1 specification exactly.
//
// Reference: VirtIO Specification 1.1, Section 5.8

const std = @import("std");

// =============================================================================
// PCI Device Identification
// =============================================================================

/// VirtIO vendor ID
pub const PCI_VENDOR_VIRTIO: u16 = 0x1AF4;

/// VirtIO-Input device ID (modern, non-transitional)
/// Formula: 0x1040 + device_type, where device_type = 18 for input
pub const PCI_DEVICE_INPUT: u16 = 0x1052;

// =============================================================================
// Queue Configuration
// =============================================================================

/// Queue indices for VirtIO-Input
pub const QueueIndex = struct {
    /// Event queue (device -> driver): Input events from device
    pub const EVENTS: u16 = 0;
    /// Status queue (driver -> device): LED updates, etc.
    pub const STATUS: u16 = 1;
};

/// Number of pre-allocated event buffers
pub const EVENT_BUFFER_COUNT: usize = 64;

// =============================================================================
// Configuration Space Select Values
// =============================================================================

/// Configuration space select values (write to config.select)
pub const ConfigSelect = struct {
    /// Unset - no configuration selected
    pub const UNSET: u8 = 0x00;
    /// Device name (string, up to 128 bytes)
    pub const ID_NAME: u8 = 0x01;
    /// Device serial number (string)
    pub const ID_SERIAL: u8 = 0x02;
    /// Device IDs (bustype, vendor, product, version)
    pub const ID_DEVIDS: u8 = 0x03;
    /// Input device property bits
    pub const PROP_BITS: u8 = 0x10;
    /// Event type capability bits (subsel = event type)
    pub const EV_BITS: u8 = 0x11;
    /// Absolute axis info (subsel = axis code)
    pub const ABS_INFO: u8 = 0x12;
};

// =============================================================================
// Event Types (matches Linux input.h)
// =============================================================================

/// Event type constants
pub const EventType = struct {
    /// Synchronization event - marks end of an event packet
    pub const EV_SYN: u16 = 0x00;
    /// Key/button event
    pub const EV_KEY: u16 = 0x01;
    /// Relative axis movement (mouse dx/dy)
    pub const EV_REL: u16 = 0x02;
    /// Absolute axis position (tablet x/y)
    pub const EV_ABS: u16 = 0x03;
    /// Miscellaneous event
    pub const EV_MSC: u16 = 0x04;
    /// Switch event
    pub const EV_SW: u16 = 0x05;
    /// LED event
    pub const EV_LED: u16 = 0x11;
    /// Sound event
    pub const EV_SND: u16 = 0x12;
    /// Autorepeat event
    pub const EV_REP: u16 = 0x14;
};

// =============================================================================
// Wire Format Structures
// =============================================================================

/// VirtIO-Input event structure (8 bytes)
/// This is the wire format received from the device
pub const VirtioInputEvent = extern struct {
    /// Event type (EV_KEY, EV_REL, EV_ABS, EV_SYN, etc.)
    type: u16,
    /// Event code (KEY_*, REL_*, ABS_*, etc.)
    code: u16,
    /// Event value (delta for relative, position for absolute, 0/1 for buttons)
    value: i32,

    comptime {
        if (@sizeOf(@This()) != 8) @compileError("VirtioInputEvent must be 8 bytes");
    }
};

/// VirtIO-Input device configuration space (136 bytes total)
/// Accessed via the device-specific capability BAR
pub const VirtioInputConfig = extern struct {
    /// Configuration selector (write to query different data)
    select: u8,
    /// Sub-selection (e.g., event type for EV_BITS, axis code for ABS_INFO)
    subsel: u8,
    /// Size of returned data in the union (read after setting select/subsel)
    size: u8,
    /// Reserved, must be zero
    _reserved: [5]u8,
    /// Union data (interpretation depends on select value)
    u: [128]u8,

    comptime {
        if (@sizeOf(@This()) != 136) @compileError("VirtioInputConfig must be 136 bytes");
    }
};

/// Device identification structure (returned via ID_DEVIDS)
pub const VirtioInputDevIds = extern struct {
    /// Bus type (BUS_USB, BUS_VIRTUAL, etc.)
    bustype: u16,
    /// Vendor ID
    vendor: u16,
    /// Product ID
    product: u16,
    /// Device version
    version: u16,

    comptime {
        if (@sizeOf(@This()) != 8) @compileError("VirtioInputDevIds must be 8 bytes");
    }
};

/// Absolute axis information (returned via ABS_INFO)
pub const VirtioInputAbsInfo = extern struct {
    /// Minimum value for this axis
    min: i32,
    /// Maximum value for this axis
    max: i32,
    /// Fuzz value (noise threshold)
    fuzz: i32,
    /// Flat value (dead zone)
    flat: i32,
    /// Resolution (units per mm, or 0 if unknown)
    res: i32,

    comptime {
        if (@sizeOf(@This()) != 20) @compileError("VirtioInputAbsInfo must be 20 bytes");
    }

    /// Calculate the range of this axis
    pub fn range(self: VirtioInputAbsInfo) i32 {
        return self.max - self.min;
    }
};

// =============================================================================
// Bus Types (from Linux input.h)
// =============================================================================

pub const BusType = struct {
    pub const PCI: u16 = 0x01;
    pub const ISAPNP: u16 = 0x02;
    pub const USB: u16 = 0x03;
    pub const HIL: u16 = 0x04;
    pub const BLUETOOTH: u16 = 0x05;
    pub const VIRTUAL: u16 = 0x06;
};

// =============================================================================
// LED Codes (for status queue)
// =============================================================================

pub const LedCode = struct {
    pub const NUML: u16 = 0x00;
    pub const CAPSL: u16 = 0x01;
    pub const SCROLLL: u16 = 0x02;
    pub const COMPOSE: u16 = 0x03;
    pub const KANA: u16 = 0x04;
};

// =============================================================================
// Unit Tests
// =============================================================================

test "VirtioInputEvent size" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(VirtioInputEvent));
}

test "VirtioInputConfig size" {
    try std.testing.expectEqual(@as(usize, 136), @sizeOf(VirtioInputConfig));
}

test "VirtioInputDevIds size" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(VirtioInputDevIds));
}

test "VirtioInputAbsInfo size" {
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(VirtioInputAbsInfo));
}

test "VirtioInputAbsInfo range" {
    const info = VirtioInputAbsInfo{
        .min = -32768,
        .max = 32767,
        .fuzz = 0,
        .flat = 0,
        .res = 0,
    };
    try std.testing.expectEqual(@as(i32, 65535), info.range());
}
