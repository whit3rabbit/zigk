// sscanf implementation (stdio.h)
//
// Formatted input from string.
// Supports: %d, %i, %u, %x, %s, %c, %n, %%
// Supports cross-architecture varargs via VaList abstraction for aarch64.

const std = @import("std");
const builtin = @import("builtin");
const internal = @import("../internal.zig");
const va_list_mod = @import("../va_list.zig");

const VaList = va_list_mod.VaList;

// ============================================================================
// aarch64 _impl exports (called by C shims)
// ============================================================================

/// sscanf_impl - called by C shim on aarch64
pub export fn sscanf_impl(str: ?[*:0]const u8, fmt: ?[*:0]const u8, ap_raw: ?*anyopaque) c_int {
    if (str == null or fmt == null) return -1;
    var ap = VaList.from(ap_raw);
    return sscanf_core(str.?, fmt.?, &ap);
}

/// fscanf_impl - called by C shim on aarch64 (stub)
pub export fn fscanf_impl(stream: ?*anyopaque, fmt: ?[*:0]const u8, ap_raw: ?*anyopaque) c_int {
    _ = stream;
    _ = fmt;
    _ = ap_raw;
    return 0;
}

/// scanf_impl - called by C shim on aarch64 (stub)
pub export fn scanf_impl(fmt: ?[*:0]const u8, ap_raw: ?*anyopaque) c_int {
    _ = fmt;
    _ = ap_raw;
    return 0;
}

// ============================================================================
// x86_64 variadic exports (using @cVaArg which works on x86_64)
// On aarch64, the C shim provides these functions and calls the _impl versions
// ============================================================================

const X86SscanfExports = if (builtin.cpu.arch == .x86_64) struct {
    pub export fn sscanf(str: ?[*:0]const u8, fmt: ?[*:0]const u8, ...) callconv(.c) c_int {
        if (str == null or fmt == null) return -1;
        var args = @cVaStart();
        defer @cVaEnd(&args);
        var ap = VaList.from(@ptrCast(&args));
        return sscanf_core(str.?, fmt.?, &ap);
    }

    pub export fn fscanf(stream: ?*anyopaque, fmt: ?[*:0]const u8, ...) callconv(.c) c_int {
        _ = stream;
        _ = fmt;
        return 0;
    }

    pub export fn scanf(fmt: ?[*:0]const u8, ...) callconv(.c) c_int {
        _ = fmt;
        return 0;
    }
} else struct {};

comptime {
    _ = X86SscanfExports;
}

// ============================================================================
// Core implementation using VaList (for aarch64)
// ============================================================================

fn sscanf_core(str: [*:0]const u8, fmt: [*:0]const u8, ap: *VaList) c_int {
    var s = str;
    var f = fmt;
    var matched: c_int = 0;

    while (f[0] != 0) {
        if (internal.isWhitespace(f[0])) {
            while (internal.isWhitespace(s[0])) s += 1;
            f += 1;
            continue;
        }

        if (f[0] != '%') {
            if (s[0] != f[0]) break;
            s += 1;
            f += 1;
            continue;
        }

        f += 1;
        if (f[0] == 0) break;

        if (f[0] == '%') {
            if (s[0] != '%') break;
            s += 1;
            f += 1;
            continue;
        }

        var suppress = false;
        if (f[0] == '*') {
            suppress = true;
            f += 1;
        }

        var width: usize = 0;
        var has_width = false;
        while (f[0] >= '0' and f[0] <= '9') {
            has_width = true;
            width = width * 10 + @as(usize, f[0] - '0');
            f += 1;
        }
        if (!has_width) width = 4095;

        var is_long = false;
        var is_short = false;
        if (f[0] == 'l') {
            is_long = true;
            f += 1;
            if (f[0] == 'l') f += 1;
        } else if (f[0] == 'h') {
            is_short = true;
            f += 1;
            if (f[0] == 'h') f += 1;
        }

        const spec = f[0];
        f += 1;

        switch (spec) {
            'd', 'i' => {
                while (internal.isWhitespace(s[0])) s += 1;
                var negative = false;
                if (s[0] == '-') { negative = true; s += 1; }
                else if (s[0] == '+') { s += 1; }

                var base: u8 = 10;
                if (spec == 'i' and s[0] == '0') {
                    if (s[1] == 'x' or s[1] == 'X') { base = 16; s += 2; }
                    else { base = 8; }
                }

                var value: i64 = 0;
                var digits: usize = 0;
                while (digits < width) {
                    var digit: ?u8 = null;
                    if (s[0] >= '0' and s[0] <= '9') { digit = s[0] - '0'; }
                    else if (base == 16) {
                        if (s[0] >= 'a' and s[0] <= 'f') { digit = s[0] - 'a' + 10; }
                        else if (s[0] >= 'A' and s[0] <= 'F') { digit = s[0] - 'A' + 10; }
                    }
                    if (digit == null or digit.? >= base) break;
                    value = value * base + digit.?;
                    s += 1;
                    digits += 1;
                }
                if (digits == 0) break;
                if (negative) value = -value;
                if (!suppress) {
                    if (is_long) {
                        const ptr = ap.arg(?*i64);
                        if (ptr) |p| p.* = value;
                    } else if (is_short) {
                        const ptr = ap.arg(?*i16);
                        if (ptr) |p| p.* = @intCast(value);
                    } else {
                        const ptr = ap.arg(?*i32);
                        if (ptr) |p| p.* = @intCast(value);
                    }
                    matched += 1;
                }
            },
            'u' => {
                while (internal.isWhitespace(s[0])) s += 1;
                var value: u64 = 0;
                var digits: usize = 0;
                while (digits < width and s[0] >= '0' and s[0] <= '9') {
                    value = value * 10 + @as(u64, s[0] - '0');
                    s += 1;
                    digits += 1;
                }
                if (digits == 0) break;
                if (!suppress) {
                    if (is_long) {
                        const ptr = ap.arg(?*u64);
                        if (ptr) |p| p.* = value;
                    } else {
                        const ptr = ap.arg(?*u32);
                        if (ptr) |p| p.* = @intCast(value);
                    }
                    matched += 1;
                }
            },
            'x', 'X' => {
                while (internal.isWhitespace(s[0])) s += 1;
                if (s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) { s += 2; }
                var value: u64 = 0;
                var digits: usize = 0;
                while (digits < width) {
                    const digit = internal.hexDigitValue(s[0]);
                    if (digit == null) break;
                    value = value * 16 + digit.?;
                    s += 1;
                    digits += 1;
                }
                if (digits == 0) break;
                if (!suppress) {
                    if (is_long) {
                        const ptr = ap.arg(?*u64);
                        if (ptr) |p| p.* = value;
                    } else {
                        const ptr = ap.arg(?*u32);
                        if (ptr) |p| p.* = @intCast(value);
                    }
                    matched += 1;
                }
            },
            's' => {
                while (internal.isWhitespace(s[0])) s += 1;
                if (!suppress) {
                    const ptr = ap.arg(?[*]u8);
                    if (ptr) |dest| {
                        var i: usize = 0;
                        while (i < width and s[0] != 0 and !internal.isWhitespace(s[0])) {
                            dest[i] = s[0];
                            s += 1;
                            i += 1;
                        }
                        dest[i] = 0;
                        if (i > 0) matched += 1;
                    }
                } else {
                    while (s[0] != 0 and !internal.isWhitespace(s[0])) s += 1;
                }
            },
            'c' => {
                const count = if (!has_width) 1 else width;
                if (!suppress) {
                    const ptr = ap.arg(?[*]u8);
                    if (ptr) |dest| {
                        var i: usize = 0;
                        while (i < count and s[0] != 0) {
                            dest[i] = s[0];
                            s += 1;
                            i += 1;
                        }
                        if (i > 0) matched += 1;
                    }
                } else {
                    var i: usize = 0;
                    while (i < count and s[0] != 0) { s += 1; i += 1; }
                }
            },
            'n' => {
                if (!suppress) {
                    const ptr = ap.arg(?*i32);
                    if (ptr) |p| {
                        p.* = @intCast(@intFromPtr(s) - @intFromPtr(str));
                    }
                }
            },
            '[' => {
                while (f[0] != 0 and f[0] != ']') f += 1;
                if (f[0] == ']') f += 1;
            },
            else => break,
        }
    }
    return matched;
}

// ============================================================================
// x86_64 implementation using @cVaArg (kept for compatibility)
// ============================================================================

fn sscanf_cva(str: [*:0]const u8, fmt: [*:0]const u8, args: anytype) c_int {
    var s = str;
    var f = fmt;
    var matched: c_int = 0;

    while (f[0] != 0) {
        if (internal.isWhitespace(f[0])) {
            while (internal.isWhitespace(s[0])) s += 1;
            f += 1;
            continue;
        }

        if (f[0] != '%') {
            if (s[0] != f[0]) break;
            s += 1;
            f += 1;
            continue;
        }

        f += 1;
        if (f[0] == 0) break;

        if (f[0] == '%') {
            if (s[0] != '%') break;
            s += 1;
            f += 1;
            continue;
        }

        var suppress = false;
        if (f[0] == '*') {
            suppress = true;
            f += 1;
        }

        var width: usize = 0;
        var has_width = false;
        while (f[0] >= '0' and f[0] <= '9') {
            has_width = true;
            width = width * 10 + @as(usize, f[0] - '0');
            f += 1;
        }
        if (!has_width) width = 4095;

        var is_long = false;
        var is_short = false;
        if (f[0] == 'l') {
            is_long = true;
            f += 1;
            if (f[0] == 'l') f += 1;
        } else if (f[0] == 'h') {
            is_short = true;
            f += 1;
            if (f[0] == 'h') f += 1;
        }

        const spec = f[0];
        f += 1;

        switch (spec) {
            'd', 'i' => {
                while (internal.isWhitespace(s[0])) s += 1;
                var negative = false;
                if (s[0] == '-') { negative = true; s += 1; }
                else if (s[0] == '+') { s += 1; }

                var base: u8 = 10;
                if (spec == 'i' and s[0] == '0') {
                    if (s[1] == 'x' or s[1] == 'X') { base = 16; s += 2; }
                    else { base = 8; }
                }

                var value: i64 = 0;
                var digits: usize = 0;
                while (digits < width) {
                    var digit: ?u8 = null;
                    if (s[0] >= '0' and s[0] <= '9') { digit = s[0] - '0'; }
                    else if (base == 16) {
                        if (s[0] >= 'a' and s[0] <= 'f') { digit = s[0] - 'a' + 10; }
                        else if (s[0] >= 'A' and s[0] <= 'F') { digit = s[0] - 'A' + 10; }
                    }
                    if (digit == null or digit.? >= base) break;
                    value = value * base + digit.?;
                    s += 1;
                    digits += 1;
                }
                if (digits == 0) break;
                if (negative) value = -value;
                if (!suppress) {
                    if (is_long) {
                        const ptr = @cVaArg(args, ?*c_long);
                        if (ptr) |p| p.* = @intCast(value);
                    } else if (is_short) {
                        const ptr = @cVaArg(args, ?*c_short);
                        if (ptr) |p| p.* = @intCast(value);
                    } else {
                        const ptr = @cVaArg(args, ?*c_int);
                        if (ptr) |p| p.* = @intCast(value);
                    }
                    matched += 1;
                }
            },
            'u' => {
                while (internal.isWhitespace(s[0])) s += 1;
                var value: u64 = 0;
                var digits: usize = 0;
                while (digits < width and s[0] >= '0' and s[0] <= '9') {
                    value = value * 10 + @as(u64, s[0] - '0');
                    s += 1;
                    digits += 1;
                }
                if (digits == 0) break;
                if (!suppress) {
                    if (is_long) {
                        const ptr = @cVaArg(args, ?*c_ulong);
                        if (ptr) |p| p.* = @intCast(value);
                    } else {
                        const ptr = @cVaArg(args, ?*c_uint);
                        if (ptr) |p| p.* = @intCast(value);
                    }
                    matched += 1;
                }
            },
            'x', 'X' => {
                while (internal.isWhitespace(s[0])) s += 1;
                if (s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) { s += 2; }
                var value: u64 = 0;
                var digits: usize = 0;
                while (digits < width) {
                    const digit = internal.hexDigitValue(s[0]);
                    if (digit == null) break;
                    value = value * 16 + digit.?;
                    s += 1;
                    digits += 1;
                }
                if (digits == 0) break;
                if (!suppress) {
                    if (is_long) {
                        const ptr = @cVaArg(args, ?*c_ulong);
                        if (ptr) |p| p.* = @intCast(value);
                    } else {
                        const ptr = @cVaArg(args, ?*c_uint);
                        if (ptr) |p| p.* = @intCast(value);
                    }
                    matched += 1;
                }
            },
            's' => {
                while (internal.isWhitespace(s[0])) s += 1;
                if (!suppress) {
                    const ptr = @cVaArg(args, ?[*]u8);
                    if (ptr) |dest| {
                        var i: usize = 0;
                        while (i < width and s[0] != 0 and !internal.isWhitespace(s[0])) {
                            dest[i] = s[0];
                            s += 1;
                            i += 1;
                        }
                        dest[i] = 0;
                        if (i > 0) matched += 1;
                    }
                } else {
                    while (s[0] != 0 and !internal.isWhitespace(s[0])) s += 1;
                }
            },
            'c' => {
                const count = if (!has_width) 1 else width;
                if (!suppress) {
                    const ptr = @cVaArg(args, ?[*]u8);
                    if (ptr) |dest| {
                        var i: usize = 0;
                        while (i < count and s[0] != 0) {
                            dest[i] = s[0];
                            s += 1;
                            i += 1;
                        }
                        if (i > 0) matched += 1;
                    }
                } else {
                    var i: usize = 0;
                    while (i < count and s[0] != 0) { s += 1; i += 1; }
                }
            },
            'n' => {
                if (!suppress) {
                    const ptr = @cVaArg(args, ?*c_int);
                    if (ptr) |p| {
                        p.* = @intCast(@intFromPtr(s) - @intFromPtr(str));
                    }
                }
            },
            '[' => {
                while (f[0] != 0 and f[0] != ']') f += 1;
                if (f[0] == ']') f += 1;
            },
            else => break,
        }
    }
    return matched;
}
