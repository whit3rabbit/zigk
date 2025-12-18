// Memory operations (string.h)
//
// Low-level memory manipulation functions.

const builtin = @import("builtin");
const internal = @import("../internal.zig");

/// Copy n bytes from src to dest (non-overlapping)
pub export fn memcpy(dest: ?*anyopaque, src: ?*const anyopaque, n: usize) ?*anyopaque {
    if (n == 0) return dest;
    if (dest == null or src == null) return dest;

    const d = @as([*]u8, @ptrCast(dest.?));
    const s = @as([*]const u8, @ptrCast(src.?));

    internal.safeCopy(d, s, n);
    return dest;
}

/// Set n bytes of memory to value c
pub export fn memset(s: ?*anyopaque, c: c_int, n: usize) ?*anyopaque {
    if (n == 0) return s;
    if (s == null) return s;

    const d = @as([*]u8, @ptrCast(s.?));
    const val = @as(u8, @truncate(@as(c_uint, @bitCast(c))));

    internal.safeFill(d, val, n);
    return s;
}

/// Copy n bytes from src to dest (handles overlapping)
pub export fn memmove(dest: ?*anyopaque, src: ?*const anyopaque, n: usize) ?*anyopaque {
    if (n == 0) return dest;
    if (dest == null or src == null) return dest;

    const d = @as([*]u8, @ptrCast(dest.?));
    const s = @as([*]const u8, @ptrCast(src.?));

    const d_ptr = @intFromPtr(d);
    const s_ptr = @intFromPtr(s);
    const s_end = s_ptr + n;
    const d_end = d_ptr + n;

    if (d_ptr == s_ptr or d_ptr >= s_end or s_ptr >= d_end) {
        internal.safeCopy(d, s, n);
        return dest;
    }

    if (d_ptr < s_ptr) {
        internal.safeCopy(d, s, n);
        return dest;
    }

    if (builtin.cpu.arch == .x86_64 and n >= @sizeOf(usize)) {
        const word_size = @sizeOf(usize);
        var i: usize = n;
        while (i > 0 and (i % word_size) != 0) {
            i -= 1;
            d[i] = s[i];
        }

        const word_count = i / word_size;
        const d_words = @as([*]align(1) usize, @ptrCast(d));
        const s_words = @as([*]align(1) const usize, @ptrCast(s));
        var w: usize = word_count;
        while (w > 0) {
            w -= 1;
            d_words[w] = s_words[w];
        }
        return dest;
    }

    var i: usize = n;
    while (i > 0) {
        i -= 1;
        d[i] = s[i];
    }
    return dest;
}

/// Compare n bytes of s1 and s2
pub export fn memcmp(s1: ?*const anyopaque, s2: ?*const anyopaque, n: usize) c_int {
    if (n == 0) return 0;
    if (s1 == null and s2 == null) return 0;
    if (s1 == null) return -1;
    if (s2 == null) return 1;

    const p1 = @as([*]const u8, @ptrCast(s1.?));
    const p2 = @as([*]const u8, @ptrCast(s2.?));

    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (p1[i] != p2[i]) {
            return @as(c_int, p1[i]) - @as(c_int, p2[i]);
        }
    }
    return 0;
}

/// Search for byte c in first n bytes of s
/// Returns pointer to first occurrence or null
pub export fn memchr(s: ?*const anyopaque, c: c_int, n: usize) ?*anyopaque {
    if (s == null or n == 0) return null;

    const p = @as([*]const u8, @ptrCast(s.?));
    const ch: u8 = @truncate(@as(c_uint, @bitCast(c)));

    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (p[i] == ch) {
            return @ptrFromInt(@intFromPtr(s.?) + i);
        }
    }
    return null;
}

/// Search for byte c in first n bytes of s (from end)
/// Returns pointer to last occurrence or null
pub export fn memrchr(s: ?*const anyopaque, c: c_int, n: usize) ?*anyopaque {
    if (s == null or n == 0) return null;

    const p = @as([*]const u8, @ptrCast(s.?));
    const ch: u8 = @truncate(@as(c_uint, @bitCast(c)));

    var i: usize = n;
    while (i > 0) {
        i -= 1;
        if (p[i] == ch) {
            return @ptrFromInt(@intFromPtr(s.?) + i);
        }
    }
    return null;
}

/// Copy memory with explicit non-null pointers (Zig-native helper)
/// Uses safeCopy to avoid @memcpy recursion in freestanding mode
pub fn copyBytes(dest: [*]u8, src: [*]const u8, n: usize) void {
    internal.safeCopy(dest, src, n);
}
