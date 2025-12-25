// AArch64 Architecture Memory Operations
//
// Provides optimized versions of memory fill and copy.

const std = @import("std");

pub fn init() void {}

/// Memory fill (memset equivalent)
pub fn fill(dest: [*]u8, val: u8, count: usize) void {
    @memset(dest[0..count], val);
}

/// Memory copy (memcpy equivalent)
pub fn copy(dest: [*]u8, src: [*]const u8, count: usize) void {
    @memcpy(dest[0..count], src[0..count]);
}
