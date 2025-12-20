// USB HID Class Driver Types and Constants
//
// Reference: Device Class Definition for HID 1.11

const std = @import("std");

// =============================================================================
// HID Descriptors
// =============================================================================

/// HID Descriptor (after Interface Descriptor)
pub const HidDescriptor = packed struct {
    b_length: u8,
    b_descriptor_type: u8, // 0x21
    bcd_hid: u16,
    b_country_code: u8,
    b_num_descriptors: u8,
    b_class_descriptor_type: u8, // 0x22 (Report)
    w_class_descriptor_length: u16,

    comptime {
        if (@sizeOf(@This()) != 9) @compileError("HidDescriptor must be 9 bytes");
    }
};

// =============================================================================
// HID Request Codes
// =============================================================================

pub const Request = struct {
    pub const GET_REPORT: u8 = 0x01;
    pub const GET_IDLE: u8 = 0x02;
    pub const GET_PROTOCOL: u8 = 0x03;
    pub const SET_REPORT: u8 = 0x09;
    pub const SET_IDLE: u8 = 0x0A;
    pub const SET_PROTOCOL: u8 = 0x0B;
};

pub const Protocol = struct {
    pub const BOOT: u8 = 0;
    pub const REPORT: u8 = 1;
};

// =============================================================================
// HID Report Item Tags
// =============================================================================

pub const ItemType = enum(u2) {
    main = 0,
    global = 1,
    local = 2,
    reserved = 3,
};

pub const MainItem = enum(u4) {
    input = 0x8,
    output = 0x9,
    feature = 0xB,
    collection = 0xA,
    end_collection = 0xC,
};

pub const GlobalItem = enum(u4) {
    usage_page = 0x0,
    logical_min = 0x1,
    logical_max = 0x2,
    physical_min = 0x3,
    physical_max = 0x4,
    unit_exponent = 0x5,
    unit = 0x6,
    report_size = 0x7,
    report_id = 0x8,
    report_count = 0x9,
    push = 0xA,
    pop = 0xB,
};

pub const LocalItem = enum(u4) {
    usage = 0x0,
    usage_min = 0x1,
    usage_max = 0x2,
    designator_index = 0x3,
    designator_min = 0x4,
    designator_max = 0x5,
    string_index = 0x7,
    string_min = 0x8,
    string_max = 0x9,
    delimiter = 0xA,
};

// =============================================================================
// Usage Pages and IDs
// =============================================================================

pub const UsagePage = struct {
    pub const GENERIC_DESKTOP: u16 = 0x01;
    pub const KEYBOARD: u16 = 0x07;
    pub const LEDS: u16 = 0x08;
    pub const BUTTON: u16 = 0x09;
    pub const DIGITIZER: u16 = 0x0D;
};

pub const UsageDigitizer = struct {
    pub const DIGITIZER: u16 = 0x01;
    pub const PEN: u16 = 0x02;
    pub const TOUCH_SCREEN: u16 = 0x04;
    pub const TOUCH_PAD: u16 = 0x05;
    pub const FINGER: u16 = 0x22;
    pub const TIP_PRESSURE: u16 = 0x30;
    pub const IN_RANGE: u16 = 0x32;
    pub const TOUCH: u16 = 0x33;
    pub const TIP_SWITCH: u16 = 0x42;
    pub const BARREL_SWITCH: u16 = 0x44;
    pub const ERASER: u16 = 0x45;
    pub const CONFIDENCE: u16 = 0x47;
    pub const CONTACT_ID: u16 = 0x51;
    pub const CONTACT_COUNT: u16 = 0x54;
    pub const TILT_X: u16 = 0x3D;
    pub const TILT_Y: u16 = 0x3E;
};

pub const UsageGeneric = struct {
    pub const POINTER: u16 = 0x01;
    pub const MOUSE: u16 = 0x02;
    pub const JOYSTICK: u16 = 0x04;
    pub const GAMEPAD: u16 = 0x05;
    pub const KEYBOARD: u16 = 0x06;
    pub const KEYPAD: u16 = 0x07;
    pub const X: u16 = 0x30;
    pub const Y: u16 = 0x31;
    pub const Z: u16 = 0x32;
    pub const WHEEL: u16 = 0x38;
};

// =============================================================================
// HID Report Descriptor Parser Constants
// =============================================================================

pub const MAX_FIELDS: usize = 32;
pub const MAX_USAGES: usize = 64;
pub const MAX_GLOBAL_STACK: usize = 4;
pub const MAX_REPORTS: usize = 4;
