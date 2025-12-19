// String operations (string.h)
//
// Basic null-terminated string functions.

const std = @import("std");

/// Get length of null-terminated string
pub export fn strlen(s: ?[*:0]const u8) usize {
    if (s == null) return 0;
    return std.mem.len(s.?);
}

/// Get length of string, bounded by maxlen
pub export fn strnlen(s: ?[*:0]const u8, maxlen: usize) usize {
    if (s == null) return 0;

    const str = s.?;
    var i: usize = 0;
    while (i < maxlen and str[i] != 0) : (i += 1) {}
    return i;
}

/// Compare two null-terminated strings
pub export fn strcmp(s1: ?[*:0]const u8, s2: ?[*:0]const u8) c_int {
    if (s1 == null and s2 == null) return 0;
    if (s1 == null) return -1;
    if (s2 == null) return 1;

    var p1 = s1.?;
    var p2 = s2.?;

    while (p1[0] != 0 and p2[0] != 0 and p1[0] == p2[0]) {
        p1 += 1;
        p2 += 1;
    }

    return @as(c_int, p1[0]) - @as(c_int, p2[0]);
}

/// Compare at most n characters of two strings
pub export fn strncmp(s1: ?[*:0]const u8, s2: ?[*:0]const u8, n: usize) c_int {
    if (n == 0) return 0;
    if (s1 == null and s2 == null) return 0;
    if (s1 == null) return -1;
    if (s2 == null) return 1;

    var p1 = s1.?;
    var p2 = s2.?;
    var i: usize = 0;

    while (i < n and p1[0] != 0 and p2[0] != 0 and p1[0] == p2[0]) {
        p1 += 1;
        p2 += 1;
        i += 1;
    }

    if (i == n) return 0;
    return @as(c_int, p1[0]) - @as(c_int, p2[0]);
}

/// Copy null-terminated string from src to dest
/// SECURITY WARNING: UNSAFE - No bounds checking. Buffer overflow risk!
/// This function is a common source of security vulnerabilities.
/// REQUIRED: Use strlcpy() instead for all new code.
pub export fn strcpy(dest: ?[*:0]u8, src: ?[*:0]const u8) ?[*:0]u8 {
    if (dest == null or src == null) return dest;

    var d = dest.?;
    var s = src.?;

    while (s[0] != 0) {
        d[0] = s[0];
        d += 1;
        s += 1;
    }
    d[0] = 0;
    return dest;
}

/// Copy at most n characters from src to dest
/// Pads with null bytes if src is shorter than n
pub export fn strncpy(dest: ?[*]u8, src: ?[*:0]const u8, n: usize) ?[*]u8 {
    if (dest == null or src == null) return dest;

    var d = dest.?;
    var s = src.?;
    var i: usize = 0;

    // Copy from src while not at null and within limit
    while (i < n and s[0] != 0) {
        d[i] = s[0];
        s += 1;
        i += 1;
    }

    // Pad remainder with null bytes
    while (i < n) {
        d[i] = 0;
        i += 1;
    }

    return dest;
}

/// Copy at most n-1 characters, always null-terminate
/// Returns total length of src (for truncation detection)
pub export fn strlcpy(dest: ?[*]u8, src: ?[*:0]const u8, n: usize) usize {
    if (src == null) return 0;
    if (dest == null or n == 0) return strlen(src);

    const d = dest.?;
    var s = src.?;
    var i: usize = 0;

    // Copy at most n-1 characters
    while (i < n - 1 and s[0] != 0) {
        d[i] = s[0];
        s += 1;
        i += 1;
    }

    // Always null-terminate if n > 0
    if (n > 0) {
        d[i] = 0;
    }

    // Return total length of src
    while (s[0] != 0) {
        s += 1;
        i += 1;
    }

    return i;
}
