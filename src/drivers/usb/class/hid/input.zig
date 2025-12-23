// HID Input Processing and Mapping
//
// Implements mapping from HID reports to kernel input events (keyboard/mouse).

const std = @import("std");
const console = @import("console");
const keyboard = @import("keyboard");
const mouse = @import("mouse");
const types = @import("types.zig");
const descriptor = @import("descriptor.zig");

// =============================================================================
// Data Extraction (Security Patched)
// =============================================================================

/// Extract a field value from a report buffer at bit-level precision
/// Security: Validates bit_offset and bit_size from untrusted device data
/// to prevent out-of-bounds reads and integer overflows.
pub fn extractFieldValue(data: []const u8, field: *const descriptor.HidField) i32 {
    // Security: Validate bit_size is reasonable (max 32 bits for u32)
    if (field.bit_size == 0 or field.bit_size > 32) return 0;

    // Security: Use safe cast for byte offset calculation
    const byte_offset = std.math.cast(usize, field.bit_offset / 8) orelse return 0;
    const bit_shift: u5 = @truncate(field.bit_offset % 8);

    if (byte_offset >= data.len) return 0;

    // Calculate bytes needed to cover the field
    const bits_in_first_byte = 8 - @as(u8, bit_shift);
    const remaining_bits = if (field.bit_size > bits_in_first_byte)
        field.bit_size - bits_in_first_byte
    else
        0;
    const bytes_needed = 1 + (remaining_bits + 7) / 8;

    // Security: Limit bytes_needed to prevent reading too far
    const safe_bytes_needed = @min(bytes_needed, 4); // Max 4 bytes for u32

    // Read bytes (little-endian)
    var raw: u32 = 0;
    var byte_idx: usize = 0;
    while (byte_idx < safe_bytes_needed) : (byte_idx += 1) {
        // Security: Check bounds before each access
        const access_offset = std.math.add(usize, byte_offset, byte_idx) catch break;
        if (access_offset >= data.len) break;
        raw |= @as(u32, data[access_offset]) << @intCast(byte_idx * 8);
    }

    // Shift and mask to extract the field
    raw >>= bit_shift;
    const mask: u32 = if (field.bit_size >= 32) 0xFFFFFFFF else (@as(u32, 1) << @intCast(field.bit_size)) - 1;
    raw &= mask;

    // Sign-extend if logical_min is negative (indicating signed values)
    if (field.logical_min < 0 and field.bit_size > 0 and field.bit_size < 32) {
        const sign_bit: u32 = @as(u32, 1) << @intCast(field.bit_size - 1);
        if (raw & sign_bit != 0) {
            raw |= ~mask; // Sign extend
        }
    }

    return @bitCast(raw);
}

// =============================================================================
// Scaling Helpers
// =============================================================================

/// Scale a value from logical range to screen coordinates
/// Security: Uses i64 arithmetic to prevent overflow from malicious device descriptors (Vuln 2)
pub fn scaleToScreen(value: i32, logical_min: i32, logical_max: i32, screen_size: u32) u32 {
    // Security: Widen to i64 before subtraction to prevent overflow
    // (e.g., INT32_MAX - INT32_MIN would overflow i32 but not i64)
    const range_i64 = @as(i64, logical_max) - @as(i64, logical_min);
    if (range_i64 <= 0) return 0;

    // Security: Also widen normalized calculation
    const normalized_i64 = @as(i64, value) - @as(i64, logical_min);
    if (normalized_i64 < 0) return 0;

    // Safe cast: range_i64 is positive and normalized_i64 is non-negative
    const normalized: u64 = @intCast(normalized_i64);
    const range: u64 = @intCast(range_i64);

    const scaled = normalized * @as(u64, screen_size) / range;
    return @intCast(@min(scaled, screen_size - 1));
}

// =============================================================================
// Input Injection
// =============================================================================

pub fn injectMod(scancode: u8, pressed: bool, extended: bool) void {
    if (extended) keyboard.injectScancode(0xE0);
    keyboard.injectScancode(if (pressed) scancode else scancode | 0x80);
}

// =============================================================================
// Scancode Mapping
// =============================================================================

pub const Scancode = struct {
    code: u8,
    extended: bool = false,
};

/// Map USB Usage ID to PS/2 Scancode (Set 1)
/// Only covers common keys
pub fn mapUsbToScancode(usage: u8) ?Scancode {
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
