// Internal libc utilities - not exported to C API
//
// Shared helper functions used across libc modules.
// These are internal implementation details and should not be
// exported or used directly by user programs.

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
