// AArch64 Architecture Memory Operations
//
// Provides optimized versions of memory fill and copy.
//
// SECURITY: These are low-level primitives that do NOT validate buffer sizes.
// Callers MUST ensure that:
//   1. dest/src pointers are valid kernel memory addresses
//   2. count does not exceed the actual buffer allocation
//   3. src and dest do not overlap (for copy operations)
//
// Prefer using the slice-based variants (fillSlice, copySlice) when possible,
// as they make buffer bounds explicit and prevent common size mismatches.

const std = @import("std");

pub fn init() void {}

/// Memory fill (memset equivalent) - UNSAFE: caller must validate count
/// SAFETY: Caller must ensure dest points to at least `count` bytes of valid memory.
/// Prefer fillSlice() for bounds-safe operations.
pub fn fill(dest: [*]u8, val: u8, count: usize) void {
    @memset(dest[0..count], val);
}

/// Memory copy (memcpy equivalent) - UNSAFE: caller must validate count
/// SAFETY: Caller must ensure dest and src each point to at least `count` bytes
/// of valid memory, and that the regions do not overlap.
/// Prefer copySlice() for bounds-safe operations.
pub fn copy(dest: [*]u8, src: [*]const u8, count: usize) void {
    @memcpy(dest[0..count], src[0..count]);
}

/// Memory fill with explicit slice bounds - SAFE
/// The slice length is the authoritative size, preventing buffer overruns.
pub fn fillSlice(dest: []u8, val: u8) void {
    @memset(dest, val);
}

/// Memory copy with explicit slice bounds - SAFE
/// Copies min(dest.len, src.len) bytes. Returns number of bytes copied.
pub fn copySlice(dest: []u8, src: []const u8) usize {
    const len = @min(dest.len, src.len);
    @memcpy(dest[0..len], src[0..len]);
    return len;
}

/// Zero memory region - SAFE slice-based variant
pub fn zeroSlice(dest: []u8) void {
    @memset(dest, 0);
}
