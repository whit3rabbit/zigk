// Internal libc utilities - not exported to C API
//
// Shared helper functions used across libc modules.
// These are internal implementation details and should not be
// exported or used directly by user programs.

// =============================================================================
// Debug Configuration
// =============================================================================

const builtin = @import("builtin");

extern fn zscapek_memcpy(dest: [*]u8, src: [*]const u8, n: usize) callconv(.c) [*]u8;
extern fn zscapek_memset(dest: [*]u8, value: u8, n: usize) callconv(.c) [*]u8;

/// Debug mode heap checks - compiles out in release
pub const DEBUG_HEAP = builtin.mode == .Debug;

/// Magic number for valid allocated blocks
pub const HEAP_MAGIC: u32 = 0xDEADBEEF;

/// Magic number for freed blocks (double-free detection)
pub const FREED_MAGIC: u32 = 0xFEEDFACE;

// =============================================================================
// Safe Memory Operations (Recursion-Safe)
// =============================================================================

/// Inline-safe memory copy - NEVER uses @memcpy to avoid recursion.
/// In freestanding mode, Zig may lower @memcpy to a call to memcpy,
/// which causes infinite recursion if memcpy itself uses @memcpy.
pub inline fn safeCopy(dest: [*]u8, src: [*]const u8, n: usize) void {
    if (n == 0) return;
    if (builtin.cpu.arch == .x86_64 and n >= @sizeOf(usize)) {
        _ = zscapek_memcpy(dest, src, n);
        return;
    }

    for (0..n) |i| {
        dest[i] = src[i];
    }
}

/// Inline-safe memory fill - NEVER uses @memset to avoid recursion.
/// Same rationale as safeCopy.
pub inline fn safeFill(dest: [*]u8, value: u8, n: usize) void {
    if (n == 0) return;
    if (builtin.cpu.arch == .x86_64 and n >= @sizeOf(usize)) {
        _ = zscapek_memset(dest, value, n);
        return;
    }

    for (0..n) |i| {
        dest[i] = value;
    }
}

/// Debug-mode bounds check for memory operations
pub inline fn debugBoundsCheck(len: usize, max: usize) void {
    if (DEBUG_HEAP and len > max) {
        @panic("libc: buffer overflow detected");
    }
}

/// Convert uppercase ASCII letter to lowercase
pub fn toLowerInternal(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

/// Convert lowercase ASCII letter to uppercase
pub fn toUpperInternal(c: u8) u8 {
    return if (c >= 'a' and c <= 'z') c - 32 else c;
}

/// Checked addition for allocation sizes
/// Returns null if overflow would occur
pub fn checkedAdd(a: usize, b: usize) ?usize {
    const result = @addWithOverflow(a, b);
    return if (result[1] == 0) result[0] else null;
}

/// Checked multiplication for allocation sizes
/// Returns null if overflow would occur
pub fn checkedMultiply(a: usize, b: usize) ?usize {
    const result = @mulWithOverflow(a, b);
    return if (result[1] == 0) result[0] else null;
}

/// Align size up to 16-byte boundary
pub fn alignTo16(size: usize) usize {
    return (size + 15) & ~@as(usize, 15);
}

/// Check if a character is a whitespace character
pub fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c;
}

/// Check if a character is a decimal digit
pub fn isDecDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Check if a character is a hexadecimal digit
pub fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'A' and c <= 'F') or (c >= 'a' and c <= 'f');
}

/// Convert a hex digit character to its numeric value
pub fn hexDigitValue(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    return null;
}
