// Case-insensitive string operations (strings.h)
//
// Functions for case-insensitive string comparison.

const internal = @import("../internal.zig");

/// Compare two strings ignoring case
pub export fn strcasecmp(s1: ?[*:0]const u8, s2: ?[*:0]const u8) c_int {
    if (s1 == null and s2 == null) return 0;
    if (s1 == null) return -1;
    if (s2 == null) return 1;

    var p1 = s1.?;
    var p2 = s2.?;

    while (p1[0] != 0 and p2[0] != 0) {
        const c1 = internal.toLowerInternal(p1[0]);
        const c2 = internal.toLowerInternal(p2[0]);
        if (c1 != c2) return @as(c_int, c1) - @as(c_int, c2);
        p1 += 1;
        p2 += 1;
    }

    return @as(c_int, internal.toLowerInternal(p1[0])) - @as(c_int, internal.toLowerInternal(p2[0]));
}

/// Compare at most n characters of two strings ignoring case
pub export fn strncasecmp(s1: ?[*:0]const u8, s2: ?[*:0]const u8, n: usize) c_int {
    if (n == 0) return 0;
    if (s1 == null and s2 == null) return 0;
    if (s1 == null) return -1;
    if (s2 == null) return 1;

    var p1 = s1.?;
    var p2 = s2.?;
    var i: usize = 0;

    while (i < n and p1[0] != 0 and p2[0] != 0) {
        const c1 = internal.toLowerInternal(p1[0]);
        const c2 = internal.toLowerInternal(p2[0]);
        if (c1 != c2) return @as(c_int, c1) - @as(c_int, c2);
        p1 += 1;
        p2 += 1;
        i += 1;
    }

    if (i == n) return 0;
    return @as(c_int, internal.toLowerInternal(p1[0])) - @as(c_int, internal.toLowerInternal(p2[0]));
}

/// Alias for strcasecmp (BSD compatibility)
pub const stricmp = strcasecmp;

/// Alias for strncasecmp (BSD compatibility)
pub const strnicmp = strncasecmp;
