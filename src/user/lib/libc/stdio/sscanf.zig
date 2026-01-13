// sscanf/fscanf implementation (stdio.h)
//
// Formatted input from string or file.
// Supports: %d, %i, %u, %x, %s, %c, %n, %%, %[...]
// Supports cross-architecture varargs via VaList abstraction for aarch64.

const std = @import("std");
const builtin = @import("builtin");
const internal = @import("../internal.zig");
const va_list_mod = @import("../va_list.zig");
const streams = @import("streams.zig");
const file = @import("file.zig");

const VaList = va_list_mod.VaList;
const FILE = file.FILE;
const EOF = file.EOF;

// ============================================================================
// aarch64 _impl exports (called by C shims)
// ============================================================================

/// sscanf_impl - called by C shim on aarch64
pub export fn sscanf_impl(str: ?[*:0]const u8, fmt: ?[*:0]const u8, ap_raw: ?*anyopaque) c_int {
    if (str == null or fmt == null) return -1;
    var ap = VaList.from(ap_raw);
    return sscanf_core(str.?, fmt.?, &ap);
}

/// fscanf_impl - called by C shim on aarch64
pub export fn fscanf_impl(stream: ?*anyopaque, fmt: ?[*:0]const u8, ap_raw: ?*anyopaque) c_int {
    if (stream == null or fmt == null) return EOF;
    const f: *FILE = @ptrCast(@alignCast(stream.?));
    var ap = VaList.from(ap_raw);
    return fscanf_core(f, fmt.?, &ap);
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
        if (stream == null or fmt == null) return EOF;
        const f: *FILE = @ptrCast(@alignCast(stream.?));
        var args = @cVaStart();
        defer @cVaEnd(&args);
        var ap = VaList.from(@ptrCast(&args));
        return fscanf_core(f, fmt.?, &ap);
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

        // Security: Cap width at 4095 to prevent overflow from malicious format strings
        // like "%99999999999999999999s". Overflow would wrap to small value causing
        // unexpected truncation. Capping provides predictable behavior.
        const MAX_WIDTH: usize = 4095;
        var width: usize = 0;
        var has_width = false;
        while (f[0] >= '0' and f[0] <= '9') {
            has_width = true;
            const digit = @as(usize, f[0] - '0');
            width = @min(std.math.mul(usize, width, 10) catch MAX_WIDTH, MAX_WIDTH);
            width = @min(std.math.add(usize, width, digit) catch MAX_WIDTH, MAX_WIDTH);
            f += 1;
        }
        if (!has_width) width = MAX_WIDTH;

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
                    // SECURITY: Use checked arithmetic to prevent overflow
                    const mul_result = std.math.mul(i64, value, @as(i64, base)) catch break;
                    value = std.math.add(i64, mul_result, @as(i64, digit.?)) catch break;
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
                        // SECURITY: Saturate to i16 range to prevent UB from @intCast
                        const clamped = std.math.clamp(value, std.math.minInt(i16), std.math.maxInt(i16));
                        if (ptr) |p| p.* = @intCast(clamped);
                    } else {
                        const ptr = ap.arg(?*i32);
                        // SECURITY: Saturate to i32 range to prevent UB from @intCast
                        const clamped = std.math.clamp(value, std.math.minInt(i32), std.math.maxInt(i32));
                        if (ptr) |p| p.* = @intCast(clamped);
                    }
                    matched += 1;
                }
            },
            'u' => {
                while (internal.isWhitespace(s[0])) s += 1;
                var value: u64 = 0;
                var digits: usize = 0;
                while (digits < width and s[0] >= '0' and s[0] <= '9') {
                    // SECURITY: Use checked arithmetic to prevent overflow
                    const mul_result = std.math.mul(u64, value, 10) catch break;
                    value = std.math.add(u64, mul_result, @as(u64, s[0] - '0')) catch break;
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
                        // SECURITY: Saturate to u32 range to prevent UB from @intCast
                        const clamped = @min(value, std.math.maxInt(u32));
                        if (ptr) |p| p.* = @intCast(clamped);
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
                    // SECURITY: Use checked arithmetic to prevent overflow
                    const mul_result = std.math.mul(u64, value, 16) catch break;
                    value = std.math.add(u64, mul_result, digit.?) catch break;
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
                        // SECURITY: Saturate to u32 range to prevent UB from @intCast
                        const clamped = @min(value, std.math.maxInt(u32));
                        if (ptr) |p| p.* = @intCast(clamped);
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
                // Parse scanset: %[abc] matches chars in set, %[^abc] matches chars NOT in set
                var negated = false;
                if (f[0] == '^') {
                    negated = true;
                    f += 1;
                }

                // Build scanset - handle ] as first char specially
                var scanset: [256]bool = [_]bool{false} ** 256;
                if (f[0] == ']') {
                    scanset[']'] = true;
                    f += 1;
                }
                while (f[0] != 0 and f[0] != ']') {
                    scanset[f[0]] = true;
                    f += 1;
                }
                if (f[0] == ']') f += 1;

                // Read matching characters
                if (!suppress) {
                    const ptr = ap.arg(?[*]u8);
                    if (ptr) |dest| {
                        var i: usize = 0;
                        while (i < width and s[0] != 0) {
                            const in_set = scanset[s[0]];
                            const matches = if (negated) !in_set else in_set;
                            if (!matches) break;
                            dest[i] = s[0];
                            s += 1;
                            i += 1;
                        }
                        dest[i] = 0;
                        if (i > 0) matched += 1;
                    }
                } else {
                    while (s[0] != 0) {
                        const in_set = scanset[s[0]];
                        const matches = if (negated) !in_set else in_set;
                        if (!matches) break;
                        s += 1;
                    }
                }
            },
            else => break,
        }
    }
    return matched;
}

// ============================================================================
// fscanf_core - Read formatted input from FILE stream
// ============================================================================

fn fscanf_core(stream: *FILE, fmt: [*:0]const u8, ap: *VaList) c_int {
    var f = fmt;
    var matched: c_int = 0;

    while (f[0] != 0) {
        // Skip whitespace in format - matches any amount of input whitespace
        if (internal.isWhitespace(f[0])) {
            var c = streams.fgetc(stream);
            while (c != EOF and internal.isWhitespace(@truncate(@as(c_uint, @bitCast(c))))) {
                c = streams.fgetc(stream);
            }
            // Push back non-whitespace char
            if (c != EOF) _ = streams.ungetc(c, stream);
            f += 1;
            continue;
        }

        // Literal character match
        if (f[0] != '%') {
            const c = streams.fgetc(stream);
            if (c == EOF or @as(u8, @truncate(@as(c_uint, @bitCast(c)))) != f[0]) {
                if (c != EOF) _ = streams.ungetc(c, stream);
                break;
            }
            f += 1;
            continue;
        }

        f += 1;
        if (f[0] == 0) break;

        // Literal %
        if (f[0] == '%') {
            const c = streams.fgetc(stream);
            if (c == EOF or @as(u8, @truncate(@as(c_uint, @bitCast(c)))) != '%') {
                if (c != EOF) _ = streams.ungetc(c, stream);
                break;
            }
            f += 1;
            continue;
        }

        // Assignment suppression
        var suppress = false;
        if (f[0] == '*') {
            suppress = true;
            f += 1;
        }

        // Field width
        const MAX_WIDTH: usize = 4095;
        var width: usize = 0;
        var has_width = false;
        while (f[0] >= '0' and f[0] <= '9') {
            has_width = true;
            const digit = @as(usize, f[0] - '0');
            width = @min(std.math.mul(usize, width, 10) catch MAX_WIDTH, MAX_WIDTH);
            width = @min(std.math.add(usize, width, digit) catch MAX_WIDTH, MAX_WIDTH);
            f += 1;
        }
        if (!has_width) width = MAX_WIDTH;

        // Length modifiers
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
                // Skip leading whitespace
                var c = streams.fgetc(stream);
                while (c != EOF and internal.isWhitespace(@truncate(@as(c_uint, @bitCast(c))))) {
                    c = streams.fgetc(stream);
                }
                if (c == EOF) break;

                var negative = false;
                var ch: u8 = @truncate(@as(c_uint, @bitCast(c)));
                if (ch == '-') {
                    negative = true;
                    c = streams.fgetc(stream);
                    if (c == EOF) break;
                    ch = @truncate(@as(c_uint, @bitCast(c)));
                } else if (ch == '+') {
                    c = streams.fgetc(stream);
                    if (c == EOF) break;
                    ch = @truncate(@as(c_uint, @bitCast(c)));
                }

                var base: u8 = 10;
                if (spec == 'i' and ch == '0') {
                    c = streams.fgetc(stream);
                    if (c == EOF) {
                        // Just "0"
                        if (!suppress) {
                            if (is_long) {
                                const ptr = ap.arg(?*i64);
                                if (ptr) |p| p.* = 0;
                            } else if (is_short) {
                                const ptr = ap.arg(?*i16);
                                if (ptr) |p| p.* = 0;
                            } else {
                                const ptr = ap.arg(?*i32);
                                if (ptr) |p| p.* = 0;
                            }
                            matched += 1;
                        }
                        continue;
                    }
                    ch = @truncate(@as(c_uint, @bitCast(c)));
                    if (ch == 'x' or ch == 'X') {
                        base = 16;
                        c = streams.fgetc(stream);
                        if (c == EOF) break;
                        ch = @truncate(@as(c_uint, @bitCast(c)));
                    } else {
                        base = 8;
                    }
                }

                var value: i64 = 0;
                var digits: usize = 0;
                while (digits < width) {
                    var digit_val: ?u8 = null;
                    if (ch >= '0' and ch <= '9') {
                        digit_val = ch - '0';
                    } else if (base == 16) {
                        if (ch >= 'a' and ch <= 'f') digit_val = ch - 'a' + 10;
                        if (ch >= 'A' and ch <= 'F') digit_val = ch - 'A' + 10;
                    }
                    if (digit_val == null or digit_val.? >= base) break;

                    const mul_result = std.math.mul(i64, value, @as(i64, base)) catch break;
                    value = std.math.add(i64, mul_result, @as(i64, digit_val.?)) catch break;
                    digits += 1;

                    c = streams.fgetc(stream);
                    if (c == EOF) break;
                    ch = @truncate(@as(c_uint, @bitCast(c)));
                }

                // Push back unmatched char
                if (c != EOF and digits > 0) _ = streams.ungetc(c, stream);

                if (digits == 0) {
                    if (c != EOF) _ = streams.ungetc(c, stream);
                    break;
                }

                if (negative) value = -value;
                if (!suppress) {
                    if (is_long) {
                        const ptr = ap.arg(?*i64);
                        if (ptr) |p| p.* = value;
                    } else if (is_short) {
                        const ptr = ap.arg(?*i16);
                        // SECURITY: Saturate to i16 range to prevent UB from @intCast
                        const clamped = std.math.clamp(value, std.math.minInt(i16), std.math.maxInt(i16));
                        if (ptr) |p| p.* = @intCast(clamped);
                    } else {
                        const ptr = ap.arg(?*i32);
                        // SECURITY: Saturate to i32 range to prevent UB from @intCast
                        const clamped = std.math.clamp(value, std.math.minInt(i32), std.math.maxInt(i32));
                        if (ptr) |p| p.* = @intCast(clamped);
                    }
                    matched += 1;
                }
            },
            'u' => {
                var c = streams.fgetc(stream);
                while (c != EOF and internal.isWhitespace(@truncate(@as(c_uint, @bitCast(c))))) {
                    c = streams.fgetc(stream);
                }
                if (c == EOF) break;

                var value: u64 = 0;
                var digits: usize = 0;
                var ch: u8 = @truncate(@as(c_uint, @bitCast(c)));

                while (digits < width and ch >= '0' and ch <= '9') {
                    const mul_result = std.math.mul(u64, value, 10) catch break;
                    value = std.math.add(u64, mul_result, @as(u64, ch - '0')) catch break;
                    digits += 1;
                    c = streams.fgetc(stream);
                    if (c == EOF) break;
                    ch = @truncate(@as(c_uint, @bitCast(c)));
                }
                if (c != EOF and digits > 0) _ = streams.ungetc(c, stream);
                if (digits == 0) {
                    if (c != EOF) _ = streams.ungetc(c, stream);
                    break;
                }

                if (!suppress) {
                    if (is_long) {
                        const ptr = ap.arg(?*u64);
                        if (ptr) |p| p.* = value;
                    } else {
                        const ptr = ap.arg(?*u32);
                        // SECURITY: Saturate to u32 range to prevent UB from @intCast
                        const clamped = @min(value, std.math.maxInt(u32));
                        if (ptr) |p| p.* = @intCast(clamped);
                    }
                    matched += 1;
                }
            },
            'x', 'X' => {
                var c = streams.fgetc(stream);
                while (c != EOF and internal.isWhitespace(@truncate(@as(c_uint, @bitCast(c))))) {
                    c = streams.fgetc(stream);
                }
                if (c == EOF) break;

                var ch: u8 = @truncate(@as(c_uint, @bitCast(c)));
                // Skip 0x prefix
                if (ch == '0') {
                    c = streams.fgetc(stream);
                    if (c != EOF) {
                        ch = @truncate(@as(c_uint, @bitCast(c)));
                        if (ch == 'x' or ch == 'X') {
                            c = streams.fgetc(stream);
                            if (c == EOF) break;
                            ch = @truncate(@as(c_uint, @bitCast(c)));
                        }
                    } else {
                        break;
                    }
                }

                var value: u64 = 0;
                var digits: usize = 0;
                while (digits < width) {
                    const digit_val = internal.hexDigitValue(ch);
                    if (digit_val == null) break;
                    const mul_result = std.math.mul(u64, value, 16) catch break;
                    value = std.math.add(u64, mul_result, digit_val.?) catch break;
                    digits += 1;
                    c = streams.fgetc(stream);
                    if (c == EOF) break;
                    ch = @truncate(@as(c_uint, @bitCast(c)));
                }
                if (c != EOF and digits > 0) _ = streams.ungetc(c, stream);
                if (digits == 0) {
                    if (c != EOF) _ = streams.ungetc(c, stream);
                    break;
                }

                if (!suppress) {
                    if (is_long) {
                        const ptr = ap.arg(?*u64);
                        if (ptr) |p| p.* = value;
                    } else {
                        const ptr = ap.arg(?*u32);
                        // SECURITY: Saturate to u32 range to prevent UB from @intCast
                        const clamped = @min(value, std.math.maxInt(u32));
                        if (ptr) |p| p.* = @intCast(clamped);
                    }
                    matched += 1;
                }
            },
            's' => {
                // Skip leading whitespace
                var c = streams.fgetc(stream);
                while (c != EOF and internal.isWhitespace(@truncate(@as(c_uint, @bitCast(c))))) {
                    c = streams.fgetc(stream);
                }
                if (c == EOF) break;

                if (!suppress) {
                    const ptr = ap.arg(?[*]u8);
                    if (ptr) |dest| {
                        var i: usize = 0;
                        while (i < width and c != EOF) {
                            const ch: u8 = @truncate(@as(c_uint, @bitCast(c)));
                            if (internal.isWhitespace(ch)) break;
                            dest[i] = ch;
                            i += 1;
                            c = streams.fgetc(stream);
                        }
                        if (c != EOF) _ = streams.ungetc(c, stream);
                        dest[i] = 0;
                        if (i > 0) matched += 1;
                    }
                } else {
                    while (c != EOF) {
                        const ch: u8 = @truncate(@as(c_uint, @bitCast(c)));
                        if (internal.isWhitespace(ch)) break;
                        c = streams.fgetc(stream);
                    }
                    if (c != EOF) _ = streams.ungetc(c, stream);
                }
            },
            'c' => {
                const count = if (!has_width) 1 else width;
                if (!suppress) {
                    const ptr = ap.arg(?[*]u8);
                    if (ptr) |dest| {
                        var i: usize = 0;
                        while (i < count) {
                            const c = streams.fgetc(stream);
                            if (c == EOF) break;
                            dest[i] = @truncate(@as(c_uint, @bitCast(c)));
                            i += 1;
                        }
                        if (i > 0) matched += 1;
                    }
                } else {
                    var i: usize = 0;
                    while (i < count) {
                        const c = streams.fgetc(stream);
                        if (c == EOF) break;
                        i += 1;
                    }
                }
            },
            'n' => {
                // %n for fscanf would need position tracking - not implemented
                // Just skip this specifier (is_short and is_long not used for %n)
            },
            '[' => {
                // Parse scanset
                var negated = false;
                if (f[0] == '^') {
                    negated = true;
                    f += 1;
                }

                var scanset: [256]bool = [_]bool{false} ** 256;
                if (f[0] == ']') {
                    scanset[']'] = true;
                    f += 1;
                }
                while (f[0] != 0 and f[0] != ']') {
                    scanset[f[0]] = true;
                    f += 1;
                }
                if (f[0] == ']') f += 1;

                // Read matching characters
                if (!suppress) {
                    const ptr = ap.arg(?[*]u8);
                    if (ptr) |dest| {
                        var i: usize = 0;
                        while (i < width) {
                            const c = streams.fgetc(stream);
                            if (c == EOF) break;
                            const ch: u8 = @truncate(@as(c_uint, @bitCast(c)));
                            const in_set = scanset[ch];
                            const matches = if (negated) !in_set else in_set;
                            if (!matches) {
                                _ = streams.ungetc(c, stream);
                                break;
                            }
                            dest[i] = ch;
                            i += 1;
                        }
                        dest[i] = 0;
                        if (i > 0) matched += 1;
                    }
                } else {
                    while (true) {
                        const c = streams.fgetc(stream);
                        if (c == EOF) break;
                        const ch: u8 = @truncate(@as(c_uint, @bitCast(c)));
                        const in_set = scanset[ch];
                        const matches = if (negated) !in_set else in_set;
                        if (!matches) {
                            _ = streams.ungetc(c, stream);
                            break;
                        }
                    }
                }
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

        // Security: Cap width at 4095 to prevent overflow from malicious format strings
        const MAX_WIDTH: usize = 4095;
        var width: usize = 0;
        var has_width = false;
        while (f[0] >= '0' and f[0] <= '9') {
            has_width = true;
            const digit = @as(usize, f[0] - '0');
            width = @min(std.math.mul(usize, width, 10) catch MAX_WIDTH, MAX_WIDTH);
            width = @min(std.math.add(usize, width, digit) catch MAX_WIDTH, MAX_WIDTH);
            f += 1;
        }
        if (!has_width) width = MAX_WIDTH;

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
                    // SECURITY: Use checked arithmetic to prevent overflow
                    const mul_result = std.math.mul(i64, value, @as(i64, base)) catch break;
                    value = std.math.add(i64, mul_result, @as(i64, digit.?)) catch break;
                    s += 1;
                    digits += 1;
                }
                if (digits == 0) break;
                if (negative) value = -value;
                if (!suppress) {
                    if (is_long) {
                        const ptr = @cVaArg(args, ?*c_long);
                        // SECURITY: Saturate to c_long range to prevent UB from @intCast
                        const clamped = std.math.clamp(value, std.math.minInt(c_long), std.math.maxInt(c_long));
                        if (ptr) |p| p.* = @intCast(clamped);
                    } else if (is_short) {
                        const ptr = @cVaArg(args, ?*c_short);
                        // SECURITY: Saturate to c_short range to prevent UB from @intCast
                        const clamped = std.math.clamp(value, std.math.minInt(c_short), std.math.maxInt(c_short));
                        if (ptr) |p| p.* = @intCast(clamped);
                    } else {
                        const ptr = @cVaArg(args, ?*c_int);
                        // SECURITY: Saturate to c_int range to prevent UB from @intCast
                        const clamped = std.math.clamp(value, std.math.minInt(c_int), std.math.maxInt(c_int));
                        if (ptr) |p| p.* = @intCast(clamped);
                    }
                    matched += 1;
                }
            },
            'u' => {
                while (internal.isWhitespace(s[0])) s += 1;
                var value: u64 = 0;
                var digits: usize = 0;
                while (digits < width and s[0] >= '0' and s[0] <= '9') {
                    // SECURITY: Use checked arithmetic to prevent overflow
                    const mul_result = std.math.mul(u64, value, 10) catch break;
                    value = std.math.add(u64, mul_result, @as(u64, s[0] - '0')) catch break;
                    s += 1;
                    digits += 1;
                }
                if (digits == 0) break;
                if (!suppress) {
                    if (is_long) {
                        const ptr = @cVaArg(args, ?*c_ulong);
                        // SECURITY: Saturate to c_ulong range to prevent UB from @intCast
                        const clamped = @min(value, std.math.maxInt(c_ulong));
                        if (ptr) |p| p.* = @intCast(clamped);
                    } else {
                        const ptr = @cVaArg(args, ?*c_uint);
                        // SECURITY: Saturate to c_uint range to prevent UB from @intCast
                        const clamped = @min(value, std.math.maxInt(c_uint));
                        if (ptr) |p| p.* = @intCast(clamped);
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
                    // SECURITY: Use checked arithmetic to prevent overflow
                    const mul_result = std.math.mul(u64, value, 16) catch break;
                    value = std.math.add(u64, mul_result, digit.?) catch break;
                    s += 1;
                    digits += 1;
                }
                if (digits == 0) break;
                if (!suppress) {
                    if (is_long) {
                        const ptr = @cVaArg(args, ?*c_ulong);
                        // SECURITY: Saturate to c_ulong range to prevent UB from @intCast
                        const clamped = @min(value, std.math.maxInt(c_ulong));
                        if (ptr) |p| p.* = @intCast(clamped);
                    } else {
                        const ptr = @cVaArg(args, ?*c_uint);
                        // SECURITY: Saturate to c_uint range to prevent UB from @intCast
                        const clamped = @min(value, std.math.maxInt(c_uint));
                        if (ptr) |p| p.* = @intCast(clamped);
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
                // Parse scanset: %[abc] matches chars in set, %[^abc] matches chars NOT in set
                var negated = false;
                if (f[0] == '^') {
                    negated = true;
                    f += 1;
                }

                // Build scanset - handle ] as first char specially
                var scanset: [256]bool = [_]bool{false} ** 256;
                if (f[0] == ']') {
                    scanset[']'] = true;
                    f += 1;
                }
                while (f[0] != 0 and f[0] != ']') {
                    scanset[f[0]] = true;
                    f += 1;
                }
                if (f[0] == ']') f += 1;

                // Read matching characters
                if (!suppress) {
                    const ptr = @cVaArg(args, ?[*]u8);
                    if (ptr) |dest| {
                        var i: usize = 0;
                        while (i < width and s[0] != 0) {
                            const in_set = scanset[s[0]];
                            const matches = if (negated) !in_set else in_set;
                            if (!matches) break;
                            dest[i] = s[0];
                            s += 1;
                            i += 1;
                        }
                        dest[i] = 0;
                        if (i > 0) matched += 1;
                    }
                } else {
                    while (s[0] != 0) {
                        const in_set = scanset[s[0]];
                        const matches = if (negated) !in_set else in_set;
                        if (!matches) break;
                        s += 1;
                    }
                }
            },
            else => break,
        }
    }
    return matched;
}
