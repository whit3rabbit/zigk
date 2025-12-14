// String concatenation operations (string.h)
//
// Functions for combining and duplicating strings.

const std = @import("std");

/// Concatenate src onto end of dest
/// WARNING: UNSAFE - No bounds checking on destination buffer.
/// Use strlcat() instead for safer bounded concatenation.
pub export fn strcat(dest: ?[*:0]u8, src: ?[*:0]const u8) ?[*:0]u8 {
    if (dest == null or src == null) return dest;

    var d = dest.?;
    const s = src.?;

    // Find end of dest
    while (d[0] != 0) d += 1;

    // Copy src
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {
        d[i] = s[i];
    }
    d[i] = 0;

    return dest;
}

/// Concatenate at most n characters from src onto dest
pub export fn strncat(dest: ?[*:0]u8, src: ?[*:0]const u8, n: usize) ?[*:0]u8 {
    if (dest == null or src == null) return dest;

    var d = dest.?;
    const s = src.?;

    // Find end of dest
    while (d[0] != 0) d += 1;

    // Copy at most n chars from src
    var i: usize = 0;
    while (i < n and s[i] != 0) : (i += 1) {
        d[i] = s[i];
    }
    d[i] = 0;

    return dest;
}

/// Concatenate at most n-1 characters, always null-terminate
/// Returns total length that would have been copied
pub export fn strlcat(dest: ?[*]u8, src: ?[*:0]const u8, n: usize) usize {
    if (src == null) return 0;
    if (dest == null or n == 0) return 0;

    const d = dest.?;
    const s = src.?;

    // Find length of dest (bounded by n)
    var dest_len: usize = 0;
    while (dest_len < n and d[dest_len] != 0) : (dest_len += 1) {}

    // If dest fills buffer, return n + src length
    if (dest_len >= n) {
        return n + std.mem.len(s);
    }

    // Copy src to end of dest
    var i: usize = 0;
    while (dest_len + i < n - 1 and s[i] != 0) {
        d[dest_len + i] = s[i];
        i += 1;
    }

    d[dest_len + i] = 0;

    // Return would-be total length
    return dest_len + std.mem.len(s);
}

// strdup is defined in root.zig since it depends on malloc from memory module
