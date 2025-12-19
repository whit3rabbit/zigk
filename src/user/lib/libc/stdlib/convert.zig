// String to number conversion (stdlib.h)
//
// Functions for parsing numbers from strings.

const internal = @import("../internal.zig");
const errno_mod = @import("../errno.zig");

/// Convert string to integer with overflow protection
/// On overflow, returns INT_MAX or INT_MIN and sets errno to ERANGE
pub export fn atoi(str: ?[*:0]const u8) c_int {
    if (str == null) return 0;
    var s = str.?;

    // Skip whitespace
    while (internal.isWhitespace(s[0])) {
        s += 1;
    }

    // Handle sign
    var negative: bool = false;
    if (s[0] == '-') {
        negative = true;
        s += 1;
    } else if (s[0] == '+') {
        s += 1;
    }

    // Parse digits with overflow checking
    const INT_MAX: c_int = 2147483647;
    const INT_MIN: c_int = -2147483648;
    var result: c_int = 0;
    var overflowed = false;

    while (s[0] >= '0' and s[0] <= '9') {
        const digit: c_int = @as(c_int, s[0] - '0');

        // Check multiplication overflow
        const mul_result = @mulWithOverflow(result, 10);
        if (mul_result[1] != 0) {
            overflowed = true;
            break;
        }

        // Check addition overflow
        const add_result = @addWithOverflow(mul_result[0], digit);
        if (add_result[1] != 0) {
            overflowed = true;
            break;
        }

        result = add_result[0];
        s += 1;
    }

    if (overflowed) {
        errno_mod.errno = errno_mod.ERANGE;
        return if (negative) INT_MIN else INT_MAX;
    }

    return if (negative) -result else result;
}

/// Convert string to long integer with overflow protection
/// On overflow, returns LONG_MAX or LONG_MIN and sets errno to ERANGE
pub export fn atol(str: ?[*:0]const u8) c_long {
    if (str == null) return 0;
    var s = str.?;

    while (internal.isWhitespace(s[0])) {
        s += 1;
    }

    var negative: bool = false;
    if (s[0] == '-') {
        negative = true;
        s += 1;
    } else if (s[0] == '+') {
        s += 1;
    }

    // Parse digits with overflow checking
    const LONG_MAX: c_long = 9223372036854775807;
    const LONG_MIN: c_long = -9223372036854775808;
    var result: c_long = 0;
    var overflowed = false;

    while (s[0] >= '0' and s[0] <= '9') {
        const digit: c_long = @as(c_long, s[0] - '0');

        const mul_result = @mulWithOverflow(result, 10);
        if (mul_result[1] != 0) {
            overflowed = true;
            break;
        }

        const add_result = @addWithOverflow(mul_result[0], digit);
        if (add_result[1] != 0) {
            overflowed = true;
            break;
        }

        result = add_result[0];
        s += 1;
    }

    if (overflowed) {
        errno_mod.errno = errno_mod.ERANGE;
        return if (negative) LONG_MIN else LONG_MAX;
    }

    return if (negative) -result else result;
}

/// Convert string to long long integer with overflow protection
/// On overflow, returns LLONG_MAX or LLONG_MIN and sets errno to ERANGE
pub export fn atoll(str: ?[*:0]const u8) c_longlong {
    if (str == null) return 0;
    var s = str.?;

    while (internal.isWhitespace(s[0])) {
        s += 1;
    }

    var negative: bool = false;
    if (s[0] == '-') {
        negative = true;
        s += 1;
    } else if (s[0] == '+') {
        s += 1;
    }

    // Parse digits with overflow checking
    const LLONG_MAX: c_longlong = 9223372036854775807;
    const LLONG_MIN: c_longlong = -9223372036854775808;
    var result: c_longlong = 0;
    var overflowed = false;

    while (s[0] >= '0' and s[0] <= '9') {
        const digit: c_longlong = @as(c_longlong, s[0] - '0');

        const mul_result = @mulWithOverflow(result, 10);
        if (mul_result[1] != 0) {
            overflowed = true;
            break;
        }

        const add_result = @addWithOverflow(mul_result[0], digit);
        if (add_result[1] != 0) {
            overflowed = true;
            break;
        }

        result = add_result[0];
        s += 1;
    }

    if (overflowed) {
        errno_mod.errno = errno_mod.ERANGE;
        return if (negative) LLONG_MIN else LLONG_MAX;
    }

    return if (negative) -result else result;
}

/// Convert string to long with base detection and overflow protection
/// On overflow, returns LONG_MAX or LONG_MIN and sets errno to ERANGE
pub export fn strtol(str: ?[*:0]const u8, endptr: ?*?[*:0]u8, base_arg: c_int) c_long {
    const LONG_MAX: c_long = 9223372036854775807;
    const LONG_MIN: c_long = -9223372036854775808;

    if (str == null) {
        if (endptr) |ep| ep.* = null;
        return 0;
    }
    var s = str.?;

    // Skip whitespace
    while (internal.isWhitespace(s[0])) {
        s += 1;
    }

    // Handle sign
    var negative: bool = false;
    if (s[0] == '-') {
        negative = true;
        s += 1;
    } else if (s[0] == '+') {
        s += 1;
    }

    // Determine base
    var base: c_int = base_arg;
    if (base == 0) {
        if (s[0] == '0') {
            if (s[1] == 'x' or s[1] == 'X') {
                base = 16;
                s += 2;
            } else {
                base = 8;
            }
        } else {
            base = 10;
        }
    } else if (base == 16 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
        s += 2;
    }

    // Parse digits with overflow checking
    var result: c_long = 0;
    var overflowed = false;

    while (true) {
        var digit: c_int = -1;
        if (s[0] >= '0' and s[0] <= '9') {
            digit = s[0] - '0';
        } else if (s[0] >= 'a' and s[0] <= 'z') {
            digit = s[0] - 'a' + 10;
        } else if (s[0] >= 'A' and s[0] <= 'Z') {
            digit = s[0] - 'A' + 10;
        }

        if (digit < 0 or digit >= base) break;

        // Check multiplication overflow
        const mul_result = @mulWithOverflow(result, @as(c_long, base));
        if (mul_result[1] != 0) {
            overflowed = true;
            s += 1;
            continue;
        }

        // Check addition overflow
        const add_result = @addWithOverflow(mul_result[0], @as(c_long, digit));
        if (add_result[1] != 0) {
            overflowed = true;
            s += 1;
            continue;
        }

        result = add_result[0];
        s += 1;
    }

    if (endptr) |ep| {
        ep.* = @ptrCast(@constCast(s));
    }

    if (overflowed) {
        errno_mod.errno = errno_mod.ERANGE;
        return if (negative) LONG_MIN else LONG_MAX;
    }

    return if (negative) -result else result;
}

/// Convert string to unsigned long with base detection and overflow protection
/// On overflow, returns ULONG_MAX and sets errno to ERANGE
pub export fn strtoul(str: ?[*:0]const u8, endptr: ?*?[*:0]u8, base_arg: c_int) c_ulong {
    const ULONG_MAX: c_ulong = 18446744073709551615;

    if (str == null) {
        if (endptr) |ep| ep.* = null;
        return 0;
    }
    var s = str.?;

    while (internal.isWhitespace(s[0])) {
        s += 1;
    }

    if (s[0] == '+') s += 1;

    var base: c_int = base_arg;
    if (base == 0) {
        if (s[0] == '0') {
            if (s[1] == 'x' or s[1] == 'X') {
                base = 16;
                s += 2;
            } else {
                base = 8;
            }
        } else {
            base = 10;
        }
    } else if (base == 16 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
        s += 2;
    }

    // Parse digits with overflow checking
    var result: c_ulong = 0;
    var overflowed = false;

    while (true) {
        var digit: c_int = -1;
        if (s[0] >= '0' and s[0] <= '9') {
            digit = s[0] - '0';
        } else if (s[0] >= 'a' and s[0] <= 'z') {
            digit = s[0] - 'a' + 10;
        } else if (s[0] >= 'A' and s[0] <= 'Z') {
            digit = s[0] - 'A' + 10;
        }

        if (digit < 0 or digit >= base) break;

        // Check multiplication overflow
        const mul_result = @mulWithOverflow(result, @as(c_ulong, @intCast(base)));
        if (mul_result[1] != 0) {
            overflowed = true;
            s += 1;
            continue;
        }

        // Check addition overflow
        const add_result = @addWithOverflow(mul_result[0], @as(c_ulong, @intCast(digit)));
        if (add_result[1] != 0) {
            overflowed = true;
            s += 1;
            continue;
        }

        result = add_result[0];
        s += 1;
    }

    if (endptr) |ep| {
        ep.* = @ptrCast(@constCast(s));
    }

    if (overflowed) {
        errno_mod.errno = errno_mod.ERANGE;
        return ULONG_MAX;
    }

    return result;
}

/// Convert string to long long with base detection
pub export fn strtoll(str: ?[*:0]const u8, endptr: ?*?[*:0]u8, base_arg: c_int) c_longlong {
    // Implementation similar to strtol but with c_longlong
    const result = strtol(str, endptr, base_arg);
    return @as(c_longlong, result);
}

/// Convert string to unsigned long long with base detection
pub export fn strtoull(str: ?[*:0]const u8, endptr: ?*?[*:0]u8, base_arg: c_int) c_ulonglong {
    const result = strtoul(str, endptr, base_arg);
    return @as(c_ulonglong, result);
}

/// Convert string to double (simplified)
pub export fn atof(nptr: ?[*:0]const u8) f64 {
    if (nptr == null) return 0.0;
    const s = nptr.?;

    var i: usize = 0;

    // Skip whitespace
    while (s[i] != 0 and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}

    // Check sign
    var negative: bool = false;
    if (s[i] == '-') {
        negative = true;
        i += 1;
    } else if (s[i] == '+') {
        i += 1;
    }

    // Parse integer part
    var result: f64 = 0.0;
    while (s[i] != 0 and s[i] >= '0' and s[i] <= '9') {
        result = result * 10.0 + @as(f64, @floatFromInt(s[i] - '0'));
        i += 1;
    }

    // Parse fractional part
    if (s[i] == '.') {
        i += 1;
        var frac: f64 = 0.1;
        while (s[i] != 0 and s[i] >= '0' and s[i] <= '9') {
            result += @as(f64, @floatFromInt(s[i] - '0')) * frac;
            frac *= 0.1;
            i += 1;
        }
    }

    // TODO: Handle exponent (e/E notation)

    return if (negative) -result else result;
}

/// Convert string to double with end pointer
pub export fn strtod(nptr: ?[*:0]const u8, endptr: ?*?[*:0]u8) f64 {
    // Simplified - just use atof and set endptr to end of parsed portion
    const result = atof(nptr);
    if (endptr) |ep| {
        if (nptr) |s| {
            var i: usize = 0;
            // Skip what was parsed
            while (s[i] != 0 and (s[i] == ' ' or s[i] == '\t' or s[i] == '-' or s[i] == '+' or
                (s[i] >= '0' and s[i] <= '9') or s[i] == '.')) : (i += 1)
            {}
            ep.* = @ptrCast(@constCast(s + i));
        } else {
            ep.* = null;
        }
    }
    return result;
}

/// Convert string to float
pub export fn strtof(nptr: ?[*:0]const u8, endptr: ?*?[*:0]u8) f32 {
    return @floatCast(strtod(nptr, endptr));
}
