// USB HID Class Driver
//
// Implements support for Human Interface Devices (HID) class 0x03.
// Handles parsing of HID descriptors and mapping input events to
// the kernel's input subsystem (keyboard/mouse).
//
// Reference: Device Class Definition for HID 1.11

const std = @import("std");
const console = @import("console");
const usb = @import("../root.zig");
const keyboard = @import("../../keyboard.zig");
const mouse = @import("../../mouse.zig");

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

    // Note: There can be more descriptor type/length pairs if b_num_descriptors > 1
    // but the struct is fixed size here for the common case.

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

const ItemType = enum(u2) {
    main = 0,
    global = 1,
    local = 2,
    reserved = 3,
};

const MainItem = enum(u4) {
    input = 0x8,
    output = 0x9,
    feature = 0xB,
    collection = 0xA,
    end_collection = 0xC,
};

const GlobalItem = enum(u4) {
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

const LocalItem = enum(u4) {
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

const UsagePage = struct {
    pub const GENERIC_DESKTOP: u16 = 0x01;
    pub const KEYBOARD: u16 = 0x07;
    pub const LEDS: u16 = 0x08;
    pub const BUTTON: u16 = 0x09;
};

const UsageGeneric = struct {
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
// HID Driver Logic
// =============================================================================

pub const HidDriver = struct {
    is_keyboard: bool = false,
    is_mouse: bool = false,
    interface_num: u8 = 0,
    in_endpoint: u8 = 0,
    out_endpoint: ?u8 = null,
    packet_size: u16 = 0,

    // Keyboard state
    prev_modifiers: u8 = 0,
    prev_keys: [6]u8 = .{ 0, 0, 0, 0, 0, 0 },

    const Self = @This();

    /// Initialize descriptor parsing
    pub fn parseReportDescriptor(self: *Self, data: []const u8) !void {
        var i: usize = 0;

        // Very basic parser state to detect device type
        var current_usage_page: u16 = 0;
        var current_usage: u16 = 0;
        var in_collection = false;

        console.debug("HID: Parsing {} byte report descriptor", .{data.len});

        while (i < data.len) {
            const header = data[i];
            i += 1;

            if (header == 0xFE) { // Long item
                if (i + 2 > data.len) break;
                const len = data[i];
                i += 1 + 2 + len; // Skip tag, size, data
                continue;
            }

            const tag = (header >> 4) & 0x0F;
            const type = (header >> 2) & 0x03;
            const size_code = header & 0x03;

            const size: usize = switch (size_code) {
                0 => 0,
                1 => 1,
                2 => 2,
                3 => 4,
                else => 0,
            };

            if (i + size > data.len) break;

            var value: u32 = 0;
            if (size > 0) {
                value = data[i];
                if (size >= 2) value |= (@as(u32, data[i + 1]) << 8);
                if (size >= 4) value |= (@as(u32, data[i + 2]) << 16) | (@as(u32, data[i + 3]) << 24);
                i += size;
            }

            // Detect usage
            if (type == @intFromEnum(ItemType.global)) {
                if (tag == @intFromEnum(GlobalItem.usage_page)) {
                    current_usage_page = @truncate(value);
                }
            } else if (type == @intFromEnum(ItemType.local)) {
                if (tag == @intFromEnum(LocalItem.usage)) {
                    current_usage = @truncate(value);

                    // Check for top-level usage
                    if (!in_collection) {
                        if (current_usage_page == UsagePage.GENERIC_DESKTOP) {
                            if (current_usage == UsageGeneric.KEYBOARD) {
                                self.is_keyboard = true;
                                console.info("HID: Detected Keyboard", .{});
                            } else if (current_usage == UsageGeneric.MOUSE) {
                                self.is_mouse = true;
                                console.info("HID: Detected Mouse", .{});
                            }
                        }
                    }
                }
            } else if (type == @intFromEnum(ItemType.main)) {
                if (tag == @intFromEnum(MainItem.collection)) {
                    in_collection = true;
                } else if (tag == @intFromEnum(MainItem.end_collection)) {
                    in_collection = false;
                }
            }
        }
    }

    /// Handle an incoming input report
    /// Assumes Boot Protocol format for simplicity if device is identified as kb/mouse
    pub fn handleInputReport(self: *Self, data: []const u8) void {
        if (self.is_keyboard) {
            self.handleKeyboardReport(data);
        } else if (self.is_mouse) {
            self.handleMouseReport(data);
        }
    }

    /// Handle Boot Protocol Keyboard Report
    /// Format: [Mods, Reserved, Key1, Key2, Key3, Key4, Key5, Key6]
    fn handleKeyboardReport(self: *Self, data: []const u8) void {
        if (data.len < 8) return;

        const modifiers = data[0];
        // data[1] is reserved
        const keys = data[2..8];

        // 1. Handle Modifier changes
        // Modifiers are handled by the keyboard driver via scancodes usually,
        // but here we get a bitmask.
        // We can simulate scancodes for modifiers.
        // Left Ctrl: 0x01 -> Scancode 0x1D
        // Left Shift: 0x02 -> Scancode 0x2A
        // Left Alt: 0x04 -> Scancode 0x38
        // Left GUI: 0x08 -> Scancode 0xE0 0x5B (Windows)
        // Right Ctrl: 0x10 -> Scancode 0xE0 0x1D
        // Right Shift: 0x20 -> Scancode 0x36
        // Right Alt: 0x40 -> Scancode 0xE0 0x38
        // Right GUI: 0x80 -> Scancode 0xE0 0x5C

        const mod_diff = modifiers ^ self.prev_modifiers;
        if (mod_diff != 0) {
            if (mod_diff & 0x01 != 0) injectMod(0x1D, (modifiers & 0x01) != 0, false);
            if (mod_diff & 0x02 != 0) injectMod(0x2A, (modifiers & 0x02) != 0, false);
            if (mod_diff & 0x04 != 0) injectMod(0x38, (modifiers & 0x04) != 0, false);
            // GUI keys skipped for simplicity or need extended
            if (mod_diff & 0x10 != 0) injectMod(0x1D, (modifiers & 0x10) != 0, true);
            if (mod_diff & 0x20 != 0) injectMod(0x36, (modifiers & 0x20) != 0, false);
            if (mod_diff & 0x40 != 0) injectMod(0x38, (modifiers & 0x40) != 0, true);
        }
        self.prev_modifiers = modifiers;

        // 2. Handle Key presses/releases
        // We compare current keys against previous keys
        // Simple approach: Check what's new (pressed) and what's gone (released)

        // Check for Rollover error (all 1s)
        if (keys[0] == 0x01) return;

        // Check for releases
        for (self.prev_keys) |prev| {
            if (prev == 0) continue;
            var found = false;
            for (keys) |curr| {
                if (curr == prev) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                // Key released
                if (mapUsbToScancode(prev)) |sc| {
                    if (sc.extended) keyboard.injectScancode(0xE0);
                    keyboard.injectScancode(sc.code | 0x80); // Break code
                }
            }
        }

        // Check for presses
        for (keys) |curr| {
            if (curr == 0) continue;
            var found = false;
            for (self.prev_keys) |prev| {
                if (prev == curr) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                // Key pressed
                if (mapUsbToScancode(curr)) |sc| {
                    if (sc.extended) keyboard.injectScancode(0xE0);
                    keyboard.injectScancode(sc.code);
                }
            }
        }

        @memcpy(&self.prev_keys, keys);
    }

    /// Handle Boot Protocol Mouse Report
    /// Format: [Buttons, X, Y, (Optional Wheel)]
    fn handleMouseReport(self: *Self, data: []const u8) void {
        if (data.len < 3) return;

        const buttons_raw = data[0];
        const x_raw = @as(i8, @bitCast(data[1]));
        const y_raw = @as(i8, @bitCast(data[2]));

        var z_raw: i8 = 0;
        if (data.len >= 4) {
            z_raw = @as(i8, @bitCast(data[3]));
        }

        const buttons = mouse.Buttons{
            .left = (buttons_raw & 0x01) != 0,
            .right = (buttons_raw & 0x02) != 0,
            .middle = (buttons_raw & 0x04) != 0,
        };

        // USB coordinates: Right positive, Down positive.
        // PS/2 coordinates: Right positive, Up positive.
        // Mouse driver expects: Positive = Up (standard convention logic in driver).
        // Wait, mouse.zig says:
        // "Y is inverted so positive = up (standard convention)"
        // "dy: i16 = if ((flags & 0x20) != 0) 256 - packet[2] else -packet[2]"
        // The driver flips PS/2 Y.
        // Here we just pass raw delta. If USB gives Down positive, and we want Up positive, we negate Y.

        mouse.injectRawInput(x_raw, -y_raw, z_raw, buttons);
    }
};

fn injectMod(scancode: u8, pressed: bool, extended: bool) void {
    if (extended) keyboard.injectScancode(0xE0);
    keyboard.injectScancode(if (pressed) scancode else scancode | 0x80);
}

const Scancode = struct {
    code: u8,
    extended: bool = false,
};

/// Map USB Usage ID to PS/2 Scancode (Set 1)
/// Only covers common keys
fn mapUsbToScancode(usage: u8) ?Scancode {
    return switch (usage) {
        0x04 => .{ .code = 0x1E }, // A
        0x05 => .{ .code = 0x30 }, // B
        0x06 => .{ .code = 0x2E }, // C
        0x07 => .{ .code = 0x20 }, // D
        0x08 => .{ .code = 0x12 }, // E
        0x09 => .{ .code = 0x21 }, // F
        0x0A => .{ .code = 0x22 }, // G
        0x0B => .{ .code = 0x23 }, // H
        0x0C => .{ .code = 0x17 }, // I
        0x0D => .{ .code = 0x24 }, // J
        0x0E => .{ .code = 0x25 }, // K
        0x0F => .{ .code = 0x26 }, // L
        0x10 => .{ .code = 0x32 }, // M
        0x11 => .{ .code = 0x31 }, // N
        0x12 => .{ .code = 0x18 }, // O
        0x13 => .{ .code = 0x19 }, // P
        0x14 => .{ .code = 0x10 }, // Q
        0x15 => .{ .code = 0x13 }, // R
        0x16 => .{ .code = 0x1F }, // S
        0x17 => .{ .code = 0x14 }, // T
        0x18 => .{ .code = 0x16 }, // U
        0x19 => .{ .code = 0x2F }, // V
        0x1A => .{ .code = 0x11 }, // W
        0x1B => .{ .code = 0x2D }, // X
        0x1C => .{ .code = 0x15 }, // Y
        0x1D => .{ .code = 0x2C }, // Z

        0x1E => .{ .code = 0x02 }, // 1
        0x1F => .{ .code = 0x03 }, // 2
        0x20 => .{ .code = 0x04 }, // 3
        0x21 => .{ .code = 0x05 }, // 4
        0x22 => .{ .code = 0x06 }, // 5
        0x23 => .{ .code = 0x07 }, // 6
        0x24 => .{ .code = 0x08 }, // 7
        0x25 => .{ .code = 0x09 }, // 8
        0x26 => .{ .code = 0x0A }, // 9
        0x27 => .{ .code = 0x0B }, // 0

        0x28 => .{ .code = 0x1C }, // Enter
        0x29 => .{ .code = 0x01 }, // Esc
        0x2A => .{ .code = 0x0E }, // Backspace
        0x2B => .{ .code = 0x0F }, // Tab
        0x2C => .{ .code = 0x39 }, // Space

        0x2D => .{ .code = 0x0C }, // -
        0x2E => .{ .code = 0x0D }, // =
        0x2F => .{ .code = 0x1A }, // [
        0x30 => .{ .code = 0x1B }, // ]
        0x31 => .{ .code = 0x2B }, // \
        0x33 => .{ .code = 0x27 }, // ;
        0x34 => .{ .code = 0x28 }, // '
        0x35 => .{ .code = 0x29 }, // `
        0x36 => .{ .code = 0x33 }, // ,
        0x37 => .{ .code = 0x34 }, // .
        0x38 => .{ .code = 0x35 }, // /

        0x39 => .{ .code = 0x3A }, // CapsLock

        0x3A => .{ .code = 0x3B }, // F1
        0x3B => .{ .code = 0x3C }, // F2
        0x3C => .{ .code = 0x3D }, // F3
        0x3D => .{ .code = 0x3E }, // F4
        0x3E => .{ .code = 0x3F }, // F5
        0x3F => .{ .code = 0x40 }, // F6
        0x40 => .{ .code = 0x41 }, // F7
        0x41 => .{ .code = 0x42 }, // F8
        0x42 => .{ .code = 0x43 }, // F9
        0x43 => .{ .code = 0x44 }, // F10
        0x44 => .{ .code = 0x57 }, // F11
        0x45 => .{ .code = 0x58 }, // F12

        0x49 => .{ .code = 0x52, .extended = true }, // Insert
        0x4A => .{ .code = 0x47, .extended = true }, // Home
        0x4B => .{ .code = 0x49, .extended = true }, // PageUp
        0x4C => .{ .code = 0x53, .extended = true }, // Delete
        0x4D => .{ .code = 0x4F, .extended = true }, // End
        0x4E => .{ .code = 0x51, .extended = true }, // PageDown
        0x4F => .{ .code = 0x4D, .extended = true }, // Right
        0x50 => .{ .code = 0x4B, .extended = true }, // Left
        0x51 => .{ .code = 0x50, .extended = true }, // Down
        0x52 => .{ .code = 0x48, .extended = true }, // Up

        else => null,
    };
}
