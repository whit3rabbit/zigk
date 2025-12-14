// String search operations (string.h)
//
// Functions for searching within strings.

const std = @import("std");

/// Find first occurrence of character c in string s
pub export fn strchr(s: ?[*:0]const u8, c: c_int) ?[*:0]u8 {
    if (s == null) return null;

    var p = s.?;
    const ch: u8 = @truncate(@as(c_uint, @bitCast(c)));

    while (true) {
        if (p[0] == ch) return @ptrCast(@constCast(p));
        if (p[0] == 0) return null;
        p += 1;
    }
}

/// Find last occurrence of character c in string s
pub export fn strrchr(s: ?[*:0]const u8, c: c_int) ?[*:0]u8 {
    if (s == null) return null;

    const str = s.?;
    const ch: u8 = @truncate(@as(c_uint, @bitCast(c)));

    var last: ?[*:0]u8 = null;
    var i: usize = 0;

    while (true) {
        if (str[i] == ch) {
            last = @ptrCast(@constCast(str + i));
        }
        if (str[i] == 0) break;
        i += 1;
    }

    return last;
}

/// Find first occurrence of needle in haystack
/// SECURITY FIX: Properly bounds the search to prevent out-of-bounds reads
pub export fn strstr(haystack: ?[*:0]const u8, needle: ?[*:0]const u8) ?[*:0]u8 {
    if (haystack == null or needle == null) return null;

    const h = haystack.?;
    const n = needle.?;

    // Empty needle matches at beginning
    if (n[0] == 0) return @ptrCast(@constCast(h));

    const needle_len = std.mem.len(n);
    const haystack_len = std.mem.len(h);

    // SECURITY FIX: Cannot find needle longer than haystack
    if (needle_len > haystack_len) return null;

    // SECURITY FIX: Bound the search to prevent reading past haystack end
    const max_start = haystack_len - needle_len;
    var i: usize = 0;

    while (i <= max_start) : (i += 1) {
        var match = true;
        var j: usize = 0;

        while (j < needle_len) : (j += 1) {
            if (h[i + j] != n[j]) {
                match = false;
                break;
            }
        }

        if (match) return @ptrCast(@constCast(h + i));
    }

    return null;
}

/// Find first occurrence of any character from accept in s
pub export fn strpbrk(s: ?[*:0]const u8, accept: ?[*:0]const u8) ?[*:0]u8 {
    if (s == null or accept == null) return null;

    var p = s.?;
    const a = accept.?;

    while (p[0] != 0) {
        var i: usize = 0;
        while (a[i] != 0) : (i += 1) {
            if (p[0] == a[i]) {
                return @ptrCast(@constCast(p));
            }
        }
        p += 1;
    }

    return null;
}

/// Count initial characters in s that are in accept
pub export fn strspn(s: ?[*:0]const u8, accept: ?[*:0]const u8) usize {
    if (s == null or accept == null) return 0;

    const str = s.?;
    const acc = accept.?;
    var count: usize = 0;

    outer: while (str[count] != 0) {
        var i: usize = 0;
        while (acc[i] != 0) : (i += 1) {
            if (str[count] == acc[i]) {
                count += 1;
                continue :outer;
            }
        }
        break;
    }

    return count;
}

/// Count initial characters in s that are NOT in reject
pub export fn strcspn(s: ?[*:0]const u8, reject: ?[*:0]const u8) usize {
    if (s == null) return 0;
    if (reject == null) return std.mem.len(s.?);

    const str = s.?;
    const rej = reject.?;
    var count: usize = 0;

    while (str[count] != 0) {
        var i: usize = 0;
        while (rej[i] != 0) : (i += 1) {
            if (str[count] == rej[i]) {
                return count;
            }
        }
        count += 1;
    }

    return count;
}
